"""Second facteur du personnel : état, enrôlement, activation, codes de secours, désactivation (rôles non obligatoires).

Ces routes n'utilisent pas `require` : un rôle sensible sans second facteur doit pouvoir l'enrôler
(`require` refuse tout le reste tant que ce n'est pas fait)."""
from fastapi import APIRouter, Depends, HTTPException, Request
from pydantic import BaseModel, Field

from .. import totp
from ..auth import User, get_current_user, verify_password
from ..config import settings
from ..db import one_row, tx
from ..securite import ip_client, journaliser

router = APIRouter(prefix="/api/auth/totp", tags=["totp"])


class CodeIn(BaseModel):
    code: str = Field(min_length=6, max_length=20)


class DesactiverIn(CodeIn):
    mot_de_passe: str = Field(min_length=1, max_length=200)


def _pas_valide(cur, user_id: int, code: str) -> int:
    """Vérifie un code à 6 chiffres contre le secret (actif ou en cours d'enrôlement) ; retourne le pas accepté."""
    t = one_row(cur, "SELECT secret_chiffre, dernier_pas FROM utilisateur_totp WHERE utilisateur_id = %s FOR UPDATE", (user_id,))
    if t is None:
        raise HTTPException(status_code=409, detail="Aucun second facteur en cours d'enrôlement")
    pas = totp.verifier(totp.dechiffrer(t["secret_chiffre"]), code, t["dernier_pas"])
    if pas is None:
        raise HTTPException(status_code=422, detail="Code incorrect ou déjà utilisé")
    return pas


def _enregistrer_codes(cur, user_id: int) -> list[str]:
    cur.execute("DELETE FROM code_secours_totp WHERE utilisateur_id = %s", (user_id,))
    codes = totp.nouveaux_codes_secours()
    for c in codes:
        cur.execute("INSERT INTO code_secours_totp(utilisateur_id, code_hash) VALUES (%s, %s)", (user_id, totp.hacher_secours(c)))
    return codes


@router.get("")
def etat(user: User = Depends(get_current_user)):
    with tx() as cur:
        restants = one_row(cur, "SELECT count(*) AS n FROM code_secours_totp WHERE utilisateur_id = %s AND utilise_le IS NULL", (user.id,))["n"]
        en_cours = one_row(cur, "SELECT 1 AS x FROM utilisateur_totp WHERE utilisateur_id = %s AND NOT actif", (user.id,)) is not None
    return {"actif": user.totp_actif, "obligatoire": user.role in totp.roles_obligatoires() and settings.totp_obligatoire,
            "a_enroler": user.totp_a_enroler, "enrolement_en_cours": en_cours, "codes_secours_restants": restants}


@router.post("/preparer")
def preparer(user: User = Depends(get_current_user)):
    """Génère un secret (remplace un enrôlement non terminé). Il n'est actif qu'après un premier code valide."""
    if user.doit_changer_mdp:
        raise HTTPException(status_code=403, detail="Changez d'abord votre mot de passe temporaire")
    if user.totp_actif:
        raise HTTPException(status_code=409, detail="Le second facteur est déjà actif : demandez une réinitialisation à un responsable")
    secret = totp.nouveau_secret()
    with tx(user.login) as cur:
        cur.execute("DELETE FROM utilisateur_totp WHERE utilisateur_id = %s AND NOT actif", (user.id,))
        cur.execute("INSERT INTO utilisateur_totp(utilisateur_id, secret_chiffre) VALUES (%s, %s)", (user.id, totp.chiffrer(secret)))
    return {"secret": secret, "uri": totp.uri(secret, user.login), "periode": totp.PAS, "chiffres": totp.CHIFFRES}


@router.post("/activer")
def activer(body: CodeIn, request: Request, user: User = Depends(get_current_user)):
    """Preuve de possession : le premier code valide active le second facteur et remet les codes de secours (montrés une fois)."""
    if user.totp_actif:
        raise HTTPException(status_code=409, detail="Le second facteur est déjà actif")
    with tx(user.login) as cur:
        pas = _pas_valide(cur, user.id, body.code)
        cur.execute("UPDATE utilisateur_totp SET actif = true, active_le = now(), dernier_pas = %s WHERE utilisateur_id = %s", (pas, user.id))
        codes = _enregistrer_codes(cur, user.id)
        journaliser(cur, user.login, user.id, "totp_active", ip_client(request))
    return {"codes_secours": codes}


@router.post("/codes-secours")
def regenerer_codes(body: CodeIn, user: User = Depends(get_current_user)):
    """Nouveaux codes de secours (les anciens deviennent inutilisables). Exige un code TOTP courant."""
    if not user.totp_actif:
        raise HTTPException(status_code=409, detail="Second facteur non actif")
    with tx(user.login) as cur:
        pas = _pas_valide(cur, user.id, body.code)
        cur.execute("UPDATE utilisateur_totp SET dernier_pas = %s WHERE utilisateur_id = %s", (pas, user.id))
        return {"codes_secours": _enregistrer_codes(cur, user.id)}


@router.post("/desactiver", status_code=204)
def desactiver(body: DesactiverIn, request: Request, user: User = Depends(get_current_user)):
    """Retrait du second facteur, possible seulement pour un rôle où il n'est pas obligatoire."""
    if not user.totp_actif:
        raise HTTPException(status_code=409, detail="Second facteur non actif")
    if settings.totp_obligatoire and user.role in totp.roles_obligatoires():
        raise HTTPException(status_code=403, detail="Le second facteur est obligatoire pour votre rôle : un responsable peut le réinitialiser")
    with tx(user.login) as cur:
        r = one_row(cur, "SELECT mot_de_passe_hash FROM utilisateur WHERE id = %s", (user.id,))
        if not r or not verify_password(body.mot_de_passe, r["mot_de_passe_hash"]):
            raise HTTPException(status_code=403, detail="Mot de passe incorrect")
        _pas_valide(cur, user.id, body.code)
        cur.execute("DELETE FROM code_secours_totp WHERE utilisateur_id = %s", (user.id,))
        cur.execute("DELETE FROM utilisateur_totp WHERE utilisateur_id = %s", (user.id,))
        journaliser(cur, user.login, user.id, "totp_desactive", ip_client(request))
