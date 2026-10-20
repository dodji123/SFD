"""Caisse : caisses, sessions journalières (ouverture, opérations, fermeture avec écart)."""
import datetime as dt
from typing import Literal

from fastapi import APIRouter, Depends, HTTPException
from pydantic import BaseModel, Field

from ..auth import User, agence_filter, agence_scope, require, verifier_agence
from ..db import all_rows, one_row, tx

router = APIRouter(prefix="/api", tags=["caisse"])

SESSION = (
    "SELECT s.id, k.agence_id, s.caisse_id, k.code AS caisse, s.date_session, s.statut, s.solde_ouverture, "
    "       v.encaissements, v.decaissements, v.solde_theorique, s.solde_compte, s.ecart_fermeture, s.ecart_ouverture, s.ferme_le "
    "FROM session_caisse s JOIN caisse k ON k.id = s.caisse_id JOIN v_session_caisse_solde v ON v.session_id = s.id "
)


def verifier_session(cur, user: User, session_id: int) -> int:
    """Retourne l'agence de la session, ou 404 si elle n'existe pas ou est d'une autre agence."""
    r = one_row(cur, "SELECT k.agence_id FROM session_caisse s JOIN caisse k ON k.id = s.caisse_id WHERE s.id = %s", (session_id,))
    if r is None or not user.peut_agence(r["agence_id"]):
        raise HTTPException(status_code=404, detail="Introuvable")
    return r["agence_id"]


class CaisseIn(BaseModel):
    agence_id: int | None = None
    code: str = Field(min_length=1, max_length=10)
    type: Literal["principale", "guichet", "coffre"] = "principale"
    libelle: str | None = None
    responsable_id: int | None = None
    plafond: int | None = Field(default=None, ge=0)     # au-delà : à reverser en banque ou au coffre


class CaissePatch(BaseModel):
    libelle: str | None = None
    responsable_id: int | None = None
    plafond: int | None = Field(default=None, ge=0)
    actif: bool | None = None


CAISSE = ("SELECT k.*, u.nom AS responsable FROM caisse k LEFT JOIN utilisateur u ON u.id = k.responsable_id ")


def _responsable_ok(cur, user: User, responsable_id: int | None, agence_id: int) -> None:
    if responsable_id is None:
        return
    r = one_row(cur, "SELECT agence_id, actif FROM utilisateur WHERE id = %s", (responsable_id,))
    if r is None or not r["actif"] or (r["agence_id"] is not None and r["agence_id"] != agence_id):
        raise HTTPException(status_code=422, detail="Responsable inconnu, inactif ou d'une autre agence")


@router.get("/caisses")
def lister_caisses(agence_id: int | None = None, user: User = Depends(require("caisse:read"))):
    ag = agence_filter(user, agence_id)
    with tx() as cur:
        return all_rows(cur, CAISSE + "WHERE (%s::int IS NULL OR k.agence_id = %s) ORDER BY k.agence_id, k.code", (ag, ag))


@router.post("/caisses", status_code=201)
def creer_caisse(body: CaisseIn, user: User = Depends(require("caisse:write"))):
    ag = agence_scope(user, body.agence_id)
    with tx(user.login) as cur:
        _responsable_ok(cur, user, body.responsable_id, ag)
        return one_row(cur, "INSERT INTO caisse(agence_id, code, type, libelle, responsable_id, plafond) VALUES (%s, %s, %s, %s, %s, %s) RETURNING *",
                       (ag, body.code, body.type, body.libelle, body.responsable_id, body.plafond))


@router.patch("/caisses/{caisse_id}")
def modifier_caisse(caisse_id: int, body: CaissePatch, user: User = Depends(require("tresorerie:write"))):
    champs = body.model_dump(exclude_unset=True)
    if not champs:
        raise HTTPException(status_code=422, detail="Aucune modification")
    with tx(user.login) as cur:
        ag = verifier_agence(cur, user, "caisse", caisse_id)
        if champs.get("actif") is False and one_row(cur, "SELECT 1 AS x FROM session_caisse WHERE caisse_id = %s AND statut = 'ouverte'", (caisse_id,)):
            raise HTTPException(status_code=422, detail="Impossible de désactiver une caisse dont la session est ouverte")
        if "responsable_id" in champs:
            _responsable_ok(cur, user, champs["responsable_id"], ag)
        sets = ", ".join(f"{c} = %s" for c in champs)
        return one_row(cur, f"UPDATE caisse SET {sets} WHERE id = %s RETURNING *", (*champs.values(), caisse_id))


class OuvertureIn(BaseModel):
    date_session: dt.date
    solde_ouverture: int = Field(ge=0)
    billetage: dict | None = None
    accepter_ecart: bool = False     # accepter un solde d'ouverture différent du solde compté la veille (l'écart est tracé)


@router.post("/caisses/{caisse_id}/sessions", status_code=201)
def ouvrir_session(caisse_id: int, body: OuvertureIn, user: User = Depends(require("caisse:write"))):
    """Une seule session ouverte par caisse ; le solde d'ouverture doit égaler le solde compté à la fermeture précédente."""
    import json
    with tx(user.login) as cur:
        verifier_agence(cur, user, "caisse", caisse_id)
        sid = one_row(
            cur, "SELECT ouvrir_session_caisse(%s, %s, %s, %s::jsonb, %s, %s) AS id",
            (caisse_id, body.date_session, body.solde_ouverture, json.dumps(body.billetage) if body.billetage else None, user.id, body.accepter_ecart),
        )["id"]
        return one_row(cur, SESSION + "WHERE s.id = %s", (sid,))


@router.get("/sessions")
def lister_sessions(agence_id: int | None = None, statut: Literal["ouverte", "fermee"] | None = None,
                    date: dt.date | None = None, user: User = Depends(require("caisse:read"))):
    ag = agence_filter(user, agence_id)
    with tx() as cur:
        return all_rows(
            cur,
            SESSION + "WHERE (%s::int IS NULL OR k.agence_id = %s) AND (%s::text IS NULL OR s.statut = %s) "
            "AND (%s::date IS NULL OR s.date_session = %s) ORDER BY s.date_session DESC, s.id DESC LIMIT 200",
            (ag, ag, statut, statut, date, date),
        )


@router.get("/sessions/{session_id}")
def detail_session(session_id: int, user: User = Depends(require("caisse:read"))):
    with tx() as cur:
        verifier_session(cur, user, session_id)
        s = one_row(cur, SESSION + "WHERE s.id = %s", (session_id,))
        s["operations"] = all_rows(
            cur, "SELECT id, type, motif, montant, date_operation, reference_table, reference_id, libelle "
                 "FROM operation_caisse WHERE session_id = %s ORDER BY id", (session_id,))
        return s


class OperationIn(BaseModel):
    type: Literal["encaissement", "decaissement"]
    motif: str = Field(min_length=1, max_length=30)
    montant: int = Field(gt=0)
    date_operation: dt.date | None = None
    libelle: str | None = None


@router.post("/sessions/{session_id}/operations", status_code=201)
def operation(session_id: int, body: OperationIn, user: User = Depends(require("caisse:write"))):
    with tx(user.login) as cur:
        verifier_session(cur, user, session_id)
        cur.execute("SELECT caisse_operation(%s, %s, %s, %s, COALESCE(%s, current_date), NULL, NULL, %s)",
                    (session_id, body.type, body.motif, body.montant, body.date_operation, body.libelle))
        return one_row(cur, SESSION + "WHERE s.id = %s", (session_id,))


class FermetureIn(BaseModel):
    solde_compte: int = Field(ge=0)
    billetage: dict | None = None


@router.post("/sessions/{session_id}/fermer")
def fermer(session_id: int, body: FermetureIn, user: User = Depends(require("caisse:write"))):
    import json
    with tx(user.login) as cur:
        verifier_session(cur, user, session_id)
        ecart = one_row(cur, "SELECT fermer_session_caisse(%s, %s, %s::jsonb, %s) AS ecart",
                        (session_id, body.solde_compte, json.dumps(body.billetage) if body.billetage else None, user.id))["ecart"]
        s = one_row(cur, SESSION + "WHERE s.id = %s", (session_id,))
    return {**s, "ecart": ecart}
