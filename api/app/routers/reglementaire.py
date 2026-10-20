"""États financiers réglementaires (postes du référentiel comptable des SFD) et ratios prudentiels du guide d'audit.

Les calculs vivent dans la base (modules 19 et 20) ; l'API contrôle les droits et le cloisonnement par agence.
Les états du réseau entier (consolidé) sont réservés au siège (permission etats:consolide)."""
import datetime as dt
from typing import Literal

from fastapi import APIRouter, Depends, HTTPException, Query
from pydantic import BaseModel, Field

from ..auth import User, agence_scope, require
from ..db import all_rows, one_row, tx

router = APIRouter(prefix="/api/reglementaire", tags=["reglementaire"])


def _perimetre(user: User, agence_id: int | None, consolide: bool) -> int | None:
    """Agence demandée, ou None pour le réseau entier (siège habilité seulement)."""
    if consolide:
        if not user.siege or user.role not in ("admin", "directeur", "comptable", "auditeur"):
            raise HTTPException(status_code=403, detail="Les états consolidés sont réservés au siège")
        return None
    return agence_scope(user, agence_id)


def _lignes_bilan(cur, ag: int | None, au: dt.date) -> dict:
    lignes = all_rows(cur, "SELECT cote, code, libelle, montant FROM etat_bilan_reglementaire(%s::smallint, %s)", (ag, au))
    actif = [l for l in lignes if l["cote"] == "actif"]
    passif = [l for l in lignes if l["cote"] == "passif"]

    def total(rows, code):
        return next((l["montant"] for l in rows if l["code"] == code), 0)

    return {"actif": actif, "passif": passif, "total_actif": total(actif, "E90"), "total_passif": total(passif, "L90")}


@router.get("/bilan")
def bilan(au: dt.date, agence_id: int | None = None, consolide: bool = False, user: User = Depends(require("compta:read"))):
    ag = _perimetre(user, agence_id, consolide)
    with tx() as cur:
        return {"au": au, "agence_id": ag, "consolide": ag is None, **_lignes_bilan(cur, ag, au)}


@router.get("/resultat")
def resultat(du: dt.date, au: dt.date, agence_id: int | None = None, consolide: bool = False, user: User = Depends(require("compta:read"))):
    if du > au:
        raise HTTPException(status_code=422, detail="La date de début doit précéder la date de fin")
    ag = _perimetre(user, agence_id, consolide)
    with tx() as cur:
        lignes = all_rows(cur, "SELECT cote, code, libelle, montant FROM etat_resultat_reglementaire(%s::smallint, %s, %s)", (ag, du, au))
    return {"du": du, "au": au, "agence_id": ag, "consolide": ag is None,
            "produits": [l for l in lignes if l["cote"] == "produit"], "charges": [l for l in lignes if l["cote"] == "charge"]}


@router.get("/hors-bilan")
def hors_bilan(au: dt.date, agence_id: int | None = None, consolide: bool = False, user: User = Depends(require("compta:read"))):
    ag = _perimetre(user, agence_id, consolide)
    with tx() as cur:
        return {"au": au, "agence_id": ag, "lignes": all_rows(cur, "SELECT code, libelle, montant FROM etat_hors_bilan(%s::smallint, %s)", (ag, au))}


# ---------------------------------------------------------------- ratios prudentiels
@router.get("/ratios")
def ratios(date: dt.date, agence_id: int | None = None, consolide: bool = False, user: User = Depends(require("compta:read"))):
    ag = _perimetre(user, agence_id, consolide)
    with tx() as cur:
        lignes = all_rows(cur, "SELECT ratio, libelle, numerateur, denominateur, valeur, norme_type, norme, conforme, saisies_manquantes, note "
                               "FROM ratios_prudentiels(%s::smallint, %s)", (ag, date))
        fp = one_row(cur, "SELECT fonds_propres_retraites(%s::smallint, %s) AS fp", (ag, date))["fp"]
    return {"date": date, "agence_id": ag, "consolide": ag is None, "fonds_propres": fp, "ratios": lignes,
            "non_conformes": [l["ratio"] for l in lignes if l["conforme"] is False]}


@router.post("/ratios/enregistrer", status_code=201)
def enregistrer(date: dt.date, agence_id: int | None = None, consolide: bool = False, user: User = Depends(require("ratios:enregistrer"))):
    """Fige les ratios du jour dans l'historique (preuve de ce qui a été calculé)."""
    ag = _perimetre(user, agence_id, consolide)
    with tx(user.login) as cur:
        n = one_row(cur, "SELECT enregistrer_ratios(%s::smallint, %s, %s) AS n", (ag, date, user.id))["n"]
    return {"enregistres": n}


@router.get("/ratios/historique")
def historique(ratio: str = Query(pattern=r"^(I|II|III|IV|V|VI|VII|VIII|IX)$"), agence_id: int | None = None, consolide: bool = False,
               limit: int = Query(24, ge=1, le=200), user: User = Depends(require("compta:read"))):
    ag = _perimetre(user, agence_id, consolide)
    with tx() as cur:
        return all_rows(cur, "SELECT date_calcul, valeur, norme_type, norme, conforme, cree_le FROM ratio_historique "
                             "WHERE agence_id IS NOT DISTINCT FROM %s AND ratio = %s ORDER BY date_calcul DESC, id DESC LIMIT %s", (ag, ratio, limit))


# ---------------------------------------------------------------- saisies complémentaires
CODES = Literal["depots_mlt", "engagements_ct_donnes", "engagements_ct_recus", "ops_autres_activites",
                "complement_provisions_autorites", "participations_autres_sfd"]


class DonneeIn(BaseModel):
    code: CODES
    date_effet: dt.date
    valeur: int = Field(ge=0)
    commentaire: str | None = Field(default=None, max_length=300)
    agence_id: int | None = None


@router.post("/donnees", status_code=201)
def saisir(body: DonneeIn, user: User = Depends(require("ratios:saisir"))):
    ag = agence_scope(user, body.agence_id)
    with tx(user.login) as cur:
        return one_row(cur, "INSERT INTO donnee_reglementaire(agence_id, code, date_effet, valeur, commentaire, saisi_par) VALUES (%s,%s,%s,%s,%s,%s) "
                            "RETURNING id, agence_id, code, date_effet, valeur, commentaire", (ag, body.code, body.date_effet, body.valeur, body.commentaire, user.id))


@router.get("/donnees")
def lister_donnees(agence_id: int | None = None, user: User = Depends(require("compta:read"))):
    """Historique des saisies complémentaires de l'agence (la plus récente avant la date de calcul fait foi)."""
    ag = agence_scope(user, agence_id)
    with tx() as cur:
        return all_rows(cur, "SELECT d.id, d.code, d.date_effet, d.valeur, d.commentaire, u.login AS saisi_par, d.cree_le FROM donnee_reglementaire d "
                             "LEFT JOIN utilisateur u ON u.id = d.saisi_par WHERE d.agence_id = %s ORDER BY d.code, d.date_effet DESC, d.id DESC LIMIT 200", (ag,))


# ---------------------------------------------------------------- hypothèses de calcul et seuils (paramétrables)
@router.get("/hypotheses")
def hypotheses(user: User = Depends(require("compta:read"))):
    """Points d'interprétation du guide : valeur retenue, valeurs possibles, validation par le comptable."""
    with tx() as cur:
        return {
            "hypotheses": all_rows(cur, "SELECT code, libelle, explication, valeurs, valeur, validee, validee_par_login, validee_le, commentaire FROM v_hypotheses ORDER BY code"),
            "seuils": all_rows(cur, "SELECT cle, valeur, description FROM parametre WHERE agence_id IS NULL AND (cle LIKE 'ratio_norme_%%' OR cle = 'type_institution_liquidite') ORDER BY cle"),
        }


class ValeurIn(BaseModel):
    valeur: str = Field(min_length=1, max_length=40)


class ValidationIn(BaseModel):
    commentaire: str | None = Field(default=None, max_length=300)


@router.put("/hypotheses/{code}")
def modifier_hypothese(code: str, body: ValeurIn, user: User = Depends(require("ratios:parametrer"))):
    with tx(user.login) as cur:
        cur.execute("SELECT modifier_hypothese(%s, %s)", (code, body.valeur))
    return hypotheses(user)


@router.post("/hypotheses/{code}/valider", status_code=201)
def valider_hypothese(code: str, body: ValidationIn, user: User = Depends(require("ratios:valider"))):
    """Le comptable valide la valeur actuellement retenue ; la validation tombe si la valeur change."""
    with tx(user.login) as cur:
        cur.execute("SELECT valider_hypothese(%s, %s, %s)", (code, user.id, body.commentaire))
    return hypotheses(user)


TYPES_INSTITUTION = ("non_affilie", "affilie", "sans_depots")


@router.put("/seuils/{cle}")
def modifier_seuil(cle: str, body: ValeurIn, user: User = Depends(require("ratios:parametrer"))):
    """Modifie un seuil de ratio (ratio_norme_*) ou le type d'institution du ratio de liquidité."""
    with tx(user.login) as cur:
        if cle == "type_institution_liquidite":
            if body.valeur not in TYPES_INSTITUTION:
                raise HTTPException(status_code=422, detail=f"Valeur possible : {', '.join(TYPES_INSTITUTION)}")
            cur.execute("UPDATE parametre SET valeur = %s WHERE cle = %s AND agence_id IS NULL", (body.valeur, cle))
        else:
            try:
                nombre = float(body.valeur.replace(",", "."))
            except ValueError:
                raise HTTPException(status_code=422, detail="Le seuil doit être un nombre")
            cur.execute("SELECT modifier_norme_ratio(%s, %s)", (cle, nombre))
    return hypotheses(user)
