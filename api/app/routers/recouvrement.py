"""Recouvrement des crédits en retard, passage en perte, rééchelonnement, et documents de crédit
(contrat à signer, certificat de clôture). Les règles d'enchaînement sont dans le schéma (module 37)."""
import datetime as dt
from typing import Literal

from fastapi import APIRouter, Depends, HTTPException
from pydantic import BaseModel, Field

from ..auth import User, agence_filter, require, verifier_agence
from ..db import all_rows, one_row, tx

router = APIRouter(prefix="/api", tags=["recouvrement"])

DOSSIER_SQL = (
    "SELECT d.*, c.numero AS credit, cl.nom AS client, c.montant_accorde, ua.nom AS agent, "
    "       jours_retard_credit(d.credit_id) AS jours_retard, "
    "       (SELECT capital_restant FROM v_credit_situation s WHERE s.credit_id = d.credit_id) AS capital_restant "
    "FROM dossier_recouvrement d JOIN credit c ON c.id = d.credit_id JOIN client cl ON cl.id = c.client_id "
    "LEFT JOIN utilisateur ua ON ua.id = d.agent_id "
)


@router.get("/recouvrement/credits-en-retard")
def credits_en_retard(agence_id: int | None = None, user: User = Depends(require("recouvrement:read"))):
    """Crédits en retard sans dossier de recouvrement ouvert."""
    ag = agence_filter(user, agence_id)
    with tx() as cur:
        return all_rows(
            cur,
            "SELECT c.id, c.numero, c.agence_id, cl.nom AS client, s.capital_restant, jours_retard_credit(c.id) AS jours_retard "
            "FROM credit c JOIN client cl ON cl.id = c.client_id JOIN v_credit_situation s ON s.credit_id = c.id "
            "WHERE c.statut = 'en_retard' AND (%s::int IS NULL OR c.agence_id = %s) "
            "  AND NOT EXISTS (SELECT 1 FROM dossier_recouvrement d WHERE d.credit_id = c.id AND d.statut NOT IN ('regle','perte')) "
            "ORDER BY jours_retard DESC LIMIT 300",
            (ag, ag),
        )


@router.get("/recouvrement/dossiers")
def dossiers(statut: str | None = None, agence_id: int | None = None, user: User = Depends(require("recouvrement:read"))):
    ag = agence_filter(user, agence_id)
    with tx() as cur:
        return all_rows(cur, DOSSIER_SQL + "WHERE (%s::int IS NULL OR d.agence_id = %s) AND (%s::text IS NULL OR d.statut = %s) ORDER BY d.id DESC LIMIT 300",
                        (ag, ag, statut, statut))


class OuvrirIn(BaseModel):
    credit_id: int
    agent_id: int | None = None
    note: str | None = Field(default=None, max_length=1000)


@router.post("/recouvrement/dossiers", status_code=201)
def ouvrir(body: OuvrirIn, user: User = Depends(require("recouvrement:write"))):
    with tx(user.login) as cur:
        verifier_agence(cur, user, "credit", body.credit_id)
        did = one_row(cur, "SELECT ouvrir_dossier_recouvrement(%s, %s, %s, %s) AS id", (body.credit_id, user.id, body.agent_id, body.note))["id"]
        return one_row(cur, DOSSIER_SQL + "WHERE d.id = %s", (did,))


@router.get("/recouvrement/dossiers/{dossier_id}")
def detail(dossier_id: int, user: User = Depends(require("recouvrement:read"))):
    with tx() as cur:
        verifier_agence(cur, user, "dossier_recouvrement", dossier_id)
        d = one_row(cur, DOSSIER_SQL + "WHERE d.id = %s", (dossier_id,))
        d["actions"] = all_rows(
            cur, "SELECT a.*, u.nom AS utilisateur FROM action_recouvrement a LEFT JOIN utilisateur u ON u.id = a.utilisateur_id WHERE a.dossier_id = %s ORDER BY a.id", (dossier_id,))
        d["radiation"] = one_row(cur, "SELECT * FROM radiation_credit WHERE dossier_id = %s", (dossier_id,))
        return d


class ActionIn(BaseModel):
    type: Literal["relance", "appel", "visite", "accord_amiable", "mise_en_demeure", "mise_en_demeure_aval", "saisie_salaire", "vente_garantie"]
    date_action: dt.date | None = None
    resultat: str | None = Field(default=None, max_length=1000)
    montant_promis: int | None = Field(default=None, gt=0)
    date_promesse: dt.date | None = None
    valeur_estimee: int | None = Field(default=None, gt=0)


@router.post("/recouvrement/dossiers/{dossier_id}/actions", status_code=201)
def ajouter_action(dossier_id: int, body: ActionIn, user: User = Depends(require("recouvrement:write"))):
    with tx(user.login) as cur:
        verifier_agence(cur, user, "dossier_recouvrement", dossier_id)
        return one_row(
            cur,
            "INSERT INTO action_recouvrement(dossier_id, date_action, type, resultat, montant_promis, date_promesse, valeur_estimee, utilisateur_id) "
            "VALUES (%s, COALESCE(%s, current_date), %s, %s, %s, %s, %s, %s) RETURNING *",
            (dossier_id, body.date_action, body.type, body.resultat, body.montant_promis, body.date_promesse, body.valeur_estimee, user.id),
        )


class PerteIn(BaseModel):
    motif: str = Field(min_length=10, max_length=2000)


@router.post("/recouvrement/dossiers/{dossier_id}/perte")
def perte(dossier_id: int, body: PerteIn, user: User = Depends(require("recouvrement:perte"))):
    with tx(user.login) as cur:
        verifier_agence(cur, user, "dossier_recouvrement", dossier_id)
        cur.execute("SELECT passer_en_perte(%s, %s, %s)", (dossier_id, user.id, body.motif))
        return one_row(cur, DOSSIER_SQL + "WHERE d.id = %s", (dossier_id,))


@router.post("/recouvrement/dossiers/{dossier_id}/cloturer")
def cloturer(dossier_id: int, user: User = Depends(require("recouvrement:write"))):
    with tx(user.login) as cur:
        verifier_agence(cur, user, "dossier_recouvrement", dossier_id)
        cur.execute("SELECT cloturer_dossier_regle(%s)", (dossier_id,))
        return one_row(cur, DOSSIER_SQL + "WHERE d.id = %s", (dossier_id,))


class ReechelonnerIn(BaseModel):
    nb_echeances: int = Field(gt=0, le=240)
    note: str | None = Field(default=None, max_length=1000)


@router.post("/recouvrement/credits/{credit_id}/reechelonner", status_code=201)
def reechelonner(credit_id: int, body: ReechelonnerIn, user: User = Depends(require("credit:request"))):
    """Crée une nouvelle demande (capital restant) à faire décider par le comité ; le crédit d'origine reste inchangé."""
    with tx(user.login) as cur:
        verifier_agence(cur, user, "credit", credit_id)
        did = one_row(cur, "SELECT reechelonner_credit(%s, %s, %s) AS id", (credit_id, body.nb_echeances, body.note))["id"]
        return one_row(cur, "SELECT * FROM demande_credit WHERE id = %s", (did,))


# ---------------------------------------------------------------- documents de crédit
def _entete(cur, agence_id: int) -> dict:
    return {
        "institution": one_row(cur, "SELECT raison_sociale, sigle, agrement, adresse, ville, telephone, email, logo, pied_de_page FROM institution WHERE id = 1"),
        "agence": one_row(cur, "SELECT code, libelle, adresse, ville, telephone FROM agence WHERE id = %s", (agence_id,)),
    }


@router.get("/documents-credit/{credit_id}/contrat")
def contrat(credit_id: int, user: User = Depends(require("credit:read"))):
    """Données du contrat de crédit à imprimer et à signer (termes, échéancier, garanties, décision du comité)."""
    with tx() as cur:
        ag = verifier_agence(cur, user, "credit", credit_id)
        c = one_row(cur, "SELECT c.*, cl.nom AS client, cl.numero AS client_numero, cl.telephone AS client_telephone FROM credit c JOIN client cl ON cl.id = c.client_id WHERE c.id = %s", (credit_id,))
        d = one_row(cur, "SELECT d.id, d.numero, d.date_demande, d.date_decision, d.commentaire, u.nom AS validateur FROM demande_credit d LEFT JOIN utilisateur u ON u.id = d.validateur_id WHERE d.credit_id = %s", (credit_id,))
        return {
            **_entete(cur, ag), "credit": c, "demande": d,
            "echeances": all_rows(cur, "SELECT no_echeance, date_prevue, capital, interet FROM echeance WHERE credit_id = %s ORDER BY no_echeance", (credit_id,)),
            "garantie_compte": one_row(cur, "SELECT g.montant_bloque, ce.numero AS compte FROM garantie_compte g JOIN compte_epargne ce ON ce.id = g.compte_id WHERE g.credit_id = %s", (credit_id,)),
            "garants": all_rows(cur, "SELECT cl.nom, g.montant_caution FROM garant_credit g JOIN client cl ON cl.id = g.garant_client_id WHERE g.credit_id = %s OR g.demande_id = %s", (credit_id, d["id"] if d else None)),
            "comite": one_row(cur, "SELECT s.numero AS seance, sd.decision, sd.motif, sd.montant_accorde, sd.conditions FROM seance_dossier sd JOIN seance_comite s ON s.id = sd.seance_id "
                                   "WHERE sd.demande_id = %s AND sd.decision = 'acceptation' ORDER BY sd.id DESC LIMIT 1", (d["id"] if d else None,)),
        }


@router.get("/documents-credit/{credit_id}/certificat-cloture")
def certificat_cloture(credit_id: int, user: User = Depends(require("credit:read"))):
    """Certificat de clôture d'un crédit entièrement remboursé."""
    with tx() as cur:
        ag = verifier_agence(cur, user, "credit", credit_id)
        c = one_row(cur, "SELECT c.numero, c.montant_accorde, c.date_deblocage, c.date_solde, c.statut, cl.nom AS client, cl.numero AS client_numero FROM credit c JOIN client cl ON cl.id = c.client_id WHERE c.id = %s", (credit_id,))
        if c["statut"] != "solde":
            raise HTTPException(status_code=422, detail="Le crédit n'est pas soldé : pas de certificat de clôture")
        tot = one_row(cur, "SELECT COALESCE(sum(capital_paye), 0) AS capital, COALESCE(sum(interet_paye), 0) AS interets, COALESCE(sum(penalite_payee), 0) AS penalites FROM echeance WHERE credit_id = %s", (credit_id,))
        garantie = one_row(cur, "SELECT montant_bloque, statut, libere_le FROM garantie_compte WHERE credit_id = %s", (credit_id,))
        return {**_entete(cur, ag), "credit": c, "totaux": tot, "garantie": garantie, "date_edition": dt.date.today().isoformat()}
