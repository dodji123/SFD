"""Visites terrain et recouvrement : positions GPS des lieux de travail (emprunteur, caution) et des lieux visités."""
import datetime as dt
from typing import Literal

import psycopg2
from fastapi import APIRouter, Depends, HTTPException
from pydantic import BaseModel, Field

from ..auth import User, agence_scope, require, verifier_agence
from ..db import all_rows, one_row, tx
from ..errors import message_pg

router = APIRouter(prefix="/api/terrain", tags=["terrain"])


class LocalisationIn(BaseModel):
    client_id: int
    role: Literal["lieu_travail", "caution", "visite"]
    latitude: float = Field(ge=-90, le=90)
    longitude: float = Field(ge=-180, le=180)
    libelle: str | None = Field(default=None, max_length=200)
    precision_m: float | None = Field(default=None, ge=0)


@router.post("/localisations", status_code=201)
def enregistrer_localisation(body: LocalisationIn, user: User = Depends(require("recouvrement:write"))):
    with tx(user.login) as cur:
        verifier_agence(cur, user, "client", body.client_id)
        lid = one_row(cur, "SELECT enregistrer_localisation(%s, %s, %s, %s, %s, %s, %s) AS id",
                      (body.client_id, body.role, body.latitude, body.longitude, body.libelle, body.precision_m, user.id))["id"]
        return one_row(cur, "SELECT * FROM localisation WHERE id = %s", (lid,))


class VisiteIn(BaseModel):
    credit_id: int
    type: Literal["visite", "recouvrement"]
    localisation_id: int | None = None
    resultat: str | None = Field(default=None, max_length=1000)
    date: dt.date | None = None


@router.post("/visites", status_code=201)
def enregistrer_visite(body: VisiteIn, user: User = Depends(require("recouvrement:write"))):
    with tx(user.login) as cur:
        verifier_agence(cur, user, "credit", body.credit_id)
        vid = one_row(cur, "SELECT enregistrer_visite_terrain(%s, %s, %s, %s, %s, COALESCE(%s, current_date)) AS id",
                      (body.credit_id, body.type, user.id, body.localisation_id, body.resultat, body.date))["id"]
        return one_row(cur, "SELECT * FROM visite_terrain WHERE id = %s", (vid,))


# ---------------------------------------------------------------- synchronisation en agence (saisies hors ligne)
class LocalisationSync(LocalisationIn):
    cle: str = Field(min_length=1, max_length=64)


class VisiteSync(BaseModel):
    cle: str = Field(min_length=1, max_length=64)
    credit_id: int
    type: Literal["visite", "recouvrement"]
    localisation_cle: str | None = Field(default=None, max_length=64)   # position saisie hors ligne, rattachée par son identifiant
    resultat: str | None = Field(default=None, max_length=1000)
    date: dt.date | None = None


class SyncIn(BaseModel):
    localisations: list[LocalisationSync] = []
    visites: list[VisiteSync] = []


@router.post("/sync")
def synchroniser(body: SyncIn, user: User = Depends(require("recouvrement:write"))):
    """Rejoue les saisies faites hors ligne : positions d'abord, puis visites. Chaque élément a sa propre transaction ;
    un refus n'empêche pas les autres. Un identifiant déjà reçu n'est pas enregistré deux fois."""
    resultats = []
    for l in body.localisations:
        try:
            with tx(user.login) as cur:
                verifier_agence(cur, user, "client", l.client_id)
                one_row(cur, "SELECT enregistrer_localisation(%s, %s, %s, %s, %s, %s, %s, %s) AS id",
                        (l.client_id, l.role, l.latitude, l.longitude, l.libelle, l.precision_m, user.id, l.cle))
            resultats.append({"cle": l.cle, "type": "localisation", "statut": "ok"})
        except HTTPException as e:
            resultats.append({"cle": l.cle, "type": "localisation", "statut": "erreur", "motif": e.detail})
        except psycopg2.Error as e:
            resultats.append({"cle": l.cle, "type": "localisation", "statut": "erreur", "motif": message_pg(e)})
    for v in body.visites:
        try:
            with tx(user.login) as cur:
                verifier_agence(cur, user, "credit", v.credit_id)
                loc = None
                if v.localisation_cle:
                    loc = one_row(cur, "SELECT id FROM localisation WHERE cle = %s", (v.localisation_cle,))
                    if loc is None:
                        raise HTTPException(status_code=422, detail="position non synchronisée : synchronisez les positions avant la visite")
                one_row(cur, "SELECT enregistrer_visite_terrain(%s, %s, %s, %s, %s, COALESCE(%s, current_date), %s) AS id",
                        (v.credit_id, v.type, user.id, loc["id"] if loc else None, v.resultat, v.date, v.cle))
            resultats.append({"cle": v.cle, "type": "visite", "statut": "ok"})
        except HTTPException as e:
            resultats.append({"cle": v.cle, "type": "visite", "statut": "erreur", "motif": e.detail})
        except psycopg2.Error as e:
            resultats.append({"cle": v.cle, "type": "visite", "statut": "erreur", "motif": message_pg(e)})
    return {"resultats": resultats}


@router.get("/visites")
def lister_visites(du: dt.date, au: dt.date, agence_id: int | None = None, user: User = Depends(require("recouvrement:read"))):
    """Visites et recouvrements de la période, avec le client, le crédit et la position GPS du lieu visité."""
    if au < du:
        raise HTTPException(status_code=422, detail="La date de fin précède la date de début")
    ag = agence_scope(user, agence_id)
    with tx() as cur:
        return all_rows(
            cur,
            "SELECT v.id, v.date_visite, v.type, v.resultat, u.nom AS agent, cl.numero AS client_numero, cl.nom AS client, "
            "       c.numero AS credit, l.latitude, l.longitude, l.libelle AS lieu, l.precision_m "
            "FROM visite_terrain v JOIN utilisateur u ON u.id = v.agent_id JOIN client cl ON cl.id = v.client_id "
            "LEFT JOIN credit c ON c.id = v.credit_id LEFT JOIN localisation l ON l.id = v.localisation_id "
            "WHERE v.agence_id = %s AND v.date_visite BETWEEN %s AND %s ORDER BY v.date_visite DESC, v.id DESC",
            (ag, du, au),
        )


@router.get("/localisations")
def lister_localisations(client_id: int, user: User = Depends(require("recouvrement:read"))):
    """Positions GPS enregistrées pour un client : lieux de travail, cautions et lieux visités."""
    with tx() as cur:
        verifier_agence(cur, user, "client", client_id)
        return all_rows(cur, "SELECT id, role, libelle, latitude, longitude, precision_m, releve_le FROM localisation "
                             "WHERE client_id = %s ORDER BY releve_le DESC", (client_id,))
