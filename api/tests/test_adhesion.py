import datetime as dt

import pytest

# Modules sous test : routers/adhesion.py (adhésion, parts, liaison tontine / épargne classique) et le guichet d'épargne de routers/epargne.py


@pytest.fixture(scope="module")
def base(client, h, sql, agences, produits):
    a1 = agences["a1"]
    c = client.post("/api/clients", json={"nom": "Membre Test"}, headers=h("chef1"))
    assert c.status_code == 201, c.text
    return {"client": c.json(), "produits": produits, "a1": a1}


def _suffixe(cl):
    return str(int(cl["numero"].split("-")[-1]))


def test_epargne_classique_reservee_aux_membres(client, h, sql, base):
    cid, pcl = base["client"]["id"], base["produits"]["CL"]
    sql("UPDATE parametre SET valeur = 'oui' WHERE cle = 'adhesion_obligatoire' AND agence_id IS NULL")
    try:
        r = client.post("/api/comptes-epargne", json={"client_id": cid, "produit_id": pcl}, headers=h("caissier1"))
        assert r.status_code == 422 and "membre" in r.json()["detail"]
        # recherche par le numéro d'ordre
        d = client.get("/api/adhesions/recherche", params={"suffixe": _suffixe(base["client"])}, headers=h("caissier1")).json()
        assert d["en_regle"] is False and d["adhesion"] is None and d["obligatoire"] is True and d["valeur_part"] == 5000
        # parts sans adhésion refusées, adhésion, puis parts
        assert client.post("/api/adhesions/parts", json={"client_id": cid, "nb_parts": 2}, headers=h("caissier1")).status_code == 422
        assert client.post("/api/adhesions", json={"client_id": cid}, headers=h("agent1")).status_code == 403
        a = client.post("/api/adhesions", json={"client_id": cid}, headers=h("caissier1"))
        assert a.status_code == 201, a.text
        assert a.json()["adhesion"]["numero"].startswith("AD-T1-") and a.json()["en_regle"] is False and a.json()["droit_adhesion"] == 2000
        assert client.post("/api/adhesions", json={"client_id": cid}, headers=h("caissier1")).status_code == 422          # une seule adhésion
        assert client.post("/api/comptes-epargne", json={"client_id": cid, "produit_id": pcl}, headers=h("caissier1")).status_code == 422
        p = client.post("/api/adhesions/parts", json={"client_id": cid, "nb_parts": 2}, headers=h("caissier1"))
        assert p.status_code == 201 and p.json()["en_regle"] is True and p.json()["adhesion"]["capital_souscrit"] == 10000
        assert client.post("/api/adhesions/parts", json={"client_id": cid, "nb_parts": 1, "date": "2999-01-01"}, headers=h("caissier1")).status_code == 422
        assert client.post("/api/comptes-epargne", json={"client_id": cid, "produit_id": pcl}, headers=h("caissier1")).status_code == 201
        j = client.get("/api/adhesions/jour", params={"date": str(dt.date.today())}, headers=h("caissier1")).json()
        mine = [x for x in j["lignes"] if x["client"] == "Membre Test"]
        assert sorted(x["nature"] for x in mine) == ["adhesion", "parts"] and j["total"] >= 12000
        assert [x for x in client.get("/api/adhesions/jour", params={"date": str(dt.date.today())}, headers=h("caissier2")).json()["lignes"] if x["client"] == "Membre Test"] == []
    finally:
        sql("UPDATE parametre SET valeur = 'non' WHERE cle = 'adhesion_obligatoire' AND agence_id IS NULL")


def test_guichet_depot_retrait(client, h, base):
    cl = base["client"]
    pcl = base["produits"]["CL"]
    cpt = client.get("/api/comptes-epargne", params={"client_id": cl["id"]}, headers=h("caissier1")).json()[0]
    p = {"suffixe": _suffixe(cl), "produit_id": pcl}
    r = client.get("/api/comptes-epargne/recherche", params=p, headers=h("caissier1"))
    assert r.status_code == 200 and r.json()["compte"]["id"] == cpt["id"] and r.json()["client"]["nom"] == "Membre Test"
    assert client.get("/api/comptes-epargne/recherche", params={**p, "suffixe": "987654"}, headers=h("caissier1")).status_code == 404
    assert client.get("/api/comptes-epargne/recherche", params={**p, "produit_id": base["produits"]["P1"]}, headers=h("caissier1")).status_code == 404
    assert client.post(f"/api/comptes-epargne/{cpt['id']}/depot", json={"montant": 50000, "date_operation": "2999-01-01"}, headers=h("caissier1")).status_code == 422
    assert client.post(f"/api/comptes-epargne/{cpt['id']}/depot", json={"montant": 50000}, headers=h("caissier1")).status_code == 201
    assert client.post(f"/api/comptes-epargne/{cpt['id']}/retrait", json={"montant": 10000}, headers=h("caissier1")).status_code == 201
    ops = client.get("/api/comptes-epargne/operations", params={"date": str(dt.date.today())}, headers=h("caissier1")).json()
    mine = [o for o in ops["lignes"] if o["client"] == "Membre Test"]
    assert sorted((o["type"], o["montant"]) for o in mine) == [("depot", 50000), ("retrait", 10000)]
    assert ops["total_depots"] >= 50000 and ops["total_retraits"] >= 10000
    # le siège désigne l'agence ; l'auditeur lit sans écrire
    d = {"date": str(dt.date.today())}
    assert client.get("/api/comptes-epargne/operations", params=d, headers=h("auditeur")).status_code == 400
    assert client.get("/api/comptes-epargne/operations", params={**d, "agence_id": base["a1"]}, headers=h("auditeur")).status_code == 200
    assert [o for o in client.get("/api/comptes-epargne/operations", params=d, headers=h("caissier2")).json()["lignes"] if o["client"] == "Membre Test"] == []


def test_liaison_tontine_epargne(client, h, base):
    cl, pcl, p1 = base["client"], base["produits"]["CL"], base["produits"]["P1"]
    cpt = client.get("/api/comptes-epargne", params={"client_id": cl["id"]}, headers=h("caissier1")).json()[0]
    cy = client.post("/api/cycles", json={"client_id": cl["id"], "produit_id": p1, "mise": 500, "date_debut": "2026-10-01", "date_fin": "2026-10-31"}, headers=h("chef1"))
    assert cy.status_code == 201, cy.text
    cid = cy.json()["id"]
    s = client.get("/api/liaisons/recherche", params={"suffixe": _suffixe(cl)}, headers=h("caissier1")).json()
    assert [c["id"] for c in s["comptes"]] == [cpt["id"]] and [c["id"] for c in s["cycles"]] == [cid] and s["cycles"][0]["compte_lie_id"] is None
    assert client.put(f"/api/liaisons/cycles/{cid}", json={"compte_id": cpt["id"]}, headers=h("agent1")).status_code == 403
    assert client.put(f"/api/liaisons/cycles/{cid}", json={"compte_id": cpt["id"]}, headers=h("caissier1")).status_code == 200
    s = client.get("/api/liaisons/recherche", params={"suffixe": _suffixe(cl)}, headers=h("caissier1")).json()
    assert s["cycles"][0]["compte_lie_id"] == cpt["id"]
    assert client.put(f"/api/liaisons/cycles/{cid}", json={"compte_id": cpt["id"]}, headers=h("caissier2")).status_code == 404       # autre agence
    assert client.delete(f"/api/liaisons/cycles/{cid}", headers=h("caissier1")).status_code == 200
    assert client.delete(f"/api/liaisons/cycles/{cid}", headers=h("caissier1")).status_code == 422                                    # plus de liaison
    # le virement épargne -> tontine passe par le compte lié : 1500 F = 3 mises de 500 F
    assert client.post("/api/virements/epargne-vers-tontine", json={"compte_id": cpt["id"], "cycle_id": cid, "montant": 1500}, headers=h("caissier1")).status_code == 201


def test_annulation_et_validation_de_la_journee_d_epargne(client, h, base):
    cl = base["client"]
    cpt = client.get("/api/comptes-epargne", params={"client_id": cl["id"]}, headers=h("caissier1")).json()[0]
    aujourdhui = str(dt.date.today())
    d = {"date": aujourdhui}
    ops = lambda: client.get("/api/comptes-epargne/operations", params=d, headers=h("caissier1")).json()
    avant = client.get(f"/api/comptes-epargne/{cpt['id']}", headers=h("caissier1")).json()["solde"]
    dep = client.post(f"/api/comptes-epargne/{cpt['id']}/depot", json={"montant": 7000}, headers=h("caissier1")).json()["mouvement"]["id"]
    try:
        o = ops()
        assert next(l for l in o["lignes"] if l["id"] == dep)["annulable"] is True and o["validee"] is False
        total_avant = o["total_depots"]
        # annulation par contre-passation : le solde revient, les deux lignes restent visibles mais sortent des totaux
        assert client.post(f"/api/comptes-epargne/operations/{dep}/annuler", headers=h("agent1")).status_code == 403
        assert client.post(f"/api/comptes-epargne/operations/{dep}/annuler", headers=h("caissier2")).status_code == 404
        assert client.post(f"/api/comptes-epargne/operations/{dep}/annuler", headers=h("caissier1")).status_code == 200
        assert client.get(f"/api/comptes-epargne/{cpt['id']}", headers=h("caissier1")).json()["solde"] == avant
        o = ops()
        ligne = next(l for l in o["lignes"] if l["id"] == dep)
        assert ligne["annulee"] is True and ligne["annulable"] is False and any(l["contre_passation"] for l in o["lignes"])
        assert o["total_depots"] == total_avant - 7000
        assert client.post(f"/api/comptes-epargne/operations/{dep}/annuler", headers=h("caissier1")).status_code == 422          # déjà annulée
        # validation globale de la journée : réservée au chef / admin
        assert client.post("/api/comptes-epargne/valider-journee", json=d, headers=h("caissier1")).status_code == 403
        v = client.post("/api/comptes-epargne/valider-journee", json=d, headers=h("chef1"))
        assert v.status_code == 201 and v.json()["validee"] is True and all(l["annulable"] is False for l in v.json()["lignes"])
        assert client.post(f"/api/comptes-epargne/{cpt['id']}/depot", json={"montant": 1000}, headers=h("caissier1")).status_code == 422
        assert client.post("/api/comptes-epargne/valider-journee", json=d, headers=h("chef1")).status_code == 422
        assert client.post("/api/comptes-epargne/rouvrir-journee", json=d, headers=h("chef1")).status_code == 422                 # motif obligatoire
    finally:
        r = client.post("/api/comptes-epargne/rouvrir-journee", json={**d, "motif": "fin du test"}, headers=h("chef1"))
        assert r.status_code in (200, 422)
    assert client.post(f"/api/comptes-epargne/{cpt['id']}/depot", json={"montant": 1000}, headers=h("caissier1")).status_code == 201


def test_sortie_d_un_membre_et_remboursement_des_parts(client, h, sql, base):
    c = client.post("/api/clients", json={"nom": "Sortant Test"}, headers=h("chef1")).json()
    assert client.post("/api/adhesions", json={"client_id": c["id"]}, headers=h("caissier1")).status_code == 201
    assert client.post("/api/adhesions/parts", json={"client_id": c["id"], "nb_parts": 2}, headers=h("caissier1")).status_code == 201
    assert client.post("/api/adhesions/sortie", json={"client_id": c["id"]}, headers=h("caissier1")).status_code == 403            # réservé au chef / admin
    # tontine en cours : sortie refusée
    cy = client.post("/api/cycles", json={"client_id": c["id"], "produit_id": base["produits"]["P1"], "mise": 500, "date_debut": "2026-10-01", "date_fin": "2026-10-31"}, headers=h("chef1")).json()
    r = client.post("/api/adhesions/sortie", json={"client_id": c["id"]}, headers=h("chef1"))
    assert r.status_code == 422 and "tontine" in r.json()["detail"]
    # le membre Test garde un solde : sortie refusée aussi
    r = client.post("/api/adhesions/sortie", json={"client_id": base["client"]["id"]}, headers=h("chef1"))
    assert r.status_code == 422 and "solde" in r.json()["detail"]
    sql("UPDATE cycle SET statut = 'retire' WHERE id = %s", (cy["id"],))
    r = client.post("/api/adhesions/sortie", json={"client_id": c["id"]}, headers=h("chef1"))
    assert r.status_code == 201, r.text
    assert r.json()["adhesion"]["statut"] == "radiee" and r.json()["remboursement"]["montant"] == 10000 and r.json()["en_regle"] is False
    assert client.post("/api/adhesions/sortie", json={"client_id": c["id"]}, headers=h("chef1")).status_code == 422                 # déjà radiée
    assert client.post("/api/adhesions/parts", json={"client_id": c["id"], "nb_parts": 1}, headers=h("caissier1")).status_code == 422
