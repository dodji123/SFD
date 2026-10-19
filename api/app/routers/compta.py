"""Comptabilité : exercices, plan de comptes SFD UMOA, pièces et écritures, balance, grand livre, résultat."""
import datetime as dt
from typing import Literal

from fastapi import APIRouter, Depends, HTTPException, Query
from pydantic import BaseModel, Field, model_validator

from ..auth import User, agence_filter, agence_scope, require, verifier_agence
from ..db import all_rows, one_row, tx

router = APIRouter(prefix="/api/compta", tags=["comptabilite"])


# ---------------------------------------------------------------- exercices
class ExerciceIn(BaseModel):
    code: str = Field(min_length=1, max_length=10)
    date_debut: dt.date
    date_fin: dt.date


@router.get("/exercices")
def exercices(user: User = Depends(require("compta:read"))):
    with tx() as cur:
        return all_rows(cur, "SELECT * FROM exercice_comptable ORDER BY date_debut DESC")


@router.post("/exercices", status_code=201)
def creer_exercice(body: ExerciceIn, user: User = Depends(require("compta:write"))):
    with tx(user.login) as cur:
        return one_row(cur, "INSERT INTO exercice_comptable(code, date_debut, date_fin) VALUES (%s, %s, %s) RETURNING *",
                       (body.code, body.date_debut, body.date_fin))


@router.post("/exercices/{exercice_id}/cloturer")
def cloturer_exercice(exercice_id: int, user: User = Depends(require("compta:write"))):
    with tx(user.login) as cur:
        cur.execute("SELECT cloturer_exercice(%s)", (exercice_id,))
        return one_row(cur, "SELECT * FROM exercice_comptable WHERE id = %s", (exercice_id,))


# ---------------------------------------------------------------- plan de comptes
@router.get("/comptes")
def comptes(q: str | None = None, classe: str | None = Query(None, pattern=r"^[0-9]$"), imputable: bool | None = None,
            limit: int = Query(100, ge=1, le=1500), user: User = Depends(require("compta:read"))):
    with tx() as cur:
        return all_rows(
            cur,
            "SELECT code, libelle, classe, parent, imputable FROM compte_comptable WHERE actif "
            "AND (%s::text IS NULL OR code LIKE %s || '%%' OR libelle ILIKE '%%' || %s || '%%') "
            "AND (%s::text IS NULL OR classe = %s) AND (%s::boolean IS NULL OR imputable = %s) ORDER BY code LIMIT %s",
            (q, q, q, classe, classe, imputable, imputable, limit),
        )


@router.get("/regles")
def regles(user: User = Depends(require("compta:read"))):
    with tx() as cur:
        return all_rows(cur, "SELECT * FROM regle_comptable ORDER BY evenement, ligne, agence_id NULLS FIRST")


# ---------------------------------------------------------------- pièces
PIECE = (
    "SELECT p.id, p.agence_id, p.numero, p.date_piece, p.libelle, p.evenement, p.origine, j.code AS journal, "
    "       (SELECT COALESCE(sum(debit), 0) FROM ecriture e WHERE e.piece_id = p.id) AS total "
    "FROM piece_comptable p JOIN journal j ON j.id = p.journal_id "
)


@router.get("/pieces")
def pieces(agence_id: int | None = None, du: dt.date | None = None, au: dt.date | None = None, journal: str | None = None,
           limit: int = Query(100, ge=1, le=500), user: User = Depends(require("compta:read"))):
    ag = agence_filter(user, agence_id)
    with tx() as cur:
        return all_rows(
            cur,
            PIECE + "WHERE (%s::int IS NULL OR p.agence_id = %s) AND (%s::date IS NULL OR p.date_piece >= %s) "
            "AND (%s::date IS NULL OR p.date_piece <= %s) AND (%s::text IS NULL OR j.code = %s) "
            "ORDER BY p.date_piece DESC, p.id DESC LIMIT %s",
            (ag, ag, du, du, au, au, journal, journal, limit),
        )


def _piece(cur, piece_id: int) -> dict:
    p = one_row(cur, PIECE + "WHERE p.id = %s", (piece_id,))
    p["ecritures"] = all_rows(
        cur, "SELECT e.ligne, e.compte_code, c.libelle AS compte, e.debit, e.credit, e.libelle "
             "FROM ecriture e JOIN compte_comptable c ON c.code = e.compte_code WHERE e.piece_id = %s ORDER BY e.ligne", (piece_id,))
    return p


@router.get("/pieces/{piece_id}")
def detail_piece(piece_id: int, user: User = Depends(require("compta:read"))):
    with tx() as cur:
        verifier_agence(cur, user, "piece_comptable", piece_id)
        return _piece(cur, piece_id)


class EcritureIn(BaseModel):
    compte_code: str = Field(min_length=2, max_length=7)
    debit: int = Field(default=0, ge=0)
    credit: int = Field(default=0, ge=0)
    libelle: str | None = None

    @model_validator(mode="after")
    def un_seul_sens(self):
        if (self.debit > 0) == (self.credit > 0):
            raise ValueError("Chaque ligne porte un débit OU un crédit (montant > 0)")
        return self


class PieceIn(BaseModel):
    agence_id: int | None = None
    journal: str = "OD"
    date_piece: dt.date
    libelle: str = Field(min_length=1)
    lignes: list[EcritureIn] = Field(min_length=2, max_length=200)


@router.post("/pieces", status_code=201)
def saisir_piece(body: PieceIn, user: User = Depends(require("compta:write"))):
    """Saisie manuelle : la pièce doit être équilibrée, les comptes imputables, l'exercice ouvert."""
    ag = agence_scope(user, body.agence_id)
    with tx(user.login) as cur:
        x = one_row(cur, "SELECT id FROM exercice_comptable WHERE %s BETWEEN date_debut AND date_fin", (body.date_piece,))
        if x is None:
            raise HTTPException(status_code=422, detail=f"Aucun exercice comptable pour la date {body.date_piece}")
        j = one_row(cur, "SELECT id FROM journal WHERE code = %s", (body.journal,))
        if j is None:
            raise HTTPException(status_code=422, detail=f"Journal inconnu : {body.journal}")
        pid = one_row(
            cur,
            "INSERT INTO piece_comptable(agence_id, journal_id, exercice_id, date_piece, numero, libelle, origine, utilisateur_id) "
            "VALUES (%s, %s, %s, %s, prochain_numero('piece', %s::smallint, %s, 'PC'), %s, 'manuelle', %s) RETURNING id",
            (ag, j["id"], x["id"], body.date_piece, ag, body.date_piece, body.libelle, user.id),
        )["id"]
        for i, l in enumerate(body.lignes, start=1):
            cur.execute("INSERT INTO ecriture(piece_id, ligne, compte_code, debit, credit, libelle) VALUES (%s, %s, %s, %s, %s, %s)",
                        (pid, i, l.compte_code, l.debit, l.credit, l.libelle))
        cur.execute("SET CONSTRAINTS ALL IMMEDIATE")      # vérifie l'équilibre avant de répondre
        return _piece(cur, pid)


class ContrepassationIn(BaseModel):
    date: dt.date | None = None
    motif: str | None = None


@router.post("/pieces/{piece_id}/contrepasser", status_code=201)
def contrepasser(piece_id: int, body: ContrepassationIn, user: User = Depends(require("compta:write"))):
    with tx(user.login) as cur:
        verifier_agence(cur, user, "piece_comptable", piece_id)
        nid = one_row(cur, "SELECT contrepasser_piece(%s, COALESCE(%s, current_date), %s) AS id", (piece_id, body.date, body.motif))["id"]
        cur.execute("SET CONSTRAINTS ALL IMMEDIATE")
        return _piece(cur, nid)


# ---------------------------------------------------------------- états
@router.get("/balance")
def balance(du: dt.date, au: dt.date, agence_id: int | None = None, user: User = Depends(require("compta:read"))):
    ag = agence_filter(user, agence_id)
    with tx() as cur:
        lignes = all_rows(cur, "SELECT * FROM balance(%s::smallint, %s, %s)", (ag, du, au))
    return {"lignes": lignes, "total_debit": sum(l["debit"] for l in lignes), "total_credit": sum(l["credit"] for l in lignes)}


@router.get("/grand-livre")
def grand_livre(compte: str, du: dt.date, au: dt.date, agence_id: int | None = None, user: User = Depends(require("compta:read"))):
    ag = agence_filter(user, agence_id)
    with tx() as cur:
        return all_rows(cur, "SELECT * FROM grand_livre(%s, %s::smallint, %s, %s)", (compte, ag, du, au))


@router.get("/bilan")
def bilan(au: dt.date, agence_id: int | None = None, user: User = Depends(require("compta:read"))):
    """Bilan simplifié par compte de niveau 2, issu des écritures jusqu'à la date (document de travail, non réglementaire)."""
    ag = agence_filter(user, agence_id)
    with tx() as cur:
        lignes = all_rows(cur, "SELECT cote, classe, code, libelle, montant FROM bilan_simplifie(%s::smallint, %s)", (ag, au))
    actif = [l for l in lignes if l["cote"] == "actif"]
    passif = [l for l in lignes if l["cote"] == "passif"]
    return {"au": au, "actif": actif, "passif": passif,
            "total_actif": sum(l["montant"] for l in actif), "total_passif": sum(l["montant"] for l in passif)}


@router.get("/resultat")
def resultat(du: dt.date, au: dt.date, agence_id: int | None = None, user: User = Depends(require("compta:read"))):
    ag = agence_filter(user, agence_id)
    with tx() as cur:
        r = one_row(cur, "SELECT resultat(%s::smallint, %s, %s) AS resultat", (ag, du, au))["resultat"]
    return {"du": du, "au": au, "resultat": r}
