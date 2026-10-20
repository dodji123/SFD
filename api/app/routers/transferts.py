"""Transferts de clients : entre zones (même agence) et entre agences, avec historique."""
import datetime as dt

from fastapi import APIRouter, Depends, HTTPException, Query
from pydantic import BaseModel

from ..auth import User, agence_filter, require, verifier_agence
from ..db import all_rows, one_row, tx

router = APIRouter(prefix="/api", tags=["transferts-clients"])

JOURNAL = (
    "SELECT t.id, t.client_id, cl.nom AS client, t.type, t.date_effet, t.motif, t.ancien_numero, t.nouveau_numero, "
    "       t.solde_epargne, t.comptes, t.cree_le, u.login AS utilisateur, "
    "       a1.code AS agence_source, a2.code AS agence_dest, z1.code AS zone_source, z2.code AS zone_dest "
    "FROM client_transfert t JOIN client cl ON cl.id = t.client_id "
    "JOIN agence a1 ON a1.id = t.agence_source_id JOIN agence a2 ON a2.id = t.agence_dest_id "
    "LEFT JOIN zone z1 ON z1.id = t.zone_source_id LEFT JOIN zone z2 ON z2.id = t.zone_dest_id "
    "LEFT JOIN utilisateur u ON u.id = t.utilisateur_id "
)


class TransfertZoneIn(BaseModel):
    zone_id: int
    date: dt.date | None = None
    motif: str | None = None


class TransfertAgenceIn(BaseModel):
    agence_id: int
    zone_id: int | None = None
    date: dt.date | None = None
    motif: str | None = None


@router.post("/clients/{client_id}/transfert-zone", status_code=201)
def transfert_zone(client_id: int, body: TransfertZoneIn, user: User = Depends(require("clients:transfer-zone"))):
    """Change la zone du client (même agence). La zone qui compte pour une opération est celle de sa date."""
    with tx(user.login) as cur:
        verifier_agence(cur, user, "client", client_id)
        tid = one_row(cur, "SELECT transferer_client_zone(%s, %s, COALESCE(%s, current_date), %s, %s) AS id",
                      (client_id, body.zone_id, body.date, body.motif, user.id))["id"]
        return one_row(cur, JOURNAL + "WHERE t.id = %s", (tid,))


@router.post("/clients/{client_id}/transfert-agence", status_code=201)
def transfert_agence(client_id: int, body: TransfertAgenceIn, user: User = Depends(require("clients:transfer-agence"))):
    """Déplace le client et ses comptes d'épargne vers une autre agence (refusé si une opération est en cours).
    Aucune écriture comptable inter-agences n'est passée : le solde d'épargne déplacé figure dans la réponse."""
    with tx(user.login) as cur:
        verifier_agence(cur, user, "client", client_id)
        tid = one_row(cur, "SELECT transferer_client_agence(%s, %s::smallint, %s, COALESCE(%s, current_date), %s, %s) AS id",
                      (client_id, body.agence_id, body.zone_id, body.date, body.motif, user.id))["id"]
        return one_row(cur, JOURNAL + "WHERE t.id = %s", (tid,))


@router.get("/clients/{client_id}/transferts")
def transferts_du_client(client_id: int, user: User = Depends(require("ref:read"))):
    with tx() as cur:
        # un client déjà parti reste consultable par son agence d'origine
        r = one_row(cur, "SELECT agence_id FROM client WHERE id = %s", (client_id,))
        if r is None:
            raise HTTPException(status_code=404, detail="Introuvable")
        if not user.peut_agence(r["agence_id"]) and not one_row(
                cur, "SELECT 1 AS x FROM client_transfert WHERE client_id = %s AND agence_source_id = ANY(%s) LIMIT 1", (client_id, user.agences)):
            raise HTTPException(status_code=404, detail="Introuvable")
        return all_rows(cur, JOURNAL + "WHERE t.client_id = %s ORDER BY t.date_effet DESC, t.id DESC", (client_id,))


@router.get("/transferts-clients")
def lister_transferts(type: str | None = Query(None, pattern="^(zone|agence)$"), agence_id: int | None = None,
                      limit: int = Query(100, ge=1, le=500), user: User = Depends(require("ref:read"))):
    """Transferts dont l'agence est la source ou la destination."""
    ag = agence_filter(user, agence_id)
    with tx() as cur:
        return all_rows(
            cur,
            JOURNAL + "WHERE (%s::int IS NULL OR t.agence_source_id = %s OR t.agence_dest_id = %s) AND (%s::text IS NULL OR t.type = %s) "
                      "ORDER BY t.date_effet DESC, t.id DESC LIMIT %s",
            (ag, ag, ag, type, type, limit))
