"""Relevés du carnet du client par cycle, et rapprochement carnet / machine (module 80)."""
import datetime as dt
import json

from fastapi import APIRouter, Depends, HTTPException
from pydantic import BaseModel, Field

from ..auth import User, agence_filter, require, verifier_agence
from ..db import all_rows, one_row, tx

router = APIRouter(prefix="/api/releves-carnet", tags=["releves-carnet"])


@router.get("/rapprochement")
def rapprochement(agence_id: int | None = None, statut: str | None = None, user: User = Depends(require("livret:read"))):
    """Un cycle par ligne : relevé du carnet (dates, mise, total) comparé à la machine. statut : sans_releve | conforme | ecart."""
    if statut not in (None, "sans_releve", "conforme", "ecart"):
        raise HTTPException(status_code=422, detail="Statut inconnu")
    ag = agence_filter(user, agence_id)
    with tx() as cur:
        return all_rows(
            cur,
            "SELECT * FROM v_rapprochement_carnet WHERE (%s::int IS NULL OR agence_id = %s) AND (%s::text IS NULL OR statut = %s) "
            "ORDER BY client, cycle_numero",
            (ag, ag, statut, statut),
        )


@router.get("/cycles/{cycle_id}")
def releve_du_cycle(cycle_id: int, user: User = Depends(require("livret:read"))):
    """Relevé du carnet du cycle avec ses pages, ou null s'il n'a pas encore été relevé."""
    with tx() as cur:
        verifier_agence(cur, user, "cycle", cycle_id)
        releve = one_row(cur, "SELECT * FROM releve_carnet WHERE cycle_id = %s", (cycle_id,))
        if releve is None:
            return None
        releve["pages"] = all_rows(cur, "SELECT page, montant_non_retire AS montant FROM releve_carnet_page WHERE releve_id = %s ORDER BY page",
                                   (releve["id"],))
        return releve


class PageCarnetIn(BaseModel):
    page: int = Field(ge=1)
    montant: int = Field(ge=0)


class ReleveCarnetIn(BaseModel):
    date_debut: dt.date
    date_fin: dt.date
    mise: int = Field(gt=0)
    pages: list[PageCarnetIn] = Field(min_length=1, max_length=400)
    cle: str | None = Field(default=None, max_length=64)


@router.post("/cycles/{cycle_id}", status_code=201)
def enregistrer_releve(cycle_id: int, body: ReleveCarnetIn, user: User = Depends(require("livret:controler"))):
    """Relevé du carnet pour le cycle (un seul par cycle). Avec la même clé, une saisie rejouée renvoie le relevé déjà enregistré."""
    with tx(user.login) as cur:
        verifier_agence(cur, user, "cycle", cycle_id)
        rid = one_row(
            cur, "SELECT enregistrer_releve_carnet(%s, %s, %s, %s, %s, %s::jsonb, %s) AS id",
            (cycle_id, user.id, body.date_debut, body.date_fin, body.mise, json.dumps([p.model_dump() for p in body.pages]), body.cle),
        )["id"]
        return one_row(cur, "SELECT * FROM releve_carnet WHERE id = %s", (rid,))
