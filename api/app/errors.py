"""Traduit les erreurs PostgreSQL en réponses HTTP lisibles.

Les règles métier du schéma (RAISE EXCEPTION) deviennent des 422 avec le message de la base, en français.
Les messages d'erreurs inattendues ne sont pas exposés."""
import logging

import psycopg2
import psycopg2.pool
from fastapi import FastAPI, Request
from fastapi.responses import JSONResponse

log = logging.getLogger("sfd")

# code SQLSTATE -> statut HTTP
_STATUTS = {
    "P0001": 422,  # RAISE EXCEPTION : règle métier du schéma
    "23514": 422,  # check_violation
    "23502": 422,  # not_null_violation
    "22P02": 422,  # invalid_text_representation
    "22003": 422,  # numeric_value_out_of_range
    "22007": 422,  # invalid_datetime_format
    "22008": 422,  # datetime_field_overflow
    "23505": 409,  # unique_violation
    "23503": 409,  # foreign_key_violation
    "23P01": 409,  # exclusion_violation
    "40001": 409,  # serialization_failure
    "40P01": 409,  # deadlock_detected
}


def message_pg(e: psycopg2.Error) -> str:
    msg = (e.diag.message_primary if e.diag and e.diag.message_primary else None) or "Opération refusée"
    if e.pgcode == "23505":
        return "Doublon : " + (e.diag.constraint_name or msg)
    if e.pgcode == "23503":
        return "Référence invalide ou encore utilisée : " + (e.diag.constraint_name or msg)
    return msg


def install(app: FastAPI) -> None:
    @app.exception_handler(psycopg2.Error)
    async def _pg(request: Request, exc: psycopg2.Error):
        status = _STATUTS.get(exc.pgcode or "")
        if status is None:
            log.exception("erreur PostgreSQL inattendue (%s)", exc.pgcode)
            return JSONResponse(status_code=500, content={"detail": "Erreur interne"})
        return JSONResponse(status_code=status, content={"detail": message_pg(exc)})

    @app.exception_handler(psycopg2.pool.PoolError)
    async def _pool(request: Request, exc: Exception):
        log.error("pool de connexions épuisé")
        return JSONResponse(status_code=503, content={"detail": "Service momentanément saturé"})
