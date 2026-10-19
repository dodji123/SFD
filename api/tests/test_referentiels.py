import pytest


@pytest.fixture(scope="module")
def base(client, h, agences, produits):
    """Zone, agent et client de l'agence 1 (les produits viennent de la fixture de session)."""
    z = client.post("/api/zones", json={"code": "Z1", "libelle": "Marché"}, headers=h("chef1"))
    assert z.status_code == 201, z.text
    ag = client.post("/api/agents", json={"matricule": "A01", "nom": "Ama"}, headers=h("chef1")).json()
    c = client.post("/api/clients", json={"nom": "Client Un", "zone_id": z.json()["id"], "telephone": "90000001"}, headers=h("chef1"))
    assert c.status_code == 201, c.text
    return {"zone": z.json(), "agent": ag, "produits": produits, "client": c.json()}


def test_agences_cloisonnees(client, h, agences, base):
    assert client.post("/api/agences", json={"code": "T3", "libelle": "Autre"}, headers=h("chef1")).status_code == 403
    assert client.post("/api/agences", json={"code": "T3", "libelle": "Autre"}, headers=h("admin")).status_code == 201
    mes = client.get("/api/agences", headers=h("chef1")).json()
    assert [a["id"] for a in mes] == [agences["a1"]]
    assert len(client.get("/api/agences", headers=h("admin")).json()) >= 3


def test_siege_doit_designer_l_agence(client, h, agences):
    corps = {"code": "ZS", "libelle": "Zone siège"}
    assert client.post("/api/zones", json=corps, headers=h("admin")).status_code == 400
    assert client.post("/api/zones", json={**corps, "agence_id": agences["a2"]}, headers=h("admin")).status_code == 201
    # un utilisateur d'agence ne peut pas viser une autre agence
    assert client.post("/api/zones", json={**corps, "code": "ZX", "agence_id": agences["a2"]}, headers=h("chef1")).status_code == 403


def test_client_numerotation_et_recherche(client, h, base):
    assert base["client"]["numero"].startswith("CL-T1-")
    r = client.get("/api/clients", params={"q": "client un"}, headers=h("caissier1"))
    assert r.status_code == 200 and [c["nom"] for c in r.json()] == ["Client Un"]
    assert client.get("/api/clients", params={"q": "introuvable-xyz"}, headers=h("chef1")).json() == []
    # recherche par téléphone
    assert len(client.get("/api/clients", params={"q": "90000001"}, headers=h("chef1")).json()) == 1


def test_isolation_entre_agences(client, h, base, agences):
    cid = base["client"]["id"]
    assert client.get(f"/api/clients/{cid}", headers=h("chef1")).status_code == 200
    assert client.get(f"/api/clients/{cid}", headers=h("chef2")).status_code == 404
    assert client.get(f"/api/clients/{cid}", headers=h("admin")).status_code == 200
    assert client.patch(f"/api/clients/{cid}", json={"nom": "X"}, headers=h("chef2")).status_code == 404
    assert cid not in [c["id"] for c in client.get("/api/clients", headers=h("chef2")).json()]
    # viser explicitement l'agence d'un autre : refusé
    assert client.get("/api/clients", params={"agence_id": agences["a1"]}, headers=h("chef2")).status_code == 403


def test_droits_sur_les_clients(client, h):
    assert client.post("/api/clients", json={"nom": "Interdit"}, headers=h("caissier1")).status_code == 403
    assert client.post("/api/clients", json={"nom": "Interdit"}, headers=h("auditeur")).status_code == 403
    # l'auditeur (siège) lit toutes les agences
    r = client.get("/api/clients", headers=h("auditeur"))
    assert r.status_code == 200 and len(r.json()) >= 1


def test_zone_d_une_autre_agence_refusee(client, h, agences):
    zone2 = client.post("/api/zones", json={"code": "ZB", "libelle": "B"}, headers=h("chef2")).json()
    r = client.post("/api/clients", json={"nom": "Mauvaise zone", "zone_id": zone2["id"]}, headers=h("chef1"))
    assert r.status_code == 422


def test_produits(client, h, base):
    assert client.post("/api/produits-epargne", json={"code": "ZZ", "libelle": "x", "categorie": "classique"}, headers=h("caissier1")).status_code == 403
    assert client.post("/api/produits-epargne", json={"code": "P1", "libelle": "doublon", "categorie": "collecte", "type_cycle": 1}, headers=h("admin")).status_code == 409
    # une collecte sans type de cycle viole une règle du schéma
    assert client.post("/api/produits-epargne", json={"code": "Q1", "libelle": "x", "categorie": "collecte"}, headers=h("admin")).status_code == 422
    assert len(client.get("/api/produits-epargne", params={"categorie": "collecte"}, headers=h("caissier1")).json()) == 3


def test_collectrice_et_affectations(client, h, base, agences):
    k = client.post("/api/collectrices", json={"matricule": "K1", "nom": "Kofi"}, headers=h("chef1")).json()
    zid = base["zone"]["id"]
    r = client.post(f"/api/zones/{zid}/affectations", json={"collectrice_id": k["id"], "date_debut": "2026-01-01", "date_fin": "2026-06-30"}, headers=h("chef1"))
    assert r.status_code == 201
    # chevauchement refusé
    r = client.post(f"/api/zones/{zid}/affectations", json={"collectrice_id": k["id"], "date_debut": "2026-06-30"}, headers=h("chef1"))
    assert r.status_code == 409
    assert client.post(f"/api/zones/{zid}/affectations", json={"collectrice_id": k["id"], "date_debut": "2026-07-01"}, headers=h("chef1")).status_code == 201
    # collectrice d'une autre agence : introuvable
    k2 = client.post("/api/collectrices", json={"matricule": "K2", "nom": "Autre"}, headers=h("chef2")).json()
    assert client.post(f"/api/zones/{zid}/affectations", json={"collectrice_id": k2["id"], "date_debut": "2027-01-01"}, headers=h("chef1")).status_code == 404
    assert len(client.get(f"/api/zones/{zid}/affectations", headers=h("chef1")).json()) == 2


def test_comptes_epargne(client, h, base):
    cid, pid_collecte, pid_cl = base["client"]["id"], base["produits"]["P1"], base["produits"]["CL"]
    assert client.post("/api/comptes-epargne", json={"client_id": cid, "produit_id": pid_collecte}, headers=h("caissier1")).status_code == 422
    assert client.post("/api/comptes-epargne", json={"client_id": cid, "produit_id": pid_cl}, headers=h("agent1")).status_code == 403
    c = client.post("/api/comptes-epargne", json={"client_id": cid, "produit_id": pid_cl}, headers=h("caissier1"))
    assert c.status_code == 201 and c.json()["numero"].startswith("CE-T1-") and c.json()["solde"] == 0
    cpt = c.json()["id"]
    r = client.post(f"/api/comptes-epargne/{cpt}/depot", json={"montant": 100000, "libelle": "Premier dépôt"}, headers=h("caissier1"))
    assert r.status_code == 201 and r.json()["solde"] == 100000 and r.json()["disponible"] == 95000
    r = client.post(f"/api/comptes-epargne/{cpt}/retrait", json={"montant": 95001}, headers=h("caissier1"))
    assert r.status_code == 422 and "disponible" in r.json()["detail"]
    r = client.post(f"/api/comptes-epargne/{cpt}/retrait", json={"montant": 95000}, headers=h("caissier1"))
    assert r.status_code == 201 and r.json()["solde"] == 5000 and r.json()["disponible"] == 0
    assert client.post(f"/api/comptes-epargne/{cpt}/depot", json={"montant": 0}, headers=h("caissier1")).status_code == 422
    mv = client.get(f"/api/comptes-epargne/{cpt}/mouvements", headers=h("caissier1")).json()
    assert [m["type"] for m in mv] == ["retrait", "depot"] and mv[0]["sens"] == -1
    assert client.get(f"/api/comptes-epargne/{cpt}", headers=h("caissier2")).status_code == 404
    # l'auditeur lit mais n'écrit pas
    assert client.get(f"/api/comptes-epargne/{cpt}", headers=h("auditeur")).status_code == 200
    assert client.post(f"/api/comptes-epargne/{cpt}/depot", json={"montant": 10}, headers=h("auditeur")).status_code == 403


def test_les_operations_sont_auditees_avec_l_utilisateur(client, h, sql, base):
    cid = base["client"]["id"]
    c = client.post("/api/comptes-epargne", json={"client_id": cid, "produit_id": base["produits"]["CL"]}, headers=h("caissier1")).json()
    client.post(f"/api/comptes-epargne/{c['id']}/depot", json={"montant": 1234}, headers=h("caissier1"))
    rows = sql("SELECT utilisateur FROM audit_log WHERE table_name = 'mouvement_epargne' AND (apres->>'montant')::int = 1234")
    assert rows and rows[0]["utilisateur"] == "caissier1"
