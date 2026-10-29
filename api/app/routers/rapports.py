"""Rapports journaliers (global, agents, zones), écrans de crédit et tableau de bord.

Les rapports sont calculés par la base à partir des dates métier : un jour passé se reproduit à l'identique."""
import datetime as dt
from typing import Literal

from fastapi import APIRouter, Depends, HTTPException, Query

from ..auth import User, agence_scope, require
from ..db import all_rows, one_row, tx
from ..perms import PERMS

router = APIRouter(prefix="/api", tags=["rapports"])


@router.get("/rapports/journalier")
def rapport_global(date: dt.date, agence_id: int | None = None, user: User = Depends(require("rapports:read"))):
    ag = agence_scope(user, agence_id)
    with tx() as cur:
        return {"date": date, "agence_id": ag,
                "rubriques": all_rows(cur, "SELECT rubrique, valeur FROM rapport_journalier_global(%s::smallint, %s)", (ag, date))}


@router.get("/rapports/journalier/agents")
def rapport_agents(date: dt.date, agence_id: int | None = None, user: User = Depends(require("rapports:read"))):
    ag = agence_scope(user, agence_id)
    with tx() as cur:
        return all_rows(cur, "SELECT * FROM rapport_journalier_agent(%s::smallint, %s)", (ag, date))


@router.get("/rapports/journalier/zones")
def rapport_zones(date: dt.date, agence_id: int | None = None, user: User = Depends(require("rapports:read"))):
    ag = agence_scope(user, agence_id)
    with tx() as cur:
        return all_rows(cur, "SELECT * FROM rapport_journalier_zone(%s::smallint, %s)", (ag, date))


@router.get("/rapports/collecte-periode/detail")
def rapport_collecte_detail(du: dt.date, au: dt.date, produit_id: int | None = None, agent_id: int | None = None,
                            zone_id: int | None = None, q: str | None = None, agence_id: int | None = None,
                            user: User = Depends(require("rapports:read"))):
    """Détail ligne à ligne des collectes d'une période ; q : recherche d'un client par nom ou numéro (partiel)."""
    if au < du:
        raise HTTPException(status_code=422, detail="La date de fin précède la date de début")
    ag = agence_scope(user, agence_id)
    q = (q or "").strip() or None
    with tx() as cur:
        return all_rows(cur, "SELECT * FROM rapport_collecte_detail(%s::smallint, %s, %s, %s, %s, %s, %s)",
                        (ag, du, au, produit_id, agent_id, zone_id, q))


@router.get("/rapports/solde-a-retirer")
def rapport_solde_a_retirer(produit_id: int | None = None, agence_id: int | None = None,
                            user: User = Depends(require("rapports:read"))):
    """Soldes que les clients peuvent encore retirer, cycle par cycle, regroupables par produit (cycles non retirés, solde positif)."""
    ag = agence_scope(user, agence_id)
    with tx() as cur:
        return all_rows(cur, "SELECT * FROM rapport_solde_a_retirer(%s::smallint, %s)", (ag, produit_id))


@router.get("/rapports/collecte-periode")
def rapport_collecte_periode(du: dt.date, au: dt.date, groupe: Literal["produit", "agent", "zone"] = "produit",
                             produit_id: int | None = None, agence_id: int | None = None,
                             user: User = Depends(require("rapports:read"))):
    """Collectes d'une période, regroupées par produit, par agent ou par zone (zone = zone du client, collectrices affectées)."""
    if au < du:
        raise HTTPException(status_code=422, detail="La date de fin précède la date de début")
    ag = agence_scope(user, agence_id)
    with tx() as cur:
        return all_rows(cur, "SELECT * FROM rapport_collecte_periode(%s::smallint, %s, %s, %s, %s)", (ag, du, au, produit_id, groupe))


@router.get("/rapports/collecte-evolution")
def rapport_collecte_evolution(du: dt.date | None = None, au: dt.date | None = None, agence_id: int | None = None,
                               user: User = Depends(require("rapports:read"))):
    """Évolution de la collecte d'une période, globale et par agent, jour par jour, comparée à la période précédente
    de même durée. Sans dates : le mois calendaire en cours."""
    today = dt.date.today()
    du = du or today.replace(day=1)
    au = au or today
    if au < du:
        raise HTTPException(status_code=422, detail="La date de fin précède la date de début")
    duree = (au - du).days + 1
    prec_au = du - dt.timedelta(days=1)
    prec_du = prec_au - dt.timedelta(days=duree - 1)
    ag = agence_scope(user, agence_id)
    sql = ("SELECT l.date_collecte AS jour, l.agent_id, a.matricule, a.nom AS agent, sum(l.montant_collecte) AS total "
           "FROM ligne_collecte l JOIN cycle c ON c.id = l.cycle_id LEFT JOIN agent a ON a.id = l.agent_id "
           "WHERE c.agence_id = %s AND l.origine = 'collecte' AND l.date_collecte BETWEEN %s AND %s "
           "GROUP BY 1, 2, 3, 4 ORDER BY 1, 3")
    with tx() as cur:
        lignes = all_rows(cur, sql, (ag, du, au))
        precedent = all_rows(cur, "SELECT l.agent_id, sum(l.montant_collecte) AS total FROM ligne_collecte l JOIN cycle c ON c.id = l.cycle_id "
                                  "WHERE c.agence_id = %s AND l.origine = 'collecte' AND l.date_collecte BETWEEN %s AND %s GROUP BY 1",
                             (ag, prec_du, prec_au))
    par_jour: dict = {}
    agents: dict = {}
    for r in lignes:
        par_jour[r["jour"]] = par_jour.get(r["jour"], 0) + r["total"]
        a = agents.setdefault(r["agent_id"], {"agent_id": r["agent_id"], "matricule": r["matricule"], "agent": r["agent"], "total": 0, "jours": {}})
        a["total"] += r["total"]
        a["jours"][r["jour"]] = r["total"]
    prec_agent = {p["agent_id"]: p["total"] for p in precedent}
    total = sum(par_jour.values())
    total_prec = sum(prec_agent.values())
    return {
        "du": du, "au": au, "precedent_du": prec_du, "precedent_au": prec_au,
        "total": total, "total_precedent": total_prec,
        "jours": [{"jour": j, "total": t} for j, t in sorted(par_jour.items())],
        "agents": [{**{k: v for k, v in a.items() if k != "jours"}, "precedent": prec_agent.get(aid, 0),
                    "jours": [{"jour": j, "total": t} for j, t in sorted(a["jours"].items())]}
                   for aid, a in sorted(agents.items(), key=lambda x: x[1]["matricule"] or "")],
    }


@router.get("/rapports/credits/echus")
def echus(date: dt.date, agence_id: int | None = None, user: User = Depends(require("rapports:read"))):
    ag = agence_scope(user, agence_id)
    with tx() as cur:
        return all_rows(cur, "SELECT * FROM remboursements_echus(%s::smallint, %s)", (ag, date))


@router.get("/rapports/credits/a-venir")
def a_venir(date: dt.date, jours: int = Query(7, ge=1, le=90), agence_id: int | None = None,
            user: User = Depends(require("rapports:read"))):
    ag = agence_scope(user, agence_id)
    with tx() as cur:
        return all_rows(cur, "SELECT * FROM remboursements_a_venir(%s::smallint, %s, %s)", (ag, date, jours))


@router.get("/rapports/credits/situation")
def situation(date: dt.date, agence_id: int | None = None, user: User = Depends(require("rapports:read"))):
    ag = agence_scope(user, agence_id)
    with tx() as cur:
        return all_rows(cur, "SELECT * FROM situation_credits(%s::smallint, %s)", (ag, date))


@router.get("/rapports/credits/portefeuille")
def portefeuille(date: dt.date, agence_id: int | None = None, user: User = Depends(require("rapports:read"))):
    """Encours, portefeuille à risque (PAR 1 / 30 / 60 / 90 jours), retard par tranche, répartition de l'encours."""
    ag = agence_scope(user, agence_id)
    with tx() as cur:
        ind = {r["rubrique"]: r["valeur"] for r in all_rows(cur, "SELECT rubrique, valeur FROM rapport_portefeuille(%s::smallint, %s)", (ag, date))}
        tranches = all_rows(cur, "SELECT tranche, nb_credits, capital_restant, montant_en_retard FROM rapport_retard_par_tranche(%s::smallint, %s)", (ag, date))
        rep = {c: all_rows(cur, "SELECT * FROM portefeuille_repartition(%s::smallint, %s, %s)", (ag, date, c)) for c in ("type", "mode", "produit")}
    return {"date": date, "agence_id": ag, "indicateurs": ind, "tranches": tranches, "repartition": rep}


@router.get("/rapports/credits/retards")
def credits_en_retard(date: dt.date, agence_id: int | None = None, user: User = Depends(require("rapports:read"))):
    """Liste des crédits en retard à une date, du plus ancien impayé au plus récent."""
    ag = agence_scope(user, agence_id)
    with tx() as cur:
        return all_rows(
            cur,
            "SELECT credit_id, numero, client_id, client, produit, capital_restant, jours_retard, nb_echeances_en_retard, montant_en_retard, garantie_bloquee "
            "FROM portefeuille_a_date(%s::smallint, %s) WHERE jours_retard >= 1 ORDER BY jours_retard DESC, numero", (ag, date))


@router.get("/rapports/credits/periode")
def credits_periode(du: dt.date, au: dt.date, agence_id: int | None = None, user: User = Depends(require("rapports:read"))):
    ag = agence_scope(user, agence_id)
    with tx() as cur:
        r = all_rows(cur, "SELECT rubrique, valeur FROM rapport_credits_periode(%s::smallint, %s, %s)", (ag, du, au))
    return {"du": du, "au": au, "agence_id": ag, "rubriques": {x["rubrique"]: x["valeur"] for x in r}}


@router.get("/rapports/financier")
def rapport_financier(du: dt.date, au: dt.date, agence_id: int | None = None, user: User = Depends(require("rapports:read"))):
    """Compte d'exploitation opérationnel d'une période (produits, charges, résultat), calculé à partir des opérations."""
    ag = agence_scope(user, agence_id)
    with tx() as cur:
        lignes = all_rows(cur, "SELECT section, rubrique, libelle, valeur FROM rapport_financier(%s::smallint, %s, %s)", (ag, du, au))
    return {"du": du, "au": au, "agence_id": ag, "lignes": lignes}


@router.get("/tableau-de-bord")
def tableau_de_bord(agence_id: int | None = None, date: dt.date | None = None, user: User = Depends(require("ref:read"))):
    """Compteurs d'exploitation d'une agence (le siège désigne l'agence)."""
    ag = agence_scope(user, agence_id)
    jour = date or dt.date.today()
    with tx() as cur:
        out = one_row(
            cur,
            "SELECT "
            " (SELECT count(*) FROM cycle WHERE agence_id = %(a)s AND statut = 'en_cours') AS cycles_en_cours,"
            " (SELECT COALESCE(sum(l.montant_collecte), 0) FROM ligne_collecte l JOIN cycle c ON c.id = l.cycle_id "
            "   WHERE c.agence_id = %(a)s AND l.date_collecte = %(d)s AND l.origine = 'collecte') AS collecte_du_jour,"
            " (SELECT count(*) FROM retrait WHERE agence_id = %(a)s AND statut IN ('demande','ecart_en_traitement','fonds_disponibles') "
            "   AND nature <> 'regularisation') AS retraits_a_traiter,"
            " (SELECT count(*) FROM credit WHERE agence_id = %(a)s AND statut = 'en_retard') AS credits_en_retard,"
            " (SELECT count(*) FROM demande_credit WHERE agence_id = %(a)s AND statut = 'demandee') AS demandes_a_decider,"
            " (SELECT count(*) FROM session_caisse s JOIN caisse k ON k.id = s.caisse_id "
            "   WHERE k.agence_id = %(a)s AND s.statut = 'ouverte') AS sessions_ouvertes,"
            " (SELECT COALESCE(sum(-solde), 0) FROM v_solde_compte_agent WHERE agence_id = %(a)s AND solde < 0) AS dettes_agents,"
            " (SELECT COALESCE(sum(restant), 0) FROM v_surplus WHERE agence_id = %(a)s AND statut = 'a_traiter') AS surplus_a_traiter",
            {"a": ag, "d": jour},
        )
    out["date"] = jour
    out["agence_id"] = ag
    return out


@router.get("/moi/permissions")
def mes_permissions(user: User = Depends(require("ref:read"))):
    """Permissions du rôle courant : sert à l'interface pour masquer ce qui est interdit (le contrôle reste côté API)."""
    return {"role": user.role, "permissions": sorted(p for p, roles in PERMS.items() if user.role in roles)}
