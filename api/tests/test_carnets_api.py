import pytest

# Module sous test : carnets (routers/carnets.py, schema/48_carnets.sql) — stock, remise aux agents, attribution aux cycles


@pytest.fixture(scope="module")
def base(client, h):
    pa = client.post("/api/produits-epargne", json={"code": "CAA", "libelle": "Tontine A", "categorie": "collecte"}, headers=h("chef1")).json()
    pb = client.post("/api/produits-epargne", json={"code": "CAB", "libelle": "Tontine B", "categorie": "collecte"}, headers=h("chef1")).json()
    ag = client.post("/api/agents", json={"matricule": "CAR-A1", "nom": "Agent carnet"}, headers=h("chef1")).json()
    cl = client.post("/api/clients", json={"nom": "Cliente carnet"}, headers=h("chef1")).json()
    cy = {}
    for cle, p in (("a", pa), ("b", pb)):
        r = client.post("/api/cycles", json={"client_id": cl["id"], "produit_id": p["id"], "mise": 500, "type_cycle": 2, "date_debut": "2026-10-01", "date_fin": "2026-10-31"}, headers=h("chef1"))
        assert r.status_code == 201, r.text
        cy[cle] = r.json()
    return {"pa": pa, "pb": pb, "agent": ag, "cycle": cy}


def test_lot_stock_et_droits(client, h, base):
    corps = {"produit_id": base["pa"]["id"], "quantite": 5, "reference": "BL-1"}
    assert client.post("/api/carnets/lots", json=corps, headers=h("agent1")).status_code == 403
    assert client.post("/api/carnets/lots", json=corps, headers=h("auditeur")).status_code == 403            # lecture seule
    lot = client.post("/api/carnets/lots", json=corps, headers=h("chef1"))
    assert lot.status_code == 201, lot.text
    assert lot.json()["quantite"] == 5 and lot.json()["premier_numero"].endswith("CAA-000001") and lot.json()["dernier_numero"].endswith("CAA-000005")
    suite = client.post("/api/carnets/lots", json={**corps, "quantite": 2}, headers=h("chef1")).json()
    assert suite["premier_numero"].endswith("CAA-000006")                                                      # numérotation continue
    assert client.post("/api/carnets/lots", json={"produit_id": base["pb"]["id"], "quantite": 3}, headers=h("chef1")).status_code == 201
    stock = {s["produit"]: s for s in client.get("/api/carnets/stock", headers=h("auditeur")).json()}
    assert stock["CAA"]["en_stock"] == 7 and stock["CAB"]["en_stock"] == 3 and stock["CAA"]["reapprovisionner"] is True
    assert client.get("/api/carnets/stock", headers=h("chef2")).json() == []                                   # autre agence
    assert client.get("/api/carnets/stock", headers=h("agent1")).status_code == 403


def test_attribution_un_livret_par_produit_et_remplacement(client, h, base):
    liste = client.get("/api/carnets", params={"statut": "en_stock"}, headers=h("chef1")).json()
    ca = [c for c in liste if c["produit"] == "CAA"]
    cb = [c for c in liste if c["produit"] == "CAB"]
    cyc_a, cyc_b = base["cycle"]["a"]["id"], base["cycle"]["b"]["id"]
    # remise à un agent puis attribution
    r = client.post(f"/api/carnets/{ca[0]['id']}/remettre", json={"agent_id": base["agent"]["id"]}, headers=h("chef1"))
    assert r.status_code == 200 and r.json()["statut"] == "chez_agent"
    assert client.post(f"/api/carnets/{ca[0]['id']}/remettre", json={"agent_id": base["agent"]["id"]}, headers=h("chef1")).status_code == 422
    # le livret d'un autre produit est refusé
    assert client.post(f"/api/carnets/{cb[0]['id']}/attribuer", json={"cycle_id": cyc_a}, headers=h("chef1")).status_code == 422
    ok = client.post(f"/api/carnets/{ca[0]['id']}/attribuer", json={"cycle_id": cyc_a}, headers=h("chef1"))
    assert ok.status_code == 200 and ok.json()["statut"] == "attribue" and ok.json()["cycle"] == base["cycle"]["a"]["numero"] and ok.json()["client"] == "Cliente carnet"
    assert client.post(f"/api/carnets/{ca[1]['id']}/attribuer", json={"cycle_id": cyc_a}, headers=h("chef1")).status_code == 409      # un seul carnet par cycle
    assert client.post(f"/api/carnets/{cb[0]['id']}/attribuer", json={"cycle_id": cyc_b}, headers=h("chef1")).status_code == 200
    # perte (motif obligatoire) puis remplacement tracé
    assert client.post(f"/api/carnets/{ca[0]['id']}/declarer", json={"statut": "perdu", "motif": "pf"}, headers=h("chef1")).status_code == 422
    assert client.post(f"/api/carnets/{ca[0]['id']}/declarer", json={"statut": "perdu", "motif": "Perdu au marché"}, headers=h("chef1")).json()["statut"] == "perdu"
    remp = client.post(f"/api/carnets/{ca[1]['id']}/attribuer", json={"cycle_id": cyc_a, "remplace_id": ca[0]["id"]}, headers=h("chef1"))
    assert remp.status_code == 200 and remp.json()["remplace_id"] == ca[0]["id"]
    hist = client.get(f"/api/carnets/{ca[0]['id']}", headers=h("chef1")).json()["historique"]
    assert [m["a_statut"] for m in hist] == ["en_stock", "chez_agent", "attribue", "perdu"]
    assert [c["numero"] for c in client.get(f"/api/cycles/{cyc_a}/carnets", headers=h("chef1")).json()] == [ca[0]["numero"], ca[1]["numero"]]
    assert client.post(f"/api/carnets/{cb[0]['id']}/terminer", headers=h("chef1")).json()["statut"] == "termine"
    # cloisonnement
    assert client.get(f"/api/carnets/{ca[0]['id']}", headers=h("chef2")).status_code == 404
    assert client.post(f"/api/carnets/{ca[2]['id']}/declarer", json={"statut": "annule", "motif": "Carnet défectueux"}, headers=h("chef2")).status_code == 404
