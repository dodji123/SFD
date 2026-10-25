import datetime as dt

import pytest


@pytest.fixture(scope="module")
def guichet(client, h, produits):
    """Zone, agent, client, cycle de 5 collectes de 1 000 F (mise 1 000 F => net 4 000 F), caisse et session ouverte."""
    z = client.post("/api/zones", json={"code": "ZD", "libelle": "Zone retrait direct"}, headers=h("chef1")).json()
    ag = client.post("/api/agents", json={"matricule": "D-A1", "nom": "Agent D1"}, headers=h("chef1")).json()
    cl = client.post("/api/clients", json={"nom": "Cli Direct", "zone_id": z["id"]}, headers=h("chef1")).json()
    c = client.post("/api/cycles", json={"client_id": cl["id"], "produit_id": produits["P1"], "mise": 1000,
                                         "date_debut": "2026-10-01", "date_fin": "2026-10-31"}, headers=h("chef1")).json()
    d0 = dt.date(2026, 10, 1)
    lignes = [{"date_collecte": str(d0 + dt.timedelta(days=i)), "montant_collecte": 1000, "agent_id": ag["id"]} for i in range(5)]
    assert client.post(f"/api/cycles/{c['id']}/lignes", json={"lignes": lignes}, headers=h("chef1")).status_code == 201
    caisse = client.post("/api/caisses", json={"code": "CP-D"}, headers=h("chef1")).json()
    session = client.post(f"/api/caisses/{caisse['id']}/sessions", json={"date_session": "2026-10-10", "solde_ouverture": 1000000},
                          headers=h("caissier1")).json()
    return {"cycle": c, "session": session}


def test_retrait_partiel_en_especes_sans_cloture(client, h, guichet):
    cid = guichet["cycle"]["id"]
    r = client.post(f"/api/cycles/{cid}/retrait-direct", json={"nature": "retrait_client", "date": "2026-10-10", "montant": 1500,
                                                              "cloturer": False, "session_id": guichet["session"]["id"]},
                    headers=h("caissier1"))
    assert r.status_code == 201, r.text
    assert r.json()["statut"] == "execute" and r.json()["montant_paye"] == 1500
    assert r.json()["caissiere"] is not None
    cycle = client.get(f"/api/cycles/{cid}", headers=h("chef1")).json()
    assert cycle["statut"] == "en_cours"


def test_retrait_total_retire_le_cycle(client, h, guichet):
    cid = guichet["cycle"]["id"]
    r = client.post(f"/api/cycles/{cid}/retrait-direct", json={"nature": "retrait_client", "date": "2026-10-20",
                                                              "session_id": guichet["session"]["id"]}, headers=h("caissier1"))
    assert r.status_code == 201, r.text
    assert r.json()["montant_paye"] == 2500
    cycle = client.get(f"/api/cycles/{cid}", headers=h("chef1")).json()
    assert cycle["statut"] == "retire"


def test_sans_session_refuse_pour_especes(client, h, guichet):
    cid = guichet["cycle"]["id"]
    r = client.post(f"/api/cycles/{cid}/retrait-direct", json={"nature": "retrait_client", "date": "2026-10-20"}, headers=h("caissier1"))
    assert r.status_code == 422
