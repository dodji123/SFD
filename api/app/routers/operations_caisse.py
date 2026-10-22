"""Opérations standard (de caisse / hors caisse) et transferts de fonds entre caisses (module 50).
Les règles (comptes cohérents avec la famille, justificatif, seuil de validation, séparation des tâches, accusé de réception,
inaltérabilité) sont dans le schéma ; ce routeur contrôle les droits et le périmètre d'agence."""
import datetime as dt
from typing import Literal

from fastapi import APIRouter, Depends, HTTPException, Query
from pydantic import BaseModel, Field

from ..auth import User, agence_filter, agence_scope, require
from ..db import all_rows, one_row, tx

router = APIRouter(prefix="/api", tags=["operations-caisse"])


# ================================================================== catalogue des opérations standard
class OperationStandardIn(BaseModel):
    code: str = Field(pattern=r"^[a-z0-9_]{2,30}$")
    libelle: str = Field(min_length=3, max_length=200)
    famille: Literal["caisse", "hors_caisse"]
    categorie: Literal["charge", "produit", "immobilisation", "regularisation", "autre"]
    sens: Literal["entree", "sortie"]
    compte_debit: str | None = Field(default=None, max_length=7)
    compte_credit: str | None = Field(default=None, max_length=7)
    journal_code: str = Field(default="OD", max_length=6)
    justificatif_obligatoire: bool = False
    seuil_validation: int | None = Field(default=None, ge=0)


@router.get("/operations-standard")
def lister_operations_standard(famille: str | None = None, categorie: str | None = None, actif: bool | None = None, q: str | None = None,
                               user: User = Depends(require("operation:read"))):
    with tx() as cur:
        return all_rows(
            cur,
            "SELECT s.*, (SELECT count(*) FROM operation_generale g WHERE g.code_operation = s.code) AS nb_utilisations FROM operation_standard s "
            "WHERE (%s::text IS NULL OR famille = %s) AND (%s::text IS NULL OR categorie = %s) AND (%s::boolean IS NULL OR actif = %s) "
            "AND (%s::text IS NULL OR code ILIKE '%%' || %s || '%%' OR libelle ILIKE '%%' || %s || '%%') ORDER BY famille, categorie, libelle",
            (famille or None, famille or None, categorie or None, categorie or None, actif, actif, q or None, q or None, q or None),
        )


@router.post("/operations-standard", status_code=201)
def creer_operation_standard(body: OperationStandardIn, user: User = Depends(require("operation:param"))):
    with tx(user.login) as cur:
        cur.execute(
            "INSERT INTO operation_standard(code, libelle, famille, categorie, sens, compte_debit, compte_credit, journal_code, justificatif_obligatoire, seuil_validation) "
            "VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s, %s)",
            (body.code, body.libelle, body.famille, body.categorie, body.sens, body.compte_debit, body.compte_credit, body.journal_code, body.justificatif_obligatoire, body.seuil_validation),
        )
        return one_row(cur, "SELECT * FROM operation_standard WHERE code = %s", (body.code,))


class OperationStandardMaj(BaseModel):
    libelle: str | None = Field(default=None, min_length=3, max_length=200)
    compte_debit: str | None = Field(default=None, max_length=7)
    compte_credit: str | None = Field(default=None, max_length=7)
    journal_code: str | None = Field(default=None, max_length=6)
    justificatif_obligatoire: bool | None = None
    seuil_validation: int | None = Field(default=None, ge=0)
    sans_seuil: bool = False
    actif: bool | None = None


@router.patch("/operations-standard/{code}")
def modifier_operation_standard(code: str, body: OperationStandardMaj, user: User = Depends(require("operation:param"))):
    with tx(user.login) as cur:
        o = one_row(cur, "SELECT * FROM operation_standard WHERE code = %s", (code,))
        if o is None:
            raise HTTPException(status_code=404, detail="Introuvable")
        comptes_changent = (body.compte_debit, body.compte_credit) != (None, None) and (body.compte_debit, body.compte_credit) != (o["compte_debit"], o["compte_credit"])
        cur.execute(
            "UPDATE operation_standard SET libelle = COALESCE(%s, libelle), compte_debit = COALESCE(%s, compte_debit), compte_credit = COALESCE(%s, compte_credit), "
            "journal_code = COALESCE(%s, journal_code), justificatif_obligatoire = COALESCE(%s, justificatif_obligatoire), "
            "seuil_validation = CASE WHEN %s THEN NULL ELSE COALESCE(%s, seuil_validation) END, actif = COALESCE(%s, actif), "
            "comptes_valides = CASE WHEN %s THEN false ELSE comptes_valides END WHERE code = %s",
            (body.libelle, body.compte_debit, body.compte_credit, body.journal_code, body.justificatif_obligatoire, body.sans_seuil, body.seuil_validation, body.actif, comptes_changent, code),
        )
        return one_row(cur, "SELECT * FROM operation_standard WHERE code = %s", (code,))


@router.post("/operations-standard/{code}/valider-comptes")
def valider_comptes(code: str, user: User = Depends(require("operation:comptes-valider"))):
    """Le comptable atteste les comptes de l'opération (les modifier ensuite remet la validation à zéro)."""
    with tx(user.login) as cur:
        cur.execute("UPDATE operation_standard SET comptes_valides = true WHERE code = %s", (code,))
        if cur.rowcount == 0:
            raise HTTPException(status_code=404, detail="Introuvable")
        return one_row(cur, "SELECT * FROM operation_standard WHERE code = %s", (code,))


# ================================================================== opérations saisies
class OperationIn(BaseModel):
    code_operation: str
    montant: int = Field(gt=0, le=10_000_000_000)
    date_operation: dt.date | None = None
    tiers: str | None = Field(default=None, max_length=200)
    tiers_id: int | None = None
    reference_justificatif: str | None = Field(default=None, max_length=120)
    libelle: str | None = Field(default=None, max_length=300)
    caisse_id: int | None = None          # pour une opération de caisse : la session ouverte de cette caisse à la date de l'opération
    agence_id: int | None = None
    cle: str | None = Field(default=None, min_length=8, max_length=64)


def _session_ouverte(cur, caisse_id: int, jour: dt.date) -> dict:
    s = one_row(cur, "SELECT s.id, k.agence_id FROM session_caisse s JOIN caisse k ON k.id = s.caisse_id WHERE s.caisse_id = %s AND s.date_session = %s AND s.statut = 'ouverte'", (caisse_id, jour))
    if s is None:
        raise HTTPException(status_code=422, detail="Aucune session ouverte pour cette caisse à cette date")
    return s


@router.post("/operations-generales", status_code=201)
def saisir_operation(body: OperationIn, user: User = Depends(require("operation:saisir"))):
    jour = body.date_operation or dt.date.today()
    with tx(user.login) as cur:
        op = one_row(cur, "SELECT famille FROM operation_standard WHERE code = %s AND actif", (body.code_operation,))
        if op is None:
            raise HTTPException(status_code=404, detail="Opération standard inconnue ou inactive")
        session_id = None
        if op["famille"] == "caisse":
            if body.caisse_id is None:
                raise HTTPException(status_code=422, detail="Choisissez la caisse concernée")
            s = _session_ouverte(cur, body.caisse_id, jour)
            if not user.peut_agence(s["agence_id"]):
                raise HTTPException(status_code=403, detail="Agence non autorisée")
            session_id, ag = s["id"], s["agence_id"]
        else:
            ag = agence_scope(user, body.agence_id)
        r = one_row(cur, "SELECT saisir_operation_generale(%s::smallint, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s) AS id",
                    (ag, body.code_operation, jour, body.montant, body.tiers, body.reference_justificatif, body.libelle, session_id, user.id, body.cle, body.tiers_id))
        return one_row(cur, "SELECT * FROM v_operation_generale WHERE id = %s", (r["id"],))


@router.get("/operations-generales")
def lister_operations(statut: str | None = None, famille: str | None = None, categorie: str | None = None, code: str | None = None, q: str | None = None,
                      agence_id: int | None = None, du: dt.date | None = None, au: dt.date | None = None, limit: int = Query(200, ge=1, le=500),
                      user: User = Depends(require("operation:read"))):
    ag = agence_filter(user, agence_id)
    with tx() as cur:
        return all_rows(
            cur,
            "SELECT * FROM v_operation_generale WHERE (%s::int IS NULL OR agence_id = %s) AND (%s::text IS NULL OR statut = %s) AND (%s::text IS NULL OR famille = %s) "
            "AND (%s::text IS NULL OR categorie = %s) AND (%s::text IS NULL OR code_operation = %s) "
            "AND (%s::text IS NULL OR tiers ILIKE '%%' || %s || '%%' OR reference_justificatif ILIKE '%%' || %s || '%%' OR operation ILIKE '%%' || %s || '%%') "
            "AND (%s::date IS NULL OR date_operation >= %s) AND (%s::date IS NULL OR date_operation <= %s) "
            "ORDER BY (statut = 'a_valider') DESC, date_operation DESC, id DESC LIMIT %s",
            (ag, ag, statut or None, statut or None, famille or None, famille or None, categorie or None, categorie or None, code or None, code or None,
             q or None, q or None, q or None, q or None, du, du, au, au, limit),
        )


class DecisionIn(BaseModel):
    valide: bool
    commentaire: str | None = Field(default=None, max_length=300)
    caisse_id: int | None = None


@router.post("/operations-generales/{operation_id}/decider")
def decider_operation(operation_id: int, body: DecisionIn, user: User = Depends(require("operation:valider"))):
    with tx(user.login) as cur:
        o = one_row(cur, "SELECT agence_id, statut, date_operation, famille FROM v_operation_generale WHERE id = %s", (operation_id,))
        if o is None or not user.peut_agence(o["agence_id"]):
            raise HTTPException(status_code=404, detail="Introuvable")
        if o["statut"] != "a_valider":
            raise HTTPException(status_code=422, detail=f"Cette opération est déjà {o['statut']}")
        session = None
        if body.valide and o["famille"] == "caisse" and body.caisse_id:
            session = _session_ouverte(cur, body.caisse_id, dt.date.today())["id"]
        cur.execute("SELECT decider_operation_generale(%s, %s, %s, %s, %s)", (operation_id, body.valide, user.id, body.commentaire, session))
        return one_row(cur, "SELECT * FROM v_operation_generale WHERE id = %s", (operation_id,))


# ================================================================== transferts de fonds
class EnvoiIn(BaseModel):
    caisse_source_id: int
    caisse_dest_id: int
    montant: int = Field(gt=0, le=10_000_000_000)
    motif: str | None = Field(default=None, max_length=300)
    date_envoi: dt.date | None = None


def _caisse(cur, caisse_id: int) -> dict:
    k = one_row(cur, "SELECT id, agence_id, code FROM caisse WHERE id = %s AND actif", (caisse_id,))
    if k is None:
        raise HTTPException(status_code=404, detail="Caisse introuvable")
    return k


@router.post("/transferts-fonds", status_code=201)
def envoyer(body: EnvoiIn, user: User = Depends(require("caisse:write"))):
    jour = body.date_envoi or dt.date.today()
    with tx(user.login) as cur:
        k1 = _caisse(cur, body.caisse_source_id)
        _caisse(cur, body.caisse_dest_id)
        if not user.peut_agence(k1["agence_id"]):
            raise HTTPException(status_code=403, detail="Agence non autorisée")
        s = _session_ouverte(cur, body.caisse_source_id, jour)
        r = one_row(cur, "SELECT envoyer_fonds(%s, %s, %s, %s, %s, %s) AS id", (s["id"], body.caisse_dest_id, body.montant, body.motif, user.id, jour))
        return one_row(cur, "SELECT * FROM v_transfert_fonds WHERE id = %s", (r["id"],))


@router.get("/transferts-fonds/destinations")
def destinations_possibles(user: User = Depends(require("caisse:write"))):
    """Caisses actives de toutes les agences (un envoi de fonds peut viser une autre agence) : code et agence seulement."""
    with tx() as cur:
        return all_rows(cur, "SELECT k.id, k.code, k.type, a.code AS agence, k.agence_id FROM caisse k JOIN agence a ON a.id = k.agence_id WHERE k.actif ORDER BY a.code, k.code")


@router.get("/transferts-fonds")
def lister_transferts_fonds(statut: str | None = None, caisse_id: int | None = None, agence_id: int | None = None, en_retard: bool | None = None,
                            user: User = Depends(require("caisse:read"))):
    ag = agence_filter(user, agence_id)
    with tx() as cur:
        return all_rows(
            cur,
            "SELECT * FROM v_transfert_fonds WHERE (%s::int IS NULL OR agence_source_id = %s OR agence_dest_id = %s) AND (%s::text IS NULL OR statut = %s) "
            "AND (%s::int IS NULL OR caisse_source_id = %s OR caisse_dest_id = %s) AND (%s::boolean IS NULL OR en_retard = %s) ORDER BY (statut = 'envoye') DESC, id DESC LIMIT 300",
            (ag, ag, ag, statut or None, statut or None, caisse_id, caisse_id, caisse_id, en_retard, en_retard),
        )


class ReceptionIn(BaseModel):
    montant_recu: int = Field(ge=0, le=10_000_000_000)
    commentaire: str | None = Field(default=None, max_length=300)


def _transfert_visible(cur, user: User, transfert_id: int) -> dict:
    t = one_row(cur, "SELECT * FROM v_transfert_fonds WHERE id = %s", (transfert_id,))
    if t is None or not (user.peut_agence(t["agence_source_id"]) or user.peut_agence(t["agence_dest_id"])):
        raise HTTPException(status_code=404, detail="Introuvable")
    return t


@router.post("/transferts-fonds/{transfert_id}/recevoir")
def recevoir(transfert_id: int, body: ReceptionIn, user: User = Depends(require("caisse:write"))):
    with tx(user.login) as cur:
        t = _transfert_visible(cur, user, transfert_id)
        if not user.peut_agence(t["agence_dest_id"]):
            raise HTTPException(status_code=403, detail="La réception revient à la caisse destinataire")
        s = _session_ouverte(cur, t["caisse_dest_id"], dt.date.today())
        cur.execute("SELECT recevoir_fonds(%s, %s, %s, %s, %s)", (transfert_id, s["id"], body.montant_recu, user.id, body.commentaire))
        return one_row(cur, "SELECT * FROM v_transfert_fonds WHERE id = %s", (transfert_id,))


class RefusIn(BaseModel):
    motif: str = Field(min_length=5, max_length=300)


@router.post("/transferts-fonds/{transfert_id}/refuser")
def refuser(transfert_id: int, body: RefusIn, user: User = Depends(require("caisse:write"))):
    with tx(user.login) as cur:
        t = _transfert_visible(cur, user, transfert_id)
        if not user.peut_agence(t["agence_dest_id"]):
            raise HTTPException(status_code=403, detail="Le refus revient à la caisse destinataire")
        s = _session_ouverte(cur, t["caisse_source_id"], dt.date.today())
        cur.execute("SELECT refuser_fonds(%s, %s, %s, %s)", (transfert_id, s["id"], user.id, body.motif))
        return one_row(cur, "SELECT * FROM v_transfert_fonds WHERE id = %s", (transfert_id,))
