"""Collecte mobile : synchronisation par lot des saisies faites hors ligne.

Chaque saisie porte une clé d'opération générée par le téléphone. L'API la mémorise (mf.operation_mobile) dans la
même transaction que la ligne de collecte : renvoyer un lot déjà reçu (réseau coupé avant l'accusé, double envoi)
ne crée aucune seconde ligne. Chaque opération a sa propre transaction : un refus n'empêche pas les autres.
"""
import datetime as dt
from typing import Literal

import psycopg2
from fastapi import APIRouter, Depends, HTTPException
from pydantic import BaseModel, Field

from ..auth import User, require, verifier_agence
from ..db import one_row, tx
from ..errors import message_pg
from .collecte import _verifier_reste

router = APIRouter(prefix="/api", tags=["collecte-mobile"])


class OperationIn(BaseModel):
    cle: str = Field(min_length=8, max_length=64, pattern=r"^[A-Za-z0-9_-]+$")
    cycle_id: int
    date_collecte: dt.date
    montant_collecte: int                 # contrôlé opération par opération (refus motivé plutôt que lot rejeté)
    agent_id: int | None = None           # ignoré pour un agent/une collectrice : c'est leur propre rattachement


class SyncIn(BaseModel):
    operations: list[OperationIn] = Field(min_length=1, max_length=200)


class ResultatOperation(BaseModel):
    cle: str
    statut: Literal["appliquee", "doublon", "refusee"]
    ligne_id: int | None = None
    code: str | None = None
    motif: str | None = None


class SyncOut(BaseModel):
    date_serveur: dt.date
    resultats: list[ResultatOperation]


class Refus(Exception):
    def __init__(self, code: str, motif: str):
        super().__init__(motif)
        self.code, self.motif = code, motif


def _code_depuis_message(msg: str) -> str:
    """Rattache un message du schéma (RAISE EXCEPTION) à un code stable pour l'écran des refus."""
    m = msg.lower()
    if "clos" in m and "saisie refusée" in m:
        return "cycle_clos"
    if "après la fin du cycle" in m:
        return "hors_delai"
    if "antérieure au début" in m:
        return "avant_debut"
    if "au-delà du livret" in m:
        return "livret_plein"
    return "autre"


def _agent_de(cur, user: User, demande: int | None) -> int:
    if user.role == "agent":
        agent = user.agent_id
    elif user.role == "collectrice":
        agent = user.agent_id
        if agent is None and user.collectrice_id is not None:
            r = one_row(cur, "SELECT agent_id FROM collectrice WHERE id = %s", (user.collectrice_id,))
            agent = r["agent_id"] if r else None
    else:
        agent = demande
    if agent is None:
        raise Refus("droit_agence", "Votre compte n'est lié à aucun agent de collecte")
    if demande is not None and user.role in ("agent", "collectrice") and demande != agent:
        raise Refus("droit_agence", "Un agent ne saisit que ses propres collectes")
    return agent


def _doublon(cle: str, user: User, deja: dict) -> ResultatOperation:
    if deja["utilisateur_id"] != user.id:
        raise Refus("cle_conflit", "Cette clé d'opération appartient à un autre utilisateur")
    return ResultatOperation(cle=cle, statut="doublon", ligne_id=deja["ligne_id"])


def _appliquer(user: User, op: OperationIn) -> ResultatOperation:
    with tx(user.login) as cur:
        deja = one_row(cur, "SELECT utilisateur_id, cycle_id, ligne_id FROM operation_mobile WHERE cle = %s", (op.cle,))
        if deja is not None:
            return _doublon(op.cle, user, deja)
        try:
            ag = verifier_agence(cur, user, "cycle", op.cycle_id)
        except HTTPException:
            raise Refus("droit_agence", "Cycle introuvable ou hors de votre agence") from None
        if op.montant_collecte <= 0:
            raise Refus("montant_invalide", "Le montant doit être positif")
        if op.date_collecte > dt.date.today():
            raise Refus("date_future", "La date de collecte ne peut pas être dans le futur")
        agent = _agent_de(cur, user, op.agent_id)
        if one_row(cur, "SELECT 1 AS x FROM agent WHERE id = %s AND agence_id = %s", (agent, ag)) is None:
            raise Refus("droit_agence", "Agent introuvable ou hors de l'agence du cycle")
        # la clé est posée avant la ligne : deux envois simultanés de la même clé s'attendent sur l'index unique
        pris = one_row(cur, "INSERT INTO operation_mobile(cle, utilisateur_id, cycle_id) VALUES (%s, %s, %s) "
                            "ON CONFLICT (cle) DO NOTHING RETURNING cle", (op.cle, user.id, op.cycle_id))
        if pris is None:
            deja = one_row(cur, "SELECT utilisateur_id, cycle_id, ligne_id FROM operation_mobile WHERE cle = %s", (op.cle,))
            return _doublon(op.cle, user, deja)
        c = one_row(cur, "SELECT c.type_cycle, c.mise_courante, s.reste_a_collecter FROM cycle c "
                         "JOIN v_cycle_situation s ON s.cycle_id = c.id WHERE c.id = %s", (op.cycle_id,))
        if c["type_cycle"] != 3 and op.montant_collecte % int(c["mise_courante"]) != 0:
            raise Refus("montant_invalide", f"Le montant doit être un multiple de la mise ({int(c['mise_courante'])} F)")
        try:
            _verifier_reste(c, op.montant_collecte, 0)
        except HTTPException as e:
            raise Refus("depasse_reste", str(e.detail)) from None
        idx = one_row(cur, "SELECT COALESCE(max((page - 1) * 31 + no_ligne), 0) AS m FROM ligne_collecte WHERE cycle_id = %s", (op.cycle_id,))["m"] + 1
        ligne = one_row(cur, "INSERT INTO ligne_collecte(cycle_id, page, no_ligne, date_collecte, agent_id, montant_collecte) "
                             "VALUES (%s, %s, %s, %s, %s, %s) RETURNING id",
                        (op.cycle_id, (idx - 1) // 31 + 1, (idx - 1) % 31 + 1, op.date_collecte, agent, op.montant_collecte))
        cur.execute("UPDATE operation_mobile SET ligne_id = %s WHERE cle = %s", (ligne["id"], op.cle))
        return ResultatOperation(cle=op.cle, statut="appliquee", ligne_id=ligne["id"])


@router.post("/collecte/sync")
def synchroniser(body: SyncIn, user: User = Depends(require("collecte:write"))) -> SyncOut:
    """Applique les saisies reçues du téléphone, dans l'ordre. Réponse : un résultat par opération
    (`appliquee`, `doublon` = déjà reçue, `refusee` avec `code` et `motif`). Seule une opération `refusee` est à corriger."""
    resultats: list[ResultatOperation] = []
    for op in body.operations:
        try:
            resultats.append(_appliquer(user, op))
        except Refus as r:
            resultats.append(ResultatOperation(cle=op.cle, statut="refusee", code=r.code, motif=r.motif))
        except psycopg2.Error as e:       # règle métier du schéma : message de la base, en français
            if e.pgcode not in ("P0001", "23514", "23502", "22003"):
                raise
            msg = message_pg(e)
            resultats.append(ResultatOperation(cle=op.cle, statut="refusee", code=_code_depuis_message(msg), motif=msg))
    return SyncOut(date_serveur=dt.date.today(), resultats=resultats)
