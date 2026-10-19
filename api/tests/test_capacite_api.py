import pytest

# Module sous test : routers/capacite.py (analyse de capacité de remboursement d'une demande de crédit)

CHARGES = [
    {"libelle": "Loyer", "categorie": "activite", "montant": 30000, "periode": "mois"},
    {"libelle": "Transport", "categorie": "activite", "montant": 1500, "periode": "jourouvre"},
    {"libelle": "Électricité et eau", "categorie": "activite", "montant": 12000, "periode": "mois"},
    {"libelle": "Taxe", "categorie": "activite", "montant": 15000, "periode": "trimestre"},
    {"libelle": "Nourriture", "categorie": "menage", "montant": 2500, "periode": "jour7"},
    {"libelle": "Scolarité", "categorie": "menage", "montant": 60000, "periode": "trimestre"},
    {"libelle": "Santé", "categorie": "menage", "montant": 15000, "periode": "mois"},
]
REVENUS = {"secteur": "commerce", "anciennete_mois": 36, "jours_activite": 26, "ventes_mensuelles": 900000, "achats_mensuels": 600000, "autres_revenus": 0, "charges": CHARGES}


@pytest.fixture(scope="module")
def base(client, h, agences):
    c = client.post("/api/clients", json={"nom": "Capacite Test"}, headers=h("chef1")).json()
    p = client.post("/api/produits-credit", json={"code": "PCAP", "libelle": "Crédit capacité", "type": "sans_epargne", "taux_annuel": 0.18}, headers=h("chef1")).json()
    d = client.post("/api/demandes-credit", json={"client_id": c["id"], "produit_id": p["id"], "montant": 600000, "nb_echeances": 12, "mode_remboursement": "especes"}, headers=h("chef1"))
    assert d.status_code == 201, d.text
    return {"client": c, "demande": d.json(), "produit": p}


def test_simulation_sans_enregistrement(client, h, base):
    corps = {**REVENUS, "client_id": base["client"]["id"], "montant": 600000, "nb_echeances": 12, "taux": 0.18, "periodicite_jours": 30, "methode": "annuite_constante"}
    r = client.post("/api/capacite/simuler", json=corps, headers=h("chef1"))
    assert r.status_code == 200, r.text
    a = r.json()
    assert a["revenus"] == 214000 and a["revenu_disponible"] == 104000 and a["charge_mensuelle"] == 55008
    assert a["taux_endettement"] == pytest.approx(0.257, abs=1e-3) and a["couverture"] == pytest.approx(1.891, abs=1e-3) and a["conforme"] is True
    assert a["endettement_max_pct"] == 33 and a["couverture_min"] == 1.5                       # seuils paramétrés
    assert client.post("/api/capacite/simuler", json=corps, headers=h("chef2")).status_code == 404                 # client d'une autre agence
    assert client.post("/api/capacite/simuler", json={**corps, "charges": [{"categorie": "autre", "montant": 1, "periode": "mois"}]}, headers=h("chef1")).status_code == 422
    assert client.post("/api/capacite/simuler", json={**corps, "montant": 0}, headers=h("chef1")).status_code == 422
    assert client.get(f"/api/demandes-credit/{base['demande']['id']}/analyse", headers=h("chef1")).json()["analyse"] is None        # rien d'enregistré


def test_simulation_pour_une_demande(client, h, base):
    url = f"/api/demandes-credit/{base['demande']['id']}/analyse/simuler"
    a = client.post(url, json=REVENUS, headers=h("chef1")).json()
    assert a["charge_mensuelle"] == 59000 and a["revenus"] == 214000            # produit à capital constant
    assert client.post(url, json=REVENUS, headers=h("chef2")).status_code == 404


def test_enregistrement_et_remplacement(client, h, base):
    did = base["demande"]["id"]
    url = f"/api/demandes-credit/{did}/analyse"
    assert client.put(url, json=REVENUS, headers=h("caissier1")).status_code == 403          # le caissier ne saisit pas l'analyse
    assert client.put(url, json=REVENUS, headers=h("chef2")).status_code == 404              # autre agence
    r = client.put(url, json=REVENUS, headers=h("agent1"))
    assert r.status_code == 200, r.text
    a = r.json()
    # produit à capital constant : première échéance 50 000 + 9 000 d'intérêts
    assert a["resultat"]["charge_mensuelle"] == 59000 and a["conforme"] is True and float(a["taux_endettement"]) == pytest.approx(59000 / 214000, abs=1e-3)
    lu = client.get(url, headers=h("chef1")).json()
    assert lu["analyse"]["id"] == a["id"] and lu["analyse"]["utilisateur"] == "agent1" and lu["endettement_max_pct"] == 33 and lu["demande_statut"] == "demandee"
    # une nouvelle saisie remplace l'analyse (une seule par demande) : dette externe de 40 000 par mois
    dette = {**REVENUS, "charges": CHARGES + [{"libelle": "Crédit ailleurs", "categorie": "dette", "montant": 40000, "periode": "mois"}]}
    b = client.put(url, json=dette, headers=h("agent1")).json()
    assert b["id"] == a["id"] and b["conforme"] is False and b["resultat"]["dettes_en_cours"] == 40000
    assert any("endettement" in x for x in b["resultat"]["alertes"])


def test_dettes_deja_dues_a_l_institution(client, h, sql, base):
    c = base["client"]
    crid = sql("INSERT INTO credit(agence_id, numero, client_id, type, montant_accorde, taux, date_deblocage, nb_echeances, mode_remboursement) "
               "VALUES (1, 'CAP-CR-1', %s, 'sans_epargne', 60000, 0.12, '2026-09-01', 6, 'especes') RETURNING id", (c["id"],))[0]["id"]
    sql("SELECT generer_echeancier(%s)", (crid,))
    corps = {**REVENUS, "client_id": c["id"], "montant": 300000, "nb_echeances": 6, "taux": 0.12, "periodicite_jours": 30, "methode": "capital_constant"}
    a = client.post("/api/capacite/simuler", json=corps, headers=h("chef1")).json()
    assert a["dettes_internes"] == 10600 and a["dettes_en_cours"] == 10600          # 10 000 de capital + 600 d'intérêts, par mois
    assert a["revenu_disponible"] == 214000 - 110000 - 10600
    sql("UPDATE credit SET statut = 'solde', date_solde = current_date WHERE id = %s", (crid,))
    assert client.post("/api/capacite/simuler", json=corps, headers=h("chef1")).json()["dettes_internes"] == 0       # crédit soldé : plus de dette


def test_analyse_figee_apres_la_decision(client, h, base):
    did = base["demande"]["id"]
    assert client.post(f"/api/demandes-credit/{did}/decision", json={"approuve": False, "commentaire": "test"}, headers=h("chef1")).status_code == 200
    r = client.put(f"/api/demandes-credit/{did}/analyse", json=REVENUS, headers=h("agent1"))
    assert r.status_code == 422 and "décidée" in r.json()["detail"]
    assert client.get(f"/api/demandes-credit/{did}/analyse", headers=h("chef1")).json()["analyse"] is not None          # la lecture reste possible


def test_dossier_complet_et_politique_parametree(client, h, sql, base):
    c = client.post("/api/clients", json={"nom": "Dossier Complet"}, headers=h("chef1")).json()
    p = client.post("/api/produits-credit", json={"code": "PFRAIS", "libelle": "Crédit avec frais", "type": "sans_epargne", "taux_annuel": 0.18, "frais_dossier_taux": 0.02}, headers=h("chef1")).json()
    d = client.post("/api/demandes-credit", json={"client_id": c["id"], "produit_id": p["id"], "montant": 600000, "nb_echeances": 12, "mode_remboursement": "especes"}, headers=h("chef1")).json()
    url = f"/api/demandes-credit/{d['id']}/analyse"
    dossier = {**REVENUS, "cycle": 3, "caution": "perso", "historique": "bon",
               "garanties": [{"libelle": "Matériel", "type": "materiel", "valeur": 300000, "decote": 50}, {"libelle": "Moto", "type": "vehicule", "valeur": 400000, "decote": 40},
                             {"libelle": "Épargne", "type": "epargne", "valeur": 100000, "decote": 0}],
               "ventes_par_mois": [1200000] * 6 + [600000] * 6,
               "scenarios": [{"libelle": "Montant réduit", "montant": 400000, "nb_echeances": 12, "taux": 0.18, "methode": "annuite_constante"},
                             {"libelle": "Différé", "montant": 600000, "nb_echeances": 12, "taux": 0.18, "methode": "capital_constant", "differe": 2}],
               "groupe": [{"nom": "M1", "montant": 150000, "disponible": 45000}, {"nom": "M2", "montant": 250000, "disponible": 22000}]}
    r = client.put(url, json=dossier, headers=h("agent1"))
    assert r.status_code == 200, r.text
    a = r.json()
    res = a["resultat"]
    assert res["garanties_retenues"] == 490000 and res["frais"] == 12000 and res["pire_mois"] == 7 and res["nb_mois_defaut"] == 6        # frais du produit : 2 %
    assert a["avis"] == res["avis"] and float(a["score"]) == res["score"] and a["cycle"] == 3 and len(a["garanties"]) == 3 and len(a["ventes_par_mois"]) == 12
    assert [s["libelle"] for s in res["scenarios"]] == ["Montant réduit", "Différé"] and res["groupe"]["avis"] in ("Sous conditions", "Risqué", "Défavorable")
    assert res["groupe"]["membres"][1]["niveau"] == "insuffisant" and res["plafond_cycle"] == 800000
    # la politique est paramétrable : plafond du 3e cycle relevé et seuils d'avis modifiés par un paramètre global
    sql("UPDATE parametre SET valeur = '500000' WHERE cle = 'plafond_cycle_3' AND agence_id IS NULL")
    try:
        b = client.post(url + "/simuler", json=dossier, headers=h("chef1")).json()
        assert b["plafond_cycle"] == 500000 and b["depasse_plafond"] is True and b["montant_max_conseille"] <= 500000
        assert any("plafond du cycle 3" in x for x in b["alertes"])
    finally:
        sql("UPDATE parametre SET valeur = '800000' WHERE cle = 'plafond_cycle_3' AND agence_id IS NULL")
    # contrôles de saisie
    assert client.post(url + "/simuler", json={**dossier, "ventes_par_mois": [1] * 11}, headers=h("chef1")).status_code == 422
    assert client.post(url + "/simuler", json={**dossier, "garanties": [{"type": "avion", "valeur": 1}]}, headers=h("chef1")).status_code == 422
    assert client.post(url + "/simuler", json={**dossier, "caution": "voisin"}, headers=h("chef1")).status_code == 422
    assert client.post(url + "/simuler", json={**dossier, "cycle": 6}, headers=h("chef1")).status_code == 422
    # la lecture renvoie la politique en vigueur
    lu = client.get(url, headers=h("chef1")).json()
    assert lu["politique"]["plafonds"][2] == 800000 and lu["politique"]["poids"] == [35, 20, 15, 15, 15] and lu["analyse"]["id"] == a["id"]
