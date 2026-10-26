"""Fiche de suivi des tests manuels (module 65) : chacun coche son résultat et laisse un commentaire."""
from typing import Literal

from fastapi import APIRouter, Depends, HTTPException
from pydantic import BaseModel, Field

from ..auth import User, require
from ..db import all_rows, one_row, tx

router = APIRouter(prefix="/api/fiche-tests", tags=["fiche-tests"])


class SaisieTest(BaseModel):
    statut: Literal["a_faire", "ok", "ko"]
    commentaire: str | None = Field(default=None, max_length=1000)


@router.get("")
def lister(user: User = Depends(require("ref:read"))):
    with tx() as cur:
        return all_rows(cur, "SELECT section, numero, parcours, resultat_attendu, statut, commentaire, modifie_par, modifie_le "
                             "FROM fiche_test_manuel ORDER BY id")


@router.put("/{numero}")
def saisir(numero: str, body: SaisieTest, user: User = Depends(require("ref:read"))):
    with tx(user.login) as cur:
        r = one_row(cur, "UPDATE fiche_test_manuel SET statut = %s, commentaire = %s, modifie_par = %s, modifie_le = now() "
                         "WHERE numero = %s RETURNING numero", (body.statut, body.commentaire, user.login, numero))
        if r is None:
            raise HTTPException(status_code=404, detail="Test introuvable")
        return one_row(cur, "SELECT numero, statut, commentaire, modifie_par, modifie_le FROM fiche_test_manuel WHERE numero = %s", (numero,))
