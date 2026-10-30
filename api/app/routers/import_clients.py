"""Import des clients depuis un fichier Excel, par produit et par zone. Permission ref:write (gérant, chef d'agence).
Les numéros du fichier sont conservés tels quels (numérotation du terrain). Étape 1 : contrôle sans écriture ;
étape 2 : création des clients acceptés, une transaction par client.

Colonnes : numero, nom, zone_code, produit_code (obligatoires) ; telephone (facultative)."""
import io

from fastapi import APIRouter, Depends, File, Response, UploadFile
import psycopg2
from openpyxl import Workbook

from ..auth import User, agence_scope, require
from ..db import all_rows, one_row, tx
from ..errors import message_pg
from .import_cycles import _lire

router = APIRouter(prefix="/api/import", tags=["import"])

COLONNES_CLIENTS = ["numero", "nom", "zone_code", "produit_code"]
NOTICE_CLIENTS = [
    "Import des clients : mode d'emploi",
    "",
    "1. Un fichier par produit et par zone : chaque ligne est un client de ce produit, dans cette zone.",
    "2. numero : le numéro client du terrain, conservé tel quel. Il ne doit pas exister déjà dans l'agence.",
    "3. nom : nom du client, saisi comme il doit apparaître dans l'application.",
    "4. zone_code : un code de l'onglet Zones (zone de l'agence). produit_code : un code de l'onglet Produits.",
    "5. telephone : facultatif.",
    "6. Le produit n'est pas enregistré sur la fiche client : il contrôle le fichier et sert à le découper par produit.",
    "7. Vérifiez le fichier avec « Contrôler le fichier » avant de créer les clients : aucune écriture à cette étape.",
    "8. Importez les clients avant les cycles : un cycle se rattache à un client existant.",
]


def _texte(v) -> str:
    if v is None:
        return ""
    if isinstance(v, float) and v.is_integer():
        return str(int(v))
    return str(v).strip()


def _controler(contenu: bytes, ag: int) -> dict:
    donnees = _lire(contenu, COLONNES_CLIENTS)
    with tx() as cur:
        existants = {c["numero"] for c in all_rows(cur, "SELECT numero FROM client WHERE agence_id = %s", (ag,))}
        zones = {z["code"] for z in all_rows(cur, "SELECT code FROM zone WHERE agence_id = %s", (ag,))}
        produits = {p["code"] for p in all_rows(cur, "SELECT code FROM produit_epargne", ())}

    erreurs, valides, vus = [], [], set()
    for d in donnees:
        ligne = d["ligne"]
        avant = len(erreurs)

        def erreur(champ, motif):
            erreurs.append({"ligne": ligne, "champ": champ, "motif": motif})

        numero = _texte(d.get("numero"))
        if not numero:
            erreur("numero", "numéro client obligatoire")
        elif numero in existants:
            erreur("numero", f"le client {numero} existe déjà dans l'agence")
        elif numero in vus:
            erreur("numero", f"le client {numero} est présent deux fois dans le fichier")
        nom = _texte(d.get("nom"))
        if not nom:
            erreur("nom", "nom obligatoire")
        zone = _texte(d.get("zone_code"))
        if zone not in zones:
            erreur("zone_code", f"zone {zone or '(vide)'} inconnue dans l'agence")
        produit = _texte(d.get("produit_code"))
        if produit not in produits:
            erreur("produit_code", f"produit {produit or '(vide)'} inconnu")
        if len(erreurs) > avant:
            continue
        vus.add(numero)
        valides.append({"ligne": ligne, "numero": numero, "nom": nom, "zone_code": zone, "produit_code": produit,
                        "telephone": _texte(d.get("telephone")) or None})
    return {"lignes_lues": len(donnees), "lignes_valides": len(valides), "erreurs": erreurs, "valides": valides}


@router.get("/clients/modele")
def modele_clients(agence_id: int | None = None, user: User = Depends(require("ref:write"))):
    """Fichier type : en-têtes, zones de l'agence, codes produits, notice."""
    ag = agence_scope(user, agence_id)
    with tx() as cur:
        zones = all_rows(cur, "SELECT code, libelle FROM zone WHERE agence_id = %s ORDER BY code", (ag,))
        produits = all_rows(cur, "SELECT code, libelle FROM produit_epargne ORDER BY code", ())
    classeur = Workbook()
    clients = classeur.active
    clients.title = "Clients"
    clients.append(COLONNES_CLIENTS + ["telephone"])
    notice = classeur.create_sheet("Notice")
    for ligne in NOTICE_CLIENTS:
        notice.append([ligne])
    notice.column_dimensions["A"].width = 110
    liste_zones = classeur.create_sheet("Zones")
    liste_zones.append(["code", "libelle"])
    for z in zones:
        liste_zones.append([z["code"], z["libelle"]])
    liste_produits = classeur.create_sheet("Produits")
    liste_produits.append(["code", "libelle"])
    for p in produits:
        liste_produits.append([p["code"], p["libelle"]])
    tampon = io.BytesIO()
    classeur.save(tampon)
    return Response(
        content=tampon.getvalue(),
        media_type="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
        headers={"Content-Disposition": 'attachment; filename="modele_import_clients.xlsx"'},
    )


@router.post("/clients/verifier")
def verifier_clients(fichier: UploadFile = File(...), agence_id: int | None = None, user: User = Depends(require("ref:write"))):
    """Contrôle le fichier sans l'enregistrer : lignes acceptées, erreurs par ligne, aperçu."""
    ag = agence_scope(user, agence_id)
    r = _controler(fichier.file.read(), ag)
    return {"lignes_lues": r["lignes_lues"], "lignes_valides": r["lignes_valides"], "erreurs": r["erreurs"],
            "apercu": r["valides"][:50]}


@router.post("/clients/valider")
def valider_clients(fichier: UploadFile = File(...), agence_id: int | None = None, user: User = Depends(require("ref:write"))):
    """Crée les clients acceptés, avec leur numéro du fichier. Chaque client a sa transaction ; une ligne refusée
    par la base n'empêche pas les autres."""
    ag = agence_scope(user, agence_id)
    r = _controler(fichier.file.read(), ag)
    with tx() as cur:
        zones = {z["code"]: z["id"] for z in all_rows(cur, "SELECT id, code FROM zone WHERE agence_id = %s", (ag,))}
    crees, refus = [], list(r["erreurs"])
    for v in r["valides"]:
        try:
            with tx(user.login) as cur:
                one_row(cur, "INSERT INTO client(agence_id, zone_id, numero, nom, telephone) VALUES (%s, %s, %s, %s, %s) RETURNING id",
                        (ag, zones[v["zone_code"]], v["numero"], v["nom"], v["telephone"]))
            crees.append(v["numero"])
        except psycopg2.Error as e:
            refus.append({"ligne": v["ligne"], "champ": "base", "motif": message_pg(e)})
    return {"crees": len(crees), "refus": refus, "numeros": crees}
