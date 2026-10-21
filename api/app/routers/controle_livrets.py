"""Contrôle des livrets sur le terrain (module 47) : constat du contrôleur rapproché du système, validation par un responsable.
Les règles (écart, commentaire obligatoire, séparation des tâches, inaltérabilité) sont dans le schéma."""
import datetime as dt
from typing import Literal

from fastapi import APIRouter, Depends, HTTPException
from pydantic import BaseModel, Field

from ..auth import User, agence_filter, require, verifier_agence
from ..db import all_rows, one_row, tx

router = APIRouter(prefix="/api", tags=["controle-livrets"])


class EcartIn(BaseModel):
    no_ligne: int = Field(ge=1, le=62)
    date_collecte: dt.date | None = None
    montant_livret: int | None = Field(default=None, ge=0)
    montant_systeme: int | None = Field(default=None, ge=0)
    nature: Literal["absente_systeme", "absente_livret", "montant_different"]
    note: str | None = Field(default=None, max_length=300)


class ControleIn(BaseModel):
    cycle_id: int
    etat_livret: Literal["conforme", "incomplet", "abime", "perdu", "non_presente"]
    nb_lignes_constatees: int | None = Field(default=None, ge=0, le=500)
    total_constate: int | None = Field(default=None, ge=0)
    commentaire: str | None = Field(default=None, max_length=1000)
    date_controle: dt.date | None = None
    cle: str | None = Field(default=None, min_length=8, max_length=64)   # clé d'opération du téléphone : rejouer ne crée rien
    ecarts: list[EcartIn] = Field(default_factory=list, max_length=100)


def _detail(cur, controle_id: int) -> dict:
    c = one_row(cur, "SELECT * FROM v_controle_livret WHERE id = %s", (controle_id,))
    c["ecarts"] = all_rows(cur, "SELECT * FROM controle_livret_ligne WHERE controle_id = %s ORDER BY no_ligne", (controle_id,))
    return c


@router.post("/controles-livrets", status_code=201)
def enregistrer_controle(body: ControleIn, user: User = Depends(require("livret:controler"))):
    with tx(user.login) as cur:
        verifier_agence(cur, user, "cycle", body.cycle_id)
        if body.cle:
            deja = one_row(cur, "SELECT id, controleur_id FROM controle_livret WHERE cle = %s", (body.cle,))
            if deja is not None:
                if deja["controleur_id"] != user.id:
                    raise HTTPException(status_code=409, detail="Cette clé d'opération appartient à un autre contrôleur")
                return _detail(cur, deja["id"])
        r = one_row(
            cur,
            "INSERT INTO controle_livret(cycle_id, controleur_id, date_controle, cle, etat_livret, nb_lignes_constatees, total_constate, commentaire) "
            "VALUES (%s, %s, COALESCE(%s, current_date), %s, %s, %s, %s, %s) RETURNING id",
            (body.cycle_id, user.id, body.date_controle, body.cle, body.etat_livret, body.nb_lignes_constatees, body.total_constate, body.commentaire),
        )
        for e in body.ecarts:
            cur.execute(
                "INSERT INTO controle_livret_ligne(controle_id, no_ligne, date_collecte, montant_livret, montant_systeme, nature, note) VALUES (%s, %s, %s, %s, %s, %s, %s)",
                (r["id"], e.no_ligne, e.date_collecte, e.montant_livret, e.montant_systeme, e.nature, e.note),
            )
        return _detail(cur, r["id"])


@router.get("/controles-livrets")
def lister_controles(
    statut: str | None = None, cycle_id: int | None = None, agence_id: int | None = None, etat: str | None = None,
    controleur: str | None = None, q: str | None = None, du: dt.date | None = None, au: dt.date | None = None,
    avec_ecart: bool | None = None, user: User = Depends(require("livret:read")),
):
    ag = agence_filter(user, agence_id)
    with tx() as cur:
        return all_rows(
            cur,
            "SELECT * FROM v_controle_livret WHERE (%s::int IS NULL OR agence_id = %s) AND (%s::text IS NULL OR statut = %s) "
            "AND (%s::int IS NULL OR cycle_id = %s) AND (%s::text IS NULL OR etat_livret = %s) "
            "AND (%s::text IS NULL OR controleur ILIKE '%%' || %s || '%%') "
            "AND (%s::text IS NULL OR cycle ILIKE '%%' || %s || '%%' OR client ILIKE '%%' || %s || '%%' OR client_numero ILIKE '%%' || %s || '%%' OR produit ILIKE '%%' || %s || '%%') "
            "AND (%s::date IS NULL OR date_controle >= %s) AND (%s::date IS NULL OR date_controle <= %s) "
            "AND (%s::boolean IS NULL OR ((COALESCE(ecart_montant, 0) <> 0 OR etat_livret <> 'conforme' OR nb_ecarts_lignes > 0) = %s)) "
            "ORDER BY (statut = 'a_valider') DESC, date_controle DESC, id DESC LIMIT 300",
            (ag, ag, statut or None, statut or None, cycle_id, cycle_id, etat or None, etat or None, controleur or None, controleur or None,
             q or None, q or None, q or None, q or None, q or None, du, du, au, au, avec_ecart, avec_ecart),
        )


@router.get("/controles-livrets/{controle_id}")
def detail_controle(controle_id: int, user: User = Depends(require("livret:read"))):
    with tx() as cur:
        c = one_row(cur, "SELECT agence_id FROM controle_livret WHERE id = %s", (controle_id,))
        if c is None or not user.peut_agence(c["agence_id"]):
            raise HTTPException(status_code=404, detail="Introuvable")
        return _detail(cur, controle_id)


class DecisionIn(BaseModel):
    valide: bool
    commentaire: str | None = Field(default=None, max_length=500)


@router.post("/controles-livrets/{controle_id}/decider")
def decider_controle(controle_id: int, body: DecisionIn, user: User = Depends(require("livret:valider"))):
    with tx(user.login) as cur:
        c = one_row(cur, "SELECT agence_id, statut FROM controle_livret WHERE id = %s", (controle_id,))
        if c is None or not user.peut_agence(c["agence_id"]):
            raise HTTPException(status_code=404, detail="Introuvable")
        if c["statut"] != "a_valider":
            raise HTTPException(status_code=422, detail=f"Ce contrôle est déjà {c['statut']}")
        cur.execute("UPDATE controle_livret SET statut = %s, decide_par = %s, commentaire_decision = %s WHERE id = %s",
                    ("valide" if body.valide else "rejete", user.id, body.commentaire, controle_id))
        return _detail(cur, controle_id)
