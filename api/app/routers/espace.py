"""Espace client sécurisé.

Deux routeurs :
 - `router`  (/api/espace)  : utilisé par le client lui-même. Connexion en deux temps (numéro + PIN, puis code SMS à
   usage unique), session courte, jeton de type « client » (refusé par toutes les routes du personnel), verrouillage
   après échecs, limitation de débit par adresse IP, journal des accès non modifiable, numéros masqués. Le client ne
   voit que ses propres données : son identifiant vient du jeton, jamais de la requête.
 - `admin_router` (/api/clients/...) : le personnel recueille les consentements, ouvre ou bloque l'accès et consulte le journal.
Les règles d'ouverture (KYC complet, consentement, absence d'alerte de sanction, téléphone) sont dans la base (module 18)."""
import collections
import datetime as dt
import hashlib
import hmac
import re
import secrets
import time
from typing import Literal

import jwt
from fastapi import APIRouter, Depends, Header, HTTPException, Request
from pydantic import BaseModel, Field

from .. import sms
from ..auth import ALGO, DUMMY_HASH, User, hash_password, require, verifier_agence, verify_password
from ..config import settings
from ..db import all_rows, one_row, tx

router = APIRouter(prefix="/api/espace", tags=["espace-client"])
admin_router = APIRouter(prefix="/api", tags=["espace-client-admin"])

MSG_ECHEC = "Identifiants incorrects"

# ------------------------------------------------------------------ outils de sécurité
_tentatives: dict[str, collections.deque] = collections.defaultdict(collections.deque)


def _limiter(ip: str) -> None:
    """Limitation de débit en mémoire par adresse IP (à compléter par le pare-feu / proxy en production)."""
    maintenant = time.monotonic()
    q = _tentatives[ip]
    while q and maintenant - q[0] > 600:
        q.popleft()
    if len(q) >= settings.ip_max_attempts_10min:
        raise HTTPException(status_code=429, detail="Trop de tentatives depuis cette adresse, réessayez plus tard")
    q.append(maintenant)


def _ip(request: Request) -> str:
    return request.client.host if request.client else "?"


def _journal(cur, client_id: int | None, evenement: str, request: Request, numero: str | None = None, detail: str | None = None) -> None:
    cur.execute(
        "INSERT INTO acces_client_log(client_id, numero_saisi, evenement, ip, appareil, detail) VALUES (%s,%s,%s,%s,%s,%s)",
        (client_id, (numero or "")[:40] or None, evenement, _ip(request), (request.headers.get("user-agent") or "")[:200], detail),
    )


def _hmac_code(client_id: int, code: str) -> str:
    return hmac.new(settings.secret().encode(), f"{client_id}:{code}".encode(), hashlib.sha256).hexdigest()


def masque(numero: str | None) -> str:
    return "****" + numero[-4:] if numero and len(numero) > 4 else "****"


def pin_faible(pin: str) -> str | None:
    """Retourne la raison du refus, ou None si le PIN est acceptable."""
    if not re.fullmatch(r"\d{6,8}", pin):
        return "Le PIN comporte 6 à 8 chiffres"
    if len(set(pin)) == 1:
        return "Le PIN ne peut pas répéter le même chiffre"
    suite = "0123456789"
    if pin in suite or pin in suite[::-1] or pin in ("123123", "121212", "112233", "696969", "159753"):
        return "Ce PIN est trop simple (suite ou motif courant)"
    return None


def generer_pin() -> str:
    while True:
        pin = "".join(secrets.choice("0123456789") for _ in range(6))
        if pin_faible(pin) is None:
            return pin


def _creer_jeton(client_id: int, provisoire: bool) -> str:
    exp = dt.datetime.now(dt.timezone.utc) + dt.timedelta(minutes=settings.client_token_minutes)
    return jwt.encode({"sub": str(client_id), "typ": "client", "prov": provisoire, "exp": exp}, settings.secret(), algorithm=ALGO)


# ------------------------------------------------------------------ dépendances client
def client_courant(authorization: str | None = Header(default=None)) -> dict:
    erreur = HTTPException(status_code=401, detail="Session invalide ou expirée", headers={"WWW-Authenticate": "Bearer"})
    if not authorization or not authorization.lower().startswith("bearer "):
        raise erreur
    try:
        payload = jwt.decode(authorization.split(" ", 1)[1].strip(), settings.secret(), algorithms=[ALGO])
        client_id = int(payload["sub"])
    except (jwt.PyJWTError, KeyError, ValueError):
        raise erreur
    if payload.get("typ") != "client":                    # un jeton du personnel n'ouvre pas l'espace client
        raise erreur
    with tx() as cur:
        c = one_row(cur, "SELECT c.id, c.nom, c.numero, c.telephone, c.agence_id, a.pin_provisoire, a.derniere_connexion "
                         "FROM client c JOIN client_acces a ON a.client_id = c.id WHERE c.id = %s AND c.actif AND a.actif", (client_id,))
    if c is None:                                          # accès bloqué ou consentement retiré : effet immédiat
        raise erreur
    return c


def client_pret(c: dict = Depends(client_courant)) -> dict:
    if c["pin_provisoire"]:
        raise HTTPException(status_code=403, detail="Changez votre PIN provisoire avant de continuer")
    return c


# ------------------------------------------------------------------ connexion
class ConnexionIn(BaseModel):
    numero: str = Field(min_length=3, max_length=40)
    pin: str = Field(min_length=1, max_length=20)


def _acces(cur, numero: str):
    lignes = all_rows(cur, "SELECT id, nom, telephone, actif FROM client WHERE numero = %s LIMIT 2", (numero,))
    c = lignes[0] if len(lignes) == 1 else None            # numéro ambigu entre agences : refus générique
    a = None
    if c:
        a = one_row(cur, "SELECT *, COALESCE(verrouille_jusqua > now(), false) AS verrouille FROM client_acces WHERE client_id = %s FOR UPDATE", (c["id"],))
    return c, a


@router.post("/connexion")
def connexion(body: ConnexionIn, request: Request):
    """Étape 1 : numéro client + PIN. Si exact, un code à usage unique est envoyé par SMS."""
    _limiter(_ip(request))
    verdict, reponse = "echec", None
    with tx() as cur:
        c, a = _acces(cur, body.numero)
        ok = verify_password(body.pin, a["pin_hash"] if a else DUMMY_HASH)      # toujours un calcul : pas d'énumération par le temps
        if not c or not a or not a["actif"] or not c["actif"]:
            _journal(cur, c["id"] if c else None, "echec_connexion", request, body.numero, "accès inconnu ou inactif")
        elif a["verrouille"]:
            verdict = "verrouille"
            _journal(cur, c["id"], "connexion_verrouillee", request, body.numero)
        elif not ok:
            cur.execute(
                "UPDATE client_acces SET echecs = echecs + 1, maj_le = now(), "
                "  verrouille_jusqua = CASE WHEN echecs + 1 >= %s THEN now() + make_interval(mins => %s) ELSE verrouille_jusqua END "
                "WHERE client_id = %s RETURNING echecs", (settings.client_max_failed_pin, settings.lockout_minutes, c["id"]))
            n = cur.fetchone()["echecs"]
            _journal(cur, c["id"], "echec_pin", request, body.numero, f"échec {n}")
            if n >= settings.client_max_failed_pin:
                _journal(cur, c["id"], "verrouillage", request, body.numero, f"{settings.lockout_minutes} minutes")
        else:
            recents = one_row(cur, "SELECT count(*) AS n FROM client_otp WHERE client_id = %s AND cree_le > now() - interval '15 minutes'", (c["id"],))["n"]
            if recents >= settings.otp_max_per_15min:
                verdict = "trop_de_codes"
                _journal(cur, c["id"], "otp_limite", request, body.numero)
            else:
                code = "".join(secrets.choice("0123456789") for _ in range(6))
                cur.execute("INSERT INTO client_otp(client_id, code_hash, expire_le) VALUES (%s,%s, now() + make_interval(mins => %s))",
                            (c["id"], _hmac_code(c["id"], code), settings.otp_minutes))
                sms.envoyer(c["telephone"], f"Votre code SFD : {code} (valable {settings.otp_minutes} min). Ne le communiquez à personne.")
                cur.execute("INSERT INTO sms_outbox(client_id, telephone, type, message, statut, envoye_le) VALUES (%s,%s,'otp','Code de connexion envoyé','envoye', now())",
                            (c["id"], c["telephone"]))
                _journal(cur, c["id"], "otp_envoye", request, body.numero)
                verdict = "ok"
                reponse = {"etape": "otp", "telephone": sms.masquer_telephone(c["telephone"]), "expire_dans": settings.otp_minutes * 60}
                if settings.env != "prod" and settings.sms_mode == "console":
                    reponse["otp_dev"] = code               # développement uniquement : jamais renvoyé en production
    if verdict == "verrouille":
        raise HTTPException(status_code=429, detail="Trop de tentatives : accès verrouillé temporairement")
    if verdict == "trop_de_codes":
        raise HTTPException(status_code=429, detail="Trop de codes demandés, réessayez dans quelques minutes")
    if verdict != "ok":
        raise HTTPException(status_code=401, detail=MSG_ECHEC)
    return reponse


class OtpIn(BaseModel):
    numero: str = Field(min_length=3, max_length=40)
    code: str = Field(pattern=r"^\d{6}$")


@router.post("/otp")
def verifier_otp(body: OtpIn, request: Request):
    """Étape 2 : code reçu par SMS ; ouvre une session courte."""
    _limiter(_ip(request))
    jeton, provisoire, ok = None, False, False
    with tx() as cur:
        c, a = _acces(cur, body.numero)
        o = None
        if c and a and a["actif"] and c["actif"] and not a["verrouille"]:
            o = one_row(cur, "SELECT * FROM client_otp WHERE client_id = %s AND NOT utilise AND expire_le > now() ORDER BY id DESC LIMIT 1 FOR UPDATE", (c["id"],))
        if o is None or o["tentatives"] >= settings.otp_max_attempts:
            _journal(cur, c["id"] if c else None, "echec_otp", request, body.numero, "aucun code valide")
        elif not hmac.compare_digest(o["code_hash"], _hmac_code(c["id"], body.code)):
            cur.execute("UPDATE client_otp SET tentatives = tentatives + 1, utilise = (tentatives + 1 >= %s) WHERE id = %s", (settings.otp_max_attempts, o["id"]))
            _journal(cur, c["id"], "echec_otp", request, body.numero, "code incorrect")
        else:
            cur.execute("UPDATE client_otp SET utilise = true WHERE id = %s", (o["id"],))
            cur.execute("UPDATE client_acces SET echecs = 0, verrouille_jusqua = NULL, derniere_connexion = now() WHERE client_id = %s", (c["id"],))
            _journal(cur, c["id"], "connexion_ok", request, body.numero)
            ok, provisoire = True, a["pin_provisoire"]
            jeton = _creer_jeton(c["id"], provisoire)
    if not ok:
        raise HTTPException(status_code=401, detail="Code incorrect ou expiré")
    return {"access_token": jeton, "token_type": "bearer", "pin_provisoire": provisoire, "expire_dans": settings.client_token_minutes * 60}


class PinIn(BaseModel):
    ancien: str = Field(min_length=1, max_length=20)
    nouveau: str = Field(min_length=1, max_length=20)


@router.post("/pin", status_code=204)
def changer_pin(body: PinIn, request: Request, c: dict = Depends(client_courant)):
    raison = pin_faible(body.nouveau)
    if raison:
        raise HTTPException(status_code=422, detail=raison)
    if body.nouveau == body.ancien:
        raise HTTPException(status_code=422, detail="Le nouveau PIN doit être différent de l'ancien")
    with tx() as cur:
        a = one_row(cur, "SELECT pin_hash FROM client_acces WHERE client_id = %s FOR UPDATE", (c["id"],))
        if not verify_password(body.ancien, a["pin_hash"]):
            _journal(cur, c["id"], "echec_changement_pin", request)
            cur.execute("UPDATE client_acces SET echecs = echecs + 1 WHERE client_id = %s", (c["id"],))
            ok = False
        else:
            cur.execute("UPDATE client_acces SET pin_hash = %s, pin_provisoire = false, maj_le = now() WHERE client_id = %s", (hash_password(body.nouveau), c["id"]))
            _journal(cur, c["id"], "pin_change", request)
            ok = True
    if not ok:
        raise HTTPException(status_code=403, detail="Ancien PIN incorrect")


@router.post("/deconnexion", status_code=204)
def deconnexion(request: Request, c: dict = Depends(client_courant)):
    with tx() as cur:
        _journal(cur, c["id"], "deconnexion", request)


# ------------------------------------------------------------------ consultation (données du client connecté uniquement)
def _consulte(c: dict, request: Request, objet: str) -> None:
    with tx() as cur:
        _journal(cur, c["id"], "consultation", request, detail=objet)


@router.get("/moi")
def moi(c: dict = Depends(client_courant)):
    return {"nom": c["nom"], "numero": c["numero"], "telephone": sms.masquer_telephone(c["telephone"]),
            "pin_provisoire": c["pin_provisoire"], "derniere_connexion": c["derniere_connexion"]}


@router.get("/comptes")
def mes_comptes(request: Request, c: dict = Depends(client_pret)):
    _consulte(c, request, "comptes")
    with tx() as cur:
        lignes = all_rows(
            cur, "SELECT ce.id, ce.numero, ce.statut, p.libelle AS produit, v.solde, solde_disponible(ce.id) AS disponible "
                 "FROM compte_epargne ce JOIN produit_epargne p ON p.id = ce.produit_id JOIN v_solde_compte_epargne v ON v.compte_id = ce.id "
                 "WHERE ce.client_id = %s ORDER BY ce.id", (c["id"],))
    for l in lignes:
        l["numero"] = masque(l["numero"])
    return lignes


@router.get("/comptes/{compte_id}/mouvements")
def mes_mouvements(compte_id: int, request: Request, c: dict = Depends(client_pret)):
    with tx() as cur:
        if one_row(cur, "SELECT 1 AS x FROM compte_epargne WHERE id = %s AND client_id = %s", (compte_id, c["id"])) is None:
            raise HTTPException(status_code=404, detail="Introuvable")
        _journal(cur, c["id"], "consultation", request, detail=f"mouvements compte {compte_id}")
        return all_rows(cur, "SELECT date_operation, type, montant, libelle FROM mouvement_epargne WHERE compte_id = %s "
                             "ORDER BY date_operation DESC, id DESC LIMIT 50", (compte_id,))


@router.get("/cycles")
def mes_cycles(request: Request, c: dict = Depends(client_pret)):
    _consulte(c, request, "cycles")
    with tx() as cur:
        return all_rows(cur, "SELECT cycle_id AS id, numero, statut, type_cycle, montant_collecte FROM v_cycle_situation WHERE client_id = %s ORDER BY cycle_id DESC", (c["id"],))


@router.get("/cycles/{cycle_id}/carnet")
def mon_carnet(cycle_id: int, request: Request, c: dict = Depends(client_pret)):
    with tx() as cur:
        if one_row(cur, "SELECT 1 AS x FROM cycle WHERE id = %s AND client_id = %s", (cycle_id, c["id"])) is None:
            raise HTTPException(status_code=404, detail="Introuvable")
        _journal(cur, c["id"], "consultation", request, detail=f"carnet cycle {cycle_id}")
        return all_rows(cur, "SELECT page, no_ligne, date_collecte, montant_collecte FROM ligne_collecte WHERE cycle_id = %s ORDER BY page, no_ligne", (cycle_id,))


RESTE = "(e.capital - e.capital_paye) + (e.interet - e.interet_paye) + (e.penalite_due - e.penalite_payee)"


@router.get("/credits")
def mes_credits(request: Request, c: dict = Depends(client_pret)):
    _consulte(c, request, "credits")
    with tx() as cur:
        lignes = all_rows(
            cur, "SELECT s.credit_id AS id, s.numero, s.montant_accorde, s.capital_restant, s.prochaine_echeance, s.statut, "
                 f"  (SELECT {RESTE} FROM echeance e WHERE e.credit_id = s.credit_id AND e.statut <> 'payee' ORDER BY e.date_prevue LIMIT 1) AS montant_prochaine_echeance "
                 "FROM v_credit_situation s WHERE s.client_id = %s ORDER BY s.credit_id DESC", (c["id"],))
    for l in lignes:
        l["numero"] = masque(l["numero"])
    return lignes


@router.get("/credits/{credit_id}/echeances")
def mes_echeances(credit_id: int, request: Request, c: dict = Depends(client_pret)):
    with tx() as cur:
        if one_row(cur, "SELECT 1 AS x FROM credit WHERE id = %s AND client_id = %s", (credit_id, c["id"])) is None:
            raise HTTPException(status_code=404, detail="Introuvable")
        _journal(cur, c["id"], "consultation", request, detail=f"échéances crédit {credit_id}")
        return all_rows(cur, f"SELECT e.no_echeance, e.date_prevue, e.capital, e.interet, e.statut, ({RESTE}) AS reste_a_payer "
                             "FROM echeance e WHERE e.credit_id = %s ORDER BY e.no_echeance", (credit_id,))


@router.get("/journal")
def mon_journal(c: dict = Depends(client_courant)):
    """Mes derniers accès : permet au client de repérer une connexion qu'il ne reconnaît pas."""
    with tx() as cur:
        return all_rows(cur, "SELECT cree_le, evenement, ip FROM acces_client_log WHERE client_id = %s AND evenement <> 'consultation' ORDER BY id DESC LIMIT 20", (c["id"],))


# ------------------------------------------------------------------ côté personnel
class ConsentementIn(BaseModel):
    finalite: Literal["portail", "sms_rappel", "traitement_donnees"]
    accorde: bool
    canal: Literal["papier", "agence"] = "agence"


def _etat_consentements(cur, client_id: int) -> dict:
    historique = all_rows(cur, "SELECT id, finalite, accorde, canal, cree_le FROM consentement_client WHERE client_id = %s ORDER BY id DESC", (client_id,))
    actuel: dict[str, bool] = {}
    for h in reversed(historique):
        actuel[h["finalite"]] = h["accorde"]
    return {"actuel": actuel, "historique": historique}


@admin_router.post("/clients/{client_id}/consentements", status_code=201)
def enregistrer_consentement(client_id: int, body: ConsentementIn, user: User = Depends(require("consent:write"))):
    with tx(user.login) as cur:
        verifier_agence(cur, user, "client", client_id)
        cur.execute("INSERT INTO consentement_client(client_id, finalite, accorde, canal, recueilli_par) VALUES (%s,%s,%s,%s,%s)",
                    (client_id, body.finalite, body.accorde, body.canal, user.id))
        return _etat_consentements(cur, client_id)


@admin_router.get("/clients/{client_id}/consentements")
def lire_consentements(client_id: int, user: User = Depends(require("ref:read"))):
    with tx() as cur:
        verifier_agence(cur, user, "client", client_id)
        return _etat_consentements(cur, client_id)


@admin_router.post("/clients/{client_id}/acces/activer", status_code=201)
def activer_acces(client_id: int, user: User = Depends(require("acces_client:manage"))):
    """Ouvre (ou réinitialise) l'accès. Le PIN provisoire n'est affiché qu'ici, une seule fois : le remettre au client en main propre."""
    pin = generer_pin()
    with tx(user.login) as cur:
        verifier_agence(cur, user, "client", client_id)
        cur.execute("SELECT activer_acces_client(%s, %s, %s)", (client_id, hash_password(pin), user.id))
    return {"pin_provisoire": pin, "consigne": "À remettre au client en main propre ; il devra le changer à sa première connexion. Il ne sera plus affichable."}


class BlocageIn(BaseModel):
    motif: str | None = Field(default=None, max_length=200)


@admin_router.post("/clients/{client_id}/acces/bloquer")
def bloquer_acces(client_id: int, body: BlocageIn, user: User = Depends(require("acces_client:manage"))):
    with tx(user.login) as cur:
        verifier_agence(cur, user, "client", client_id)
        cur.execute("SELECT bloquer_acces_client(%s, %s, %s)", (client_id, user.id, body.motif))
    return {"actif": False}


@admin_router.get("/clients/{client_id}/acces")
def etat_acces(client_id: int, user: User = Depends(require("ref:read"))):
    with tx() as cur:
        verifier_agence(cur, user, "client", client_id)
        a = one_row(cur, "SELECT actif, pin_provisoire, echecs, COALESCE(verrouille_jusqua > now(), false) AS verrouille, derniere_connexion "
                         "FROM client_acces WHERE client_id = %s", (client_id,))
        journal = all_rows(cur, "SELECT cree_le, evenement, ip, detail FROM acces_client_log WHERE client_id = %s AND evenement <> 'consultation' ORDER BY id DESC LIMIT 30", (client_id,))
    return {"existe": a is not None, **(a or {}), "journal": journal}
