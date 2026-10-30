"""Import des cycles de la machine depuis un fichier Excel — étape 1 : lecture et contrôle, sans rien écrire.
Réservé au gérant et au contrôleur (permission livret:controler).

Colonnes attendues (en-tête sur la première ligne) : numero, client_numero, produit_code, date_debut, date_fin, mise,
et facultatives : objectif, type_cycle. Le gérant ou le contrôle relit le résultat avant la validation (étape 2)."""
import datetime as dt
import io

from fastapi import APIRouter, Depends, File, HTTPException, UploadFile
import psycopg2
from openpyxl import load_workbook

from ..auth import User, agence_scope, require
from ..db import all_rows, one_row, tx
from ..errors import message_pg

router = APIRouter(prefix="/api/import", tags=["import"])

COLONNES_OBLIGATOIRES = ["numero", "client_numero", "produit_code", "date_debut", "date_fin", "mise"]
MAX_LIGNES = 5000


def _date(v) -> dt.date | None:
    if isinstance(v, dt.datetime):
        return v.date()
    if isinstance(v, dt.date):
        return v
    try:
        return dt.date.fromisoformat(str(v).strip()[:10])
    except ValueError:
        return None


def _lire(contenu: bytes) -> list[dict]:
    try:
        feuille = load_workbook(io.BytesIO(contenu), read_only=True, data_only=True).active
    except Exception:
        raise HTTPException(status_code=422, detail="Fichier illisible : un classeur Excel (.xlsx) est attendu")
    lignes = list(feuille.iter_rows(values_only=True))
    if not lignes:
        raise HTTPException(status_code=422, detail="Le fichier est vide")
    entetes = [str(c).strip().lower() if c is not None else "" for c in lignes[0]]
    manquantes = [c for c in COLONNES_OBLIGATOIRES if c not in entetes]
    if manquantes:
        raise HTTPException(status_code=422, detail=f"Colonnes manquantes : {', '.join(manquantes)}")
    donnees = []
    for n, valeurs in enumerate(lignes[1:], start=2):
        if all(v is None or str(v).strip() == "" for v in valeurs):
            continue
        donnees.append({"ligne": n, **{entetes[i]: valeurs[i] for i in range(min(len(entetes), len(valeurs))) if entetes[i]}})
    if len(donnees) > MAX_LIGNES:
        raise HTTPException(status_code=422, detail=f"Trop de lignes ({len(donnees)}) : {MAX_LIGNES} au maximum par fichier")
    return donnees


def _controler(contenu: bytes, ag: int) -> dict:
    """Contrôle chaque ligne du fichier pour l'agence ag, sans rien écrire."""
    donnees = _lire(contenu)
    with tx() as cur:
        clients = {c["numero"] for c in all_rows(cur, "SELECT numero FROM client WHERE agence_id = %s", (ag,))}
        produits = {p["code"] for p in all_rows(cur, "SELECT code FROM produit_epargne", ())}
        existants = {c["numero"] for c in all_rows(cur, "SELECT numero FROM cycle WHERE agence_id = %s", (ag,))}

    erreurs, valides, vus = [], [], set()
    for d in donnees:
        ligne = d["ligne"]
        avant = len(erreurs)

        def erreur(champ, motif):
            erreurs.append({"ligne": ligne, "champ": champ, "motif": motif})

        numero = str(d.get("numero") or "").strip()
        if not numero:
            erreur("numero", "numéro de cycle obligatoire")
        elif numero in existants:
            erreur("numero", f"le cycle {numero} existe déjà dans l'agence")
        elif numero in vus:
            erreur("numero", f"le cycle {numero} est présent deux fois dans le fichier")
        client = str(d.get("client_numero") or "").strip()
        if client not in clients:
            erreur("client_numero", f"client {client or '(vide)'} inconnu dans l'agence")
        produit = str(d.get("produit_code") or "").strip()
        if produit not in produits:
            erreur("produit_code", f"produit {produit or '(vide)'} inconnu")
        debut, fin = _date(d.get("date_debut")), _date(d.get("date_fin"))
        if debut is None:
            erreur("date_debut", "date de début invalide")
        if fin is None:
            erreur("date_fin", "date de fin invalide")
        if debut and fin and fin < debut:
            erreur("date_fin", "la date de fin précède la date de début")
        try:
            mise = int(float(d.get("mise")))
            if mise <= 0:
                raise ValueError
        except (TypeError, ValueError):
            mise = None
            erreur("mise", "mise invalide (nombre entier positif attendu)")
        if len(erreurs) > avant:
            continue
        vus.add(numero)
        valides.append({"ligne": ligne, "numero": numero, "client_numero": client, "produit_code": produit,
                        "date_debut": debut.isoformat(), "date_fin": fin.isoformat(), "mise": mise})
    return {"lignes_lues": len(donnees), "lignes_valides": len(valides), "erreurs": erreurs, "valides": valides}


@router.post("/cycles/verifier")
def verifier_cycles(fichier: UploadFile = File(...), agence_id: int | None = None, user: User = Depends(require("livret:controler"))):
    """Contrôle le fichier sans l'enregistrer : lignes acceptées, erreurs par ligne, aperçu."""
    ag = agence_scope(user, agence_id)
    r = _controler(fichier.file.read(), ag)
    return {"lignes_lues": r["lignes_lues"], "lignes_valides": r["lignes_valides"], "erreurs": r["erreurs"], "apercu": r["valides"][:50]}


@router.post("/cycles/valider")
def valider_cycles(fichier: UploadFile = File(...), agence_id: int | None = None, user: User = Depends(require("livret:controler"))):
    """Étape 2 : crée les cycles des lignes acceptées. Chaque cycle a sa transaction ; une ligne refusée à la base
    n'empêche pas les autres. Même règles de création que la saisie d'un cycle (mise, objectif, nombre de lignes)."""
    ag = agence_scope(user, agence_id)
    r = _controler(fichier.file.read(), ag)
    with tx() as cur:
        clients = {c["numero"]: c["id"] for c in all_rows(cur, "SELECT id, numero FROM client WHERE agence_id = %s", (ag,))}
        produits = {p["code"]: p for p in all_rows(cur, "SELECT id, code, type_cycle, nb_pages_livret FROM produit_epargne", ())}
    crees, refus = [], list(r["erreurs"])
    for v in r["valides"]:
        p = produits[v["produit_code"]]
        type_cycle = p["type_cycle"] or 1
        nb = 31 * (p["nb_pages_livret"] or 1)
        objectif = v["mise"] * nb if type_cycle in (1, 2) else None
        try:
            with tx(user.login) as cur:
                one_row(cur, "INSERT INTO cycle(agence_id, numero, client_id, produit_id, type_cycle, mise_initiale, mise_courante, objectif, "
                             "nb_lignes_prevues, date_debut, date_fin) VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s) RETURNING id",
                        (ag, v["numero"], clients[v["client_numero"]], p["id"], type_cycle, v["mise"], v["mise"], objectif, nb,
                         v["date_debut"], v["date_fin"]))
            crees.append(v["numero"])
        except psycopg2.Error as e:
            refus.append({"ligne": v["ligne"], "champ": "base", "motif": message_pg(e)})
    return {"crees": len(crees), "refus": refus, "numeros": crees}
