"""Épargne classique : comptes et mouvements (dépôts, retraits au guichet)."""
import datetime as dt
from typing import Literal

from fastapi import APIRouter, Depends, HTTPException, Query
from pydantic import BaseModel, Field

from ..auth import User, agence_filter, agence_scope, require, verifier_agence
from ..db import all_rows, one_row, tx
from .collecte import trouver_client
from .pieces import piece_adhesion, piece_mouvement

router = APIRouter(prefix="/api/comptes-epargne", tags=["epargne"])

SELECT_COMPTE = (
    "SELECT ce.id, ce.agence_id, ce.client_id, cl.nom AS client, ce.numero, ce.statut, ce.ouvert_le, "
    "       p.libelle AS produit, p.solde_minimum, v.solde, solde_disponible(ce.id) AS disponible "
    "FROM compte_epargne ce JOIN client cl ON cl.id = ce.client_id "
    "JOIN produit_epargne p ON p.id = ce.produit_id JOIN v_solde_compte_epargne v ON v.compte_id = ce.id "
)


class CompteIn(BaseModel):
    client_id: int
    produit_id: int
    numero: str | None = Field(default=None, max_length=25)  # vide : numérotation automatique
    nb_parts: int | None = Field(default=None, ge=1, le=10000)  # parts sociales souscrites avec le compte (obligatoire si adhesion_obligatoire)


@router.get("")
def lister(client_id: int | None = None, agence_id: int | None = None,
           limit: int = Query(100, ge=1, le=500), user: User = Depends(require("epargne:read"))):
    ag = agence_filter(user, agence_id)
    with tx() as cur:
        return all_rows(cur, SELECT_COMPTE + "WHERE (%s::int IS NULL OR ce.agence_id = %s) AND (%s::int IS NULL OR ce.client_id = %s) "
                        "ORDER BY ce.id DESC LIMIT %s", (ag, ag, client_id, client_id, limit))


@router.post("", status_code=201)
def ouvrir(body: CompteIn, user: User = Depends(require("epargne:write"))):
    with tx(user.login) as cur:
        ag = verifier_agence(cur, user, "client", body.client_id)
        p = one_row(cur, "SELECT categorie FROM produit_epargne WHERE id = %s AND actif", (body.produit_id,))
        if p is None or p["categorie"] != "classique":
            raise HTTPException(status_code=422, detail="Le produit doit être un produit d'épargne classique")
        # chaque compte d'épargne classique a sa propre adhésion et ses parts sociales (paramètre adhesion_obligatoire)
        obligatoire = one_row(cur, "SELECT param('adhesion_obligatoire', %s::smallint) AS v", (ag,))["v"] == "oui"
        if body.nb_parts is None and obligatoire:
            raise HTTPException(status_code=422, detail="Un compte d'épargne classique s'ouvre avec son adhésion et au moins le nombre minimal de parts sociales : indiquer nb_parts")
        if body.nb_parts is not None:
            if body.numero is not None:
                raise HTTPException(status_code=422, detail="Le numéro de compte est attribué automatiquement avec l'adhésion")
            nid = one_row(cur, "SELECT ouvrir_compte_adherent(%s, %s, %s, current_date, %s) AS id", (body.client_id, body.produit_id, body.nb_parts, user.id))["id"]
        else:
            nid = one_row(cur, "INSERT INTO compte_epargne(agence_id, client_id, produit_id, numero) VALUES (%s, %s, %s, %s) RETURNING id",
                          (ag, body.client_id, body.produit_id, body.numero))["id"]
        compte = one_row(cur, SELECT_COMPTE + "WHERE ce.id = %s", (nid,))
        compte["piece_id"] = piece_adhesion(cur, user, nid) if body.nb_parts is not None else None
        return compte


@router.get("/recherche")
def rechercher(suffixe: str, produit_id: int, agence_id: int | None = None, date: dt.date | None = None,
               user: User = Depends(require("epargne:read"))):
    """Guichet : retrouve le client par son numéro d'ordre et son compte sur le produit d'épargne classique choisi."""
    ag = agence_scope(user, agence_id)
    with tx() as cur:
        cl = trouver_client(cur, ag, suffixe, date)
        c = one_row(cur, SELECT_COMPTE + "WHERE ce.client_id = %s AND ce.produit_id = %s AND ce.statut = 'actif' ORDER BY ce.id DESC LIMIT 1",
                    (cl["id"], produit_id))
        if c is None:
            raise HTTPException(status_code=404, detail=f"{cl['nom']} n'a aucun compte actif sur ce produit")
        return {"client": cl, "compte": c}


@router.get("/operations")
def operations_du_jour(date: dt.date, agence_id: int | None = None, user: User = Depends(require("epargne:read"))):
    """Tableau des dépôts et retraits au guichet d'un jour, avec l'état de validation de la journée.
    Une opération annulée et sa contre-passation restent visibles mais sortent des totaux."""
    ag = agence_scope(user, agence_id)
    with tx() as cur:
        lignes = all_rows(
            cur,
            "SELECT m.id, m.type, m.montant, m.libelle, m.cree_le, ce.numero AS compte, cl.numero AS client_numero, cl.nom AS client, p.code AS produit, "
            "       a.mouvement_id IS NOT NULL AS annulee, COALESCE(m.reference LIKE 'annulation:%%', false) AS contre_passation "
            "FROM mouvement_epargne m JOIN compte_epargne ce ON ce.id = m.compte_id JOIN client cl ON cl.id = ce.client_id "
            "JOIN produit_epargne p ON p.id = ce.produit_id LEFT JOIN annulation_mouvement a ON a.mouvement_id = m.id "
            "WHERE ce.agence_id = %s AND m.date_operation = %s AND m.type IN ('depot', 'retrait') ORDER BY m.id DESC",
            (ag, date),
        )
        val = one_row(cur, "SELECT v.valide_le, u.login AS valide_par FROM validation_epargne v LEFT JOIN utilisateur u ON u.id = v.valide_par "
                           "WHERE v.agence_id = %s AND v.date_operation = %s", (ag, date))
    for l in lignes:
        l["annulable"] = val is None and not l["annulee"] and not l["contre_passation"]
    comptes = [l for l in lignes if not l["annulee"] and not l["contre_passation"]]
    return {"date": date, "lignes": lignes, "validee": val is not None, "validation": val,
            "total_depots": sum(l["montant"] for l in comptes if l["type"] == "depot"),
            "total_retraits": sum(l["montant"] for l in comptes if l["type"] == "retrait")}


@router.post("/operations/{mouvement_id}/annuler")
def annuler_operation(mouvement_id: int, user: User = Depends(require("epargne:write"))):
    """Annule un dépôt ou un retrait par contre-passation (jamais de suppression)."""
    with tx(user.login) as cur:
        m = one_row(cur, "SELECT ce.agence_id FROM mouvement_epargne m JOIN compte_epargne ce ON ce.id = m.compte_id WHERE m.id = %s", (mouvement_id,))
        if m is None or (user.agence_id is not None and m["agence_id"] != user.agence_id):
            raise HTTPException(status_code=404, detail="Introuvable")
        cid = one_row(cur, "SELECT annuler_mouvement_epargne(%s, %s) AS id", (mouvement_id, user.id))["id"]
    return {"contre_passation_id": cid}


class JourneeEpargneIn(BaseModel):
    date: dt.date
    agence_id: int | None = None
    motif: str | None = Field(default=None, max_length=300)


@router.post("/valider-journee", status_code=201)
def valider_journee(body: JourneeEpargneIn, user: User = Depends(require("collecte:admin"))):
    ag = agence_scope(user, body.agence_id)
    with tx(user.login) as cur:
        cur.execute("SELECT valider_journee_epargne(%s::smallint, %s, %s)", (ag, body.date, user.id))
    return operations_du_jour(body.date, ag, user)


@router.post("/rouvrir-journee")
def rouvrir_journee(body: JourneeEpargneIn, user: User = Depends(require("collecte:admin"))):
    ag = agence_scope(user, body.agence_id)
    with tx(user.login) as cur:
        cur.execute("SELECT rouvrir_journee_epargne(%s::smallint, %s, %s, %s)", (ag, body.date, body.motif, user.id))
    return operations_du_jour(body.date, ag, user)


@router.get("/{compte_id}")
def detail(compte_id: int, user: User = Depends(require("epargne:read"))):
    with tx() as cur:
        verifier_agence(cur, user, "compte_epargne", compte_id)
        return one_row(cur, SELECT_COMPTE + "WHERE ce.id = %s", (compte_id,))


class MouvementIn(BaseModel):
    montant: int = Field(gt=0)
    date_operation: dt.date | None = None
    libelle: str | None = None


def controle_adhesion(cur, agence_id: int, compte_id: int) -> None:
    """Quand l'adhésion est obligatoire, le compte doit avoir une adhésion en règle (parts sociales) pour toute opération."""
    if one_row(cur, "SELECT param('adhesion_obligatoire', %s::smallint) AS v", (agence_id,))["v"] == "oui" and        not one_row(cur, "SELECT membre_en_regle(%s) AS b", (compte_id,))["b"]:
        raise HTTPException(status_code=422, detail="Ce compte n'a pas d'adhésion en règle (parts sociales) : régulariser avant toute opération")


def _mouvement(compte_id: int, type_: Literal["depot", "retrait"], body: MouvementIn, user: User):
    if body.date_operation is not None and body.date_operation > dt.date.today():
        raise HTTPException(status_code=422, detail="La date de l'opération ne peut pas être dans le futur")
    with tx(user.login) as cur:
        ag = verifier_agence(cur, user, "compte_epargne", compte_id)
        controle_adhesion(cur, ag, compte_id)
        mv = one_row(
            cur,
            "INSERT INTO mouvement_epargne(compte_id, type, montant, date_operation, libelle) "
            "VALUES (%s, %s, %s, COALESCE(%s, current_date), %s) RETURNING *",
            (compte_id, type_, body.montant, body.date_operation, body.libelle),
        )
        cpt = one_row(cur, "SELECT v.solde, solde_disponible(v.compte_id) AS disponible FROM v_solde_compte_epargne v WHERE v.compte_id = %s", (compte_id,))
        piece_id = piece_mouvement(cur, user, mv["id"])          # pièce justificative remise au client
    return {"mouvement": mv, **cpt, "piece_id": piece_id}


@router.post("/{compte_id}/depot", status_code=201)
def depot(compte_id: int, body: MouvementIn, user: User = Depends(require("epargne:write"))):
    return _mouvement(compte_id, "depot", body, user)


@router.post("/{compte_id}/retrait", status_code=201)
def retrait(compte_id: int, body: MouvementIn, user: User = Depends(require("epargne:write"))):
    return _mouvement(compte_id, "retrait", body, user)


@router.get("/{compte_id}/mouvements")
def mouvements(compte_id: int, limit: int = Query(100, ge=1, le=1000), user: User = Depends(require("epargne:read"))):
    with tx() as cur:
        verifier_agence(cur, user, "compte_epargne", compte_id)
        return all_rows(
            cur,
            "SELECT id, type, montant, sens_mouvement(type) AS sens, date_operation, libelle, reference "
            "FROM mouvement_epargne WHERE compte_id = %s ORDER BY date_operation DESC, id DESC LIMIT %s",
            (compte_id, limit),
        )
