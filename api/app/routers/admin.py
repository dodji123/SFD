"""Paramètres de l'application et consultation de la piste d'audit."""
from fastapi import APIRouter, Depends, HTTPException, Query
from pydantic import BaseModel, Field

from ..auth import User, agence_filter, require
from ..db import all_rows, one_row, tx

router = APIRouter(prefix="/api", tags=["administration"])

ENUMS = {
    "comptabilisation_auto": {"oui", "non"},
    "mode_cloture": {"calendaire_mensuel", "date_fin_client"},
    "arrondi_mode": {"plus_proche", "superieur", "inferieur"},
}


def _valider(cle: str, valeur: str) -> None:
    if cle in ENUMS:
        if valeur not in ENUMS[cle]:
            raise HTTPException(status_code=422, detail=f"Valeur autorisée pour {cle} : {', '.join(sorted(ENUMS[cle]))}")
        return
    try:
        float(valeur)
    except ValueError:
        raise HTTPException(status_code=422, detail=f"{cle} doit être un nombre")


@router.get("/parametres")
def lister(agence_id: int | None = None, user: User = Depends(require("params:read"))):
    """Valeur effective de chaque paramètre pour l'agence (surcharge d'agence sinon valeur globale)."""
    ag = agence_filter(user, agence_id)
    with tx() as cur:
        return all_rows(
            cur,
            "SELECT DISTINCT ON (cle) cle, valeur, description, agence_id FROM parametre "
            "WHERE agence_id IS NULL OR agence_id = %s ORDER BY cle, agence_id NULLS LAST", (ag,))


class ParametreIn(BaseModel):
    valeur: str = Field(min_length=1, max_length=200)
    agence_id: int | None = None      # vide : valeur globale


@router.put("/parametres/{cle}")
def modifier(cle: str, body: ParametreIn, user: User = Depends(require("params:write"))):
    _valider(cle, body.valeur)
    with tx(user.login) as cur:
        g = one_row(cur, "SELECT description FROM parametre WHERE cle = %s AND agence_id IS NULL", (cle,))
        if g is None:
            raise HTTPException(status_code=404, detail="Paramètre inconnu")
        cur.execute("UPDATE parametre SET valeur = %s WHERE cle = %s AND agence_id IS NOT DISTINCT FROM %s",
                    (body.valeur, cle, body.agence_id))
        if cur.rowcount == 0:
            cur.execute("INSERT INTO parametre(agence_id, cle, valeur, description) VALUES (%s, %s, %s, %s)",
                        (body.agence_id, cle, body.valeur, g["description"]))
        return one_row(cur, "SELECT cle, valeur, description, agence_id FROM parametre WHERE cle = %s AND agence_id IS NOT DISTINCT FROM %s",
                       (cle, body.agence_id))


@router.get("/audit")
def audit(table_name: str | None = None, ligne_id: str | None = None, utilisateur: str | None = None,
          limit: int = Query(100, ge=1, le=1000), user: User = Depends(require("audit:read"))):
    with tx() as cur:
        return all_rows(
            cur,
            "SELECT id, horodatage, utilisateur, table_name, operation, ligne_id, avant, apres FROM audit_log "
            "WHERE (%s::text IS NULL OR table_name = %s) AND (%s::text IS NULL OR ligne_id = %s) "
            "AND (%s::text IS NULL OR utilisateur = %s) ORDER BY id DESC LIMIT %s",
            (table_name, table_name, ligne_id, ligne_id, utilisateur, utilisateur, limit),
        )
