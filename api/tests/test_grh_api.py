import datetime as dt

import pytest

# Module sous test : routers/grh.py et routers/grh_cycle.py (organisation, agents, congés, recrutement, formation, évaluations,
# sanctions, sorties, indicateurs)


@pytest.fixture(scope="module")
def base(client, h, sql, agences, utilisateurs):
    a1 = agences["a1"]
    ag = client.post("/api/agents", json={"matricule": "GRH-A1", "nom": "Agent GRH"}, headers=h("chef1")).json()
    z = client.post("/api/zones", json={"code": "ZG", "libelle": "Zone GRH", "agent_id": ag["id"]}, headers=h("chef1")).json()
    client.post("/api/clients", json={"nom": "Client GRH", "zone_id": z["id"]}, headers=h("chef1"))
    emp = {}
    for cle, mat, nom, uid in (("chef", "G-E1", "Chef de service", utilisateurs["chef1"]), ("emp", "G-E2", "Employé caissier", utilisateurs["caissier1"]), ("autre", "G-E3", "Autre employé", None)):
        emp[cle] = sql("INSERT INTO employe(agence_id,matricule,nom,date_embauche,utilisateur_id) VALUES (%s,%s,%s,'2024-01-01',%s) RETURNING id", (a1, mat, nom, uid))[0]["id"]
    sql("UPDATE employe SET superieur_id = %s WHERE id IN (%s, %s)", (emp["chef"], emp["emp"], emp["autre"]))
    sql("INSERT INTO contrat(employe_id,type,date_debut,salaire_base) VALUES (%s,'cdi','2024-01-01',200000)", (emp["emp"],))
    yield {"agent": ag, "emp": emp, "u": utilisateurs, "a1": a1}
    # ne pas laisser de personnel actif avec contrat : les tests de paie comptent les bulletins de l'agence
    sql("UPDATE employe SET statut = 'sorti', date_sortie = current_date WHERE matricule LIKE 'G-%%' OR matricule = 'GRH-A1'")


def test_droits_et_cloisonnement(client, h, base):
    assert client.get("/api/grh/agents", headers=h("caissier1")).status_code == 403
    assert client.get("/api/grh/agents", headers=h("rh1")).status_code == 200
    assert client.get(f"/api/grh/employes/{base['emp']['emp']}", headers=h("chef2")).status_code == 404
    assert client.get(f"/api/grh/employes/{base['emp']['emp']}", headers=h("rh1")).status_code == 200
    assert client.post("/api/grh/postes", json={"code": "X", "libelle": "X"}, headers=h("chef1")).status_code == 403                  # chef : lecture seule


def test_agents_commerciaux_dans_la_rh(client, h, base):
    lignes = client.get("/api/grh/agents", headers=h("rh1")).json()
    a = next(x for x in lignes if x["matricule"] == "GRH-A1")
    assert a["employe_id"] is None and a["nb_zones"] == 1 and a["nb_clients"] == 1
    r = client.post(f"/api/grh/agents/{base['agent']['id']}/fiche-rh", json={"date_embauche": "2025-01-01"}, headers=h("rh1"))
    assert r.status_code == 201 and r.json()["matricule"] == "GRH-A1" and r.json()["agent_id"] == base["agent"]["id"]
    assert client.post(f"/api/grh/agents/{base['agent']['id']}/fiche-rh", json={}, headers=h("rh1")).status_code == 422                # déjà créée
    a = next(x for x in client.get("/api/grh/agents", headers=h("rh1")).json() if x["matricule"] == "GRH-A1")
    assert a["employe_id"] and a["poste"] == "Agent commercial"
    assert all(x["matricule"] != "GRH-A1" for x in client.get("/api/grh/agents", headers=h("chef2")).json())


def test_organisation_et_dossier(client, h, base):
    s = client.post("/api/grh/services", json={"code": "OPS", "libelle": "Opérations"}, headers=h("rh1"))
    assert s.status_code == 201
    p = client.post("/api/grh/postes", json={"code": "CAIS", "libelle": "Caissier", "service_id": s.json()["id"], "salaire_min": 100000, "salaire_max": 250000}, headers=h("rh1"))
    assert p.status_code == 201
    e = base["emp"]["emp"]
    m = client.patch(f"/api/grh/employes/{e}", json={"poste_id": p.json()["id"], "sexe": "F", "telephone": "90112233", "nb_enfants": 2}, headers=h("rh1"))
    assert m.status_code == 200 and m.json()["sexe"] == "F"
    assert client.patch(f"/api/grh/employes/{base['emp']['chef']}", json={"superieur_id": e}, headers=h("rh1")).status_code == 422        # cycle hiérarchique
    d = client.post(f"/api/grh/employes/{e}/documents", json={"type": "identite", "libelle": "CNI", "date_expiration": str(dt.date.today() + dt.timedelta(days=20))}, headers=h("rh1"))
    assert d.status_code == 201
    dossier = client.get(f"/api/grh/employes/{e}", headers=h("rh1")).json()
    assert dossier["poste_libelle"] == "Caissier" and dossier["superieur"] == "Chef de service" and len(dossier["documents"]) == 1 and dossier["solde_conges"]["acquis"] > 0
    assert any(x["nature"] == "piece_expire" for x in client.get("/api/grh/echeances", headers=h("rh1")).json())
    org = client.get("/api/grh/organigramme", headers=h("rh1")).json()
    assert {o["matricule"]: o["niveau"] for o in org if o["matricule"].startswith("G-E")}["G-E1"] == 0


def test_conges_decision_et_libre_service(client, h, base):
    e = base["emp"]["emp"]
    r = client.post("/api/grh/conges", json={"employe_id": e, "type": "annuel", "date_debut": "2027-03-01", "date_fin": "2027-03-05"}, headers=h("rh1"))
    assert r.status_code == 201 and float(r.json()["jours_ouvres"]) == 5
    cid = r.json()["id"]
    assert client.post("/api/grh/conges", json={"employe_id": e, "type": "maladie", "date_debut": "2027-03-04", "date_fin": "2027-03-08"}, headers=h("rh1")).status_code == 422   # chevauchement
    assert client.post(f"/api/grh/conges/{cid}/decider", json={"approuve": True}, headers=h("caissier1")).status_code == 403
    assert client.post(f"/api/grh/conges/{cid}/decider", json={"approuve": False}, headers=h("rh1")).status_code == 422                  # refus non motivé
    ok = client.post(f"/api/grh/conges/{cid}/decider", json={"approuve": True}, headers=h("chef1"))
    assert ok.status_code == 200 and ok.json()["statut"] == "approuve" and ok.json()["decide_par_nom"]
    assert client.post(f"/api/grh/conges/{cid}/decider", json={"approuve": True}, headers=h("chef1")).status_code == 422                  # déjà décidé
    mes = client.get("/api/grh/mes-conges", headers=h("caissier1")).json()
    assert mes["employe_id"] == e and len(mes["conges"]) == 1
    mien = client.post("/api/grh/mes-conges", json={"type": "permission", "date_debut": "2027-04-01", "date_fin": "2027-04-01", "motif": "Démarche"}, headers=h("caissier1"))
    assert mien.status_code == 201 and mien.json()["statut"] == "demande"
    assert client.get("/api/grh/mes-conges", headers=h("agent1")).status_code == 404                                                    # pas de fiche reliée
    assert client.post(f"/api/grh/conges/{cid}/annuler", headers=h("rh1")).json()["statut"] == "annule"
    assert client.post("/api/grh/jours-feries", json={"date_jour": "2027-05-01", "libelle": "Fête du travail"}, headers=h("rh1")).status_code == 201
    p = client.post("/api/grh/presences", json={"employe_id": e, "date_jour": "2026-02-02", "statut": "retard", "heure_arrivee": "09:15:00", "heure_depart": "17:00:00"}, headers=h("rh1"))
    assert p.status_code == 201 and float(p.json()["heures"]) == 7.8
    assert client.get("/api/grh/absenteisme", params={"mois": "2026-02-10"}, headers=h("rh1")).json()[0]["retards"] == 1


def test_recrutement_jusqu_a_l_embauche(client, h, base):
    poste = next(x for x in client.get("/api/grh/postes", headers=h("rh1")).json() if x["code"] == "CAIS")
    b = client.post("/api/grh/besoins", json={"poste_id": poste["id"], "motif": "Départ en retraite", "nb_postes": 1}, headers=h("rh1"))
    assert b.status_code == 201, b.text
    bid = b.json()["id"]
    c = client.post("/api/grh/candidats", json={"nom": "Candidate Test", "telephone": "90909090", "source": "annonce"}, headers=h("rh1")).json()
    assert client.post(f"/api/grh/besoins/{bid}/candidatures", json={"candidat_id": c["id"]}, headers=h("rh1")).status_code == 422          # besoin non approuvé
    assert client.post(f"/api/grh/besoins/{bid}/decider", json={"approuve": True}, headers=h("rh1")).status_code == 403                    # RH ne décide pas
    assert client.post(f"/api/grh/besoins/{bid}/decider", json={"approuve": True}, headers=h("directeur")).json()["statut"] == "approuve"
    ca = client.post(f"/api/grh/besoins/{bid}/candidatures", json={"candidat_id": c["id"]}, headers=h("rh1"))
    assert ca.status_code == 201, ca.text
    cid = ca.json()["id"]
    assert client.post(f"/api/grh/candidatures/{cid}/statut", json={"statut": "retenue"}, headers=h("rh1")).status_code == 422             # pas d'entretien
    assert client.post(f"/api/grh/candidatures/{cid}/entretiens", json={"date_entretien": str(dt.date.today()), "note": 8.5, "decision": "favorable"}, headers=h("rh1")).status_code == 201
    assert client.post(f"/api/grh/candidatures/{cid}/statut", json={"statut": "retenue"}, headers=h("rh1")).json()["statut"] == "retenue"
    corps = {"matricule": "G-NEW1", "date_embauche": "2027-01-04", "salaire_base": 300000}
    assert client.post(f"/api/grh/candidatures/{cid}/embaucher", json=corps, headers=h("rh1")).status_code == 422                          # hors fourchette
    e = client.post(f"/api/grh/candidatures/{cid}/embaucher", json={**corps, "salaire_base": 180000}, headers=h("rh1"))
    assert e.status_code == 201 and e.json()["matricule"] == "G-NEW1"
    assert next(x for x in client.get("/api/grh/besoins", headers=h("rh1")).json() if x["besoin_id"] == bid)["statut"] == "pourvu"
    assert client.get(f"/api/grh/besoins/{bid}/candidatures", headers=h("chef2")).status_code == 404


def test_formation(client, h, base):
    f = client.post("/api/grh/formations", json={"code": "LBC", "titre": "Lutte contre le blanchiment", "duree_heures": 8, "cout_unitaire": 25000}, headers=h("rh1")).json()
    hier = dt.date.today() - dt.timedelta(days=1)
    s = client.post("/api/grh/sessions-formation", json={"formation_id": f["id"], "date_debut": str(hier), "date_fin": str(hier), "capacite": 1}, headers=h("rh1")).json()
    e = base["emp"]["emp"]
    assert client.post(f"/api/grh/sessions-formation/{s['id']}/inscrire", json={"employe_id": e}, headers=h("rh1")).status_code == 201
    assert client.post(f"/api/grh/sessions-formation/{s['id']}/inscrire", json={"employe_id": base["emp"]["autre"]}, headers=h("rh1")).status_code == 422   # complet
    p = f"/api/grh/sessions-formation/{s['id']}/participants/{e}"
    assert client.patch(p, json={"statut": "valide", "certificat_ref": "C1"}, headers=h("rh1")).status_code == 422                        # présence d'abord
    assert client.patch(p, json={"statut": "present"}, headers=h("rh1")).status_code == 200
    assert client.patch(p, json={"statut": "valide", "note": 15, "certificat_ref": "CERT-1"}, headers=h("rh1")).json()["statut"] == "valide"
    assert client.post(f"/api/grh/sessions-formation/{s['id']}/cloturer", headers=h("rh1")).json()["statut"] == "realisee"
    assert client.get(f"/api/grh/sessions-formation/{s['id']}/participants", headers=h("chef2")).json() == []


def test_evaluation(client, h, base):
    c = client.post("/api/grh/campagnes-evaluation", json={"libelle": "Évaluation 2026", "periode_debut": "2026-01-01", "periode_fin": "2026-12-31"}, headers=h("rh1"))
    assert c.status_code == 201, c.text
    cid = c.json()["id"]
    o = client.post(f"/api/grh/campagnes-evaluation/{cid}/ouvrir", headers=h("rh1")).json()
    assert o["evaluations_creees"] >= 2
    ev = next(x for x in client.get("/api/grh/evaluations", params={"campagne_id": cid}, headers=h("rh1")).json() if x["matricule"] == "G-E2")
    eid = ev["id"]
    for lib, poids in (("Collecte", 70), ("Ponctualité", 30)):
        assert client.post(f"/api/grh/evaluations/{eid}/objectifs", json={"libelle": lib, "poids": poids}, headers=h("chef1")).status_code == 201
    assert client.post(f"/api/grh/evaluations/{eid}/evaluer", json={}, headers=h("chef1")).status_code == 422                              # objectifs non notés
    for ob, note in zip(client.get(f"/api/grh/evaluations/{eid}", headers=h("chef1")).json()["objectifs"], (9, 6)):
        assert client.patch(f"/api/grh/objectifs-evaluation/{ob['id']}", json={"note": note}, headers=h("chef1")).status_code == 200
    r = client.post(f"/api/grh/evaluations/{eid}/evaluer", json={"points_forts": "Rigueur"}, headers=h("chef1"))
    assert r.status_code == 200 and float(r.json()["note_globale"]) == 8.1
    assert client.post(f"/api/grh/evaluations/{eid}/valider", json={"decision": "maintien"}, headers=h("chef1")).status_code == 403          # chef : pas de validation
    v = client.post(f"/api/grh/evaluations/{eid}/valider", json={"decision": "augmentation"}, headers=h("rh1"))
    assert v.status_code == 200 and v.json()["statut"] == "validee"
    assert client.post(f"/api/grh/evaluations/{eid}/objectifs", json={"libelle": "Tardif", "poids": 5}, headers=h("chef1")).status_code == 422   # figée
    assert client.post(f"/api/grh/campagnes-evaluation/{cid}/cloturer", headers=h("rh1")).json()["statut"] == "close"


def test_sanction_et_sortie(client, h, base):
    e = base["emp"]["autre"]
    corps = {"employe_id": e, "date_faits": str(dt.date.today() - dt.timedelta(days=3)), "type": "avertissement_ecrit", "motif": "Retards répétés sur le mois"}
    s = client.post("/api/grh/sanctions", json=corps, headers=h("chef1"))
    assert s.status_code == 201, s.text
    sid = s.json()["id"]
    assert client.post(f"/api/grh/sanctions/{sid}/notifier", headers=h("chef1")).status_code == 422                                          # entretien préalable manquant
    assert client.post("/api/grh/sanctions", json={**corps, "type": "mise_a_pied"}, headers=h("chef1")).status_code == 422                    # durée manquante
    assert client.get("/api/grh/sanctions", headers=h("caissier1")).status_code == 403
    s2 = client.post("/api/grh/sanctions", json={**corps, "date_entretien_prealable": str(dt.date.today() - dt.timedelta(days=1))}, headers=h("chef1")).json()
    assert client.post(f"/api/grh/sanctions/{s2['id']}/notifier", headers=h("chef1")).json()["statut"] == "notifiee"
    assert client.post(f"/api/grh/sanctions/{s2['id']}/annuler", json={"motif": "Erreur de procédure"}, headers=h("chef1")).json()["statut"] == "annulee"

    sor = {"employe_id": e, "type": "demission", "date_notification": str(dt.date.today() - dt.timedelta(days=40)), "date_sortie": str(dt.date.today() - dt.timedelta(days=2)), "motif": "Départ volontaire"}
    assert client.post("/api/grh/sorties", json={**sor, "date_notification": str(dt.date.today()), "date_sortie": str(dt.date.today())}, headers=h("rh1")).status_code == 422   # préavis
    r = client.post("/api/grh/sorties", json=sor, headers=h("rh1"))
    assert r.status_code == 201, r.text
    assert client.post(f"/api/grh/sorties/{r.json()['id']}/finaliser", headers=h("chef1")).status_code == 403
    f = client.post(f"/api/grh/sorties/{r.json()['id']}/finaliser", headers=h("rh1"))
    assert f.status_code == 200 and f.json()["statut"] == "finalisee"
    cert = client.get(f"/api/grh/employes/{e}/certificat-travail", headers=h("rh1")).json()
    assert cert["type"] == "certificat" and cert["employe"]["statut"] == "sorti" and cert["institution"]["raison_sociale"]


def test_indicateurs(client, h, base):
    i = client.get("/api/grh/indicateurs", headers=h("rh1")).json()
    assert i["total"]["effectif"] >= 3 and i["total"]["sorties_12m"] >= 1 and i["total"]["masse_salariale"] > 0 and i["contrats"]
    assert client.get("/api/grh/indicateurs", headers=h("caissier1")).status_code == 403
