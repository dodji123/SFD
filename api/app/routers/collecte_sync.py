"""Collecte mobile : tournée de l'agent, synchronisation hors ligne et file de validation.

Le téléphone envoie ses opérations (nouveau client, ouverture de cycle, collecte, clôture) avec une clé unique générée
côté client. La synchronisation ne les écrit PAS dans les données vives : elle les met en attente (mf.operation_mobile,
statut `en_attente`) après contrôle de forme, de zone et d'agence. Un opérateur de saisie (permission
`collecte:valider`) les valide — elles sont alors rejouées dans l'ordre client → cycle → collecte → clôture — ou les rejette
avec un motif. Un client ou un cycle créé hors ligne est désigné par la clé de son opération ; la validation la remplace par
l'identifiant réel. Chaque opération est rejouée dans sa propre transaction : un refus n'empêche pas les autres.
"""
import datetime as dt
from typing import Literal

import psycopg2
from fastapi import APIRouter, Depends, HTTPException, Query
from psycopg2.extras import Json
from pydantic import BaseModel, Field, ValidationError

from ..auth import User, agence_scope, require
from ..db import all_rows, one_row, tx
from ..errors import message_pg
from .collecte import SITUATION, _type_du_cycle, _verifier_reste

router = APIRouter(prefix="/api", tags=["collecte-mobile"])

RANG = {"client": 1, "cycle": 2, "collecte": 3, "cloture": 4}
Ref = int | str          # identifiant réel, ou clé de l'opération locale qui a créé l'objet


# ------------------------------------------------------------------ contenu des opérations
class ClientP(BaseModel):
    nom: str = Field(min_length=1, max_length=200)
    telephone: str | None = Field(default=None, max_length=30)
    zone_id: int | None = None


class CycleP(BaseModel):
    client: Ref
    produit_id: int
    mise: int = Field(gt=0)
    date_debut: dt.date
    date_fin: dt.date
    type_cycle: Literal[1, 2, 3] | None = None     # libre à chaque cycle, sauf produit à type imposé
    objectif: int | None = Field(default=None, gt=0)
    nb_lignes_prevues: int | None = Field(default=None, gt=0, le=620)


class CollecteP(BaseModel):
    cycle: Ref
    date_collecte: dt.date
    montant_collecte: int


class ClotureP(BaseModel):
    cycle: Ref
    date: dt.date | None = None


PAYLOADS = {"client": ClientP, "cycle": CycleP, "collecte": CollecteP, "cloture": ClotureP}


class OperationIn(BaseModel):
    cle: str = Field(min_length=8, max_length=64, pattern=r"^[A-Za-z0-9_-]+$")
    type: Literal["client", "cycle", "collecte", "cloture"]
    payload: dict


class SyncIn(BaseModel):
    operations: list[OperationIn] = Field(min_length=1, max_length=200)


class ResultatOperation(BaseModel):
    cle: str
    statut: Literal["recue", "doublon", "refusee"]
    etat: str | None = None              # état dans la file de validation (en_attente / validee / rejetee)
    code: str | None = None
    motif: str | None = None


class SyncOut(BaseModel):
    date_serveur: dt.date
    resultats: list[ResultatOperation]


class Refus(Exception):
    def __init__(self, code: str, motif: str, differee: bool = False):
        super().__init__(motif)
        self.code, self.motif, self.differee = code, motif, differee


def _code_depuis_message(msg: str) -> str:
    """Rattache un message du schéma (RAISE EXCEPTION) à un code stable."""
    m = msg.lower()
    if "clos" in m and "saisie refusée" in m:
        return "cycle_clos"
    if "après la fin du cycle" in m:
        return "hors_delai"
    if "antérieure au début" in m:
        return "avant_debut"
    if "au-delà du livret" in m:
        return "livret_plein"
    return "autre"


# ------------------------------------------------------------------ identité et zone de l'agent
def _identite(cur, user: User) -> tuple[int, int | None]:
    """(agent, collectrice) du compte. Seuls les comptes agent/collectrice liés à un agent utilisent le mobile."""
    agent, coll = user.agent_id, user.collectrice_id
    if agent is None and coll is not None:
        r = one_row(cur, "SELECT agent_id FROM collectrice WHERE id = %s", (coll,))
        agent = r["agent_id"] if r else None
    if agent is None:
        raise Refus("droit_agence", "Votre compte n'est lié à aucun agent de collecte")
    return agent, coll


def _zones_de(cur, agent_id: int, collectrice_id: int | None, agence_id: int) -> list[dict]:
    """Zones de l'agent : celles dont il est l'agent, ou affectées (affectation en cours) à sa collectrice."""
    return all_rows(
        cur,
        "SELECT z.id, z.code, z.libelle FROM zone z WHERE z.agence_id = %s AND (z.agent_id = %s OR EXISTS ("
        "  SELECT 1 FROM affectation_zone a JOIN collectrice k ON k.id = a.collectrice_id "
        "   WHERE a.zone_id = z.id AND (k.id = %s OR k.agent_id = %s) AND current_date >= a.date_debut "
        "     AND (a.date_fin IS NULL OR current_date <= a.date_fin))) ORDER BY z.code",
        (agence_id, agent_id, collectrice_id, agent_id))


def _agence_de(user: User) -> int:
    if user.agence_id is None:
        raise Refus("droit_agence", "Votre compte n'est lié à aucune agence")
    return user.agence_id


def _controler_cycle_reel(cur, cycle_id: int, agence_id: int, zones: set[int]) -> None:
    c = one_row(cur, "SELECT c.agence_id, cl.zone_id FROM cycle c JOIN client cl ON cl.id = c.client_id WHERE c.id = %s", (cycle_id,))
    if c is None or c["agence_id"] != agence_id:
        raise Refus("droit_agence", "Cycle introuvable ou hors de votre agence")
    if c["zone_id"] not in zones:
        raise Refus("hors_zone", "Ce cycle n'est pas dans votre zone")


def _controler_client_reel(cur, client_id: int, agence_id: int, zones: set[int]) -> None:
    c = one_row(cur, "SELECT agence_id, zone_id, actif FROM client WHERE id = %s", (client_id,))
    if c is None or c["agence_id"] != agence_id or not c["actif"]:
        raise Refus("droit_agence", "Client introuvable ou hors de votre agence")
    if c["zone_id"] not in zones:
        raise Refus("hors_zone", "Ce client n'est pas dans votre zone")


def _ref_locale(cur, ref: str, type_attendu: str, agent_id: int) -> dict:
    r = one_row(cur, "SELECT type, statut, resultat_id, agent_id FROM operation_mobile WHERE cle = %s", (ref,))
    if r is None or r["type"] != type_attendu or r["agent_id"] != agent_id:
        raise Refus("dependance", f"L'opération liée ({type_attendu}) est introuvable")
    return r


# ------------------------------------------------------------------ réception (mise en attente)
def _recevoir(user: User, op: OperationIn) -> ResultatOperation:
    with tx(user.login) as cur:
        deja = one_row(cur, "SELECT utilisateur_id, statut, code, motif FROM operation_mobile WHERE cle = %s", (op.cle,))
        if deja is not None:
            if deja["utilisateur_id"] != user.id:
                raise Refus("cle_conflit", "Cette clé d'opération appartient à un autre utilisateur")
            return ResultatOperation(cle=op.cle, statut="doublon", etat=deja["statut"], code=deja["code"], motif=deja["motif"])
        try:
            p = PAYLOADS[op.type](**op.payload)
        except (ValidationError, TypeError) as e:
            raise Refus("format", "Opération mal formée : " + (e.errors()[0]["msg"] if isinstance(e, ValidationError) else str(e))) from None
        agence = _agence_de(user)
        agent, coll = _identite(cur, user)
        if one_row(cur, "SELECT 1 AS x FROM agent WHERE id = %s AND agence_id = %s", (agent, agence)) is None:
            raise Refus("droit_agence", "Agent hors de votre agence")
        zones = {z["id"] for z in _zones_de(cur, agent, coll, agence)}
        if not zones:
            raise Refus("hors_zone", "Aucune zone ne vous est affectée")
        cycle_id = None
        if op.type == "client":
            if p.zone_id is not None and p.zone_id not in zones:
                raise Refus("hors_zone", "Cette zone n'est pas la vôtre")
            if p.zone_id is None and len(zones) > 1:
                raise Refus("hors_zone", "Précisez la zone du client")
        elif op.type == "cycle":
            if p.date_fin < p.date_debut:
                raise Refus("format", "La date de fin précède la date de début")
            if isinstance(p.client, int):
                _controler_client_reel(cur, p.client, agence, zones)
            else:
                _ref_locale(cur, p.client, "client", agent)
        else:
            if op.type == "collecte":
                if p.montant_collecte <= 0:
                    raise Refus("montant_invalide", "Le montant doit être positif")
                if p.date_collecte > dt.date.today():
                    raise Refus("date_future", "La date de collecte ne peut pas être dans le futur")
            if isinstance(p.cycle, int):
                _controler_cycle_reel(cur, p.cycle, agence, zones)
                cycle_id = p.cycle
            else:
                _ref_locale(cur, p.cycle, "cycle", agent)
        cur.execute(
            "INSERT INTO operation_mobile(cle, utilisateur_id, cycle_id, agence_id, agent_id, type, payload, rang) VALUES (%s,%s,%s,%s,%s,%s,%s,%s)",
            (op.cle, user.id, cycle_id, agence, agent, op.type, Json(p.model_dump(mode="json")), RANG[op.type]))
        return ResultatOperation(cle=op.cle, statut="recue", etat="en_attente")


def _agent_mobile(user: User = Depends(require("collecte:write"))) -> User:
    if user.role not in ("agent", "collectrice"):
        raise HTTPException(status_code=403, detail="Réservé aux agents et collectrices")
    return user


@router.get("/collecte/mobile/tournee")
def tournee(user: User = Depends(_agent_mobile)):
    """Tout ce que le téléphone met en cache : zones de l'agent, ses clients, leurs cycles en cours, produits, statut de ses opérations."""
    with tx() as cur:
        try:
            agent, coll = _identite(cur, user)
            agence = _agence_de(user)
        except Refus as r:
            raise HTTPException(status_code=403, detail=r.motif) from None
        zones = _zones_de(cur, agent, coll, agence)
        ids = [z["id"] for z in zones]
        clients = all_rows(cur, "SELECT id, numero, nom, telephone, zone_id FROM client WHERE actif AND zone_id = ANY(%s) ORDER BY nom, id", (ids,))
        cycles = all_rows(cur, SITUATION + "WHERE s.statut = 'en_cours' AND cl.zone_id = ANY(%s) ORDER BY cl.nom, s.cycle_id DESC", (ids,))
        produits = all_rows(cur, "SELECT id, code, libelle, type_cycle, nb_pages_livret FROM produit_epargne WHERE categorie = 'collecte' AND actif ORDER BY code")
        operations = all_rows(
            cur, "SELECT cle, type, statut, code, motif FROM operation_mobile WHERE utilisateur_id = %s AND recu_le > now() - interval '14 days'", (user.id,))
    return {"agent_id": agent, "zones": zones, "clients": clients, "cycles": cycles, "produits": produits, "operations": operations,
            "date_serveur": dt.date.today()}


@router.post("/collecte/sync")
def synchroniser(body: SyncIn, user: User = Depends(_agent_mobile)) -> SyncOut:
    """Met en attente de validation les opérations du téléphone (idempotent par clé). Réponse : un résultat par opération —
    `recue` (en attente de validation), `doublon` (déjà reçue, avec son état actuel) ou `refusee` (code + motif, à corriger)."""
    par_cle: dict[str, ResultatOperation] = {}
    for op in sorted(body.operations, key=lambda o: RANG[o.type]):       # un client avant son cycle, un cycle avant sa collecte
        try:
            par_cle[op.cle] = _recevoir(user, op)
        except Refus as r:
            par_cle[op.cle] = ResultatOperation(cle=op.cle, statut="refusee", code=r.code, motif=r.motif)
    return SyncOut(date_serveur=dt.date.today(), resultats=[par_cle[o.cle] for o in body.operations])   # dans l'ordre reçu


# ------------------------------------------------------------------ validation par l'opérateur
class ResultatValidation(BaseModel):
    cle: str
    statut: Literal["validee", "rejetee", "differee", "ignoree"]
    code: str | None = None
    motif: str | None = None


def _resoudre(cur, ref: Ref, type_attendu: str, agent_id: int) -> int:
    if isinstance(ref, int):
        return ref
    r = _ref_locale(cur, ref, type_attendu, agent_id)
    if r["statut"] == "en_attente":
        raise Refus("dependance_attente", f"En attente : l'opération liée ({type_attendu}) n'est pas encore validée", differee=True)
    if r["statut"] != "validee" or r["resultat_id"] is None:
        raise Refus("dependance", f"L'opération liée ({type_attendu}) a été rejetée")
    return r["resultat_id"]


def _rejouer(cur, op: dict, zones: set[int]) -> int:
    """Écrit l'opération dans les données vives. Retourne l'identifiant créé (client, cycle, ligne) ou celui du cycle clos."""
    p = PAYLOADS[op["type"]](**op["payload"])
    agence, agent = op["agence_id"], op["agent_id"]
    if op["type"] == "client":
        zone_id = p.zone_id if p.zone_id is not None else (next(iter(zones)) if len(zones) == 1 else None)
        if zone_id not in zones:
            raise Refus("hors_zone", "Zone du client hors des zones de l'agent")
        return one_row(cur, "INSERT INTO client(agence_id, zone_id, nom, telephone) VALUES (%s, %s, %s, %s) RETURNING id",
                       (agence, zone_id, p.nom, p.telephone))["id"]
    if op["type"] == "cycle":
        client_id = _resoudre(cur, p.client, "client", agent)
        _controler_client_reel(cur, client_id, agence, zones)
        prod = one_row(cur, "SELECT categorie, type_cycle, nb_pages_livret FROM produit_epargne WHERE id = %s AND actif", (p.produit_id,))
        if prod is None or prod["categorie"] != "collecte":
            raise Refus("produit_invalide", "Le produit doit être un produit de collecte actif")
        try:
            type_cycle = _type_du_cycle(cur, client_id, p.produit_id, prod["type_cycle"], p.type_cycle)
        except HTTPException as e:
            raise Refus("format", str(e.detail)) from None
        nb = p.nb_lignes_prevues or 31 * prod["nb_pages_livret"]
        objectif = p.objectif if p.objectif is not None else (p.mise * nb if type_cycle in (1, 2) else None)
        return one_row(
            cur,
            "INSERT INTO cycle(agence_id, client_id, produit_id, type_cycle, mise_initiale, mise_courante, objectif, nb_lignes_prevues, "
            "date_debut, date_fin) VALUES (%s,%s,%s,%s,%s,%s,%s,%s,%s,%s) RETURNING id",
            (agence, client_id, p.produit_id, type_cycle, p.mise, p.mise, objectif, nb, p.date_debut, p.date_fin))["id"]
    cycle_id = _resoudre(cur, p.cycle, "cycle", agent)
    _controler_cycle_reel(cur, cycle_id, agence, zones)
    if op["type"] == "cloture":
        cur.execute("SELECT cloturer_cycle(%s, COALESCE(%s, current_date))", (cycle_id, p.date))
        return cycle_id
    c = one_row(cur, "SELECT c.type_cycle, c.mise_courante, s.reste_a_collecter FROM cycle c "
                     "JOIN v_cycle_situation s ON s.cycle_id = c.id WHERE c.id = %s", (cycle_id,))
    if p.montant_collecte <= 0:
        raise Refus("montant_invalide", "Le montant doit être positif")
    if c["type_cycle"] != 3 and p.montant_collecte % int(c["mise_courante"]) != 0:
        raise Refus("montant_invalide", f"Le montant doit être un multiple de la mise ({int(c['mise_courante'])} F)")
    try:
        _verifier_reste(c, p.montant_collecte, 0)
    except HTTPException as e:
        raise Refus("depasse_reste", str(e.detail)) from None
    idx = one_row(cur, "SELECT COALESCE(max((page - 1) * 31 + no_ligne), 0) AS m FROM ligne_collecte WHERE cycle_id = %s", (cycle_id,))["m"] + 1
    ligne = one_row(cur, "INSERT INTO ligne_collecte(cycle_id, page, no_ligne, date_collecte, agent_id, montant_collecte) VALUES (%s,%s,%s,%s,%s,%s) RETURNING id",
                    (cycle_id, (idx - 1) // 31 + 1, (idx - 1) % 31 + 1, p.date_collecte, agent, p.montant_collecte))
    return ligne["id"]


def _valider_une(operateur: User, cle: str) -> ResultatValidation:
    try:
        with tx(operateur.login) as cur:
            op = one_row(cur, "SELECT * FROM operation_mobile WHERE cle = %s FOR UPDATE", (cle,))
            if op is None or not operateur.peut_agence(op["agence_id"]):
                return ResultatValidation(cle=cle, statut="ignoree", code="introuvable", motif="Opération introuvable")
            if op["statut"] != "en_attente":
                return ResultatValidation(cle=cle, statut="ignoree", code="deja_decidee", motif=f"Déjà {op['statut']}")
            acteur = one_row(cur, "SELECT collectrice_id FROM utilisateur WHERE id = %s", (op["utilisateur_id"],))
            zones = {z["id"] for z in _zones_de(cur, op["agent_id"], acteur["collectrice_id"] if acteur else None, op["agence_id"])}
            resultat = _rejouer(cur, op, zones)
            cur.execute("UPDATE operation_mobile SET statut = 'validee', decide_par = %s, decide_le = now(), resultat_id = %s, "
                        "ligne_id = CASE WHEN type = 'collecte' THEN %s END WHERE cle = %s", (operateur.id, resultat, resultat, cle))
            return ResultatValidation(cle=cle, statut="validee")
    except Refus as r:
        if r.differee:
            return ResultatValidation(cle=cle, statut="differee", code=r.code, motif=r.motif)
        code, motif = r.code, r.motif
    except psycopg2.Error as e:
        if e.pgcode not in ("P0001", "23514", "23502", "22003", "23505", "23503"):
            raise
        motif = message_pg(e)
        code = _code_depuis_message(motif)
    _marquer_rejet(operateur, [cle], motif, code)
    return ResultatValidation(cle=cle, statut="rejetee", code=code, motif=motif)


def _marquer_rejet(operateur: User, cles: list[str], motif: str, code: str = "rejet_operateur") -> int:
    with tx(operateur.login) as cur:
        cur.execute(
            "UPDATE operation_mobile SET statut = 'rejetee', code = %s, motif = %s, decide_par = %s, decide_le = now() "
            "WHERE cle = ANY(%s) AND statut = 'en_attente' AND agence_id = ANY(%s)",
            (code, motif, operateur.id, cles, operateur.agences if operateur.agences is not None else _toutes_agences(cur)))
        return cur.rowcount


def _toutes_agences(cur) -> list[int]:
    return [r["id"] for r in all_rows(cur, "SELECT id FROM agence")]


class ValiderIn(BaseModel):
    cles: list[str] = Field(min_length=1, max_length=500)


class RejeterIn(ValiderIn):
    motif: str = Field(min_length=5, max_length=300)


@router.post("/collecte/validations/valider")
def valider(body: ValiderIn, user: User = Depends(require("collecte:valider"))) -> dict:
    """Valide les opérations choisies, dans l'ordre client → cycle → collecte → clôture. Une opération que le schéma refuse
    (cycle clos, hors délai de grâce…) est rejetée avec le message de la base ; celle dont la dépendance attend encore est différée."""
    with tx() as cur:
        rows = all_rows(cur, "SELECT cle FROM operation_mobile WHERE cle = ANY(%s) ORDER BY rang, recu_le, cle", (body.cles,))
    return {"resultats": [_valider_une(user, r["cle"]) for r in rows]}


@router.post("/collecte/validations/rejeter")
def rejeter(body: RejeterIn, user: User = Depends(require("collecte:valider"))) -> dict:
    return {"rejetees": _marquer_rejet(user, body.cles, body.motif)}


@router.get("/collecte/validations")
def lister_validations(statut: Literal["en_attente", "validee", "rejetee"] | None = "en_attente", agent_id: int | None = None,
                       date: dt.date | None = None, agence_id: int | None = None, user: User = Depends(require("collecte:valider"))):
    """Opérations reçues des téléphones, avec un résumé lisible ; à grouper par agent et par jour de réception."""
    ag = agence_scope(user, agence_id)
    with tx() as cur:
        ops = all_rows(
            cur,
            "SELECT o.cle, o.type, o.statut, o.code, o.motif, o.payload, o.agent_id, a.nom AS agent, a.matricule, o.recu_le, o.recu_le::date AS jour, "
            "       o.decide_le, u.login AS decide_par FROM operation_mobile o JOIN agent a ON a.id = o.agent_id LEFT JOIN utilisateur u ON u.id = o.decide_par "
            "WHERE o.agence_id = %s AND (%s::text IS NULL OR o.statut = %s) AND (%s::int IS NULL OR o.agent_id = %s) "
            "  AND (%s::date IS NULL OR o.recu_le::date = %s) ORDER BY o.recu_le::date DESC, o.agent_id, o.rang, o.recu_le LIMIT 1000",
            (ag, statut, statut, agent_id, agent_id, date, date))
        _resumer(cur, ops)
    return ops


def _resumer(cur, ops: list[dict]) -> None:
    clients = {r["id"]: r["nom"] for r in all_rows(cur, "SELECT id, nom FROM client WHERE id = ANY(%s)", (list({o["payload"].get("client") for o in ops if isinstance(o["payload"].get("client"), int)}),))}
    cycles = {r["id"]: f"{r['numero']} ({r['nom']})" for r in all_rows(
        cur, "SELECT c.id, c.numero, cl.nom FROM cycle c JOIN client cl ON cl.id = c.client_id WHERE c.id = ANY(%s)",
        (list({o["payload"].get("cycle") for o in ops if isinstance(o["payload"].get("cycle"), int)}),))}
    produits = {r["id"]: r["code"] for r in all_rows(cur, "SELECT id, code FROM produit_epargne")}
    locaux = {r["cle"]: r for r in all_rows(cur, "SELECT cle, type, payload FROM operation_mobile WHERE cle = ANY(%s)",
                                            (list({str(v) for o in ops for k, v in o["payload"].items() if k in ("client", "cycle") and isinstance(v, str)}),))}

    def client_label(ref) -> str:
        if isinstance(ref, int):
            return clients.get(ref, f"client {ref}")
        return "« " + str(locaux.get(ref, {"payload": {}})["payload"].get("nom", "?")) + " » (nouveau)"

    def cycle_label(ref) -> str:
        if isinstance(ref, int):
            return cycles.get(ref, f"cycle {ref}")
        loc = locaux.get(ref)
        return f"nouveau cycle de {client_label(loc['payload'].get('client'))}" if loc else "nouveau cycle"

    for o in ops:
        p = o["payload"]
        if o["type"] == "client":
            o["resume"] = f"Nouveau client « {p.get('nom')} »" + (f" · {p['telephone']}" if p.get("telephone") else "")
        elif o["type"] == "cycle":
            o["resume"] = (f"Ouverture de cycle pour {client_label(p.get('client'))} · {produits.get(p.get('produit_id'), '?')} · "
                           f"type {p.get('type_cycle') or 'du produit'} · mise {p.get('mise')} F · {p.get('date_debut')} → {p.get('date_fin')}")
        elif o["type"] == "collecte":
            o["resume"] = f"Collecte de {p.get('montant_collecte')} F le {p.get('date_collecte')} — {cycle_label(p.get('cycle'))}"
        else:
            o["resume"] = f"Clôture de {cycle_label(p.get('cycle'))}"
