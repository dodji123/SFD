"""Gestion des utilisateurs (administrateur)."""
from typing import Literal

from fastapi import APIRouter, Depends, HTTPException
from pydantic import BaseModel, Field

from ..auth import User, hash_password, require
from ..db import all_rows, one_row, tx
from ..securite import alerter, journaliser, verifier_politique

router = APIRouter(prefix="/api/utilisateurs", tags=["utilisateurs"])

Role = Literal["admin", "directeur", "chef_agence", "caissier", "comptable", "agent", "collectrice", "rh", "auditeur", "coordinateur"]

COLS = ("id, login, nom, role::text AS role, agence_id, reseau_id, agent_id, collectrice_id, actif, derniere_connexion, "
        "verrouille_jusqua, email, telephone, doit_changer_mdp, mdp_change_le")


class UserIn(BaseModel):
    login: str = Field(min_length=3, max_length=60, pattern=r"^[A-Za-z0-9._@-]+$")
    nom: str = Field(min_length=1, max_length=200)
    role: Role
    agence_id: int | None = None
    reseau_id: int | None = None
    agent_id: int | None = None
    collectrice_id: int | None = None
    email: str | None = Field(default=None, max_length=200, pattern=r"^[^@\s]+@[^@\s]+\.[^@\s]+$")
    telephone: str | None = Field(default=None, max_length=30)
    mot_de_passe: str      # mot de passe temporaire : à changer à la première connexion


class UserPatch(BaseModel):
    nom: str | None = None
    role: Role | None = None
    agence_id: int | None = None
    reseau_id: int | None = None
    email: str | None = Field(default=None, max_length=200, pattern=r"^[^@\s]+@[^@\s]+\.[^@\s]+$")
    telephone: str | None = Field(default=None, max_length=30)
    actif: bool | None = None


class PwdIn(BaseModel):
    mot_de_passe: str


@router.get("")
def lister(user: User = Depends(require("users:manage"))):
    with tx() as cur:
        return all_rows(cur, f"SELECT {COLS} FROM utilisateur ORDER BY login")


@router.post("", status_code=201)
def creer(body: UserIn, user: User = Depends(require("users:manage"))):
    with tx(user.login) as cur:
        verifier_politique(cur, body.mot_de_passe, body.login, None)
        r = one_row(
            cur,
            "INSERT INTO utilisateur(login, nom, role, agence_id, reseau_id, agent_id, collectrice_id, email, telephone, "
            "                        mot_de_passe_hash, doit_changer_mdp) "
            f"VALUES (%s, %s, %s::role_utilisateur, %s, %s, %s, %s, %s, %s, %s, true) RETURNING {COLS}",
            (body.login, body.nom, body.role, body.agence_id, body.reseau_id, body.agent_id, body.collectrice_id,
             body.email, body.telephone, hash_password(body.mot_de_passe)),
        )
    return r


@router.patch("/{user_id}")
def modifier(user_id: int, body: UserPatch, user: User = Depends(require("users:manage"))):
    champs = body.model_dump(exclude_unset=True)
    if not champs:
        raise HTTPException(status_code=422, detail="Aucune modification")
    if user_id == user.id and champs.get("actif") is False:
        raise HTTPException(status_code=422, detail="Vous ne pouvez pas désactiver votre propre compte")
    sets = ", ".join(f"{c} = %s" + ("::role_utilisateur" if c == "role" else "") for c in champs)
    with tx(user.login) as cur:
        r = one_row(cur, f"UPDATE utilisateur SET {sets} WHERE id = %s RETURNING {COLS}", (*champs.values(), user_id))
    if r is None:
        raise HTTPException(status_code=404, detail="Utilisateur introuvable")
    return r


@router.post("/{user_id}/mot-de-passe", status_code=204)
def reinitialiser(user_id: int, body: PwdIn, user: User = Depends(require("users:manage"))):
    """Mot de passe temporaire posé par l'administrateur : l'intéressé doit le changer avant toute opération."""
    with tx(user.login) as cur:
        cible = one_row(cur, "SELECT login, agence_id FROM utilisateur WHERE id = %s", (user_id,))
        if cible is None:
            raise HTTPException(status_code=404, detail="Utilisateur introuvable")
        verifier_politique(cur, body.mot_de_passe, cible["login"], user_id)
        cur.execute(
            "UPDATE utilisateur SET mot_de_passe_hash = %s, doit_changer_mdp = true, echecs_connexion = 0, verrouille_jusqua = NULL WHERE id = %s",
            (hash_password(body.mot_de_passe), user_id),
        )
        journaliser(cur, cible["login"], user_id, "mdp_reinit_admin", None, f"par {user.login}")
        alerter(cur, "mdp_reinit_admin", f"Mot de passe de {cible['login']} réinitialisé par {user.login}", "faible", user_id, cible["agence_id"])


@router.post("/{user_id}/deverrouiller", status_code=204)
def deverrouiller(user_id: int, user: User = Depends(require("users:manage"))):
    with tx(user.login) as cur:
        cur.execute("UPDATE utilisateur SET echecs_connexion = 0, verrouille_jusqua = NULL WHERE id = %s", (user_id,))
        if cur.rowcount == 0:
            raise HTTPException(status_code=404, detail="Utilisateur introuvable")
