"""Envoi de SMS. Aucun fournisseur n'est branché : le mode « console » journalise le message (développement),
le mode « disabled » refuse l'envoi. Pour la production, remplacer le corps de `envoyer` par l'appel à la
passerelle choisie (clé d'API en variable d'environnement, jamais dans le dépôt)."""
import logging

from fastapi import HTTPException

from .config import settings

log = logging.getLogger("sfd.sms")


def masquer_telephone(tel: str | None) -> str:
    if not tel:
        return ""
    t = tel.strip()
    return t[:2] + "*" * (len(t) - 4) + t[-2:] if len(t) > 4 else "*" * len(t)


def envoyer(telephone: str, texte: str) -> None:
    if settings.sms_mode == "console" and settings.env != "prod":
        log.warning("SMS (mode console) vers %s : %s", masquer_telephone(telephone), texte)
        return
    raise HTTPException(status_code=503, detail="Service SMS non configuré")
