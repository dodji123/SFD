import datetime as dt

import pytest


@pytest.fixture(scope="module")
def base(client, h, agences, produits):
    z = client.post("/api/zones", json={"code": "ZK", "libelle": "Zone crédit"}, headers=h("chef1")).json()
    ag = client.post("/api/agents", json={"matricule": "K-A1", "nom": "Agent K"}, headers=h("chef1")).json()
    cl = [client.post("/api/clients", json={"nom": f"Cli Crédit {i}", "zone_id": z["id"]}, headers=h("chef1")).json() for i in (1, 2, 3)]
    compte = client.post("/api/comptes-epargne", json={"client_id": cl[0]["id"], "produit_id": produits["CL"]}, headers=h("caissier1")).json()
    client.post(f"/api/comptes-epargne/{compte['id']}/depot", json={"montant": 150000}, headers=h("caissier1"))
    pce = client.post("/api/produits-credit", json={"code": "PCE1", "libelle": "Crédit sur épargne", "type": "sur_epargne",
                                                    "taux_annuel": 0.12, "frais_dossier_taux": 0.01}, headers=h("chef1")).json()
    pcs = client.post("/api/produits-credit", json={"code": "PCS1", "libelle": "Crédit sans épargne", "type": "sans_epargne",
                                                    "taux_annuel": 0.12}, headers=h("chef1")).json()
    caisse = client.post("/api/caisses", json={"code": "CP-K"}, headers=h("chef1")).json()
    session = client.post(f"/api/caisses/{caisse['id']}/sessions", json={"date_session": "2026-11-05", "solde_ouverture": 1000000}, headers=h("caissier1")).json()
    return {"z": z, "ag": ag, "cl": cl, "compte": compte, "pce": pce, "pcs": pcs, "session": session, "produits": produits}


def _demande(client, h, corps, login="chef1"):
    r = client.post("/api/demandes-credit", json=corps, headers=h(login))
    assert r.status_code == 201, r.text
    return r.json()


def test_produits_de_credit(client, h, base):
    assert base["pce"]["type"] == "sur_epargne"
    assert client.post("/api/produits-credit", json={"code": "ZZ", "libelle": "x", "type": "sur_epargne", "taux_annuel": 0.1}, headers=h("caissier1")).status_code == 403
    assert client.post("/api/produits-credit", json={"code": "PCE1", "libelle": "doublon", "type": "sur_epargne", "taux_annuel": 0.1}, headers=h("chef1")).status_code == 409
    assert len(client.get("/api/produits-credit", headers=h("agent1")).json()) >= 2


def test_demande_validations_et_droits(client, h, base):
    c, p = base["cl"][0]["id"], base["pce"]["id"]
    corps = {"client_id": c, "produit_id": p, "montant": 30000, "nb_echeances": 3, "compte_id": base["compte"]["id"], "garantie_montant": 0}
    r = client.post("/api/demandes-credit", json=corps, headers=h("chef1"))
    assert r.status_code == 422 and "garantie" in r.json()["detail"]                    # crédit sur épargne sans garantie
    assert client.post("/api/demandes-credit", json={**corps, "garantie_montant": 20000, "mode_remboursement": "tontine"}, headers=h("chef1")).status_code == 422  # tontine sans cycle
    assert client.post("/api/demandes-credit", json={**corps, "garantie_montant": 20000}, headers=h("caissier1")).status_code == 403
    assert client.post("/api/demandes-credit", json={**corps, "garantie_montant": 20000}, headers=h("chef2")).status_code == 404       # client d'une autre agence
    assert client.post("/api/demandes-credit", json={**corps, "garantie_montant": 20000, "montant": 0}, headers=h("chef1")).status_code == 422


def test_cycle_de_vie_prelevement_retard_saisie(client, h, base):
    cid, compte = base["cl"][0]["id"], base["compte"]["id"]
    d = _demande(client, h, {"client_id": cid, "produit_id": base["pce"]["id"], "montant": 30000, "nb_echeances": 3,
                             "compte_id": compte, "garantie_montant": 20000, "note": "Garantie négociée à 20 000"})
    assert d["statut"] == "demandee" and d["numero"].startswith("DC-T1-") and d["taux"] == 0.12
    # décision réservée aux responsables ; déblocage impossible avant l'approbation
    assert client.post(f"/api/demandes-credit/{d['id']}/decision", json={"approuve": True}, headers=h("agent1")).status_code == 403
    assert client.post(f"/api/demandes-credit/{d['id']}/debloquer", json={"date": "2026-11-01"}, headers=h("caissier1")).status_code == 422
    r = client.post(f"/api/demandes-credit/{d['id']}/decision", json={"approuve": True, "commentaire": "dossier complet"}, headers=h("chef1"))
    assert r.status_code == 200 and r.json()["statut"] == "approuvee" and r.json()["validateur_id"] is not None
    assert client.post(f"/api/demandes-credit/{d['id']}/decision", json={"approuve": True}, headers=h("chef1")).status_code == 422   # déjà traitée
    assert client.post(f"/api/demandes-credit/{d['id']}/debloquer", json={"date": "2026-11-01"}, headers=h("agent1")).status_code == 403

    r = client.post(f"/api/demandes-credit/{d['id']}/debloquer", json={"date": "2026-11-01", "mode": "compte"}, headers=h("caissier1"))
    assert r.status_code == 201, r.text
    cr = r.json()
    assert cr["montant_accorde"] == 30000 and cr["frais_dossier"] == 300 and cr["garantie_bloquee"] == 20000
    assert [(e["capital"], e["interet"], e["date_prevue"]) for e in cr["echeances"]] == [
        (10000, 300, "2026-12-01"), (10000, 200, "2026-12-31"), (10000, 100, "2027-01-30")]
    cpt = client.get(f"/api/comptes-epargne/{compte}", headers=h("caissier1")).json()
    assert (cpt["solde"], cpt["disponible"]) == (179700, 154700)                          # 30000 débloqués - 300 de frais ; garantie bloquée
    assert client.post(f"/api/demandes-credit/{d['id']}/debloquer", json={}, headers=h("caissier1")).status_code == 422   # déjà débloquée

    # prélèvements automatiques aux dates d'échéance
    assert client.post("/api/taches/prelever-echeances", json={"date": "2026-12-01"}, headers=h("chef1")).json() == {"prelevements": 1}
    assert client.post("/api/taches/prelever-echeances", json={"date": "2026-12-31"}, headers=h("chef1")).json() == {"prelevements": 1}
    # le client vide son disponible : 5000 restent
    dispo = client.get(f"/api/comptes-epargne/{compte}", headers=h("caissier1")).json()["disponible"]
    assert client.post(f"/api/comptes-epargne/{compte}/retrait", json={"montant": dispo - 5000}, headers=h("caissier1")).status_code == 201
    assert client.post("/api/taches/prelever-echeances", json={"date": "2027-02-04"}, headers=h("chef1")).json() == {"prelevements": 0}   # fonds insuffisants
    assert client.post("/api/taches/maj-statuts-credit", json={"date": "2027-02-04"}, headers=h("chef1")).json()["echeances_mises_a_jour"] >= 1
    detail = client.get(f"/api/credits/{cr['id']}", headers=h("chef1")).json()
    assert detail["statut"] == "en_retard" and (detail["echeances"][2]["statut"], detail["echeances"][2]["penalite_due"]) == ("echue", 50)
    assert client.post("/api/taches/saisir-garanties", json={"date": "2027-02-04"}, headers=h("chef1")).json() == {"saisies": 0}   # 5 jours <= 30
    assert client.post("/api/taches/saisir-garanties", json={"date": "2027-03-11"}, headers=h("chef1")).json() == {"saisies": 1}
    detail = client.get(f"/api/credits/{cr['id']}", headers=h("chef1")).json()
    assert detail["statut"] == "solde" and detail["echeances"][2]["penalite_payee"] == 400
    g = detail["garantie"]
    assert (g["montant_bloque"], g["montant_saisi"], g["montant_restant"], g["statut"]) == (20000, 10500, 0, "liberee")
    assert client.get(f"/api/clients/{cid}", headers=h("chef1")).json()["points_fidelite"] == 4      # +10 +10 -16


def test_credit_en_especes_remboursement_partiel_et_ordre(client, h, base):
    cid = base["cl"][1]["id"]
    d = _demande(client, h, {"client_id": cid, "produit_id": base["pcs"]["id"], "montant": 10000, "nb_echeances": 2, "mode_remboursement": "especes"})
    client.post(f"/api/demandes-credit/{d['id']}/decision", json={"approuve": True}, headers=h("chef1"))
    sid = base["session"]["id"]
    assert client.post(f"/api/demandes-credit/{d['id']}/debloquer", json={"date": "2026-11-05", "mode": "especes"}, headers=h("caissier1")).status_code == 422  # session obligatoire
    avant = client.get(f"/api/sessions/{sid}", headers=h("caissier1")).json()["solde_theorique"]
    r = client.post(f"/api/demandes-credit/{d['id']}/debloquer", json={"date": "2026-11-05", "mode": "especes", "session_id": sid}, headers=h("caissier1"))
    assert r.status_code == 201, r.text
    cr = r.json()
    assert avant - client.get(f"/api/sessions/{sid}", headers=h("caissier1")).json()["solde_theorique"] == 10000
    e1, e2 = cr["echeances"][0]["id"], cr["echeances"][1]["id"]
    assert (cr["echeances"][0]["capital"], cr["echeances"][0]["interet"]) == (5000, 100)
    assert client.post(f"/api/echeances/{e2}/rembourser-especes", json={"montant": 100, "session_id": sid, "date": "2026-12-05"}, headers=h("caissier1")).status_code == 422   # ordre
    r = client.post(f"/api/echeances/{e1}/rembourser-especes", json={"montant": 2000, "session_id": sid, "date": "2026-12-05"}, headers=h("caissier1"))
    assert r.status_code == 200 and (r.json()["echeances"][0]["statut"], r.json()["echeances"][0]["capital_paye"]) == ("partielle", 2000)
    assert client.post(f"/api/echeances/{e1}/rembourser-especes", json={"montant": 99999, "session_id": sid, "date": "2026-12-05"}, headers=h("caissier1")).status_code == 422  # plus que le dû
    r = client.post(f"/api/echeances/{e1}/rembourser-especes", json={"montant": 3100, "session_id": sid, "date": "2026-12-05"}, headers=h("caissier1"))
    assert r.json()["echeances"][0]["statut"] == "payee" and (r.json()["echeances"][0]["capital_paye"], r.json()["echeances"][0]["interet_paye"]) == (5000, 100)
    s = client.get(f"/api/sessions/{sid}", headers=h("caissier1")).json()
    assert s["encaissements"] >= 5100
    assert client.post(f"/api/echeances/{e1}/rembourser-especes", json={"montant": 1, "session_id": sid}, headers=h("chef2")).status_code == 404
    assert client.post(f"/api/echeances/{e2}/rembourser-especes", json={"montant": 1, "session_id": sid}, headers=h("agent1")).status_code == 403


def test_credit_sur_tontine_remboursement_par_seuil(client, h, base):
    cid = base["cl"][2]["id"]
    cy = client.post("/api/cycles", json={"client_id": cid, "produit_id": base["produits"]["P1"], "mise": 1000,
                                          "date_debut": "2026-10-01", "date_fin": "2026-10-31"}, headers=h("chef1")).json()
    d = _demande(client, h, {"client_id": cid, "produit_id": base["pce"]["id"], "montant": 5000, "nb_echeances": 2,
                             "mode_remboursement": "tontine", "cycle_id": cy["id"], "garantie_montant": 1})
    client.post(f"/api/demandes-credit/{d['id']}/decision", json={"approuve": True}, headers=h("chef1"))
    sid = base["session"]["id"]
    cr = client.post(f"/api/demandes-credit/{d['id']}/debloquer", json={"date": "2026-10-01", "mode": "especes", "session_id": sid}, headers=h("caissier1")).json()
    assert cr["mode_remboursement"] == "tontine" and cr["cycle_garantie_id"] == cy["id"]
    d0 = dt.date(2026, 10, 1)
    lignes = [{"date_collecte": str(d0 + dt.timedelta(days=i)), "montant_collecte": 1000, "agent_id": base["ag"]["id"]} for i in range(10)]
    assert client.post(f"/api/cycles/{cy['id']}/lignes", json={"lignes": lignes}, headers=h("chef1")).status_code == 201
    rb = client.get("/api/retraits", params={"nature": "remboursement", "cycle_id": cy["id"]}, headers=h("chef1")).json()
    rb = sorted(rb, key=lambda x: x["id"])
    assert [(r["montant"], r["date_atteinte"], r["decaissement"]) for r in rb] == [(2550, "2026-10-03", False), (2525, "2026-10-06", False)]
    # le net du cycle déduit les remboursements prélevés sur la collecte
    assert client.get(f"/api/cycles/{cy['id']}", headers=h("chef1")).json()["net"] == 10000 - 1000 - 5075
    for r in rb:
        assert client.post(f"/api/retraits/{r['id']}/constat-sans-ecart", headers=h("chef1")).status_code == 200
    assert client.post(f"/api/retraits/{rb[1]['id']}/executer", json={}, headers=h("caissier1")).status_code == 422     # l'échéance 1 passe avant
    assert client.post(f"/api/retraits/{rb[0]['id']}/executer", json={}, headers=h("caissier1")).status_code == 200
    assert client.post(f"/api/retraits/{rb[1]['id']}/executer", json={}, headers=h("caissier1")).status_code == 200
    detail = client.get(f"/api/credits/{cr['id']}", headers=h("chef1")).json()
    assert detail["statut"] == "solde" and {p["source"] for p in detail["paiements"]} == {"tontine"}
    assert [e["date_paiement"] for e in detail["echeances"]] == ["2026-10-03", "2026-10-06"]
    assert client.get(f"/api/cycles/{cy['id']}", headers=h("chef1")).json()["statut"] == "en_cours"   # le cycle continue


def test_taches_et_listes(client, h, base):
    assert client.post("/api/taches/inconnue", json={}, headers=h("chef1")).status_code == 404
    assert client.post("/api/taches/maj-statuts-credit", json={}, headers=h("caissier1")).status_code == 403
    assert client.post("/api/taches/maj-statuts-credit", json={}, headers=h("admin")).status_code == 400      # le siège doit désigner l'agence
    assert client.get("/api/credits", headers=h("chef2")).json() == []
    assert len(client.get("/api/credits", params={"statut": "solde"}, headers=h("chef1")).json()) >= 2
    assert client.get("/api/demandes-credit", params={"statut": "debloquee"}, headers=h("auditeur")).status_code == 200
    detail = client.get("/api/demandes-credit", headers=h("chef1")).json()[0]
    assert client.get(f"/api/demandes-credit/{detail['id']}", headers=h("chef2")).status_code == 404
