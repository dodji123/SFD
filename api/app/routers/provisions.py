"""Classification des créances et provisionnement (module 21) : consultation, passage des écritures, paramètres.

Les règles (anciennetés, taux, solde restant dû) vivent dans la base ; l'API contrôle les droits, le périmètre
(agence ou réseau entier, siège seulement) et la cohérence des paramètres."""
import datetime as dt

from fastapi import APIRouter, Depends, HTTPException
from pydantic import BaseModel, Field

from ..auth import User, agence_filter, require
from ..db import all_rows, one_row, tx
from .reglementaire import _perimetre

router = APIRouter(prefix="/api/provisions", tags=["provisions"])


@router.get("/classification")
def classification(date: dt.date, agence_id: int | None = None, consolide: bool = False, user: User = Depends(require("provisions:read"))):
    ag = _perimetre(user, agence_id, consolide)
    with tx() as cur:
        return all_rows(cur, "SELECT credit_id, numero, client, capital_restant, garantie_bloquee, jours_retard, classe, declasse, compte_encours, "
                             "solde_restant_du, taux_reglementaire, provision_reglementaire, taux_interne, provision_interne, provision_retenue, "
                             "compte_provision, a_passer_en_perte FROM classification_creances(%s::smallint, %s)", (ag, date))


@router.get("/rapport")
def rapport(date: dt.date, agence_id: int | None = None, consolide: bool = False, user: User = Depends(require("provisions:read"))):
    ag = _perimetre(user, agence_id, consolide)
    with tx() as cur:
        classes = all_rows(cur, "SELECT classe, libelle, nb_credits, encours, solde_restant_du, provision_reglementaire, provision_interne, provision_retenue "
                                "FROM rapport_provisions(%s::smallint, %s)", (ag, date))
        ecarts = all_rows(cur, "SELECT compte, requis, constitue, delta FROM ecarts_provisions(%s::smallint, %s)", (ag, date))
    return {
        "date": date, "agence_id": ag, "classes": classes, "ecarts": ecarts,
        "total_requis": sum(c["provision_retenue"] for c in classes), "total_constitue": sum(e["constitue"] for e in ecarts),
        "a_doter": sum(e["delta"] for e in ecarts if e["delta"] > 0), "a_reprendre": -sum(e["delta"] for e in ecarts if e["delta"] < 0),
        "a_passer_en_perte": sum(c["encours"] for c in classes if c["classe"] == "irrecouvrable"),
    }


@router.post("/generer", status_code=201)
def generer(date: dt.date, agence_id: int | None = None, user: User = Depends(require("provisions:generer"))):
    """Passe la pièce de dotation ou de reprise de l'agence (une par jour) ; sans écart, aucune pièce n'est créée."""
    ag = _perimetre(user, agence_id, False)
    with tx(user.login) as cur:
        pid = one_row(cur, "SELECT generer_provisions(%s::smallint, %s, %s) AS id", (ag, date, user.id))["id"]
        if pid is None:
            return {"piece": None, "message": "Les provisions constituées correspondent déjà aux provisions requises : rien à passer."}
        piece = one_row(cur, "SELECT p.id, p.numero, p.date_piece, (SELECT sum(debit) FROM ecriture WHERE piece_id = p.id) AS montant FROM piece_comptable p WHERE p.id = %s", (pid,))
    return {"piece": piece, "message": "Pièce de provisions passée."}


# ---------------------------------------------------------------- paramètres
SEUILS_JOURS = ["prov_jours_3m", "prov_jours_6m", "prov_jours_12m", "prov_jours_24m"]
TAUX = {"prov_taux_6m", "prov_taux_12m", "prov_taux_24m", "prov_taux_0_3m", "prov_interne_0_3m", "prov_interne_3_6m", "prov_interne_6_12m", "prov_interne_12_24m"}
INTERNES = {"prov_interne_0_3m", "prov_interne_3_6m", "prov_interne_6_12m", "prov_interne_12_24m"}
OUI_NON = {"prov_declasser_0_3m", "prov_provisionner_0_3m"}
AUTORISES = set(SEUILS_JOURS) | TAUX | OUI_NON


@router.get("/parametres")
def parametres(user: User = Depends(require("provisions:read"))):
    with tx() as cur:
        return all_rows(cur, "SELECT cle, valeur, description FROM parametre WHERE agence_id IS NULL AND cle LIKE 'prov\\_%%' AND cle <> 'prov_mode' ORDER BY cle")


class ValeurIn(BaseModel):
    valeur: str = Field(min_length=1, max_length=20)


@router.put("/parametres/{cle}")
def modifier_parametre(cle: str, body: ValeurIn, user: User = Depends(require("provisions:parametrer"))):
    if cle not in AUTORISES:
        raise HTTPException(status_code=422, detail="Paramètre de provisionnement inconnu")
    v = body.valeur.strip().replace(",", ".")
    if cle in OUI_NON:
        if v not in ("oui", "non"):
            raise HTTPException(status_code=422, detail="Valeur possible : oui ou non")
    else:
        try:
            nombre = float(v)
        except ValueError:
            raise HTTPException(status_code=422, detail="La valeur doit être un nombre")
        if cle in TAUX and not 0 <= nombre <= 100:
            raise HTTPException(status_code=422, detail="Un taux est compris entre 0 et 100 %")
        if cle in SEUILS_JOURS and (nombre < 1 or nombre != int(nombre)):
            raise HTTPException(status_code=422, detail="Un seuil d'ancienneté est un nombre entier de jours")
    with tx(user.login) as cur:
        cur.execute("INSERT INTO parametre(agence_id, cle, valeur, description) VALUES (NULL, %s, %s, 'règle interne de provisionnement (taux en %%)') "
                    "ON CONFLICT (cle, COALESCE(agence_id, 0)) DO UPDATE SET valeur = EXCLUDED.valeur", (cle, v))
        jours = [float(one_row(cur, "SELECT valeur FROM parametre WHERE cle = %s AND agence_id IS NULL", (c,))["valeur"]) for c in SEUILS_JOURS]
        if jours != sorted(set(jours)):
            raise HTTPException(status_code=422, detail="Les seuils d'ancienneté doivent être strictement croissants (3 mois < 6 mois < 12 mois < 24 mois)")
    return parametres(user)


@router.delete("/parametres/{cle}")
def retirer_regle_interne(cle: str, user: User = Depends(require("provisions:parametrer"))):
    """Retire une règle interne plus stricte (les seuils et taux réglementaires ne se suppriment pas)."""
    if cle not in INTERNES:
        raise HTTPException(status_code=422, detail="Seules les règles internes se retirent")
    with tx(user.login) as cur:
        cur.execute("DELETE FROM parametre WHERE cle = %s AND agence_id IS NULL", (cle,))
    return parametres(user)


# ---------------------------------------------------------------- mode de passage des écritures : manuel (clic) ou automatique
class ModeIn(BaseModel):
    mode: str


@router.get("/mode")
def mode(agence_id: int | None = None, user: User = Depends(require("provisions:read"))):
    """Mode retenu et dernières exécutions de la tâche automatique de l'agence."""
    ag = agence_filter(user, agence_id)
    with tx() as cur:
        m = one_row(cur, "SELECT COALESCE(valeur, 'manuel') AS valeur FROM parametre WHERE cle = 'prov_mode' AND agence_id IS NULL")
        executions = all_rows(cur, "SELECT t.date_tache, t.statut, t.nb_traites, t.message, t.fin, a.code AS agence FROM execution_tache t JOIN agence a ON a.id = t.agence_id "
                                   "WHERE t.tache = 'generer_provisions_auto' AND t.statut IN ('ok','echec') AND (%s::int IS NULL OR t.agence_id = %s) "
                                   "ORDER BY t.id DESC LIMIT 10", (ag, ag))
    return {"mode": m["valeur"] if m else "manuel", "dernieres_executions": executions}


@router.put("/mode")
def changer_mode(body: ModeIn, user: User = Depends(require("provisions:parametrer"))):
    if body.mode not in ("manuel", "automatique"):
        raise HTTPException(status_code=422, detail="Mode possible : manuel ou automatique")
    with tx(user.login) as cur:
        cur.execute("UPDATE parametre SET valeur = %s WHERE cle = 'prov_mode' AND agence_id IS NULL", (body.mode,))
    return mode(None, user)
