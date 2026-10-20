import pytest

from tests.helpers import PWD

# Module sous test : routers/reseaux.py et le périmètre « réseau » de auth.py (agence_scope / agence_filter / verifier_agence)


@pytest.fixture(scope="module")
def reseau(client, h, sql, agences):
    a3 = sql("INSERT INTO agence(code, libelle) VALUES ('RS3', 'Agence réseau 3') RETURNING id")[0]["id"]
    r = client.post("/api/reseaux", json={"code": "RS1", "libelle": "Réseau test"}, headers=h("admin"))
    assert r.status_code == 201, r.text
    rid = r.json()["id"]
    ags = client.put(f"/api/reseaux/{rid}/agences", json={"agence_ids": [agences["a1"], a3]}, headers=h("admin"))
    assert ags.status_code == 200 and len(ags.json()) == 2
    corps = {"login": "coord1", "nom": "Coordinateur", "role": "coordinateur", "reseau_id": rid, "mot_de_passe": "Coord-Passe-123"}
    assert client.post("/api/utilisateurs", json=corps, headers=h("admin")).status_code == 201
    # le mot de passe posé par l'administrateur est temporaire : on le change comme le ferait l'intéressé
    t = client.post("/api/auth/login", json={"login": "coord1", "mot_de_passe": "Coord-Passe-123"}).json()["access_token"]
    assert client.post("/api/auth/mot-de-passe", json={"ancien": "Coord-Passe-123", "nouveau": "Coord-Passe-456"}, headers={"Authorization": "Bearer " + t}).status_code == 204
    return {"id": rid, "a1": agences["a1"], "a2": agences["a2"], "a3": a3}


@pytest.fixture(scope="module")
def coord(client, reseau):
    r = client.post("/api/auth/login", json={"login": "coord1", "mot_de_passe": "Coord-Passe-456"})
    assert r.status_code == 200, r.text
    return {"Authorization": "Bearer " + r.json()["access_token"]}


def test_gestion_des_reseaux_reservee_a_l_admin(client, h, reseau):
    assert client.post("/api/reseaux", json={"code": "ZZ", "libelle": "x"}, headers=h("directeur")).status_code == 403
    assert client.get("/api/reseaux", headers=h("chef1")).status_code == 403
    assert client.patch(f"/api/reseaux/{reseau['id']}", json={}, headers=h("admin")).status_code == 422
    liste = client.get("/api/reseaux", headers=h("directeur")).json()
    assert any(r["code"] == "RS1" and r["nb_agences"] == 2 for r in liste)


def test_coordinateur_exige_un_reseau_et_pas_d_agence(client, h, reseau):
    base = {"login": "coord-mauvais", "nom": "X", "role": "coordinateur", "mot_de_passe": "Coord-Passe-123"}
    assert client.post("/api/utilisateurs", json=base, headers=h("admin")).status_code == 422                       # ni réseau ni agence
    assert client.post("/api/utilisateurs", json={**base, "agence_id": reseau["a1"]}, headers=h("admin")).status_code == 422
    assert client.post("/api/utilisateurs", json={**base, "agence_id": reseau["a1"], "reseau_id": reseau["id"], "role": "caissier"}, headers=h("admin")).status_code == 422   # agence ET réseau


def test_le_perimetre_du_coordinateur(client, coord, reseau):
    me = client.get("/api/auth/me", headers=coord).json()
    assert me["reseau_id"] == reseau["id"] and me["agence_id"] is None and sorted(me["agences"]) == sorted([reseau["a1"], reseau["a3"]])
    agences = client.get("/api/agences", headers=coord).json()
    assert {a["id"] for a in agences} == {reseau["a1"], reseau["a3"]}                       # pas l'agence hors réseau


def test_cloisonnement_par_agence_pour_un_utilisateur_de_reseau(client, h, coord, reseau):
    c1 = client.post("/api/clients", json={"nom": "Client réseau A1"}, headers=h("chef1")).json()
    c2 = client.post("/api/clients", json={"nom": "Client hors réseau A2"}, headers=h("chef2")).json()
    # lecture d'une ligne : agence du réseau oui, hors réseau non (404, on ne révèle rien)
    assert client.get(f"/api/clients/{c1['id']}", headers=coord).status_code == 200
    assert client.get(f"/api/clients/{c2['id']}", headers=coord).status_code == 404
    # liste : il doit désigner l'agence (pas de fuite « toutes les agences »), et seulement une agence de son réseau
    assert client.get("/api/clients", headers=coord).status_code == 400
    assert client.get(f"/api/clients?agence_id={reseau['a2']}", headers=coord).status_code == 403
    r = client.get(f"/api/clients?agence_id={reseau['a1']}", headers=coord)
    assert r.status_code == 200 and any(c["id"] == c1["id"] for c in r.json()) and all(c["id"] != c2["id"] for c in r.json())
    # création : dans une agence du réseau seulement
    ok = client.post("/api/clients", json={"nom": "Créé par le coordinateur", "agence_id": reseau["a3"]}, headers=coord)
    assert ok.status_code == 201 and ok.json()["agence_id"] == reseau["a3"]
    assert client.post("/api/clients", json={"nom": "Hors réseau", "agence_id": reseau["a2"]}, headers=coord).status_code == 403
    assert client.post("/api/clients", json={"nom": "Sans agence"}, headers=coord).status_code == 400


def test_etats_consolides_reserves_au_siege(client, coord):
    r = client.get("/api/etats/consolide?du=2026-01-01&au=2026-12-31", headers=coord)
    assert r.status_code in (403,)                                                         # ni la perm, ni le périmètre siège


def test_synthese_du_reseau(client, h, coord, reseau):
    s = client.get(f"/api/reseaux/{reseau['id']}/synthese", headers=coord)
    assert s.status_code == 200, s.text
    corps = s.json()
    assert {a["agence_id"] for a in corps["agences"]} == {reseau["a1"], reseau["a3"]}
    assert corps["total"]["clients"] >= 2 and "par_pct" in corps["total"]
    # un autre réseau reste invisible au coordinateur
    autre = client.post("/api/reseaux", json={"code": "RS2", "libelle": "Autre réseau"}, headers=h("admin")).json()
    client.put(f"/api/reseaux/{autre['id']}/agences", json={"agence_ids": [reseau["a2"]]}, headers=h("admin"))
    assert client.get(f"/api/reseaux/{autre['id']}/synthese", headers=coord).status_code == 404
    assert [r["code"] for r in client.get("/api/reseaux", headers=coord).json()] == ["RS1"]
    assert client.get(f"/api/reseaux/{autre['id']}/synthese", headers=h("directeur")).status_code == 200


def test_utilisateur_d_agence_reste_enferme(client, h, reseau):
    me = client.get("/api/auth/me", headers=h("chef1")).json()
    assert me["agences"] == [reseau["a1"]] and me["reseau_id"] is None
    assert client.get(f"/api/clients?agence_id={reseau['a3']}", headers=h("chef1")).status_code == 403   # même réseau, mais pas son agence
    siege = client.get("/api/auth/me", headers=h("directeur")).json()
    assert siege["agences"] is None


def test_retirer_une_agence_du_reseau_retire_l_acces(client, h, coord, reseau):
    c = client.post("/api/clients", json={"nom": "Client agence sortante", "agence_id": reseau["a3"]}, headers=coord).json()
    assert client.put(f"/api/reseaux/{reseau['id']}/agences", json={"agence_ids": [reseau["a1"]]}, headers=h("admin")).status_code == 200
    assert client.get(f"/api/clients/{c['id']}", headers=coord).status_code == 404
    client.put(f"/api/reseaux/{reseau['id']}/agences", json={"agence_ids": [reseau["a1"], reseau["a3"]]}, headers=h("admin"))
