import pytest


@pytest.fixture(scope="module")
def session(client, h, agences):
    caisse = client.post("/api/caisses", json={"code": "CK1", "type": "guichet"}, headers=h("chef1")).json()
    s = client.post(f"/api/caisses/{caisse['id']}/sessions", json={"date_session": "2026-11-05", "solde_ouverture": 1000000,
                                                                   "billetage": {"10000": 100}}, headers=h("caissier1"))
    assert s.status_code == 201, s.text
    return s.json()


def test_ouverture_et_unicite(client, h, session):
    assert session["statut"] == "ouverte" and session["solde_theorique"] == 1000000
    r = client.post(f"/api/caisses/{session['caisse_id']}/sessions", json={"date_session": "2026-11-05", "solde_ouverture": 5}, headers=h("caissier1"))
    assert r.status_code == 422 and "session ouverte" in r.json()["detail"]   # une seule session ouverte par caisse


def test_operations_et_solde_theorique(client, h, session):
    sid = session["id"]
    assert client.post(f"/api/sessions/{sid}/operations", json={"type": "decaissement", "motif": "deblocage_credit", "montant": 10000}, headers=h("caissier1")).status_code == 201
    r = client.post(f"/api/sessions/{sid}/operations", json={"type": "encaissement", "motif": "remboursement_credit", "montant": 5100}, headers=h("caissier1"))
    assert r.json()["encaissements"] == 5100 and r.json()["decaissements"] == 10000 and r.json()["solde_theorique"] == 995100
    r = client.post(f"/api/sessions/{sid}/operations", json={"type": "decaissement", "motif": "x", "montant": 5000000}, headers=h("caissier1"))
    assert r.status_code == 422 and "insuffisante" in r.json()["detail"]
    assert client.post(f"/api/sessions/{sid}/operations", json={"type": "encaissement", "motif": "x", "montant": 0}, headers=h("caissier1")).status_code == 422
    d = client.get(f"/api/sessions/{sid}", headers=h("chef1")).json()
    assert [o["motif"] for o in d["operations"]] == ["deblocage_credit", "remboursement_credit"]


def test_droits_et_cloisonnement(client, h, session):
    sid = session["id"]
    assert client.post(f"/api/sessions/{sid}/operations", json={"type": "encaissement", "motif": "x", "montant": 10}, headers=h("agent1")).status_code == 403
    assert client.get(f"/api/sessions/{sid}", headers=h("caissier2")).status_code == 404
    assert client.post(f"/api/sessions/{sid}/operations", json={"type": "encaissement", "motif": "x", "montant": 10}, headers=h("caissier2")).status_code == 404
    assert client.get(f"/api/sessions/{sid}", headers=h("comptable")).status_code == 200
    assert sid in [s["id"] for s in client.get("/api/sessions", params={"statut": "ouverte"}, headers=h("chef1")).json()]
    assert client.get("/api/sessions", headers=h("caissier2")).json() == []


def test_fermeture_avec_ecart(client, h, session):
    sid = session["id"]
    r = client.post(f"/api/sessions/{sid}/fermer", json={"solde_compte": 995000}, headers=h("caissier1"))
    assert r.status_code == 200 and r.json()["ecart"] == -100 and r.json()["statut"] == "fermee"
    assert client.post(f"/api/sessions/{sid}/operations", json={"type": "encaissement", "motif": "x", "montant": 10}, headers=h("caissier1")).status_code == 422
    assert client.post(f"/api/sessions/{sid}/fermer", json={"solde_compte": 1}, headers=h("caissier1")).status_code == 422
