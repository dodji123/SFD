"""Retraits de cycle, écarts livret / machine, virements, versements de tournée, compte agent, surplus, purge."""
import datetime as dt
from typing import Literal

from fastapi import APIRouter, Depends, HTTPException, Query
from pydantic import BaseModel, Field

from ..auth import User, agence_filter, agence_scope, require, verifier_agence
from ..controles import controler_seuil_retrait
from ..db import all_rows, one_row, tx
from .caisse import verifier_session

router = APIRouter(prefix="/api", tags=["retraits"])

RETRAIT = (
    "SELECT r.*, c.numero AS cycle, c.client_id, cl.nom AS client, z.libelle AS zone, u.nom AS caissiere FROM retrait r "
    "JOIN cycle c ON c.id = r.cycle_id JOIN client cl ON cl.id = c.client_id "
    "LEFT JOIN zone z ON z.id = cl.zone_id LEFT JOIN utilisateur u ON u.id = r.execute_par "
)


def _retrait(cur, retrait_id: int) -> dict:
    r = one_row(cur, RETRAIT + "WHERE r.id = %s", (retrait_id,))
    r["ecarts"] = all_rows(
        cur,
        "SELECT e.*, (SELECT json_agg(d ORDER BY d.date_ecart, d.id) FROM ecart_retrait_date d WHERE d.ecart_id = e.id) AS details "
        "FROM ecart_retrait e WHERE e.retrait_id = %s ORDER BY e.id", (retrait_id,))
    r["virement"] = one_row(cur, "SELECT v.*, ce.numero AS compte FROM virement v JOIN compte_epargne ce ON ce.id = v.compte_id WHERE v.retrait_id = %s", (retrait_id,))
    return r


# ---------------------------------------------------------------- demande
class RetraitIn(BaseModel):
    nature: Literal["retrait_client", "virement_vers_epargne"] = "retrait_client"
    compte_id: int | None = None     # obligatoire pour un virement vers l'épargne
    date: dt.date | None = None
    montant: int | None = Field(default=None, gt=0)   # retrait partiel ; absent = solde disponible entier
    cloturer: bool | None = None     # cycle en cours, retrait partiel : clôturer le cycle ou non


@router.post("/cycles/{cycle_id}/retrait", status_code=201)
def demander_retrait(cycle_id: int, body: RetraitIn, user: User = Depends(require("retrait:request"))):
    """Clôture le cycle s'il est encore en cours (retrait anticipé) et crée la demande de retrait."""
    with tx(user.login) as cur:
        verifier_agence(cur, user, "cycle", cycle_id)
        if body.nature == "virement_vers_epargne":
            if body.compte_id is None:
                raise HTTPException(status_code=422, detail="compte_id obligatoire pour un virement vers l'épargne")
            verifier_agence(cur, user, "compte_epargne", body.compte_id)
            vid = one_row(cur, "SELECT demander_virement_cycle_vers_epargne(%s, %s, %s, COALESCE(%s, current_date)) AS id",
                          (cycle_id, body.compte_id, user.id, body.date))["id"]
            rid = one_row(cur, "SELECT retrait_id FROM virement WHERE id = %s", (vid,))["retrait_id"]
        else:
            rid = one_row(cur, "SELECT demander_retrait_cycle(%s, 'retrait_client', COALESCE(%s, current_date), %s, %s) AS id",
                          (cycle_id, body.date, body.montant, body.cloturer))["id"]
        return _retrait(cur, rid)


class RetraitDirectIn(BaseModel):
    nature: Literal["retrait_client", "virement_vers_epargne"] = "retrait_client"
    compte_id: int | None = None
    date: dt.date | None = None
    montant: int | None = Field(default=None, gt=0)   # absent = solde disponible entier
    cloturer: bool | None = None                      # cycle en cours, retrait partiel : clôturer ou non
    session_id: int | None = None                     # caisse : session ouverte obligatoire pour un paiement en espèces


@router.post("/cycles/{cycle_id}/retrait-direct", status_code=201)
def retrait_direct(cycle_id: int, body: RetraitDirectIn, user: User = Depends(require("retrait:execute"))):
    """Retrait au guichet : demande, constat sans écart et paiement en une action.
    Le contrôle du livret a déjà été fait avant la caisse ; un écart de contrôle non validé bloque le retrait."""
    with tx(user.login) as cur:
        ag = verifier_agence(cur, user, "cycle", cycle_id)
        ecart = one_row(cur, "SELECT id FROM v_controle_livret WHERE cycle_id = %s AND statut <> 'valide' "
                             "AND (COALESCE(ecart_montant, 0) <> 0 OR nb_ecarts_lignes > 0) LIMIT 1", (cycle_id,))
        if ecart is not None:
            raise HTTPException(status_code=422, detail="Le contrôle du livret de ce cycle relève un écart non validé : le carnet reste au contrôle")
        cy = one_row(cur, "SELECT client_id FROM cycle WHERE id = %s", (cycle_id,))
        if body.nature == "virement_vers_epargne":
            if body.compte_id is None:
                raise HTTPException(status_code=422, detail="compte_id obligatoire pour un virement vers l'épargne")
            verifier_agence(cur, user, "compte_epargne", body.compte_id)
            vid = one_row(cur, "SELECT demander_virement_cycle_vers_epargne(%s, %s, %s, COALESCE(%s, current_date)) AS id",
                          (cycle_id, body.compte_id, user.id, body.date))["id"]
            rid = one_row(cur, "SELECT retrait_id FROM virement WHERE id = %s", (vid,))["retrait_id"]
            session = None
        else:
            if body.session_id is None:
                raise HTTPException(status_code=422, detail="Ouvrez une session de caisse pour payer en espèces")
            if verifier_session(cur, user, body.session_id) != ag:
                raise HTTPException(status_code=422, detail="La session de caisse appartient à une autre agence")
            rid = one_row(cur, "SELECT demander_retrait_cycle(%s, 'retrait_client', COALESCE(%s, current_date), %s, %s) AS id",
                          (cycle_id, body.date, body.montant, body.cloturer))["id"]
            montant = one_row(cur, "SELECT montant FROM retrait WHERE id = %s", (rid,))["montant"]
            controler_seuil_retrait(cur, user, cy["client_id"], ag, montant, body.date)
            session = body.session_id
        cur.execute("SELECT constater_sans_ecart(%s)", (rid,))
        cur.execute("SELECT executer_retrait(%s, %s, %s)", (rid, body.date, session))
        cur.execute("UPDATE retrait SET execute_par = %s WHERE id = %s", (user.id, rid))
        return _retrait(cur, rid)


@router.get("/retraits")
def lister_retraits(
    statut: str | None = None, nature: str | None = None, cycle_id: int | None = None, agence_id: int | None = None,
    limit: int = Query(100, ge=1, le=500), user: User = Depends(require("collecte:read")),
):
    ag = agence_filter(user, agence_id)
    with tx() as cur:
        return all_rows(
            cur,
            RETRAIT + "WHERE (%s::int IS NULL OR r.agence_id = %s) AND (%s::text IS NULL OR r.statut = %s) "
            "AND (%s::text IS NULL OR r.nature = %s) AND (%s::int IS NULL OR r.cycle_id = %s) ORDER BY r.id DESC LIMIT %s",
            (ag, ag, statut, statut, nature, nature, cycle_id, cycle_id, limit),
        )


@router.get("/retraits/{retrait_id}")
def detail_retrait(retrait_id: int, user: User = Depends(require("collecte:read"))):
    with tx() as cur:
        verifier_agence(cur, user, "retrait", retrait_id)
        return _retrait(cur, retrait_id)


# ---------------------------------------------------------------- constat et écarts
@router.post("/retraits/{retrait_id}/constat-sans-ecart")
def constater(retrait_id: int, user: User = Depends(require("retrait:ecart"))):
    with tx(user.login) as cur:
        verifier_agence(cur, user, "retrait", retrait_id)
        cur.execute("SELECT constater_sans_ecart(%s)", (retrait_id,))
        return _retrait(cur, retrait_id)


class DetailEcart(BaseModel):
    date: dt.date
    montant: int = Field(gt=0)
    agent_id: int | None = None


class EcartIn(BaseModel):
    montant_livret: int = Field(ge=0)
    montant_machine: int = Field(ge=0)
    details: list[DetailEcart] = Field(min_length=1)


@router.post("/retraits/{retrait_id}/ecart", status_code=201)
def enregistrer_ecart(retrait_id: int, body: EcartIn, user: User = Depends(require("retrait:ecart"))):
    import json
    with tx(user.login) as cur:
        verifier_agence(cur, user, "retrait", retrait_id)
        details = json.dumps([{"date": str(d.date), "montant": d.montant, **({"agent_id": d.agent_id} if d.agent_id else {})} for d in body.details])
        cur.execute("SELECT enregistrer_ecart_retrait(%s, %s, %s, %s::jsonb)", (retrait_id, body.montant_livret, body.montant_machine, details))
        return _retrait(cur, retrait_id)


class TraiterIn(BaseModel):
    date: dt.date | None = None


@router.post("/ecarts/{ecart_id}/traiter")
def traiter_ecart(ecart_id: int, body: TraiterIn, user: User = Depends(require("retrait:ecart"))):
    with tx(user.login) as cur:
        e = one_row(cur, "SELECT retrait_id FROM ecart_retrait WHERE id = %s", (ecart_id,))
        if e is None:
            raise HTTPException(status_code=404, detail="Introuvable")
        verifier_agence(cur, user, "retrait", e["retrait_id"])
        perte = one_row(cur, "SELECT traiter_ecart_retrait(%s, %s) AS perte", (ecart_id, body.date))["perte"]
        return {"perte_imputee_aux_agents": perte, "retrait": _retrait(cur, e["retrait_id"])}


# ---------------------------------------------------------------- exécution
class ExecutionIn(BaseModel):
    date: dt.date | None = None
    session_id: int | None = None     # session de caisse : obligatoire pour un retrait payé en espèces


@router.post("/retraits/{retrait_id}/executer")
def executer(retrait_id: int, body: ExecutionIn, user: User = Depends(require("retrait:execute"))):
    with tx(user.login) as cur:
        ag = verifier_agence(cur, user, "retrait", retrait_id)
        r = one_row(cur, "SELECT r.nature, r.decaissement, r.statut, r.montant, cy.client_id FROM retrait r JOIN cycle cy ON cy.id = r.cycle_id WHERE r.id = %s", (retrait_id,))
        if r["nature"] == "retrait_client" and r["decaissement"]:
            controler_seuil_retrait(cur, user, r["client_id"], ag, r["montant"], body.date)
        if body.session_id is not None:
            if verifier_session(cur, user, body.session_id) != ag:
                raise HTTPException(status_code=422, detail="La session de caisse appartient à une autre agence")
        elif r["nature"] == "retrait_client" and r["decaissement"] and r["statut"] == "fonds_disponibles":
            raise HTTPException(status_code=422, detail="Session de caisse obligatoire pour un retrait payé en espèces")
        cur.execute("SELECT executer_retrait(%s, %s, %s)", (retrait_id, body.date, body.session_id))
        cur.execute("UPDATE retrait SET execute_par = %s WHERE id = %s", (user.id, retrait_id))
        return _retrait(cur, retrait_id)


# ---------------------------------------------------------------- virement épargne -> tontine
class VirementIn(BaseModel):
    compte_id: int
    cycle_id: int
    montant: int = Field(gt=0)
    date: dt.date | None = None


@router.post("/virements/epargne-vers-tontine", status_code=201)
def virer_vers_tontine(body: VirementIn, user: User = Depends(require("epargne:write"))):
    with tx(user.login) as cur:
        verifier_agence(cur, user, "compte_epargne", body.compte_id)
        verifier_agence(cur, user, "cycle", body.cycle_id)
        c = one_row(cur, "SELECT c.type_cycle, s.reste_a_collecter FROM cycle c JOIN v_cycle_situation s ON s.cycle_id = c.id WHERE c.id = %s", (body.cycle_id,))
        if c["type_cycle"] != 3 and c["reste_a_collecter"] is not None and body.montant > c["reste_a_collecter"]:
            raise HTTPException(status_code=422, detail=f"Le montant dépasse l'encours à collecter ({max(int(c['reste_a_collecter']), 0)} F)")
        vid = one_row(cur, "SELECT virement_epargne_vers_tontine(%s, %s, %s, COALESCE(%s, current_date), %s) AS id",
                      (body.compte_id, body.cycle_id, body.montant, body.date, user.id))["id"]
        return one_row(cur, "SELECT * FROM virement WHERE id = %s", (vid,))


@router.get("/virements")
def lister_virements(cycle_id: int | None = None, compte_id: int | None = None, agence_id: int | None = None,
                     user: User = Depends(require("epargne:read"))):
    ag = agence_filter(user, agence_id)
    with tx() as cur:
        return all_rows(
            cur,
            "SELECT v.*, c.numero AS cycle, ce.numero AS compte FROM virement v JOIN cycle c ON c.id = v.cycle_id "
            "JOIN compte_epargne ce ON ce.id = v.compte_id WHERE (%s::int IS NULL OR v.agence_id = %s) "
            "AND (%s::int IS NULL OR v.cycle_id = %s) AND (%s::int IS NULL OR v.compte_id = %s) ORDER BY v.id DESC LIMIT 200",
            (ag, ag, cycle_id, cycle_id, compte_id, compte_id),
        )


# ---------------------------------------------------------------- versements de tournée, compte agent
class VersementIn(BaseModel):
    date_tournee: dt.date
    montant_verse: int = Field(ge=0)
    session_id: int | None = None   # session de caisse qui reçoit l'argent versé


@router.post("/agents/{agent_id}/versement", status_code=201)
def versement(agent_id: int, body: VersementIn, user: User = Depends(require("versement:write"))):
    """Fin de tournée : collecté (lignes saisies) - versé. Manquant : débit du compte agent ; surplus : à traiter.
    L'argent versé entre en caisse (encaissement), dans la même transaction."""
    with tx(user.login) as cur:
        verifier_agence(cur, user, "agent", agent_id)
        if body.session_id is not None:
            verifier_session(cur, user, body.session_id)   # 404 si la session est d'une autre agence
        vid = one_row(cur, "SELECT versement_tournee_caisse(%s, %s, %s, %s, %s) AS id",
                      (agent_id, body.date_tournee, body.montant_verse, user.id, body.session_id))["id"]
        return one_row(cur, "SELECT * FROM versement_agent WHERE id = %s", (vid,))


@router.get("/agents/{agent_id}/compte")
def compte_agent(agent_id: int, user: User = Depends(require("collecte:read"))):
    with tx() as cur:
        verifier_agence(cur, user, "agent", agent_id)
        s = one_row(cur, "SELECT * FROM v_solde_compte_agent WHERE agent_id = %s", (agent_id,))
        s["operations"] = all_rows(
            cur, "SELECT id, type, montant, sens_compte_agent(type) AS sens, date_operation, libelle FROM compte_agent "
                 "WHERE agent_id = %s ORDER BY date_operation DESC, id DESC LIMIT 200", (agent_id,))
        s["versements"] = all_rows(
            cur, "SELECT * FROM versement_agent WHERE agent_id = %s ORDER BY date_tournee DESC LIMIT 60", (agent_id,))
        return s


class ReglementIn(BaseModel):
    montant: int = Field(gt=0)
    date: dt.date | None = None
    session_id: int | None = None   # session de caisse qui reçoit les espèces


@router.post("/agents/{agent_id}/compte/reglement", status_code=201)
def regler(agent_id: int, body: ReglementIn, user: User = Depends(require("versement:write"))):
    """Encaissement en numéraire d'un manquant de versement : solde le compte agent et entre les espèces en caisse."""
    with tx(user.login) as cur:
        verifier_agence(cur, user, "agent", agent_id)
        if body.session_id is not None:
            verifier_session(cur, user, body.session_id)   # 404 si la session est d'une autre agence
        cur.execute("SELECT reglement_agent_especes(%s, %s, COALESCE(%s, current_date), %s)",
                    (agent_id, body.montant, body.date, body.session_id))
        return one_row(cur, "SELECT * FROM v_solde_compte_agent WHERE agent_id = %s", (agent_id,))


@router.get("/surplus")
def lister_surplus(agent_id: int | None = None, statut: str | None = None, agence_id: int | None = None,
                   user: User = Depends(require("collecte:read"))):
    ag = agence_filter(user, agence_id)
    with tx() as cur:
        return all_rows(
            cur,
            "SELECT s.*, a.nom AS agent FROM v_surplus s JOIN agent a ON a.id = s.agent_id "
            "WHERE (%s::int IS NULL OR s.agence_id = %s) AND (%s::int IS NULL OR s.agent_id = %s) "
            "AND (%s::text IS NULL OR s.statut = %s) ORDER BY s.date_surplus DESC, s.id DESC LIMIT 300",
            (ag, ag, agent_id, agent_id, statut, statut),
        )


class PurgeIn(BaseModel):
    agence_id: int | None = None
    jusqu_au: dt.date | None = None


@router.post("/collecte/purger-dates")
def purger(body: PurgeIn, user: User = Depends(require("collecte:admin"))):
    ag = agence_scope(user, body.agence_id)
    with tx(user.login) as cur:
        n = one_row(cur, "SELECT purger_dates(%s::smallint, COALESCE(%s, current_date)) AS n", (ag, body.jusqu_au))["n"]
    return {"dates_purgees": n}


# ---------------------------------------------------------------- surplus d'une autre date (module 70)
@router.get("/ecarts/{ecart_id}/details")
def details_ecart(ecart_id: int, user: User = Depends(require("collecte:read"))):
    """Détail d'un écart par date, avec les surplus de l'agent sur d'autres dates pouvant le régler."""
    with tx() as cur:
        e = one_row(cur, "SELECT e.id, e.statut, e.retrait_id FROM ecart_retrait e WHERE e.id = %s", (ecart_id,))
        if e is None:
            raise HTTPException(status_code=404, detail="Introuvable")
        verifier_agence(cur, user, "retrait", e["retrait_id"])
        details = all_rows(
            cur,
            "SELECT d.id, d.date_ecart, d.agent_id, a.nom AS agent, d.montant, d.surplus_utilise, d.perte "
            "FROM ecart_retrait_date d JOIN agent a ON a.id = d.agent_id WHERE d.ecart_id = %s ORDER BY d.date_ecart, d.id",
            (ecart_id,),
        )
        for d in details:
            d["surplus_autres_dates"] = all_rows(
                cur,
                "SELECT s.id, s.date_surplus, s.montant - s.montant_utilise AS libre FROM surplus s "
                "WHERE s.agent_id = %s AND s.date_surplus <> %s AND s.statut = 'a_traiter' AND s.montant > s.montant_utilise "
                "ORDER BY s.date_surplus, s.id",
                (d["agent_id"], d["date_ecart"]),
            )
        return {"id": e["id"], "statut": e["statut"], "details": details}


class ValidationSurplusIn(BaseModel):
    surplus_id: int
    montant: int = Field(gt=0)
    motif: str = Field(min_length=5)


@router.post("/ecart-details/{detail_id}/validation-surplus", status_code=201)
def valider_surplus_autre_date(detail_id: int, body: ValidationSurplusIn, user: User = Depends(require("retrait:ecart"))):
    """Autorisation du chef d'agence : régler ce détail d'écart par un surplus d'une autre date du même agent."""
    if user.role != "chef_agence":
        raise HTTPException(status_code=403, detail="Seul le chef d'agence valide un surplus d'une autre date")
    with tx(user.login) as cur:
        d = one_row(cur, "SELECT e.retrait_id FROM ecart_retrait_date d JOIN ecart_retrait e ON e.id = d.ecart_id WHERE d.id = %s", (detail_id,))
        if d is None:
            raise HTTPException(status_code=404, detail="Introuvable")
        verifier_agence(cur, user, "retrait", d["retrait_id"])
        vid = one_row(
            cur, "SELECT valider_surplus_autre_date(%s, %s, %s, %s, %s) AS id",
            (detail_id, body.surplus_id, body.montant, user.id, body.motif),
        )["id"]
        return one_row(cur, "SELECT * FROM validation_surplus_autre_date WHERE id = %s", (vid,))


# ---------------------------------------------------------------- rapport des manquants non payés (module 71)
@router.get("/rapport-manquants")
def rapport_manquants(du: dt.date, au: dt.date, agence_id: int | None = None,
                      user: User = Depends(require("collecte:read"))):
    if au < du:
        raise HTTPException(status_code=422, detail="La date de fin précède la date de début")
    ag = agence_scope(user, agence_id)
    with tx() as cur:
        return all_rows(cur, "SELECT * FROM rapport_manquants(%s::smallint, %s, %s)", (ag, du, au))
