"""Outils en ligne de commande.

  python -m app.cli init-schema                      charge les modules SQL dans la base (SFD_DATABASE_URL) vierge
  python -m app.cli creer-utilisateur --login ... --nom ... --role admin [--agence-code LOM]
                                                     (le mot de passe est demandé, jamais passé en argument)
  python -m app.cli donnees-demo                     jeu de démonstration (refusé si SFD_ENV=prod)
  python -m app.cli planifier [--date AAAA-MM-JJ] [--agence-code LOM] [--forcer]
                                                     traitements quotidiens de toutes les agences (voir planificateur.py)
"""
import argparse
import datetime as dt
import getpass
import glob
import pathlib
import sys

import psycopg2

from .auth import hash_password
from .config import settings

SCHEMA_DIR = pathlib.Path(__file__).resolve().parents[2] / "schema"


def modules() -> list[pathlib.Path]:
    out: list[pathlib.Path] = []
    for pat in ("0[0-5]_*.sql", "07_*.sql", "08_*.sql", "09_*.sql", "[12][0-9]_*.sql"):
        out += [pathlib.Path(p) for p in sorted(glob.glob(str(SCHEMA_DIR / pat)))]
    return out


def connect():
    return psycopg2.connect(settings.database_url, options="-c search_path=mf,public")


def init_schema() -> None:
    conn = psycopg2.connect(settings.database_url)
    conn.autocommit = True
    cur = conn.cursor()
    cur.execute("SELECT 1 FROM information_schema.schemata WHERE schema_name = 'mf'")
    if cur.fetchone():
        sys.exit("Le schéma mf existe déjà : base non vierge, rien n'a été fait.")
    for f in modules():
        print("charge", f.name)
        cur.execute(f.read_text(encoding="utf-8"))
    print("schéma chargé.")


def creer_utilisateur(login: str, nom: str, role: str, agence_code: str | None) -> None:
    mdp = getpass.getpass("Mot de passe : ")
    if len(mdp) < settings.password_min_length:
        sys.exit(f"Le mot de passe doit comporter au moins {settings.password_min_length} caractères.")
    if mdp != getpass.getpass("Confirmer : "):
        sys.exit("Les mots de passe diffèrent.")
    conn = connect()
    with conn, conn.cursor() as cur:
        agence_id = None
        if agence_code:
            cur.execute("SELECT id FROM agence WHERE code = %s", (agence_code,))
            r = cur.fetchone()
            if not r:
                sys.exit(f"Agence inconnue : {agence_code}")
            agence_id = r[0]
        cur.execute(
            "INSERT INTO utilisateur(login, nom, role, agence_id, mot_de_passe_hash) VALUES (%s, %s, %s::role_utilisateur, %s, %s)",
            (login, nom, role, agence_id, hash_password(mdp)),
        )
    print("utilisateur créé :", login)


def main(argv: list[str] | None = None) -> None:
    p = argparse.ArgumentParser(prog="python -m app.cli")
    sub = p.add_subparsers(dest="cmd", required=True)
    sub.add_parser("init-schema")
    sub.add_parser("donnees-demo")
    pl = sub.add_parser("planifier", help="traitements quotidiens de toutes les agences (cron / tâche planifiée)")
    pl.add_argument("--date", type=dt.date.fromisoformat, help="AAAA-MM-JJ (défaut : aujourd'hui)")
    pl.add_argument("--agence-code", help="limiter à une agence")
    pl.add_argument("--forcer", action="store_true", help="rejouer aussi les tâches déjà réussies pour cette date")
    u =sub.add_parser("creer-utilisateur")
    u.add_argument("--login", required=True)
    u.add_argument("--nom", required=True)
    u.add_argument("--role", required=True,
                   choices=["admin", "directeur", "chef_agence", "caissier", "comptable", "agent", "collectrice", "rh", "auditeur"])
    u.add_argument("--agence-code")
    a = p.parse_args(argv)
    if a.cmd == "init-schema":
        init_schema()
    elif a.cmd == "creer-utilisateur":
        creer_utilisateur(a.login, a.nom, a.role, a.agence_code)
    elif a.cmd == "planifier":
        import logging

        from .planificateur import planifier

        logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
        try:
            res = planifier(a.date, a.agence_code, a.forcer)
        except (ValueError, RuntimeError) as e:
            sys.exit(str(e))
        if any(r.statut == "echec" for r in res):
            sys.exit(1)
    elif a.cmd == "donnees-demo":
        if settings.env == "prod":
            sys.exit("Données de démonstration refusées en production.")
        from .demo import charger

        charger()


if __name__ == "__main__":
    main()
