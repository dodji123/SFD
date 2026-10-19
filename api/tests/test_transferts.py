import pytest


@pytest.fixture(scope="module")
def cadre(client, h, sql, agences, produits):
    """Agence 1 : zones ZA/ZB, trois clients ; agence 2 : zone ZC. Le client 'Mobile' a un compte d'épargne de 50 000 F."""
    za = client.post("/api/zones", json={"code": "TA", "libelle": "Zone A"}, headers=h("chef1")).json()["id"]
    zb = client.post("/api/zones", json={"code": "TB", "libelle": "Zone B"}, headers=h("chef1")).json()["id"]
    zc = client.post("/api/zones", json={"code": "TC", "libelle": "Zone C"}, headers=h("chef2")).json()["id"]
    cl = {n: client.post("/api/clients", json={"nom": n, "zone_id": za}, headers=h("chef1")).json() for n in ("Mobile", "Occupé", "Zonal")}
    ce = sql("INSERT INTO compte_epargne(agence_id, client_id, produit_id) VALUES (%s, %s, %s) RETURNING id",
             (agences["a1"], cl["Mobile"]["id"], produits["CL"]))[0]["id"]
    sql("INSERT INTO mouvement_epargne(compte_id, type, montant, date_operation) VALUES (%s, 'depot', 50000, '2026-10-05')", (ce,))
    sql("INSERT INTO cycle(agence_id, client_id, produit_id, type_cycle, mise_initiale, mise_courante, objectif, date_debut, date_fin) "
        "VALUES (%s, %s, %s, 1, 500, 500, 15500, '2026-10-01', '2026-10-31')", (agences["a1"], cl["Occupé"]["id"], produits["P1"]))
    return {"za": za, "zb": zb, "zc": zc, "cl": cl, "ce": ce}


def test_transfert_de_zone(client, h, cadre):
    cid = cadre["cl"]["Zonal"]["id"]
    r = client.post(f"/api/clients/{cid}/transfert-zone", json={"zone_id": cadre["zb"], "date": "2026-10-10", "motif": "déménagement"}, headers=h("chef1"))
    assert r.status_code == 201, r.text
    d = r.json()
    assert (d["type"], d["zone_source"], d["zone_dest"], d["motif"], d["utilisateur"]) == ("zone", "TA", "TB", "déménagement", "chef1")
    assert client.get(f"/api/clients/{cid}", headers=h("chef1")).json()["zone"] == "TB"
    # même zone, zone d'une autre agence, date non postérieure : refusés
    assert client.post(f"/api/clients/{cid}/transfert-zone", json={"zone_id": cadre["zb"]}, headers=h("chef1")).status_code == 422
    assert client.post(f"/api/clients/{cid}/transfert-zone", json={"zone_id": cadre["zc"]}, headers=h("chef1")).status_code == 422
    assert client.post(f"/api/clients/{cid}/transfert-zone", json={"zone_id": cadre["za"], "date": "2026-10-10"}, headers=h("chef1")).status_code == 422
    hist = client.get(f"/api/clients/{cid}/transferts", headers=h("chef1")).json()
    assert [(t["type"], t["zone_dest"]) for t in hist] == [("zone", "TB")]


def test_modification_de_fiche_passe_par_le_transfert(client, h, cadre):
    cid = cadre["cl"]["Occupé"]["id"]
    r = client.patch(f"/api/clients/{cid}", json={"zone_id": cadre["zb"], "telephone": "90111111"}, headers=h("chef1"))
    assert r.status_code == 200 and r.json()["zone_id"] == cadre["zb"] and r.json()["telephone"] == "90111111"
    assert len(client.get(f"/api/clients/{cid}/transferts", headers=h("chef1")).json()) == 1
    assert client.patch(f"/api/clients/{cid}", json={"zone_id": None}, headers=h("chef1")).status_code == 422


def test_droits_transfert(client, h, cadre):
    cid = cadre["cl"]["Zonal"]["id"]
    assert client.post(f"/api/clients/{cid}/transfert-zone", json={"zone_id": cadre["za"], "date": "2026-10-20"}, headers=h("caissier1")).status_code == 403
    assert client.post(f"/api/clients/{cid}/transfert-zone", json={"zone_id": cadre["za"], "date": "2026-10-20"}, headers=h("chef2")).status_code == 404
    # le chef d'agence ne transfère pas d'agence (siège seulement)
    assert client.post(f"/api/clients/{cid}/transfert-agence", json={"agence_id": 1}, headers=h("chef1")).status_code == 403


def test_transfert_agence_refuse_si_operation_en_cours(client, h, cadre, agences):
    cid = cadre["cl"]["Occupé"]["id"]
    r = client.post(f"/api/clients/{cid}/transfert-agence", json={"agence_id": agences["a2"], "zone_id": cadre["zc"]}, headers=h("admin"))
    assert r.status_code == 422 and "cycle" in r.json()["detail"]


def test_transfert_agence(client, h, cadre, agences):
    cid = cadre["cl"]["Mobile"]["id"]
    ancien = client.get(f"/api/clients/{cid}", headers=h("chef1")).json()["numero"]
    r = client.post(f"/api/clients/{cid}/transfert-agence", json={"agence_id": agences["a2"], "zone_id": cadre["zc"], "date": "2026-10-15", "motif": "mutation"}, headers=h("admin"))
    assert r.status_code == 201, r.text
    d = r.json()
    assert d["type"] == "agence" and d["agence_source"] == "T1" and d["agence_dest"] == "T2" and d["zone_dest"] == "TC"
    assert d["ancien_numero"] == ancien and d["nouveau_numero"].startswith("CL-T2-") and d["solde_epargne"] == 50000
    assert d["comptes"][0]["nouveau"].startswith("CE-T2-")
    # le client change de périmètre : visible par l'agence 2, plus par l'agence 1
    assert client.get(f"/api/clients/{cid}", headers=h("chef2")).status_code == 200
    assert client.get(f"/api/clients/{cid}", headers=h("chef1")).status_code == 404
    comptes = client.get(f"/api/clients/{cid}", headers=h("chef2")).json()["comptes"]
    assert comptes[0]["solde"] == 50000
    # l'agence d'origine garde la trace du départ
    assert [t["type"] for t in client.get(f"/api/clients/{cid}/transferts", headers=h("chef1")).json()] == ["agence"]
    assert any(t["client_id"] == cid for t in client.get("/api/transferts-clients", params={"type": "agence"}, headers=h("chef1")).json())
    assert any(t["client_id"] == cid for t in client.get("/api/transferts-clients", headers=h("chef2")).json())
    # un chef d'agence ne voit pas les transferts qui ne le concernent pas
    assert all(cid != t["client_id"] for t in client.get("/api/transferts-clients", params={"agence_id": agences["a1"]}, headers=h("chef1")).json()
               if t["agence_source"] != "T1" and t["agence_dest"] != "T1")
    assert client.get("/api/transferts-clients", params={"type": "x"}, headers=h("admin")).status_code == 422
