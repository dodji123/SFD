"""Référentiels : agences, zones, agents, collectrices et affectations, clients, produits d'épargne."""
import datetime as dt
from typing import Literal

from fastapi import APIRouter, Depends, HTTPException, Query
from pydantic import BaseModel, Field

from ..auth import User, agence_filter, agence_scope, require, verifier_agence
from ..db import all_rows, one_row, tx

router = APIRouter(prefix="/api", tags=["referentiels"])


# ------------------------------------------------------------------ agences
class AgenceIn(BaseModel):
    code: str = Field(min_length=1, max_length=10)
    libelle: str = Field(min_length=1)
    siege: bool = False


@router.get("/agences")
def lister_agences(user: User = Depends(require("ref:read"))):
    with tx() as cur:
        if user.agence_id is not None:
            return all_rows(cur, "SELECT * FROM agence WHERE id = %s", (user.agence_id,))
        return all_rows(cur, "SELECT * FROM agence ORDER BY code")


@router.post("/agences", status_code=201)
def creer_agence(body: AgenceIn, user: User = Depends(require("agences:write"))):
    with tx(user.login) as cur:
        return one_row(cur, "INSERT INTO agence(code, libelle, siege) VALUES (%s, %s, %s) RETURNING *",
                       (body.code, body.libelle, body.siege))


# ------------------------------------------------------------------ zones
class ZoneIn(BaseModel):
    agence_id: int | None = None
    code: str = Field(min_length=1, max_length=10)
    libelle: str = Field(min_length=1)
    agent_id: int | None = None      # agent commercial qui collecte dans la zone


def _agent_de_l_agence(cur, agent_id: int | None, agence_id: int) -> None:
    if agent_id is not None and one_row(cur, "SELECT 1 AS x FROM agent WHERE id = %s AND agence_id = %s", (agent_id, agence_id)) is None:
        raise HTTPException(status_code=422, detail="L'agent n'appartient pas à l'agence de la zone")


class ZoneAgentIn(BaseModel):
    agent_id: int | None = None


@router.patch("/zones/{zone_id}")
def affecter_agent_zone(zone_id: int, body: ZoneAgentIn, user: User = Depends(require("ref:write"))):
    with tx(user.login) as cur:
        ag = verifier_agence(cur, user, "zone", zone_id)
        _agent_de_l_agence(cur, body.agent_id, ag)
        return one_row(cur, "UPDATE zone SET agent_id = %s WHERE id = %s RETURNING *", (body.agent_id, zone_id))


@router.get("/zones")
def lister_zones(agence_id: int | None = None, user: User = Depends(require("ref:read"))):
    ag = agence_filter(user, agence_id)
    with tx() as cur:
        return all_rows(
            cur,
            "SELECT z.*, (SELECT k.nom FROM affectation_zone a JOIN collectrice k ON k.id = a.collectrice_id "
            "              WHERE a.zone_id = z.id AND current_date >= a.date_debut "
            "                AND (a.date_fin IS NULL OR current_date <= a.date_fin) LIMIT 1) AS collectrice "
            "FROM zone z WHERE (%s::int IS NULL OR z.agence_id = %s) ORDER BY z.agence_id, z.code",
            (ag, ag),
        )


@router.post("/zones", status_code=201)
def creer_zone(body: ZoneIn, user: User = Depends(require("ref:write"))):
    ag = agence_scope(user, body.agence_id)
    with tx(user.login) as cur:
        _agent_de_l_agence(cur, body.agent_id, ag)
        return one_row(cur, "INSERT INTO zone(agence_id, code, libelle, agent_id) VALUES (%s, %s, %s, %s) RETURNING *",
                       (ag, body.code, body.libelle, body.agent_id))


class AffectationIn(BaseModel):
    collectrice_id: int
    date_debut: dt.date
    date_fin: dt.date | None = None


@router.get("/zones/{zone_id}/affectations")
def lister_affectations(zone_id: int, user: User = Depends(require("ref:read"))):
    with tx() as cur:
        verifier_agence(cur, user, "zone", zone_id)
        return all_rows(
            cur,
            "SELECT a.*, k.nom AS collectrice FROM affectation_zone a JOIN collectrice k ON k.id = a.collectrice_id "
            "WHERE a.zone_id = %s ORDER BY a.date_debut DESC",
            (zone_id,),
        )


@router.post("/zones/{zone_id}/affectations", status_code=201)
def affecter(zone_id: int, body: AffectationIn, user: User = Depends(require("ref:write"))):
    with tx(user.login) as cur:
        ag = verifier_agence(cur, user, "zone", zone_id)
        verifier_agence(cur, user, "collectrice", body.collectrice_id)
        c = one_row(cur, "SELECT agence_id FROM collectrice WHERE id = %s", (body.collectrice_id,))
        if c["agence_id"] != ag:
            raise HTTPException(status_code=422, detail="La collectrice n'appartient pas à l'agence de la zone")
        return one_row(
            cur,
            "INSERT INTO affectation_zone(zone_id, collectrice_id, date_debut, date_fin) VALUES (%s, %s, %s, %s) RETURNING *",
            (zone_id, body.collectrice_id, body.date_debut, body.date_fin),
        )


# ------------------------------------------------------------------ agents et collectrices
class PersonneIn(BaseModel):
    agence_id: int | None = None
    matricule: str = Field(min_length=1, max_length=20)
    nom: str = Field(min_length=1)


@router.get("/agents")
def lister_agents(agence_id: int | None = None, user: User = Depends(require("ref:read"))):
    ag = agence_filter(user, agence_id)
    with tx() as cur:
        return all_rows(cur, "SELECT * FROM agent WHERE (%s::int IS NULL OR agence_id = %s) ORDER BY agence_id, matricule", (ag, ag))


@router.post("/agents", status_code=201)
def creer_agent(body: PersonneIn, user: User = Depends(require("ref:write"))):
    ag = agence_scope(user, body.agence_id)
    with tx(user.login) as cur:
        return one_row(cur, "INSERT INTO agent(agence_id, matricule, nom) VALUES (%s, %s, %s) RETURNING *", (ag, body.matricule, body.nom))


@router.get("/collectrices")
def lister_collectrices(agence_id: int | None = None, user: User = Depends(require("ref:read"))):
    ag = agence_filter(user, agence_id)
    with tx() as cur:
        return all_rows(cur, "SELECT * FROM collectrice WHERE (%s::int IS NULL OR agence_id = %s) ORDER BY agence_id, matricule", (ag, ag))


class CollectriceIn(PersonneIn):
    agent_id: int | None = None


@router.post("/collectrices", status_code=201)
def creer_collectrice(body: CollectriceIn, user: User = Depends(require("ref:write"))):
    ag = agence_scope(user, body.agence_id)
    with tx(user.login) as cur:
        if body.agent_id is not None:
            a = one_row(cur, "SELECT agence_id FROM agent WHERE id = %s", (body.agent_id,))
            if a is None or a["agence_id"] != ag:
                raise HTTPException(status_code=422, detail="Agent inconnu ou d'une autre agence")
        return one_row(cur, "INSERT INTO collectrice(agence_id, matricule, nom, agent_id) VALUES (%s, %s, %s, %s) RETURNING *",
                       (ag, body.matricule, body.nom, body.agent_id))


# ------------------------------------------------------------------ clients
class ClientIn(BaseModel):
    agence_id: int | None = None
    zone_id: int | None = None
    numero: str | None = Field(default=None, max_length=20)  # vide : numérotation automatique
    nom: str = Field(min_length=1)
    telephone: str | None = None


class ClientPatch(BaseModel):
    nom: str | None = None
    zone_id: int | None = None
    telephone: str | None = None
    actif: bool | None = None


def _zone_de_l_agence(cur, zone_id: int | None, agence_id: int) -> None:
    if zone_id is None:
        return
    z = one_row(cur, "SELECT agence_id FROM zone WHERE id = %s", (zone_id,))
    if z is None or z["agence_id"] != agence_id:
        raise HTTPException(status_code=422, detail="Zone inconnue ou d'une autre agence")


@router.get("/clients")
def lister_clients(
    agence_id: int | None = None, q: str | None = None, zone_id: int | None = None,
    limit: int = Query(50, ge=1, le=500), offset: int = Query(0, ge=0),
    user: User = Depends(require("ref:read")),
):
    ag = agence_filter(user, agence_id)
    with tx() as cur:
        return all_rows(
            cur,
            "SELECT c.*, z.code AS zone FROM client c LEFT JOIN zone z ON z.id = c.zone_id "
            "WHERE (%s::int IS NULL OR c.agence_id = %s) AND (%s::int IS NULL OR c.zone_id = %s) "
            "  AND (%s::text IS NULL OR c.nom ILIKE '%%' || %s || '%%' OR c.numero ILIKE '%%' || %s || '%%' OR c.telephone ILIKE '%%' || %s || '%%') "
            "ORDER BY c.nom, c.id LIMIT %s OFFSET %s",
            (ag, ag, zone_id, zone_id, q, q, q, q, limit, offset),
        )


@router.post("/clients", status_code=201)
def creer_client(body: ClientIn, user: User = Depends(require("ref:write"))):
    ag = agence_scope(user, body.agence_id)
    with tx(user.login) as cur:
        _zone_de_l_agence(cur, body.zone_id, ag)
        return one_row(
            cur,
            "INSERT INTO client(agence_id, zone_id, numero, nom, telephone) VALUES (%s, %s, %s, %s, %s) RETURNING *",
            (ag, body.zone_id, body.numero, body.nom, body.telephone),
        )


@router.get("/clients/{client_id}")
def detail_client(client_id: int, user: User = Depends(require("ref:read"))):
    with tx() as cur:
        verifier_agence(cur, user, "client", client_id)
        c = one_row(cur, "SELECT c.*, z.code AS zone FROM client c LEFT JOIN zone z ON z.id = c.zone_id WHERE c.id = %s", (client_id,))
        c["comptes"] = all_rows(
            cur,
            "SELECT ce.id, ce.numero, ce.statut, p.libelle AS produit, v.solde, solde_disponible(ce.id) AS disponible "
            "FROM compte_epargne ce JOIN produit_epargne p ON p.id = ce.produit_id "
            "JOIN v_solde_compte_epargne v ON v.compte_id = ce.id WHERE ce.client_id = %s ORDER BY ce.id", (client_id,))
        c["cycles"] = all_rows(
            cur,
            "SELECT s.cycle_id AS id, s.numero, s.statut, s.type_cycle, s.montant_collecte, s.net FROM v_cycle_situation s "
            "WHERE s.client_id = %s ORDER BY s.cycle_id DESC", (client_id,))
        c["credits"] = all_rows(
            cur, "SELECT credit_id AS id, numero, type, mode_remboursement, capital_restant, statut "
                 "FROM v_credit_situation WHERE client_id = %s ORDER BY credit_id DESC", (client_id,))
        c["points_fidelite"] = one_row(cur, "SELECT points FROM v_points_client WHERE client_id = %s", (client_id,))["points"]
        return c


@router.patch("/clients/{client_id}")
def modifier_client(client_id: int, body: ClientPatch, user: User = Depends(require("ref:write"))):
    champs = body.model_dump(exclude_unset=True)
    if not champs:
        raise HTTPException(status_code=422, detail="Aucune modification")
    with tx(user.login) as cur:
        ag = verifier_agence(cur, user, "client", client_id)
        if "zone_id" in champs:
            # le changement de zone passe par le transfert (historique : la zone compte à la date de l'opération)
            zone = champs.pop("zone_id")
            if zone is None:
                raise HTTPException(status_code=422, detail="Un client doit avoir une zone : choisir une zone")
            _zone_de_l_agence(cur, zone, ag)
            if one_row(cur, "SELECT 1 AS x FROM client WHERE id = %s AND zone_id IS DISTINCT FROM %s", (client_id, zone)):
                cur.execute("SELECT transferer_client_zone(%s, %s, current_date, 'modification de la fiche', %s)", (client_id, zone, user.id))
        if champs:
            sets = ", ".join(f"{c} = %s" for c in champs)
            cur.execute(f"UPDATE client SET {sets} WHERE id = %s", (*champs.values(), client_id))
        return one_row(cur, "SELECT * FROM client WHERE id = %s", (client_id,))


# ------------------------------------------------------------------ produits d'épargne
class ProduitIn(BaseModel):
    code: str = Field(min_length=1, max_length=10)
    libelle: str = Field(min_length=1)
    categorie: Literal["collecte", "classique"]
    type_cycle: Literal[1, 2, 3] | None = None
    nb_pages_livret: int = Field(default=1, ge=1, le=20)
    taux_interet: float = Field(default=0, ge=0, le=1)
    solde_minimum: int = Field(default=0, ge=0)


@router.get("/produits-epargne")
def lister_produits(categorie: str | None = None, user: User = Depends(require("ref:read"))):
    with tx() as cur:
        return all_rows(cur, "SELECT * FROM produit_epargne WHERE actif AND (%s::text IS NULL OR categorie = %s) ORDER BY code", (categorie, categorie))


@router.post("/produits-epargne", status_code=201)
def creer_produit(body: ProduitIn, user: User = Depends(require("ref:write"))):
    with tx(user.login) as cur:
        return one_row(
            cur,
            "INSERT INTO produit_epargne(code, libelle, categorie, type_cycle, nb_pages_livret, taux_interet, solde_minimum) "
            "VALUES (%s, %s, %s, %s, %s, %s, %s) RETURNING *",
            (body.code, body.libelle, body.categorie, body.type_cycle, body.nb_pages_livret, body.taux_interet, body.solde_minimum),
        )
