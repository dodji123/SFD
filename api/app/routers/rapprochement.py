"""Rapprochement des fiches (crédits, épargne) avec la comptabilité, validation par le comptable (module 22)."""
import datetime as dt

from fastapi import APIRouter, Depends
from pydantic import BaseModel, Field

from ..auth import User, require
from ..db import all_rows, one_row, tx
from .reglementaire import _perimetre

router = APIRouter(prefix="/api/rapprochement", tags=["rapprochement"])


@router.get("")
def rapprochement(date: dt.date, agence_id: int | None = None, consolide: bool = False, user: User = Depends(require("compta:read"))):
    """Inventaire des fiches contre la comptabilité, rubrique par rubrique ; avec le statut de validation de l'agence."""
    ag = _perimetre(user, agence_id, consolide)
    with tx() as cur:
        lignes = all_rows(cur, "SELECT code, libelle, inventaire, comptabilite, ecart, conforme, note FROM rapprochement(%s::smallint, %s)", (ag, date))
        etats = all_rows(cur, "SELECT agence_id, agence, validee, statut, ecart_total, valide_le FROM etat_rapprochement_agences(%s)", (date,))
        tolerance = one_row(cur, "SELECT COALESCE(valeur, '0') AS v FROM parametre WHERE cle = 'rapprochement_tolerance' AND agence_id IS NULL")
    validation = None if ag is None else next((e for e in etats if e["agence_id"] == ag), None)
    return {"date": date, "agence_id": ag, "consolide": ag is None, "lignes": lignes, "tolerance": tolerance["v"] if tolerance else "0",
            "ecart_total": sum(abs(l["ecart"]) for l in lignes), "tous_conformes": all(l["conforme"] for l in lignes),
            "validation": validation, "agences": etats if ag is None else None}


class ValidationIn(BaseModel):
    date: dt.date
    justification: str | None = Field(default=None, max_length=500)
    agence_id: int | None = None


@router.post("/valider", status_code=201)
def valider(body: ValidationIn, user: User = Depends(require("rapprochement:valider"))):
    """Valide le rapprochement de l'agence : « conforme » sans écart, « écart justifié » avec une justification obligatoire."""
    ag = _perimetre(user, body.agence_id, False)
    with tx(user.login) as cur:
        cur.execute("SELECT valider_rapprochement(%s::smallint, %s, %s, %s)", (ag, body.date, user.id, body.justification))
    return rapprochement(body.date, ag, False, user)


@router.get("/historique")
def historique(agence_id: int | None = None, consolide: bool = False, user: User = Depends(require("compta:read"))):
    ag = _perimetre(user, agence_id, consolide)
    with tx() as cur:
        return all_rows(cur, "SELECT v.date_arrete, v.statut, v.ecart_total, v.justification, u.login AS valide_par, v.cree_le, a.code AS agence "
                             "FROM rapprochement_validation v JOIN agence a ON a.id = v.agence_id LEFT JOIN utilisateur u ON u.id = v.valide_par "
                             "WHERE (%s::int IS NULL OR v.agence_id = %s) ORDER BY v.id DESC LIMIT 50", (ag, ag))
