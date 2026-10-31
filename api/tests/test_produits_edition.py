def _zone_et_client(client, h, code):
    z = client.post("/api/zones", json={"code": code, "libelle": f"Zone {code}"}, headers=h("chef1"))
    assert z.status_code == 201, z.text
    c = client.post("/api/clients", json={"nom": f"Client {code}", "zone_id": z.json()["id"]}, headers=h("chef1"))
    assert c.status_code == 201, c.text
    return c.json()


def test_produit_sans_donnees_modifiable_puis_supprimable(client, h, agences):
    p = client.post("/api/produits-epargne", json={"code": "EDT", "libelle": "En création", "categorie": "collecte", "type_cycle": 1},
                    headers=h("chef1"))
    assert p.status_code == 201, p.text
    pid = p.json()["id"]
    # sans donnée : la nature et le type de cycle peuvent changer, le libellé aussi
    r = client.patch(f"/api/produits-epargne/{pid}", json={"libelle": "Renommé", "categorie": "classique", "type_cycle": None, "solde_minimum": 2000},
                     headers=h("chef1"))
    assert r.status_code == 200, r.text
    assert r.json()["libelle"] == "Renommé" and r.json()["categorie"] == "classique" and r.json()["type_cycle"] is None
    assert r.json()["solde_minimum"] == 2000
    assert client.delete(f"/api/produits-epargne/{pid}", headers=h("chef1")).status_code == 204
    codes = [x["code"] for x in client.get("/api/produits-epargne", headers=h("chef1")).json()]
    assert "EDT" not in codes
    assert client.delete(f"/api/produits-epargne/{pid}", headers=h("chef1")).status_code == 404


def test_produit_avec_donnees_ne_se_supprime_ni_ne_change_de_nature(client, h, produits):
    cl = _zone_et_client(client, h, "ZED")
    compte = client.post("/api/comptes-epargne", json={"client_id": cl["id"], "produit_id": produits["CL"]}, headers=h("chef1"))
    assert compte.status_code == 201, compte.text
    r = client.delete(f"/api/produits-epargne/{produits['CL']}", headers=h("chef1"))
    assert r.status_code == 409 and "désactivez-le" in r.json()["detail"]
    r = client.patch(f"/api/produits-epargne/{produits['CL']}", json={"categorie": "collecte", "type_cycle": 1}, headers=h("chef1"))
    assert r.status_code == 409
    # le libellé reste modifiable même avec des données
    assert client.patch(f"/api/produits-epargne/{produits['CL']}", json={"libelle": "CL"}, headers=h("chef1")).status_code == 200


def test_edition_produit_reserve_au_referentiel(client, h, produits):
    assert client.delete(f"/api/produits-epargne/{produits['P1']}", headers=h("caissier1")).status_code == 403
    assert client.patch(f"/api/produits-epargne/{produits['P1']}", json={"libelle": "x"}, headers=h("caissier1")).status_code == 403
