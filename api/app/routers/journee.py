"""Ouverture et clôture de la journée de l'agence (module 64). Les règles (ordre des journées, sessions de caisse fermées,
collecte et épargne validées, réouverture avec motif) sont dans la base."""
import datetime as dt

from fastapi import APIRouter, Depends
from pydantic import BaseModel, Field

from ..auth import User, agence_scope, require
from ..db import all_rows, one_row, tx

router = APIRouter(prefix="/api/journee", tags=["journee"])


class JourneeIn(BaseModel):
    date: dt.date
    motif: str | None = Field(default=None, max_length=300)


@router.get("")
def etat(agence_id: int | None = None, user: User = Depends(require("caisse:read"))):
    ag = agence_scope(user, agence_id)
    with tx() as cur:
        jours = all_rows(cur, "SELECT date_journee, statut, ouverte_le, cloturee_le FROM journee_agence "
                              "WHERE agence_id = %s ORDER BY date_journee DESC LIMIT 30", (ag,))
        sessions = one_row(cur, "SELECT count(*) AS n FROM session_caisse s JOIN caisse k ON k.id = s.caisse_id "
                                "WHERE k.agence_id = %s AND s.statut = 'ouverte'", (ag,))["n"]
    return {"agence_id": ag, "jours": jours, "sessions_ouvertes": sessions}


@router.post("/ouvrir", status_code=201)
def ouvrir(body: JourneeIn, agence_id: int | None = None, user: User = Depends(require("caisse:write"))):
    ag = agence_scope(user, agence_id)
    with tx(user.login) as cur:
        cur.execute("SELECT ouvrir_journee(%s::smallint, %s, %s)", (ag, body.date, user.id))
    return {"ok": True}


@router.post("/cloturer")
def cloturer(body: JourneeIn, agence_id: int | None = None, user: User = Depends(require("caisse:write"))):
    ag = agence_scope(user, agence_id)
    with tx(user.login) as cur:
        cur.execute("SELECT cloturer_journee(%s::smallint, %s, %s)", (ag, body.date, user.id))
    return {"ok": True}


@router.post("/rouvrir")
def rouvrir(body: JourneeIn, agence_id: int | None = None, user: User = Depends(require("collecte:admin"))):
    ag = agence_scope(user, agence_id)
    with tx(user.login) as cur:
        cur.execute("SELECT rouvrir_journee(%s::smallint, %s, %s, %s)", (ag, body.date, body.motif, user.id))
    return {"ok": True}
