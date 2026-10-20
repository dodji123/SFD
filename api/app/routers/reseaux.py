"""Réseaux d'agences : regroupement d'agences, rattachement, vue de synthèse du réseau (périmètre du coordinateur)."""
from fastapi import APIRouter, Depends, HTTPException
from pydantic import BaseModel, Field

from ..auth import User, require
from ..db import all_rows, one_row, tx

router = APIRouter(prefix="/api/reseaux", tags=["reseaux"])


def _verifier_acces_reseau(cur, user: User, reseau_id: int) -> None:
    if user.siege:
        return
    r = one_row(cur, "SELECT 1 AS x FROM agence WHERE reseau_id = %s AND id = ANY(%s) LIMIT 1", (reseau_id, user.agences))
    if r is None:
        raise HTTPException(status_code=404, detail="Introuvable")


class ReseauIn(BaseModel):
    code: str = Field(min_length=1, max_length=10, pattern=r"^[A-Za-z0-9_-]+$")
    libelle: str = Field(min_length=1, max_length=200)


class ReseauPatch(BaseModel):
    libelle: str | None = Field(default=None, min_length=1, max_length=200)
    actif: bool | None = None


@router.get("")
def lister(user: User = Depends(require("reseaux:read"))):
    with tx() as cur:
        return all_rows(
            cur,
            "SELECT r.*, (SELECT count(*) FROM agence a WHERE a.reseau_id = r.id) AS nb_agences, "
            "       (SELECT count(*) FROM utilisateur u WHERE u.reseau_id = r.id AND u.actif) AS nb_utilisateurs "
            "FROM reseau r WHERE (%s OR EXISTS (SELECT 1 FROM agence a WHERE a.reseau_id = r.id AND a.id = ANY(%s))) ORDER BY r.code",
            (user.siege, user.agences or []),
        )


@router.post("", status_code=201)
def creer(body: ReseauIn, user: User = Depends(require("reseaux:write"))):
    with tx(user.login) as cur:
        return one_row(cur, "INSERT INTO reseau(code, libelle) VALUES (%s, %s) RETURNING *", (body.code, body.libelle))


@router.patch("/{reseau_id}")
def modifier(reseau_id: int, body: ReseauPatch, user: User = Depends(require("reseaux:write"))):
    champs = body.model_dump(exclude_unset=True)
    if not champs:
        raise HTTPException(status_code=422, detail="Aucune modification")
    sets = ", ".join(f"{c} = %s" for c in champs)
    with tx(user.login) as cur:
        r = one_row(cur, f"UPDATE reseau SET {sets} WHERE id = %s RETURNING *", (*champs.values(), reseau_id))
    if r is None:
        raise HTTPException(status_code=404, detail="Réseau introuvable")
    return r


class AgencesIn(BaseModel):
    agence_ids: list[int]


@router.put("/{reseau_id}/agences")
def rattacher_agences(reseau_id: int, body: AgencesIn, user: User = Depends(require("reseaux:write"))):
    """Fixe la liste des agences du réseau (une agence appartient à un seul réseau)."""
    with tx(user.login) as cur:
        if one_row(cur, "SELECT 1 AS x FROM reseau WHERE id = %s AND actif", (reseau_id,)) is None:
            raise HTTPException(status_code=404, detail="Réseau introuvable ou inactif")
        cur.execute("UPDATE agence SET reseau_id = NULL WHERE reseau_id = %s AND NOT (id = ANY(%s))", (reseau_id, body.agence_ids))
        cur.execute("UPDATE agence SET reseau_id = %s WHERE id = ANY(%s)", (reseau_id, body.agence_ids))
        return all_rows(cur, "SELECT id, code, libelle, reseau_id FROM agence WHERE reseau_id = %s ORDER BY code", (reseau_id,))


@router.get("/{reseau_id}/synthese")
def synthese(reseau_id: int, user: User = Depends(require("reseaux:read"))):
    """Vue agrégée du réseau : une ligne par agence et un total (le coordinateur ne voit que son réseau)."""
    with tx() as cur:
        _verifier_acces_reseau(cur, user, reseau_id)
        reseau = one_row(cur, "SELECT * FROM reseau WHERE id = %s", (reseau_id,))
        if reseau is None:
            raise HTTPException(status_code=404, detail="Introuvable")
        lignes = all_rows(
            cur,
            "SELECT a.id AS agence_id, a.code, a.libelle, "
            "  (SELECT count(*) FROM client c WHERE c.agence_id = a.id) AS clients, "
            "  (SELECT count(*) FROM credit c WHERE c.agence_id = a.id AND c.statut <> 'solde') AS credits_en_cours, "
            "  COALESCE((SELECT sum(s.capital_restant) FROM credit c JOIN v_credit_situation s ON s.credit_id = c.id "
            "             WHERE c.agence_id = a.id AND c.statut <> 'solde'), 0) AS encours, "
            "  (SELECT count(*) FROM credit c WHERE c.agence_id = a.id AND c.statut = 'en_retard') AS credits_en_retard, "
            "  COALESCE((SELECT sum(s.capital_restant) FROM credit c JOIN v_credit_situation s ON s.credit_id = c.id "
            "             WHERE c.agence_id = a.id AND c.statut = 'en_retard'), 0) AS encours_en_retard, "
            "  (SELECT count(*) FROM demande_credit d WHERE d.agence_id = a.id AND d.statut = 'demandee') AS demandes_en_attente "
            "FROM agence a WHERE a.reseau_id = %s AND (%s OR a.id = ANY(%s)) ORDER BY a.code",
            (reseau_id, user.siege, user.agences or []),
        )
    total = {k: sum(l[k] for l in lignes) for k in ("clients", "credits_en_cours", "encours", "credits_en_retard", "encours_en_retard", "demandes_en_attente")}
    total["par_pct"] = round(float(total["encours_en_retard"]) / float(total["encours"]) * 100, 2) if total["encours"] else 0.0
    return {"reseau": reseau, "agences": lignes, "total": total}
