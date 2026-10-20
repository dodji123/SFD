"""Authentification (JWT) et contrôle d'accès (rôles, cloisonnement par agence)."""
import datetime as dt

import bcrypt
import jwt
from fastapi import Depends, Header, HTTPException, Response
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
    reseau_id: int | None = None
    agent_id: int | None = None
    collectrice_id: int | None = None
    doit_changer_mdp: bool = False
    # agences accessibles : None = toutes (siège) ; sinon la liste (une agence, ou celles d'un réseau)
    agences: list[int] | None = None

    @property
    def siege(self) -> bool:
        return self.agences is None

    def peut_agence(self, agence_id: int | None) -> bool:
        return self.agences is None or (agence_id is not None and agence_id in self.agences)


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


def create_token(user_id: int, role: str, agence_id: int | None, expires: dt.timedelta | None = None, ori: int | None = None) -> str:
    """Jeton de session du personnel. Durée = inactivité maximale (renouvelée à l'usage, voir get_current_user)."""
    now = dt.datetime.now(dt.timezone.utc)
    exp = now + (expires or dt.timedelta(minutes=settings.session_inactivity_minutes))
    return jwt.encode({"sub": str(user_id), "typ": "staff", "role": role, "agence": agence_id, "iat": now,
                       "ori": ori if ori is not None else int(now.timestamp()), "t": now.timestamp(), "exp": exp},
                      settings.secret(), algorithm=ALGO)


USER_COLS = "id, login, nom, role::text AS role, agence_id, reseau_id, agent_id, collectrice_id, doit_changer_mdp"
MAX_SESSION_HEURES = 12     # durée absolue d'une session, quelles que soient les renouvellements


def charger_user(cur, row: dict) -> "User":
    """Construit l'utilisateur avec son périmètre (agences accessibles)."""
    cur.execute("SELECT agences_utilisateur(%s) AS a", (row["id"],))
    agences = cur.fetchone()["a"]
    data = {k: row[k] for k in ("id", "login", "nom", "role", "agence_id", "reseau_id", "agent_id", "collectrice_id", "doit_changer_mdp")}
    return User(**data, agences=agences)


def _unauthorized(msg: str = "Authentification requise") -> HTTPException:
    return HTTPException(status_code=401, detail=msg, headers={"WWW-Authenticate": "Bearer"})


def get_current_user(response: Response, authorization: str | None = Header(default=None)) -> User:
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
        row = one_row(cur, f"SELECT {USER_COLS}, mdp_change_le FROM utilisateur WHERE id = %s AND actif", (user_id,))
        user = charger_user(cur, row) if row else None
    if user is None:
        raise _unauthorized("Compte désactivé ou inconnu")
    # un changement ou une réinitialisation du mot de passe invalide les sessions ouvertes avant lui
    if float(payload.get("t", 0)) < row["mdp_change_le"].timestamp():
        raise _unauthorized("Session invalidée : mot de passe modifié")
    ori = int(payload.get("ori", payload.get("iat", 0)))
    if dt.datetime.now(dt.timezone.utc).timestamp() - ori > MAX_SESSION_HEURES * 3600:
        raise _unauthorized("Session expirée : reconnectez-vous")
    # session glissante : un nouveau jeton court accompagne la réponse (inactivité maximale de la session)
    response.headers["X-Nouveau-Jeton"] = create_token(user.id, user.role, user.agence_id, ori=ori)
    return user


def require(perm: str):
    """Dépendance de route : l'utilisateur doit avoir un rôle autorisé pour `perm`."""
    if perm not in PERMS:
        raise KeyError(f"permission inconnue : {perm}")

    def dep(user: User = Depends(get_current_user)) -> User:
        if user.doit_changer_mdp:
            # mot de passe temporaire : aucune opération avant son remplacement (guide du contrôle interne)
            raise HTTPException(status_code=403, detail="Vous devez d'abord changer votre mot de passe temporaire")
        if user.role not in PERMS[perm]:
            raise HTTPException(status_code=403, detail="Droits insuffisants pour cette opération")
        return user

    return dep


def agence_scope(user: User, agence_id: int | None = None) -> int:
    """Agence sur laquelle opère la requête.

    Un utilisateur d'agence est enfermé dans son agence. Un utilisateur de réseau opère dans une agence de
    son réseau (à désigner s'il en a plusieurs). Le siège doit désigner l'agence."""
    if agence_id is not None:
        if not user.peut_agence(agence_id):
            raise HTTPException(status_code=403, detail="Agence non autorisée")
        return agence_id
    if user.agences is not None and len(user.agences) == 1:
        return user.agences[0]
    raise HTTPException(status_code=400, detail="agence_id obligatoire (siège ou réseau de plusieurs agences)")


def agence_filter(user: User, agence_id: int | None = None) -> int | None:
    """Comme agence_scope, mais pour une lecture : le siège peut ne pas préciser d'agence (toutes).
    Un utilisateur de réseau doit désigner une agence de son réseau (les vues agrégées du réseau ont leurs routes)."""
    if agence_id is not None:
        if not user.peut_agence(agence_id):
            raise HTTPException(status_code=403, detail="Agence non autorisée")
        return agence_id
    if user.agences is None:
        return None
    if len(user.agences) == 1:
        return user.agences[0]
    raise HTTPException(status_code=400, detail="Choisissez une agence de votre réseau (agence_id)")


# tables dont l'appartenance à une agence se vérifie directement (colonne agence_id)
_TABLES_AGENCE = {
    "client", "zone", "agent", "collectrice", "compte_epargne", "cycle", "retrait", "credit", "demande_credit",
    "caisse", "employe", "virement", "ecart_retrait", "surplus", "versement_agent", "piece_comptable", "bulletin_paie",
    "compte_banque", "depot_garantie", "depot_terme", "dossier_recouvrement", "procuration", "cheque_emission",
}


def verifier_agence(cur, user: User, table: str, row_id: int) -> int:
    """Vérifie que la ligne existe et appartient à l'agence de l'utilisateur ; retourne son agence.
    404 plutôt que 403 : on ne révèle pas l'existence d'une ligne d'une autre agence."""
    if table not in _TABLES_AGENCE:
        raise KeyError(table)
    cur.execute(f"SELECT agence_id FROM {table} WHERE id = %s", (row_id,))
    r = cur.fetchone()
    if r is None or not user.peut_agence(r["agence_id"]):
        raise HTTPException(status_code=404, detail="Introuvable")
    return r["agence_id"]


def role_siege_autorise(role: str) -> bool:
    return role in ROLES_SIEGE
