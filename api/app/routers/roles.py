"""Attribution des rôles (module 53) : matrice de droits, rôles personnalisés, affectations temporaires avec validation.
Les règles (séparation des tâches, durée, périmètre, garde-fous de l'administrateur, historique) sont dans le schéma."""
import datetime as dt
from typing import Literal

from fastapi import APIRouter, Depends, HTTPException
from pydantic import BaseModel, Field

from ..auth import User, agence_filter, require
from ..db import all_rows, one_row, tx
from ..perms import PERMS

router = APIRouter(prefix="/api", tags=["roles"])


# ================================================================== matrice
@router.get("/roles")
def lister_roles(user: User = Depends(require("roles:demander"))):
    with tx() as cur:
        return all_rows(
            cur,
            "SELECT r.code, r.libelle, r.systeme, r.actif, "
            "       (SELECT count(*) FROM mf.droit_role d WHERE d.role_code = r.code) AS nb_droits, "
            "       (SELECT count(*) FROM mf.utilisateur u WHERE u.role::text = r.code AND u.actif) AS nb_utilisateurs_base "
            "FROM mf.role_droit r ORDER BY r.systeme DESC, r.code",
        )


@router.get("/roles/utilisateurs")
def utilisateurs_du_perimetre(user: User = Depends(require("roles:demander"))):
    """Utilisateurs actifs du périmètre de l'appelant : ceux à qui l'on peut demander un rôle temporaire."""
    with tx() as cur:
        return all_rows(
            cur,
            "SELECT id, login, nom, role::text AS role, agence_id FROM mf.utilisateur "
            "WHERE actif AND (%s OR (mf.agences_utilisateur(id) && %s::int[])) ORDER BY nom",
            (user.siege, user.agences or []),
        )


@router.get("/roles/matrice")
def matrice(user: User = Depends(require("roles:demander"))):
    """Qui peut faire quoi : une ligne par permission, avec les rôles qui la détiennent."""
    with tx() as cur:
        perms = all_rows(cur, "SELECT p.code, p.categorie, COALESCE(array_agg(d.role_code ORDER BY d.role_code) FILTER (WHERE d.role_code IS NOT NULL), '{}') AS roles "
                              "FROM mf.permission p LEFT JOIN mf.droit_role d ON d.perm = p.code GROUP BY p.code, p.categorie ORDER BY p.categorie, p.code")
        roles = all_rows(cur, "SELECT code, libelle, systeme, actif FROM mf.role_droit ORDER BY systeme DESC, code")
    return {"roles": roles, "permissions": perms}


class RoleIn(BaseModel):
    code: str = Field(pattern=r"^[a-z0-9_]{2,30}$")
    libelle: str = Field(min_length=3, max_length=100)


@router.post("/roles", status_code=201)
def creer_role(body: RoleIn, user: User = Depends(require("roles:gerer"))):
    with tx(user.login) as cur:
        cur.execute("INSERT INTO mf.role_droit(code, libelle, systeme, cree_par) VALUES (%s, %s, false, %s)", (body.code, body.libelle, user.id))
        return one_row(cur, "SELECT code, libelle, systeme, actif FROM mf.role_droit WHERE code = %s", (body.code,))


class RoleMaj(BaseModel):
    libelle: str | None = Field(default=None, min_length=3, max_length=100)
    actif: bool | None = None


@router.patch("/roles/{code}")
def modifier_role(code: str, body: RoleMaj, user: User = Depends(require("roles:gerer"))):
    with tx(user.login) as cur:
        if one_row(cur, "SELECT 1 AS x FROM mf.role_droit WHERE code = %s", (code,)) is None:
            raise HTTPException(status_code=404, detail="Introuvable")
        cur.execute("UPDATE mf.role_droit SET libelle = COALESCE(%s, libelle), actif = COALESCE(%s, actif) WHERE code = %s", (body.libelle, body.actif, code))
        return one_row(cur, "SELECT code, libelle, systeme, actif FROM mf.role_droit WHERE code = %s", (code,))


class DroitsIn(BaseModel):
    permissions: list[str] = Field(max_length=200)


@router.put("/roles/{code}/droits")
def remplacer_droits(code: str, body: DroitsIn, user: User = Depends(require("roles:gerer"))):
    """Remplace l'ensemble des permissions du rôle. Les permissions inconnues sont refusées ; le rôle administrateur
    garde toujours la gestion des rôles et des utilisateurs (garde-fou du schéma)."""
    inconnues = sorted(set(body.permissions) - set(PERMS))
    if inconnues:
        raise HTTPException(status_code=422, detail=f"Permissions inconnues : {', '.join(inconnues)}")
    with tx(user.login) as cur:
        if one_row(cur, "SELECT 1 AS x FROM mf.role_droit WHERE code = %s", (code,)) is None:
            raise HTTPException(status_code=404, detail="Introuvable")
        cur.execute("DELETE FROM mf.droit_role WHERE role_code = %s AND perm <> ALL(%s)", (code, list(body.permissions)))
        cur.execute("INSERT INTO mf.droit_role(role_code, perm) SELECT %s, unnest(%s::text[]) ON CONFLICT DO NOTHING", (code, list(body.permissions)))
        return one_row(cur, "SELECT count(*) AS nb FROM mf.droit_role WHERE role_code = %s", (code,))


# ================================================================== affectations
def _controle_attribution(cur, user: User, utilisateur_id: int, role_code: str) -> None:
    """On n'accorde que des droits qu'on possède soi-même, et seulement à une personne de son périmètre."""
    if user.agences is not None:
        ok = one_row(cur, "SELECT 1 AS x FROM mf.utilisateur WHERE id = %s AND mf.agences_utilisateur(id) && %s::int[]", (utilisateur_id, user.agences))
        if ok is None:
            raise HTTPException(status_code=403, detail="Cette personne n'est pas dans votre périmètre")
    depasse = all_rows(cur, "SELECT perm FROM mf.droit_role WHERE role_code = %s "
                            "EXCEPT SELECT perm FROM mf.droits_utilisateur(%s) AS d(perm)", (role_code, user.id))
    if depasse:
        raise HTTPException(status_code=403, detail="Ce rôle dépasse vos propres droits : " + ", ".join(sorted(d["perm"] for d in depasse)))


class AffectationIn(BaseModel):
    utilisateur_id: int
    role_code: str
    agence_id: int
    date_debut: dt.date
    date_fin: dt.date
    motif: str = Field(min_length=10, max_length=300)


@router.post("/affectations-roles", status_code=201)
def demander_affectation(body: AffectationIn, user: User = Depends(require("roles:demander"))):
    if not user.peut_agence(body.agence_id):
        raise HTTPException(status_code=403, detail="Agence non autorisée")
    with tx(user.login) as cur:
        _controle_attribution(cur, user, body.utilisateur_id, body.role_code)
        r = one_row(cur, "INSERT INTO mf.affectation_role(utilisateur_id, role_code, agence_id, date_debut, date_fin, motif, demande_par) "
                         "VALUES (%s, %s, %s, %s, %s, %s, %s) RETURNING id",
                    (body.utilisateur_id, body.role_code, body.agence_id, body.date_debut, body.date_fin, body.motif, user.id))
        return one_row(cur, "SELECT * FROM mf.v_affectation_role WHERE id = %s", (r["id"],))


@router.get("/affectations-roles")
def lister_affectations(statut: Literal["demandee", "active", "refusee", "revoquee"] | None = None, agence_id: int | None = None,
                        utilisateur_id: int | None = None, user: User = Depends(require("roles:demander"))):
    ag = agence_filter(user, agence_id)
    with tx() as cur:
        return all_rows(
            cur,
            "SELECT * FROM mf.v_affectation_role WHERE (%s::int IS NULL OR agence_id = %s) AND (%s::text IS NULL OR statut = %s) "
            "AND (%s::int IS NULL OR utilisateur_id = %s) ORDER BY (statut = 'demandee') DESC, id DESC LIMIT 300",
            (ag, ag, statut, statut, utilisateur_id, utilisateur_id),
        )


def _affectation_visible(cur, user: User, affectation_id: int) -> None:
    a = one_row(cur, "SELECT agence_id FROM mf.affectation_role WHERE id = %s", (affectation_id,))
    if a is None or not user.peut_agence(a["agence_id"]):
        raise HTTPException(status_code=404, detail="Introuvable")


class DecisionIn(BaseModel):
    accepte: bool
    commentaire: str | None = Field(default=None, max_length=300)


@router.post("/affectations-roles/{affectation_id}/decider")
def decider_affectation(affectation_id: int, body: DecisionIn, user: User = Depends(require("roles:valider"))):
    with tx(user.login) as cur:
        _affectation_visible(cur, user, affectation_id)
        a = one_row(cur, "SELECT utilisateur_id, role_code FROM mf.affectation_role WHERE id = %s", (affectation_id,))
        if body.accepte:
            _controle_attribution(cur, user, a["utilisateur_id"], a["role_code"])
        cur.execute(
            "UPDATE mf.affectation_role SET statut = %s, valide_par = %s, commentaire_decision = %s WHERE id = %s AND statut = 'demandee'",
            ("active" if body.accepte else "refusee", user.id, body.commentaire, affectation_id),
        )
        if cur.rowcount == 0:
            raise HTTPException(status_code=422, detail="Cette demande n'est plus en attente")
        return one_row(cur, "SELECT * FROM mf.v_affectation_role WHERE id = %s", (affectation_id,))


class RevocationIn(BaseModel):
    motif: str = Field(min_length=5, max_length=300)


@router.post("/affectations-roles/{affectation_id}/revoquer")
def revoquer_affectation(affectation_id: int, body: RevocationIn, user: User = Depends(require("roles:valider"))):
    with tx(user.login) as cur:
        _affectation_visible(cur, user, affectation_id)
        cur.execute(
            "UPDATE mf.affectation_role SET statut = 'revoquee', revoque_par = %s, motif_revocation = %s WHERE id = %s AND statut = 'active'",
            (user.id, body.motif, affectation_id),
        )
        if cur.rowcount == 0:
            raise HTTPException(status_code=422, detail="Seule une affectation active se révoque")
        return one_row(cur, "SELECT * FROM mf.v_affectation_role WHERE id = %s", (affectation_id,))
