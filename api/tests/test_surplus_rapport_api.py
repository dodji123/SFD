import datetime as dt

import pytest


@pytest.fixture(scope="module")
def ecart(client, h, produits):
    """Agent, cycle de 5 collectes de 1 000 F (1er au 5 octobre), surplus de 400 le 5 octobre, écart de 500 le 3 octobre."""
    z = client.post("/api/zones", json={"code": "ZS", "libelle": "Zone surplus"}, headers=h("chef1")).json()
    ag = client.post("/api/agents", json={"matricule": "S-A1", "nom": "Agent S1"}, headers=h("chef1")).json()
    cl = client.post("/api/clients", json={"nom": "Cli Surplus", "zone_id": z["id"]}, headers=h("chef1")).json()
    c = client.post("/api/cycles", json={"client_id": cl["id"], "produit_id": produits["P1"], "mise": 1000,
                                         "date_debut": "2026-10-01", "date_fin": "2026-10-31"}, headers=h("chef1")).json()
    d0 = dt.date(2026, 10, 1)
    lignes = [{"date_collecte": str(d0 + dt.timedelta(days=i)), "montant_collecte": 1000, "agent_id": ag["id"]} for i in range(5)]
    assert client.post(f"/api/cycles/{c['id']}/lignes", json={"lignes": lignes}, headers=h("chef1")).status_code == 201

    for jour, verse in [(1, 1000), (2, 1000), (3, 1000), (4, 1000), (5, 1400)]:
        r = client.post(f"/api/agents/{ag['id']}/versement",
                        json={"date_tournee": str(d0 + dt.timedelta(days=jour - 1)), "montant_verse": verse}, headers=h("caissier1"))
        assert r.status_code == 201, r.text

    retrait = client.post(f"/api/cycles/{c['id']}/retrait", json={"date": "2026-10-10"}, headers=h("chef1")).json()
    r = client.post(f"/api/retraits/{retrait['id']}/ecart", json={
        "montant_livret": 5500, "montant_machine": 5000,
        "details": [{"date": "2026-10-03", "montant": 500, "agent_id": ag["id"]}],
    }, headers=h("chef1"))
    assert r.status_code == 201, r.text
    ecart_id = next(e["id"] for e in client.get(f"/api/retraits/{retrait['id']}", headers=h("chef1")).json()["ecarts"])
    return {"agent": ag, "ecart_id": ecart_id}


def _detail(client, h, ecart_id):
    return client.get(f"/api/ecarts/{ecart_id}/details", headers=h("chef1")).json()["details"][0]


def test_surplus_d_une_autre_date_proposé(client, h, ecart):
    d = _detail(client, h, ecart["ecart_id"])
    assert d["montant"] == 500 and d["perte"] == 0
    assert [(s["date_surplus"], s["libre"]) for s in d["surplus_autres_dates"]] == [("2026-10-05", 400)]


def test_caissier_ne_valide_pas(client, h, ecart):
    d = _detail(client, h, ecart["ecart_id"])
    r = client.post(f"/api/ecart-details/{d['id']}/validation-surplus",
                    json={"surplus_id": d["surplus_autres_dates"][0]["id"], "montant": 400, "motif": "essai du caissier"},
                    headers=h("caissier1"))
    assert r.status_code == 403


def test_motif_trop_court_refusé(client, h, ecart):
    d = _detail(client, h, ecart["ecart_id"])
    r = client.post(f"/api/ecart-details/{d['id']}/validation-surplus",
                    json={"surplus_id": d["surplus_autres_dates"][0]["id"], "montant": 400, "motif": "ok"}, headers=h("chef1"))
    assert r.status_code == 422


def test_montant_superieur_au_surplus_refusé(client, h, ecart):
    d = _detail(client, h, ecart["ecart_id"])
    r = client.post(f"/api/ecart-details/{d['id']}/validation-surplus",
                    json={"surplus_id": d["surplus_autres_dates"][0]["id"], "montant": 450, "motif": "trop pour le surplus"},
                    headers=h("chef1"))
    assert r.status_code == 422


def test_chef_valide_puis_traitement_laisse_la_perte(client, h, ecart):
    d = _detail(client, h, ecart["ecart_id"])
    r = client.post(f"/api/ecart-details/{d['id']}/validation-surplus",
                    json={"surplus_id": d["surplus_autres_dates"][0]["id"], "montant": 400, "motif": "surplus du 5 autorisé"},
                    headers=h("chef1"))
    assert r.status_code == 201, r.text
    assert r.json()["montant"] == 400 and r.json()["consomme"] == 0

    t = client.post(f"/api/ecarts/{ecart['ecart_id']}/traiter", json={}, headers=h("chef1"))
    assert t.status_code == 200, t.text
    assert t.json()["perte_imputee_aux_agents"] == 100


def test_rapport_des_manquants_sur_la_periode(client, h, ecart):
    lignes = client.get("/api/rapport-manquants", params={"du": "2026-10-01", "au": "2026-10-31"}, headers=h("chef1")).json()
    s1 = next(x for x in lignes if x["matricule"] == "S-A1")
    assert s1["pertes"] == 100 and s1["reste_du"] == 100 and s1["recouvre"] == 0


def test_rapport_periode_inversee_refusée(client, h):
    r = client.get("/api/rapport-manquants", params={"du": "2026-10-31", "au": "2026-10-01"}, headers=h("chef1"))
    assert r.status_code == 422
