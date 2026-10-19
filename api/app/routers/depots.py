"""Dépôts bloqués : dépôt de garantie et dépôt à terme (module 28), et leur déblocage."""
import datetime as dt
from typing import Literal

from fastapi import APIRouter, Depends, HTTPException
from pydantic import BaseModel, Field

from ..auth import User, agence_scope, require, verifier_agence
from ..db import all_rows, one_row, tx
from .epargne import controle_adhesion
from .pieces import piece_garantie, piece_terme

router = APIRouter(prefix="/api/depots", tags=["depots"])


@router.get("/parametres")
def parametres(agence_id: int | None = None, user: User = Depends(require("epargne:read"))):
    """Taux, durée et montant minimaux des dépôts à terme, pénalité de rupture."""
    ag = agence_scope(user, agence_id)
    with tx() as cur:
        p = {c: one_row(cur, "SELECT param(%s, %s::smallint) AS v", (c, ag))["v"]
             for c in ("dat_taux_annuel", "dat_duree_min_mois", "dat_montant_min", "dat_penalite_rupture_pct")}
    return {"taux_annuel": float(p["dat_taux_annuel"] or 0), "duree_min_mois": int(p["dat_duree_min_mois"] or 1),
            "montant_min": int(p["dat_montant_min"] or 0), "penalite_rupture_pct": float(p["dat_penalite_rupture_pct"] or 100)}


# ---------------------------------------------------------------- dépôt de garantie
GARANTIE = (
    "SELECT d.id, d.numero, d.agence_id, d.client_id, cl.numero AS client_numero, cl.nom AS client, d.compte_id, ce.numero AS compte, "
    "       d.montant, d.motif, d.credit_id, cr.numero AS credit, cr.statut AS credit_statut, d.date_depot, d.statut, d.date_liberation "
    "FROM depot_garantie d JOIN client cl ON cl.id = d.client_id JOIN compte_epargne ce ON ce.id = d.compte_id "
    "LEFT JOIN credit cr ON cr.id = d.credit_id "
)


class GarantieIn(BaseModel):
    compte_id: int
    montant: int = Field(gt=0)
    motif: str | None = Field(default=None, max_length=200)
    credit_id: int | None = None
    date: dt.date | None = None


@router.post("/garanties", status_code=201)
def deposer_garantie(body: GarantieIn, user: User = Depends(require("epargne:write"))):
    with tx(user.login) as cur:
        ag = verifier_agence(cur, user, "compte_epargne", body.compte_id)
        controle_adhesion(cur, ag, body.compte_id)
        did = one_row(cur, "SELECT deposer_garantie(%s, %s, COALESCE(%s, current_date), %s, %s, %s) AS id",
                      (body.compte_id, body.montant, body.date, body.motif, body.credit_id, user.id))["id"]
        return {**one_row(cur, GARANTIE + "WHERE d.id = %s", (did,)), "piece_id": piece_garantie(cur, user, did)}


@router.get("/garanties")
def lister_garanties(statut: Literal["bloque", "libere"] | None = None, date: dt.date | None = None, agence_id: int | None = None,
                     user: User = Depends(require("epargne:read"))):
    ag = agence_scope(user, agence_id)
    with tx() as cur:
        return all_rows(cur, GARANTIE + "WHERE d.agence_id = %s AND (%s::text IS NULL OR d.statut = %s) AND (%s::date IS NULL OR d.date_depot = %s) "
                        "ORDER BY d.id DESC LIMIT 500", (ag, statut, statut, date, date))


class LiberationIn(BaseModel):
    date: dt.date | None = None


@router.post("/garanties/{depot_id}/liberer")
def liberer_garantie(depot_id: int, body: LiberationIn, user: User = Depends(require("depot:debloquer"))):
    with tx(user.login) as cur:
        verifier_agence(cur, user, "depot_garantie", depot_id)
        cur.execute("SELECT liberer_depot_garantie(%s, COALESCE(%s, current_date), %s)", (depot_id, body.date, user.id))
        return {**one_row(cur, GARANTIE + "WHERE d.id = %s", (depot_id,)), "piece_id": piece_garantie(cur, user, depot_id, True)}


# ---------------------------------------------------------------- dépôt à terme
TERME = (
    "SELECT d.id, d.numero, d.agence_id, d.client_id, cl.numero AS client_numero, cl.nom AS client, d.compte_id, ce.numero AS compte, "
    "       d.montant, d.duree_mois, d.taux_annuel, d.date_depot, d.date_echeance, d.interets_prevus, d.statut, d.date_deblocage, d.interets_verses, "
    "       (d.statut = 'en_cours' AND d.date_echeance <= current_date) AS echu "
    "FROM depot_terme d JOIN client cl ON cl.id = d.client_id JOIN compte_epargne ce ON ce.id = d.compte_id "
)


class TermeIn(BaseModel):
    compte_id: int
    montant: int = Field(gt=0)
    duree_mois: int = Field(ge=1, le=120)
    taux_annuel: float | None = Field(default=None, ge=0, le=1)     # fraction (0.04 = 4 %) ; vide : taux paramétré
    date: dt.date | None = None


@router.post("/terme", status_code=201)
def placer_terme(body: TermeIn, user: User = Depends(require("epargne:write"))):
    with tx(user.login) as cur:
        ag = verifier_agence(cur, user, "compte_epargne", body.compte_id)
        controle_adhesion(cur, ag, body.compte_id)
        did = one_row(cur, "SELECT placer_depot_terme(%s, %s, %s, COALESCE(%s, current_date), %s, %s) AS id",
                      (body.compte_id, body.montant, body.duree_mois, body.date, body.taux_annuel, user.id))["id"]
        return {**one_row(cur, TERME + "WHERE d.id = %s", (did,)), "piece_id": piece_terme(cur, user, did)}


@router.get("/terme")
def lister_termes(statut: Literal["en_cours", "verse", "rompu"] | None = None, date: dt.date | None = None, agence_id: int | None = None,
                  user: User = Depends(require("epargne:read"))):
    ag = agence_scope(user, agence_id)
    with tx() as cur:
        return all_rows(cur, TERME + "WHERE d.agence_id = %s AND (%s::text IS NULL OR d.statut = %s) AND (%s::date IS NULL OR d.date_depot = %s) "
                        "ORDER BY d.date_echeance, d.id DESC LIMIT 500", (ag, statut, statut, date, date))


@router.post("/terme/{depot_id}/debloquer")
def debloquer_terme(depot_id: int, body: LiberationIn, user: User = Depends(require("depot:debloquer"))):
    """Déblocage à l'échéance : capital et intérêts rendus au compte."""
    with tx(user.login) as cur:
        verifier_agence(cur, user, "depot_terme", depot_id)
        cur.execute("SELECT debloquer_depot_terme(%s, COALESCE(%s, current_date), %s)", (depot_id, body.date, user.id))
        return {**one_row(cur, TERME + "WHERE d.id = %s", (depot_id,)), "piece_id": piece_terme(cur, user, depot_id, True)}


@router.post("/terme/{depot_id}/rompre")
def rompre_terme(depot_id: int, body: LiberationIn, user: User = Depends(require("depot:debloquer"))):
    """Rupture anticipée : capital rendu, intérêts courus au prorata diminués de la pénalité."""
    with tx(user.login) as cur:
        verifier_agence(cur, user, "depot_terme", depot_id)
        cur.execute("SELECT rompre_depot_terme(%s, COALESCE(%s, current_date), %s)", (depot_id, body.date, user.id))
        return {**one_row(cur, TERME + "WHERE d.id = %s", (depot_id,)), "piece_id": piece_terme(cur, user, depot_id, True)}


@router.get("/deblocages")
def a_debloquer(agence_id: int | None = None, user: User = Depends(require("epargne:read"))):
    """Tout ce qui attend un déblocage : garanties bloquées, dépôts à terme en cours, crédits approuvés."""
    ag = agence_scope(user, agence_id)
    with tx() as cur:
        garanties = all_rows(cur, GARANTIE + "WHERE d.agence_id = %s AND d.statut = 'bloque' ORDER BY d.date_depot, d.id", (ag,))
        termes = all_rows(cur, TERME + "WHERE d.agence_id = %s AND d.statut = 'en_cours' ORDER BY d.date_echeance, d.id", (ag,))
        credits = all_rows(cur, "SELECT dc.id, dc.numero, dc.client_id, cl.numero AS client_numero, cl.nom AS client, dc.montant, dc.cree_le "
                                "FROM demande_credit dc JOIN client cl ON cl.id = dc.client_id WHERE dc.agence_id = %s AND dc.statut = 'approuvee' ORDER BY dc.id", (ag,))
    return {"garanties": garanties, "termes": termes, "credits": credits}
