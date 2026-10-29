"""Page de suivi des collectes et des écarts de versement : liste des écarts, liste des collectes, situation par agent.

Écart de versement = collecté (lignes saisies pour l'agent ce jour-là) - versé. Positif = manquant, négatif = surplus."""
import datetime as dt

from fastapi import APIRouter, Depends, HTTPException

from ..auth import User, agence_scope, require, verifier_agence
from ..db import all_rows, one_row, tx

router = APIRouter(prefix="/api", tags=["ecarts-versement"])


def _periode(du: dt.date, au: dt.date) -> None:
    if au < du:
        raise HTTPException(status_code=422, detail="La date de fin précède la date de début")


@router.get("/ecarts-versement")
def ecarts_versement(du: dt.date, au: dt.date, agent_id: int | None = None, agence_id: int | None = None,
                     user: User = Depends(require("collecte:read"))):
    """Fins de tournée de la période dont le versement diffère de la collecte (manquants et surplus)."""
    _periode(du, au)
    ag = agence_scope(user, agence_id)
    with tx() as cur:
        return all_rows(
            cur,
            "SELECT v.id, v.date_tournee, a.id AS agent_id, a.matricule, a.nom AS agent, v.montant_collecte, v.montant_verse, v.ecart, "
            "       CASE WHEN v.ecart > 0 THEN 'manquant' ELSE 'surplus' END AS sens, ABS(v.ecart) AS montant "
            "FROM versement_agent v JOIN agent a ON a.id = v.agent_id "
            "WHERE v.agence_id = %s AND v.ecart <> 0 AND v.date_tournee BETWEEN %s AND %s "
            "AND (%s::int IS NULL OR v.agent_id = %s) ORDER BY v.date_tournee DESC, v.id DESC",
            (ag, du, au, agent_id, agent_id),
        )


@router.get("/collectes/liste")
def liste_collectes(du: dt.date, au: dt.date, agent_id: int | None = None, produit_id: int | None = None,
                    agence_id: int | None = None, user: User = Depends(require("collecte:read"))):
    """Lignes de collecte de la période (origine collecte), filtrables par agent et par produit."""
    _periode(du, au)
    ag = agence_scope(user, agence_id)
    with tx() as cur:
        return all_rows(
            cur,
            "SELECT l.id, l.date_collecte, a.matricule, a.nom AS agent, cl.numero AS client_numero, cl.nom AS client, "
            "       c.numero AS souscription, p.id AS produit_id, p.code AS produit, l.montant_collecte, l.origine "
            "FROM ligne_collecte l JOIN cycle c ON c.id = l.cycle_id JOIN client cl ON cl.id = c.client_id "
            "JOIN produit_epargne p ON p.id = c.produit_id LEFT JOIN agent a ON a.id = l.agent_id "
            "WHERE c.agence_id = %s AND l.origine = 'collecte' AND l.date_collecte BETWEEN %s AND %s "
            "AND (%s::int IS NULL OR l.agent_id = %s) AND (%s::int IS NULL OR c.produit_id = %s) "
            "ORDER BY l.date_collecte DESC, l.id DESC",
            (ag, du, au, agent_id, agent_id, produit_id, produit_id),
        )


@router.get("/ecarts-collecte")
def ecarts_collecte(agence_id: int | None = None, user: User = Depends(require("collecte:read"))):
    """Manquants relevés au contrôle au carnet, avec leur solde et ce qui peut être réglé par surplus.
    Règle : le surplus de la même date sert toujours ; ceux d'autres dates ne servent que si toutes les collectes
    de l'agent à cette date sont retirées. Le reste, s'il y en a, est imputé à l'agent au règlement."""
    ag = agence_scope(user, agence_id)
    with tx() as cur:
        lignes = all_rows(
            cur,
            "SELECT l.id, l.date_collecte, a.id AS agent_id, a.matricule, a.nom AS agent, cl.numero AS client_numero, cl.nom AS client, "
            "       c.id AS cycle_id, c.numero AS cycle, l.ecart AS manquant, r.id AS reglement_id, "
            "       COALESCE(r.surplus_utilise, 0) AS surplus_utilise, COALESCE(r.impute_agent, 0) AS impute_agent, "
            "       (SELECT COALESCE(sum(s.montant - s.montant_utilise), 0) FROM mf.surplus s "
            "         WHERE s.agent_id = l.agent_id AND s.statut = 'a_traiter' AND s.date_surplus = l.date_collecte) AS surplus_meme_date, "
            "       (SELECT COALESCE(sum(s.montant - s.montant_utilise), 0) FROM mf.surplus s "
            "         WHERE s.agent_id = l.agent_id AND s.statut = 'a_traiter' AND s.date_surplus <> l.date_collecte) AS surplus_autres_dates, "
            "       NOT EXISTS (SELECT 1 FROM mf.ligne_collecte x JOIN mf.cycle cy ON cy.id = x.cycle_id "
            "                    WHERE x.agent_id = l.agent_id AND x.date_collecte = l.date_collecte AND cy.statut <> 'retire') AS toutes_retirees "
            "FROM controle_carnet_ligne l JOIN controle_carnet k ON k.id = l.controle_id JOIN cycle c ON c.id = k.cycle_id "
            "JOIN client cl ON cl.id = c.client_id LEFT JOIN agent a ON a.id = l.agent_id "
            "LEFT JOIN reglement_manquant_collecte r ON r.controle_ligne_id = l.id "
            "WHERE c.agence_id = %s AND l.ecart > 0 ORDER BY l.date_collecte DESC, l.id DESC",
            (ag,),
        )
    for l in lignes:
        reglable = 0 if l["reglement_id"] is not None else min(
            l["manquant"], l["surplus_meme_date"] + (l["surplus_autres_dates"] if l["toutes_retirees"] else 0))
        l["solde_reglable"] = reglable
        l["statut"] = "regle" if l["reglement_id"] is not None else ("a_regler" if reglable > 0 else "en_attente")
    return lignes


@router.post("/ecarts-collecte/{ligne_id}/regler", status_code=201)
def regler_ecart_collecte(ligne_id: int, user: User = Depends(require("livret:controler"))):
    """Règle un manquant par le surplus disponible ; le reste est imputé au compte de l'agent (règle du module 73)."""
    with tx(user.login) as cur:
        l = one_row(cur, "SELECT l.id, c.id AS cycle_id FROM controle_carnet_ligne l JOIN controle_carnet k ON k.id = l.controle_id "
                         "JOIN cycle c ON c.id = k.cycle_id WHERE l.id = %s", (ligne_id,))
        if l is None:
            raise HTTPException(status_code=404, detail="Introuvable")
        verifier_agence(cur, user, "cycle", l["cycle_id"])
        impute = one_row(cur, "SELECT regler_manquant_collecte(%s, current_date) AS impute", (ligne_id,))["impute"]
        return {"impute_a_l_agent": impute}


@router.get("/manquants-versement")
def manquants_versement(agence_id: int | None = None, user: User = Depends(require("collecte:read"))):
    """Agents dont le compte est débiteur (manquants de versement non encore réglés), avec le montant à régler.
    Le règlement se fait en numéraire, ou par retenue sur le salaire au bulletin (DETTE_AGENT, plafonnée au net)."""
    ag = agence_scope(user, agence_id)
    with tx() as cur:
        return all_rows(
            cur,
            "SELECT s.agent_id, a.matricule, a.nom AS agent, -s.solde AS dette, "
            "       (SELECT max(date_operation) FROM compte_agent c WHERE c.agent_id = s.agent_id AND c.type = 'manquant_versement') AS dernier_manquant "
            "FROM v_solde_compte_agent s JOIN agent a ON a.id = s.agent_id "
            "WHERE s.agence_id = %s AND s.solde < 0 ORDER BY dette DESC",
            (ag,),
        )


@router.get("/ecarts-versement/situation-agents")
def situation_agents(du: dt.date, au: dt.date, agence_id: int | None = None, user: User = Depends(require("collecte:read"))):
    """Par agent, sur la période : collecté, versé, manquants, surplus, et solde actuel du compte agent."""
    _periode(du, au)
    ag = agence_scope(user, agence_id)
    with tx() as cur:
        return all_rows(
            cur,
            "SELECT a.id AS agent_id, a.matricule, a.nom AS agent, "
            "       count(v.id) AS nb_versements, "
            "       COALESCE(sum(v.montant_collecte), 0) AS total_collecte, "
            "       COALESCE(sum(v.montant_verse), 0) AS total_verse, "
            "       COALESCE(sum(v.ecart) FILTER (WHERE v.ecart > 0), 0) AS manquants, "
            "       COALESCE(-sum(v.ecart) FILTER (WHERE v.ecart < 0), 0) AS surplus, "
            "       COALESCE(sum(v.ecart), 0) AS ecart_net, "
            "       COALESCE(count(v.id) FILTER (WHERE v.ecart <> 0), 0) AS nb_ecarts, "
            "       COALESCE(s.solde, 0) AS solde_compte_agent "
            "FROM agent a "
            "LEFT JOIN versement_agent v ON v.agent_id = a.id AND v.date_tournee BETWEEN %s AND %s "
            "LEFT JOIN v_solde_compte_agent s ON s.agent_id = a.id "
            "WHERE a.agence_id = %s "
            "GROUP BY a.id, a.matricule, a.nom, s.solde ORDER BY a.matricule",
            (du, au, ag),
        )
