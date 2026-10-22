"""Passerelle mobile money. Aucun opérateur réel n'est branché : le mode « simulation » (défaut) permet de démontrer tout le
parcours (initiation, confirmation, échec, expiration) sans argent réel ; le mode « live » est à implémenter avec les accès
fournis par l'opérateur (clés en variables d'environnement, jamais dans le dépôt) ; le mode « disabled » refuse tout paiement.

Contrat avec le reste de l'application :
 - `initier(...)` demande le paiement à l'opérateur et renvoie un dict {reference_operateur, message} ;
 - l'opérateur notifie l'issue sur le webhook `/api/mobile-money/webhook/{operateur}` (signature HMAC-SHA256 du corps brut,
   en-tête `X-Signature`), qui appelle `confirmer_paiement_mobile` ou `echouer_paiement_mobile` (idempotentes)."""
import hashlib
import hmac

from fastapi import HTTPException

from .config import settings


def mode() -> str:
    return settings.mobile_money_mode if settings.mobile_money_mode in ("simulation", "live", "disabled") else "disabled"


def simulation_autorisee() -> bool:
    """La simulation n'existe jamais en production."""
    return mode() == "simulation" and settings.env != "prod"


def initier(reference: str, operateur: str, telephone: str, montant: int) -> dict:
    m = mode()
    if m == "simulation" and settings.env != "prod":
        return {"reference_operateur": f"SIM-{reference}", "message": "Simulation : choisissez l'issue du paiement ci-dessous (aucun argent réel n'est débité)."}
    if m == "live":
        # À brancher : appel de l'API de l'opérateur (collecte « push » USSD) avec ses accès, puis renvoyer sa référence.
        raise HTTPException(status_code=501, detail="Passerelle mobile money réelle non configurée")
    raise HTTPException(status_code=503, detail="Le paiement par mobile money est indisponible")


def signature(corps: bytes, secret: str | None = None) -> str:
    return hmac.new((secret if secret is not None else settings.mobile_money_webhook_secret).encode(), corps, hashlib.sha256).hexdigest()


def signature_valide(corps: bytes, recue: str | None) -> bool:
    if not settings.mobile_money_webhook_secret or not recue:
        return False
    return hmac.compare_digest(signature(corps), recue.strip().lower())
