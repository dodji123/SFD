"""Collecte : cycles de tontine, livret (31 lignes par page), mises, clôtures."""
import datetime as dt

from typing import Literal

from fastapi import APIRouter, Depends, HTTPException, Query
from pydantic import BaseModel, Field

from ..auth import User, agence_filter, agence_scope, require, verifier_agence
from ..db import all_rows, one_row, tx

router = APIRouter(prefix="/api", tags=["collecte"])

SITUATION = (
    "SELECT s.cycle_id AS id, s.agence_id, s.numero, s.client_id, cl.nom AS client, s.type_cycle, s.statut, "
    "       c.produit_id, pe.code AS produit, pe.libelle AS produit_libelle, delai_grace_cycle(c.id) AS delai_grace, date_limite_cycle(c.id) AS date_limite, "
    "       c.mise_initiale, c.mise_courante, c.mise_finale, c.objectif, c.nb_lignes_prevues, c.date_debut, c.date_fin, c.date_cloture, "
    "       s.nb_lignes, s.montant_collecte, s.montant_previsionnel, s.reste_a_collecter, s.mise_cycle, s.net, "
    "       mf.solde_disponible_cycle(s.cycle_id) AS solde_disponible "
    "FROM v_cycle_situation s JOIN cycle c ON c.id = s.cycle_id JOIN client cl ON cl.id = s.client_id "
    "JOIN produit_epargne pe ON pe.id = c.produit_id "
)


ORDRES = {"recent": "s.cycle_id DESC", "produit": "pe.code, cl.nom, s.cycle_id DESC", "client": "cl.nom, s.cycle_id DESC", "fin": "c.date_fin, s.cycle_id DESC"}


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
    type_cycle: Literal[1, 2, 3] | None = None   # choisi à chaque nouveau cycle (ignoré si le produit impose un type)


@router.get("/cycles")
def lister_cycles(
    client_id: int | None = None, statut: str | None = None, agence_id: int | None = None, q: str | None = None,
    produit_id: int | None = None, tri: str = Query("recent", pattern="^(recent|produit|client|fin)$"),
    limit: int = Query(100, ge=1, le=500), offset: int = Query(0, ge=0),
    user: User = Depends(require("collecte:read")),
):
    ag = agence_filter(user, agence_id)
    with tx() as cur:
        return all_rows(
            cur,
            SITUATION + "WHERE (%s::int IS NULL OR s.agence_id = %s) AND (%s::int IS NULL OR s.client_id = %s) "
            "AND (%s::text IS NULL OR s.statut = %s) AND (%s::int IS NULL OR c.produit_id = %s) "
            "AND (%s::text IS NULL OR s.numero ILIKE '%%' || %s || '%%' OR cl.nom ILIKE '%%' || %s || '%%' "
            "     OR cl.numero ILIKE '%%' || %s || '%%' OR pe.code ILIKE '%%' || %s || '%%' OR pe.libelle ILIKE '%%' || %s || '%%') "
            "ORDER BY " + ORDRES[tri] + " LIMIT %s OFFSET %s",
            (ag, ag, client_id, client_id, statut, statut, produit_id, produit_id, q, q, q, q, q, q, limit, offset),
        )


def _type_du_cycle(cur, client_id: int, produit_id: int, type_produit: int | None, demande: int | None) -> int:
    """Type imposé par le produit, sinon celui qu'on choisit pour ce cycle (libre à chaque cycle)."""
    if demande is not None:
        return demande
    if type_produit is not None:
        return type_produit
    raise HTTPException(status_code=422, detail="Choisissez le type de cycle (1, 2 ou 3)")


@router.get("/cycles/type-propose")
def type_propose(client_id: int, produit_id: int, user: User = Depends(require("collecte:read"))):
    """Type de cycle imposé par le produit, ou null : il se choisit alors librement pour chaque cycle."""
    with tx() as cur:
        verifier_agence(cur, user, "client", client_id)
        p = one_row(cur, "SELECT type_cycle FROM produit_epargne WHERE id = %s", (produit_id,))
        if p is None:
            raise HTTPException(status_code=404, detail="Produit introuvable")
        return {"type_cycle": p["type_cycle"], "impose_par": None}   # suggestion seulement : le type se choisit à chaque cycle


@router.post("/cycles", status_code=201)
def creer_cycle(body: CycleIn, user: User = Depends(require("collecte:write"))):
    with tx(user.login) as cur:
        ag = verifier_agence(cur, user, "client", body.client_id)
        if body.agence_id is not None and body.agence_id != ag:
            raise HTTPException(status_code=422, detail="Le client n'appartient pas à cette agence")
        p = one_row(cur, "SELECT categorie, type_cycle, nb_pages_livret FROM produit_epargne WHERE id = %s AND actif", (body.produit_id,))
        if p is None or p["categorie"] != "collecte":
            raise HTTPException(status_code=422, detail="Le produit doit être un produit de collecte")
        type_cycle = _type_du_cycle(cur, body.client_id, body.produit_id, p["type_cycle"], body.type_cycle)
        nb = body.nb_lignes_prevues or 31 * p["nb_pages_livret"]
        objectif = body.objectif if body.objectif is not None else (body.mise * nb if type_cycle in (1, 2) else None)
        cid = one_row(
            cur,
            "INSERT INTO cycle(agence_id, numero, client_id, produit_id, type_cycle, mise_initiale, mise_courante, objectif, "
            "nb_lignes_prevues, date_debut, date_fin) VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s) RETURNING id",
            (ag, body.numero, body.client_id, body.produit_id, type_cycle, body.mise, body.mise, objectif, nb,
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
        ag = verifier_agence(cur, user, "cycle", cycle_id)
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
            if one_row(cur, "SELECT 1 AS x FROM agent WHERE id = %s AND agence_id = %s", (agent, ag)) is None:
                raise HTTPException(status_code=422, detail="L'agent n'appartient pas à l'agence du cycle")
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


@router.get("/collecte/client")
def client_par_numero(suffixe: str, agence_id: int | None = None, date: dt.date | None = None, user: User = Depends(require("collecte:read"))):
    """Client désigné par son numéro d'ordre (formulaire « nouvelle mise »)."""
    ag = agence_scope(user, agence_id)
    with tx() as cur:
        return trouver_client(cur, ag, suffixe, date)


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


def _verifier_reste(c: dict, montant: int, deja: int) -> None:
    """Le montant saisi ne dépasse pas l'encours de collecte (sauf type 3, collecte libre). `deja` : ancien montant de la ligne corrigée."""
    if c["type_cycle"] != 3 and c["reste_a_collecter"] is not None and montant > c["reste_a_collecter"] + deja:
        raise HTTPException(status_code=422, detail=f"Le montant dépasse l'encours à collecter ({max(int(c['reste_a_collecter']) + deja, 0)} F)")


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
        c = one_row(cur, "SELECT c.type_cycle, c.mise_courante, c.numero, s.reste_a_collecter FROM cycle c JOIN v_cycle_situation s ON s.cycle_id = c.id WHERE c.id = %s", (body.cycle_id,))
    if c["type_cycle"] != 3 and body.montant_collecte % int(c["mise_courante"]) != 0:
        raise HTTPException(status_code=422, detail=f"Le montant doit être un multiple de la mise ({int(c['mise_courante'])} F)")
    _verifier_reste(c, body.montant_collecte, 0)
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


class SelectionIn(BaseModel):
    cycle_ids: list[int] = Field(min_length=1, max_length=200)
    date: dt.date | None = None


@router.post("/cycles/cloturer-selection")
def cloturer_selection(body: SelectionIn, user: User = Depends(require("collecte:admin"))):
    """Clôture manuelle de plusieurs mises (cycles en cours) à la date choisie ; un cycle refusé n'empêche pas les autres."""
    clotures, refuses = [], []
    for cid in body.cycle_ids:
        try:
            with tx(user.login) as cur:
                verifier_agence(cur, user, "cycle", cid)
                cur.execute("SELECT cloturer_cycle(%s, COALESCE(%s, current_date))", (cid, body.date))
            clotures.append(cid)
        except HTTPException as e:
            refuses.append({"cycle_id": cid, "motif": e.detail})
        except Exception as e:  # noqa: BLE001 — règle métier de la base : message du schéma
            refuses.append({"cycle_id": cid, "motif": str(e).splitlines()[0][:200]})
    return {"clotures": clotures, "refuses": refuses}


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
    """Tableau des collectes saisies un jour, avec l'état de validation de la journée.
    Un agent ne voit que ses collectes ; une collectrice seulement celles de sa zone en cours ; les autres, l'agence (ou un agent)."""
    ag = agence_scope(user, agence_id)
    zone = None
    if user.agent_id is not None:
        agent_id = user.agent_id
    elif user.collectrice_id is not None:
        with tx() as cur:
            aff = one_row(cur, "SELECT zone_id FROM affectation_zone WHERE collectrice_id = %s AND date_fin IS NULL "
                               "ORDER BY date_debut DESC LIMIT 1", (user.collectrice_id,))
        if aff is None:
            return {"date": date, "agence_id": ag, "lignes": [], "total": 0}
        zone = aff["zone_id"]
    with tx() as cur:
        lignes = all_rows(
            cur,
            "SELECT l.id, l.cycle_id, c.numero AS souscription, cl.numero AS client_numero, cl.nom AS client, p.code AS produit, "
            "       z.id AS zone_id, z.code AS zone_code, z.libelle AS zone, "
            "       c.type_cycle, c.mise_courante AS mise, l.montant_collecte, l.agent_id, a.matricule AS agent, "
            "       v.id IS NOT NULL AS versee "
            "FROM ligne_collecte l JOIN cycle c ON c.id = l.cycle_id JOIN client cl ON cl.id = c.client_id "
            "JOIN produit_epargne p ON p.id = c.produit_id LEFT JOIN agent a ON a.id = l.agent_id "
            "LEFT JOIN zone z ON z.id = cl.zone_id "
            "LEFT JOIN versement_agent v ON v.agent_id = l.agent_id AND v.date_tournee = l.date_collecte "
            "WHERE c.agence_id = %s AND l.date_collecte = %s AND l.origine = 'collecte' "
            "AND (%s::int IS NULL OR l.agent_id = %s) AND (%s::int IS NULL OR z.id = %s) ORDER BY l.id DESC",
            (ag, date, agent_id, agent_id, zone, zone),
        )
        ouverte = one_row(cur, "SELECT date_operation FROM date_operation WHERE statut = 'ouverte'")
    # une collecte se corrige seulement sur la date d'opération ouverte, et tant que la tournée n'est pas versée
    jour_ouvert = ouverte is not None and ouverte["date_operation"] == date
    for l in lignes:
        l["modifiable"] = jour_ouvert and not l["versee"]
    return {"date": date, "agence_id": ag, "lignes": lignes, "total": sum(l["montant_collecte"] for l in lignes)}


def _ligne_autorisee(cur, user: User, ligne_id: int) -> dict:
    l = one_row(cur, "SELECT l.id, l.agent_id, l.montant_collecte, c.agence_id, c.type_cycle, c.mise_courante, s.reste_a_collecter FROM ligne_collecte l "
                     "JOIN cycle c ON c.id = l.cycle_id JOIN v_cycle_situation s ON s.cycle_id = c.id WHERE l.id = %s", (ligne_id,))
    if l is None or not user.peut_agence(l["agence_id"]):
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
        _verifier_reste(l, body.montant_collecte, int(l["montant_collecte"]))
        cur.execute("SELECT modifier_ligne_collecte(%s, %s)", (ligne_id, body.montant_collecte))
    return {"ok": True}


@router.delete("/collecte/lignes/{ligne_id}")
def supprimer_ligne(ligne_id: int, motif: str = Query(min_length=5, max_length=300), user: User = Depends(require("collecte:write"))):
    """Suppression : la ligne disparaît des écrans et des calculs ; qui, quand, pourquoi et son contenu sont conservés pour l'audit."""
    with tx(user.login) as cur:
        _ligne_autorisee(cur, user, ligne_id)
        cur.execute("SELECT set_config('mf.motif_suppression', %s, true)", (motif,))
        cur.execute("SELECT supprimer_ligne_collecte(%s)", (ligne_id,))
    return {"ok": True}


class JourneeIn(BaseModel):
    date: dt.date
    agence_id: int | None = None
    motif: str | None = Field(default=None, max_length=300)


# ---------------------------------------------------------------- prolongation d'un cycle (avec autorisation)
class ProlongationIn(BaseModel):
    nouvelle_fin: dt.date
    motif: str = Field(min_length=10, max_length=500)


PROLONGATION_SQL = (
    "SELECT p.*, c.numero AS cycle, cl.nom AS client, c.agence_id, pe.code AS produit, ud.nom AS demande_par_nom, ua.nom AS decide_par_nom "
    "FROM prolongation_cycle p JOIN cycle c ON c.id = p.cycle_id JOIN client cl ON cl.id = c.client_id JOIN produit_epargne pe ON pe.id = c.produit_id "
    "LEFT JOIN utilisateur ud ON ud.id = p.demande_par LEFT JOIN utilisateur ua ON ua.id = p.decide_par "
)


@router.post("/cycles/{cycle_id}/prolongation", status_code=201)
def demander_prolongation(cycle_id: int, body: ProlongationIn, user: User = Depends(require("collecte:write"))):
    with tx(user.login) as cur:
        verifier_agence(cur, user, "cycle", cycle_id)
        c = one_row(cur, "SELECT date_fin FROM cycle WHERE id = %s", (cycle_id,))
        r = one_row(cur, "INSERT INTO prolongation_cycle(cycle_id, ancienne_fin, nouvelle_fin, motif, demande_par) VALUES (%s, %s, %s, %s, %s) RETURNING id",
                    (cycle_id, c["date_fin"], body.nouvelle_fin, body.motif, user.id))
        return one_row(cur, PROLONGATION_SQL + "WHERE p.id = %s", (r["id"],))


@router.get("/prolongations")
def lister_prolongations(statut: str | None = None, cycle_id: int | None = None, agence_id: int | None = None, user: User = Depends(require("collecte:read"))):
    ag = agence_filter(user, agence_id)
    with tx() as cur:
        return all_rows(cur, PROLONGATION_SQL + "WHERE (%s::int IS NULL OR c.agence_id = %s) AND (%s::text IS NULL OR p.statut = %s) AND (%s::int IS NULL OR p.cycle_id = %s) "
                                                 "ORDER BY p.id DESC LIMIT 200", (ag, ag, statut, statut, cycle_id, cycle_id))


class DecisionProlongationIn(BaseModel):
    autorise: bool
    commentaire: str | None = Field(default=None, max_length=500)


@router.post("/prolongations/{prolongation_id}/decider")
def decider_prolongation(prolongation_id: int, body: DecisionProlongationIn, user: User = Depends(require("cycle:prolongation-decider"))):
    with tx(user.login) as cur:
        p = one_row(cur, "SELECT cycle_id, statut FROM prolongation_cycle WHERE id = %s", (prolongation_id,))
        if p is None:
            raise HTTPException(status_code=404, detail="Introuvable")
        verifier_agence(cur, user, "cycle", p["cycle_id"])
        if p["statut"] != "demandee":
            raise HTTPException(status_code=422, detail=f"Cette demande est déjà {p['statut']}")
        cur.execute("UPDATE prolongation_cycle SET statut = %s, decide_par = %s, commentaire = %s WHERE id = %s",
                    ("autorisee" if body.autorise else "refusee", user.id, body.commentaire, prolongation_id))
        return one_row(cur, PROLONGATION_SQL + "WHERE p.id = %s", (prolongation_id,))


@router.post("/prolongations/{prolongation_id}/annuler")
def annuler_prolongation(prolongation_id: int, user: User = Depends(require("collecte:write"))):
    with tx(user.login) as cur:
        p = one_row(cur, "SELECT cycle_id FROM prolongation_cycle WHERE id = %s", (prolongation_id,))
        if p is None:
            raise HTTPException(status_code=404, detail="Introuvable")
        verifier_agence(cur, user, "cycle", p["cycle_id"])
        cur.execute("UPDATE prolongation_cycle SET statut = 'annulee' WHERE id = %s AND statut = 'demandee'", (prolongation_id,))
        if cur.rowcount == 0:
            raise HTTPException(status_code=422, detail="Seule une demande en attente s'annule")
        return one_row(cur, PROLONGATION_SQL + "WHERE p.id = %s", (prolongation_id,))
