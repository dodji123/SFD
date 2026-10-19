"""Crédits : produits, demandes, décision, déblocage, échéances, remboursements en espèces, tâches planifiées."""
import datetime as dt
from typing import Literal

from fastapi import APIRouter, Depends, HTTPException, Query
from pydantic import BaseModel, Field

from ..auth import User, agence_filter, agence_scope, require, verifier_agence
from ..db import all_rows, one_row, tx
from .caisse import verifier_session

router = APIRouter(prefix="/api", tags=["credits"])


# ---------------------------------------------------------------- produits
class ProduitCreditIn(BaseModel):
    code: str = Field(min_length=1, max_length=10)
    libelle: str = Field(min_length=1)
    type: Literal["sur_epargne", "sans_epargne"]
    taux_annuel: float = Field(ge=0, le=1)
    frais_dossier_taux: float = Field(default=0, ge=0, le=1)
    periodicite_jours: int = Field(default=30, gt=0, le=366)
    methode: Literal["capital_constant", "annuite_constante"] = "capital_constant"


@router.get("/produits-credit")
def lister_produits(user: User = Depends(require("credit:read"))):
    with tx() as cur:
        return all_rows(cur, "SELECT * FROM produit_credit_epargne WHERE actif ORDER BY code")


@router.post("/produits-credit", status_code=201)
def creer_produit(body: ProduitCreditIn, user: User = Depends(require("ref:write"))):
    with tx(user.login) as cur:
        return one_row(
            cur,
            "INSERT INTO produit_credit_epargne(code, libelle, type, taux_annuel, frais_dossier_taux, periodicite_jours, methode) "
            "VALUES (%s, %s, %s, %s, %s, %s, %s) RETURNING *",
            (body.code, body.libelle, body.type, body.taux_annuel, body.frais_dossier_taux, body.periodicite_jours, body.methode),
        )


# ---------------------------------------------------------------- demandes
DEMANDE = (
    "SELECT d.*, cl.nom AS client, p.code AS produit, p.type AS type_produit FROM demande_credit d "
    "JOIN client cl ON cl.id = d.client_id JOIN produit_credit_epargne p ON p.id = d.produit_id "
)


class DemandeIn(BaseModel):
    client_id: int
    produit_id: int
    montant: int = Field(gt=0)
    nb_echeances: int = Field(gt=0, le=240)
    taux: float | None = Field(default=None, ge=0, le=1)       # vide : taux du produit
    garantie_montant: int = Field(default=0, ge=0)               # négociée, sans plafond en pourcentage
    mode_remboursement: Literal["tontine", "prelevement_compte", "especes"] = "prelevement_compte"
    compte_id: int | None = None
    cycle_id: int | None = None
    note: str | None = None


@router.post("/demandes-credit", status_code=201)
def nouvelle_demande(body: DemandeIn, user: User = Depends(require("credit:request"))):
    with tx(user.login) as cur:
        verifier_agence(cur, user, "client", body.client_id)
        if body.compte_id is not None:
            verifier_agence(cur, user, "compte_epargne", body.compte_id)
        if body.cycle_id is not None:
            verifier_agence(cur, user, "cycle", body.cycle_id)
        did = one_row(
            cur, "SELECT nouvelle_demande_credit(%s, %s, %s, %s, %s, %s, %s, %s, %s, %s) AS id",
            (body.client_id, body.compte_id, body.produit_id, body.montant, body.nb_echeances, body.taux,
             body.garantie_montant, body.mode_remboursement, body.note, body.cycle_id),
        )["id"]
        return one_row(cur, DEMANDE + "WHERE d.id = %s", (did,))


@router.get("/demandes-credit")
def lister_demandes(statut: Literal["demandee", "approuvee", "refusee", "debloquee"] | None = None, client_id: int | None = None,
                    agence_id: int | None = None, user: User = Depends(require("credit:read"))):
    ag = agence_filter(user, agence_id)
    with tx() as cur:
        return all_rows(
            cur,
            DEMANDE + "WHERE (%s::int IS NULL OR d.agence_id = %s) AND (%s::text IS NULL OR d.statut = %s) "
            "AND (%s::int IS NULL OR d.client_id = %s) ORDER BY d.id DESC LIMIT 200",
            (ag, ag, statut, statut, client_id, client_id),
        )


@router.get("/demandes-credit/{demande_id}")
def detail_demande(demande_id: int, user: User = Depends(require("credit:read"))):
    with tx() as cur:
        verifier_agence(cur, user, "demande_credit", demande_id)
        return one_row(cur, DEMANDE + "WHERE d.id = %s", (demande_id,))


class DecisionIn(BaseModel):
    approuve: bool
    commentaire: str | None = None


@router.post("/demandes-credit/{demande_id}/decision")
def decider(demande_id: int, body: DecisionIn, user: User = Depends(require("credit:approve"))):
    with tx(user.login) as cur:
        verifier_agence(cur, user, "demande_credit", demande_id)
        cur.execute("SELECT approuver_demande(%s, %s, %s, %s)", (demande_id, user.id, body.approuve, body.commentaire))
        return one_row(cur, DEMANDE + "WHERE d.id = %s", (demande_id,))


class DeblocageIn(BaseModel):
    date: dt.date | None = None
    mode: Literal["compte", "especes"] = "compte"
    session_id: int | None = None        # obligatoire en espèces


@router.post("/demandes-credit/{demande_id}/debloquer", status_code=201)
def debloquer(demande_id: int, body: DeblocageIn, user: User = Depends(require("credit:disburse"))):
    with tx(user.login) as cur:
        ag = verifier_agence(cur, user, "demande_credit", demande_id)
        if body.session_id is not None and verifier_session(cur, user, body.session_id) != ag:
            raise HTTPException(status_code=422, detail="La session de caisse appartient à une autre agence")
        cid = one_row(cur, "SELECT debloquer_credit(%s, COALESCE(%s, current_date), %s, %s, %s) AS id",
                      (demande_id, body.date, body.mode, body.session_id, user.id))["id"]
        return _credit(cur, cid)


# ---------------------------------------------------------------- crédits
CREDIT = (
    "SELECT c.*, cl.nom AS client, s.capital_restant, s.nb_echeances_restantes, s.prochaine_echeance, "
    "       COALESCE(g.montant_restant, 0) AS garantie_bloquee "
    "FROM credit c JOIN client cl ON cl.id = c.client_id JOIN v_credit_situation s ON s.credit_id = c.id "
    "LEFT JOIN garantie_compte g ON g.credit_id = c.id "
)


def _credit(cur, credit_id: int) -> dict:
    c = one_row(cur, CREDIT + "WHERE c.id = %s", (credit_id,))
    c["echeances"] = all_rows(
        cur,
        "SELECT e.*, (e.capital + e.interet - e.capital_paye - e.interet_paye) AS reste_hors_penalite, "
        "       du_echeance(e.id, current_date) AS du_aujourdhui FROM echeance e WHERE e.credit_id = %s ORDER BY e.no_echeance",
        (credit_id,))
    c["garantie"] = one_row(cur, "SELECT * FROM garantie_compte WHERE credit_id = %s", (credit_id,))
    c["paiements"] = all_rows(cur, "SELECT * FROM paiement_echeance WHERE credit_id = %s ORDER BY date_operation, id", (credit_id,))
    return c


@router.get("/credits")
def lister_credits(statut: Literal["en_cours", "en_retard", "solde"] | None = None, client_id: int | None = None,
                   agence_id: int | None = None, limit: int = Query(100, ge=1, le=500),
                   user: User = Depends(require("credit:read"))):
    ag = agence_filter(user, agence_id)
    with tx() as cur:
        return all_rows(
            cur,
            CREDIT + "WHERE (%s::int IS NULL OR c.agence_id = %s) AND (%s::text IS NULL OR c.statut = %s) "
            "AND (%s::int IS NULL OR c.client_id = %s) ORDER BY c.id DESC LIMIT %s",
            (ag, ag, statut, statut, client_id, client_id, limit),
        )


@router.get("/credits/{credit_id}")
def detail_credit(credit_id: int, user: User = Depends(require("credit:read"))):
    with tx() as cur:
        verifier_agence(cur, user, "credit", credit_id)
        return _credit(cur, credit_id)


class RemboursementIn(BaseModel):
    montant: int = Field(gt=0)
    session_id: int
    date: dt.date | None = None


@router.post("/echeances/{echeance_id}/rembourser-especes")
def rembourser_especes(echeance_id: int, body: RemboursementIn, user: User = Depends(require("credit:repay"))):
    """Paiement partiel accepté ; les échéances se règlent dans l'ordre ; imputation capital, intérêts, pénalités."""
    with tx(user.login) as cur:
        e = one_row(cur, "SELECT e.credit_id, c.agence_id FROM echeance e JOIN credit c ON c.id = e.credit_id WHERE e.id = %s", (echeance_id,))
        if e is None or (user.agence_id is not None and e["agence_id"] != user.agence_id):
            raise HTTPException(status_code=404, detail="Introuvable")
        if verifier_session(cur, user, body.session_id) != e["agence_id"]:
            raise HTTPException(status_code=422, detail="La session de caisse appartient à une autre agence")
        cur.execute("SELECT rembourser_echeance_especes(%s, %s, %s, COALESCE(%s, current_date))",
                    (echeance_id, body.montant, body.session_id, body.date))
        return _credit(cur, e["credit_id"])


# ---------------------------------------------------------------- tâches planifiées (lancées par un planificateur externe)
class TacheIn(BaseModel):
    agence_id: int | None = None
    date: dt.date | None = None


TACHES = {
    "prelever-echeances": ("prelever_echeances_compte", "prelevements"),
    "maj-statuts-credit": ("maj_statuts_credit", "echeances_mises_a_jour"),
    "saisir-garanties": ("saisir_garantie_echeances", "saisies"),
}


@router.post("/taches/{nom}")
def lancer_tache(nom: str, body: TacheIn, user: User = Depends(require("taches:run"))):
    """À planifier chaque jour par agence : prélèvements automatiques (date du jour : premier jour où le disponible suffit),
    passage des échéances en retard et pénalités, saisie des garanties."""
    if nom not in TACHES:
        raise HTTPException(status_code=404, detail="Tâche inconnue")
    fn, cle = TACHES[nom]
    ag = agence_scope(user, body.agence_id)
    with tx(user.login) as cur:
        n = one_row(cur, f"SELECT {fn}(%s::smallint, COALESCE(%s, current_date)) AS n", (ag, body.date))["n"]
    return {cle: n}
