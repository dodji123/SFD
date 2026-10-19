"""Accès PostgreSQL : pool de connexions et transaction explicite par requête.

Chaque route ouvre `with tx(user.login) as cur:` : la transaction est validée à la sortie du bloc,
annulée si une exception le traverse. L'utilisateur est transmis à la base (`mf.utilisateur`) pour la
piste d'audit.
"""
from contextlib import contextmanager
from typing import Any, Iterator

import psycopg2
import psycopg2.extras
import psycopg2.pool

from .config import settings

_pool: psycopg2.pool.ThreadedConnectionPool | None = None


def init_pool() -> None:
    global _pool
    if _pool is None:
        _pool = psycopg2.pool.ThreadedConnectionPool(
            1, settings.pool_max, settings.database_url, options="-c search_path=mf,public"
        )


def close_pool() -> None:
    global _pool
    if _pool is not None:
        _pool.closeall()
        _pool = None


@contextmanager
def tx(login: str | None = None) -> Iterator["psycopg2.extras.RealDictCursor"]:
    init_pool()
    assert _pool is not None
    conn = _pool.getconn()
    try:
        conn.autocommit = False
        cur = conn.cursor(cursor_factory=psycopg2.extras.RealDictCursor)
        if login:
            cur.execute("SELECT set_config('mf.utilisateur', %s, true)", (login,))
        yield cur
        conn.commit()
    except BaseException:
        conn.rollback()
        raise
    finally:
        _pool.putconn(conn)


def all_rows(cur, sql: str, params: Any = None) -> list[dict]:
    cur.execute(sql, params)
    return [dict(r) for r in cur.fetchall()]


def one_row(cur, sql: str, params: Any = None) -> dict | None:
    cur.execute(sql, params)
    r = cur.fetchone()
    return dict(r) if r else None
