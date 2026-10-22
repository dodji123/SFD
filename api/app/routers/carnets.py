"""Carnets (livrets papier) : stock par agence et par produit, remise aux agents, attribution aux cycles (module 48).
Chaque produit a son livret ; les règles (produit/agence du cycle, un carnet attribué par cycle, états, journal) sont dans le schéma."""
from typing import Literal

from fastapi import APIRouter, Depends, HTTPException
from pydantic import BaseModel, Field

from ..auth import User, agence_filter, agence_scope, require, verifier_agence
from ..db import all_rows, one_row, tx

router = APIRouter(prefix="/api", tags=["carnets"])


def _carnet(cur, user: User, carnet_id: int) -> dict:
    c = one_row(cur, "SELECT * FROM v_carnet WHERE id = %s", (carnet_id,))
    if c is None or not user.peut_agence(c["agence_id"]):
        raise HTTPException(status_code=404, detail="Introuvable")
    return c


class LotIn(BaseModel):
    produit_id: int
    quantite: int = Field(ge=1, le=5000)
    reference: str | None = Field(default=None, max_length=120)
    agence_id: int | None = None


@router.post("/carnets/lots", status_code=201)
def recevoir_lot(body: LotIn, user: User = Depends(require("carnet:write"))):
    ag = agence_scope(user, body.agence_id)
    with tx(user.login) as cur:
        lot = one_row(cur, "SELECT mf.recevoir_lot_carnets(%s::smallint, %s, %s, %s) AS id", (ag, body.produit_id, body.quantite, body.reference))
        return one_row(cur, "SELECT l.*, p.code AS produit, (SELECT numero FROM carnet WHERE lot_id = l.id ORDER BY ordre LIMIT 1) AS premier_numero, "
                            "(SELECT numero FROM carnet WHERE lot_id = l.id ORDER BY ordre DESC LIMIT 1) AS dernier_numero "
                            "FROM carnet_lot l JOIN produit_epargne p ON p.id = l.produit_id WHERE l.id = %s", (lot["id"],))


@router.get("/carnets/stock")
def stock(agence_id: int | None = None, produit_id: int | None = None, user: User = Depends(require("carnet:read"))):
    ag = agence_filter(user, agence_id)
    with tx() as cur:
        return all_rows(cur, "SELECT * FROM v_stock_carnets WHERE (%s::int IS NULL OR agence_id = %s) AND (%s::int IS NULL OR produit_id = %s) ORDER BY agence, produit",
                        (ag, ag, produit_id, produit_id))


@router.get("/carnets")
def lister(statut: str | None = None, produit_id: int | None = None, agent_id: int | None = None, agence_id: int | None = None,
           q: str | None = None, limit: int = 200, user: User = Depends(require("carnet:read"))):
    ag = agence_filter(user, agence_id)
    with tx() as cur:
        return all_rows(
            cur,
            "SELECT * FROM v_carnet WHERE (%s::int IS NULL OR agence_id = %s) AND (%s::text IS NULL OR statut = %s) AND (%s::int IS NULL OR produit_id = %s) "
            "AND (%s::int IS NULL OR agent_id = %s) "
            "AND (%s::text IS NULL OR numero ILIKE '%%' || %s || '%%' OR client ILIKE '%%' || %s || '%%' OR client_numero ILIKE '%%' || %s || '%%' OR cycle ILIKE '%%' || %s || '%%') "
            "ORDER BY agence_id, produit_id, ordre LIMIT %s",
            (ag, ag, statut or None, statut or None, produit_id, produit_id, agent_id, agent_id, q or None, q or None, q or None, q or None, q or None, min(max(limit, 1), 500)),
        )


@router.get("/carnets/{carnet_id}")
def detail(carnet_id: int, user: User = Depends(require("carnet:read"))):
    with tx() as cur:
        c = _carnet(cur, user, carnet_id)
        c["historique"] = all_rows(cur, "SELECT m.*, a.matricule AS agent, cy.numero AS cycle FROM carnet_mouvement m LEFT JOIN agent a ON a.id = m.agent_id "
                                        "LEFT JOIN cycle cy ON cy.id = m.cycle_id WHERE m.carnet_id = %s ORDER BY m.id", (carnet_id,))
        return c


@router.get("/cycles/{cycle_id}/carnets")
def carnets_du_cycle(cycle_id: int, user: User = Depends(require("carnet:read"))):
    with tx() as cur:
        verifier_agence(cur, user, "cycle", cycle_id)
        return all_rows(cur, "SELECT * FROM v_carnet WHERE cycle_id = %s ORDER BY id", (cycle_id,))


class RemiseIn(BaseModel):
    agent_id: int


@router.post("/carnets/{carnet_id}/remettre")
def remettre_a_agent(carnet_id: int, body: RemiseIn, user: User = Depends(require("carnet:write"))):
    with tx(user.login) as cur:
        _carnet(cur, user, carnet_id)
        cur.execute("UPDATE carnet SET statut = 'chez_agent', agent_id = %s WHERE id = %s AND statut = 'en_stock'", (body.agent_id, carnet_id))
        if cur.rowcount == 0:
            raise HTTPException(status_code=422, detail="Seul un carnet en stock peut être remis à un agent")
        return _carnet(cur, user, carnet_id)


@router.post("/carnets/{carnet_id}/retour")
def retour_en_stock(carnet_id: int, user: User = Depends(require("carnet:write"))):
    with tx(user.login) as cur:
        _carnet(cur, user, carnet_id)
        cur.execute("UPDATE carnet SET statut = 'en_stock', agent_id = NULL WHERE id = %s AND statut = 'chez_agent'", (carnet_id,))
        if cur.rowcount == 0:
            raise HTTPException(status_code=422, detail="Seul un carnet remis à un agent revient en stock")
        return _carnet(cur, user, carnet_id)


class AttributionIn(BaseModel):
    cycle_id: int
    remplace_id: int | None = None


@router.post("/carnets/{carnet_id}/attribuer")
def attribuer(carnet_id: int, body: AttributionIn, user: User = Depends(require("carnet:write"))):
    with tx(user.login) as cur:
        _carnet(cur, user, carnet_id)
        verifier_agence(cur, user, "cycle", body.cycle_id)
        cur.execute("UPDATE carnet SET statut = 'attribue', agent_id = NULL, cycle_id = %s, remplace_id = %s WHERE id = %s AND statut IN ('en_stock','chez_agent')",
                    (body.cycle_id, body.remplace_id, carnet_id))
        if cur.rowcount == 0:
            raise HTTPException(status_code=422, detail="Seul un carnet en stock ou chez un agent s'attribue")
        return _carnet(cur, user, carnet_id)


class DeclarationIn(BaseModel):
    statut: Literal["perdu", "abime", "annule"]
    motif: str = Field(min_length=5, max_length=300)


@router.post("/carnets/{carnet_id}/declarer")
def declarer(carnet_id: int, body: DeclarationIn, user: User = Depends(require("carnet:write"))):
    with tx(user.login) as cur:
        _carnet(cur, user, carnet_id)
        cur.execute("UPDATE carnet SET statut = %s, motif = %s WHERE id = %s", (body.statut, body.motif, carnet_id))
        return _carnet(cur, user, carnet_id)


@router.post("/carnets/{carnet_id}/terminer")
def terminer(carnet_id: int, user: User = Depends(require("carnet:write"))):
    with tx(user.login) as cur:
        _carnet(cur, user, carnet_id)
        cur.execute("UPDATE carnet SET statut = 'termine' WHERE id = %s AND statut = 'attribue'", (carnet_id,))
        if cur.rowcount == 0:
            raise HTTPException(status_code=422, detail="Seul un carnet attribué se termine")
        return _carnet(cur, user, carnet_id)
