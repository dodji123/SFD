import pytest


@pytest.fixture(scope="module")
def exercice(client, h, agences):
    r = client.post("/api/compta/exercices", json={"code": "2026", "date_debut": "2026-01-01", "date_fin": "2026-12-31"}, headers=h("comptable"))
    assert r.status_code == 201, r.text
    return r.json()


def _piece(client, h, agences, lignes=None, date="2026-10-08", login="comptable", **kw):
    corps = {"agence_id": agences["a1"], "journal": "OD", "date_piece": date, "libelle": "Loyer d'octobre",
             "lignes": lignes or [{"compte_code": "6212", "debit": 50000}, {"compte_code": "1011", "credit": 50000}], **kw}
    return client.post("/api/compta/pieces", json=corps, headers=h(login))


def test_exercices(client, h, exercice):
    assert exercice["statut"] == "ouvert"
    r = client.post("/api/compta/exercices", json={"code": "X", "date_debut": "2026-12-01", "date_fin": "2027-06-30"}, headers=h("comptable"))
    assert r.status_code == 409                                         # chevauchement
    assert client.post("/api/compta/exercices", json={"code": "Y", "date_debut": "2030-01-01", "date_fin": "2030-12-31"}, headers=h("chef1")).status_code == 403
    assert client.get("/api/compta/exercices", headers=h("auditeur")).status_code == 200
    assert client.get("/api/compta/exercices", headers=h("caissier1")).status_code == 403


def test_plan_de_comptes(client, h):
    r = client.get("/api/compta/comptes", params={"q": "1011"}, headers=h("comptable")).json()
    assert [c["code"] for c in r] == ["1011"] and r[0]["imputable"] is True
    sans = client.get("/api/compta/comptes", params={"classe": "9", "limit": 1500}, headers=h("comptable")).json()
    assert len(sans) == 87
    assert all(c["classe"] == "9" for c in sans)
    epargne = client.get("/api/compta/comptes", params={"q": "épargne"}, headers=h("comptable")).json()
    assert any(c["code"] == "25311" for c in epargne)
    assert client.get("/api/compta/comptes", params={"classe": "x"}, headers=h("comptable")).status_code == 422
    assert client.get("/api/compta/comptes", params={"imputable": "false", "q": "253"}, headers=h("comptable")).json()[0]["imputable"] is False


def test_saisie_manuelle_et_controles(client, h, agences, exercice):
    r = _piece(client, h, agences)
    assert r.status_code == 201, r.text
    p = r.json()
    assert p["numero"].startswith("PC-T1-2026-") and p["total"] == 50000 and p["origine"] == "manuelle"
    assert [(e["compte_code"], e["debit"], e["credit"]) for e in p["ecritures"]] == [("6212", 50000, 0), ("1011", 0, 50000)]
    # déséquilibrée
    r = _piece(client, h, agences, lignes=[{"compte_code": "6212", "debit": 100}, {"compte_code": "1011", "credit": 90}])
    assert r.status_code == 422 and "déséquilibrée" in r.json()["detail"]
    # compte non imputable
    r = _piece(client, h, agences, lignes=[{"compte_code": "253", "debit": 10}, {"compte_code": "1011", "credit": 10}])
    assert r.status_code == 422 and "imputable" in r.json()["detail"]
    # compte inconnu, date hors exercice, journal inconnu, ligne ambiguë, une seule ligne
    assert _piece(client, h, agences, lignes=[{"compte_code": "9999999", "debit": 1}, {"compte_code": "1011", "credit": 1}]).status_code == 409
    assert _piece(client, h, agences, date="2035-01-01").status_code == 422
    assert _piece(client, h, agences, journal="XXX").status_code == 422
    assert _piece(client, h, agences, lignes=[{"compte_code": "6212", "debit": 1, "credit": 1}, {"compte_code": "1011", "credit": 1}]).status_code == 422
    assert _piece(client, h, agences, lignes=[{"compte_code": "6212", "debit": 1}]).status_code == 422
    # droits
    assert _piece(client, h, agences, login="chef1").status_code == 403
    assert _piece(client, h, agences, login="auditeur").status_code == 403
    # une pièce refusée ne laisse rien derrière elle
    assert len(client.get("/api/compta/pieces", params={"agence_id": agences["a1"]}, headers=h("comptable")).json()) == 1


def test_etats_et_cloisonnement(client, h, agences, exercice):
    a1 = agences["a1"]
    p = client.get("/api/compta/pieces", params={"agence_id": a1}, headers=h("comptable")).json()[0]
    b = client.get("/api/compta/balance", params={"du": "2026-01-01", "au": "2026-12-31", "agence_id": a1}, headers=h("comptable")).json()
    assert b["total_debit"] == b["total_credit"] == 50000
    assert {l["compte"]: l["solde_debiteur"] - l["solde_crediteur"] for l in b["lignes"]} == {"6212": 50000, "1011": -50000}
    gl = client.get("/api/compta/grand-livre", params={"compte": "1011", "du": "2026-01-01", "au": "2026-12-31", "agence_id": a1}, headers=h("comptable")).json()
    assert [(l["credit"], l["solde_cumule"]) for l in gl] == [(50000, -50000)]
    r = client.get("/api/compta/resultat", params={"du": "2026-01-01", "au": "2026-12-31", "agence_id": a1}, headers=h("comptable")).json()
    assert r["resultat"] == -50000                                       # une charge de 50000, aucun produit
    # cloisonnement : l'autre agence ne voit rien
    assert client.get("/api/compta/pieces", headers=h("chef2")).json() == []
    assert client.get(f"/api/compta/pieces/{p['id']}", headers=h("chef2")).status_code == 404
    assert client.get(f"/api/compta/pieces/{p['id']}", headers=h("chef1")).status_code == 200
    assert client.get("/api/compta/balance", params={"du": "2026-01-01", "au": "2026-12-31"}, headers=h("chef2")).json()["lignes"] == []
    assert client.get("/api/compta/pieces", params={"agence_id": a1}, headers=h("chef2")).status_code == 403


def test_contrepassation(client, h, agences, exercice):
    a1 = agences["a1"]
    p = client.get("/api/compta/pieces", params={"agence_id": a1}, headers=h("comptable")).json()[0]
    assert client.post(f"/api/compta/pieces/{p['id']}/contrepasser", json={}, headers=h("chef1")).status_code == 403
    r = client.post(f"/api/compta/pieces/{p['id']}/contrepasser", json={"date": "2026-10-20", "motif": "erreur de saisie"}, headers=h("comptable"))
    assert r.status_code == 201 and r.json()["origine"] == "contrepassation"
    assert [(e["debit"], e["credit"]) for e in r.json()["ecritures"]] == [(0, 50000), (50000, 0)]
    assert client.post(f"/api/compta/pieces/{p['id']}/contrepasser", json={}, headers=h("comptable")).status_code == 422
    b = client.get("/api/compta/balance", params={"du": "2026-01-01", "au": "2026-12-31", "agence_id": a1}, headers=h("comptable")).json()
    assert all(l["solde_debiteur"] == l["solde_crediteur"] == 0 for l in b["lignes"])


@pytest.fixture()
def compta_auto(client, h, agences, exercice):
    corps = {"valeur": "oui", "agence_id": agences["a1"]}
    assert client.put("/api/parametres/comptabilisation_auto", json=corps, headers=h("admin")).status_code == 200
    yield
    client.put("/api/parametres/comptabilisation_auto", json={"valeur": "non", "agence_id": agences["a1"]}, headers=h("admin"))


def test_comptabilisation_automatique(client, h, agences, produits, compta_auto):
    a1 = agences["a1"]
    cl = client.post("/api/clients", json={"nom": "Client compta"}, headers=h("chef1")).json()
    cpt = client.post("/api/comptes-epargne", json={"client_id": cl["id"], "produit_id": produits["CL"]}, headers=h("caissier1")).json()
    assert client.post(f"/api/comptes-epargne/{cpt['id']}/depot", json={"montant": 10000, "date_operation": "2026-10-09"}, headers=h("caissier1")).status_code == 201
    auto = [p for p in client.get("/api/compta/pieces", params={"agence_id": a1}, headers=h("comptable")).json() if p["origine"] == "auto"]
    assert len(auto) == 1 and auto[0]["evenement"] == "epargne_depot" and auto[0]["total"] == 10000 and auto[0]["journal"] == "CAI"
    d = client.get(f"/api/compta/pieces/{auto[0]['id']}", headers=h("comptable")).json()
    assert [(e["compte_code"], e["debit"], e["credit"]) for e in d["ecritures"]] == [("1011", 10000, 0), ("25111", 0, 10000)]
    # sans exercice pour la date, l'opération est refusée (rien n'est enregistré à moitié)
    r = client.post(f"/api/comptes-epargne/{cpt['id']}/depot", json={"montant": 500, "date_operation": "2019-06-01"}, headers=h("caissier1"))
    assert r.status_code == 422 and "exercice" in r.json()["detail"]
    assert client.get(f"/api/comptes-epargne/{cpt['id']}", headers=h("caissier1")).json()["solde"] == 10000
    assert len(client.get("/api/compta/regles", headers=h("comptable")).json()) >= 40


def test_automatique_desactive_par_defaut_et_cloture(client, h, agences, produits, exercice):
    cl = client.post("/api/clients", json={"nom": "Client sans compta"}, headers=h("chef1")).json()
    cpt = client.post("/api/comptes-epargne", json={"client_id": cl["id"], "produit_id": produits["CL"]}, headers=h("caissier1")).json()
    avant = len(client.get("/api/compta/pieces", params={"agence_id": agences["a1"], "limit": 500}, headers=h("comptable")).json())
    client.post(f"/api/comptes-epargne/{cpt['id']}/depot", json={"montant": 700, "date_operation": "2019-06-01"}, headers=h("caissier1"))
    assert len(client.get("/api/compta/pieces", params={"agence_id": agences["a1"], "limit": 500}, headers=h("comptable")).json()) == avant
    # clôture : plus aucune écriture sur l'exercice
    assert client.post(f"/api/compta/exercices/{exercice['id']}/cloturer", headers=h("comptable")).json()["statut"] == "cloture"
    assert _piece(client, h, agences).status_code == 422
    assert client.post(f"/api/compta/exercices/{exercice['id']}/cloturer", headers=h("comptable")).status_code == 422
