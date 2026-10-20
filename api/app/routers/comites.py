"""Comité de gestion du crédit : comités, membres, délégations, séances, dossiers, votes, décisions, procès-verbal.

Les règles (quorum, majorité, compétence, visites, figement du procès-verbal) sont dans le schéma (module 35) ;
cette couche gère le périmètre (agence / réseau / siège), les droits d'animation et la présentation."""
import datetime as dt
from typing import Literal

from fastapi import APIRouter, Depends, HTTPException, Query
from pydantic import BaseModel, Field

from ..auth import User, require
from ..db import all_rows, one_row, tx

router = APIRouter(prefix="/api/comites", tags=["comites"])


# ------------------------------------------------------------------ périmètre
def _comite(cur, comite_id: int) -> dict:
    c = one_row(cur, "SELECT * FROM comite_credit WHERE id = %s", (comite_id,))
    if c is None:
        raise HTTPException(status_code=404, detail="Comité introuvable")
    return c


def _voit(cur, user: User, c: dict) -> bool:
    if user.siege or (c["agence_id"] is None and c["reseau_id"] is None):
        return True
    if c["agence_id"] is not None:
        return user.peut_agence(c["agence_id"])
    return one_row(cur, "SELECT 1 AS x FROM agence WHERE reseau_id = %s AND id = ANY(%s) LIMIT 1", (c["reseau_id"], user.agences)) is not None


def _gere(cur, user: User, c: dict) -> bool:
    """Droit de créer / modifier le comité : agence -> périmètre de l'utilisateur ; réseau -> son réseau ; central -> siège."""
    if user.siege:
        return True
    if c["agence_id"] is not None:
        return user.peut_agence(c["agence_id"])
    if c["reseau_id"] is not None:
        return user.reseau_id == c["reseau_id"]
    return False


def _acces_comite(cur, user: User, comite_id: int) -> dict:
    c = _comite(cur, comite_id)
    if not _voit(cur, user, c):
        raise HTTPException(status_code=404, detail="Introuvable")
    return c


def _membre(cur, comite_id: int, user_id: int) -> dict | None:
    return one_row(cur, "SELECT * FROM comite_membre WHERE comite_id = %s AND utilisateur_id = %s "
                        "AND depuis <= current_date AND (jusqua IS NULL OR jusqua >= current_date)", (comite_id, user_id))


def _anime(cur, user: User, c: dict) -> bool:
    """Peut préparer et conduire la séance : gestionnaire du comité, président ou secrétaire."""
    if "comite:manage" in _perms(user) and _gere(cur, user, c):
        return True
    m = _membre(cur, c["id"], user.id)
    return m is not None and m["fonction"] in ("president", "secretaire")


def _perms(user: User) -> set[str]:
    from ..perms import PERMS
    return {p for p, roles in PERMS.items() if user.role in roles}


def _exiger_anime(cur, user: User, c: dict) -> None:
    if not _anime(cur, user, c):
        raise HTTPException(status_code=403, detail="Réservé au gestionnaire du comité, au président ou au secrétaire")


# ------------------------------------------------------------------ comités et membres
class ComiteIn(BaseModel):
    code: str = Field(min_length=1, max_length=10, pattern=r"^[A-Za-z0-9_-]+$")
    libelle: str = Field(min_length=1, max_length=200)
    agence_id: int | None = None
    reseau_id: int | None = None
    montant_min: int = Field(default=0, ge=0)
    montant_max: int | None = Field(default=None, gt=0)
    quorum: int = Field(default=3, ge=1, le=20)


class ComitePatch(BaseModel):
    libelle: str | None = Field(default=None, min_length=1, max_length=200)
    montant_min: int | None = Field(default=None, ge=0)
    montant_max: int | None = Field(default=None, gt=0)
    quorum: int | None = Field(default=None, ge=1, le=20)
    actif: bool | None = None


@router.get("")
def lister(user: User = Depends(require("comite:read"))):
    with tx() as cur:
        lignes = all_rows(
            cur,
            "SELECT c.*, a.code AS agence, r.code AS reseau, "
            "  (SELECT count(*) FROM comite_membre m WHERE m.comite_id = c.id AND m.jusqua IS NULL) AS nb_membres "
            "FROM comite_credit c LEFT JOIN agence a ON a.id = c.agence_id LEFT JOIN reseau r ON r.id = c.reseau_id ORDER BY c.code",
        )
        return [c for c in lignes if _voit(cur, user, c)]


@router.post("", status_code=201)
def creer(body: ComiteIn, user: User = Depends(require("comite:manage"))):
    with tx(user.login) as cur:
        if not _gere(cur, user, body.model_dump()):
            raise HTTPException(status_code=403, detail="Ce comité est hors de votre périmètre")
        return one_row(
            cur,
            "INSERT INTO comite_credit(code, libelle, agence_id, reseau_id, montant_min, montant_max, quorum) "
            "VALUES (%s, %s, %s, %s, %s, %s, %s) RETURNING *",
            (body.code, body.libelle, body.agence_id, body.reseau_id, body.montant_min, body.montant_max, body.quorum),
        )


@router.patch("/{comite_id}")
def modifier(comite_id: int, body: ComitePatch, user: User = Depends(require("comite:manage"))):
    champs = body.model_dump(exclude_unset=True)
    if not champs:
        raise HTTPException(status_code=422, detail="Aucune modification")
    with tx(user.login) as cur:
        c = _acces_comite(cur, user, comite_id)
        if not _gere(cur, user, c):
            raise HTTPException(status_code=403, detail="Ce comité est hors de votre périmètre")
        sets = ", ".join(f"{k} = %s" for k in champs)
        return one_row(cur, f"UPDATE comite_credit SET {sets} WHERE id = %s RETURNING *", (*champs.values(), comite_id))


@router.get("/{comite_id}")
def detail(comite_id: int, user: User = Depends(require("comite:read"))):
    with tx() as cur:
        c = _acces_comite(cur, user, comite_id)
        c["membres"] = all_rows(
            cur,
            "SELECT m.id, m.utilisateur_id, u.login, u.nom, u.role::text AS role, m.fonction, m.avec_voix, m.depuis, m.jusqua "
            "FROM comite_membre m JOIN utilisateur u ON u.id = m.utilisateur_id WHERE m.comite_id = %s "
            "ORDER BY (m.jusqua IS NOT NULL), CASE m.fonction WHEN 'president' THEN 0 WHEN 'secretaire' THEN 1 ELSE 2 END, u.nom",
            (comite_id,),
        )
        return c


class MembreIn(BaseModel):
    utilisateur_id: int
    fonction: Literal["president", "secretaire", "membre"] = "membre"
    avec_voix: bool = True


@router.post("/{comite_id}/membres", status_code=201)
def ajouter_membre(comite_id: int, body: MembreIn, user: User = Depends(require("comite:manage"))):
    with tx(user.login) as cur:
        c = _acces_comite(cur, user, comite_id)
        if not _gere(cur, user, c):
            raise HTTPException(status_code=403, detail="Ce comité est hors de votre périmètre")
        cible = one_row(cur, "SELECT id, actif, agences_utilisateur(id) AS agences FROM utilisateur WHERE id = %s", (body.utilisateur_id,))
        if cible is None or not cible["actif"]:
            raise HTTPException(status_code=404, detail="Utilisateur introuvable ou inactif")
        # un membre doit pouvoir opérer sur les dossiers du comité
        if c["agence_id"] is not None and cible["agences"] is not None and c["agence_id"] not in cible["agences"]:
            raise HTTPException(status_code=422, detail="Cet utilisateur n'appartient pas à l'agence du comité")
        return one_row(
            cur,
            "INSERT INTO comite_membre(comite_id, utilisateur_id, fonction, avec_voix) VALUES (%s, %s, %s, %s) "
            "ON CONFLICT (comite_id, utilisateur_id) DO UPDATE SET fonction = EXCLUDED.fonction, avec_voix = EXCLUDED.avec_voix, "
            "  jusqua = NULL, depuis = current_date RETURNING *",
            (comite_id, body.utilisateur_id, body.fonction, body.avec_voix),
        )


@router.post("/{comite_id}/membres/{membre_id}/retirer", status_code=204)
def retirer_membre(comite_id: int, membre_id: int, user: User = Depends(require("comite:manage"))):
    with tx(user.login) as cur:
        c = _acces_comite(cur, user, comite_id)
        if not _gere(cur, user, c):
            raise HTTPException(status_code=403, detail="Ce comité est hors de votre périmètre")
        cur.execute("UPDATE comite_membre SET jusqua = current_date WHERE id = %s AND comite_id = %s AND jusqua IS NULL", (membre_id, comite_id))
        if cur.rowcount == 0:
            raise HTTPException(status_code=404, detail="Membre introuvable")


@router.get("/utilisateurs/liste")
def utilisateurs_du_perimetre(user: User = Depends(require("comite:read"))):
    """Utilisateurs actifs de mon périmètre (choix des membres, rapporteurs, bénéficiaires de délégation)."""
    with tx() as cur:
        return all_rows(
            cur,
            "SELECT id, login, nom, role::text AS role, agence_id, reseau_id FROM utilisateur "
            "WHERE actif AND (%s OR (agences_utilisateur(id) && %s::int[])) ORDER BY nom",
            (user.siege, user.agences or []),
        )


# ------------------------------------------------------------------ délégations
class DelegationIn(BaseModel):
    utilisateur_id: int
    montant_max_credit: int = Field(gt=0)
    montant_max_periode: int | None = Field(default=None, gt=0)
    periode: Literal["mois", "trimestre", "annee"] = "mois"
    fin: dt.date | None = None
    motif: str = Field(min_length=5, max_length=500)


@router.get("/delegations/liste")
def delegations(user: User = Depends(require("comite:read"))):
    with tx() as cur:
        return all_rows(
            cur,
            "SELECT d.*, u.login, u.nom, g.login AS accordee_par_login, "
            "       (d.debut <= current_date AND (d.fin IS NULL OR d.fin >= current_date)) AS active "
            "FROM delegation_credit d JOIN utilisateur u ON u.id = d.utilisateur_id JOIN utilisateur g ON g.id = d.accordee_par "
            "WHERE (%s OR (agences_utilisateur(d.utilisateur_id) && %s::int[])) ORDER BY d.id DESC LIMIT 200",
            (user.siege, user.agences or []),
        )


@router.post("/delegations", status_code=201)
def accorder_delegation(body: DelegationIn, user: User = Depends(require("delegation:write"))):
    with tx(user.login) as cur:
        cible = one_row(cur, "SELECT id, actif, agences_utilisateur(id) AS agences FROM utilisateur WHERE id = %s", (body.utilisateur_id,))
        if cible is None or not cible["actif"]:
            raise HTTPException(status_code=404, detail="Utilisateur introuvable ou inactif")
        # on ne délègue qu'à quelqu'un de son propre périmètre
        if not user.siege and (cible["agences"] is None or not set(cible["agences"]) <= set(user.agences or [])):
            raise HTTPException(status_code=403, detail="Ce bénéficiaire est hors de votre périmètre")
        return one_row(
            cur,
            "INSERT INTO delegation_credit(utilisateur_id, montant_max_credit, montant_max_periode, periode, fin, motif, accordee_par) "
            "VALUES (%s, %s, %s, %s, %s, %s, %s) RETURNING *",
            (body.utilisateur_id, body.montant_max_credit, body.montant_max_periode, body.periode, body.fin, body.motif, user.id),
        )


@router.post("/delegations/{delegation_id}/terminer")
def terminer_delegation(delegation_id: int, user: User = Depends(require("delegation:write"))):
    with tx(user.login) as cur:
        d = one_row(cur, "SELECT d.*, agences_utilisateur(d.utilisateur_id) AS agences FROM delegation_credit d WHERE d.id = %s", (delegation_id,))
        if d is None or (not user.siege and (d["agences"] is None or not set(d["agences"]) <= set(user.agences or []))):
            raise HTTPException(status_code=404, detail="Introuvable")
        return one_row(cur, "UPDATE delegation_credit SET fin = current_date WHERE id = %s AND (fin IS NULL OR fin > current_date) RETURNING *", (delegation_id,))


# ------------------------------------------------------------------ séances
class SeanceIn(BaseModel):
    comite_id: int
    date_seance: dt.datetime
    lieu: str | None = Field(default=None, max_length=200)
    ordre_du_jour: str | None = Field(default=None, max_length=4000)


class SeancePatch(BaseModel):
    date_seance: dt.datetime | None = None
    lieu: str | None = Field(default=None, max_length=200)
    ordre_du_jour: str | None = Field(default=None, max_length=4000)


def _seance(cur, user: User, seance_id: int) -> tuple[dict, dict]:
    s = one_row(cur, "SELECT * FROM seance_comite WHERE id = %s", (seance_id,))
    if s is None:
        raise HTTPException(status_code=404, detail="Séance introuvable")
    c = _acces_comite(cur, user, s["comite_id"])
    return s, c


@router.get("/seances/liste")
def seances(statut: str | None = None, comite_id: int | None = None, user: User = Depends(require("comite:read"))):
    with tx() as cur:
        lignes = all_rows(
            cur,
            "SELECT s.id, s.numero, s.comite_id, c.code AS comite, c.agence_id, c.reseau_id, s.date_seance, s.lieu, s.statut, "
            "       g.nb_dossiers, g.total_demande, g.total_accorde, g.nb_acceptes, g.nb_ajournes, g.nb_rejetes "
            "FROM seance_comite s JOIN comite_credit c ON c.id = s.comite_id JOIN v_seance_analyse_globale g ON g.seance_id = s.id "
            "WHERE (%s::text IS NULL OR s.statut = %s) AND (%s::int IS NULL OR s.comite_id = %s) ORDER BY s.date_seance DESC LIMIT 200",
            (statut, statut, comite_id, comite_id),
        )
        return [l for l in lignes if _voit(cur, user, l)]


@router.post("/seances", status_code=201)
def creer_seance(body: SeanceIn, user: User = Depends(require("comite:participer"))):
    with tx(user.login) as cur:
        c = _acces_comite(cur, user, body.comite_id)
        _exiger_anime(cur, user, c)
        return one_row(
            cur,
            "INSERT INTO seance_comite(comite_id, date_seance, lieu, ordre_du_jour, cree_par) VALUES (%s, %s, %s, %s, %s) RETURNING *",
            (body.comite_id, body.date_seance, body.lieu, body.ordre_du_jour, user.id),
        )


@router.patch("/seances/{seance_id}")
def modifier_seance(seance_id: int, body: SeancePatch, user: User = Depends(require("comite:participer"))):
    champs = body.model_dump(exclude_unset=True)
    if not champs:
        raise HTTPException(status_code=422, detail="Aucune modification")
    with tx(user.login) as cur:
        s, c = _seance(cur, user, seance_id)
        _exiger_anime(cur, user, c)
        if s["statut"] not in ("preparee", "convoquee"):
            raise HTTPException(status_code=422, detail="La séance ne peut plus être modifiée")
        sets = ", ".join(f"{k} = %s" for k in champs)
        return one_row(cur, f"UPDATE seance_comite SET {sets} WHERE id = %s RETURNING *", (*champs.values(), seance_id))


DOSSIER_SQL = (
    "SELECT sd.*, d.numero AS demande_numero, d.nb_echeances, d.taux, d.garantie_montant, d.statut AS statut_demande, "
    "       d.agence_id, cl.nom AS client, p.code AS produit, rp.nom AS rapporteur, "
    "       ac.conforme AS analyse_conforme, ac.taux_endettement, ac.couverture "
    "FROM seance_dossier sd JOIN demande_credit d ON d.id = sd.demande_id JOIN client cl ON cl.id = d.client_id "
    "JOIN produit_credit_epargne p ON p.id = d.produit_id LEFT JOIN utilisateur rp ON rp.id = sd.rapporteur_id "
    "LEFT JOIN analyse_capacite ac ON ac.demande_id = d.id "
)


def _detail_seance(cur, user: User, seance_id: int, tout_voir: bool = False) -> dict:
    s, c = _seance(cur, user, seance_id)
    s["comite"] = c
    s["membres"] = all_rows(
        cur,
        "SELECT m.utilisateur_id, u.login, u.nom, m.fonction, m.avec_voix, p.present, p.motif_absence "
        "FROM comite_membre m JOIN utilisateur u ON u.id = m.utilisateur_id "
        "LEFT JOIN seance_presence p ON p.seance_id = %s AND p.utilisateur_id = m.utilisateur_id "
        "WHERE m.comite_id = %s AND (m.jusqua IS NULL OR p.seance_id IS NOT NULL) "
        "ORDER BY CASE m.fonction WHEN 'president' THEN 0 WHEN 'secretaire' THEN 1 ELSE 2 END, u.nom",
        (seance_id, s["comite_id"]),
    )
    s["quorum_atteint"] = one_row(cur, "SELECT seance_quorum(%s) AS q", (seance_id,))["q"]
    dossiers = all_rows(cur, DOSSIER_SQL + "WHERE sd.seance_id = %s ORDER BY sd.id", (seance_id,))
    for d in dossiers:
        votes = all_rows(cur, "SELECT v.utilisateur_id, u.nom, v.vote, v.motif, v.vote_le FROM seance_vote v JOIN utilisateur u ON u.id = v.utilisateur_id "
                              "WHERE v.dossier_id = %s ORDER BY u.nom", (d["id"],))
        d["nb_votes"] = len(votes)
        d["recusations"] = all_rows(cur, "SELECT r.utilisateur_id, u.nom, r.motif FROM seance_recusation r JOIN utilisateur u ON u.id = r.utilisateur_id WHERE r.dossier_id = %s", (d["id"],))
        # le vote reste secret tant que le dossier n'est pas décidé : chacun ne voit que le sien
        if d["decision"] is not None or tout_voir:
            d["votes"] = votes
        else:
            d["votes"] = [v for v in votes if v["utilisateur_id"] == user.id]
    s["dossiers"] = dossiers
    s["analyse_globale"] = one_row(cur, "SELECT * FROM v_seance_analyse_globale WHERE seance_id = %s", (seance_id,))
    s["signataires"] = one_row(
        cur,
        "SELECT (SELECT nom FROM comite_membre m JOIN utilisateur u ON u.id = m.utilisateur_id WHERE m.comite_id = %s AND m.fonction = 'president' AND m.jusqua IS NULL) AS president, "
        "       (SELECT nom FROM comite_membre m JOIN utilisateur u ON u.id = m.utilisateur_id WHERE m.comite_id = %s AND m.fonction = 'secretaire' AND m.jusqua IS NULL) AS secretaire",
        (s["comite_id"], s["comite_id"]),
    )
    return s


@router.get("/seances/{seance_id}")
def detail_seance(seance_id: int, user: User = Depends(require("comite:read"))):
    with tx() as cur:
        return _detail_seance(cur, user, seance_id)


class InscriptionIn(BaseModel):
    demande_id: int
    rapporteur_id: int | None = None
    analyse_individuelle: str | None = Field(default=None, max_length=4000)


@router.post("/seances/{seance_id}/dossiers", status_code=201)
def inscrire(seance_id: int, body: InscriptionIn, user: User = Depends(require("comite:participer"))):
    with tx(user.login) as cur:
        s, c = _seance(cur, user, seance_id)
        _exiger_anime(cur, user, c)
        if s["statut"] not in ("preparee", "convoquee"):
            raise HTTPException(status_code=422, detail="On n'inscrit plus de dossier : la séance est ouverte ou terminée")
        d = one_row(cur, "SELECT agence_id FROM demande_credit WHERE id = %s", (body.demande_id,))
        if d is None or not user.peut_agence(d["agence_id"]):
            raise HTTPException(status_code=404, detail="Demande introuvable")
        return one_row(cur, "INSERT INTO seance_dossier(seance_id, demande_id, rapporteur_id, analyse_individuelle) VALUES (%s, %s, %s, %s) RETURNING *",
                       (seance_id, body.demande_id, body.rapporteur_id, body.analyse_individuelle))


class DossierPatch(BaseModel):
    rapporteur_id: int | None = None
    analyse_individuelle: str | None = Field(default=None, max_length=4000)
    visite_le: dt.date | None = None
    visite_par: int | None = None
    contre_visite_le: dt.date | None = None
    contre_visite_par: int | None = None


def _dossier(cur, user: User, dossier_id: int) -> tuple[dict, dict, dict]:
    d = one_row(cur, "SELECT * FROM seance_dossier WHERE id = %s", (dossier_id,))
    if d is None:
        raise HTTPException(status_code=404, detail="Dossier introuvable")
    s, c = _seance(cur, user, d["seance_id"])
    return d, s, c


@router.patch("/dossiers/{dossier_id}")
def modifier_dossier(dossier_id: int, body: DossierPatch, user: User = Depends(require("comite:participer"))):
    champs = body.model_dump(exclude_unset=True)
    if not champs:
        raise HTTPException(status_code=422, detail="Aucune modification")
    with tx(user.login) as cur:
        d, s, c = _dossier(cur, user, dossier_id)
        _exiger_anime(cur, user, c)
        # visite et contre-visite se renseignent en paire (personne + date)
        if ("visite_le" in champs) != ("visite_par" in champs) or ("contre_visite_le" in champs) != ("contre_visite_par" in champs):
            raise HTTPException(status_code=422, detail="Renseignez la date ET la personne pour une visite")
        sets = ", ".join(f"{k} = %s" for k in champs)
        return one_row(cur, f"UPDATE seance_dossier SET {sets} WHERE id = %s RETURNING *", (*champs.values(), dossier_id))


@router.delete("/dossiers/{dossier_id}", status_code=204)
def retirer_dossier(dossier_id: int, user: User = Depends(require("comite:participer"))):
    with tx(user.login) as cur:
        d, s, c = _dossier(cur, user, dossier_id)
        _exiger_anime(cur, user, c)
        if s["statut"] not in ("preparee", "convoquee"):
            raise HTTPException(status_code=422, detail="Le dossier ne peut plus être retiré")
        cur.execute("DELETE FROM seance_dossier WHERE id = %s", (dossier_id,))


@router.post("/seances/{seance_id}/convoquer")
def convoquer(seance_id: int, user: User = Depends(require("comite:participer"))):
    with tx(user.login) as cur:
        s, c = _seance(cur, user, seance_id)
        _exiger_anime(cur, user, c)
        cur.execute("SELECT convoquer_seance(%s, %s)", (seance_id, user.id))
        return _detail_seance(cur, user, seance_id)


class PresenceIn(BaseModel):
    utilisateur_id: int
    present: bool
    motif_absence: str | None = Field(default=None, max_length=300)


@router.post("/seances/{seance_id}/presences")
def pointer(seance_id: int, body: PresenceIn, user: User = Depends(require("comite:participer"))):
    with tx(user.login) as cur:
        s, c = _seance(cur, user, seance_id)
        _exiger_anime(cur, user, c)
        cur.execute("SELECT pointer_presence(%s, %s, %s, %s)", (seance_id, body.utilisateur_id, body.present, body.motif_absence))
        return _detail_seance(cur, user, seance_id)


@router.post("/seances/{seance_id}/ouvrir")
def ouvrir(seance_id: int, user: User = Depends(require("comite:participer"))):
    with tx(user.login) as cur:
        s, c = _seance(cur, user, seance_id)
        _exiger_anime(cur, user, c)
        cur.execute("SELECT ouvrir_seance(%s)", (seance_id,))
        return _detail_seance(cur, user, seance_id)


class VoteIn(BaseModel):
    vote: Literal["acceptation", "ajournement", "rejet", "abstention"]
    motif: str | None = Field(default=None, max_length=1000)


@router.post("/dossiers/{dossier_id}/vote", status_code=201)
def voter(dossier_id: int, body: VoteIn, user: User = Depends(require("comite:participer"))):
    """Vote du membre connecté (modifiable tant que le dossier n'est pas décidé). Le vote est secret jusqu'à la décision."""
    with tx(user.login) as cur:
        _dossier(cur, user, dossier_id)
        cur.execute(
            "INSERT INTO seance_vote(dossier_id, utilisateur_id, vote, motif) VALUES (%s, %s, %s, %s) "
            "ON CONFLICT (dossier_id, utilisateur_id) DO UPDATE SET vote = EXCLUDED.vote, motif = EXCLUDED.motif, vote_le = now()",
            (dossier_id, user.id, body.vote, body.motif),
        )
        return {"dossier_id": dossier_id, "vote": body.vote}


class RecusationIn(BaseModel):
    utilisateur_id: int | None = None      # vide : le membre connecté se récuse
    motif: str = Field(min_length=5, max_length=500)


@router.post("/dossiers/{dossier_id}/recusation", status_code=201)
def recuser(dossier_id: int, body: RecusationIn, user: User = Depends(require("comite:participer"))):
    with tx(user.login) as cur:
        d, s, c = _dossier(cur, user, dossier_id)
        cible = body.utilisateur_id or user.id
        if cible != user.id:
            _exiger_anime(cur, user, c)
        if _membre(cur, c["id"], cible) is None:
            raise HTTPException(status_code=422, detail="Cette personne n'est pas membre du comité")
        return one_row(cur, "INSERT INTO seance_recusation(dossier_id, utilisateur_id, motif) VALUES (%s, %s, %s) RETURNING *",
                       (dossier_id, cible, body.motif))


class DecisionIn(BaseModel):
    motif: str = Field(min_length=10, max_length=2000)
    montant_accorde: int | None = Field(default=None, gt=0)
    conditions: str | None = Field(default=None, max_length=2000)


@router.post("/dossiers/{dossier_id}/decider")
def decider(dossier_id: int, body: DecisionIn, user: User = Depends(require("comite:participer"))):
    """Constate la décision d'après les votes (majorité) et l'applique à la demande de crédit."""
    with tx(user.login) as cur:
        d, s, c = _dossier(cur, user, dossier_id)
        m = _membre(cur, c["id"], user.id)
        if m is None or m["fonction"] not in ("president", "secretaire"):
            raise HTTPException(status_code=403, detail="Seuls le président et le secrétaire constatent la décision")
        r = one_row(cur, "SELECT decider_dossier(%s, %s, %s, %s, %s) AS decision", (dossier_id, body.motif, body.montant_accorde, body.conditions, user.id))
        out = one_row(cur, DOSSIER_SQL + "WHERE sd.id = %s", (dossier_id,))
        out["decision_calculee"] = r["decision"]
        return out


@router.post("/seances/{seance_id}/signer")
def signer(seance_id: int, user: User = Depends(require("comite:participer"))):
    with tx(user.login) as cur:
        _seance(cur, user, seance_id)
        fonction = one_row(cur, "SELECT signer_pv(%s, %s) AS f", (seance_id, user.id))["f"]
        return {"signe_en_tant_que": fonction}


@router.post("/seances/{seance_id}/cloturer")
def cloturer(seance_id: int, user: User = Depends(require("comite:participer"))):
    with tx(user.login) as cur:
        s, c = _seance(cur, user, seance_id)
        _exiger_anime(cur, user, c)
        cur.execute("SELECT cloturer_seance(%s)", (seance_id,))
        return _detail_seance(cur, user, seance_id)


class AnnulationIn(BaseModel):
    motif: str = Field(min_length=5, max_length=500)


@router.post("/seances/{seance_id}/annuler")
def annuler(seance_id: int, body: AnnulationIn, user: User = Depends(require("comite:participer"))):
    with tx(user.login) as cur:
        s, c = _seance(cur, user, seance_id)
        _exiger_anime(cur, user, c)
        cur.execute("SELECT annuler_seance(%s, %s)", (seance_id, body.motif))
        return _detail_seance(cur, user, seance_id)


@router.get("/seances/{seance_id}/pv")
def proces_verbal(seance_id: int, user: User = Depends(require("comite:read"))):
    """Données du procès-verbal imprimable (séance ouverte ou close)."""
    with tx() as cur:
        s = _detail_seance(cur, user, seance_id, tout_voir=True)
        if s["statut"] not in ("ouverte", "close"):
            raise HTTPException(status_code=422, detail="Le procès-verbal n'existe qu'une fois la séance ouverte")
        s["institution"] = one_row(cur, "SELECT raison_sociale, sigle, agrement, adresse, ville, telephone, email, logo, pied_de_page FROM institution WHERE id = 1")
        s["agence"] = one_row(cur, "SELECT code, libelle, adresse, ville, telephone FROM agence WHERE id = %s", (s["comite"]["agence_id"],)) if s["comite"]["agence_id"] else None
        # votes visibles dans le PV : si le dossier n'est pas décidé, ils ne sont pas révélés
        for d in s["dossiers"]:
            if d["decision"] is None:
                d["votes"] = []
        return s


# ------------------------------------------------------------------ aides
@router.get("/demandes/a-examiner")
def a_examiner(comite_id: int, user: User = Depends(require("comite:read"))):
    """Demandes en attente relevant de la compétence du comité (montant, agence ou réseau) et pas déjà inscrites."""
    with tx() as cur:
        c = _acces_comite(cur, user, comite_id)
        return all_rows(
            cur,
            "SELECT d.id, d.numero, d.agence_id, ag.code AS agence, d.montant, d.nb_echeances, d.date_demande, cl.nom AS client, p.code AS produit, "
            "       ac.conforme AS analyse_conforme "
            "FROM demande_credit d JOIN agence ag ON ag.id = d.agence_id JOIN client cl ON cl.id = d.client_id "
            "JOIN produit_credit_epargne p ON p.id = d.produit_id LEFT JOIN analyse_capacite ac ON ac.demande_id = d.id "
            "WHERE d.statut = 'demandee' AND d.montant >= %s AND (%s::numeric IS NULL OR d.montant <= %s) "
            "  AND (%s::int IS NULL OR d.agence_id = %s) AND (%s::int IS NULL OR ag.reseau_id = %s) "
            "  AND (%s OR d.agence_id = ANY(%s)) "
            "  AND NOT EXISTS (SELECT 1 FROM seance_dossier sd WHERE sd.demande_id = d.id AND sd.decision IS NULL) "
            "ORDER BY d.date_demande, d.id LIMIT 200",
            (c["montant_min"], c["montant_max"], c["montant_max"], c["agence_id"], c["agence_id"], c["reseau_id"], c["reseau_id"],
             user.siege, user.agences or []),
        )


@router.get("/demandes/{demande_id}/historique")
def historique_demande(demande_id: int, user: User = Depends(require("comite:read"))):
    """Passages d'une demande devant les comités (ajournements successifs, décision finale)."""
    with tx() as cur:
        d = one_row(cur, "SELECT agence_id FROM demande_credit WHERE id = %s", (demande_id,))
        if d is None or not user.peut_agence(d["agence_id"]):
            raise HTTPException(status_code=404, detail="Introuvable")
        return all_rows(
            cur,
            "SELECT sd.id AS dossier_id, s.id AS seance_id, s.numero AS seance, s.date_seance, s.statut AS statut_seance, c.code AS comite, "
            "       sd.decision, sd.motif, sd.montant_accorde, sd.conditions, sd.decide_le "
            "FROM seance_dossier sd JOIN seance_comite s ON s.id = sd.seance_id JOIN comite_credit c ON c.id = s.comite_id "
            "WHERE sd.demande_id = %s ORDER BY s.date_seance DESC",
            (demande_id,),
        )
