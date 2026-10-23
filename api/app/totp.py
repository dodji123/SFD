"""Second facteur TOTP (RFC 6238, SHA-1, 6 chiffres, pas de 30 s) sans dépendance externe, et codes de secours.

Le secret est chiffré (Fernet) avant d'aller en base : une fuite de la base seule ne donne pas les secrets.
Le format stocké « v1:<jeton> » prépare la rotation de la clé."""
import base64
import hashlib
import hmac
import secrets
import struct
import time
from urllib.parse import quote

from cryptography.fernet import Fernet, InvalidToken

from .config import settings

PAS = 30
CHIFFRES = 6
FENETRE = 1                      # pas accepté de part et d'autre (dérive d'horloge de ±30 s)
ALPHABET_SECOURS = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"      # sans I, O, 0, 1


def nouveau_secret() -> str:
    return base64.b32encode(secrets.token_bytes(20)).decode().rstrip("=")


def _hotp(secret_b32: str, compteur: int) -> str:
    cle = base64.b32decode(secret_b32 + "=" * (-len(secret_b32) % 8), casefold=True)
    h = hmac.new(cle, struct.pack(">Q", compteur), hashlib.sha1).digest()
    o = h[-1] & 0x0F
    n = (struct.unpack(">I", h[o:o + 4])[0] & 0x7FFFFFFF) % (10 ** CHIFFRES)
    return str(n).zfill(CHIFFRES)


def code_a(secret_b32: str, instant: float | None = None) -> str:
    return _hotp(secret_b32, int((instant if instant is not None else time.time()) // PAS))


def verifier(secret_b32: str, code: str, dernier_pas: int = 0, instant: float | None = None) -> int | None:
    """Retourne le pas accepté, ou None. Un pas inférieur ou égal à `dernier_pas` est refusé (rejeu)."""
    code = (code or "").strip().replace(" ", "")
    if not (len(code) == CHIFFRES and code.isdigit()):
        return None
    courant = int((instant if instant is not None else time.time()) // PAS)
    trouve = None
    for pas in range(courant - FENETRE, courant + FENETRE + 1):          # tous les pas sont testés (temps constant)
        if hmac.compare_digest(_hotp(secret_b32, pas), code) and pas > dernier_pas:
            trouve = pas
    return trouve


def uri(secret_b32: str, login: str) -> str:
    emetteur = quote(settings.totp_issuer)
    return f"otpauth://totp/{emetteur}:{quote(login)}?secret={secret_b32}&issuer={emetteur}&algorithm=SHA1&digits={CHIFFRES}&period={PAS}"


# ------------------------------------------------------------------ chiffrement du secret
def _fernet() -> Fernet:
    base = settings.totp_key or settings.secret()
    return Fernet(base64.urlsafe_b64encode(hashlib.sha256(b"sfd-totp|" + base.encode()).digest()))


def chiffrer(secret_b32: str) -> str:
    return "v1:" + _fernet().encrypt(secret_b32.encode()).decode()


def dechiffrer(stocke: str) -> str:
    try:
        return _fernet().decrypt(stocke.removeprefix("v1:").encode()).decode()
    except InvalidToken as e:                                       # clé changée sans migration des secrets
        raise RuntimeError("Secret TOTP indéchiffrable : clé SFD_TOTP_KEY / SFD_JWT_SECRET modifiée ?") from e


# ------------------------------------------------------------------ codes de secours
def normaliser_secours(code: str) -> str:
    return (code or "").upper().replace("-", "").replace(" ", "")


def hacher_secours(code: str) -> str:
    return hashlib.sha256(normaliser_secours(code).encode()).hexdigest()


def nouveaux_codes_secours(n: int | None = None) -> list[str]:
    """Codes lisibles « XXXXX-XXXXX » (10 caractères, 50 bits) ; montrés une seule fois, seul le haché est conservé."""
    out = []
    for _ in range(n or settings.totp_codes_secours):
        c = "".join(secrets.choice(ALPHABET_SECOURS) for _ in range(10))
        out.append(f"{c[:5]}-{c[5:]}")
    return out


def est_code_secours(code: str) -> bool:
    c = normaliser_secours(code)
    return len(c) == 10 and all(ch in ALPHABET_SECOURS for ch in c)


def roles_obligatoires() -> set[str]:
    return {r.strip() for r in settings.totp_roles.split(",") if r.strip()}
