import datetime as dt

import pytest


@pytest.fixture(scope="module")
def cycles_carnet(client, h, produits):
    """Deux cycles de 5 collectes de 1 000 F (1er au 31 octobre) : un pour le relevé conforme, un pour l'écart."""
    z = client.post("/api/zones", json={"code": "ZR", "libelle": "Zone relevés"}, headers=h("chef1")).json()
    ag = client.post("/api/agents", json={"matricule": "R-A1", "nom": "Agent R1"}, headers=h("chef1")).json()
    out = {}
    for code in ("RC1", "RC2"):
        cl = client.post("/api/clients", json={"nom": f"Cli {code}", "zone_id": z["id"]}, headers=h("chef1")).json()
        c = client.post("/api/cycles", json={"client_id": cl["id"], "produit_id": produits["P1"], "mise": 1000,
                                             "date_debut": "2026-10-01", "date_fin": "2026-10-31"}, headers=h("chef1")).json()
        d0 = dt.date(2026, 10, 1)
        lignes = [{"date_collecte": str(d0 + dt.timedelta(days=i)), "montant_collecte": 1000, "agent_id": ag["id"]} for i in range(5)]
        assert client.post(f"/api/cycles/{c['id']}/lignes", json={"lignes": lignes}, headers=h("chef1")).status_code == 201
        out[code] = c
    return out


def test_rapprochement_liste_les_cycles_sans_releve(client, h, cycles_carnet):
    r = client.get("/api/releves-carnet/rapprochement", params={"statut": "sans_releve"}, headers=h("chef1"))
    assert r.status_code == 200, r.text
    assert {cycles_carnet["RC1"]["id"], cycles_carnet["RC2"]["id"]} <= {x["cycle_id"] for x in r.json()}


def test_releve_conforme_rapproche_sans_ecart(client, h, cycles_carnet):
    cid = cycles_carnet["RC1"]["id"]
    body = {"date_debut": "2026-10-01", "date_fin": "2026-10-31", "mise": 1000, "cle": "R-TEST-1",
            "pages": [{"page": 1, "montant": 3000}, {"page": 2, "montant": 2000}]}
    r = client.post(f"/api/releves-carnet/cycles/{cid}", json=body, headers=h("chef1"))
    assert r.status_code == 201, r.text
    assert r.json()["total_carnet"] == 5000

    releve = client.get(f"/api/releves-carnet/cycles/{cid}", headers=h("chef1")).json()
    assert [p["montant"] for p in releve["pages"]] == [3000, 2000]

    ligne = next(x for x in client.get("/api/releves-carnet/rapprochement", headers=h("chef1")).json() if x["cycle_id"] == cid)
    assert ligne["statut"] == "conforme" and ligne["ecarts"] == []


def test_saisie_rejouee_ne_cree_pas_de_doublon(client, h, cycles_carnet):
    cid = cycles_carnet["RC1"]["id"]
    body = {"date_debut": "2026-10-01", "date_fin": "2026-10-31", "mise": 1000, "cle": "R-TEST-1",
            "pages": [{"page": 1, "montant": 3000}, {"page": 2, "montant": 2000}]}
    r = client.post(f"/api/releves-carnet/cycles/{cid}", json=body, headers=h("chef1"))
    assert r.status_code == 201, r.text
    assert client.get(f"/api/releves-carnet/cycles/{cid}", headers=h("chef1")).json()["id"] == r.json()["id"]


def test_second_releve_du_cycle_refuse(client, h, cycles_carnet):
    cid = cycles_carnet["RC1"]["id"]
    body = {"date_debut": "2026-10-01", "date_fin": "2026-10-31", "mise": 1000, "cle": "R-TEST-2",
            "pages": [{"page": 1, "montant": 5000}]}
    r = client.post(f"/api/releves-carnet/cycles/{cid}", json=body, headers=h("chef1"))
    assert r.status_code == 422, r.text
    assert "déjà un relevé" in r.text


def test_releve_avec_ecart_est_enregistre_et_signale(client, h, cycles_carnet):
    cid = cycles_carnet["RC2"]["id"]
    body = {"date_debut": "2026-10-01", "date_fin": "2026-10-30", "mise": 1000, "cle": "R-TEST-3",
            "pages": [{"page": 1, "montant": 4000}]}
    assert client.post(f"/api/releves-carnet/cycles/{cid}", json=body, headers=h("chef1")).status_code == 201
    ligne = next(x for x in client.get("/api/releves-carnet/rapprochement", params={"statut": "ecart"}, headers=h("chef1")).json()
                 if x["cycle_id"] == cid)
    assert set(ligne["ecarts"]) == {"dates", "total"}
    assert ligne["ecart_total"] == 4000 - 5000


def test_pages_en_double_refusees(client, h, produits):
    cl = client.post("/api/clients", json={"nom": "Cli doublon page", "zone_id": None}, headers=h("chef1"))
    assert cl.status_code == 201, cl.text
    c = client.post("/api/cycles", json={"client_id": cl.json()["id"], "produit_id": produits["P1"], "mise": 1000,
                                         "date_debut": "2026-10-01", "date_fin": "2026-10-31"}, headers=h("chef1")).json()
    body = {"date_debut": "2026-10-01", "date_fin": "2026-10-31", "mise": 1000,
            "pages": [{"page": 1, "montant": 1000}, {"page": 1, "montant": 1000}]}
    assert client.post(f"/api/releves-carnet/cycles/{c['id']}", json=body, headers=h("chef1")).status_code >= 400


def test_caissier_ne_saisit_pas_de_releve(client, h, cycles_carnet):
    cid = cycles_carnet["RC2"]["id"]
    body = {"date_debut": "2026-10-01", "date_fin": "2026-10-31", "mise": 1000, "pages": [{"page": 1, "montant": 1000}]}
    assert client.post(f"/api/releves-carnet/cycles/{cid}", json=body, headers=h("caissier1")).status_code == 403


def test_statut_inconnu_refuse(client, h):
    assert client.get("/api/releves-carnet/rapprochement", params={"statut": "bizarre"}, headers=h("chef1")).status_code == 422
