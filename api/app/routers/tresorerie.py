"""Trésorerie : état des caisses, transferts entre caisses, comptes bancaires, position et prévision."""
import datetime as dt
from typing import Literal

from fastapi import APIRouter, Depends, HTTPException, Query
from pydantic import BaseModel, Field

from ..auth import User, agence_filter, agence_scope, require, verifier_agence
from ..db import all_rows, one_row, tx
from .caisse import verifier_session

router = APIRouter(prefix="/api", tags=["tresorerie"])


# ---------------------------------------------------------------- état des caisses
@router.get("/caisses/etat")
def etat_caisses(date: dt.date, agence_id: int | None = None, user: User = Depends(require("tresorerie:read"))):
    """Chaque caisse active : non ouverte / ouverte / fermée à cette date, solde, dépassement du plafond."""
    ag = agence_scope(user, agence_id)
    with tx() as cur:
        return all_rows(cur, "SELECT * FROM etat_caisses(%s::smallint, %s)", (ag, date))


# ---------------------------------------------------------------- transferts entre caisses
TRANSFERT = (
    "SELECT t.*, k1.code AS caisse_source, k2.code AS caisse_dest FROM transfert_caisse t "
    "JOIN session_caisse s1 ON s1.id = t.session_source JOIN caisse k1 ON k1.id = s1.caisse_id "
    "JOIN session_caisse s2 ON s2.id = t.session_dest JOIN caisse k2 ON k2.id = s2.caisse_id "
)


class TransfertIn(BaseModel):
    session_source: int
    session_dest: int
    montant: int = Field(gt=0)
    date: dt.date | None = None
    motif: str | None = None


@router.post("/sessions/transfert", status_code=201)
def transferer(body: TransfertIn, user: User = Depends(require("caisse:write"))):
    """Approvisionnement d'un guichet depuis le coffre, reversement, etc. Les deux sessions doivent être ouvertes."""
    with tx(user.login) as cur:
        a1 = verifier_session(cur, user, body.session_source)
        a2 = verifier_session(cur, user, body.session_dest)
        if a1 != a2:
            raise HTTPException(status_code=422, detail="Un transfert de caisse reste dans la même agence")
        tid = one_row(cur, "SELECT transferer_entre_caisses(%s, %s, %s, COALESCE(%s, current_date), %s, %s) AS id",
                      (body.session_source, body.session_dest, body.montant, body.date, body.motif, user.id))["id"]
        return one_row(cur, TRANSFERT + "WHERE t.id = %s", (tid,))


@router.get("/transferts-caisse")
def lister_transferts(du: dt.date | None = None, au: dt.date | None = None, agence_id: int | None = None,
                      user: User = Depends(require("caisse:read"))):
    ag = agence_filter(user, agence_id)
    with tx() as cur:
        return all_rows(
            cur,
            TRANSFERT + "WHERE (%s::int IS NULL OR t.agence_id = %s) AND (%s::date IS NULL OR t.date_operation >= %s) "
            "AND (%s::date IS NULL OR t.date_operation <= %s) ORDER BY t.id DESC LIMIT 300",
            (ag, ag, du, du, au, au),
        )


# ---------------------------------------------------------------- comptes bancaires
class BanqueIn(BaseModel):
    agence_id: int | None = None
    code: str = Field(min_length=1, max_length=10)
    libelle: str = Field(min_length=1)
    banque: str | None = None
    numero_compte: str | None = None


@router.get("/banques")
def lister_banques(agence_id: int | None = None, user: User = Depends(require("tresorerie:read"))):
    ag = agence_filter(user, agence_id)
    with tx() as cur:
        return all_rows(
            cur,
            "SELECT b.*, v.solde, (SELECT count(*) FROM mouvement_banque m WHERE m.compte_banque_id = b.id AND NOT m.rapproche) AS non_rapproches "
            "FROM compte_banque b JOIN v_solde_compte_banque v ON v.compte_banque_id = b.id "
            "WHERE (%s::int IS NULL OR b.agence_id = %s) ORDER BY b.agence_id, b.code", (ag, ag))


@router.post("/banques", status_code=201)
def creer_banque(body: BanqueIn, user: User = Depends(require("tresorerie:write"))):
    ag = agence_scope(user, body.agence_id)
    with tx(user.login) as cur:
        return one_row(cur, "INSERT INTO compte_banque(agence_id, code, libelle, banque, numero_compte) VALUES (%s, %s, %s, %s, %s) RETURNING *",
                       (ag, body.code, body.libelle, body.banque, body.numero_compte))


@router.get("/banques/{banque_id}/mouvements")
def mouvements_banque(banque_id: int, limit: int = Query(200, ge=1, le=1000), user: User = Depends(require("tresorerie:read"))):
    with tx() as cur:
        verifier_agence(cur, user, "compte_banque", banque_id)
        return all_rows(
            cur,
            "SELECT id, date_operation, type, montant, sens_mouvement_banque(type) AS sens, libelle, rapproche, rapproche_le "
            "FROM mouvement_banque WHERE compte_banque_id = %s ORDER BY date_operation DESC, id DESC LIMIT %s", (banque_id, limit))


class MouvementBanqueIn(BaseModel):
    type: Literal["depot_externe", "retrait_externe", "frais", "interets"]
    montant: int = Field(gt=0)
    date: dt.date | None = None
    libelle: str | None = None


@router.post("/banques/{banque_id}/mouvements", status_code=201)
def mouvement_externe(banque_id: int, body: MouvementBanqueIn, user: User = Depends(require("tresorerie:write"))):
    """Mouvements sans contrepartie de caisse : refinancement, frais bancaires, intérêts, retrait externe."""
    with tx(user.login) as cur:
        verifier_agence(cur, user, "compte_banque", banque_id)
        return one_row(
            cur,
            "INSERT INTO mouvement_banque(compte_banque_id, date_operation, type, montant, libelle, utilisateur_id) "
            "VALUES (%s, COALESCE(%s, current_date), %s, %s, %s, %s) RETURNING *",
            (banque_id, body.date, body.type, body.montant, body.libelle, user.id))


class RapprochementIn(BaseModel):
    date: dt.date | None = None
    rapproche: bool = True


@router.post("/banques/mouvements/{mouvement_id}/rapprocher")
def rapprocher(mouvement_id: int, body: RapprochementIn, user: User = Depends(require("tresorerie:write"))):
    with tx(user.login) as cur:
        m = one_row(cur, "SELECT compte_banque_id FROM mouvement_banque WHERE id = %s", (mouvement_id,))
        if m is None:
            raise HTTPException(status_code=404, detail="Introuvable")
        verifier_agence(cur, user, "compte_banque", m["compte_banque_id"])
        cur.execute("SELECT rapprocher_mouvement_banque(%s, COALESCE(%s, current_date), %s)", (mouvement_id, body.date, body.rapproche))
        return one_row(cur, "SELECT * FROM mouvement_banque WHERE id = %s", (mouvement_id,))


class OperationBanqueIn(BaseModel):
    compte_banque_id: int
    montant: int = Field(gt=0)
    date: dt.date | None = None
    libelle: str | None = None


def _op_banque(session_id: int, body: OperationBanqueIn, user: User, fn: str) -> dict:
    with tx(user.login) as cur:
        ag = verifier_session(cur, user, session_id)
        if verifier_agence(cur, user, "compte_banque", body.compte_banque_id) != ag:
            raise HTTPException(status_code=422, detail="La caisse et le compte bancaire sont d'agences différentes")
        mid = one_row(cur, f"SELECT {fn}(%s, %s, %s, COALESCE(%s, current_date), %s, %s) AS id",
                      (session_id, body.compte_banque_id, body.montant, body.date, body.libelle, user.id))["id"]
        return one_row(cur, "SELECT * FROM mouvement_banque WHERE id = %s", (mid,))


@router.post("/sessions/{session_id}/versement-banque", status_code=201)
def versement_banque(session_id: int, body: OperationBanqueIn, user: User = Depends(require("caisse:write"))):
    """La caisse reverse des espèces en banque : décaissement de caisse + entrée sur le compte bancaire."""
    return _op_banque(session_id, body, user, "versement_en_banque")


@router.post("/sessions/{session_id}/retrait-banque", status_code=201)
def retrait_banque(session_id: int, body: OperationBanqueIn, user: User = Depends(require("caisse:write"))):
    """La banque alimente la caisse : sortie bancaire (solde contrôlé) + encaissement de caisse."""
    return _op_banque(session_id, body, user, "retrait_en_banque")


# ---------------------------------------------------------------- position et prévision
@router.get("/tresorerie/position")
def position(date: dt.date, agence_id: int | None = None, user: User = Depends(require("tresorerie:read"))):
    ag = agence_scope(user, agence_id)
    with tx() as cur:
        liq = all_rows(cur, "SELECT * FROM tresorerie_liquidites(%s::smallint, %s)", (ag, date))
        ind = all_rows(cur, "SELECT rubrique, valeur FROM tresorerie_indicateurs(%s::smallint, %s)", (ag, date))
    return {"date": date, "agence_id": ag, "liquidites": liq, "indicateurs": {r["rubrique"]: r["valeur"] for r in ind}}


@router.get("/tresorerie/prevision")
def prevision(date: dt.date, jours: int = Query(30, ge=1, le=365), pas: int = Query(7, ge=1, le=90),
              agence_id: int | None = None, user: User = Depends(require("tresorerie:read"))):
    ag = agence_scope(user, agence_id)
    with tx() as cur:
        return all_rows(cur, "SELECT * FROM prevision_tresorerie(%s::smallint, %s, %s, %s)", (ag, date, jours, pas))
