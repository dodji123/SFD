"""Connexion, profil, changement et récupération du mot de passe."""
import datetime as dt

from fastapi import APIRouter, Depends, HTTPException, Request, Response
from pydantic import BaseModel, Field

from ..auth import (DUMMY_HASH, USER_COLS, User, charger_user, create_token, get_current_user, hash_password,
                    verify_password)
from ..config import settings
from ..db import one_row, tx
from ..securite import (alerter, envoyer_message, hacher_jeton, hors_heures, ip_client, journaliser, nouveau_jeton,
                        verifier_politique)

router = APIRouter(prefix="/api/auth", tags=["auth"])

MSG_ECHEC = "Identifiants incorrects"
MSG_OUBLI = "Si ce compte existe et possède une adresse de contact, un lien de réinitialisation vient d'être envoyé."


class LoginIn(BaseModel):
    login: str = Field(min_length=1, max_length=60)
    mot_de_passe: str = Field(min_length=1, max_length=200)


@router.post("/login")
def login(body: LoginIn, request: Request):
    verdict = "echec"  # echec | verrouille | ok
    token = None
    user = None
    ip = ip_client(request)
    with tx() as cur:
        u = one_row(
            cur,
            f"SELECT {USER_COLS}, actif, mot_de_passe_hash, mdp_change_le, "
            "       COALESCE(verrouille_jusqua > now(), false) AS verrouille "
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
        elif ok:
            perime = (settings.password_max_age_days > 0
                      and u["mdp_change_le"] < dt.datetime.now(dt.timezone.utc) - dt.timedelta(days=settings.password_max_age_days))
            cur.execute(
                "UPDATE utilisateur SET echecs_connexion = 0, verrouille_jusqua = NULL, derniere_connexion = now(), "
                "       doit_changer_mdp = doit_changer_mdp OR %s WHERE id = %s RETURNING doit_changer_mdp",
                (perime, u["id"]),
            )
            u["doit_changer_mdp"] = cur.fetchone()["doit_changer_mdp"]
            verdict = "ok"
            journaliser(cur, body.login, u["id"], "succes", ip, "mot de passe expiré" if perime else None)
            if hors_heures():
                journaliser(cur, body.login, u["id"], "hors_heures", ip, "connexion hors des heures ouvrables")
                alerter(cur, "connexion_hors_heures", f"Connexion de {body.login} hors des heures ouvrables ({settings.heures_ouvrables})",
                        "faible", u["id"], u["agence_id"])
            user = charger_user(cur, u)
            token = create_token(u["id"], u["role"], u["agence_id"])
        else:
            cur.execute(
                "UPDATE utilisateur SET echecs_connexion = echecs_connexion + 1, "
                "  verrouille_jusqua = CASE WHEN echecs_connexion + 1 >= %s "
                "                           THEN now() + make_interval(mins => %s) ELSE verrouille_jusqua END "
                "WHERE id = %s RETURNING COALESCE(verrouille_jusqua > now(), false) AS verrouille, echecs_connexion",
                (settings.max_failed_logins, settings.lockout_minutes, u["id"]),
            )
            etat = cur.fetchone()
            verdict = "echec"
            journaliser(cur, body.login, u["id"], "echec", ip, f"échec n°{etat['echecs_connexion']}")
            if etat["verrouille"] and etat["echecs_connexion"] == settings.max_failed_logins:
                journaliser(cur, body.login, u["id"], "verrouille", ip, f"verrouillé {settings.lockout_minutes} min")
                alerter(cur, "verrouillage", f"Compte {body.login} verrouillé après {settings.max_failed_logins} échecs (IP {ip})",
                        "moyenne", u["id"], u["agence_id"])
    # les compteurs d'échecs sont validés (sortie du bloc tx) avant de lever l'erreur
    if verdict == "verrouille":
        raise HTTPException(status_code=429, detail="Trop de tentatives : compte verrouillé temporairement")
    if verdict != "ok":
        raise HTTPException(status_code=401, detail=MSG_ECHEC)
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
