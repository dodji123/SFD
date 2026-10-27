"""Contrôle des cycles au carnet du client : cycles d'une période, lignes de collecte, enregistrement et historique du contrôle."""
import datetime as dt
import json

from fastapi import APIRouter, Depends, HTTPException
from pydantic import BaseModel, Field

from ..auth import User, agence_filter, require, verifier_agence
from ..db import all_rows, one_row, tx

router = APIRouter(prefix="/api/controle-carnet", tags=["controle-carnet"])


@router.get("/cycles")
def cycles_du_controle(du: dt.date, au: dt.date, produit_id: int | None = None, q: str | None = None,
                       agence_id: int | None = None, user: User = Depends(require("livret:read"))):
    """Cycles dont la période chevauche [du, au], avec la date de leur dernier contrôle au carnet.
    q : recherche par numéro de client ou nom (partiel)."""
    ag = agence_filter(user, agence_id)
    if au < du:
        return []
    q = (q or "").strip() or None
    with tx() as cur:
        return all_rows(
            cur,
            "SELECT c.id, c.numero, c.client_id, cl.nom AS client, cl.numero AS client_numero, c.produit_id, pe.libelle AS produit, "
            "c.type_cycle, c.mise_courante, c.date_debut, c.date_fin, c.statut, "
            "(SELECT max(k.date_controle) FROM controle_carnet k WHERE k.cycle_id = c.id) AS dernier_controle "
            "FROM cycle c JOIN client cl ON cl.id = c.client_id JOIN produit_epargne pe ON pe.id = c.produit_id "
            "WHERE (%s::int IS NULL OR c.agence_id = %s) AND c.date_debut <= %s AND c.date_fin >= %s "
            "AND (%s::int IS NULL OR c.produit_id = %s) "
            "AND (%s::text IS NULL OR cl.nom ILIKE '%%' || %s || '%%' OR cl.numero ILIKE '%%' || %s || '%%') "
            "ORDER BY cl.nom, c.date_debut, c.id",
            (ag, ag, au, du, produit_id, produit_id, q, q, q),
        )


@router.get("/cycles/{cycle_id}/lignes")
def lignes_du_cycle(cycle_id: int, user: User = Depends(require("livret:read"))):
    """Lignes de collecte du cycle, dans l'ordre du tableau de collecte (ce que le contrôleur vérifie au carnet)."""
    with tx() as cur:
        verifier_agence(cur, user, "cycle", cycle_id)
        return all_rows(
            cur,
            "SELECT l.id, l.date_collecte, l.page, l.no_ligne, l.montant_collecte, l.agent_id, a.nom AS agent, l.origine "
            "FROM ligne_collecte l LEFT JOIN agent a ON a.id = l.agent_id WHERE l.cycle_id = %s "
            "ORDER BY l.date_collecte, l.page, l.no_ligne, l.id",
            (cycle_id,),
        )


class LigneCarnetIn(BaseModel):
    ligne_id: int
    montant_carnet: int = Field(ge=0)


class ControleCarnetIn(BaseModel):
    date_controle: dt.date | None = None
    commentaire: str | None = None
    lignes: list[LigneCarnetIn] = Field(min_length=1, max_length=400)


@router.post("/cycles/{cycle_id}/controles", status_code=201)
def enregistrer_controle(cycle_id: int, body: ControleCarnetIn, user: User = Depends(require("livret:controler"))):
    """Contrôle complet du cycle : une entrée par ligne de collecte. Le contrôle ne se modifie plus ensuite."""
    with tx(user.login) as cur:
        verifier_agence(cur, user, "cycle", cycle_id)
        cid = one_row(
            cur, "SELECT enregistrer_controle_carnet(%s, %s, %s, %s::jsonb, %s) AS id",
            (cycle_id, user.id, body.date_controle, json.dumps([l.model_dump() for l in body.lignes]), body.commentaire),
        )["id"]
        return one_row(cur, "SELECT * FROM controle_carnet WHERE id = %s", (cid,))


@router.get("/cycles/{cycle_id}/controles")
def controles_du_cycle(cycle_id: int, user: User = Depends(require("livret:read"))):
    """Historique des contrôles au carnet du cycle, avec leurs lignes."""
    with tx() as cur:
        verifier_agence(cur, user, "cycle", cycle_id)
        controles = all_rows(
            cur,
            "SELECT k.*, u.nom AS controleur FROM controle_carnet k LEFT JOIN utilisateur u ON u.id = k.controleur_id "
            "WHERE k.cycle_id = %s ORDER BY k.date_controle DESC, k.id DESC",
            (cycle_id,),
        )
        for k in controles:
            k["lignes"] = all_rows(
                cur,
                "SELECT l.*, r.surplus_utilise, r.impute_agent FROM controle_carnet_ligne l "
                "LEFT JOIN reglement_manquant_collecte r ON r.controle_ligne_id = l.id "
                "WHERE l.controle_id = %s ORDER BY l.id",
                (k["id"],),
            )
        return controles


@router.post("/controles/{controle_id}/regler-manquants")
def regler_manquants(controle_id: int, user: User = Depends(require("livret:controler"))):
    """Règle les manquants de collecte du contrôle : surplus de l'agent d'abord, le reste est imputé à son compte."""
    with tx(user.login) as cur:
        k = one_row(cur, "SELECT cycle_id FROM controle_carnet WHERE id = %s", (controle_id,))
        if k is None:
            raise HTTPException(status_code=404, detail="Introuvable")
        verifier_agence(cur, user, "cycle", k["cycle_id"])
        impute = one_row(cur, "SELECT regler_manquants_controle(%s, current_date) AS total", (controle_id,))["total"]
        return {"impute_a_l_agent": impute}
