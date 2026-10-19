"""Collecte : cycles de tontine, livret (31 lignes par page), mises, clôtures."""
import datetime as dt

from fastapi import APIRouter, Depends, HTTPException, Query
from pydantic import BaseModel, Field

from ..auth import User, agence_filter, agence_scope, require, verifier_agence
from ..db import all_rows, one_row, tx

router = APIRouter(prefix="/api", tags=["collecte"])

SITUATION = (
    "SELECT s.cycle_id AS id, s.agence_id, s.numero, s.client_id, cl.nom AS client, s.type_cycle, s.statut, "
    "       c.mise_initiale, c.mise_courante, c.mise_finale, c.objectif, c.nb_lignes_prevues, c.date_debut, c.date_fin, c.date_cloture, "
    "       s.nb_lignes, s.montant_collecte, s.montant_previsionnel, s.reste_a_collecter, s.mise_cycle, s.net "
    "FROM v_cycle_situation s JOIN cycle c ON c.id = s.cycle_id JOIN client cl ON cl.id = s.client_id "
)


class CycleIn(BaseModel):
    agence_id: int | None = None
    client_id: int
    produit_id: int
    mise: int = Field(gt=0)
    date_debut: dt.date
    date_fin: dt.date
    objectif: int | None = Field(default=None, gt=0)
    nb_lignes_prevues: int | None = Field(default=None, gt=0, le=620)
    numero: str | None = Field(default=None, max_length=25)  # vide : numérotation automatique


@router.get("/cycles")
def lister_cycles(
    client_id: int | None = None, statut: str | None = None, agence_id: int | None = None, q: str | None = None,
    limit: int = Query(100, ge=1, le=500), offset: int = Query(0, ge=0),
    user: User = Depends(require("collecte:read")),
):
    ag = agence_filter(user, agence_id)
    with tx() as cur:
        return all_rows(
            cur,
            SITUATION + "WHERE (%s::int IS NULL OR s.agence_id = %s) AND (%s::int IS NULL OR s.client_id = %s) "
            "AND (%s::text IS NULL OR s.statut = %s) "
            "AND (%s::text IS NULL OR s.numero ILIKE '%%' || %s || '%%' OR cl.nom ILIKE '%%' || %s || '%%') "
            "ORDER BY s.cycle_id DESC LIMIT %s OFFSET %s",
            (ag, ag, client_id, client_id, statut, statut, q, q, q, limit, offset),
        )


@router.post("/cycles", status_code=201)
def creer_cycle(body: CycleIn, user: User = Depends(require("collecte:write"))):
    with tx(user.login) as cur:
        ag = verifier_agence(cur, user, "client", body.client_id)
        if body.agence_id is not None and body.agence_id != ag:
            raise HTTPException(status_code=422, detail="Le client n'appartient pas à cette agence")
        p = one_row(cur, "SELECT categorie, type_cycle, nb_pages_livret FROM produit_epargne WHERE id = %s AND actif", (body.produit_id,))
        if p is None or p["categorie"] != "collecte":
            raise HTTPException(status_code=422, detail="Le produit doit être un produit de collecte")
        nb = body.nb_lignes_prevues or 31 * p["nb_pages_livret"]
        objectif = body.objectif if body.objectif is not None else (body.mise * nb if p["type_cycle"] in (1, 2) else None)
        cid = one_row(
            cur,
            "INSERT INTO cycle(agence_id, numero, client_id, produit_id, type_cycle, mise_initiale, mise_courante, objectif, "
            "nb_lignes_prevues, date_debut, date_fin) VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s) RETURNING id",
            (ag, body.numero, body.client_id, body.produit_id, p["type_cycle"], body.mise, body.mise, objectif, nb,
             body.date_debut, body.date_fin),
        )["id"]
        return one_row(cur, SITUATION + "WHERE s.cycle_id = %s", (cid,))


def _detail(cur, cycle_id: int) -> dict:
    c = one_row(cur, SITUATION + "WHERE s.cycle_id = %s", (cycle_id,))
    c["lignes"] = all_rows(
        cur,
        "SELECT l.id, l.page, l.no_ligne, l.date_collecte, l.montant_collecte, l.mise_appliquee, l.origine, l.agent_id, a.nom AS agent "
        "FROM ligne_collecte l LEFT JOIN agent a ON a.id = l.agent_id WHERE l.cycle_id = %s ORDER BY l.page, l.no_ligne", (cycle_id,))
    c["mises"] = all_rows(cur, "SELECT date_effet, mise, motif FROM cycle_mise_historique WHERE cycle_id = %s ORDER BY date_effet", (cycle_id,))
    c["retraits"] = all_rows(
        cur, "SELECT id, nature, montant, montant_paye, ecart, statut, date_demande, date_operation FROM retrait "
             "WHERE cycle_id = %s ORDER BY id", (cycle_id,))
    return c


@router.get("/cycles/{cycle_id}")
def detail_cycle(cycle_id: int, user: User = Depends(require("collecte:read"))):
    with tx() as cur:
        verifier_agence(cur, user, "cycle", cycle_id)
        return _detail(cur, cycle_id)


class LigneIn(BaseModel):
    date_collecte: dt.date
    montant_collecte: int = Field(gt=0)
    agent_id: int | None = None
    page: int | None = Field(default=None, ge=1)
    no_ligne: int | None = Field(default=None, ge=1, le=31)


class LignesIn(BaseModel):
    lignes: list[LigneIn] = Field(min_length=1, max_length=100)


@router.post("/cycles/{cycle_id}/lignes", status_code=201)
def saisir_lignes(cycle_id: int, body: LignesIn, user: User = Depends(require("collecte:write"))):
    """Saisie du livret. Tout ou rien : une ligne refusée annule le lot. La page et le numéro de ligne
    sont attribués à la suite des lignes existantes s'ils ne sont pas fournis."""
    with tx(user.login) as cur:
        verifier_agence(cur, user, "cycle", cycle_id)
        idx = one_row(cur, "SELECT COALESCE(max((page - 1) * 31 + no_ligne), 0) AS m FROM ligne_collecte WHERE cycle_id = %s", (cycle_id,))["m"]
        for ln in body.lignes:
            agent = ln.agent_id
            if user.role == "agent":
                if user.agent_id is None:
                    raise HTTPException(status_code=403, detail="Votre compte n'est lié à aucun agent")
                if agent is not None and agent != user.agent_id:
                    raise HTTPException(status_code=403, detail="Un agent ne saisit que ses propres collectes")
                agent = user.agent_id
            if agent is None:
                raise HTTPException(status_code=422, detail="agent_id obligatoire pour une ligne de collecte")
            if ln.page is not None and ln.no_ligne is not None:
                page, no = ln.page, ln.no_ligne
            else:
                idx += 1
                page, no = (idx - 1) // 31 + 1, (idx - 1) % 31 + 1
            cur.execute(
                "INSERT INTO ligne_collecte(cycle_id, page, no_ligne, date_collecte, agent_id, montant_collecte) "
                "VALUES (%s, %s, %s, %s, %s, %s)",
                (cycle_id, page, no, ln.date_collecte, agent, ln.montant_collecte),
            )
        return _detail(cur, cycle_id)


def trouver_client(cur, agence_id: int, suffixe: str, date: dt.date | None = None) -> dict:
    """Retrouve un client actif par son numéro d'ordre (le « 5 » de CL-LOM-2026-000005) ou par son numéro complet.
    Plusieurs années peuvent partager le même numéro d'ordre : on retient l'année de `date`, à défaut le client le plus récent."""
    s = suffixe.strip()
    if not s:
        raise HTTPException(status_code=422, detail="Numéro client vide")
    if s.isdigit():
        cl = one_row(cur, "SELECT id, numero, nom, zone_id FROM client WHERE agence_id = %s AND actif AND numero ~ %s "
                          "ORDER BY (numero LIKE '%%-' || %s || '-%%') DESC, id DESC LIMIT 1",
                     (agence_id, r"-0*" + str(int(s)) + "$", str((date or dt.date.today()).year)))
    else:
        cl = one_row(cur, "SELECT id, numero, nom, zone_id FROM client WHERE agence_id = %s AND numero = %s AND actif", (agence_id, s))
    if cl is None:
        raise HTTPException(status_code=404, detail=f"Client n° {s} introuvable dans cette agence")
    return cl


@router.get("/collecte/client-cycle")
def cycle_du_client(suffixe: str, produit_id: int, zone_id: int | None = None, agence_id: int | None = None,
                    date: dt.date | None = None, user: User = Depends(require("collecte:read"))):
    """Formulaire de saisie : l'opérateur ne tape que le numéro d'ordre du client (le « 5 » de CL-LOM-2026-000005).
    Plusieurs années peuvent partager le même numéro d'ordre : on retient l'année de la collecte, à défaut le client le plus récent."""
    ag = agence_scope(user, agence_id)
    with tx() as cur:
        cl = trouver_client(cur, ag, suffixe, date)
        if zone_id is not None and cl["zone_id"] != zone_id:
            raise HTTPException(status_code=422, detail="Ce client n'appartient pas à la zone choisie")
        c = one_row(cur, SITUATION + "WHERE s.client_id = %s AND c.produit_id = %s AND s.statut = 'en_cours' "
                         "ORDER BY s.cycle_id DESC LIMIT 1", (cl["id"], produit_id))
        if c is None:
            raise HTTPException(status_code=404, detail=f"{cl['nom']} n'a aucun cycle en cours sur ce produit")
        return {"client": cl, "cycle": c}


class SaisieIn(BaseModel):
    cycle_id: int
    agent_id: int
    date_collecte: dt.date
    montant_collecte: int = Field(gt=0)


@router.post("/collecte/saisie", status_code=201)
def saisie_guichet(body: SaisieIn, user: User = Depends(require("collecte:write"))):
    """Saisie d'une collecte depuis le formulaire : le montant doit être un multiple de la mise (sauf cycle de type 3)."""
    if body.date_collecte > dt.date.today():
        raise HTTPException(status_code=422, detail="La date de collecte ne peut pas être dans le futur")
    with tx() as cur:
        verifier_agence(cur, user, "cycle", body.cycle_id)
        c = one_row(cur, "SELECT type_cycle, mise_courante, numero FROM cycle WHERE id = %s", (body.cycle_id,))
    if c["type_cycle"] != 3 and body.montant_collecte % int(c["mise_courante"]) != 0:
        raise HTTPException(status_code=422, detail=f"Le montant doit être un multiple de la mise ({int(c['mise_courante'])} F)")
    return saisir_lignes(body.cycle_id, LignesIn(lignes=[LigneIn(date_collecte=body.date_collecte, montant_collecte=body.montant_collecte, agent_id=body.agent_id)]), user)


class MiseIn(BaseModel):
    mise: int = Field(gt=0)
    date_effet: dt.date
    motif: str | None = None


@router.post("/cycles/{cycle_id}/mise")
def changer_mise(cycle_id: int, body: MiseIn, user: User = Depends(require("collecte:write"))):
    with tx(user.login) as cur:
        verifier_agence(cur, user, "cycle", cycle_id)
        cur.execute("SELECT changer_mise(%s, %s, %s, %s)", (cycle_id, body.mise, body.date_effet, body.motif))
        return _detail(cur, cycle_id)


class ClotureIn(BaseModel):
    date: dt.date | None = None


@router.post("/cycles/{cycle_id}/cloturer")
def cloturer(cycle_id: int, body: ClotureIn, user: User = Depends(require("collecte:admin"))):
    with tx(user.login) as cur:
        verifier_agence(cur, user, "cycle", cycle_id)
        cur.execute("SELECT cloturer_cycle(%s, COALESCE(%s, current_date))", (cycle_id, body.date))
        return _detail(cur, cycle_id)


class EchusIn(BaseModel):
    agence_id: int | None = None
    date: dt.date | None = None


@router.post("/collecte/cloturer-echus")
def cloturer_echus(body: EchusIn, user: User = Depends(require("collecte:admin"))):
    ag = agence_scope(user, body.agence_id)
    with tx(user.login) as cur:
        n = one_row(cur, "SELECT cloturer_cycles_echus(%s::smallint, COALESCE(%s, current_date)) AS n", (ag, body.date))["n"]
    return {"cycles_clotures": n}


@router.get("/collecte/journee")
def journee(agent_id: int, date: dt.date, user: User = Depends(require("collecte:read"))):
    """Feuille de collecte d'un agent pour un jour (base de la tournée et du versement)."""
    with tx() as cur:
        verifier_agence(cur, user, "agent", agent_id)
        lignes = all_rows(
            cur,
            "SELECT l.id, l.cycle_id, c.numero AS cycle, cl.nom AS client, l.page, l.no_ligne, l.montant_collecte, l.mise_appliquee "
            "FROM ligne_collecte l JOIN cycle c ON c.id = l.cycle_id JOIN client cl ON cl.id = c.client_id "
            "WHERE l.agent_id = %s AND l.date_collecte = %s AND l.origine = 'collecte' ORDER BY c.numero, l.no_ligne",
            (agent_id, date),
        )
        versement = one_row(cur, "SELECT * FROM versement_agent WHERE agent_id = %s AND date_tournee = %s", (agent_id, date))
    return {"agent_id": agent_id, "date": date, "total_collecte": sum(l["montant_collecte"] for l in lignes),
            "nb_lignes": len(lignes), "lignes": lignes, "versement": versement}


# ---------------------------------------------------------------- journée de collecte : tableau, correction, validation
@router.get("/collecte/jour")
def collecte_du_jour(date: dt.date, agent_id: int | None = None, agence_id: int | None = None,
                     user: User = Depends(require("collecte:read"))):
    """Tableau des collectes saisies un jour (toute l'agence, ou un agent), avec l'état de validation de la journée."""
    ag = agence_scope(user, agence_id)
    with tx() as cur:
        lignes = all_rows(
            cur,
            "SELECT l.id, l.cycle_id, c.numero AS souscription, cl.numero AS client_numero, cl.nom AS client, p.code AS produit, "
            "       c.type_cycle, c.mise_courante AS mise, l.montant_collecte, l.agent_id, a.matricule AS agent, "
            "       v.id IS NOT NULL AS versee "
            "FROM ligne_collecte l JOIN cycle c ON c.id = l.cycle_id JOIN client cl ON cl.id = c.client_id "
            "JOIN produit_epargne p ON p.id = c.produit_id LEFT JOIN agent a ON a.id = l.agent_id "
            "LEFT JOIN versement_agent v ON v.agent_id = l.agent_id AND v.date_tournee = l.date_collecte "
            "WHERE c.agence_id = %s AND l.date_collecte = %s AND l.origine = 'collecte' "
            "AND (%s::int IS NULL OR l.agent_id = %s) ORDER BY l.id DESC",
            (ag, date, agent_id, agent_id),
        )
        val = one_row(cur, "SELECT v.valide_le, u.login AS valide_par FROM validation_collecte v LEFT JOIN utilisateur u ON u.id = v.valide_par "
                           "WHERE v.agence_id = %s AND v.date_collecte = %s", (ag, date))
    for l in lignes:
        l["modifiable"] = val is None and not l["versee"]
    return {"date": date, "agence_id": ag, "validee": val is not None, "validation": val, "lignes": lignes,
            "total": sum(l["montant_collecte"] for l in lignes)}


def _ligne_autorisee(cur, user: User, ligne_id: int) -> dict:
    l = one_row(cur, "SELECT l.id, l.agent_id, c.agence_id, c.type_cycle, c.mise_courante FROM ligne_collecte l JOIN cycle c ON c.id = l.cycle_id WHERE l.id = %s", (ligne_id,))
    if l is None or (user.agence_id is not None and l["agence_id"] != user.agence_id):
        raise HTTPException(status_code=404, detail="Introuvable")
    if user.role == "agent" and l["agent_id"] != user.agent_id:
        raise HTTPException(status_code=403, detail="Un agent ne corrige que ses propres collectes")
    return l


class CorrectionIn(BaseModel):
    montant_collecte: int = Field(gt=0)


@router.put("/collecte/lignes/{ligne_id}")
def modifier_ligne(ligne_id: int, body: CorrectionIn, user: User = Depends(require("collecte:write"))):
    with tx(user.login) as cur:
        l = _ligne_autorisee(cur, user, ligne_id)
        if l["type_cycle"] != 3 and body.montant_collecte % int(l["mise_courante"]) != 0:
            raise HTTPException(status_code=422, detail=f"Le montant doit être un multiple de la mise ({int(l['mise_courante'])} F)")
        cur.execute("SELECT modifier_ligne_collecte(%s, %s)", (ligne_id, body.montant_collecte))
    return {"ok": True}


@router.delete("/collecte/lignes/{ligne_id}")
def supprimer_ligne(ligne_id: int, user: User = Depends(require("collecte:write"))):
    with tx(user.login) as cur:
        _ligne_autorisee(cur, user, ligne_id)
        cur.execute("SELECT supprimer_ligne_collecte(%s)", (ligne_id,))
    return {"ok": True}


class JourneeIn(BaseModel):
    date: dt.date
    agence_id: int | None = None
    motif: str | None = Field(default=None, max_length=300)


@router.post("/collecte/valider-journee", status_code=201)
def valider_journee(body: JourneeIn, user: User = Depends(require("collecte:admin"))):
    """Validation globale de la journée : les lignes du jour ne se modifient plus."""
    ag = agence_scope(user, body.agence_id)
    with tx(user.login) as cur:
        cur.execute("SELECT valider_journee_collecte(%s::smallint, %s, %s)", (ag, body.date, user.id))
    return collecte_du_jour(body.date, None, ag, user)


@router.post("/collecte/rouvrir-journee")
def rouvrir_journee(body: JourneeIn, user: User = Depends(require("collecte:admin"))):
    ag = agence_scope(user, body.agence_id)
    with tx(user.login) as cur:
        cur.execute("SELECT rouvrir_journee_collecte(%s::smallint, %s, %s, %s)", (ag, body.date, body.motif, user.id))
    return collecte_du_jour(body.date, None, ag, user)
