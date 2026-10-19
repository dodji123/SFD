"""Adhésion des membres et parts sociales (module 24) ; liaison cycle de tontine / compte d'épargne classique (module 25)."""
import datetime as dt

from fastapi import APIRouter, Depends, HTTPException
from pydantic import BaseModel, Field

from ..auth import User, agence_scope, require, verifier_agence
from ..db import all_rows, one_row, tx
from .collecte import SITUATION, trouver_client
from .epargne import SELECT_COMPTE

router = APIRouter(prefix="/api", tags=["adhesion"])


def _membre(cur, client_id: int, agence_id: int) -> dict:
    m = one_row(cur, "SELECT adhesion_id, numero, date_adhesion, statut, nb_parts, capital_souscrit FROM v_membre WHERE client_id = %s", (client_id,))
    p = {c: one_row(cur, "SELECT param(%s, %s::smallint) AS v", (c, agence_id))["v"]
         for c in ("part_valeur_nominale", "parts_minimum", "droit_adhesion", "adhesion_obligatoire")}
    rb = one_row(cur, "SELECT r.nb_parts, r.montant, r.date_operation FROM remboursement_part r JOIN adhesion a ON a.id = r.adhesion_id WHERE a.client_id = %s", (client_id,))
    return {"adhesion": m, "remboursement": rb, "en_regle": one_row(cur, "SELECT membre_en_regle(%s) AS b", (client_id,))["b"],
            "valeur_part": int(p.get("part_valeur_nominale", 0)), "parts_minimum": int(p.get("parts_minimum", 1)),
            "droit_adhesion": int(p.get("droit_adhesion", 0)), "obligatoire": p.get("adhesion_obligatoire") == "oui"}


@router.get("/adhesions/recherche")
def rechercher_membre(suffixe: str, agence_id: int | None = None, user: User = Depends(require("epargne:read"))):
    """Guichet d'adhésion : retrouve le client par son numéro d'ordre et donne sa situation de membre."""
    ag = agence_scope(user, agence_id)
    with tx() as cur:
        cl = trouver_client(cur, ag, suffixe)
        return {"client": cl, **_membre(cur, cl["id"], ag)}


class AdhererIn(BaseModel):
    client_id: int
    date: dt.date | None = None


@router.post("/adhesions", status_code=201)
def adherer(body: AdhererIn, user: User = Depends(require("adhesion:write"))):
    with tx(user.login) as cur:
        ag = verifier_agence(cur, user, "client", body.client_id)
        cur.execute("SELECT adherer(%s, COALESCE(%s, current_date), %s)", (body.client_id, body.date, user.id))
        return _membre(cur, body.client_id, ag)


class PartsIn(BaseModel):
    client_id: int
    nb_parts: int = Field(gt=0, le=10000)
    date: dt.date | None = None


@router.post("/adhesions/parts", status_code=201)
def souscrire(body: PartsIn, user: User = Depends(require("adhesion:write"))):
    with tx(user.login) as cur:
        ag = verifier_agence(cur, user, "client", body.client_id)
        cur.execute("SELECT souscrire_parts(%s, %s, COALESCE(%s, current_date), %s)", (body.client_id, body.nb_parts, body.date, user.id))
        return _membre(cur, body.client_id, ag)


class SortieIn(BaseModel):
    client_id: int
    date: dt.date | None = None


@router.post("/adhesions/sortie", status_code=201)
def sortir(body: SortieIn, user: User = Depends(require("collecte:admin"))):
    """Sortie d'un membre : remboursement des parts et radiation (refusée tant qu'il reste un solde, une tontine ou un crédit)."""
    with tx(user.login) as cur:
        ag = verifier_agence(cur, user, "client", body.client_id)
        cur.execute("SELECT radier_adhesion(%s, COALESCE(%s, current_date), %s)", (body.client_id, body.date, user.id))
        return _membre(cur, body.client_id, ag)


@router.get("/adhesions/jour")
def adhesions_du_jour(date: dt.date, agence_id: int | None = None, user: User = Depends(require("epargne:read"))):
    """Tableau des adhésions et souscriptions de parts d'un jour."""
    ag = agence_scope(user, agence_id)
    with tx() as cur:
        lignes = all_rows(
            cur,
            "SELECT 'adhesion' AS nature, a.id, a.cree_le, cl.numero AS client_numero, cl.nom AS client, a.numero AS reference, "
            "       a.droit_adhesion AS montant, NULL::int AS nb_parts FROM adhesion a JOIN client cl ON cl.id = a.client_id "
            "WHERE a.agence_id = %s AND a.date_adhesion = %s "
            "UNION ALL "
            "SELECT 'parts', s.id, s.cree_le, cl.numero, cl.nom, a.numero, s.montant, s.nb_parts FROM souscription_part s "
            "JOIN adhesion a ON a.id = s.adhesion_id JOIN client cl ON cl.id = a.client_id "
            "WHERE a.agence_id = %s AND s.date_souscription = %s ORDER BY cree_le DESC",
            (ag, date, ag, date),
        )
    return {"date": date, "lignes": lignes, "total": sum(l["montant"] for l in lignes)}


# ---------------------------------------------------------------- liaison tontine <-> épargne classique
@router.get("/liaisons/recherche")
def situation_client(suffixe: str, agence_id: int | None = None, user: User = Depends(require("epargne:read"))):
    """Les deux comptes du client : comptes d'épargne classique et cycles de tontine en cours, avec leur liaison."""
    ag = agence_scope(user, agence_id)
    with tx() as cur:
        cl = trouver_client(cur, ag, suffixe)
        comptes = all_rows(cur, SELECT_COMPTE + "WHERE ce.client_id = %s AND ce.statut = 'actif' ORDER BY ce.id", (cl["id"],))
        cycles = all_rows(cur, SITUATION + "WHERE s.client_id = %s AND s.statut = 'en_cours' ORDER BY s.cycle_id", (cl["id"],))
        liens = {l["cycle_id"]: l["compte_id"] for l in all_rows(cur, "SELECT cycle_id, compte_id FROM liaison_tontine_epargne WHERE client_id = %s", (cl["id"],))}
        for c in cycles:
            c["compte_lie_id"] = liens.get(c["id"])
        return {"client": cl, "comptes": comptes, "cycles": cycles}


class LiaisonIn(BaseModel):
    compte_id: int


@router.put("/liaisons/cycles/{cycle_id}")
def lier(cycle_id: int, body: LiaisonIn, user: User = Depends(require("epargne:write"))):
    with tx(user.login) as cur:
        verifier_agence(cur, user, "cycle", cycle_id)
        verifier_agence(cur, user, "compte_epargne", body.compte_id)
        cur.execute("SELECT lier_cycle_compte(%s, %s, %s)", (cycle_id, body.compte_id, user.id))
    return {"cycle_id": cycle_id, "compte_id": body.compte_id}


@router.delete("/liaisons/cycles/{cycle_id}")
def delier(cycle_id: int, user: User = Depends(require("epargne:write"))):
    with tx(user.login) as cur:
        verifier_agence(cur, user, "cycle", cycle_id)
        cur.execute("SELECT delier_cycle_compte(%s)", (cycle_id,))
    return {"ok": True}
