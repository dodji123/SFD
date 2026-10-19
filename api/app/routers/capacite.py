"""Analyse de capacité de remboursement (modules 31 et 32) : simulation, enregistrement et lecture pour une demande de crédit.

L'analyse est indicative : elle éclaire la décision sans la bloquer."""
import json
from typing import Literal

from fastapi import APIRouter, Depends, HTTPException
from pydantic import BaseModel, Field

from .. import capacite
from ..auth import User, verifier_agence, require
from ..db import one_row, tx

router = APIRouter(prefix="/api", tags=["capacite"])


class ChargeIn(BaseModel):
    libelle: str = Field(default="", max_length=120)
    categorie: Literal["activite", "menage", "dette"]
    montant: float = Field(ge=0, le=1e10)
    periode: Literal["jourouvre", "jour7", "semaine", "mois", "trimestre", "semestre", "an"]


class GarantieIn(BaseModel):
    libelle: str = Field(default="", max_length=120)
    type: Literal["terrain", "batiment", "vehicule", "stock", "materiel", "betail", "epargne", "autre"] = "autre"
    valeur: float = Field(ge=0, le=1e11)
    decote: float = Field(default=50, ge=0, le=100)           # % perdu sur la valeur en cas de vente forcée


class ScenarioIn(BaseModel):
    libelle: str = Field(default="", max_length=60)
    montant: float = Field(gt=0, le=1e11)
    nb_echeances: int = Field(gt=0, le=240)
    taux: float = Field(ge=0, le=1)                           # fraction annuelle
    methode: Literal["capital_constant", "annuite_constante", "plat", "infine"] = "capital_constant"
    differe: int = Field(default=0, ge=0, le=239)


class MembreIn(BaseModel):
    nom: str = Field(default="", max_length=80)
    montant: float = Field(ge=0, le=1e11)
    disponible: float = Field(ge=-1e11, le=1e11)              # revenu disponible mensuel du membre avant la nouvelle échéance


class RevenusIn(BaseModel):
    secteur: str | None = Field(default=None, max_length=20)
    anciennete_mois: int = Field(default=0, ge=0, le=1200)
    jours_activite: int = Field(default=26, ge=1, le=31)
    ventes_mensuelles: float = Field(default=0, ge=0, le=1e11)
    achats_mensuels: float = Field(default=0, ge=0, le=1e11)
    autres_revenus: float = Field(default=0, ge=0, le=1e11)
    charges: list[ChargeIn] = Field(default_factory=list, max_length=60)
    cycle: int = Field(default=1, ge=1, le=5)
    caution: Literal["aucune", "perso", "groupe"] = "perso"
    historique: Literal["nouveau", "bon", "mineur", "grave"] = "bon"
    garanties: list[GarantieIn] = Field(default_factory=list, max_length=30)
    ventes_par_mois: list[float] | None = Field(default=None, min_length=12, max_length=12)      # 12 mois si l'activité est saisonnière
    scenarios: list[ScenarioIn] = Field(default_factory=list, max_length=10)
    groupe: list[MembreIn] = Field(default_factory=list, max_length=60)


class SimulationIn(RevenusIn):
    client_id: int
    montant: int = Field(gt=0)
    nb_echeances: int = Field(gt=0, le=240)
    taux: float = Field(ge=0, le=1)                                     # fraction annuelle (0.18 = 18 %)
    periodicite_jours: int = Field(default=30, gt=0, le=365)
    methode: Literal["capital_constant", "annuite_constante"] = "capital_constant"
    frais_pct: float = Field(default=0, ge=0, le=100)


def _parametre(cur, cle: str, agence_id: int, defaut: float) -> float:
    r = one_row(cur, "SELECT param_num(%s, %s::smallint) AS v", (cle, agence_id))
    return float(r["v"]) if r and r["v"] is not None else defaut


def _politique(cur, agence_id: int) -> dict:
    """Règles de l'institution : seuils, pondérations du score, plafonds par cycle (paramètres, surchargeables par agence)."""
    d = capacite.POLITIQUE_DEFAUT
    return {
        "max_dti": _parametre(cur, "endettement_max_pct", agence_id, d["max_dti"]), "min_couv": _parametre(cur, "couverture_min", agence_id, d["min_couv"]),
        "min_gar": _parametre(cur, "garantie_min_pct", agence_id, d["min_gar"]),
        "poids": [_parametre(cur, f"score_poids_{k}", agence_id, d["poids"][i]) for i, k in enumerate(("capacite", "endettement", "garanties", "anciennete", "historique"))],
        "seuils": [_parametre(cur, f"score_seuil_{k}", agence_id, d["seuils"][i]) for i, k in enumerate(("favorable", "conditions", "risque"))],
        "plafonds": [_parametre(cur, f"plafond_cycle_{n}", agence_id, d["plafonds"][n - 1]) for n in range(1, 6)],
    }


def dettes_internes(cur, client_id: int) -> float:
    """Remboursements mensuels déjà dus à l'institution : prochaine échéance non soldée de chaque crédit non soldé, ramenée au mois."""
    r = one_row(
        cur,
        "SELECT COALESCE(sum(((e.capital - e.capital_paye) + (e.interet - e.interet_paye)) * 30.0 / c.periodicite_jours), 0) AS m "
        "FROM credit c JOIN LATERAL (SELECT * FROM echeance x WHERE x.credit_id = c.id AND x.statut <> 'payee' ORDER BY x.no_echeance LIMIT 1) e ON true "
        "WHERE c.client_id = %s AND c.statut <> 'solde'", (client_id,))
    return float(r["m"])


def _calculer(cur, agence_id: int, client_id: int, p: dict, r: RevenusIn, frais_pct: float = 0.0) -> dict:
    pol = _politique(cur, agence_id)
    cond = dict(nb_echeances=p["nb_echeances"], taux_annuel=p["taux"], periodicite_jours=p["periodicite_jours"], methode=p["methode"])
    try:
        res = capacite.analyser(
            montant=p["montant"], **cond, ventes=r.ventes_mensuelles, achats=r.achats_mensuels, autres_revenus=r.autres_revenus, jours_activite=r.jours_activite,
            charges=[c.model_dump() for c in r.charges], dettes_internes_mensuelles=dettes_internes(cur, client_id), frais_pct=frais_pct,
            anciennete_mois=r.anciennete_mois, cycle=r.cycle, caution=r.caution, historique=r.historique, garanties=[g.model_dump() for g in r.garanties],
            ventes_mois=r.ventes_par_mois, politique=pol,
            scenarios=[{"libelle": s.libelle, "montant": s.montant, "nb_echeances": s.nb_echeances, "taux_annuel": s.taux, "methode": s.methode, "differe": s.differe} for s in r.scenarios] or None)
        if r.groupe:
            res["groupe"] = capacite.analyser_groupe([m.model_dump() for m in r.groupe], **cond, cycle=r.cycle, politique=pol)
    except ValueError as e:
        raise HTTPException(status_code=422, detail=str(e))
    return res


@router.post("/capacite/simuler")
def simuler(body: SimulationIn, user: User = Depends(require("credit:read"))):
    """Calcul à la volée, sans enregistrement (formulaire d'analyse)."""
    with tx() as cur:
        ag = verifier_agence(cur, user, "client", body.client_id)
        return _calculer(cur, ag, body.client_id, body.model_dump(), body, body.frais_pct)


def _demande(cur, user: User, demande_id: int) -> dict:
    verifier_agence(cur, user, "demande_credit", demande_id)
    return one_row(cur, "SELECT d.id, d.agence_id, d.client_id, d.montant, d.nb_echeances, d.taux, d.statut, p.periodicite_jours, p.methode, "
                        "       p.frais_dossier_taux * 100 AS frais_pct "
                        "FROM demande_credit d JOIN produit_credit_epargne p ON p.id = d.produit_id WHERE d.id = %s", (demande_id,))


def _conditions(d: dict) -> dict:
    return {"montant": float(d["montant"]), "nb_echeances": int(d["nb_echeances"]), "taux": float(d["taux"]),
            "periodicite_jours": int(d["periodicite_jours"]), "methode": d["methode"]}


@router.get("/demandes-credit/{demande_id}/analyse")
def lire(demande_id: int, user: User = Depends(require("credit:read"))):
    """Analyse enregistrée de la demande (ou rien) avec les seuils en vigueur."""
    with tx() as cur:
        d = _demande(cur, user, demande_id)
        a = one_row(cur, "SELECT a.*, u.login AS utilisateur FROM analyse_capacite a LEFT JOIN utilisateur u ON u.id = a.utilisateur_id WHERE a.demande_id = %s", (demande_id,))
        pol = _politique(cur, d["agence_id"])
    return {"analyse": a, "demande_statut": d["statut"], "endettement_max_pct": pol["max_dti"], "couverture_min": pol["min_couv"], "politique": pol}


@router.post("/demandes-credit/{demande_id}/analyse/simuler")
def simuler_demande(demande_id: int, body: RevenusIn, user: User = Depends(require("credit:read"))):
    """Calcul à la volée pour une demande existante (montant, durée, taux, périodicité, méthode et frais viennent de la demande et de son produit)."""
    with tx() as cur:
        d = _demande(cur, user, demande_id)
        return _calculer(cur, d["agence_id"], d["client_id"], _conditions(d), body, float(d["frais_pct"]))


@router.put("/demandes-credit/{demande_id}/analyse")
def enregistrer(demande_id: int, body: RevenusIn, user: User = Depends(require("credit:request"))):
    """Calcule et enregistre l'analyse de la demande (une par demande, remplacée à chaque enregistrement tant que la demande n'est pas décidée)."""
    with tx(user.login) as cur:
        d = _demande(cur, user, demande_id)
        if d["statut"] != "demandee":
            raise HTTPException(status_code=422, detail="La demande est déjà décidée : l'analyse ne se modifie plus")
        res = _calculer(cur, d["agence_id"], d["client_id"], _conditions(d), body, float(d["frais_pct"]))
        row = one_row(
            cur,
            "INSERT INTO analyse_capacite(agence_id, demande_id, client_id, secteur, anciennete_mois, jours_activite, ventes_mensuelles, achats_mensuels, autres_revenus, "
            "                             charges, resultat, taux_endettement, couverture, conforme, utilisateur_id, cycle, caution, historique, garanties, ventes_par_mois, "
            "                             scenarios, groupe, score, avis) "
            "VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s, %s::jsonb, %s::jsonb, %s, %s, %s, %s, %s, %s, %s, %s::jsonb, %s::jsonb, %s::jsonb, %s::jsonb, %s, %s) "
            "ON CONFLICT (demande_id) DO UPDATE SET secteur = EXCLUDED.secteur, anciennete_mois = EXCLUDED.anciennete_mois, jours_activite = EXCLUDED.jours_activite, "
            "  ventes_mensuelles = EXCLUDED.ventes_mensuelles, achats_mensuels = EXCLUDED.achats_mensuels, autres_revenus = EXCLUDED.autres_revenus, "
            "  charges = EXCLUDED.charges, resultat = EXCLUDED.resultat, taux_endettement = EXCLUDED.taux_endettement, couverture = EXCLUDED.couverture, "
            "  conforme = EXCLUDED.conforme, utilisateur_id = EXCLUDED.utilisateur_id, cycle = EXCLUDED.cycle, caution = EXCLUDED.caution, historique = EXCLUDED.historique, "
            "  garanties = EXCLUDED.garanties, ventes_par_mois = EXCLUDED.ventes_par_mois, scenarios = EXCLUDED.scenarios, groupe = EXCLUDED.groupe, "
            "  score = EXCLUDED.score, avis = EXCLUDED.avis, modifie_le = now() RETURNING *",
            (d["agence_id"], demande_id, d["client_id"], body.secteur, body.anciennete_mois, body.jours_activite, body.ventes_mensuelles, body.achats_mensuels,
             body.autres_revenus, json.dumps([c.model_dump() for c in body.charges]), json.dumps(res), res["taux_endettement"], res["couverture"], res["conforme"], user.id,
             body.cycle, body.caution, body.historique, json.dumps([g.model_dump() for g in body.garanties]),
             json.dumps(body.ventes_par_mois) if body.ventes_par_mois is not None else None,
             json.dumps([s.model_dump() for s in body.scenarios]), json.dumps([m.model_dump() for m in body.groupe]), res["score"], res["avis"]))
        return row
