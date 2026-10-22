import datetime as dt

import pytest

# Module sous test : routers/charges_produits.py (tiers, budget prévu / réalisé, récurrentes, alertes) + schema/51_charges_produits.sql


@pytest.fixture(scope="module")
def base(sql, agences):
    k = sql("INSERT INTO caisse(agence_id, code, type) VALUES (%s, 'CP-CHG', 'principale') RETURNING id", (agences["a1"],))[0]["id"]
    sql("INSERT INTO session_caisse(caisse_id, date_session, solde_ouverture) VALUES (%s, %s, 1000000)", (k, dt.date.today()))
    return {"caisse": k}


def test_tiers_et_droits(client, h, base, agences):
    assert client.post("/api/tiers", json={"nom": "Bailleur Test", "type": "bailleur"}, headers=h("caissier1")).status_code == 403
    a1 = client.post("/api/tiers", json={"nom": "Bailleur Test", "type": "bailleur", "agence_id": agences["a1"]}, headers=h("chef1"))
    assert a1.status_code == 201, a1.text
    base["tiers"] = a1.json()["id"]
    assert client.post("/api/tiers", json={"nom": "bailleur test", "agence_id": agences["a1"]}, headers=h("chef1")).status_code == 409          # même nom dans l'agence
    assert client.post("/api/tiers", json={"nom": "Commun SA"}, headers=h("chef1")).status_code == 403                                      # tiers commun : siège
    assert client.post("/api/tiers", json={"nom": "Commun SA"}, headers=h("comptable")).status_code == 201
    assert client.post("/api/tiers", json={"nom": "Autre agence", "agence_id": agences["a2"]}, headers=h("chef1")).status_code == 403
    vus = {t["nom"] for t in client.get("/api/tiers", headers=h("chef1")).json()}
    assert {"Bailleur Test", "Commun SA"} <= vus
    assert client.get("/api/tiers", params={"q": "bailleur"}, headers=h("auditeur")).json()[0]["nom"] == "Bailleur Test"
    assert client.get("/api/tiers", headers=h("agent1")).status_code == 403
    assert client.patch(f"/api/tiers/{base['tiers']}", json={"telephone": "+22890000000"}, headers=h("chef2")).status_code == 404            # autre agence
    assert client.patch(f"/api/tiers/{base['tiers']}", json={"telephone": "+22890000000"}, headers=h("chef1")).json()["telephone"] == "+22890000000"


def test_budget_realise_synthese_et_alertes(client, h, base, agences):
    annee = dt.date.today().year
    mois = dt.date.today().month
    ligne = {"mois": mois, "code_operation": "facture_loyer_a_payer", "montant_prevu": 90000}
    assert client.put("/api/budget-charges-produits", json={"annee": annee, "lignes": [ligne]}, headers=h("caissier1")).status_code == 403
    assert client.put("/api/budget-charges-produits", json={"annee": annee, "lignes": [{**ligne, "code_operation": "virement_fournisseur"}]}, headers=h("chef1")).status_code == 422   # ni charge ni produit
    assert client.put("/api/budget-charges-produits", json={"annee": annee, "lignes": [ligne]}, headers=h("chef1")).json() == {"enregistrees": 1}
    assert client.put("/api/budget-charges-produits", json={"annee": annee, "lignes": [{**ligne, "montant_prevu": 95000}]}, headers=h("chef1")).status_code == 200   # mise à jour
    corps = {"code_operation": "facture_loyer_a_payer", "montant": 100000, "reference_justificatif": "LOY-API", "tiers_id": base["tiers"], "agence_id": agences["a1"]}
    op = client.post("/api/operations-generales", json=corps, headers=h("chef1"))
    assert op.status_code == 201, op.text
    assert op.json()["tiers_nom"] == "Bailleur Test"
    client.post("/api/operations-generales", json={"code_operation": "produit_divers", "montant": 20000, "caisse_id": base["caisse"], "tiers": "Vente"}, headers=h("caissier1"))
    b = client.get("/api/budget-charges-produits", params={"annee": annee, "mois": mois}, headers=h("auditeur")).json()
    loyer = next(x for x in b if x["code_operation"] == "facture_loyer_a_payer")
    assert float(loyer["prevu"]) == 95000 and float(loyer["realise"]) == 100000 and loyer["depassement"] is True and float(loyer["taux"]) == 105.3
    assert [x["code_operation"] for x in client.get("/api/budget-charges-produits", params={"annee": annee, "depassement": "true"}, headers=h("chef1")).json()] == ["facture_loyer_a_payer"]
    s = client.get("/api/charges-produits/synthese", params={"annee": annee}, headers=h("chef1")).json()
    mm = next(m for m in s["mensuel"] if m["mois"] == mois)
    assert mm["charges"] == 100000 and mm["produits"] == 20000 and mm["resultat"] == -80000 and s["total"]["charges_prevues"] == 95000
    al = client.get("/api/charges-produits/alertes", headers=h("chef1")).json()
    assert any(a["type"] == "depassement_budget" for a in al)
    assert client.get("/api/charges-produits/alertes", headers=h("chef2")).json() == []                                                     # autre agence
    assert client.get("/api/budget-charges-produits", params={"annee": annee}, headers=h("chef2")).json() == []


def test_operations_recurrentes(client, h, base, agences):
    debut = (dt.date.today().replace(day=1) - dt.timedelta(days=62)).replace(day=1)
    corps = {"code_operation": "facture_loyer_a_payer", "montant": 100000, "periodicite": "mensuelle", "prochaine_date": debut.isoformat(), "libelle": "Loyer récurrent", "tiers_id": base["tiers"]}
    assert client.post("/api/operations-recurrentes", json=corps, headers=h("caissier1")).status_code == 403
    assert client.post("/api/operations-recurrentes", json={**corps, "code_operation": "paiement_loyer"}, headers=h("chef1")).status_code == 422   # de caisse : refusé
    autre = client.post("/api/tiers", json={"nom": "Tiers agence 2", "agence_id": agences["a2"]}, headers=h("comptable")).json()["id"]
    assert client.post("/api/operations-recurrentes", json={**corps, "tiers_id": autre}, headers=h("chef1")).status_code == 422                 # tiers d'une autre agence
    r = client.post("/api/operations-recurrentes", json=corps, headers=h("chef1"))
    assert r.status_code == 201, r.text
    assert client.post("/api/operations-recurrentes/generer", json={}, headers=h("chef1")).status_code == 403                                  # relève du siège
    n = client.post("/api/operations-recurrentes/generer", json={}, headers=h("comptable")).json()["operations_creees"]
    assert n >= 3                                                                                                                           # au moins trois échéances rattrapées
    assert client.post("/api/operations-recurrentes/generer", json={}, headers=h("comptable")).json() == {"operations_creees": 0}             # rejeu sans effet
    liste = client.get("/api/operations-recurrentes", headers=h("chef1")).json()
    assert liste[0]["tiers"] == "Bailleur Test" and liste[0]["derniere_generation"] == dt.date.today().isoformat()
    assert client.patch(f"/api/operations-recurrentes/{r.json()['id']}", json={"actif": False}, headers=h("chef2")).status_code == 404
    assert client.patch(f"/api/operations-recurrentes/{r.json()['id']}", json={"actif": False}, headers=h("chef1")).json()["actif"] is False
