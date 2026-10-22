import datetime as dt

import pytest

# Module sous test : routers/immobilisations.py (registre, amortissement, sortie, maintenance, interventions, alertes)
# + schema/52_immobilisations.sql et 54_permissions_immobilisations.sql


@pytest.fixture(scope="module")
def base(client, h):
    r = client.post("/api/immobilisations", json={
        "designation": "Mobilier du bureau test", "categorie": "mobilier_bureau", "date_acquisition": "2026-01-10",
        "date_mise_en_service": "2026-01-15", "valeur_acquisition": 600000}, headers=h("chef1"))
    assert r.status_code == 201, r.text
    assert r.json()["numero"].startswith("IMM-") and r.json()["statut"] == "en_service"
    return {"immo": r.json()["id"], "numero": r.json()["numero"]}


def test_registre_et_droits(client, h, base):
    assert client.post("/api/immobilisations", json={"designation": "Interdit", "categorie": "mobilier_bureau", "date_acquisition": "2026-01-10",
                                                       "date_mise_en_service": "2026-01-10", "valeur_acquisition": 1000}, headers=h("caissier1")).status_code == 403
    assert client.get("/api/immobilisations", headers=h("caissier1")).status_code == 403
    assert client.get("/api/categories-immobilisation", headers=h("auditeur")).status_code == 200
    assert client.get(f"/api/immobilisations/{base['immo']}", headers=h("chef2")).status_code == 404            # autre agence
    detail = client.get(f"/api/immobilisations/{base['immo']}", headers=h("auditeur")).json()
    assert detail["numero"] == base["numero"] and detail["valeur_nette"] == 600000


def test_amortissement_et_sortie(client, h, base):
    am = client.post("/api/immobilisations/amortissements/calculer", json={"jusqu": "2026-03-31"}, headers=h("chef1"))
    assert am.status_code == 200 and am.json()["dotations_creees"] >= 3
    assert client.post("/api/immobilisations/amortissements/calculer", json={"jusqu": "2026-03-31"}, headers=h("chef1")).json()["dotations_creees"] == 0
    det = client.get(f"/api/immobilisations/{base['immo']}", headers=h("chef1")).json()
    assert det["amortissements"][0]["montant"] == 10000                                                      # 600 000 / 60 mois
    assert det["cumul_amortissement"] == 30000
    assert client.post(f"/api/immobilisations/{base['immo']}/sortie", json={"date_sortie": "2026-06-30", "type_sortie": "cession", "motif": "ok"},
                       headers=h("chef1")).status_code == 422                                                # motif trop court
    s = client.post(f"/api/immobilisations/{base['immo']}/sortie", json={"date_sortie": "2026-06-30", "type_sortie": "cession", "valeur_cession": 400000,
                                                                          "motif": "Vendu à un tiers"}, headers=h("chef1"))
    assert s.status_code == 200 and s.json()["immobilisation"]["statut"] == "sortie"
    assert s.json()["valeur_nette_comptable"] == 540000
    assert client.post(f"/api/immobilisations/{base['immo']}/pannes", json={"description": "Panne après sortie"}, headers=h("chef1")).status_code == 422


def test_panne_reparation_et_couts(client, h):
    immo = client.post("/api/immobilisations", json={"designation": "Ordinateur réparable", "categorie": "materiel_informatique", "date_acquisition": "2026-02-01",
                                                     "date_mise_en_service": "2026-02-01", "valeur_acquisition": 100000}, headers=h("chef1")).json()["id"]
    # le caissier signale la panne, avec mise hors service
    p = client.post(f"/api/immobilisations/{immo}/pannes", json={"description": "Écran fissuré", "priorite": "urgente", "hors_service": True}, headers=h("caissier1"))
    assert p.status_code == 201, p.text
    xid = p.json()["id"]
    assert client.get(f"/api/immobilisations/{immo}", headers=h("chef1")).json()["statut"] == "hors_service"
    alertes = client.get("/api/immobilisations-alertes", headers=h("chef1")).json()
    assert any(a["type"] == "panne_urgente" and a["reference"] == client.get(f"/api/immobilisations/{immo}", headers=h("chef1")).json()["numero"] for a in alertes)
    # réparation : une facture est exigée dès qu'il y a un coût
    assert client.post(f"/api/interventions/{xid}/terminer", json={"date_fin": dt.date.today().isoformat(), "resultat": "Écran remplacé", "cout_main_oeuvre": 20000,
                                                                    "cout_pieces": 15000}, headers=h("chef1")).status_code == 422
    assert client.post(f"/api/interventions/{xid}/planifier", json={"date_planifiee": "2026-02-05"}, headers=h("chef1")).json()["statut"] == "planifiee"
    assert client.post(f"/api/interventions/{xid}/demarrer", headers=h("chef1")).json()["statut"] == "en_cours"
    assert client.get(f"/api/immobilisations/{immo}", headers=h("chef1")).json()["statut"] == "en_maintenance"
    t = client.post(f"/api/interventions/{xid}/terminer", json={"date_fin": dt.date.today().isoformat(), "resultat": "Écran remplacé", "cout_main_oeuvre": 20000,
                                                                "cout_pieces": 15000, "reference_facture": "FAC-REP-API"}, headers=h("chef1"))
    assert t.status_code == 200, t.text
    assert t.json()["statut"] == "terminee" and t.json()["cout_total"] == 35000 and t.json()["operation_id"]
    assert client.get(f"/api/immobilisations/{immo}", headers=h("chef1")).json()["statut"] == "en_service"
    couts = client.get("/api/immobilisations-couts", headers=h("auditeur")).json()
    assert any(float(c["cout_total"]) >= 35000 for c in couts)
    assert client.post(f"/api/interventions/{xid}/annuler", json={"motif": "trop tard"}, headers=h("chef1")).status_code == 422      # terminée : figée


def test_plan_de_maintenance(client, h, base):
    # un bien en service (le bien de référence a été vendu plus haut)
    neuf = client.post("/api/immobilisations", json={"designation": "Climatiseur du bureau", "categorie": "installation_technique", "date_acquisition": "2026-03-01",
                                                     "date_mise_en_service": "2026-03-01", "valeur_acquisition": 250000}, headers=h("chef1")).json()["id"]
    base["immo"] = neuf
    plan = client.post("/api/plans-maintenance", json={"immobilisation_id": base["immo"], "libelle": "Contrôle annuel du mobilier",
                                                       "periodicite_mois": 12, "prochaine_echeance": dt.date.today().isoformat()}, headers=h("chef1"))
    assert plan.status_code == 201, plan.text
    g = client.post("/api/maintenance/preventives/generer", headers=h("chef1"))
    assert g.status_code == 200 and g.json()["interventions_planifiees"] >= 1
    assert client.post("/api/maintenance/preventives/generer", headers=h("chef1")).json()["interventions_planifiees"] == 0      # pas de doublon
    assert client.post("/api/plans-maintenance", json={"immobilisation_id": base["immo"], "libelle": "Plan", "periodicite_mois": 0,
                                                       "prochaine_echeance": "2026-09-01"}, headers=h("chef1")).status_code == 422
    assert client.post("/api/plans-maintenance", json={"immobilisation_id": base["immo"], "libelle": "Plan autre agence", "periodicite_mois": 12,
                                                       "prochaine_echeance": "2026-09-01"}, headers=h("chef2")).status_code == 404
