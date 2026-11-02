"""Date d'opération : journée comptable unique de l'institution (module 81). Ouverte avant toute opération,
clôturée pour tout le monde ; une date ne peut être future ni recréée. Les règles sont dans la base."""
import datetime as dt

from fastapi import APIRouter, Depends
from pydantic import BaseModel

from ..auth import User, require
from ..db import all_rows, one_row, tx

router = APIRouter(prefix="/api/journee", tags=["journee"])


class DateOperationIn(BaseModel):
    date: dt.date


@router.get("")
def etat(user: User = Depends(require("caisse:read"))):
    with tx() as cur:
        ouverte = one_row(cur, "SELECT date_operation FROM date_operation WHERE statut = 'ouverte'")
        jours = all_rows(cur, "SELECT date_operation, statut, ouverte_le, cloturee_le FROM date_operation "
                              "ORDER BY date_operation DESC LIMIT 30")
    return {"date_operation_ouverte": ouverte["date_operation"] if ouverte else None, "jours": jours}


@router.post("/ouvrir", status_code=201)
def ouvrir(body: DateOperationIn, user: User = Depends(require("journee:admin"))):
    with tx(user.login) as cur:
        cur.execute("SELECT ouvrir_date_operation(%s, %s)", (body.date, user.id))
    return {"ok": True}


@router.post("/cloturer")
def cloturer(user: User = Depends(require("journee:admin"))):
    with tx(user.login) as cur:
        cur.execute("SELECT cloturer_date_operation(%s)", (user.id,))
    return {"ok": True}
