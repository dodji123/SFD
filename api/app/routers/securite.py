"""Sécurité : journal des connexions, alertes d'opérations inhabituelles, registre des sauvegardes, état de la sécurité."""
import datetime as dt
from typing import Literal

from fastapi import APIRouter, Depends, HTTPException, Query
from pydantic import BaseModel, Field

from ..auth import User, require
from ..config import settings
from ..db import all_rows, one_row, tx
from ..securite import alerter

router = APIRouter(prefix="/api/securite", tags=["securite"])

SAUVEGARDE_MAX_JOURS = 7          # au-delà, aucune sauvegarde récente : constat
RESTAURATION_MAX_JOURS = 90       # une sauvegarde doit avoir été testée en restauration au moins tous les 90 jours


@router.get("/connexions")
def connexions(login: str | None = None, evenement: str | None = None, limit: int = Query(100, ge=1, le=500),
               user: User = Depends(require("securite:read"))):
    with tx() as cur:
        return all_rows(
            cur,
            "SELECT id, horodatage, login, utilisateur_id, evenement, ip, detail FROM journal_connexion "
            "WHERE (%s::text IS NULL OR login = %s) AND (%s::text IS NULL OR evenement = %s) ORDER BY id DESC LIMIT %s",
            (login, login, evenement, evenement, limit),
        )


@router.get("/alertes")
def alertes(ouvertes: bool = True, limit: int = Query(100, ge=1, le=500), user: User = Depends(require("securite:alertes"))):
    with tx() as cur:
        return all_rows(
            cur,
            "SELECT a.*, u.login AS utilisateur FROM alerte_securite a LEFT JOIN utilisateur u ON u.id = a.utilisateur_id "
            "WHERE (NOT %s OR a.traitee_le IS NULL) ORDER BY a.id DESC LIMIT %s",
            (ouvertes, limit),
        )


class TraiterIn(BaseModel):
    commentaire: str = Field(min_length=5, max_length=1000)


@router.post("/alertes/{alerte_id}/traiter")
def traiter_alerte(alerte_id: int, body: TraiterIn, user: User = Depends(require("securite:alertes"))):
    with tx(user.login) as cur:
        r = one_row(cur, "UPDATE alerte_securite SET traitee_le = now(), traitee_par = %s, commentaire = %s "
                         "WHERE id = %s AND traitee_le IS NULL RETURNING *", (user.id, body.commentaire, alerte_id))
    if r is None:
        raise HTTPException(status_code=404, detail="Alerte introuvable ou déjà traitée")
    return r


# ------------------------------------------------------------------ sauvegardes
class SauvegardeIn(BaseModel):
    effectuee_le: dt.datetime
    type: Literal["complete", "incrementale", "journal"] = "complete"
    support: str = Field(min_length=2, max_length=200)
    emplacement: str | None = Field(default=None, max_length=300)
    taille_mo: float | None = Field(default=None, ge=0)
    empreinte: str | None = Field(default=None, max_length=128)


@router.get("/sauvegardes")
def sauvegardes(user: User = Depends(require("securite:read"))):
    with tx() as cur:
        return all_rows(
            cur,
            "SELECT s.*, a.login AS effectuee_par_login, t.login AS test_par_login FROM sauvegarde s "
            "LEFT JOIN utilisateur a ON a.id = s.effectuee_par LEFT JOIN utilisateur t ON t.id = s.test_par "
            "ORDER BY s.effectuee_le DESC LIMIT 100",
        )


@router.post("/sauvegardes", status_code=201)
def enregistrer_sauvegarde(body: SauvegardeIn, user: User = Depends(require("sauvegarde:write"))):
    maintenant = dt.datetime.now(body.effectuee_le.tzinfo)
    if body.effectuee_le > maintenant + dt.timedelta(minutes=5):
        raise HTTPException(status_code=422, detail="La date de sauvegarde est dans le futur")
    with tx(user.login) as cur:
        return one_row(
            cur,
            "INSERT INTO sauvegarde(effectuee_le, type, support, emplacement, taille_mo, empreinte, effectuee_par) "
            "VALUES (%s, %s, %s, %s, %s, %s, %s) RETURNING *",
            (body.effectuee_le, body.type, body.support, body.emplacement, body.taille_mo, body.empreinte, user.id),
        )


class TestRestaurationIn(BaseModel):
    resultat: Literal["reussi", "echec"]
    commentaire: str | None = Field(default=None, max_length=1000)


@router.post("/sauvegardes/{sauvegarde_id}/test")
def tester_sauvegarde(sauvegarde_id: int, body: TestRestaurationIn, user: User = Depends(require("sauvegarde:tester"))):
    """Test de restauration, fait par une autre personne que l'auteur de la sauvegarde (contrôlé par la base)."""
    with tx(user.login) as cur:
        r = one_row(
            cur,
            "UPDATE sauvegarde SET test_restaure_le = now(), test_resultat = %s, test_par = %s, test_commentaire = %s "
            "WHERE id = %s AND test_restaure_le IS NULL RETURNING *",
            (body.resultat, user.id, body.commentaire, sauvegarde_id),
        )
        if r is None:
            raise HTTPException(status_code=404, detail="Sauvegarde introuvable ou déjà testée")
        if body.resultat == "echec":
            alerter(cur, "sauvegarde_ancienne", f"Le test de restauration de la sauvegarde n°{sauvegarde_id} a ÉCHOUÉ", "elevee", user.id)
        return r


# ------------------------------------------------------------------ état général
@router.get("/etat")
def etat(user: User = Depends(require("securite:read"))):
    """Indicateurs de sécurité : sauvegardes, comptes à risque, alertes ouvertes."""
    with tx() as cur:
        sauv = one_row(cur, "SELECT max(effectuee_le) AS derniere, (SELECT derniere_fiable FROM v_sauvegarde_fiable) AS derniere_fiable, "
                            "max(test_restaure_le) FILTER (WHERE test_resultat = 'reussi') AS dernier_test_reussi FROM sauvegarde")
        comptes = one_row(
            cur,
            "SELECT count(*) FILTER (WHERE actif) AS actifs, "
            "       count(*) FILTER (WHERE actif AND mot_de_passe_hash IS NULL) AS sans_mot_de_passe, "
            "       count(*) FILTER (WHERE actif AND doit_changer_mdp) AS mot_de_passe_temporaire, "
            "       count(*) FILTER (WHERE actif AND (email IS NULL OR email = '')) AS sans_contact, "
            "       count(*) FILTER (WHERE actif AND verrouille_jusqua > now()) AS verrouilles, "
            "       count(*) FILTER (WHERE actif AND %s > 0 AND mdp_change_le < now() - make_interval(days => %s)) AS mot_de_passe_perime, "
            "       count(*) FILTER (WHERE actif AND (derniere_connexion IS NULL OR derniere_connexion < now() - interval '90 days')) AS inactifs_90j "
            "FROM utilisateur",
            (settings.password_max_age_days, settings.password_max_age_days),
        )
        alertes_ouvertes = one_row(cur, "SELECT count(*) AS n, count(*) FILTER (WHERE gravite = 'elevee') AS elevees FROM alerte_securite WHERE traitee_le IS NULL")
    maintenant = dt.datetime.now(dt.timezone.utc)
    constats = []
    if sauv["derniere"] is None or sauv["derniere"] < maintenant - dt.timedelta(days=SAUVEGARDE_MAX_JOURS):
        constats.append({"gravite": "elevee", "texte": f"Aucune sauvegarde enregistrée depuis plus de {SAUVEGARDE_MAX_JOURS} jours"})
    if sauv["dernier_test_reussi"] is None or sauv["dernier_test_reussi"] < maintenant - dt.timedelta(days=RESTAURATION_MAX_JOURS):
        constats.append({"gravite": "elevee", "texte": f"Aucun test de restauration réussi depuis {RESTAURATION_MAX_JOURS} jours : une sauvegarde non testée n'est pas fiable"})
    if comptes["sans_contact"]:
        constats.append({"gravite": "moyenne", "texte": f"{comptes['sans_contact']} compte(s) sans adresse de contact : récupération du mot de passe impossible"})
    if comptes["mot_de_passe_perime"]:
        constats.append({"gravite": "moyenne", "texte": f"{comptes['mot_de_passe_perime']} compte(s) avec mot de passe périmé"})
    if comptes["inactifs_90j"]:
        constats.append({"gravite": "faible", "texte": f"{comptes['inactifs_90j']} compte(s) actif(s) sans connexion depuis 90 jours : à désactiver ?"})
    return {"sauvegardes": sauv, "comptes": comptes, "alertes": alertes_ouvertes, "constats": constats,
            "politique": {"session_minutes": settings.session_inactivity_minutes, "mdp_longueur_min": settings.password_min_length,
                          "mdp_validite_jours": settings.password_max_age_days, "mdp_historique": settings.password_history,
                          "verrouillage": f"{settings.max_failed_logins} échecs / {settings.lockout_minutes} min",
                          "heures_ouvrables": settings.heures_ouvrables}}
