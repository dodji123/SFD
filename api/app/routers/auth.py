"""Connexion, profil, changement de mot de passe."""
from fastapi import APIRouter, Depends, HTTPException
from pydantic import BaseModel, Field

from ..auth import (DUMMY_HASH, User, create_token, get_current_user, hash_password, verify_password)
from ..config import settings
from ..db import one_row, tx

router = APIRouter(prefix="/api/auth", tags=["auth"])

MSG_ECHEC = "Identifiants incorrects"


class LoginIn(BaseModel):
    login: str = Field(min_length=1, max_length=60)
    mot_de_passe: str = Field(min_length=1, max_length=200)


@router.post("/login")
def login(body: LoginIn):
    verdict = "echec"  # echec | verrouille | ok
    token = None
    user = None
    with tx() as cur:
        u = one_row(
            cur,
            "SELECT id, login, nom, role::text AS role, agence_id, agent_id, collectrice_id, actif, mot_de_passe_hash, "
            "       COALESCE(verrouille_jusqua > now(), false) AS verrouille "
            "FROM utilisateur WHERE login = %s FOR UPDATE",
            (body.login,),
        )
        ok = verify_password(body.mot_de_passe, u["mot_de_passe_hash"] if u else DUMMY_HASH)
        if u is None or not u["actif"]:
            verdict = "echec"
        elif u["verrouille"]:
            verdict = "verrouille"
        elif ok:
            cur.execute(
                "UPDATE utilisateur SET echecs_connexion = 0, verrouille_jusqua = NULL, derniere_connexion = now() WHERE id = %s",
                (u["id"],),
            )
            verdict = "ok"
            token = create_token(u["id"], u["role"], u["agence_id"])
            user = User(**{k: u[k] for k in ("id", "login", "nom", "role", "agence_id", "agent_id", "collectrice_id")})
        else:
            cur.execute(
                "UPDATE utilisateur SET echecs_connexion = echecs_connexion + 1, "
                "  verrouille_jusqua = CASE WHEN echecs_connexion + 1 >= %s "
                "                           THEN now() + make_interval(mins => %s) ELSE verrouille_jusqua END "
                "WHERE id = %s",
                (settings.max_failed_logins, settings.lockout_minutes, u["id"]),
            )
            verdict = "echec"
    # les compteurs d'échecs sont validés (sortie du bloc tx) avant de lever l'erreur
    if verdict == "verrouille":
        raise HTTPException(status_code=429, detail="Trop de tentatives : compte verrouillé temporairement")
    if verdict != "ok":
        raise HTTPException(status_code=401, detail=MSG_ECHEC)
    return {"access_token": token, "token_type": "bearer", "user": user}


@router.get("/me", response_model=User)
def me(user: User = Depends(get_current_user)):
    return user


class ChangePasswordIn(BaseModel):
    ancien: str
    nouveau: str = Field(min_length=1, max_length=200)


@router.post("/mot-de-passe", status_code=204)
def changer_mot_de_passe(body: ChangePasswordIn, user: User = Depends(get_current_user)):
    if len(body.nouveau) < settings.password_min_length:
        raise HTTPException(status_code=422, detail=f"Le mot de passe doit comporter au moins {settings.password_min_length} caractères")
    with tx(user.login) as cur:
        r = one_row(cur, "SELECT mot_de_passe_hash FROM utilisateur WHERE id = %s", (user.id,))
        if not r or not verify_password(body.ancien, r["mot_de_passe_hash"]):
            raise HTTPException(status_code=403, detail="Ancien mot de passe incorrect")
        cur.execute("UPDATE utilisateur SET mot_de_passe_hash = %s WHERE id = %s", (hash_password(body.nouveau), user.id))
