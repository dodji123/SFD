"""Procurations sur les comptes d'épargne et chèques à signatures multiples (module 38)."""
import datetime as dt

from fastapi import APIRouter, Depends, HTTPException
from pydantic import BaseModel, Field

from ..auth import User, agence_filter, agence_scope, require, verifier_agence
from ..db import all_rows, one_row, tx

router = APIRouter(prefix="/api", tags=["procurations-cheques"])


# ---------------------------------------------------------------- procurations
class ProcurationIn(BaseModel):
    compte_id: int
    mandataire_nom: str = Field(min_length=2, max_length=200)
    mandataire_piece: str = Field(min_length=3, max_length=100)
    mandataire_tel: str | None = Field(default=None, max_length=30)
    debut: dt.date | None = None
    fin: dt.date | None = None
    plafond: int | None = Field(default=None, gt=0)


@router.get("/procurations")
def lister_procurations(compte_id: int | None = None, agence_id: int | None = None, user: User = Depends(require("epargne:read"))):
    ag = agence_filter(user, agence_id)
    with tx() as cur:
        return all_rows(
            cur,
            "SELECT p.*, ce.numero AS compte, cl.nom AS client FROM procuration p JOIN compte_epargne ce ON ce.id = p.compte_id JOIN client cl ON cl.id = ce.client_id "
            "WHERE (%s::int IS NULL OR p.agence_id = %s) AND (%s::int IS NULL OR p.compte_id = %s) ORDER BY p.id DESC LIMIT 200",
            (ag, ag, compte_id, compte_id),
        )


@router.post("/procurations", status_code=201)
def creer_procuration(body: ProcurationIn, user: User = Depends(require("procuration:write"))):
    with tx(user.login) as cur:
        ag = verifier_agence(cur, user, "compte_epargne", body.compte_id)
        return one_row(
            cur,
            "INSERT INTO procuration(agence_id, compte_id, mandataire_nom, mandataire_piece, mandataire_tel, debut, fin, plafond, cree_par) "
            "VALUES (%s, %s, %s, %s, %s, COALESCE(%s, current_date), %s, %s, %s) RETURNING *",
            (ag, body.compte_id, body.mandataire_nom, body.mandataire_piece, body.mandataire_tel, body.debut, body.fin, body.plafond, user.id),
        )


@router.post("/procurations/{procuration_id}/valider")
def valider_procuration(procuration_id: int, user: User = Depends(require("procuration:valider"))):
    """Validation par une autre personne que celle qui a saisi la procuration (contrôlé par la base)."""
    with tx(user.login) as cur:
        verifier_agence(cur, user, "procuration", procuration_id)
        cur.execute("SELECT valider_procuration(%s, %s)", (procuration_id, user.id))
        return one_row(cur, "SELECT * FROM procuration WHERE id = %s", (procuration_id,))


@router.post("/procurations/{procuration_id}/revoquer")
def revoquer_procuration(procuration_id: int, user: User = Depends(require("procuration:valider"))):
    with tx(user.login) as cur:
        verifier_agence(cur, user, "procuration", procuration_id)
        r = one_row(cur, "UPDATE procuration SET statut = 'revoquee' WHERE id = %s AND statut <> 'revoquee' RETURNING *", (procuration_id,))
    if r is None:
        raise HTTPException(status_code=422, detail="Procuration déjà révoquée")
    return r


# ---------------------------------------------------------------- chèques
class ChequeIn(BaseModel):
    compte_banque_id: int
    numero_cheque: str = Field(min_length=1, max_length=30)
    beneficiaire: str = Field(min_length=2, max_length=200)
    objet: str = Field(min_length=3, max_length=500)
    montant: int = Field(gt=0)


FONCTION_PAR_ROLE = {"directeur": "directeur", "comptable": "comptable", "admin": "president_ca"}

CHEQUE_SQL = (
    "SELECT c.*, u.nom AS prepare_par, "
    "  COALESCE((SELECT json_agg(json_build_object('fonction', s.fonction, 'nom', us.nom, 'signe_le', s.signe_le) ORDER BY s.signe_le) "
    "            FROM cheque_signature s JOIN utilisateur us ON us.id = s.utilisateur_id WHERE s.cheque_id = c.id), '[]'::json) AS signatures "
    "FROM cheque_emission c LEFT JOIN utilisateur u ON u.id = c.cree_par "
)


@router.get("/cheques")
def lister_cheques(agence_id: int | None = None, user: User = Depends(require("cheque:read"))):
    ag = agence_filter(user, agence_id)
    with tx() as cur:
        return all_rows(cur, CHEQUE_SQL + "WHERE (%s::int IS NULL OR c.agence_id = %s) ORDER BY c.id DESC LIMIT 200", (ag, ag))


@router.post("/cheques", status_code=201)
def preparer_cheque(body: ChequeIn, user: User = Depends(require("cheque:prepare"))):
    with tx(user.login) as cur:
        cb = one_row(cur, "SELECT agence_id FROM compte_banque WHERE id = %s AND actif", (body.compte_banque_id,))
        if cb is None:
            raise HTTPException(status_code=404, detail="Compte bancaire introuvable")
        ag = agence_scope(user, cb["agence_id"])
        cid = one_row(
            cur,
            "INSERT INTO cheque_emission(agence_id, compte_banque_id, numero_cheque, beneficiaire, objet, montant, cree_par) "
            "VALUES (%s, %s, %s, %s, %s, %s, %s) RETURNING id",
            (ag, body.compte_banque_id, body.numero_cheque, body.beneficiaire, body.objet, body.montant, user.id),
        )["id"]
        return one_row(cur, CHEQUE_SQL + "WHERE c.id = %s", (cid,))


@router.post("/cheques/{cheque_id}/signer")
def signer_cheque(cheque_id: int, user: User = Depends(require("cheque:sign"))):
    """La qualité de signataire découle du rôle : directeur, comptable, ou président du conseil (administrateur)."""
    fonction = FONCTION_PAR_ROLE.get(user.role)
    if fonction is None:
        raise HTTPException(status_code=403, detail="Ce rôle ne signe pas les chèques")
    with tx(user.login) as cur:
        verifier_agence(cur, user, "cheque_emission", cheque_id)
        cur.execute("INSERT INTO cheque_signature(cheque_id, utilisateur_id, fonction) VALUES (%s, %s, %s)", (cheque_id, user.id, fonction))
        return one_row(cur, CHEQUE_SQL + "WHERE c.id = %s", (cheque_id,))


@router.post("/cheques/{cheque_id}/emettre")
def emettre_cheque(cheque_id: int, user: User = Depends(require("cheque:prepare"))):
    with tx(user.login) as cur:
        verifier_agence(cur, user, "cheque_emission", cheque_id)
        cur.execute("SELECT emettre_cheque(%s)", (cheque_id,))
        return one_row(cur, CHEQUE_SQL + "WHERE c.id = %s", (cheque_id,))


@router.post("/cheques/{cheque_id}/annuler")
def annuler_cheque(cheque_id: int, user: User = Depends(require("cheque:prepare"))):
    with tx(user.login) as cur:
        verifier_agence(cur, user, "cheque_emission", cheque_id)
        r = one_row(cur, "UPDATE cheque_emission SET statut = 'annule' WHERE id = %s AND statut = 'prepare' RETURNING id", (cheque_id,))
        if r is None:
            raise HTTPException(status_code=422, detail="Seul un chèque non émis s'annule")
        return one_row(cur, CHEQUE_SQL + "WHERE c.id = %s", (cheque_id,))
