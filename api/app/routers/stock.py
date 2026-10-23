"""Stock des fournitures (module 57) : articles, lieux (siège, agence, agent), entrées, transferts, demandes de sortie / rebut /
inventaire validées par une autre personne, soldes, valorisation, alertes, immobilisations affectées aux agents.
Les règles (stock jamais négatif, ajout seul, décision par une autre personne, coût moyen) sont dans le schéma ; ce routeur
contrôle les droits et le cloisonnement : un utilisateur d'agence ne voit ni ne touche que les lieux de son agence, le siège
(lieu « siège ») est réservé aux utilisateurs du siège."""
import datetime as dt
from typing import Literal

from fastapi import APIRouter, Depends, HTTPException
from pydantic import BaseModel, Field

from ..auth import User, agence_scope, require
from ..db import all_rows, one_row, tx

router = APIRouter(prefix="/api/stock", tags=["stock"])


# ------------------------------------------------------------------ périmètre
def _tous(user: User) -> bool:
    return user.agences is None


def _scope(user: User) -> tuple[bool, list[int]]:
    """(voit tout, agences visibles) pour les filtres SQL : agence_id NULL (siège) n'est visible que si tout l'est."""
    return _tous(user), list(user.agences or [])


def _peut_lieu(user: User, lieu_agence_id: int | None) -> bool:
    return _tous(user) if lieu_agence_id is None else user.peut_agence(lieu_agence_id)


class LieuRef(BaseModel):
    type: Literal["siege", "agence", "agent"]
    agence_id: int | None = None
    utilisateur_id: int | None = None


def _lieu(cur, user: User, ref: LieuRef) -> int:
    """Retrouve ou crée le lieu désigné, après contrôle du périmètre."""
    if ref.type == "siege":
        if not _tous(user):
            raise HTTPException(status_code=403, detail="Le stock du siège est réservé au siège")
        return one_row(cur, "SELECT mf.lieu_stock_pour('siege', NULL) AS id")["id"]
    if ref.type == "agence":
        ag = agence_scope(user, ref.agence_id)
        return one_row(cur, "SELECT mf.lieu_stock_pour('agence', %s::smallint) AS id", (ag,))["id"]
    if ref.utilisateur_id is None:
        raise HTTPException(status_code=422, detail="Agent obligatoire")
    u = one_row(cur, "SELECT agence_id FROM mf.utilisateur WHERE id = %s AND actif", (ref.utilisateur_id,))
    if u is None or not user.peut_agence(u["agence_id"]):
        raise HTTPException(status_code=404, detail="Agent introuvable")
    return one_row(cur, "SELECT mf.lieu_stock_pour('agent', %s::smallint, %s) AS id", (u["agence_id"], ref.utilisateur_id))["id"]


def _article(cur, article_id: int) -> dict:
    a = one_row(cur, "SELECT * FROM mf.article WHERE id = %s", (article_id,))
    if a is None:
        raise HTTPException(status_code=404, detail="Article introuvable")
    return a


# ------------------------------------------------------------------ articles
class ArticleIn(BaseModel):
    code: str = Field(min_length=2, max_length=30, pattern=r"^[A-Z0-9_-]+$")
    designation: str = Field(min_length=3, max_length=200)
    type: Literal["consommable", "immobilisable"]
    unite: str = Field(default="unité", min_length=1, max_length=20)
    seuil_alerte: float = Field(default=0, ge=0, le=1_000_000)
    categorie_immobilisation: str | None = None


class ArticlePatch(BaseModel):
    designation: str | None = Field(default=None, min_length=3, max_length=200)
    unite: str | None = Field(default=None, min_length=1, max_length=20)
    seuil_alerte: float | None = Field(default=None, ge=0, le=1_000_000)
    actif: bool | None = None


@router.get("/articles")
def lister_articles(type: Literal["consommable", "immobilisable"] | None = None, q: str | None = None, actifs: bool = True,
                    user: User = Depends(require("stock:read"))):
    tous, ags = _scope(user)
    with tx() as cur:
        return all_rows(
            cur,
            "SELECT a.*, COALESCE(s.quantite, 0) AS quantite, COALESCE(s.valeur, 0) AS valeur, "
            "       (a.type = 'consommable' AND a.seuil_alerte > 0 AND COALESCE(s.quantite, 0) <= a.seuil_alerte) AS en_alerte, "
            "       (SELECT count(*) FROM mf.immobilisation i WHERE i.article_id = a.id AND i.statut <> 'sortie' AND (%s OR i.agence_id = ANY(%s))) AS nb_unites "
            "FROM mf.article a LEFT JOIN LATERAL ("
            "  SELECT sum(quantite) AS quantite, sum(valeur) AS valeur FROM mf.v_solde_stock v WHERE v.article_id = a.id AND (%s OR v.agence_id = ANY(%s))) s ON true "
            "WHERE (%s::text IS NULL OR a.type = %s) AND (NOT %s OR a.actif) "
            "AND (%s::text IS NULL OR a.code ILIKE '%%' || %s || '%%' OR a.designation ILIKE '%%' || %s || '%%') ORDER BY a.designation",
            (tous, ags, tous, ags, type, type, actifs, q, q, q),
        )


@router.post("/articles", status_code=201)
def creer_article(body: ArticleIn, user: User = Depends(require("stock:gerer"))):
    with tx(user.login) as cur:
        r = one_row(cur, "INSERT INTO mf.article(code, designation, type, unite, seuil_alerte, categorie_immobilisation) VALUES (%s, %s, %s, %s, %s, %s) RETURNING id",
                    (body.code, body.designation, body.type, body.unite, body.seuil_alerte, body.categorie_immobilisation))
        return _article(cur, r["id"])


@router.patch("/articles/{article_id}")
def modifier_article(article_id: int, body: ArticlePatch, user: User = Depends(require("stock:gerer"))):
    with tx(user.login) as cur:
        a = _article(cur, article_id)
        cur.execute("UPDATE mf.article SET designation = %s, unite = %s, seuil_alerte = %s, actif = %s WHERE id = %s",
                    (body.designation or a["designation"], body.unite or a["unite"],
                     a["seuil_alerte"] if body.seuil_alerte is None else body.seuil_alerte, a["actif"] if body.actif is None else body.actif, article_id))
        return _article(cur, article_id)


# ------------------------------------------------------------------ lieux
@router.get("/destinations")
def destinations(user: User = Depends(require("stock:read"))):
    """Lieux utilisables dans le périmètre de l'utilisateur : siège, agences, agents (le lieu est créé au premier mouvement)."""
    tous, ags = _scope(user)
    with tx() as cur:
        out: list[dict] = []
        if tous:
            out.append({"type": "siege", "agence_id": None, "utilisateur_id": None, "libelle": "Siège"})
        out += [{"type": "agence", "agence_id": r["id"], "utilisateur_id": None, "libelle": "Agence " + r["libelle"]}
                for r in all_rows(cur, "SELECT id, libelle FROM mf.agence WHERE (%s OR id = ANY(%s)) ORDER BY libelle", (tous, ags))]
        out += [{"type": "agent", "agence_id": r["agence_id"], "utilisateur_id": r["id"], "libelle": f"Agent {r['nom']} ({r['agence']})"}
                for r in all_rows(cur, "SELECT u.id, u.nom, u.agence_id, a.libelle AS agence FROM mf.utilisateur u JOIN mf.agence a ON a.id = u.agence_id "
                                       "WHERE u.actif AND (%s OR u.agence_id = ANY(%s)) AND u.role IN ('agent','collectrice','caissier') ORDER BY a.libelle, u.nom", (tous, ags))]
        return out


# ------------------------------------------------------------------ soldes, valorisation, alertes, mouvements
@router.get("/soldes")
def soldes(article_id: int | None = None, lieu_type: Literal["siege", "agence", "agent"] | None = None, agence_id: int | None = None,
           tous_les_soldes: bool = False, user: User = Depends(require("stock:read"))):
    tous, ags = _scope(user)
    with tx() as cur:
        return all_rows(
            cur,
            "SELECT * FROM mf.v_solde_stock WHERE (%s OR agence_id = ANY(%s)) AND (%s::int IS NULL OR article_id = %s) "
            "AND (%s::text IS NULL OR lieu_type = %s) AND (%s::int IS NULL OR agence_id = %s) AND (%s OR quantite <> 0) ORDER BY designation, lieu_type, lieu",
            (tous, ags, article_id, article_id, lieu_type, lieu_type, agence_id, agence_id, tous_les_soldes),
        )


@router.get("/valorisation")
def valorisation(user: User = Depends(require("stock:read"))):
    """Valeur du stock au coût moyen pondéré, par lieu d'affectation (siège, agence)."""
    tous, ags = _scope(user)
    with tx() as cur:
        lignes = all_rows(
            cur,
            "SELECT v.agence_id, COALESCE(a.libelle, 'Siège') AS perimetre, count(DISTINCT v.article_id) AS nb_articles, sum(v.valeur) AS valeur "
            "FROM mf.v_solde_stock v LEFT JOIN mf.agence a ON a.id = v.agence_id WHERE (%s OR v.agence_id = ANY(%s)) AND v.quantite <> 0 "
            "GROUP BY v.agence_id, a.libelle ORDER BY perimetre",
            (tous, ags),
        )
        return {"lignes": lignes, "total": sum(int(x["valeur"] or 0) for x in lignes)}


@router.get("/alertes")
def alertes(user: User = Depends(require("stock:read"))):
    tous, ags = _scope(user)
    with tx() as cur:
        return all_rows(
            cur,
            "SELECT al.*, COALESCE(a.libelle, 'Siège') AS perimetre FROM mf.v_alerte_stock al LEFT JOIN mf.agence a ON a.id = al.agence_id "
            "WHERE (%s OR al.agence_id = ANY(%s)) ORDER BY al.rupture DESC, al.designation",
            (tous, ags),
        )


@router.get("/mouvements")
def mouvements(article_id: int | None = None, type: Literal["entree", "sortie", "transfert", "inventaire", "rebut"] | None = None,
               agence_id: int | None = None, limite: int = 200, user: User = Depends(require("stock:read"))):
    tous, ags = _scope(user)
    with tx() as cur:
        return all_rows(
            cur,
            "SELECT * FROM mf.v_mouvement_stock WHERE (%s OR agence_id = ANY(%s)) AND (%s::int IS NULL OR article_id = %s) "
            "AND (%s::text IS NULL OR type = %s) AND (%s::int IS NULL OR agence_id = %s) ORDER BY id DESC LIMIT %s",
            (tous, ags, article_id, article_id, type, type, agence_id, agence_id, max(1, min(limite, 1000))),
        )


# ------------------------------------------------------------------ entrées et transferts
class EntreeIn(BaseModel):
    article_id: int
    lieu: LieuRef
    quantite: float = Field(gt=0, le=10_000_000)
    cout_unitaire: float = Field(gt=0, le=10_000_000_000)
    date_mouvement: dt.date | None = None
    reference_facture: str | None = Field(default=None, max_length=120)
    tiers_id: int | None = None


@router.post("/entrees", status_code=201)
def entrer(body: EntreeIn, user: User = Depends(require("stock:mouvoir"))):
    with tx(user.login) as cur:
        _article(cur, body.article_id)
        lieu = _lieu(cur, user, body.lieu)
        mid = one_row(cur, "SELECT mf.entrer_stock(%s, %s, %s, %s, %s, %s, %s, %s) AS id",
                      (body.article_id, lieu, body.quantite, body.cout_unitaire, body.date_mouvement, body.reference_facture, body.tiers_id, user.id))["id"]
        return one_row(cur, "SELECT * FROM mf.v_mouvement_stock WHERE id = %s", (mid,))


class TransfertIn(BaseModel):
    article_id: int
    source: LieuRef
    destination: LieuRef
    quantite: float = Field(gt=0, le=10_000_000)
    date_mouvement: dt.date | None = None
    motif: str = Field(min_length=5, max_length=300)


@router.post("/transferts", status_code=201)
def transferer(body: TransfertIn, user: User = Depends(require("stock:mouvoir"))):
    """Le transfert est direct (le total ne change pas), mais les deux lieux doivent être dans le périmètre de l'utilisateur :
    seul le siège transfère d'une agence à une autre."""
    with tx(user.login) as cur:
        _article(cur, body.article_id)
        src = _lieu(cur, user, body.source)
        dst = _lieu(cur, user, body.destination)
        g = one_row(cur, "SELECT mf.transferer_stock(%s, %s, %s, %s, %s, %s, %s) AS g",
                    (body.article_id, src, dst, body.quantite, body.date_mouvement, body.motif, user.id))["g"]
        return all_rows(cur, "SELECT * FROM mf.v_mouvement_stock WHERE groupe_id = %s ORDER BY id", (g,))


# ------------------------------------------------------------------ demandes (sortie, rebut, inventaire, rebut d'immobilisation)
class DemandeIn(BaseModel):
    type: Literal["sortie", "rebut", "inventaire", "rebut_immobilisation"]
    article_id: int | None = None
    lieu: LieuRef | None = None
    immobilisation_id: int | None = None
    quantite: float | None = Field(default=None, ge=0, le=10_000_000)
    date_effet: dt.date | None = None
    motif: str = Field(min_length=5, max_length=300)


def _demande(cur, user: User, demande_id: int) -> dict:
    d = one_row(cur, "SELECT * FROM mf.v_demande_stock WHERE id = %s", (demande_id,))
    if d is None or not _peut_lieu(user, d["agence_id"]):
        raise HTTPException(status_code=404, detail="Introuvable")
    return d


@router.post("/demandes", status_code=201)
def demander(body: DemandeIn, user: User = Depends(require("stock:mouvoir"))):
    with tx(user.login) as cur:
        if body.type == "rebut_immobilisation":
            if body.immobilisation_id is None:
                raise HTTPException(status_code=422, detail="Immobilisation obligatoire")
            i = one_row(cur, "SELECT agence_id FROM mf.immobilisation WHERE id = %s", (body.immobilisation_id,))
            if i is None or not user.peut_agence(i["agence_id"]):
                raise HTTPException(status_code=404, detail="Immobilisation introuvable")
            r = one_row(cur, "INSERT INTO mf.demande_stock(type, immobilisation_id, date_effet, motif, demande_par) VALUES ('rebut_immobilisation', %s, COALESCE(%s, current_date), %s, %s) RETURNING id",
                        (body.immobilisation_id, body.date_effet, body.motif, user.id))
        else:
            if body.article_id is None or body.lieu is None or body.quantite is None:
                raise HTTPException(status_code=422, detail="Article, lieu et quantité obligatoires")
            _article(cur, body.article_id)
            lieu = _lieu(cur, user, body.lieu)
            r = one_row(cur, "INSERT INTO mf.demande_stock(type, article_id, lieu_id, quantite, date_effet, motif, demande_par) VALUES (%s, %s, %s, %s, COALESCE(%s, current_date), %s, %s) RETURNING id",
                        (body.type, body.article_id, lieu, body.quantite, body.date_effet, body.motif, user.id))
        return _demande(cur, user, r["id"])


@router.get("/demandes")
def lister_demandes(statut: Literal["en_attente", "validee", "rejetee"] | None = None, user: User = Depends(require("stock:read"))):
    tous, ags = _scope(user)
    with tx() as cur:
        return all_rows(
            cur,
            "SELECT * FROM mf.v_demande_stock WHERE (%s OR agence_id = ANY(%s)) AND (%s::text IS NULL OR statut = %s) ORDER BY (statut = 'en_attente') DESC, id DESC LIMIT 300",
            (tous, ags, statut, statut),
        )


class DecisionIn(BaseModel):
    valider: bool
    motif: str | None = Field(default=None, max_length=300)


@router.post("/demandes/{demande_id}/decider")
def decider(demande_id: int, body: DecisionIn, user: User = Depends(require("stock:valider"))):
    with tx(user.login) as cur:
        d = _demande(cur, user, demande_id)
        if d["demande_par"] == user.id:
            raise HTTPException(status_code=403, detail="La décision doit venir d'une autre personne que le demandeur")
        one_row(cur, "SELECT mf.decider_demande_stock(%s, %s, %s, %s) AS r", (demande_id, body.valider, user.id, body.motif))
        return _demande(cur, user, demande_id)


# ------------------------------------------------------------------ immobilisations liées aux articles, affectation aux agents
def _immo(cur, user: User, immo_id: int) -> dict:
    i = one_row(cur, "SELECT * FROM mf.v_immobilisation_stock WHERE id = %s", (immo_id,))
    if i is None or not user.peut_agence(i["agence_id"]):
        raise HTTPException(status_code=404, detail="Introuvable")
    return i


@router.get("/immobilisations")
def lister_immobilisations(article_id: int | None = None, affecte_a: int | None = None, statut: str | None = None,
                           user: User = Depends(require("stock:read"))):
    tous, ags = _scope(user)
    with tx() as cur:
        return all_rows(
            cur,
            "SELECT * FROM mf.v_immobilisation_stock WHERE article_id IS NOT NULL AND (%s OR agence_id = ANY(%s)) AND (%s::int IS NULL OR article_id = %s) "
            "AND (%s::int IS NULL OR affecte_a_id = %s) AND (%s::text IS NULL OR statut = %s) ORDER BY agence_id, ordre DESC LIMIT 500",
            (tous, ags, article_id, article_id, affecte_a, affecte_a, statut, statut),
        )


class UniteIn(BaseModel):
    article_id: int
    designation: str = Field(min_length=3, max_length=200)
    date_acquisition: dt.date
    date_mise_en_service: dt.date
    valeur_acquisition: int = Field(gt=0, le=10_000_000_000)
    valeur_residuelle: int = Field(default=0, ge=0)
    tiers_id: int | None = None
    reference_facture: str | None = Field(default=None, max_length=120)
    numero_serie: str | None = Field(default=None, max_length=120)
    localisation: str | None = Field(default=None, max_length=200)
    date_fin_garantie: dt.date | None = None
    utilisateur_id: int | None = None          # affectation immédiate à un agent
    agence_id: int | None = None


@router.post("/immobilisations", status_code=201)
def enregistrer_unite(body: UniteIn, user: User = Depends(require("immobilisation:gerer"))):
    """Enregistre une unité d'un article immobilisable au registre (numéro, amortissement du module 52), avec affectation facultative."""
    ag = agence_scope(user, body.agence_id)
    with tx(user.login) as cur:
        a = _article(cur, body.article_id)
        if a["type"] != "immobilisable" or not a["actif"]:
            raise HTTPException(status_code=422, detail="Article immobilisable actif obligatoire")
        r = one_row(cur, "INSERT INTO mf.immobilisation(agence_id, designation, categorie, date_acquisition, date_mise_en_service, valeur_acquisition, valeur_residuelle, "
                         "tiers_id, reference_facture, numero_serie, localisation, date_fin_garantie, cree_par, article_id) "
                         "VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s) RETURNING id",
                    (ag, body.designation, a["categorie_immobilisation"], body.date_acquisition, body.date_mise_en_service, body.valeur_acquisition, body.valeur_residuelle,
                     body.tiers_id, body.reference_facture, body.numero_serie, body.localisation, body.date_fin_garantie, user.id, body.article_id))
        if body.utilisateur_id is not None:
            cur.execute("SELECT mf.affecter_immobilisation(%s, %s, %s, %s, %s)", (r["id"], body.utilisateur_id, body.date_mise_en_service, "Affectation initiale", user.id))
        return _immo(cur, user, r["id"])


class AffectationIn(BaseModel):
    utilisateur_id: int
    date_debut: dt.date | None = None
    motif: str | None = Field(default=None, max_length=300)


@router.post("/immobilisations/{immo_id}/affecter")
def affecter(immo_id: int, body: AffectationIn, user: User = Depends(require("stock:mouvoir"))):
    with tx(user.login) as cur:
        _immo(cur, user, immo_id)
        cur.execute("SELECT mf.affecter_immobilisation(%s, %s, %s, %s, %s)", (immo_id, body.utilisateur_id, body.date_debut, body.motif, user.id))
        return _immo(cur, user, immo_id)


class RestitutionIn(BaseModel):
    date_fin: dt.date | None = None


@router.post("/immobilisations/{immo_id}/restituer")
def restituer(immo_id: int, body: RestitutionIn, user: User = Depends(require("stock:mouvoir"))):
    with tx(user.login) as cur:
        _immo(cur, user, immo_id)
        cur.execute("SELECT mf.restituer_immobilisation(%s, %s)", (immo_id, body.date_fin))
        return _immo(cur, user, immo_id)


@router.get("/immobilisations/{immo_id}/affectations")
def historique_affectations(immo_id: int, user: User = Depends(require("stock:read"))):
    with tx() as cur:
        _immo(cur, user, immo_id)
        return all_rows(cur, "SELECT f.*, u.nom AS agent FROM mf.affectation_immobilisation f JOIN mf.utilisateur u ON u.id = f.utilisateur_id "
                             "WHERE f.immobilisation_id = %s ORDER BY f.id DESC", (immo_id,))
