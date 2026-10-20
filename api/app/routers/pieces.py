"""Pièces justificatives des opérations (module 29) : génération, compilation des retraits de tontine, consultation.

Pas de pièce pour le dépôt de tontine (collecte). Les retraits de plusieurs cycles d'un client se compilent sur une seule pièce.
Les routes d'opération (épargne, adhésion, dépôts) appellent les fonctions `piece_*` pour fournir leur pièce dans la réponse."""
import datetime as dt
import json

from fastapi import APIRouter, Depends, HTTPException, Query
from pydantic import BaseModel, Field

from ..auth import User, agence_scope, require
from ..db import all_rows, one_row, tx

router = APIRouter(prefix="/api/pieces", tags=["pieces"])

TYPES = {
    "depot_epargne": "Reçu de dépôt", "retrait_epargne": "Reçu de retrait", "adhesion": "Reçu d'adhésion",
    "souscription_parts": "Reçu de souscription de parts", "depot_garantie": "Reçu de dépôt de garantie",
    "liberation_garantie": "Pièce de déblocage de garantie", "depot_terme": "Reçu de dépôt à terme",
    "deblocage_terme": "Pièce de déblocage de dépôt à terme", "rupture_terme": "Pièce de rupture de dépôt à terme",
    "retrait_tontine": "Pièce de retrait de tontine",
}


def _creer(cur, user: User, type_: str, client_id: int, compte_id: int | None, date: dt.date, libelle: str, lignes: list[dict]) -> int:
    return one_row(cur, "SELECT creer_piece(%s, %s, %s, %s, %s, %s::jsonb, %s) AS id",
                   (type_, client_id, compte_id, date, libelle, json.dumps(lignes), user.id))["id"]


def _existante(cur, source: str) -> int | None:
    r = one_row(cur, "SELECT piece_id FROM piece_justificative_ligne WHERE source = %s", (source,))
    return r["piece_id"] if r else None


# ------------------------------------------------------------------ une opération = une pièce (idempotent)
def piece_mouvement(cur, user: User, mouvement_id: int) -> int | None:
    """Dépôt ou retrait d'épargne (les dépôts de garantie ont leur propre pièce)."""
    source = f"mouvement_epargne:{mouvement_id}"
    if (p := _existante(cur, source)) is not None:
        return p
    m = one_row(cur, "SELECT m.type, m.montant, m.date_operation, m.libelle, m.reference, ce.id AS compte_id, ce.numero AS compte, ce.client_id "
                     "FROM mouvement_epargne m JOIN compte_epargne ce ON ce.id = m.compte_id WHERE m.id = %s", (mouvement_id,))
    if m is None or m["type"] not in ("depot", "retrait") or (m["reference"] or "").startswith("depot_garantie:"):
        return None
    depot = m["type"] == "depot"
    lib = f"{'Dépôt' if depot else 'Retrait'} sur le compte {m['compte']}" + (f" : {m['libelle']}" if m["libelle"] else "")
    return _creer(cur, user, "depot_epargne" if depot else "retrait_epargne", m["client_id"], m["compte_id"], m["date_operation"],
                  "Dépôt d'épargne" if depot else "Retrait d'épargne", [{"libelle": lib, "montant": int(m["montant"]), "source": source}])


def piece_adhesion(cur, user: User, compte_id: int) -> int | None:
    """Adhésion d'un compte : le droit d'adhésion et les parts souscrites (lignes ajoutées une seule fois)."""
    a = one_row(cur, "SELECT a.id, a.client_id, a.date_adhesion, a.droit_adhesion, ce.numero AS compte FROM adhesion a JOIN compte_epargne ce ON ce.id = a.compte_id "
                     "WHERE a.compte_id = %s", (compte_id,))
    if a is None:
        return None
    lignes = []
    if _existante(cur, f"adhesion:{a['id']}") is None:
        lignes.append({"libelle": f"Droit d'adhésion — compte {a['compte']}", "montant": int(a["droit_adhesion"]), "source": f"adhesion:{a['id']}"})
    for s in all_rows(cur, "SELECT id, nb_parts, valeur_nominale, montant FROM souscription_part WHERE adhesion_id = %s ORDER BY id", (a["id"],)):
        if _existante(cur, f"souscription_part:{s['id']}") is None:
            lignes.append({"libelle": f"{s['nb_parts']} part(s) sociale(s) de {int(s['valeur_nominale'])} F — compte {a['compte']}", "montant": int(s["montant"]), "source": f"souscription_part:{s['id']}"})
    if not lignes:
        return _existante(cur, f"adhesion:{a['id']}")
    entree = lignes[0]["source"].startswith("adhesion:")
    return _creer(cur, user, "adhesion" if entree else "souscription_parts", a["client_id"], compte_id, dt.date.today(),
                  "Adhésion et parts sociales" if entree else "Souscription de parts sociales", lignes)


def piece_garantie(cur, user: User, depot_id: int, liberation: bool = False) -> int | None:
    source = f"{'liberation_garantie' if liberation else 'depot_garantie'}:{depot_id}"
    if (p := _existante(cur, source)) is not None:
        return p
    d = one_row(cur, "SELECT d.client_id, d.compte_id, d.montant, d.motif, d.date_depot, d.date_liberation, d.numero, d.statut, ce.numero AS compte "
                     "FROM depot_garantie d JOIN compte_epargne ce ON ce.id = d.compte_id WHERE d.id = %s", (depot_id,))
    if d is None or (liberation and d["statut"] != "libere"):
        return None
    if liberation:
        return _creer(cur, user, "liberation_garantie", d["client_id"], d["compte_id"], d["date_liberation"], "Déblocage de dépôt de garantie",
                      [{"libelle": f"Déblocage du dépôt de garantie {d['numero']} — compte {d['compte']}", "montant": int(d["montant"]), "source": source}])
    return _creer(cur, user, "depot_garantie", d["client_id"], d["compte_id"], d["date_depot"], "Dépôt de garantie",
                  [{"libelle": f"Dépôt de garantie {d['numero']} — compte {d['compte']}" + (f" : {d['motif']}" if d["motif"] else ""), "montant": int(d["montant"]), "source": source}])


def piece_terme(cur, user: User, depot_id: int, solde: bool = False) -> int | None:
    d = one_row(cur, "SELECT d.client_id, d.compte_id, d.montant, d.numero, d.duree_mois, d.taux_annuel, d.date_depot, d.date_echeance, d.interets_prevus, "
                     "       d.statut, d.date_deblocage, d.interets_verses, ce.numero AS compte FROM depot_terme d JOIN compte_epargne ce ON ce.id = d.compte_id WHERE d.id = %s", (depot_id,))
    if d is None:
        return None
    if not solde:
        source = f"depot_terme:{depot_id}"
        if (p := _existante(cur, source)) is not None:
            return p
        return _creer(cur, user, "depot_terme", d["client_id"], d["compte_id"], d["date_depot"], "Dépôt à terme",
                      [{"libelle": f"Placement {d['numero']} : {d['duree_mois']} mois à {round(float(d['taux_annuel']) * 100, 2)} %, échéance le {d['date_echeance'].strftime('%d/%m/%Y')} — compte {d['compte']}",
                        "montant": int(d["montant"]), "source": source}])
    if d["statut"] == "en_cours":
        return None
    rompu = d["statut"] == "rompu"
    prefixe = "rupture_terme" if rompu else "deblocage_terme"
    if (p := _existante(cur, f"{prefixe}:{depot_id}:capital")) is not None:
        return p
    lignes = [{"libelle": f"Capital du dépôt {d['numero']} rendu au compte {d['compte']}", "montant": int(d["montant"]), "source": f"{prefixe}:{depot_id}:capital"}]
    if int(d["interets_verses"] or 0) > 0:
        lignes.append({"libelle": f"Intérêts du dépôt {d['numero']}", "montant": int(d["interets_verses"]), "source": f"{prefixe}:{depot_id}:interets"})
    return _creer(cur, user, prefixe, d["client_id"], d["compte_id"], d["date_deblocage"],
                  "Rupture anticipée de dépôt à terme" if rompu else "Déblocage de dépôt à terme", lignes)


# ------------------------------------------------------------------ lecture
def detail(cur, piece_id: int) -> dict:
    p = one_row(cur, "SELECT p.*, cl.numero AS client_numero, cl.nom AS client, cl.telephone, ce.numero AS compte, a.code AS agence_code, a.libelle AS agence, a.adresse AS agence_adresse, a.ville AS agence_ville, "
                     "       a.telephone AS agence_telephone, a.email AS agence_email, u.login AS utilisateur "
                     "FROM piece_justificative p JOIN client cl ON cl.id = p.client_id JOIN agence a ON a.id = p.agence_id "
                     "LEFT JOIN compte_epargne ce ON ce.id = p.compte_id LEFT JOIN utilisateur u ON u.id = p.utilisateur_id WHERE p.id = %s", (piece_id,))
    if p is None:
        raise HTTPException(status_code=404, detail="Introuvable")
    p["titre"] = TYPES.get(p["type"], p["type"])
    inst = one_row(cur, "SELECT raison_sociale, sigle, agrement, immatriculation, adresse, ville, telephone, email, site_web, logo, pied_de_page FROM institution WHERE id = 1")
    p["institution"] = inst
    p["lignes"] = all_rows(cur, "SELECT ligne, libelle, montant FROM piece_justificative_ligne WHERE piece_id = %s ORDER BY ligne", (piece_id,))
    return p


@router.get("")
def lister(date: dt.date | None = None, type: str | None = None, client_id: int | None = None, agence_id: int | None = None,
           limit: int = Query(200, ge=1, le=500), user: User = Depends(require("epargne:read"))):
    ag = agence_scope(user, agence_id)
    with tx() as cur:
        return all_rows(
            cur,
            "SELECT p.id, p.numero, p.type, p.date_piece, p.libelle, p.montant, cl.numero AS client_numero, cl.nom AS client, ce.numero AS compte, "
            "       (SELECT count(*) FROM piece_justificative_ligne l WHERE l.piece_id = p.id) AS nb_lignes "
            "FROM piece_justificative p JOIN client cl ON cl.id = p.client_id LEFT JOIN compte_epargne ce ON ce.id = p.compte_id "
            "WHERE p.agence_id = %s AND (%s::date IS NULL OR p.date_piece = %s) AND (%s::text IS NULL OR p.type = %s) AND (%s::int IS NULL OR p.client_id = %s) "
            "ORDER BY p.id DESC LIMIT %s", (ag, date, date, type, type, client_id, client_id, limit))


@router.get("/{piece_id}")
def lire(piece_id: int, user: User = Depends(require("epargne:read"))):
    with tx() as cur:
        p = detail(cur, piece_id)
        if not user.peut_agence(p["agence_id"]):
            raise HTTPException(status_code=404, detail="Introuvable")
        return p


# ------------------------------------------------------------------ génération à la demande
class OperationIn(BaseModel):
    source: str = Field(pattern=r"^(mouvement_epargne|adhesion|depot_garantie|liberation_garantie|depot_terme|deblocage_terme|rupture_terme)$")
    id: int


@router.post("/operation", status_code=201)
def pour_operation(body: OperationIn, user: User = Depends(require("epargne:write"))):
    """Pièce d'une opération (créée si elle n'existe pas encore, sinon la même est renvoyée) : `id` est celui du mouvement,
    du compte (adhésion), du dépôt de garantie ou du dépôt à terme."""
    with tx(user.login) as cur:
        if body.source == "mouvement_epargne":
            ag = one_row(cur, "SELECT ce.agence_id FROM mouvement_epargne m JOIN compte_epargne ce ON ce.id = m.compte_id WHERE m.id = %s", (body.id,))
            pid = piece_mouvement(cur, user, body.id) if ag and user.peut_agence(ag["agence_id"]) else None
        elif body.source == "adhesion":
            ag = one_row(cur, "SELECT agence_id FROM compte_epargne WHERE id = %s", (body.id,))
            pid = piece_adhesion(cur, user, body.id) if ag and user.peut_agence(ag["agence_id"]) else None
        elif body.source in ("depot_garantie", "liberation_garantie"):
            ag = one_row(cur, "SELECT agence_id FROM depot_garantie WHERE id = %s", (body.id,))
            pid = piece_garantie(cur, user, body.id, body.source == "liberation_garantie") if ag and user.peut_agence(ag["agence_id"]) else None
        else:
            ag = one_row(cur, "SELECT agence_id FROM depot_terme WHERE id = %s", (body.id,))
            pid = piece_terme(cur, user, body.id, body.source != "depot_terme") if ag and user.peut_agence(ag["agence_id"]) else None
        if pid is None:
            raise HTTPException(status_code=422, detail="Aucune pièce justificative pour cette opération")
        return detail(cur, pid)


class RetraitsIn(BaseModel):
    retrait_ids: list[int] = Field(min_length=1, max_length=50)
    date: dt.date | None = None


@router.post("/retraits-tontine", status_code=201)
def pour_retraits_tontine(body: RetraitsIn, user: User = Depends(require("retrait:execute"))):
    """Une seule pièce pour les retraits exécutés de plusieurs cycles d'un même client."""
    with tx(user.login) as cur:
        if not user.siege:
            autres = one_row(cur, "SELECT count(*) AS n FROM retrait WHERE id = ANY(%s) AND NOT (agence_id = ANY(%s))", (body.retrait_ids, user.agences))["n"]
            if autres:
                raise HTTPException(status_code=404, detail="Introuvable")
        pid = one_row(cur, "SELECT creer_piece_retraits_tontine(%s::integer[], COALESCE(%s, current_date), %s) AS id", (body.retrait_ids, body.date, user.id))["id"]
        return detail(cur, pid)
