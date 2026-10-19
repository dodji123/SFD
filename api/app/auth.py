"""Authentification (JWT) et contrôle d'accès (rôles, cloisonnement par agence)."""
import datetime as dt

import bcrypt
import jwt
from fastapi import Depends, Header, HTTPException
from pydantic import BaseModel

from .config import settings
from .db import one_row, tx
from .perms import PERMS, ROLES_SIEGE

ALGO = "HS256"


class User(BaseModel):
    id: int
    login: str
    nom: str
    role: str
    agence_id: int | None = None
    agent_id: int | None = None
    collectrice_id: int | None = None

    @property
    def siege(self) -> bool:
        return self.agence_id is None


def hash_password(password: str) -> str:
    return bcrypt.hashpw(password.encode(), bcrypt.gensalt(12)).decode()


def verify_password(password: str, hashed: str | None) -> bool:
    if not hashed:
        return False
    try:
        return bcrypt.checkpw(password.encode(), hashed.encode())
    except ValueError:
        return False


# haché factice : on vérifie toujours un mot de passe, même pour un login inconnu (pas d'énumération par le temps)
DUMMY_HASH = bcrypt.hashpw(b"dummy", bcrypt.gensalt(12)).decode()


def create_token(user_id: int, role: str, agence_id: int | None, expires: dt.timedelta | None = None) -> str:
    exp = dt.datetime.now(dt.timezone.utc) + (expires or dt.timedelta(minutes=settings.jwt_expire_minutes))
    return jwt.encode({"sub": str(user_id), "typ": "staff", "role": role, "agence": agence_id, "exp": exp}, settings.secret(), algorithm=ALGO)


def _unauthorized(msg: str = "Authentification requise") -> HTTPException:
    return HTTPException(status_code=401, detail=msg, headers={"WWW-Authenticate": "Bearer"})


def get_current_user(authorization: str | None = Header(default=None)) -> User:
    if not authorization or not authorization.lower().startswith("bearer "):
        raise _unauthorized()
    token = authorization.split(" ", 1)[1].strip()
    try:
        payload = jwt.decode(token, settings.secret(), algorithms=[ALGO])
        user_id = int(payload["sub"])
    except (jwt.PyJWTError, KeyError, ValueError):
        raise _unauthorized("Session invalide ou expirée")
    # un jeton de l'espace client ne doit jamais ouvrir une route du personnel (même secret, autre type)
    if payload.get("typ", "staff") != "staff":
        raise _unauthorized("Session invalide ou expirée")
    with tx() as cur:
        row = one_row(
            cur,
            "SELECT id, login, nom, role::text AS role, agence_id, agent_id, collectrice_id "
            "FROM utilisateur WHERE id = %s AND actif",
            (user_id,),
        )
    if row is None:
        raise _unauthorized("Compte désactivé ou inconnu")
    return User(**row)


def require(perm: str):
    """Dépendance de route : l'utilisateur doit avoir un rôle autorisé pour `perm`."""
    if perm not in PERMS:
        raise KeyError(f"permission inconnue : {perm}")

    def dep(user: User = Depends(get_current_user)) -> User:
        if user.role not in PERMS[perm]:
            raise HTTPException(status_code=403, detail="Droits insuffisants pour cette opération")
        return user

    return dep


def agence_scope(user: User, agence_id: int | None = None) -> int:
    """Agence sur laquelle opère la requête.

    Un utilisateur d'agence est enfermé dans son agence (toute autre agence demandée est refusée).
    Un utilisateur du siège doit désigner l'agence."""
    if user.agence_id is not None:
        if agence_id is not None and agence_id != user.agence_id:
            raise HTTPException(status_code=403, detail="Agence non autorisée")
        return user.agence_id
    if agence_id is None:
        raise HTTPException(status_code=400, detail="agence_id obligatoire pour un utilisateur du siège")
    return agence_id


def agence_filter(user: User, agence_id: int | None = None) -> int | None:
    """Comme agence_scope, mais pour une lecture : le siège peut ne pas préciser d'agence (toutes)."""
    if user.agence_id is not None:
        if agence_id is not None and agence_id != user.agence_id:
            raise HTTPException(status_code=403, detail="Agence non autorisée")
        return user.agence_id
    return agence_id


# tables dont l'appartenance à une agence se vérifie directement (colonne agence_id)
_TABLES_AGENCE = {
    "client", "zone", "agent", "collectrice", "compte_epargne", "cycle", "retrait", "credit", "demande_credit",
    "caisse", "employe", "virement", "ecart_retrait", "surplus", "versement_agent", "piece_comptable", "bulletin_paie",
    "compte_banque", "depot_garantie", "depot_terme",
}


def verifier_agence(cur, user: User, table: str, row_id: int) -> int:
    """Vérifie que la ligne existe et appartient à l'agence de l'utilisateur ; retourne son agence.
    404 plutôt que 403 : on ne révèle pas l'existence d'une ligne d'une autre agence."""
    if table not in _TABLES_AGENCE:
        raise KeyError(table)
    cur.execute(f"SELECT agence_id FROM {table} WHERE id = %s", (row_id,))
    r = cur.fetchone()
    if r is None or (user.agence_id is not None and r["agence_id"] != user.agence_id):
        raise HTTPException(status_code=404, detail="Introuvable")
    return r["agence_id"]


def role_siege_autorise(role: str) -> bool:
    return role in ROLES_SIEGE
