import pytest


@pytest.fixture(scope="module")
def jour():
    return "2026-01-05"


def test_ouverture_cloture_et_reouverture(client, h, jour):
    # chef2 : agence de son rattachement (pas de session ouverte dans la base de test à cette date)
    r = client.post("/api/journee/ouvrir", json={"date": jour}, headers=h("chef2"))
    assert r.status_code == 201, r.text
    # une seule journée ouverte à la fois
    assert client.post("/api/journee/ouvrir", json={"date": "2026-01-06"}, headers=h("chef2")).status_code == 422
    assert client.get("/api/journee", headers=h("chef2")).json()["jours"][0]["statut"] == "ouverte"

    assert client.post("/api/journee/cloturer", json={"date": jour}, headers=h("chef2")).status_code == 200
    assert client.get("/api/journee", headers=h("chef2")).json()["jours"][0]["statut"] == "cloturee"
    # une journée close ne se clôture pas une seconde fois
    assert client.post("/api/journee/cloturer", json={"date": jour}, headers=h("chef2")).status_code == 422

    # réouverture : motif obligatoire, réservée aux responsables de collecte
    assert client.post("/api/journee/rouvrir", json={"date": jour}, headers=h("chef2")).status_code == 422
    assert client.post("/api/journee/rouvrir", json={"date": jour, "motif": "erreur de saisie"}, headers=h("caissier1")).status_code == 403
    r = client.post("/api/journee/rouvrir", json={"date": jour, "motif": "erreur de saisie"}, headers=h("chef2"))
    assert r.status_code == 200, r.text
    assert client.get("/api/journee", headers=h("chef2")).json()["jours"][0]["statut"] == "ouverte"


def test_ouverture_refusee_pour_une_date_future(client, h):
    assert client.post("/api/journee/ouvrir", json={"date": "2099-01-01"}, headers=h("chef2")).status_code == 422
