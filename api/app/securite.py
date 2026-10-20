"""Briques de sécurité des comptes du personnel : politique de mot de passe, journal des connexions,
alertes de sécurité, messages de récupération. Utilisé par routers/auth.py et routers/utilisateurs.py."""
import datetime as dt
import hashlib
import logging
import re
import secrets

from fastapi import HTTPException, Request

from .auth import verify_password
from .config import settings

log = logging.getLogger("sfd.securite")

SPECIAUX = r"""[!@#$%^&*()_+\-=\[\]{};':"\\|,.<>/?~`€£§°]"""


def ip_client(request: Request | None) -> str | None:
    if request is None or request.client is None:
        return None
    return request.client.host


def erreurs_politique(nouveau: str, login: str) -> list[str]:
    """Règles de composition d'un mot de passe (guide du contrôle interne : mot de passe robuste)."""
    e = []
    if len(nouveau) < settings.password_min_length:
        e.append(f"au moins {settings.password_min_length} caractères")
    if not re.search(r"[a-z]", nouveau):
        e.append("une minuscule")
    if not re.search(r"[A-Z]", nouveau):
        e.append("une majuscule")
    if not re.search(r"\d", nouveau):
        e.append("un chiffre")
    if not re.search(SPECIAUX, nouveau):
        e.append("un caractère spécial")
    if login and len(login) >= 3 and login.lower() in nouveau.lower():
        e.append("ne doit pas contenir l'identifiant")
    return e


def verifier_politique(cur, nouveau: str, login: str, user_id: int | None) -> None:
    """Lève 422 si le mot de passe est trop faible ou déjà utilisé récemment."""
    e = erreurs_politique(nouveau, login)
    if e:
        raise HTTPException(status_code=422, detail="Mot de passe trop faible : " + ", ".join(e))
    if user_id is not None and settings.password_history > 0:
        cur.execute("SELECT hash FROM historique_mdp WHERE utilisateur_id = %s ORDER BY id DESC LIMIT %s",
                    (user_id, settings.password_history))
        for r in cur.fetchall():
            if verify_password(nouveau, r["hash"]):
                raise HTTPException(
                    status_code=422,
                    detail=f"Ce mot de passe a déjà été utilisé : choisissez-en un différent des {settings.password_history} derniers")


def journaliser(cur, login: str, user_id: int | None, evenement: str, ip: str | None = None, detail: str | None = None) -> None:
    cur.execute("INSERT INTO journal_connexion(login, utilisateur_id, evenement, ip, detail) VALUES (%s, %s, %s, %s, %s)",
                (login[:60], user_id, evenement, ip, detail))


def alerter(cur, type_: str, detail: str, gravite: str = "moyenne", user_id: int | None = None, agence_id: int | None = None) -> None:
    cur.execute("INSERT INTO alerte_securite(type, gravite, utilisateur_id, agence_id, detail) VALUES (%s, %s, %s, %s, %s)",
                (type_, gravite, user_id, agence_id, detail))


def hors_heures(maintenant: dt.datetime | None = None) -> bool:
    """Vrai si l'heure courante est hors de la plage ouvrable configurée (HH-HH)."""
    try:
        a, b = (int(x) for x in settings.heures_ouvrables.split("-"))
    except ValueError:
        return False
    h = (maintenant or dt.datetime.now()).hour
    return not (a <= h < b)


def nouveau_jeton() -> tuple[str, str]:
    """(jeton remis à l'utilisateur, haché conservé en base)."""
    jeton = secrets.token_urlsafe(32)
    return jeton, hashlib.sha256(jeton.encode()).hexdigest()


def hacher_jeton(jeton: str) -> str:
    return hashlib.sha256(jeton.encode()).hexdigest()


def envoyer_message(cur, user_id: int, canal: str, destinataire: str, objet: str, corps: str) -> None:
    """Dépose le message dans la file sortante ; en mode « console », il est aussi journalisé (développement)."""
    cur.execute("INSERT INTO message_personnel(utilisateur_id, canal, destinataire, objet, corps) VALUES (%s, %s, %s, %s, %s)",
                (user_id, canal, destinataire, objet, corps))
    if settings.mail_mode == "console":
        log.warning("MESSAGE [%s -> %s] %s\n%s", canal, destinataire, objet, corps)
    elif settings.mail_mode == "smtp" and canal == "email":
        _envoyer_smtp(cur, destinataire, objet, corps)


def _envoyer_smtp(cur, destinataire: str, objet: str, corps: str) -> None:
    """Envoi réel ; un échec ne bloque jamais l'opération : le message passe à « echec » avec l'erreur journalisée."""
    import smtplib
    from email.message import EmailMessage
    cur.execute("SELECT max(id) AS id FROM message_personnel WHERE destinataire = %s", (destinataire,))
    mid = cur.fetchone()["id"]
    try:
        if not (settings.smtp_host and settings.smtp_from):
            raise RuntimeError("SFD_SMTP_HOST et SFD_SMTP_FROM sont obligatoires en mode smtp")
        m = EmailMessage()
        m["From"], m["To"], m["Subject"] = settings.smtp_from, destinataire, objet
        m.set_content(corps)
        with smtplib.SMTP(settings.smtp_host, settings.smtp_port, timeout=10) as s:
            if settings.smtp_starttls:
                s.starttls()
            if settings.smtp_user:
                s.login(settings.smtp_user, settings.smtp_password)
            s.send_message(m)
        cur.execute("UPDATE message_personnel SET statut = 'envoye', envoye_le = now() WHERE id = %s", (mid,))
    except Exception as e:  # noqa: BLE001
        log.error("envoi du message impossible : %s", e)
        cur.execute("UPDATE message_personnel SET statut = 'echec' WHERE id = %s", (mid,))
