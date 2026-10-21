"""GRH — organisation, dossier du personnel, agents commerciaux, congés, présences, indicateurs (modules 39 et 40).
Les règles (séparation des tâches, soldes, chevauchements, hiérarchie) sont dans le schéma."""
import datetime as dt
from typing import Literal

from fastapi import APIRouter, Depends, HTTPException
from pydantic import BaseModel, Field

from ..auth import User, agence_filter, require, verifier_agence
from ..db import all_rows, one_row, tx

router = APIRouter(prefix="/api/grh", tags=["grh"])


# ---------------------------------------------------------------- services et postes
class ServiceIn(BaseModel):
    code: str = Field(min_length=1, max_length=15)
    libelle: str = Field(min_length=1)
    parent_id: int | None = None


@router.get("/services")
def services(user: User = Depends(require("grh:read"))):
    with tx() as cur:
        return all_rows(cur, "SELECT s.*, p.libelle AS parent, (SELECT count(*) FROM employe e WHERE e.service_id = s.id AND e.statut = 'actif') AS effectif "
                             "FROM service_rh s LEFT JOIN service_rh p ON p.id = s.parent_id ORDER BY s.code")


@router.post("/services", status_code=201)
def creer_service(body: ServiceIn, user: User = Depends(require("grh:write"))):
    with tx(user.login) as cur:
        return one_row(cur, "INSERT INTO service_rh(code, libelle, parent_id) VALUES (%s, %s, %s) RETURNING *", (body.code, body.libelle, body.parent_id))


class PosteIn(BaseModel):
    code: str = Field(min_length=1, max_length=15)
    libelle: str = Field(min_length=1)
    service_id: int | None = None
    description: str | None = None
    competences: str | None = None
    salaire_min: int | None = Field(default=None, ge=0)
    salaire_max: int | None = Field(default=None, ge=0)
    effectif_prevu: int = Field(default=1, ge=0, le=500)


@router.get("/postes")
def postes(user: User = Depends(require("grh:read"))):
    with tx() as cur:
        return all_rows(cur, "SELECT p.*, s.libelle AS service, (SELECT count(*) FROM employe e WHERE e.poste_id = p.id AND e.statut = 'actif') AS effectif "
                             "FROM poste p LEFT JOIN service_rh s ON s.id = p.service_id ORDER BY p.code")


@router.post("/postes", status_code=201)
def creer_poste(body: PosteIn, user: User = Depends(require("grh:write"))):
    with tx(user.login) as cur:
        return one_row(cur, "INSERT INTO poste(code, libelle, service_id, description, competences, salaire_min, salaire_max, effectif_prevu) "
                            "VALUES (%s, %s, %s, %s, %s, %s, %s, %s) RETURNING *",
                       (body.code, body.libelle, body.service_id, body.description, body.competences, body.salaire_min, body.salaire_max, body.effectif_prevu))


@router.get("/organigramme")
def organigramme(agence_id: int | None = None, user: User = Depends(require("grh:read"))):
    ag = agence_filter(user, agence_id)
    with tx() as cur:
        return all_rows(cur, "SELECT * FROM v_organigramme WHERE (%s::int IS NULL OR agence_id = %s) ORDER BY chemin", (ag, ag))


# ---------------------------------------------------------------- dossier du personnel
class DossierPatch(BaseModel):
    poste_id: int | None = None
    service_id: int | None = None
    superieur_id: int | None = None
    sexe: Literal["F", "M"] | None = None
    date_naissance: dt.date | None = None
    lieu_naissance: str | None = None
    situation_familiale: Literal["celibataire", "marie", "divorce", "veuf"] | None = None
    nb_enfants: int | None = Field(default=None, ge=0, le=30)
    telephone: str | None = Field(default=None, max_length=30)
    email: str | None = Field(default=None, max_length=200)
    adresse: str | None = None
    urgence_nom: str | None = None
    urgence_telephone: str | None = Field(default=None, max_length=30)
    piece_identite: str | None = None
    numero_cnss: str | None = Field(default=None, max_length=30)
    banque: str | None = None
    numero_compte: str | None = Field(default=None, max_length=40)
    poste: str | None = None


@router.get("/employes/{employe_id}")
def dossier(employe_id: int, user: User = Depends(require("grh:read"))):
    with tx() as cur:
        verifier_agence(cur, user, "employe", employe_id)
        e = one_row(cur, "SELECT e.*, p.libelle AS poste_libelle, s.libelle AS service, sup.nom AS superieur FROM employe e "
                         "LEFT JOIN poste p ON p.id = e.poste_id LEFT JOIN service_rh s ON s.id = e.service_id LEFT JOIN employe sup ON sup.id = e.superieur_id WHERE e.id = %s", (employe_id,))
        e["contrats"] = all_rows(cur, "SELECT * FROM contrat WHERE employe_id = %s ORDER BY date_debut DESC", (employe_id,))
        e["documents"] = all_rows(cur, "SELECT * FROM document_employe WHERE employe_id = %s ORDER BY id DESC", (employe_id,))
        e["conges"] = all_rows(cur, "SELECT * FROM conge WHERE employe_id = %s ORDER BY date_debut DESC LIMIT 30", (employe_id,))
        e["solde_conges"] = one_row(cur, "SELECT conge_acquis(%s) AS acquis, solde_conge(%s) AS solde", (employe_id, employe_id))
        e["sanctions"] = all_rows(cur, "SELECT * FROM sanction WHERE employe_id = %s ORDER BY date_faits DESC", (employe_id,))
        e["formations"] = all_rows(cur, "SELECT f.titre, s.date_debut, s.date_fin, p.statut, p.note, p.certificat_ref FROM participation_formation p "
                                        "JOIN session_formation s ON s.id = p.session_id JOIN formation f ON f.id = s.formation_id WHERE p.employe_id = %s ORDER BY s.date_debut DESC", (employe_id,))
        e["evaluations"] = all_rows(cur, "SELECT ev.id, c.libelle AS campagne, ev.statut, ev.note_globale, ev.decision FROM evaluation ev JOIN campagne_evaluation c ON c.id = ev.campagne_id "
                                         "WHERE ev.employe_id = %s ORDER BY ev.id DESC", (employe_id,))
        e["sortie"] = one_row(cur, "SELECT * FROM sortie_employe WHERE employe_id = %s", (employe_id,))
        return e


@router.patch("/employes/{employe_id}")
def modifier_dossier(employe_id: int, body: DossierPatch, user: User = Depends(require("grh:write"))):
    champs = body.model_dump(exclude_unset=True)
    if not champs:
        raise HTTPException(status_code=422, detail="Aucune modification")
    with tx(user.login) as cur:
        verifier_agence(cur, user, "employe", employe_id)
        sets = ", ".join(f"{c} = %s" for c in champs)
        return one_row(cur, f"UPDATE employe SET {sets} WHERE id = %s RETURNING *", (*champs.values(), employe_id))


class DocumentIn(BaseModel):
    type: Literal["identite", "diplome", "contrat", "cnss", "certificat_medical", "casier_judiciaire", "attestation", "photo", "autre"]
    libelle: str = Field(min_length=1, max_length=200)
    reference: str | None = None
    date_emission: dt.date | None = None
    date_expiration: dt.date | None = None
    note: str | None = None


@router.post("/employes/{employe_id}/documents", status_code=201)
def ajouter_document(employe_id: int, body: DocumentIn, user: User = Depends(require("grh:write"))):
    with tx(user.login) as cur:
        verifier_agence(cur, user, "employe", employe_id)
        return one_row(cur, "INSERT INTO document_employe(employe_id, type, libelle, reference, date_emission, date_expiration, note) VALUES (%s, %s, %s, %s, %s, %s, %s) RETURNING *",
                       (employe_id, body.type, body.libelle, body.reference, body.date_emission, body.date_expiration, body.note))


@router.get("/echeances")
def echeances(agence_id: int | None = None, user: User = Depends(require("grh:read"))):
    """Fins de contrat, fins de période d'essai, pièces du dossier qui expirent."""
    ag = agence_filter(user, agence_id)
    with tx() as cur:
        return all_rows(cur, "SELECT * FROM v_grh_echeances WHERE (%s::int IS NULL OR agence_id = %s) ORDER BY echeance", (ag, ag))


# ---------------------------------------------------------------- agents commerciaux
@router.get("/agents")
def agents_commerciaux(agence_id: int | None = None, user: User = Depends(require("grh:read"))):
    """Agents commerciaux avec leur situation RH (fiche, salaire), leurs zones, clients et collecte du mois."""
    ag = agence_filter(user, agence_id)
    with tx() as cur:
        return all_rows(cur, "SELECT v.*, p.libelle AS poste FROM v_agent_rh v LEFT JOIN employe e ON e.id = v.employe_id LEFT JOIN poste p ON p.id = e.poste_id "
                             "WHERE (%s::int IS NULL OR v.agence_id = %s) ORDER BY v.agence_id, v.matricule", (ag, ag))


class FicheAgentIn(BaseModel):
    date_embauche: dt.date | None = None
    poste_id: int | None = None


@router.post("/agents/{agent_id}/fiche-rh", status_code=201)
def fiche_rh_agent(agent_id: int, body: FicheAgentIn, user: User = Depends(require("grh:write"))):
    with tx(user.login) as cur:
        verifier_agence(cur, user, "agent", agent_id)
        eid = one_row(cur, "SELECT creer_employe_depuis_agent(%s, COALESCE(%s, current_date), %s) AS id", (agent_id, body.date_embauche, body.poste_id))["id"]
        return one_row(cur, "SELECT * FROM employe WHERE id = %s", (eid,))


# ---------------------------------------------------------------- congés
class CongeIn(BaseModel):
    employe_id: int
    type: Literal["annuel", "maladie", "maternite", "paternite", "permission", "deuil", "formation", "sans_solde", "autre"]
    date_debut: dt.date
    date_fin: dt.date
    motif: str | None = Field(default=None, max_length=500)
    remplacant_id: int | None = None


CONGE_SQL = ("SELECT c.*, e.matricule, e.nom, e.agence_id, u.nom AS decide_par_nom FROM conge c JOIN employe e ON e.id = c.employe_id "
             "LEFT JOIN utilisateur u ON u.id = c.decide_par ")


@router.get("/conges")
def conges(statut: str | None = None, employe_id: int | None = None, agence_id: int | None = None, user: User = Depends(require("grh:read"))):
    ag = agence_filter(user, agence_id)
    with tx() as cur:
        return all_rows(cur, CONGE_SQL + "WHERE (%s::int IS NULL OR e.agence_id = %s) AND (%s::text IS NULL OR c.statut = %s) AND (%s::int IS NULL OR c.employe_id = %s) "
                                         "ORDER BY c.date_debut DESC LIMIT 300", (ag, ag, statut, statut, employe_id, employe_id))


@router.post("/conges", status_code=201)
def demander_conge(body: CongeIn, user: User = Depends(require("grh:write"))):
    with tx(user.login) as cur:
        verifier_agence(cur, user, "employe", body.employe_id)
        r = one_row(cur, "INSERT INTO conge(employe_id, type, date_debut, date_fin, motif, remplacant_id) VALUES (%s, %s, %s, %s, %s, %s) RETURNING id",
                    (body.employe_id, body.type, body.date_debut, body.date_fin, body.motif, body.remplacant_id))
        return one_row(cur, CONGE_SQL + "WHERE c.id = %s", (r["id"],))


class DecisionIn(BaseModel):
    approuve: bool
    commentaire: str | None = Field(default=None, max_length=500)


@router.post("/conges/{conge_id}/decider")
def decider_conge(conge_id: int, body: DecisionIn, user: User = Depends(require("conge:decider"))):
    with tx(user.login) as cur:
        c = one_row(cur, "SELECT employe_id, statut FROM conge WHERE id = %s", (conge_id,))
        if c is None:
            raise HTTPException(status_code=404, detail="Introuvable")
        verifier_agence(cur, user, "employe", c["employe_id"])
        if c["statut"] != "demande":
            raise HTTPException(status_code=422, detail=f"Cette demande est déjà {c['statut']}")
        cur.execute("UPDATE conge SET statut = %s, decide_par = %s, commentaire_decision = %s WHERE id = %s",
                    ("approuve" if body.approuve else "refuse", user.id, body.commentaire, conge_id))
        return one_row(cur, CONGE_SQL + "WHERE c.id = %s", (conge_id,))


@router.post("/conges/{conge_id}/annuler")
def annuler_conge(conge_id: int, user: User = Depends(require("grh:write"))):
    with tx(user.login) as cur:
        c = one_row(cur, "SELECT employe_id FROM conge WHERE id = %s", (conge_id,))
        if c is None:
            raise HTTPException(status_code=404, detail="Introuvable")
        verifier_agence(cur, user, "employe", c["employe_id"])
        cur.execute("UPDATE conge SET statut = 'annule' WHERE id = %s AND statut IN ('demande','approuve')", (conge_id,))
        if cur.rowcount == 0:
            raise HTTPException(status_code=422, detail="Ce congé ne peut plus être annulé")
        return one_row(cur, CONGE_SQL + "WHERE c.id = %s", (conge_id,))


@router.get("/employes/{employe_id}/solde-conges")
def solde_conges(employe_id: int, user: User = Depends(require("grh:read"))):
    with tx() as cur:
        verifier_agence(cur, user, "employe", employe_id)
        return one_row(cur, "SELECT conge_acquis(%s) AS acquis, solde_conge(%s) AS solde", (employe_id, employe_id))


# libre-service : l'employé relié à son compte utilisateur voit et demande ses propres congés
class MonCongeIn(BaseModel):
    type: Literal["annuel", "maladie", "permission", "deuil", "sans_solde", "autre"]
    date_debut: dt.date
    date_fin: dt.date
    motif: str | None = Field(default=None, max_length=500)


def _mon_employe(cur, user: User) -> int:
    e = one_row(cur, "SELECT id FROM employe WHERE utilisateur_id = %s AND statut = 'actif'", (user.id,))
    if e is None:
        raise HTTPException(status_code=404, detail="Aucune fiche d'employé n'est reliée à votre compte")
    return e["id"]


@router.get("/mes-conges")
def mes_conges(user: User = Depends(require("grh:self"))):
    with tx() as cur:
        eid = _mon_employe(cur, user)
        return {"employe_id": eid, "solde": one_row(cur, "SELECT conge_acquis(%s) AS acquis, solde_conge(%s) AS solde", (eid, eid)),
                "conges": all_rows(cur, CONGE_SQL + "WHERE c.employe_id = %s ORDER BY c.date_debut DESC LIMIT 50", (eid,))}


@router.post("/mes-conges", status_code=201)
def demander_mon_conge(body: MonCongeIn, user: User = Depends(require("grh:self"))):
    with tx(user.login) as cur:
        eid = _mon_employe(cur, user)
        r = one_row(cur, "INSERT INTO conge(employe_id, type, date_debut, date_fin, motif) VALUES (%s, %s, %s, %s, %s) RETURNING id",
                    (eid, body.type, body.date_debut, body.date_fin, body.motif))
        return one_row(cur, CONGE_SQL + "WHERE c.id = %s", (r["id"],))


# ---------------------------------------------------------------- jours fériés, présences
class FerieIn(BaseModel):
    date_jour: dt.date
    libelle: str = Field(min_length=2, max_length=200)
    agence_id: int | None = None


@router.get("/jours-feries")
def jours_feries(annee: int | None = None, user: User = Depends(require("grh:read"))):
    with tx() as cur:
        return all_rows(cur, "SELECT * FROM jour_ferie WHERE (%s::int IS NULL OR extract(year FROM date_jour) = %s) ORDER BY date_jour", (annee, annee))


def _droit_ferie(user: User, agence_id: int | None) -> None:
    """Un jour férié commun à toutes les agences est réservé au siège ; sinon l'agence doit être dans le périmètre."""
    if agence_id is None:
        if not user.siege:
            raise HTTPException(status_code=403, detail="Un jour férié commun relève du siège")
    elif not user.peut_agence(agence_id):
        raise HTTPException(status_code=403, detail="Agence non autorisée")


@router.post("/jours-feries", status_code=201)
def ajouter_ferie(body: FerieIn, user: User = Depends(require("grh:write"))):
    _droit_ferie(user, body.agence_id)
    with tx(user.login) as cur:
        return one_row(cur, "INSERT INTO jour_ferie(date_jour, libelle, agence_id) VALUES (%s, %s, %s) RETURNING *", (body.date_jour, body.libelle, body.agence_id))


@router.delete("/jours-feries/{ferie_id}", status_code=204)
def supprimer_ferie(ferie_id: int, user: User = Depends(require("grh:write"))):
    with tx(user.login) as cur:
        r = one_row(cur, "SELECT agence_id FROM jour_ferie WHERE id = %s", (ferie_id,))
        if r is None:
            raise HTTPException(status_code=404, detail="Introuvable")
        _droit_ferie(user, r["agence_id"])
        cur.execute("DELETE FROM jour_ferie WHERE id = %s", (ferie_id,))


class PresenceIn(BaseModel):
    employe_id: int
    date_jour: dt.date
    statut: Literal["present", "absent", "retard", "conge", "mission", "absent_justifie", "ferie"]
    heure_arrivee: dt.time | None = None
    heure_depart: dt.time | None = None
    motif: str | None = Field(default=None, max_length=300)


@router.post("/presences", status_code=201)
def pointer(body: PresenceIn, user: User = Depends(require("conge:decider"))):
    with tx(user.login) as cur:
        verifier_agence(cur, user, "employe", body.employe_id)
        pid = one_row(cur, "SELECT enregistrer_presence(%s, %s, %s, %s, %s, %s) AS id",
                      (body.employe_id, body.date_jour, body.statut, body.heure_arrivee, body.heure_depart, body.motif))["id"]
        return one_row(cur, "SELECT * FROM presence WHERE id = %s", (pid,))


@router.get("/presences")
def presences_du_jour(date: dt.date, agence_id: int | None = None, user: User = Depends(require("grh:read"))):
    """Tous les employés actifs avec leur pointage du jour (statut vide = non pointé)."""
    ag = agence_filter(user, agence_id)
    with tx() as cur:
        return all_rows(cur, "SELECT e.id AS employe_id, e.matricule, e.nom, p.statut, p.heure_arrivee, p.heure_depart, p.heures, p.motif "
                             "FROM employe e LEFT JOIN presence p ON p.employe_id = e.id AND p.date_jour = %s "
                             "WHERE e.statut = 'actif' AND (%s::int IS NULL OR e.agence_id = %s) ORDER BY e.matricule", (date, ag, ag))


@router.get("/absenteisme")
def absenteisme(mois: dt.date, agence_id: int | None = None, user: User = Depends(require("grh:read"))):
    ag = agence_filter(user, agence_id)
    with tx() as cur:
        return all_rows(cur, "SELECT * FROM v_absenteisme WHERE mois = date_trunc('month', %s::date)::date AND (%s::int IS NULL OR agence_id = %s) ORDER BY matricule", (mois, ag, ag))


# ---------------------------------------------------------------- indicateurs
@router.get("/indicateurs")
def indicateurs(agence_id: int | None = None, user: User = Depends(require("grh:read"))):
    ag = agence_filter(user, agence_id)
    with tx() as cur:
        lignes = all_rows(cur, "SELECT * FROM v_grh_indicateurs WHERE (%s::int IS NULL OR agence_id = %s) ORDER BY agence", (ag, ag))
        total = {k: sum(float(l[k]) for l in lignes) for k in ("effectif", "femmes", "hommes", "masse_salariale", "entrees_12m", "sorties_12m", "en_conge_aujourdhui", "absences_du_mois", "besoins_ouverts")}
        total["turnover_pct"] = round(total["sorties_12m"] / total["effectif"] * 100, 1) if total["effectif"] else 0.0
        repartition = all_rows(cur, "SELECT c.type::text AS type, count(*) AS n FROM contrat c JOIN employe e ON e.id = c.employe_id WHERE e.statut = 'actif' "
                                    "AND c.date_debut <= current_date AND (c.date_fin IS NULL OR c.date_fin >= current_date) AND (%s::int IS NULL OR e.agence_id = %s) GROUP BY c.type ORDER BY c.type", (ag, ag))
        return {"agences": lignes, "total": total, "contrats": repartition}
