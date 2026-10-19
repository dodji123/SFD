"""Fixtures : base PostgreSQL de test reconstruite depuis les modules SQL, client HTTP, utilisateurs par rôle.

Prérequis : conteneur PostgreSQL du projet (sfd-pg, port 5440) ou SFD_TEST_ADMIN_URL.
Les tests partagent une base de session ; chaque fichier de test travaille dans sa propre agence."""
import glob
import os
import pathlib

import psycopg2
import psycopg2.extras
import pytest

ADMIN_URL = os.environ.get("SFD_TEST_ADMIN_URL", "postgresql://postgres:sfd@localhost:5440/postgres")
TEST_DB = "sfd_api_test"
TEST_URL = ADMIN_URL.rsplit("/", 1)[0] + "/" + TEST_DB
os.environ["SFD_DATABASE_URL"] = TEST_URL
os.environ["SFD_JWT_SECRET"] = "secret-de-test-assez-long-0123456789abcdef"
os.environ["SFD_ENV"] = "test"
os.environ["SFD_MAX_FAILED_LOGINS"] = "5"

from tests.helpers import PWD, make_user  # noqa: E402

SCHEMA_DIR = pathlib.Path(__file__).resolve().parents[2] / "schema"


def _modules() -> list[pathlib.Path]:
    """Même ordre que tools/build_schema_complet.sh."""
    out: list[pathlib.Path] = []
    for pat in ("0[0-5]_*.sql", "07_*.sql", "08_*.sql", "09_*.sql", "[123][0-9]_*.sql"):
        out += [pathlib.Path(p) for p in sorted(glob.glob(str(SCHEMA_DIR / pat)))]
    return out


@pytest.fixture(scope="session", autouse=True)
def base_de_test():
    admin = psycopg2.connect(ADMIN_URL)
    admin.autocommit = True
    cur = admin.cursor()
    cur.execute(f"DROP DATABASE IF EXISTS {TEST_DB} WITH (FORCE)")
    cur.execute(f"CREATE DATABASE {TEST_DB}")
    admin.close()
    conn = psycopg2.connect(TEST_URL)
    conn.autocommit = True
    for f in _modules():
        conn.cursor().execute(f.read_text(encoding="utf-8"))
    # les tests existants ouvrent des comptes sans adhésion ; test_adhesion.py active le contrôle le temps de ses vérifications
    conn.cursor().execute("UPDATE mf.parametre SET valeur = 'non' WHERE cle = 'adhesion_obligatoire' AND agence_id IS NULL")
    conn.close()
    yield


@pytest.fixture(scope="session")
def client(base_de_test):
    from fastapi.testclient import TestClient

    from app.main import app

    with TestClient(app) as c:
        yield c


@pytest.fixture(scope="session")
def sql(base_de_test):
    """Exécute du SQL directement dans la base de test (validation immédiate). Retourne les lignes (dict) s'il y en a."""
    conn = psycopg2.connect(TEST_URL, options="-c search_path=mf,public")
    conn.autocommit = True

    def run(query: str, params=None):
        cur = conn.cursor(cursor_factory=psycopg2.extras.RealDictCursor)
        cur.execute(query, params)
        return [dict(r) for r in cur.fetchall()] if cur.description else []

    yield run
    conn.close()


@pytest.fixture(scope="session")
def agences(sql):
    a1 = sql("INSERT INTO agence(code, libelle) VALUES ('T1', 'Agence test 1') RETURNING id")[0]["id"]
    a2 = sql("INSERT INTO agence(code, libelle) VALUES ('T2', 'Agence test 2') RETURNING id")[0]["id"]
    return {"a1": a1, "a2": a2}


@pytest.fixture(scope="session")
def produits(sql):
    """Produits d'épargne (globaux) : P1/P2/P3 = tontine de types 1/2/3 (1 page), CL = compte classique (minimum 5000)."""
    ids = {}
    for code, cat, tc, pages, mini in (("P1", "collecte", 1, 1, 0), ("P2", "collecte", 2, 1, 0), ("P3", "collecte", 3, 1, 0),
                                       ("CL", "classique", None, 1, 5000)):
        ids[code] = sql(
            "INSERT INTO produit_epargne(code, libelle, categorie, type_cycle, nb_pages_livret, solde_minimum) "
            "VALUES (%s, %s, %s, %s, %s, %s) RETURNING id", (code, code, cat, tc, pages, mini))[0]["id"]
    return ids


@pytest.fixture(scope="session")
def utilisateurs(sql, agences):
    """Un utilisateur par rôle utile. Retourne {login: id}."""
    a1, a2 = agences["a1"], agences["a2"]
    spec = [
        ("admin", "admin", None), ("directeur", "directeur", None), ("comptable", "comptable", None),
        ("auditeur", "auditeur", None), ("chef1", "chef_agence", a1), ("caissier1", "caissier", a1),
        ("agent1", "agent", a1), ("coll1", "collectrice", a1), ("rh1", "rh", a1), ("chef2", "chef_agence", a2),
        ("caissier2", "caissier", a2),
    ]
    return {login: make_user(sql, login, role, ag) for login, role, ag in spec}


def _headers(client, login: str, pwd: str = PWD) -> dict:
    r = client.post("/api/auth/login", json={"login": login, "mot_de_passe": pwd})
    assert r.status_code == 200, r.text
    return {"Authorization": "Bearer " + r.json()["access_token"]}


@pytest.fixture(scope="session")
def h(client, utilisateurs):
    """h('chef1') -> en-têtes d'autorisation (connexion mise en cache)."""
    cache: dict[str, dict] = {}

    def get(login: str) -> dict:
        if login not in cache:
            cache[login] = _headers(client, login)
        return cache[login]

    return get
