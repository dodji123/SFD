"""Ressources humaines : employés, contrats, rubriques de paie, avances, commissions, bulletins."""
import datetime as dt
from typing import Literal

from fastapi import APIRouter, Depends, HTTPException, Query
from pydantic import BaseModel, Field

from ..auth import User, agence_filter, agence_scope, require, verifier_agence
from ..db import all_rows, one_row, tx

router = APIRouter(prefix="/api", tags=["rh"])


# ---------------------------------------------------------------- employés et contrats
class EmployeIn(BaseModel):
    agence_id: int | None = None
    matricule: str = Field(min_length=1, max_length=20)
    nom: str = Field(min_length=1)
    poste: str | None = None
    date_embauche: dt.date
    collectrice_id: int | None = None
    agent_id: int | None = None


@router.get("/employes")
def lister_employes(agence_id: int | None = None, user: User = Depends(require("rh:read"))):
    ag = agence_filter(user, agence_id)
    with tx() as cur:
        return all_rows(
            cur,
            "SELECT e.*, (SELECT salaire_base FROM contrat c WHERE c.employe_id = e.id AND c.date_debut <= current_date "
            "              AND (c.date_fin IS NULL OR c.date_fin >= current_date) LIMIT 1) AS salaire_base "
            "FROM employe e WHERE (%s::int IS NULL OR e.agence_id = %s) ORDER BY e.agence_id, e.matricule", (ag, ag))


@router.post("/employes", status_code=201)
def creer_employe(body: EmployeIn, user: User = Depends(require("rh:write"))):
    ag = agence_scope(user, body.agence_id)
    with tx(user.login) as cur:
        return one_row(
            cur,
            "INSERT INTO employe(agence_id, matricule, nom, poste, date_embauche, collectrice_id, agent_id) "
            "VALUES (%s, %s, %s, %s, %s, %s, %s) RETURNING *",
            (ag, body.matricule, body.nom, body.poste, body.date_embauche, body.collectrice_id, body.agent_id))


class ContratIn(BaseModel):
    type: Literal["cdi", "cdd", "stage", "journalier"]
    date_debut: dt.date
    date_fin: dt.date | None = None
    salaire_base: int = Field(ge=0)


@router.post("/employes/{employe_id}/contrats", status_code=201)
def creer_contrat(employe_id: int, body: ContratIn, user: User = Depends(require("rh:write"))):
    with tx(user.login) as cur:
        verifier_agence(cur, user, "employe", employe_id)
        return one_row(
            cur, "INSERT INTO contrat(employe_id, type, date_debut, date_fin, salaire_base) VALUES (%s, %s, %s, %s, %s) RETURNING *",
            (employe_id, body.type, body.date_debut, body.date_fin, body.salaire_base))


class AvanceIn(BaseModel):
    montant: int = Field(gt=0)
    date_avance: dt.date


@router.post("/employes/{employe_id}/avances", status_code=201)
def creer_avance(employe_id: int, body: AvanceIn, user: User = Depends(require("rh:write"))):
    with tx(user.login) as cur:
        verifier_agence(cur, user, "employe", employe_id)
        return one_row(
            cur, "INSERT INTO avance_salaire(employe_id, date_avance, montant, restant) VALUES (%s, %s, %s, %s) RETURNING *",
            (employe_id, body.date_avance, body.montant, body.montant))


# ---------------------------------------------------------------- rubriques de paie (taux à saisir : non fournis)
class RubriqueIn(BaseModel):
    agence_id: int | None = None
    code: str = Field(min_length=1, max_length=20)
    libelle: str = Field(min_length=1)
    type: Literal["gain", "retenue_salariale", "charge_patronale"]
    mode: Literal["fixe", "pourcentage"]
    valeur: float = Field(ge=0)
    base: Literal["brut", "salaire_base"] = "brut"
    ordre: int = 100


@router.get("/rubriques-paie")
def lister_rubriques(user: User = Depends(require("rh:read"))):
    """Un utilisateur d'agence voit les rubriques de son agence et les rubriques globales ; le siège voit tout."""
    ag = agence_filter(user)
    with tx() as cur:
        return all_rows(cur, "SELECT * FROM rubrique_paie WHERE (%s::int IS NULL OR agence_id IS NULL OR agence_id = %s) ORDER BY ordre, id", (ag, ag))


@router.post("/rubriques-paie", status_code=201)
def creer_rubrique(body: RubriqueIn, user: User = Depends(require("rh:write"))):
    """Un utilisateur d'agence ne crée que des rubriques de son agence (jamais globales ni d'une autre agence) ;
    seul le siège peut créer une rubrique globale (agence_id vide)."""
    ag = agence_scope(user, body.agence_id) if user.agence_id is not None else body.agence_id
    with tx(user.login) as cur:
        return one_row(
            cur,
            "INSERT INTO rubrique_paie(agence_id, code, libelle, type, mode, valeur, base, ordre) "
            "VALUES (%s, %s, %s, %s, %s, %s, %s, %s) RETURNING *",
            (ag, body.code, body.libelle, body.type, body.mode, body.valeur, body.base, body.ordre))


# ---------------------------------------------------------------- commissions et bulletins
class CommissionIn(BaseModel):
    collectrice_id: int
    du: dt.date
    au: dt.date


@router.post("/commissions/calculer", status_code=201)
def calculer_commission(body: CommissionIn, user: User = Depends(require("rh:write"))):
    with tx(user.login) as cur:
        verifier_agence(cur, user, "collectrice", body.collectrice_id)
        cid = one_row(cur, "SELECT calculer_commission(%s, %s, %s) AS id", (body.collectrice_id, body.du, body.au))["id"]
        return one_row(cur, "SELECT * FROM commission_collectrice WHERE id = %s", (cid,))


@router.get("/commissions")
def lister_commissions(agence_id: int | None = None, user: User = Depends(require("rh:read"))):
    ag = agence_filter(user, agence_id)
    with tx() as cur:
        return all_rows(
            cur, "SELECT c.*, k.nom AS collectrice FROM commission_collectrice c JOIN collectrice k ON k.id = c.collectrice_id "
                 "WHERE (%s::int IS NULL OR c.agence_id = %s) ORDER BY c.periode_fin DESC, c.id DESC LIMIT 200", (ag, ag))


BULLETIN = "SELECT b.*, e.matricule, e.nom FROM bulletin_paie b JOIN employe e ON e.id = b.employe_id "


class BulletinIn(BaseModel):
    employe_id: int
    periode: dt.date


@router.post("/bulletins", status_code=201)
def generer_bulletin(body: BulletinIn, user: User = Depends(require("rh:write"))):
    with tx(user.login) as cur:
        verifier_agence(cur, user, "employe", body.employe_id)
        bid = one_row(cur, "SELECT generer_bulletin(%s, %s) AS id", (body.employe_id, body.periode))["id"]
        return _bulletin(cur, bid)


class BulletinsAgenceIn(BaseModel):
    agence_id: int | None = None
    periode: dt.date


@router.post("/bulletins/generer-agence")
def generer_bulletins(body: BulletinsAgenceIn, user: User = Depends(require("rh:write"))):
    ag = agence_scope(user, body.agence_id)
    with tx(user.login) as cur:
        n = one_row(cur, "SELECT generer_bulletins(%s::smallint, %s) AS n", (ag, body.periode))["n"]
    return {"bulletins_generes": n}


def _bulletin(cur, bid: int) -> dict:
    b = one_row(cur, BULLETIN + "WHERE b.id = %s", (bid,))
    b["lignes"] = all_rows(cur, "SELECT code, libelle, type, base, taux, montant FROM ligne_bulletin WHERE bulletin_id = %s ORDER BY id", (bid,))
    return b


@router.get("/bulletins")
def lister_bulletins(periode: dt.date | None = None, agence_id: int | None = None, user: User = Depends(require("rh:read"))):
    ag = agence_filter(user, agence_id)
    with tx() as cur:
        return all_rows(
            cur, BULLETIN + "WHERE (%s::int IS NULL OR b.agence_id = %s) AND (%s::date IS NULL OR b.periode = date_trunc('month', %s::date)) "
                            "ORDER BY b.periode DESC, e.matricule LIMIT 500", (ag, ag, periode, periode))


@router.get("/bulletins/{bulletin_id}")
def detail_bulletin(bulletin_id: int, user: User = Depends(require("rh:read"))):
    with tx() as cur:
        verifier_agence(cur, user, "bulletin_paie", bulletin_id)
        return _bulletin(cur, bulletin_id)


@router.post("/bulletins/{bulletin_id}/valider")
def valider_bulletin(bulletin_id: int, user: User = Depends(require("rh:write"))):
    with tx(user.login) as cur:
        verifier_agence(cur, user, "bulletin_paie", bulletin_id)
        cur.execute("SELECT valider_bulletin(%s)", (bulletin_id,))
        return _bulletin(cur, bulletin_id)
