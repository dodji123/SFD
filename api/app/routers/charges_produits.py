"""Charges et produits (module 51) : tiers, budget mensuel prévu / réalisé, opérations récurrentes, synthèse et alertes.
Les règles (budget sur charge ou produit seulement, récurrence hors caisse, idempotence de la génération) sont dans le schéma."""
import datetime as dt
from typing import Literal

from fastapi import APIRouter, Depends, HTTPException, Query
from pydantic import BaseModel, Field

from ..auth import User, agence_filter, agence_scope, require
from ..db import all_rows, one_row, tx

router = APIRouter(prefix="/api", tags=["charges-produits"])


# ================================================================== tiers
class TiersIn(BaseModel):
    nom: str = Field(min_length=2, max_length=150)
    type: Literal["fournisseur", "bailleur", "prestataire", "administration", "autre"] = "fournisseur"
    telephone: str | None = Field(default=None, max_length=20)
    adresse: str | None = Field(default=None, max_length=300)
    identifiant_fiscal: str | None = Field(default=None, max_length=40)
    agence_id: int | None = None           # absent : tiers commun à toutes les agences (réservé au siège)


@router.get("/tiers")
def lister_tiers(q: str | None = None, type: str | None = None, actif: bool | None = None, agence_id: int | None = None, user: User = Depends(require("operation:read"))):
    ag = agence_filter(user, agence_id)
    with tx() as cur:
        return all_rows(
            cur,
            "SELECT t.*, a.code AS agence FROM tiers t LEFT JOIN agence a ON a.id = t.agence_id "
            "WHERE (%s::int IS NULL OR t.agence_id = %s OR t.agence_id IS NULL) AND (%s::text IS NULL OR t.type = %s) AND (%s::boolean IS NULL OR t.actif = %s) "
            "AND (%s::text IS NULL OR t.nom ILIKE '%%' || %s || '%%' OR t.identifiant_fiscal ILIKE '%%' || %s || '%%') ORDER BY t.nom LIMIT 300",
            (ag, ag, type or None, type or None, actif, actif, q or None, q or None, q or None),
        )


@router.post("/tiers", status_code=201)
def creer_tiers(body: TiersIn, user: User = Depends(require("charge:gerer"))):
    if body.agence_id is None and not user.siege:
        raise HTTPException(status_code=403, detail="Un tiers commun à toutes les agences relève du siège")
    if body.agence_id is not None and not user.peut_agence(body.agence_id):
        raise HTTPException(status_code=403, detail="Agence non autorisée")
    with tx(user.login) as cur:
        return one_row(cur, "INSERT INTO tiers(agence_id, nom, type, telephone, adresse, identifiant_fiscal) VALUES (%s, %s, %s, %s, %s, %s) RETURNING *",
                       (body.agence_id, body.nom.strip(), body.type, body.telephone, body.adresse, body.identifiant_fiscal))


class TiersMaj(BaseModel):
    nom: str | None = Field(default=None, min_length=2, max_length=150)
    telephone: str | None = Field(default=None, max_length=20)
    adresse: str | None = Field(default=None, max_length=300)
    identifiant_fiscal: str | None = Field(default=None, max_length=40)
    actif: bool | None = None


@router.patch("/tiers/{tiers_id}")
def modifier_tiers(tiers_id: int, body: TiersMaj, user: User = Depends(require("charge:gerer"))):
    with tx(user.login) as cur:
        t = one_row(cur, "SELECT agence_id FROM tiers WHERE id = %s", (tiers_id,))
        visible = t is not None and (user.peut_agence(t["agence_id"]) if t["agence_id"] is not None else user.siege)
        if not visible:
            raise HTTPException(status_code=404, detail="Introuvable")
        cur.execute("UPDATE tiers SET nom = COALESCE(%s, nom), telephone = COALESCE(%s, telephone), adresse = COALESCE(%s, adresse), "
                    "identifiant_fiscal = COALESCE(%s, identifiant_fiscal), actif = COALESCE(%s, actif) WHERE id = %s",
                    (body.nom, body.telephone, body.adresse, body.identifiant_fiscal, body.actif, tiers_id))
        return one_row(cur, "SELECT * FROM tiers WHERE id = %s", (tiers_id,))


# ================================================================== budget et synthèse
class LigneBudget(BaseModel):
    mois: int = Field(ge=1, le=12)
    code_operation: str
    montant_prevu: int = Field(ge=0, le=10_000_000_000)
    commentaire: str | None = Field(default=None, max_length=200)


class BudgetIn(BaseModel):
    annee: int = Field(ge=2000, le=2100)
    agence_id: int | None = None
    lignes: list[LigneBudget] = Field(min_length=1, max_length=600)


@router.put("/budget-charges-produits")
def enregistrer_budget(body: BudgetIn, user: User = Depends(require("budget:gerer"))):
    ag = agence_scope(user, body.agence_id)
    with tx(user.login) as cur:
        for l in body.lignes:
            cur.execute(
                "INSERT INTO budget_ligne(agence_id, annee, mois, code_operation, montant_prevu, commentaire, cree_par) VALUES (%s, %s, %s, %s, %s, %s, %s) "
                "ON CONFLICT (agence_id, annee, mois, code_operation) DO UPDATE SET montant_prevu = EXCLUDED.montant_prevu, commentaire = EXCLUDED.commentaire, cree_par = EXCLUDED.cree_par",
                (ag, body.annee, l.mois, l.code_operation, l.montant_prevu, l.commentaire, user.id),
            )
        return {"enregistrees": len(body.lignes)}


@router.get("/budget-charges-produits")
def lire_budget(annee: int, mois: int | None = Query(default=None, ge=1, le=12), categorie: str | None = None, agence_id: int | None = None,
                depassement: bool | None = None, user: User = Depends(require("operation:read"))):
    ag = agence_filter(user, agence_id)
    with tx() as cur:
        return all_rows(
            cur,
            "SELECT * FROM v_budget_realise WHERE annee = %s AND (%s::int IS NULL OR agence_id = %s) AND (%s::int IS NULL OR mois = %s) "
            "AND (%s::text IS NULL OR categorie = %s) AND (%s::boolean IS NULL OR depassement = %s) ORDER BY mois, categorie, libelle",
            (annee, ag, ag, mois, mois, categorie or None, categorie or None, depassement, depassement),
        )


@router.get("/charges-produits/synthese")
def synthese(annee: int, agence_id: int | None = None, user: User = Depends(require("operation:read"))):
    """Produits, charges et résultat par mois, avec le budget correspondant."""
    ag = agence_filter(user, agence_id)
    with tx() as cur:
        mensuel = all_rows(
            cur,
            "SELECT mois, COALESCE(sum(realise) FILTER (WHERE categorie = 'produit'), 0)::bigint AS produits, COALESCE(sum(realise) FILTER (WHERE categorie = 'charge'), 0)::bigint AS charges, "
            "COALESCE(sum(prevu) FILTER (WHERE categorie = 'produit'), 0)::bigint AS produits_prevus, COALESCE(sum(prevu) FILTER (WHERE categorie = 'charge'), 0)::bigint AS charges_prevues "
            "FROM v_budget_realise WHERE annee = %s AND (%s::int IS NULL OR agence_id = %s) GROUP BY mois ORDER BY mois",
            (annee, ag, ag),
        )
    for m in mensuel:
        m["resultat"] = m["produits"] - m["charges"]
    total = {k: sum(m[k] for m in mensuel) for k in ("produits", "charges", "produits_prevus", "charges_prevues", "resultat")}
    return {"annee": annee, "mensuel": mensuel, "total": total}


@router.get("/charges-produits/alertes")
def alertes(agence_id: int | None = None, user: User = Depends(require("operation:read"))):
    ag = agence_filter(user, agence_id)
    with tx() as cur:
        return all_rows(cur, "SELECT * FROM v_alerte_charge_produit WHERE (%s::int IS NULL OR agence_id = %s) ORDER BY type, reference", (ag, ag))


# ================================================================== opérations récurrentes
class RecurrenteIn(BaseModel):
    code_operation: str
    montant: int = Field(gt=0, le=10_000_000_000)
    periodicite: Literal["mensuelle", "trimestrielle", "annuelle"]
    jour_du_mois: int = Field(default=1, ge=1, le=28)
    prochaine_date: dt.date
    date_fin: dt.date | None = None
    tiers_id: int | None = None
    libelle: str | None = Field(default=None, max_length=200)
    agence_id: int | None = None


@router.post("/operations-recurrentes", status_code=201)
def creer_recurrente(body: RecurrenteIn, user: User = Depends(require("charge:gerer"))):
    ag = agence_scope(user, body.agence_id)
    with tx(user.login) as cur:
        return one_row(cur, "INSERT INTO operation_recurrente(agence_id, code_operation, montant, tiers_id, libelle, periodicite, jour_du_mois, prochaine_date, date_fin, cree_par) "
                            "VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s, %s) RETURNING *",
                       (ag, body.code_operation, body.montant, body.tiers_id, body.libelle, body.periodicite, body.jour_du_mois, body.prochaine_date, body.date_fin, user.id))


@router.get("/operations-recurrentes")
def lister_recurrentes(actif: bool | None = None, agence_id: int | None = None, user: User = Depends(require("operation:read"))):
    ag = agence_filter(user, agence_id)
    with tx() as cur:
        return all_rows(
            cur,
            "SELECT r.*, s.libelle AS operation, s.categorie, t.nom AS tiers FROM operation_recurrente r JOIN operation_standard s ON s.code = r.code_operation LEFT JOIN tiers t ON t.id = r.tiers_id "
            "WHERE (%s::int IS NULL OR r.agence_id = %s) AND (%s::boolean IS NULL OR r.actif = %s) ORDER BY r.actif DESC, r.prochaine_date",
            (ag, ag, actif, actif),
        )


class RecurrenteMaj(BaseModel):
    actif: bool


@router.patch("/operations-recurrentes/{recurrente_id}")
def modifier_recurrente(recurrente_id: int, body: RecurrenteMaj, user: User = Depends(require("charge:gerer"))):
    with tx(user.login) as cur:
        r = one_row(cur, "SELECT agence_id FROM operation_recurrente WHERE id = %s", (recurrente_id,))
        if r is None or not user.peut_agence(r["agence_id"]):
            raise HTTPException(status_code=404, detail="Introuvable")
        cur.execute("UPDATE operation_recurrente SET actif = %s WHERE id = %s", (body.actif, recurrente_id))
        return one_row(cur, "SELECT * FROM operation_recurrente WHERE id = %s", (recurrente_id,))


class GenerationIn(BaseModel):
    jusqu: dt.date | None = None


@router.post("/operations-recurrentes/generer")
def generer(body: GenerationIn, user: User = Depends(require("charge:gerer"))):
    """Crée les opérations récurrentes dues, pour toutes les agences (rejouable sans effet) : opération du siège."""
    if not user.siege:
        raise HTTPException(status_code=403, detail="La génération des opérations récurrentes relève du siège")
    with tx(user.login) as cur:
        n = one_row(cur, "SELECT generer_operations_recurrentes(%s, %s) AS n", (body.jusqu or dt.date.today(), user.id))["n"]
        return {"operations_creees": n}
