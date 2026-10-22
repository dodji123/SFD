"""Immobilisations, maintenance et réparations (module 52).
Les règles (amortissement, sorties, transitions des interventions, séparation des tâches, périmètre d'agence)
sont dans le schéma ; ce routeur contrôle les droits et le périmètre."""
import datetime as dt
from typing import Literal

from fastapi import APIRouter, Depends, HTTPException
from pydantic import BaseModel, Field

from ..auth import User, agence_filter, agence_scope, require
from ..db import all_rows, one_row, tx

router = APIRouter(prefix="/api", tags=["immobilisations"])


def _immo(cur, user: User, immo_id: int) -> dict:
    i = one_row(cur, "SELECT * FROM mf.v_immobilisation WHERE id = %s", (immo_id,))
    if i is None or not user.peut_agence(i["agence_id"]):
        raise HTTPException(status_code=404, detail="Introuvable")
    return i


def _intervention(cur, user: User, intervention_id: int) -> dict:
    x = one_row(cur, "SELECT * FROM mf.v_intervention WHERE id = %s", (intervention_id,))
    if x is None or not user.peut_agence(x["agence_id"]):
        raise HTTPException(status_code=404, detail="Introuvable")
    return x


# ================================================================== catégories
@router.get("/categories-immobilisation")
def categories(user: User = Depends(require("immobilisation:read"))):
    with tx() as cur:
        return all_rows(cur, "SELECT code, libelle, duree_annees, compte_immobilisation, compte_amortissement, compte_dotation, actif "
                             "FROM mf.categorie_immobilisation ORDER BY libelle")


# ================================================================== registre
class ImmobilisationIn(BaseModel):
    designation: str = Field(min_length=3, max_length=200)
    categorie: str
    date_acquisition: dt.date
    date_mise_en_service: dt.date
    valeur_acquisition: int = Field(gt=0, le=10_000_000_000)
    valeur_residuelle: int = Field(default=0, ge=0)
    duree_annees: int | None = Field(default=None, ge=1, le=50)
    tiers_id: int | None = None
    reference_facture: str | None = Field(default=None, max_length=120)
    numero_serie: str | None = Field(default=None, max_length=120)
    localisation: str | None = Field(default=None, max_length=200)
    date_fin_garantie: dt.date | None = None
    agence_id: int | None = None


@router.get("/immobilisations")
def lister_immobilisations(statut: str | None = None, categorie: str | None = None, agence_id: int | None = None, q: str | None = None,
                           user: User = Depends(require("immobilisation:read"))):
    ag = agence_filter(user, agence_id)
    with tx() as cur:
        return all_rows(
            cur,
            "SELECT * FROM mf.v_immobilisation WHERE (%s::int IS NULL OR agence_id = %s) AND (%s::text IS NULL OR statut = %s) "
            "AND (%s::text IS NULL OR categorie = %s) AND (%s::text IS NULL OR designation ILIKE '%%' || %s || '%%' OR numero ILIKE '%%' || %s || '%%') "
            "ORDER BY agence_id, ordre DESC LIMIT 500",
            (ag, ag, statut, statut, categorie, categorie, q, q, q),
        )


@router.get("/immobilisations/{immo_id}")
def detail_immobilisation(immo_id: int, user: User = Depends(require("immobilisation:read"))):
    with tx() as cur:
        i = _immo(cur, user, immo_id)
        i["amortissements"] = all_rows(cur, "SELECT annee, mois, montant, cumul_apres FROM mf.amortissement_immobilisation WHERE immobilisation_id = %s ORDER BY annee, mois", (immo_id,))
        i["interventions"] = all_rows(cur, "SELECT * FROM mf.v_intervention WHERE immobilisation_id = %s ORDER BY id DESC", (immo_id,))
        i["plans"] = all_rows(cur, "SELECT * FROM mf.plan_maintenance WHERE immobilisation_id = %s ORDER BY id", (immo_id,))
        return i


@router.post("/immobilisations", status_code=201)
def creer_immobilisation(body: ImmobilisationIn, user: User = Depends(require("immobilisation:gerer"))):
    ag = agence_scope(user, body.agence_id)
    with tx(user.login) as cur:
        r = one_row(cur, "INSERT INTO mf.immobilisation(agence_id, designation, categorie, date_acquisition, date_mise_en_service, valeur_acquisition, valeur_residuelle, "
                         "duree_annees, tiers_id, reference_facture, numero_serie, localisation, date_fin_garantie, cree_par) "
                         "VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s) RETURNING id",
                    (ag, body.designation, body.categorie, body.date_acquisition, body.date_mise_en_service, body.valeur_acquisition, body.valeur_residuelle,
                     body.duree_annees, body.tiers_id, body.reference_facture, body.numero_serie, body.localisation, body.date_fin_garantie, user.id))
        return _immo(cur, user, r["id"])


class SortieIn(BaseModel):
    date_sortie: dt.date
    type_sortie: Literal["cession", "rebut", "perte"]
    valeur_cession: int | None = Field(default=None, ge=0)
    motif: str = Field(min_length=5, max_length=300)


@router.post("/immobilisations/{immo_id}/sortie")
def sortir(immo_id: int, body: SortieIn, user: User = Depends(require("immobilisation:gerer"))):
    with tx(user.login) as cur:
        _immo(cur, user, immo_id)
        vnc = one_row(cur, "SELECT mf.sortir_immobilisation(%s, %s, %s, %s, %s, %s) AS vnc",
                      (immo_id, body.date_sortie, body.type_sortie, body.valeur_cession, body.motif, user.id))["vnc"]
        return {"valeur_nette_comptable": vnc, "immobilisation": _immo(cur, user, immo_id)}


class AmortissementIn(BaseModel):
    jusqu: dt.date | None = None
    agence_id: int | None = None


@router.post("/immobilisations/amortissements/calculer")
def calculer(body: AmortissementIn, user: User = Depends(require("immobilisation:gerer"))):
    """Constate les dotations mensuelles dues jusqu'à la date donnée (rejouable sans effet)."""
    ag = agence_scope(user, body.agence_id)
    with tx(user.login) as cur:
        n = one_row(cur, "SELECT mf.calculer_amortissements(%s::smallint, %s, %s) AS n", (ag, body.jusqu or dt.date.today(), user.id))["n"]
        return {"dotations_creees": n}


# ================================================================== plans de maintenance
class PlanIn(BaseModel):
    immobilisation_id: int
    libelle: str = Field(min_length=3, max_length=200)
    periodicite_mois: int = Field(ge=1, le=120)
    prochaine_echeance: dt.date
    tiers_id: int | None = None
    cout_prevu: int | None = Field(default=None, ge=0)


@router.post("/plans-maintenance", status_code=201)
def creer_plan(body: PlanIn, user: User = Depends(require("maintenance:gerer"))):
    with tx(user.login) as cur:
        _immo(cur, user, body.immobilisation_id)
        r = one_row(cur, "INSERT INTO mf.plan_maintenance(immobilisation_id, libelle, periodicite_mois, prochaine_echeance, tiers_id, cout_prevu) "
                         "VALUES (%s, %s, %s, %s, %s, %s) RETURNING id",
                    (body.immobilisation_id, body.libelle, body.periodicite_mois, body.prochaine_echeance, body.tiers_id, body.cout_prevu))
        return one_row(cur, "SELECT * FROM mf.plan_maintenance WHERE id = %s", (r["id"],))


@router.post("/maintenance/preventives/generer")
def generer_preventives(user: User = Depends(require("maintenance:gerer"))):
    """Planifie les interventions préventives dont l'échéance approche (rejouable sans effet)."""
    with tx(user.login) as cur:
        n = one_row(cur, "SELECT mf.generer_interventions_preventives(current_date, %s) AS n", (user.id,))["n"]
        return {"interventions_planifiees": n}


# ================================================================== interventions
class PanneIn(BaseModel):
    description: str = Field(min_length=5, max_length=1000)
    priorite: Literal["basse", "normale", "haute", "urgente"] = "normale"
    hors_service: bool = False


@router.post("/immobilisations/{immo_id}/pannes", status_code=201)
def signaler_panne(immo_id: int, body: PanneIn, user: User = Depends(require("maintenance:signaler"))):
    with tx(user.login) as cur:
        _immo(cur, user, immo_id)
        r = one_row(cur, "SELECT mf.signaler_panne(%s, %s, %s, %s, %s) AS id",
                    (immo_id, body.description, body.priorite, body.hors_service, user.id))
        return _intervention(cur, user, r["id"])


@router.get("/interventions")
def lister_interventions(statut: str | None = None, ouvertes: bool | None = None, agence_id: int | None = None,
                         user: User = Depends(require("immobilisation:read"))):
    ag = agence_filter(user, agence_id)
    with tx() as cur:
        return all_rows(
            cur,
            "SELECT * FROM mf.v_intervention WHERE (%s::int IS NULL OR agence_id = %s) AND (%s::text IS NULL OR statut = %s) "
            "AND (%s::boolean IS NULL OR ouverte = %s) ORDER BY ouverte DESC, id DESC LIMIT 300",
            (ag, ag, statut, statut, ouvertes, ouvertes),
        )


class PlanifierIn(BaseModel):
    date_planifiee: dt.date
    tiers_id: int | None = None


@router.post("/interventions/{intervention_id}/planifier")
def planifier(intervention_id: int, body: PlanifierIn, user: User = Depends(require("maintenance:gerer"))):
    with tx(user.login) as cur:
        _intervention(cur, user, intervention_id)
        cur.execute("UPDATE mf.intervention SET statut = 'planifiee', date_planifiee = %s, tiers_id = COALESCE(%s, tiers_id) WHERE id = %s",
                    (body.date_planifiee, body.tiers_id, intervention_id))
        return _intervention(cur, user, intervention_id)


@router.post("/interventions/{intervention_id}/demarrer")
def demarrer(intervention_id: int, user: User = Depends(require("maintenance:gerer"))):
    with tx(user.login) as cur:
        _intervention(cur, user, intervention_id)
        cur.execute("UPDATE mf.intervention SET statut = 'en_cours', date_debut = COALESCE(date_debut, current_date) WHERE id = %s", (intervention_id,))
        return _intervention(cur, user, intervention_id)


class TerminerIn(BaseModel):
    date_fin: dt.date
    resultat: str = Field(min_length=5, max_length=1000)
    cout_main_oeuvre: int = Field(default=0, ge=0, le=10_000_000_000)
    cout_pieces: int = Field(default=0, ge=0, le=10_000_000_000)
    reference_facture: str | None = Field(default=None, max_length=120)
    tiers_id: int | None = None


@router.post("/interventions/{intervention_id}/terminer")
def terminer(intervention_id: int, body: TerminerIn, user: User = Depends(require("maintenance:gerer"))):
    with tx(user.login) as cur:
        _intervention(cur, user, intervention_id)
        cur.execute(
            "UPDATE mf.intervention SET statut = 'terminee', date_fin = %s, resultat = %s, cout_main_oeuvre = %s, cout_pieces = %s, "
            "reference_facture = %s, tiers_id = COALESCE(%s, tiers_id) WHERE id = %s",
            (body.date_fin, body.resultat, body.cout_main_oeuvre, body.cout_pieces, body.reference_facture, body.tiers_id, intervention_id),
        )
        return _intervention(cur, user, intervention_id)


class AnnulerIn(BaseModel):
    motif: str = Field(min_length=5, max_length=300)


@router.post("/interventions/{intervention_id}/annuler")
def annuler(intervention_id: int, body: AnnulerIn, user: User = Depends(require("maintenance:gerer"))):
    with tx(user.login) as cur:
        _intervention(cur, user, intervention_id)
        cur.execute("UPDATE mf.intervention SET statut = 'annulee', resultat = %s WHERE id = %s", (body.motif, intervention_id))
        return _intervention(cur, user, intervention_id)


# ================================================================== synthèse et alertes
@router.get("/immobilisations-couts")
def couts(agence_id: int | None = None, user: User = Depends(require("immobilisation:read"))):
    ag = agence_filter(user, agence_id)
    with tx() as cur:
        return all_rows(cur, "SELECT * FROM mf.v_cout_maintenance WHERE (%s::int IS NULL OR agence_id = %s) ORDER BY cout_total DESC", (ag, ag))


@router.get("/immobilisations-alertes")
def alertes(agence_id: int | None = None, user: User = Depends(require("immobilisation:read"))):
    ag = agence_filter(user, agence_id)
    with tx() as cur:
        return all_rows(cur, "SELECT * FROM mf.v_alerte_immobilisation WHERE (%s::int IS NULL OR agence_id = %s) ORDER BY type, reference", (ag, ag))
