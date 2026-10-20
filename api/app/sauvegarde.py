"""Sauvegarde automatisée de la base, avec somme de contrôle, enregistrement au registre et test de restauration
sur une base temporaire. Utilise pg_dump / psql du poste, ou ceux d'un conteneur Docker (SFD_BACKUP_DOCKER_CONTAINER).

Le test automatique est enregistré sans « test_par » : il complète, sans remplacer, le test fait par une personne
(onglet Sécurité) que le guide exige pour une sauvegarde de référence."""
import datetime as dt
import hashlib
import os
import pathlib
import shutil
import subprocess
from urllib.parse import urlparse

import psycopg2

from .config import settings


def _cible() -> tuple[str, str, str, str]:
    u = urlparse(settings.database_url)
    return u.hostname or "localhost", str(u.port or 5432), u.username or "postgres", (u.path or "/sfd").lstrip("/")


def _env():
    env = os.environ.copy()
    env["PGPASSWORD"] = urlparse(settings.database_url).password or ""
    return env


def _commande(outil: str, args: list[str]) -> list[str]:
    conteneur = settings.backup_docker_container
    if conteneur:
        return ["docker", "exec", "-i", conteneur, outil, *args]
    if shutil.which(outil) is None:
        raise RuntimeError(f"{outil} introuvable : installer le client PostgreSQL ou définir SFD_BACKUP_DOCKER_CONTAINER")
    return [outil, *args]


def _args_connexion(user: str, base: str, hote: str, port: str, extra: list[str]) -> list[str]:
    args = ["-U", user, "-d", base, *extra]
    return args if settings.backup_docker_container else ["-h", hote, "-p", port, *args]


def sauvegarder(dossier: str) -> dict:
    """Écrit un dump complet dans `dossier`, calcule son empreinte SHA-256 et l'enregistre au registre."""
    hote, port, user, base = _cible()
    rep = pathlib.Path(dossier)
    rep.mkdir(parents=True, exist_ok=True, mode=0o700)
    os.chmod(rep, 0o700)           # un dump contient toutes les données : lisible par son propriétaire seulement
    fichier = rep / f"{base}_{dt.datetime.now():%Y%m%d_%H%M%S}.sql"
    with os.fdopen(os.open(fichier, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600), "wb") as f:
        r = subprocess.run(_commande("pg_dump", _args_connexion(user, base, hote, port, ["--no-owner"])), stdout=f, stderr=subprocess.PIPE, env=_env())
    if r.returncode != 0 or fichier.stat().st_size == 0:
        fichier.unlink(missing_ok=True)
        raise RuntimeError("pg_dump a échoué : " + r.stderr.decode(errors="replace")[:300])
    h = hashlib.sha256()
    with open(fichier, "rb") as f:
        for bloc in iter(lambda: f.read(1 << 20), b""):
            h.update(bloc)
    conn = psycopg2.connect(settings.database_url, options="-c search_path=mf,public")
    conn.autocommit = True
    cur = conn.cursor()
    cur.execute("INSERT INTO sauvegarde(effectuee_le, type, support, emplacement, taille_mo, empreinte) "
                "VALUES (now(), 'complete', %s, %s, %s, %s) RETURNING id",
                ("Fichier local (automatique)", str(fichier), round(fichier.stat().st_size / 1048576, 2), h.hexdigest()))
    sid = cur.fetchone()[0]
    conn.close()
    return {"id": sid, "fichier": str(fichier), "empreinte": h.hexdigest()}


def tester_restauration(sauvegarde_id: int) -> dict:
    """Rejoue le dump dans une base temporaire et vérifie la présence des tables ; enregistre le résultat."""
    hote, port, user, base = _cible()
    conn = psycopg2.connect(settings.database_url, options="-c search_path=mf,public")
    conn.autocommit = True
    cur = conn.cursor()
    cur.execute("SELECT emplacement, empreinte FROM sauvegarde WHERE id = %s AND test_restaure_le IS NULL", (sauvegarde_id,))
    r = cur.fetchone()
    if r is None:
        raise RuntimeError("Sauvegarde introuvable ou déjà testée")
    fichier = pathlib.Path(r[0])
    resultat, commentaire = "echec", ""
    temp = f"{base}_restauration_test"
    racine = settings.database_url.rsplit("/", 1)[0]
    admin = psycopg2.connect(racine + "/postgres")
    admin.autocommit = True
    ac = admin.cursor()
    try:
        contenu = fichier.read_bytes()
        if hashlib.sha256(contenu).hexdigest() != r[1]:
            commentaire = "empreinte différente : le fichier a été altéré"
        else:
            ac.execute(f'DROP DATABASE IF EXISTS "{temp}" WITH (FORCE)')
            ac.execute(f'CREATE DATABASE "{temp}"')
            p = subprocess.run(_commande("psql", _args_connexion(user, temp, hote, port, ["-v", "ON_ERROR_STOP=1", "-q"])),
                               input=contenu, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, env=_env())
            if p.returncode != 0:
                commentaire = "restauration en erreur : " + p.stderr.decode(errors="replace")[:200]
            else:
                tc = psycopg2.connect(racine + "/" + temp)
                c2 = tc.cursor()
                c2.execute("SELECT count(*) FROM information_schema.tables WHERE table_schema = 'mf'")
                n = c2.fetchone()[0]
                tc.close()
                resultat, commentaire = ("reussi", f"{n} tables restaurées dans une base temporaire") if n > 20 else ("echec", f"seulement {n} tables")
    except Exception as e:  # noqa: BLE001 — toute erreur est un échec du test, consignée au registre
        commentaire = f"erreur : {e}"[:300]
    finally:
        ac.execute(f'DROP DATABASE IF EXISTS "{temp}" WITH (FORCE)')
        admin.close()
    cur.execute("UPDATE sauvegarde SET test_restaure_le = now(), test_resultat = %s, test_commentaire = %s WHERE id = %s",
                (resultat, "Test automatique : " + commentaire, sauvegarde_id))
    conn.close()
    return {"resultat": resultat, "commentaire": commentaire}
