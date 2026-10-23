"""Connexion, profil, changement et récupération du mot de passe."""
import datetime as dt

import jwt
from fastapi import APIRouter, Depends, HTTPException, Request, Response
from pydantic import BaseModel, Field

from .. import totp
from ..auth import (DUMMY_HASH, USER_COLS, User, charger_user, create_defi, create_token, get_current_user, hash_password,
                    verify_password)
from ..config import settings
from ..db import one_row, tx
from ..securite import (alerter, envoyer_message, hacher_jeton, hors_heures, ip_client, journaliser, nouveau_jeton,
                        verifier_politique)

router = APIRouter(prefix="/api/auth", tags=["auth"])

MSG_ECHEC = "Identifiants incorrects"
MSG_TOTP = "Code incorrect"
MSG_OUBLI = "Si ce compte existe et possède une adresse de contact, un lien de réinitialisation vient d'être envoyé."


class LoginIn(BaseModel):
    login: str = Field(min_length=1, max_length=60)
    mot_de_passe: str = Field(min_length=1, max_length=200)


def _finaliser_connexion(cur, u: dict, ip: str | None) -> tuple[str, "User"]:
    """Mot de passe (et second facteur s'il existe) acceptés : compteurs remis à zéro, journal, jeton de session."""
    perime = (settings.password_max_age_days > 0
              and u["mdp_change_le"] < dt.datetime.now(dt.timezone.utc) - dt.timedelta(days=settings.password_max_age_days))
    cur.execute(
        "UPDATE utilisateur SET echecs_connexion = 0, verrouille_jusqua = NULL, derniere_connexion = now(), "
        "       doit_changer_mdp = doit_changer_mdp OR %s WHERE id = %s RETURNING doit_changer_mdp",
        (perime, u["id"]),
    )
    u["doit_changer_mdp"] = cur.fetchone()["doit_changer_mdp"]
    journaliser(cur, u["login"], u["id"], "succes", ip, "mot de passe expiré" if perime else None)
    if hors_heures():
        journaliser(cur, u["login"], u["id"], "hors_heures", ip, "connexion hors des heures ouvrables")
        alerter(cur, "connexion_hors_heures", f"Connexion de {u['login']} hors des heures ouvrables ({settings.heures_ouvrables})",
                "faible", u["id"], u["agence_id"])
    return create_token(u["id"], u["role"], u["agence_id"]), charger_user(cur, u)


def _compter_echec(cur, u: dict, ip: str | None, evenement: str, detail: str) -> None:
    """Un échec (mot de passe ou second facteur) : même compteur, même verrouillage, même alerte."""
    cur.execute(
        "UPDATE utilisateur SET echecs_connexion = echecs_connexion + 1, "
        "  verrouille_jusqua = CASE WHEN echecs_connexion + 1 >= %s "
        "                           THEN now() + make_interval(mins => %s) ELSE verrouille_jusqua END "
        "WHERE id = %s RETURNING COALESCE(verrouille_jusqua > now(), false) AS verrouille, echecs_connexion",
        (settings.max_failed_logins, settings.lockout_minutes, u["id"]),
    )
    etat = cur.fetchone()
    journaliser(cur, u["login"], u["id"], evenement, ip, f"{detail} n°{etat['echecs_connexion']}")
    if etat["verrouille"] and etat["echecs_connexion"] == settings.max_failed_logins:
        journaliser(cur, u["login"], u["id"], "verrouille", ip, f"verrouillé {settings.lockout_minutes} min")
        alerter(cur, "verrouillage", f"Compte {u['login']} verrouillé après {settings.max_failed_logins} échecs (IP {ip})",
                "moyenne", u["id"], u["agence_id"])


@router.post("/login")
def login(body: LoginIn, request: Request):
    """Mot de passe. Si le compte a un second facteur actif, la réponse est un défi (`totp_requis`) à compléter par
    POST /login/totp : aucun jeton de session n'est délivré avant."""
    verdict = "echec"  # echec | verrouille | ok | totp
    token = None
    user = None
    defi = None
    ip = ip_client(request)
    with tx() as cur:
        u = one_row(
            cur,
            f"SELECT {USER_COLS}, actif, mot_de_passe_hash, mdp_change_le, "
            "       COALESCE(verrouille_jusqua > now(), false) AS verrouille, "
            "       EXISTS (SELECT 1 FROM utilisateur_totp t WHERE t.utilisateur_id = utilisateur.id AND t.actif) AS totp "
            "FROM utilisateur WHERE login = %s FOR UPDATE",
            (body.login,),
        )
        ok = verify_password(body.mot_de_passe, u["mot_de_passe_hash"] if u else DUMMY_HASH)
        if u is None or not u["actif"]:
            verdict = "echec"
            journaliser(cur, body.login, u["id"] if u else None, "echec", ip, "compte inconnu ou désactivé")
        elif u["verrouille"]:
            verdict = "verrouille"
            journaliser(cur, body.login, u["id"], "verrouille", ip, "tentative pendant le verrouillage")
        elif ok and u["totp"]:
            verdict = "totp"
            defi = create_defi(u["id"])
        elif ok:
            verdict = "ok"
            token, user = _finaliser_connexion(cur, u, ip)
        else:
            verdict = "echec"
            _compter_echec(cur, u, ip, "echec", "échec")
    # les compteurs d'échecs sont validés (sortie du bloc tx) avant de lever l'erreur
    if verdict == "verrouille":
        raise HTTPException(status_code=429, detail="Trop de tentatives : compte verrouillé temporairement")
    if verdict == "totp":
        return {"totp_requis": True, "defi": defi, "defi_minutes": settings.totp_defi_minutes}
    if verdict != "ok":
        raise HTTPException(status_code=401, detail=MSG_ECHEC)
    return {"access_token": token, "token_type": "bearer", "user": user, "session_minutes": settings.session_inactivity_minutes}


class LoginTotpIn(BaseModel):
    defi: str = Field(min_length=10, max_length=2000)
    code: str = Field(min_length=6, max_length=20)      # code à 6 chiffres, ou code de secours


@router.post("/login/totp")
def login_totp(body: LoginTotpIn, request: Request):
    """Deuxième temps : code TOTP (ou code de secours, à usage unique). Les échecs comptent comme ceux du mot de passe."""
    try:
        payload = jwt.decode(body.defi, settings.secret(), algorithms=["HS256"])
        if payload.get("typ") != "totp":
            raise ValueError
        uid = int(payload["sub"])
    except (jwt.PyJWTError, KeyError, ValueError):
        raise HTTPException(status_code=401, detail="Défi expiré : recommencez la connexion")
    ip = ip_client(request)
    verdict, token, user = "echec", None, None
    with tx() as cur:
        u = one_row(
            cur,
            f"SELECT {USER_COLS}, actif, mdp_change_le, COALESCE(verrouille_jusqua > now(), false) AS verrouille "
            "FROM utilisateur WHERE id = %s FOR UPDATE", (uid,))
        t = one_row(cur, "SELECT secret_chiffre, dernier_pas FROM utilisateur_totp WHERE utilisateur_id = %s AND actif FOR UPDATE", (uid,))
        if u is None or not u["actif"] or t is None:
            raise HTTPException(status_code=401, detail="Défi expiré : recommencez la connexion")
        if u["verrouille"]:
            verdict = "verrouille"
            journaliser(cur, u["login"], uid, "verrouille", ip, "tentative pendant le verrouillage")
        else:
            ok, secours = False, False
            if totp.est_code_secours(body.code):
                r = one_row(cur, "UPDATE code_secours_totp SET utilise_le = now() WHERE id = ("
                                 "  SELECT id FROM code_secours_totp WHERE utilisateur_id = %s AND code_hash = %s AND utilise_le IS NULL FOR UPDATE)"
                                 " RETURNING id", (uid, totp.hacher_secours(body.code)))
                ok = secours = r is not None
            else:
                pas = totp.verifier(totp.dechiffrer(t["secret_chiffre"]), body.code, t["dernier_pas"])
                if pas is not None:
                    cur.execute("UPDATE utilisateur_totp SET dernier_pas = %s WHERE utilisateur_id = %s", (pas, uid))
                    ok = True
            if ok:
                verdict = "ok"
                if secours:
                    reste = one_row(cur, "SELECT count(*) AS n FROM code_secours_totp WHERE utilisateur_id = %s AND utilise_le IS NULL", (uid,))["n"]
                    journaliser(cur, u["login"], uid, "totp_secours", ip, f"code de secours utilisé, {reste} restant(s)")
                    if reste <= 2:
                        alerter(cur, "totp_secours_bas", f"{u['login']} : il reste {reste} code(s) de secours", "faible", uid, u["agence_id"])
                token, user = _finaliser_connexion(cur, u, ip)
            else:
                _compter_echec(cur, u, ip, "totp_echec", "code du second facteur incorrect")
    if verdict == "verrouille":
        raise HTTPException(status_code=429, detail="Trop de tentatives : compte verrouillé temporairement")
    if verdict != "ok":
        raise HTTPException(status_code=401, detail=MSG_TOTP)
    return {"access_token": token, "token_type": "bearer", "user": user, "session_minutes": settings.session_inactivity_minutes}


@router.get("/me", response_model=User)
def me(user: User = Depends(get_current_user)):
    return user


class ChangePasswordIn(BaseModel):
    ancien: str
    nouveau: str = Field(min_length=1, max_length=200)


@router.post("/mot-de-passe", status_code=204)
def changer_mot_de_passe(body: ChangePasswordIn, request: Request, response: Response, user: User = Depends(get_current_user)):
    with tx(user.login) as cur:
        r = one_row(cur, "SELECT mot_de_passe_hash FROM utilisateur WHERE id = %s", (user.id,))
        if not r or not verify_password(body.ancien, r["mot_de_passe_hash"]):
            raise HTTPException(status_code=403, detail="Ancien mot de passe incorrect")
        if body.ancien == body.nouveau:
            raise HTTPException(status_code=422, detail="Le nouveau mot de passe doit différer de l'ancien")
        verifier_politique(cur, body.nouveau, user.login, user.id)
        cur.execute("UPDATE utilisateur SET mot_de_passe_hash = %s, doit_changer_mdp = false WHERE id = %s",
                    (hash_password(body.nouveau), user.id))
        journaliser(cur, user.login, user.id, "mdp_change", ip_client(request))
    # la session de celui qui change son mot de passe continue avec un jeton émis après le changement
    response.headers["X-Nouveau-Jeton"] = create_token(user.id, user.role, user.agence_id)


class OubliIn(BaseModel):
    login: str = Field(min_length=1, max_length=60)


@router.post("/mot-de-passe-oublie", status_code=202)
def mot_de_passe_oublie(body: OubliIn, request: Request):
    """Envoie un lien à usage unique à l'adresse du compte. La réponse est identique que le compte existe ou non
    (pas d'énumération des comptes)."""
    ip = ip_client(request)
    with tx() as cur:
        u = one_row(cur, "SELECT id, login, nom, email, agence_id FROM utilisateur WHERE login = %s AND actif FOR UPDATE", (body.login,))
        if u is None:
            journaliser(cur, body.login, None, "mdp_oublie", ip, "compte inconnu")
        elif not u["email"]:
            journaliser(cur, body.login, u["id"], "mdp_oublie", ip, "aucune adresse de contact : voir l'administrateur")
        else:
            recents = one_row(cur, "SELECT count(*) AS n FROM jeton_reinit_mdp WHERE utilisateur_id = %s AND cree_le > now() - interval '1 hour'",
                              (u["id"],))["n"]
            if recents >= settings.reset_max_per_hour:
                journaliser(cur, body.login, u["id"], "mdp_oublie", ip, "limite de demandes atteinte")
            else:
                jeton, h = nouveau_jeton()
                cur.execute("INSERT INTO jeton_reinit_mdp(utilisateur_id, jeton_hash, expire_le, ip) "
                            "VALUES (%s, %s, now() + make_interval(mins => %s), %s)", (u["id"], h, settings.reset_token_minutes, ip))
                lien = f"{settings.app_url}/reinitialiser?jeton={jeton}"
                envoyer_message(
                    cur, u["id"], "email", u["email"], "Réinitialisation de votre mot de passe",
                    f"Bonjour {u['nom']},\n\nPour choisir un nouveau mot de passe, ouvrez ce lien (valable {settings.reset_token_minutes} minutes, "
                    f"utilisable une seule fois) :\n{lien}\n\nSi vous n'êtes pas à l'origine de cette demande, ignorez ce message "
                    "et prévenez votre responsable.")
                journaliser(cur, body.login, u["id"], "mdp_oublie", ip, "lien envoyé")
    return {"message": MSG_OUBLI}


class ReinitIn(BaseModel):
    jeton: str = Field(min_length=10, max_length=200)
    nouveau: str = Field(min_length=1, max_length=200)


@router.post("/reinitialiser-mot-de-passe", status_code=204)
def reinitialiser(body: ReinitIn, request: Request):
    ip = ip_client(request)
    with tx() as cur:
        j = one_row(
            cur,
            "SELECT j.id, j.utilisateur_id, u.login FROM jeton_reinit_mdp j JOIN utilisateur u ON u.id = j.utilisateur_id "
            "WHERE j.jeton_hash = %s AND j.utilise_le IS NULL AND j.expire_le > now() AND u.actif FOR UPDATE OF j",
            (hacher_jeton(body.jeton),),
        )
        if j is None:
            raise HTTPException(status_code=400, detail="Lien invalide, expiré ou déjà utilisé")
        verifier_politique(cur, body.nouveau, j["login"], j["utilisateur_id"])
        cur.execute(
            "UPDATE utilisateur SET mot_de_passe_hash = %s, doit_changer_mdp = false, echecs_connexion = 0, verrouille_jusqua = NULL WHERE id = %s",
            (hash_password(body.nouveau), j["utilisateur_id"]),
        )
        # tous les liens en attente de ce compte deviennent inutilisables
        cur.execute("UPDATE jeton_reinit_mdp SET utilise_le = now() WHERE utilisateur_id = %s AND utilise_le IS NULL", (j["utilisateur_id"],))
        journaliser(cur, j["login"], j["utilisateur_id"], "mdp_reinitialise", ip)
