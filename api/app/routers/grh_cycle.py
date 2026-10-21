"""GRH — recrutement, formation, évaluations, sanctions, sorties (modules 41 à 43).
Les règles (décideur ≠ demandeur, quorum de notes, figement, préavis, prescription) sont dans le schéma."""
import datetime as dt
from typing import Literal

from fastapi import APIRouter, Depends, HTTPException
from pydantic import BaseModel, Field

from ..auth import User, agence_filter, agence_scope, require, verifier_agence
from ..db import all_rows, one_row, tx
from ..perms import ADMIN, DIR, RH

router = APIRouter(prefix="/api/grh", tags=["grh"])


def _employe_de(cur, user: User, table: str, row_id: int, colonne: str = "employe_id") -> int:
    r = one_row(cur, f"SELECT {colonne} AS e FROM {table} WHERE id = %s", (row_id,))
    if r is None:
        raise HTTPException(status_code=404, detail="Introuvable")
    verifier_agence(cur, user, "employe", r["e"])
    return r["e"]


def _pas_soi_meme(cur, user: User, employe_id: int) -> None:
    """Séparation des tâches : on ne traite pas son propre dossier disciplinaire ou d'évaluation."""
    if one_row(cur, "SELECT 1 FROM employe WHERE id = %s AND utilisateur_id = %s", (employe_id, user.id)):
        raise HTTPException(status_code=403, detail="Vous ne pouvez pas traiter un dossier qui vous concerne")


def _evaluation_accessible(cur, user: User, evaluation_id: int) -> None:
    """Écriture sur une évaluation : ni l'évalué, ni un autre que l'évaluateur désigné (sauf administration, direction, RH)."""
    ev = one_row(cur, "SELECT ev.employe_id, ee.utilisateur_id AS evaluateur_user FROM evaluation ev JOIN employe ee ON ee.id = ev.evaluateur_id WHERE ev.id = %s", (evaluation_id,))
    if ev is None:
        raise HTTPException(status_code=404, detail="Introuvable")
    verifier_agence(cur, user, "employe", ev["employe_id"])
    _pas_soi_meme(cur, user, ev["employe_id"])
    if ev["evaluateur_user"] is not None and ev["evaluateur_user"] != user.id and user.role not in (ADMIN, DIR, RH):
        raise HTTPException(status_code=403, detail="Seul l'évaluateur désigné peut noter cette évaluation")


# ---------------------------------------------------------------- recrutement
class BesoinIn(BaseModel):
    agence_id: int | None = None
    poste_id: int
    motif: str = Field(min_length=5, max_length=500)
    nb_postes: int = Field(default=1, ge=1, le=50)
    date_souhaitee: dt.date | None = None


@router.get("/besoins")
def besoins(statut: str | None = None, agence_id: int | None = None, user: User = Depends(require("grh:read"))):
    ag = agence_filter(user, agence_id)
    with tx() as cur:
        return all_rows(cur, "SELECT v.*, b.motif, b.date_souhaitee, b.decide_par, b.commentaire FROM v_recrutement v JOIN besoin_recrutement b ON b.id = v.besoin_id "
                             "WHERE (%s::int IS NULL OR v.agence_id = %s) AND (%s::text IS NULL OR v.statut = %s) ORDER BY v.besoin_id DESC", (ag, ag, statut, statut))


@router.post("/besoins", status_code=201)
def creer_besoin(body: BesoinIn, user: User = Depends(require("grh:write"))):
    ag = agence_scope(user, body.agence_id)
    with tx(user.login) as cur:
        return one_row(cur, "INSERT INTO besoin_recrutement(agence_id, poste_id, motif, nb_postes, date_souhaitee, demandeur_id) VALUES (%s, %s, %s, %s, %s, %s) RETURNING *",
                       (ag, body.poste_id, body.motif, body.nb_postes, body.date_souhaitee, user.id))


class DecisionBesoinIn(BaseModel):
    approuve: bool
    commentaire: str | None = Field(default=None, max_length=500)


@router.post("/besoins/{besoin_id}/decider")
def decider_besoin(besoin_id: int, body: DecisionBesoinIn, user: User = Depends(require("recrutement:decider"))):
    with tx(user.login) as cur:
        verifier_agence(cur, user, "besoin_recrutement", besoin_id)
        cur.execute("UPDATE besoin_recrutement SET statut = %s, decide_par = %s, commentaire = %s WHERE id = %s AND statut = 'soumis'",
                    ("approuve" if body.approuve else "refuse", user.id, body.commentaire, besoin_id))
        if cur.rowcount == 0:
            raise HTTPException(status_code=422, detail="Ce besoin n'est plus en attente de décision")
        return one_row(cur, "SELECT * FROM besoin_recrutement WHERE id = %s", (besoin_id,))


class CandidatIn(BaseModel):
    nom: str = Field(min_length=2, max_length=200)
    telephone: str | None = Field(default=None, max_length=30)
    email: str | None = Field(default=None, max_length=200)
    source: Literal["spontanee", "annonce", "recommandation", "cabinet", "autre"] = "spontanee"
    cv_reference: str | None = None
    notes: str | None = None


@router.get("/candidats")
def candidats(user: User = Depends(require("grh:write"))):
    with tx() as cur:
        return all_rows(cur, "SELECT * FROM candidat ORDER BY id DESC LIMIT 300")


@router.post("/candidats", status_code=201)
def creer_candidat(body: CandidatIn, user: User = Depends(require("grh:write"))):
    with tx(user.login) as cur:
        return one_row(cur, "INSERT INTO candidat(nom, telephone, email, source, cv_reference, notes) VALUES (%s, %s, %s, %s, %s, %s) RETURNING *",
                       (body.nom, body.telephone, body.email, body.source, body.cv_reference, body.notes))


CAND_SQL = ("SELECT ca.*, c.nom, c.telephone, c.email, "
            "  (SELECT max(note) FROM entretien en WHERE en.candidature_id = ca.id) AS meilleure_note, "
            "  (SELECT count(*) FROM entretien en WHERE en.candidature_id = ca.id) AS nb_entretiens "
            "FROM candidature ca JOIN candidat c ON c.id = ca.candidat_id ")


@router.get("/besoins/{besoin_id}/candidatures")
def candidatures(besoin_id: int, user: User = Depends(require("grh:read"))):
    with tx() as cur:
        verifier_agence(cur, user, "besoin_recrutement", besoin_id)
        return all_rows(cur, CAND_SQL + "WHERE ca.besoin_id = %s ORDER BY ca.id", (besoin_id,))


class CandidatureIn(BaseModel):
    candidat_id: int


@router.post("/besoins/{besoin_id}/candidatures", status_code=201)
def deposer_candidature(besoin_id: int, body: CandidatureIn, user: User = Depends(require("grh:write"))):
    with tx(user.login) as cur:
        verifier_agence(cur, user, "besoin_recrutement", besoin_id)
        r = one_row(cur, "INSERT INTO candidature(besoin_id, candidat_id) VALUES (%s, %s) RETURNING id", (besoin_id, body.candidat_id))
        return one_row(cur, CAND_SQL + "WHERE ca.id = %s", (r["id"],))


class StatutCandidatureIn(BaseModel):
    statut: Literal["preselection", "retenue", "refusee", "desistement"]
    motif_refus: str | None = Field(default=None, max_length=500)


def _verifier_candidature(cur, user: User, candidature_id: int) -> int:
    r = one_row(cur, "SELECT besoin_id FROM candidature WHERE id = %s", (candidature_id,))
    if r is None:
        raise HTTPException(status_code=404, detail="Introuvable")
    verifier_agence(cur, user, "besoin_recrutement", r["besoin_id"])
    return r["besoin_id"]


@router.post("/candidatures/{candidature_id}/statut")
def statut_candidature(candidature_id: int, body: StatutCandidatureIn, user: User = Depends(require("grh:write"))):
    with tx(user.login) as cur:
        _verifier_candidature(cur, user, candidature_id)
        cur.execute("UPDATE candidature SET statut = %s, motif_refus = %s WHERE id = %s", (body.statut, body.motif_refus, candidature_id))
        return one_row(cur, CAND_SQL + "WHERE ca.id = %s", (candidature_id,))


class EntretienIn(BaseModel):
    date_entretien: dt.date
    type: Literal["telephone", "technique", "rh", "direction"] = "rh"
    note: float = Field(ge=0, le=10)
    decision: Literal["favorable", "reserve", "defavorable"]
    avis: str | None = Field(default=None, max_length=1000)


@router.post("/candidatures/{candidature_id}/entretiens", status_code=201)
def ajouter_entretien(candidature_id: int, body: EntretienIn, user: User = Depends(require("grh:write"))):
    with tx(user.login) as cur:
        _verifier_candidature(cur, user, candidature_id)
        return one_row(cur, "INSERT INTO entretien(candidature_id, date_entretien, type, evaluateur_id, note, decision, avis) VALUES (%s, %s, %s, %s, %s, %s, %s) RETURNING *",
                       (candidature_id, body.date_entretien, body.type, user.id, body.note, body.decision, body.avis))


class EmbaucheIn(BaseModel):
    matricule: str = Field(min_length=1, max_length=20)
    date_embauche: dt.date
    salaire_base: int = Field(ge=0)
    type_contrat: Literal["cdi", "cdd", "stage", "journalier"] = "cdi"
    date_fin: dt.date | None = None
    periode_essai_fin: dt.date | None = None


@router.post("/candidatures/{candidature_id}/embaucher", status_code=201)
def embaucher(candidature_id: int, body: EmbaucheIn, user: User = Depends(require("grh:write"))):
    with tx(user.login) as cur:
        _verifier_candidature(cur, user, candidature_id)
        eid = one_row(cur, "SELECT embaucher_candidat(%s, %s, %s, %s, %s, %s, %s) AS id",
                      (candidature_id, body.matricule, body.date_embauche, body.salaire_base, body.type_contrat, body.date_fin, body.periode_essai_fin))["id"]
        return one_row(cur, "SELECT * FROM employe WHERE id = %s", (eid,))


# ---------------------------------------------------------------- formation
class FormationIn(BaseModel):
    code: str = Field(min_length=1, max_length=15)
    titre: str = Field(min_length=2)
    organisme: str | None = None
    duree_heures: float = Field(gt=0, le=2000)
    cout_unitaire: int = Field(default=0, ge=0)
    objectifs: str | None = None


@router.get("/formations")
def formations(user: User = Depends(require("grh:read"))):
    with tx() as cur:
        return all_rows(cur, "SELECT f.*, (SELECT count(*) FROM session_formation s WHERE s.formation_id = f.id) AS nb_sessions FROM formation f ORDER BY f.code")


@router.post("/formations", status_code=201)
def creer_formation(body: FormationIn, user: User = Depends(require("grh:write"))):
    with tx(user.login) as cur:
        return one_row(cur, "INSERT INTO formation(code, titre, organisme, duree_heures, cout_unitaire, objectifs) VALUES (%s, %s, %s, %s, %s, %s) RETURNING *",
                       (body.code, body.titre, body.organisme, body.duree_heures, body.cout_unitaire, body.objectifs))


class SessionIn(BaseModel):
    formation_id: int
    date_debut: dt.date
    date_fin: dt.date
    lieu: str | None = None
    formateur: str | None = None
    capacite: int = Field(default=20, ge=1, le=500)
    cout_total: int | None = Field(default=None, ge=0)


SESSION_SQL = ("SELECT s.*, f.titre, f.duree_heures, (SELECT count(*) FROM participation_formation p WHERE p.session_id = s.id) AS inscrits "
               "FROM session_formation s JOIN formation f ON f.id = s.formation_id ")


@router.get("/sessions-formation")
def sessions(statut: str | None = None, user: User = Depends(require("grh:read"))):
    with tx() as cur:
        return all_rows(cur, SESSION_SQL + "WHERE (%s::text IS NULL OR s.statut = %s) ORDER BY s.date_debut DESC LIMIT 200", (statut, statut))


@router.post("/sessions-formation", status_code=201)
def creer_session(body: SessionIn, user: User = Depends(require("grh:write"))):
    with tx(user.login) as cur:
        r = one_row(cur, "INSERT INTO session_formation(formation_id, date_debut, date_fin, lieu, formateur, capacite, cout_total) VALUES (%s, %s, %s, %s, %s, %s, %s) RETURNING id",
                    (body.formation_id, body.date_debut, body.date_fin, body.lieu, body.formateur, body.capacite, body.cout_total))
        return one_row(cur, SESSION_SQL + "WHERE s.id = %s", (r["id"],))


@router.get("/sessions-formation/{session_id}/participants")
def participants(session_id: int, user: User = Depends(require("grh:read"))):
    with tx() as cur:
        return all_rows(cur, "SELECT p.*, e.matricule, e.nom, e.agence_id FROM participation_formation p JOIN employe e ON e.id = p.employe_id "
                             "WHERE p.session_id = %s AND (%s OR e.agence_id = ANY(%s)) ORDER BY e.nom", (session_id, user.siege, user.agences or []))


class InscriptionIn(BaseModel):
    employe_id: int


@router.post("/sessions-formation/{session_id}/inscrire", status_code=201)
def inscrire(session_id: int, body: InscriptionIn, user: User = Depends(require("grh:write"))):
    with tx(user.login) as cur:
        verifier_agence(cur, user, "employe", body.employe_id)
        return one_row(cur, "INSERT INTO participation_formation(session_id, employe_id) VALUES (%s, %s) RETURNING *", (session_id, body.employe_id))


class ParticipationIn(BaseModel):
    statut: Literal["present", "absent", "valide"]
    note: float | None = Field(default=None, ge=0, le=20)
    certificat_ref: str | None = Field(default=None, max_length=100)


@router.patch("/sessions-formation/{session_id}/participants/{employe_id}")
def maj_participation(session_id: int, employe_id: int, body: ParticipationIn, user: User = Depends(require("grh:write"))):
    with tx(user.login) as cur:
        verifier_agence(cur, user, "employe", employe_id)
        r = one_row(cur, "UPDATE participation_formation SET statut = %s, note = COALESCE(%s, note), certificat_ref = COALESCE(%s, certificat_ref) "
                         "WHERE session_id = %s AND employe_id = %s RETURNING *", (body.statut, body.note, body.certificat_ref, session_id, employe_id))
    if r is None:
        raise HTTPException(status_code=404, detail="Participation introuvable")
    return r


@router.post("/sessions-formation/{session_id}/cloturer")
def cloturer_session(session_id: int, user: User = Depends(require("grh:write"))):
    with tx(user.login) as cur:
        r = one_row(cur, "UPDATE session_formation SET statut = 'realisee' WHERE id = %s AND statut = 'planifiee' AND date_debut <= current_date RETURNING id", (session_id,))
        if r is None:
            raise HTTPException(status_code=422, detail="Session introuvable, déjà clôturée, ou pas encore commencée")
        return one_row(cur, SESSION_SQL + "WHERE s.id = %s", (session_id,))


# ---------------------------------------------------------------- évaluations
class CampagneIn(BaseModel):
    libelle: str = Field(min_length=3, max_length=200)
    periode_debut: dt.date
    periode_fin: dt.date


@router.get("/campagnes-evaluation")
def campagnes(user: User = Depends(require("grh:read"))):
    with tx() as cur:
        return all_rows(cur, "SELECT c.*, (SELECT count(*) FROM evaluation e WHERE e.campagne_id = c.id) AS nb, "
                             "(SELECT count(*) FROM evaluation e WHERE e.campagne_id = c.id AND e.statut = 'validee') AS validees FROM campagne_evaluation c ORDER BY c.id DESC")


@router.post("/campagnes-evaluation", status_code=201)
def creer_campagne(body: CampagneIn, user: User = Depends(require("evaluation:valider"))):
    with tx(user.login) as cur:
        return one_row(cur, "INSERT INTO campagne_evaluation(libelle, periode_debut, periode_fin) VALUES (%s, %s, %s) RETURNING *", (body.libelle, body.periode_debut, body.periode_fin))


@router.post("/campagnes-evaluation/{campagne_id}/ouvrir")
def ouvrir_campagne(campagne_id: int, agence_id: int | None = None, user: User = Depends(require("evaluation:valider"))):
    ag = agence_filter(user, agence_id)
    with tx(user.login) as cur:
        n = one_row(cur, "SELECT ouvrir_evaluations(%s, %s::smallint) AS n", (campagne_id, ag))["n"]
        sans = one_row(cur, "SELECT count(*) AS n FROM employe WHERE statut = 'actif' AND superieur_id IS NULL AND (%s::int IS NULL OR agence_id = %s)", (ag, ag))["n"]
        return {"evaluations_creees": n, "employes_sans_superieur": sans}


@router.post("/campagnes-evaluation/{campagne_id}/cloturer")
def cloturer_campagne(campagne_id: int, user: User = Depends(require("evaluation:valider"))):
    with tx(user.login) as cur:
        r = one_row(cur, "UPDATE campagne_evaluation SET statut = 'close' WHERE id = %s AND statut = 'ouverte' RETURNING *", (campagne_id,))
    if r is None:
        raise HTTPException(status_code=422, detail="Campagne introuvable ou déjà close")
    return r


EVAL_SQL = ("SELECT ev.*, e.matricule, e.nom, e.agence_id, ee.nom AS evaluateur FROM evaluation ev JOIN employe e ON e.id = ev.employe_id "
            "JOIN employe ee ON ee.id = ev.evaluateur_id ")


@router.get("/evaluations")
def evaluations(campagne_id: int | None = None, agence_id: int | None = None, user: User = Depends(require("grh:read"))):
    ag = agence_filter(user, agence_id)
    with tx() as cur:
        return all_rows(cur, EVAL_SQL + "WHERE (%s::int IS NULL OR ev.campagne_id = %s) AND (%s::int IS NULL OR e.agence_id = %s) ORDER BY e.nom LIMIT 500", (campagne_id, campagne_id, ag, ag))


@router.get("/evaluations/{evaluation_id}")
def detail_evaluation(evaluation_id: int, user: User = Depends(require("grh:read"))):
    with tx() as cur:
        _employe_de(cur, user, "evaluation", evaluation_id)
        ev = one_row(cur, EVAL_SQL + "WHERE ev.id = %s", (evaluation_id,))
        ev["objectifs"] = all_rows(cur, "SELECT * FROM objectif_evaluation WHERE evaluation_id = %s ORDER BY id", (evaluation_id,))
        ev["note_calculee"] = one_row(cur, "SELECT note_evaluation(%s) AS n", (evaluation_id,))["n"]
        return ev


class ObjectifIn(BaseModel):
    libelle: str = Field(min_length=2, max_length=300)
    poids: float = Field(gt=0, le=100)


@router.post("/evaluations/{evaluation_id}/objectifs", status_code=201)
def ajouter_objectif(evaluation_id: int, body: ObjectifIn, user: User = Depends(require("evaluation:ecrire"))):
    with tx(user.login) as cur:
        _evaluation_accessible(cur, user, evaluation_id)
        return one_row(cur, "INSERT INTO objectif_evaluation(evaluation_id, libelle, poids) VALUES (%s, %s, %s) RETURNING *", (evaluation_id, body.libelle, body.poids))


class NoteObjectifIn(BaseModel):
    note: float = Field(ge=0, le=10)
    resultat: str | None = Field(default=None, max_length=500)


@router.patch("/objectifs-evaluation/{objectif_id}")
def noter_objectif(objectif_id: int, body: NoteObjectifIn, user: User = Depends(require("evaluation:ecrire"))):
    with tx(user.login) as cur:
        r = one_row(cur, "SELECT evaluation_id FROM objectif_evaluation WHERE id = %s", (objectif_id,))
        if r is None:
            raise HTTPException(status_code=404, detail="Introuvable")
        _evaluation_accessible(cur, user, r["evaluation_id"])
        return one_row(cur, "UPDATE objectif_evaluation SET note = %s, resultat = %s WHERE id = %s RETURNING *", (body.note, body.resultat, objectif_id))


class ConclusionIn(BaseModel):
    points_forts: str | None = Field(default=None, max_length=1000)
    axes_progres: str | None = Field(default=None, max_length=1000)
    commentaire_employe: str | None = Field(default=None, max_length=1000)


@router.post("/evaluations/{evaluation_id}/evaluer")
def evaluer(evaluation_id: int, body: ConclusionIn, user: User = Depends(require("evaluation:ecrire"))):
    """L'évaluateur clôt sa notation : poids totalisant 100 et objectifs tous notés (contrôlé par la base)."""
    with tx(user.login) as cur:
        _evaluation_accessible(cur, user, evaluation_id)
        cur.execute("UPDATE evaluation SET statut = 'evalue', points_forts = %s, axes_progres = %s, commentaire_employe = %s WHERE id = %s",
                    (body.points_forts, body.axes_progres, body.commentaire_employe, evaluation_id))
        return one_row(cur, EVAL_SQL + "WHERE ev.id = %s", (evaluation_id,))


class ValidationIn(BaseModel):
    decision: Literal["maintien", "augmentation", "promotion", "formation", "alerte"]


@router.post("/evaluations/{evaluation_id}/valider")
def valider_evaluation(evaluation_id: int, body: ValidationIn, user: User = Depends(require("evaluation:valider"))):
    with tx(user.login) as cur:
        _employe_de(cur, user, "evaluation", evaluation_id)
        cur.execute("UPDATE evaluation SET statut = 'validee', decision = %s, validee_par = %s WHERE id = %s AND statut = 'evalue'", (body.decision, user.id, evaluation_id))
        if cur.rowcount == 0:
            raise HTTPException(status_code=422, detail="Seule une évaluation terminée par l'évaluateur se valide")
        return one_row(cur, EVAL_SQL + "WHERE ev.id = %s", (evaluation_id,))


# ---------------------------------------------------------------- sanctions
class SanctionIn(BaseModel):
    employe_id: int
    date_faits: dt.date
    type: Literal["avertissement_verbal", "avertissement_ecrit", "blame", "mise_a_pied"]
    motif: str = Field(min_length=10, max_length=1000)
    date_entretien_prealable: dt.date | None = None
    jours_mise_a_pied: int | None = Field(default=None, ge=1, le=30)
    explications_employe: str | None = Field(default=None, max_length=1000)


SANCTION_SQL = "SELECT s.*, e.matricule, e.nom, e.agence_id FROM sanction s JOIN employe e ON e.id = s.employe_id "


@router.get("/sanctions")
def sanctions(employe_id: int | None = None, agence_id: int | None = None, user: User = Depends(require("sanction:write"))):
    ag = agence_filter(user, agence_id)
    with tx() as cur:
        return all_rows(cur, SANCTION_SQL + "WHERE (%s::int IS NULL OR e.agence_id = %s) AND (%s::int IS NULL OR s.employe_id = %s) ORDER BY s.date_faits DESC LIMIT 300", (ag, ag, employe_id, employe_id))


@router.post("/sanctions", status_code=201)
def proposer_sanction(body: SanctionIn, user: User = Depends(require("sanction:write"))):
    with tx(user.login) as cur:
        verifier_agence(cur, user, "employe", body.employe_id)
        _pas_soi_meme(cur, user, body.employe_id)
        r = one_row(cur, "INSERT INTO sanction(employe_id, date_faits, type, motif, date_entretien_prealable, jours_mise_a_pied, explications_employe) VALUES (%s, %s, %s, %s, %s, %s, %s) RETURNING id",
                    (body.employe_id, body.date_faits, body.type, body.motif, body.date_entretien_prealable, body.jours_mise_a_pied, body.explications_employe))
        return one_row(cur, SANCTION_SQL + "WHERE s.id = %s", (r["id"],))


@router.post("/sanctions/{sanction_id}/notifier")
def notifier_sanction(sanction_id: int, user: User = Depends(require("sanction:write"))):
    with tx(user.login) as cur:
        _pas_soi_meme(cur, user, _employe_de(cur, user, "sanction", sanction_id))
        cur.execute("UPDATE sanction SET statut = 'notifiee', decide_par = %s WHERE id = %s AND statut = 'proposee'", (user.id, sanction_id))
        if cur.rowcount == 0:
            raise HTTPException(status_code=422, detail="Cette sanction n'est plus à notifier")
        return one_row(cur, SANCTION_SQL + "WHERE s.id = %s", (sanction_id,))


class AnnulationIn(BaseModel):
    motif: str = Field(min_length=5, max_length=500)


@router.post("/sanctions/{sanction_id}/annuler")
def annuler_sanction(sanction_id: int, body: AnnulationIn, user: User = Depends(require("sanction:write"))):
    with tx(user.login) as cur:
        _pas_soi_meme(cur, user, _employe_de(cur, user, "sanction", sanction_id))
        cur.execute("UPDATE sanction SET statut = 'annulee', motif_annulation = %s WHERE id = %s AND statut IN ('proposee','notifiee')", (body.motif, sanction_id))
        if cur.rowcount == 0:
            raise HTTPException(status_code=422, detail="Cette sanction ne peut plus être annulée")
        return one_row(cur, SANCTION_SQL + "WHERE s.id = %s", (sanction_id,))


# ---------------------------------------------------------------- sorties
class SortieIn(BaseModel):
    employe_id: int
    type: Literal["demission", "licenciement", "fin_cdd", "retraite", "deces", "rupture_conventionnelle"]
    date_notification: dt.date
    date_sortie: dt.date
    motif: str = Field(min_length=5, max_length=500)


SORTIE_SQL = "SELECT s.*, e.matricule, e.nom, e.agence_id FROM sortie_employe s JOIN employe e ON e.id = s.employe_id "


@router.get("/sorties")
def sorties(agence_id: int | None = None, user: User = Depends(require("sortie:write"))):
    ag = agence_filter(user, agence_id)
    with tx() as cur:
        return all_rows(cur, SORTIE_SQL + "WHERE (%s::int IS NULL OR e.agence_id = %s) ORDER BY s.id DESC LIMIT 200", (ag, ag))


@router.post("/sorties", status_code=201)
def preparer_sortie(body: SortieIn, user: User = Depends(require("sortie:write"))):
    with tx(user.login) as cur:
        verifier_agence(cur, user, "employe", body.employe_id)
        sid = one_row(cur, "SELECT preparer_sortie(%s, %s, %s, %s, %s, %s) AS id",
                      (body.employe_id, body.type, body.date_notification, body.date_sortie, body.motif, user.id))["id"]
        return one_row(cur, SORTIE_SQL + "WHERE s.id = %s", (sid,))


@router.post("/sorties/{sortie_id}/finaliser")
def finaliser_sortie(sortie_id: int, user: User = Depends(require("sortie:write"))):
    """Clôt le contrat, désactive le compte utilisateur et l'agent, solde les avances, annule les congés futurs."""
    with tx(user.login) as cur:
        _employe_de(cur, user, "sortie_employe", sortie_id)
        cur.execute("SELECT finaliser_sortie(%s, %s)", (sortie_id, user.id))
        return one_row(cur, SORTIE_SQL + "WHERE s.id = %s", (sortie_id,))


@router.get("/employes/{employe_id}/certificat-travail")
def certificat_travail(employe_id: int, user: User = Depends(require("grh:write"))):
    """Données du certificat de travail (employé sorti) ou de l'attestation de travail (employé en poste)."""
    with tx() as cur:
        ag = verifier_agence(cur, user, "employe", employe_id)
        e = one_row(cur, "SELECT e.matricule, e.nom, e.date_naissance, e.lieu_naissance, e.date_embauche, e.date_sortie, e.statut, COALESCE(p.libelle, e.poste) AS poste "
                         "FROM employe e LEFT JOIN poste p ON p.id = e.poste_id WHERE e.id = %s", (employe_id,))
        postes = all_rows(cur, "SELECT DISTINCT COALESCE(p.libelle, e.poste) AS poste FROM employe e LEFT JOIN poste p ON p.id = e.poste_id WHERE e.id = %s", (employe_id,))
        return {
            "employe": e, "postes": postes, "type": "certificat" if e["statut"] == "sorti" else "attestation", "date_edition": dt.date.today().isoformat(),
            "institution": one_row(cur, "SELECT raison_sociale, sigle, agrement, adresse, ville, telephone, logo, pied_de_page FROM institution WHERE id = 1"),
            "agence": one_row(cur, "SELECT code, libelle, ville FROM agence WHERE id = %s", (ag,)),
        }
