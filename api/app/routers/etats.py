"""États financiers : par agence (compte de résultat + bilan) et consolidés pour l'ensemble du réseau.

Documents de travail issus des écritures comptables, pas des états réglementaires. La consolidation est une
agrégation des agences : il n'existe aucune écriture inter-agences à éliminer."""
import datetime as dt

from fastapi import APIRouter, Depends, HTTPException

from ..auth import User, agence_scope, require
from ..db import all_rows, one_row, tx

router = APIRouter(prefix="/api/etats", tags=["etats-financiers"])


def _verifier_periode(du: dt.date, au: dt.date) -> None:
    if du > au:
        raise HTTPException(status_code=422, detail="La date de début doit précéder la date de fin")


def _resultat(lignes: list[dict], agences: list[dict]) -> dict:
    """Compte de résultat en colonnes : une ligne par compte, un montant par agence, un total."""
    ids = [a["id"] for a in agences]
    out: dict[str, list[dict]] = {"produit": [], "charge": []}
    index: dict[tuple, dict] = {}
    for l in lignes:
        cle = (l["cote"], l["code"])
        if cle not in index:
            index[cle] = {"code": l["code"], "libelle": l["libelle"], "par_agence": {str(i): 0 for i in ids}, "total": 0}
            out[l["cote"]].append(index[cle])
        index[cle]["par_agence"][str(l["agence_id"])] = l["montant"]
        index[cle]["total"] += l["montant"]
    tp = {str(i): sum(x["par_agence"][str(i)] for x in out["produit"]) for i in ids}
    tc = {str(i): sum(x["par_agence"][str(i)] for x in out["charge"]) for i in ids}
    return {
        "produits": out["produit"], "charges": out["charge"],
        "total_produits": {**tp, "total": sum(tp.values())},
        "total_charges": {**tc, "total": sum(tc.values())},
        "resultat": {**{k: tp[k] - tc[k] for k in tp}, "total": sum(tp.values()) - sum(tc.values())},
    }


def _bilan(lignes: list[dict], agences: list[dict]) -> dict:
    """Bilan en colonnes : le côté (actif / passif) d'une ligne se décide sur le solde total de tout le périmètre."""
    ids = [a["id"] for a in agences]
    index: dict[str, dict] = {}
    for l in lignes:
        r = index.setdefault(l["code"], {"code": l["code"], "libelle": l["libelle"], "par_agence": {str(i): 0 for i in ids}, "solde": 0})
        r["par_agence"][str(l["agence_id"])] = l["solde"]
        r["solde"] += l["solde"]
    rows = [r for r in sorted(index.values(), key=lambda r: (r["code"] == "RES", r["code"])) if r["solde"] != 0]
    actif = [{**r, "montant": r["solde"]} for r in rows if r["solde"] > 0]
    passif = [{**r, "montant": -r["solde"]} for r in rows if r["solde"] < 0]
    return {"actif": actif, "passif": passif,
            "total_actif": sum(r["montant"] for r in actif), "total_passif": sum(r["montant"] for r in passif)}


def _etats(cur, agence_id: int | None, agences: list[dict], du: dt.date, au: dt.date) -> dict:
    res = all_rows(cur, "SELECT agence_id, cote, code, libelle, montant FROM etat_resultat_par_agence(%s::smallint, %s, %s)", (agence_id, du, au))
    bil = all_rows(cur, "SELECT agence_id, code, libelle, solde FROM bilan_par_agence(%s::smallint, %s)", (agence_id, au))
    return {"compte_resultat": _resultat(res, agences), "bilan": _bilan(bil, agences)}


@router.get("/agence")
def etats_agence(du: dt.date, au: dt.date, agence_id: int | None = None, user: User = Depends(require("compta:read"))):
    """Compte de résultat de la période [du, au] et bilan au jour `au` d'une agence."""
    _verifier_periode(du, au)
    ag = agence_scope(user, agence_id)
    with tx() as cur:
        agence = one_row(cur, "SELECT id, code, libelle FROM agence WHERE id = %s", (ag,))
        if agence is None:
            raise HTTPException(status_code=404, detail="Agence inconnue")
        return {"du": du, "au": au, "agence": agence, **_etats(cur, ag, [agence], du, au)}


@router.get("/consolide")
def etats_consolides(du: dt.date, au: dt.date, user: User = Depends(require("etats:consolide"))):
    """Réseau entier : une colonne par agence et une colonne « total » (compte de résultat, bilan, synthèse)."""
    _verifier_periode(du, au)
    if not user.siege:
        raise HTTPException(status_code=403, detail="Les états consolidés sont réservés au siège")
    with tx() as cur:
        agences = all_rows(cur, "SELECT id, code, libelle FROM agence ORDER BY code")
        synthese = all_rows(cur, "SELECT agence_id, agence, produits, charges, resultat, total_actif, total_passif, ecart FROM synthese_agences(%s, %s)", (du, au))
        etats = _etats(cur, None, agences, du, au)
        rapprochement = all_rows(cur, "SELECT agence, validee, statut, ecart_total FROM etat_rapprochement_agences(%s)", (au,))
    cons = {
        "produits": sum(s["produits"] for s in synthese), "charges": sum(s["charges"] for s in synthese),
        "resultat": sum(s["resultat"] for s in synthese),
        "total_actif": etats["bilan"]["total_actif"], "total_passif": etats["bilan"]["total_passif"],
    }
    controles = {
        "bilan_equilibre": etats["bilan"]["total_actif"] == etats["bilan"]["total_passif"],
        "agences_equilibrees": all(s["ecart"] == 0 for s in synthese),
        "resultat_coherent": etats["compte_resultat"]["resultat"]["total"] == cons["resultat"],
    }
    # le rapprochement fiches / comptabilité de chaque agence doit être validé avant de s'appuyer sur le consolidé (signalement, non bloquant)
    rapp = {"toutes_validees": all(r["validee"] for r in rapprochement), "agences_non_validees": [r["agence"] for r in rapprochement if not r["validee"]],
            "agences_avec_ecart": [r["agence"] for r in rapprochement if r["statut"] == "ecart_justifie"]}
    return {"du": du, "au": au, "agences": agences, "synthese": synthese, "consolide": cons, "controles": controles, "rapprochement": rapp, **etats}
