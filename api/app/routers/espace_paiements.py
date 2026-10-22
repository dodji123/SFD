"""Espace client : collecte par mobile money, suivi de sa collecte et demande de retrait (module 49).

Deux routeurs :
 - `router` (/api/espace) : utilisé par le client lui-même (jeton « client ») ; il ne voit et n'agit que sur ses propres cycles.
   Un paiement n'est inscrit au livret que lorsque l'opérateur le confirme ; le client ne clôture jamais lui-même son cycle :
   sa demande de retrait est examinée par le personnel.
 - `admin_router` (/api) : le personnel suit les paiements, rembourse ceux que le livret n'a pas pu recevoir, décide des
   demandes de retrait ; le webhook de l'opérateur confirme ou refuse un paiement (signature HMAC)."""
import datetime as dt
import json
from typing import Literal

from fastapi import APIRouter, Depends, Header, HTTPException, Query, Request
from pydantic import BaseModel, Field

from .. import mobilemoney
from ..auth import User, agence_filter, require, verifier_agence
from ..db import all_rows, one_row, tx
from .espace import _journal, client_pret

router = APIRouter(prefix="/api/espace", tags=["espace-client-paiements"])
admin_router = APIRouter(prefix="/api", tags=["paiements-mobile"])

TEL = r"^\+?[0-9]{8,15}$"


def _paiement_client(cur, client_id: int, reference: str) -> dict:
    p = one_row(cur, "SELECT * FROM v_paiement_mobile WHERE reference = %s AND client_id = %s", (reference, client_id))
    if p is None:
        raise HTTPException(status_code=404, detail="Introuvable")
    return p


def _vue(p: dict) -> dict:
    """Ce que le client a le droit de voir d'un paiement."""
    return {k: p[k] for k in ("reference", "cycle", "produit", "operateur", "operateur_libelle", "montant", "statut", "motif", "cree_le", "expire_le") if k in p}


# ------------------------------------------------------------------ paiement par mobile money
@router.get("/operateurs")
def operateurs(c: dict = Depends(client_pret)):
    with tx() as cur:
        return {"mode": mobilemoney.mode(), "operateurs": all_rows(cur, "SELECT code, libelle FROM operateur_mobile WHERE actif ORDER BY libelle")}


class PaiementIn(BaseModel):
    cycle_id: int
    operateur: str = Field(min_length=2, max_length=12)
    telephone: str = Field(pattern=TEL)
    montant: int = Field(ge=1, le=100_000_000)
    cle: str = Field(min_length=8, max_length=64)      # clé d'opération générée par l'appareil : rejouer ne crée pas un second paiement


@router.post("/paiements", status_code=201)
def initier_paiement(body: PaiementIn, request: Request, c: dict = Depends(client_pret)):
    with tx(f"client:{c['numero']}") as cur:
        if one_row(cur, "SELECT 1 AS x FROM cycle WHERE id = %s AND client_id = %s", (body.cycle_id, c["id"])) is None:
            raise HTTPException(status_code=404, detail="Introuvable")
        cur.execute("SELECT expirer_paiements_mobile()")
        deja = one_row(cur, "SELECT reference FROM paiement_mobile WHERE cle = %s AND client_id = %s", (body.cle, c["id"]))
        if deja is not None:
            p = _paiement_client(cur, c["id"], deja["reference"])
            return {**_vue(p), "simulation": mobilemoney.simulation_autorisee(), "message": None}
        r = one_row(cur, "INSERT INTO paiement_mobile(cle, client_id, cycle_id, operateur, telephone, montant) VALUES (%s, %s, %s, %s, %s, %s) RETURNING reference",
                    (body.cle, c["id"], body.cycle_id, body.operateur, body.telephone, body.montant))
        info = mobilemoney.initier(r["reference"], body.operateur, body.telephone, body.montant)
        cur.execute("UPDATE paiement_mobile SET ref_operateur = %s WHERE reference = %s", (info["reference_operateur"], r["reference"]))
        _journal(cur, c["id"], "paiement_initie", request, detail=f"{r['reference']} cycle {body.cycle_id}")
        return {**_vue(_paiement_client(cur, c["id"], r["reference"])), "simulation": mobilemoney.simulation_autorisee(), "message": info["message"]}


@router.get("/paiements")
def mes_paiements(c: dict = Depends(client_pret), limit: int = Query(30, ge=1, le=100)):
    with tx() as cur:
        cur.execute("SELECT expirer_paiements_mobile()")
        return [_vue(p) for p in all_rows(cur, "SELECT * FROM v_paiement_mobile WHERE client_id = %s ORDER BY id DESC LIMIT %s", (c["id"], limit))]


@router.get("/paiements/{reference}")
def mon_paiement(reference: str, c: dict = Depends(client_pret)):
    with tx() as cur:
        cur.execute("SELECT expirer_paiements_mobile()")
        return _vue(_paiement_client(cur, c["id"], reference))


class SimulationIn(BaseModel):
    issue: Literal["succes", "echec"]


@router.post("/paiements/{reference}/simuler")
def simuler_issue(reference: str, body: SimulationIn, c: dict = Depends(client_pret)):
    """Démonstration uniquement : joue la réponse de l'opérateur. Indisponible hors du mode simulation (et en production)."""
    if not mobilemoney.simulation_autorisee():
        raise HTTPException(status_code=403, detail="La simulation n'est pas disponible")
    with tx(f"client:{c['numero']}") as cur:
        p = _paiement_client(cur, c["id"], reference)
        if body.issue == "succes":
            cur.execute("SELECT confirmer_paiement_mobile(%s, %s)", (p["id"], f"SIM-OK-{reference}"))
        else:
            cur.execute("SELECT echouer_paiement_mobile(%s, %s)", (p["id"], "Paiement refusé (simulation)"))
        return _vue(_paiement_client(cur, c["id"], reference))


# ------------------------------------------------------------------ suivi de sa collecte
@router.get("/cycles/{cycle_id}/suivi")
def suivi_cycle(cycle_id: int, c: dict = Depends(client_pret)):
    with tx() as cur:
        cy = one_row(
            cur,
            "SELECT s.cycle_id AS id, s.numero, s.statut, s.type_cycle, s.nb_lignes, s.montant_collecte, s.montant_previsionnel, s.reste_a_collecter, s.mise_cycle, s.net, "
            "       c.date_debut, c.date_fin, date_limite_cycle(c.id) AS date_limite, c.nb_lignes_prevues, c.objectif, c.mise_courante, p.code AS produit, p.libelle AS produit_libelle "
            "FROM v_cycle_situation s JOIN cycle c ON c.id = s.cycle_id JOIN produit_epargne p ON p.id = c.produit_id WHERE s.cycle_id = %s AND s.client_id = %s",
            (cycle_id, c["id"]))
        if cy is None:
            raise HTTPException(status_code=404, detail="Introuvable")
        cy["lignes"] = all_rows(cur, "SELECT page, no_ligne, date_collecte, montant_collecte, origine FROM ligne_collecte WHERE cycle_id = %s ORDER BY page DESC, no_ligne DESC LIMIT 62", (cycle_id,))
        cy["paiements"] = [_vue(p) for p in all_rows(cur, "SELECT * FROM v_paiement_mobile WHERE cycle_id = %s AND client_id = %s ORDER BY id DESC LIMIT 10", (cycle_id, c["id"]))]
        cy["demande_retrait"] = one_row(cur, "SELECT id, statut, canal, cree_le, commentaire FROM demande_retrait_client WHERE cycle_id = %s ORDER BY id DESC LIMIT 1", (cycle_id,))
        cy["retrait"] = one_row(cur, "SELECT statut, montant, date_demande FROM retrait WHERE cycle_id = %s AND nature IN ('retrait_client','virement_vers_epargne') AND statut <> 'annule' ORDER BY id DESC LIMIT 1", (cycle_id,))
        cy["progression"] = None if cy["objectif"] in (None, 0) else min(100, round(float(cy["montant_collecte"]) * 100 / float(cy["objectif"])))
        return cy


# ------------------------------------------------------------------ demande de retrait
class DemandeRetraitIn(BaseModel):
    cycle_id: int
    canal: Literal["agence", "mobile_money"] = "agence"
    operateur: str | None = Field(default=None, max_length=12)
    telephone: str | None = Field(default=None, pattern=TEL)
    motif: str | None = Field(default=None, max_length=300)


@router.post("/demandes-retrait", status_code=201)
def demander_retrait(body: DemandeRetraitIn, request: Request, c: dict = Depends(client_pret)):
    with tx(f"client:{c['numero']}") as cur:
        if one_row(cur, "SELECT 1 AS x FROM cycle WHERE id = %s AND client_id = %s", (body.cycle_id, c["id"])) is None:
            raise HTTPException(status_code=404, detail="Introuvable")
        r = one_row(cur, "INSERT INTO demande_retrait_client(client_id, cycle_id, canal, operateur, telephone, motif) VALUES (%s, %s, %s, %s, %s, %s) RETURNING id",
                    (c["id"], body.cycle_id, body.canal, body.operateur, body.telephone, body.motif))
        _journal(cur, c["id"], "demande_retrait", request, detail=f"cycle {body.cycle_id} via {body.canal}")
        return one_row(cur, "SELECT id, cycle, produit, canal, statut, cree_le, commentaire FROM v_demande_retrait_client WHERE id = %s", (r["id"],))


@router.get("/demandes-retrait")
def mes_demandes_retrait(c: dict = Depends(client_pret)):
    with tx() as cur:
        return all_rows(cur, "SELECT id, cycle, produit, canal, statut, cree_le, commentaire FROM v_demande_retrait_client WHERE client_id = %s ORDER BY id DESC LIMIT 30", (c["id"],))


@router.post("/demandes-retrait/{demande_id}/annuler")
def annuler_demande_retrait(demande_id: int, c: dict = Depends(client_pret)):
    with tx(f"client:{c['numero']}") as cur:
        cur.execute("UPDATE demande_retrait_client SET statut = 'annulee' WHERE id = %s AND client_id = %s AND statut = 'en_attente'", (demande_id, c["id"]))
        if cur.rowcount == 0:
            raise HTTPException(status_code=422, detail="Seule une demande en attente s'annule")
        return one_row(cur, "SELECT id, cycle, produit, canal, statut, cree_le, commentaire FROM v_demande_retrait_client WHERE id = %s", (demande_id,))


# ================================================================== personnel
@admin_router.get("/paiements-mobile")
def lister_paiements(statut: str | None = None, q: str | None = None, agence_id: int | None = None, du: dt.date | None = None, au: dt.date | None = None,
                     user: User = Depends(require("paiement-mobile:read"))):
    ag = agence_filter(user, agence_id)
    with tx() as cur:
        cur.execute("SELECT expirer_paiements_mobile()")
        return all_rows(
            cur,
            "SELECT * FROM v_paiement_mobile WHERE (%s::int IS NULL OR agence_id = %s) AND (%s::text IS NULL OR statut = %s) "
            "AND (%s::text IS NULL OR reference ILIKE '%%' || %s || '%%' OR client ILIKE '%%' || %s || '%%' OR client_numero ILIKE '%%' || %s || '%%' OR cycle ILIKE '%%' || %s || '%%' OR telephone ILIKE '%%' || %s || '%%') "
            "AND (%s::date IS NULL OR cree_le::date >= %s) AND (%s::date IS NULL OR cree_le::date <= %s) ORDER BY id DESC LIMIT 300",
            (ag, ag, statut or None, statut or None, q or None, q or None, q or None, q or None, q or None, q or None, du, du, au, au),
        )


class RemboursementIn(BaseModel):
    reference_remboursement: str = Field(min_length=3, max_length=80)


@admin_router.post("/paiements-mobile/{paiement_id}/rembourser")
def rembourser_paiement(paiement_id: int, body: RemboursementIn, user: User = Depends(require("paiement-mobile:rembourser"))):
    with tx(user.login) as cur:
        p = one_row(cur, "SELECT agence_id FROM paiement_mobile WHERE id = %s", (paiement_id,))
        if p is None or not user.peut_agence(p["agence_id"]):
            raise HTTPException(status_code=404, detail="Introuvable")
        cur.execute("UPDATE paiement_mobile SET statut = 'rembourse', motif = COALESCE(motif, '') || ' | Remboursé par ' || %s || ' (réf. ' || %s || ')' WHERE id = %s AND statut = 'a_rembourser'",
                    (user.login, body.reference_remboursement, paiement_id))
        if cur.rowcount == 0:
            raise HTTPException(status_code=422, detail="Seul un paiement « à rembourser » se rembourse")
        return one_row(cur, "SELECT * FROM v_paiement_mobile WHERE id = %s", (paiement_id,))


@admin_router.post("/mobile-money/webhook/{operateur}")
async def webhook_operateur(operateur: str, request: Request, x_signature: str | None = Header(default=None)):
    """Notification de l'opérateur : {reference, issue: succes|echec, reference_operateur, motif}. Signature HMAC-SHA256 du corps brut."""
    corps = await request.body()
    if not mobilemoney.signature_valide(corps, x_signature):
        raise HTTPException(status_code=401, detail="Signature invalide")
    try:
        data = json.loads(corps)
        reference, issue = str(data["reference"]), data["issue"]
    except (ValueError, KeyError, TypeError):
        raise HTTPException(status_code=422, detail="Notification mal formée")
    if issue not in ("succes", "echec"):
        raise HTTPException(status_code=422, detail="Issue inconnue")
    with tx("webhook:" + operateur[:12]) as cur:
        p = one_row(cur, "SELECT id FROM paiement_mobile WHERE reference = %s AND operateur = %s", (reference, operateur.upper()))
        if p is None:
            raise HTTPException(status_code=404, detail="Paiement inconnu")
        if issue == "succes":
            r = one_row(cur, "SELECT confirmer_paiement_mobile(%s, %s) AS s", (p["id"], str(data.get("reference_operateur") or "")[:80] or None))
        else:
            r = one_row(cur, "SELECT echouer_paiement_mobile(%s, %s) AS s", (p["id"], str(data.get("motif") or "Refusé par l'opérateur")[:200]))
        return {"statut": r["s"]}


@admin_router.get("/demandes-retrait-client")
def lister_demandes_retrait(statut: str | None = None, agence_id: int | None = None, user: User = Depends(require("collecte:read"))):
    ag = agence_filter(user, agence_id)
    with tx() as cur:
        return all_rows(cur, "SELECT * FROM v_demande_retrait_client WHERE (%s::int IS NULL OR agence_id = %s) AND (%s::text IS NULL OR statut = %s) "
                             "ORDER BY (statut = 'en_attente') DESC, id DESC LIMIT 200", (ag, ag, statut or None, statut or None))


class DecisionRetraitIn(BaseModel):
    accepte: bool
    commentaire: str | None = Field(default=None, max_length=300)
    date: dt.date | None = None


@admin_router.post("/demandes-retrait-client/{demande_id}/decider")
def decider_demande_retrait(demande_id: int, body: DecisionRetraitIn, user: User = Depends(require("demande-retrait:decider"))):
    with tx(user.login) as cur:
        d = one_row(cur, "SELECT cycle_id, statut FROM demande_retrait_client WHERE id = %s", (demande_id,))
        if d is None:
            raise HTTPException(status_code=404, detail="Introuvable")
        verifier_agence(cur, user, "cycle", d["cycle_id"])
        if d["statut"] != "en_attente":
            raise HTTPException(status_code=422, detail=f"Cette demande est déjà {d['statut']}")
        if body.accepte:
            rid = one_row(cur, "SELECT demander_retrait_cycle(%s, 'retrait_client', COALESCE(%s, current_date)) AS id", (d["cycle_id"], body.date))["id"]
            cur.execute("UPDATE demande_retrait_client SET statut = 'acceptee', decide_par = %s, commentaire = %s, retrait_id = %s WHERE id = %s", (user.id, body.commentaire, rid, demande_id))
        else:
            cur.execute("UPDATE demande_retrait_client SET statut = 'refusee', decide_par = %s, commentaire = %s WHERE id = %s", (user.id, body.commentaire, demande_id))
        return one_row(cur, "SELECT * FROM v_demande_retrait_client WHERE id = %s", (demande_id,))
