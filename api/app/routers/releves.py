"""Relevé de compte d'un client : comptes d'épargne (mouvements et soldes), tontines (collectes et retraits), crédits."""
import datetime as dt

from fastapi import APIRouter, Depends, HTTPException, Query

from ..auth import User, require, verifier_agence
from ..db import all_rows, one_row, tx

router = APIRouter(prefix="/api", tags=["releves"])


@router.get("/clients/{client_id}/releve")
def releve(client_id: int, du: dt.date | None = None, au: dt.date | None = None, limit: int = Query(2000, ge=1, le=5000),
           user: User = Depends(require("epargne:read"))):
    """Période par défaut : les 90 derniers jours. Les soldes d'ouverture tiennent compte de tout ce qui précède `du`."""
    au = au or dt.date.today()
    du = du or au - dt.timedelta(days=90)
    if du > au:
        raise HTTPException(status_code=422, detail="La date de début suit la date de fin")
    with tx() as cur:
        ag = verifier_agence(cur, user, "client", client_id)
        cl = one_row(cur, "SELECT id, numero, nom, telephone FROM client WHERE id = %s", (client_id,))
        comptes = all_rows(cur, "SELECT c.id, c.numero, c.statut, p.libelle AS produit FROM compte_epargne c JOIN produit_epargne p ON p.id = c.produit_id "
                                "WHERE c.client_id = %s ORDER BY c.id", (client_id,))
        for c in comptes:
            c["solde_ouverture"] = one_row(
                cur, "SELECT COALESCE(sum(montant * sens_mouvement(type)), 0)::numeric(14,0) AS s FROM mouvement_epargne WHERE compte_id = %s AND date_operation < %s",
                (c["id"], du))["s"]
            mouvements = all_rows(
                cur, "SELECT id, date_operation, type, montant, libelle, sens_mouvement(type) AS sens FROM mouvement_epargne "
                     "WHERE compte_id = %s AND date_operation BETWEEN %s AND %s ORDER BY date_operation, id LIMIT %s", (c["id"], du, au, limit))
            solde = c["solde_ouverture"]
            for m in mouvements:
                solde += m["sens"] * m["montant"]
                m["solde"] = solde
            c["mouvements"] = mouvements
            c["solde_fin"] = solde
            c["total_entrees"] = sum(m["montant"] for m in mouvements if m["sens"] > 0)
            c["total_sorties"] = sum(m["montant"] for m in mouvements if m["sens"] < 0)
        cycles = all_rows(
            cur, "SELECT cy.id, cy.numero, cy.statut, p.libelle AS produit, s.montant_collecte AS total_collecte, cy.mise_courante "
                 "FROM cycle cy JOIN produit_epargne p ON p.id = cy.produit_id JOIN v_cycle_situation s ON s.cycle_id = cy.id "
                 "WHERE cy.client_id = %s AND (cy.statut = 'en_cours' OR EXISTS (SELECT 1 FROM ligne_collecte l WHERE l.cycle_id = cy.id AND l.date_collecte BETWEEN %s AND %s)) "
                 "ORDER BY cy.id", (client_id, du, au))
        for cy in cycles:
            cy["lignes"] = all_rows(cur, "SELECT date_collecte, montant_collecte, origine FROM ligne_collecte WHERE cycle_id = %s AND date_collecte BETWEEN %s AND %s "
                                         "ORDER BY date_collecte, id LIMIT %s", (cy["id"], du, au, limit))
            cy["total_periode"] = sum(l["montant_collecte"] for l in cy["lignes"])
            cy["retraits"] = all_rows(cur, "SELECT date_operation, montant, nature FROM retrait WHERE cycle_id = %s AND statut = 'execute' AND date_operation BETWEEN %s AND %s ORDER BY date_operation",
                                      (cy["id"], du, au))
        credits = all_rows(cur, "SELECT c.numero, c.montant_accorde, c.date_deblocage, c.statut, s.capital_restant, s.prochaine_echeance "
                                "FROM credit c JOIN v_credit_situation s ON s.credit_id = c.id WHERE c.client_id = %s ORDER BY c.id", (client_id,))
        return {
            "du": du, "au": au, "client": cl, "comptes": comptes, "cycles": cycles, "credits": credits,
            "institution": one_row(cur, "SELECT raison_sociale, sigle, agrement, adresse, ville, telephone, email, logo, pied_de_page FROM institution WHERE id = 1"),
            "agence": one_row(cur, "SELECT code, libelle, adresse, ville, telephone FROM agence WHERE id = %s", (ag,)),
            "edite_par": user.nom, "edite_le": dt.datetime.now().isoformat(timespec="minutes"),
        }
