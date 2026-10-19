import pytest

# Module sous test : routers/kyc.py (dossier KYC, pièces, liens, validation, garants, listes et alertes LBC/FT)


@pytest.fixture(scope="module")
def base(client, h, agences):
    pk = client.post("/api/produits-credit", json={"code": "PKYC", "libelle": "Crédit KYC", "type": "sans_epargne", "taux_annuel": 0.12}, headers=h("chef1")).json()
    cl = {n: client.post("/api/clients", json={"nom": n}, headers=h("chef1")).json() for n in ("Zoumaro Akpene Esther", "Gbeve Komla", "Dosseh Mawuena")}
    autre = client.post("/api/clients", json={"nom": "Client Autre Agence"}, headers=h("chef2")).json()
    return {"produit": pk, "cl": cl, "autre": autre}


def _complet(client, h, cid, piece, login="chef1"):
    assert client.put(f"/api/clients/{cid}/profil", json={"sexe": "F", "date_naissance": "1990-04-04", "adresse": "Lomé"}, headers=h(login)).status_code == 200
    assert client.post(f"/api/clients/{cid}/pieces", json={"type": "cni", "numero": piece, "date_expiration": "2040-01-01"}, headers=h(login)).status_code == 201


def test_dossier_et_validation(client, h, base):
    cid = base["cl"]["Gbeve Komla"]["id"]
    d = client.get(f"/api/clients/{cid}/kyc", headers=h("chef1")).json()
    assert d["statut_kyc"] == "incomplet" and "adresse" in d["manquants"] and "pièce d'identité valide" in d["manquants"]
    assert client.post(f"/api/clients/{cid}/kyc/valider", headers=h("chef1")).status_code == 422              # incomplet
    _complet(client, h, cid, "KYC-CNI-001")
    r = client.post(f"/api/clients/{cid}/kyc/valider", headers=h("chef1"))
    assert r.status_code == 200 and r.json()["statut_kyc"] == "complet" and r.json()["manquants"] == []
    # même pièce sur un autre client : refusée
    other = base["cl"]["Dosseh Mawuena"]["id"]
    assert client.post(f"/api/clients/{other}/pieces", json={"type": "cni", "numero": "KYC-CNI-001"}, headers=h("chef1")).status_code == 409
    assert client.put(f"/api/clients/{cid}/profil", json={"latitude_domicile": 120}, headers=h("chef1")).status_code == 422
    assert client.put(f"/api/clients/{cid}/profil", json={}, headers=h("chef1")).status_code == 422


def test_droits_et_cloisonnement_kyc(client, h, base):
    cid = base["cl"]["Gbeve Komla"]["id"]
    assert client.get(f"/api/clients/{cid}/kyc", headers=h("chef2")).status_code == 404
    assert client.put(f"/api/clients/{cid}/profil", json={"adresse": "x"}, headers=h("caissier1")).status_code == 403
    assert client.post(f"/api/clients/{cid}/kyc/valider", headers=h("agent1")).status_code == 403
    assert client.get("/api/kyc/pieces-a-renouveler", headers=h("chef1")).status_code == 200


def test_liens_entre_clients(client, h, base):
    a, b = base["cl"]["Gbeve Komla"]["id"], base["cl"]["Dosseh Mawuena"]["id"]
    r = client.post(f"/api/clients/{a}/liens", json={"lie_a_id": b, "type": "famille"}, headers=h("chef1"))
    assert r.status_code == 201 and r.json()["liens"][0]["lie_a_nom"] == "Dosseh Mawuena"
    assert client.post(f"/api/clients/{a}/liens", json={"lie_a_id": b, "type": "famille"}, headers=h("chef1")).status_code == 409
    assert client.post(f"/api/clients/{a}/liens", json={"lie_a_id": a, "type": "famille"}, headers=h("chef1")).status_code == 422
    assert client.post(f"/api/clients/{a}/liens", json={"lie_a_id": base["autre"]["id"], "type": "famille"}, headers=h("chef1")).status_code == 422   # autre agence


def test_listes_alertes_et_blocage_du_credit(client, h, base):
    cid = base["cl"]["Zoumaro Akpene Esther"]["id"]
    assert client.post("/api/lbc/listes", json={"source": "ONU", "categorie": "sanction", "entrees": [{"nom": "ZOUMARO Esther Akpene"}]}, headers=h("chef1")).status_code == 403
    r = client.post("/api/lbc/listes", json={"source": "ONU", "categorie": "sanction", "entrees": [{"nom": "ZOUMARO Esther Akpene", "pays": "TG"}, {"nom": "Personne Inconnue Totalement"}]}, headers=h("directeur"))
    assert r.status_code == 201 and r.json()["entrees_ajoutees"] == 2
    al = client.get("/api/lbc/alertes", params={"statut": "a_examiner"}, headers=h("chef1")).json()
    mine = [a for a in al if a["client_id"] == cid]
    assert len(mine) == 1 and mine[0]["type"] == "sanction" and mine[0]["score"] >= 0.7
    # alerte ouverte : demande de crédit refusée
    demande = {"client_id": cid, "produit_id": base["produit"]["id"], "montant": 10000, "nb_echeances": 2, "mode_remboursement": "especes"}
    rr = client.post("/api/demandes-credit", json=demande, headers=h("chef1"))
    assert rr.status_code == 422 and "sanction" in rr.json()["detail"]
    # droits : le chef d'agence lit mais ne tranche pas
    assert client.post(f"/api/lbc/alertes/{mine[0]['id']}/traiter", json={"decision": "ecartee", "note": "homonyme"}, headers=h("chef1")).status_code == 403
    assert client.post(f"/api/lbc/alertes/{mine[0]['id']}/traiter", json={"decision": "ecartee"}, headers=h("directeur")).status_code == 422       # justification
    ok = client.post(f"/api/lbc/alertes/{mine[0]['id']}/traiter", json={"decision": "ecartee", "note": "homonyme, date de naissance différente"}, headers=h("directeur"))
    assert ok.status_code == 200 and ok.json()["statut"] == "ecartee" and ok.json()["decide_par"] == "directeur"
    assert client.post("/api/demandes-credit", json=demande, headers=h("chef1")).status_code == 201
    assert client.post(f"/api/lbc/alertes/{mine[0]['id']}/traiter", json={"decision": "confirmee"}, headers=h("directeur")).status_code == 422   # déjà traitée
    assert client.get("/api/lbc/alertes", headers=h("caissier1")).status_code == 403
    assert any(l["source"] == "ONU" for l in client.get("/api/lbc/listes", headers=h("auditeur")).json())
    assert not any(a["client_id"] == base["autre"]["id"] for a in client.get("/api/lbc/alertes", headers=h("chef1")).json())


def test_ppe_validation_reservee_a_la_direction(client, h, base):
    cid = base["cl"]["Dosseh Mawuena"]["id"]
    client.post("/api/lbc/listes", json={"source": "Liste nationale", "categorie": "ppe", "entrees": [{"nom": "Mawuena Dosseh"}]}, headers=h("directeur"))
    al = [a for a in client.get("/api/lbc/alertes", params={"statut": "a_examiner"}, headers=h("directeur")).json() if a["client_id"] == cid]
    assert len(al) == 1 and al[0]["type"] == "ppe"
    assert client.post(f"/api/lbc/alertes/{al[0]['id']}/traiter", json={"decision": "confirmee", "note": "ministre"}, headers=h("directeur")).status_code == 200
    _complet(client, h, cid, "KYC-CNI-PPE")
    assert client.post(f"/api/clients/{cid}/kyc/valider", headers=h("chef1")).status_code == 403             # PPE : direction seulement
    r = client.post(f"/api/clients/{cid}/kyc/valider", headers=h("directeur"))
    assert r.status_code == 200 and r.json()["ppe"] is True and r.json()["statut_kyc"] == "complet"


def test_garants(client, h, base):
    emprunteur, garant = base["cl"]["Zoumaro Akpene Esther"]["id"], base["cl"]["Gbeve Komla"]["id"]
    d = client.post("/api/demandes-credit", json={"client_id": emprunteur, "produit_id": base["produit"]["id"], "montant": 20000, "nb_echeances": 2, "mode_remboursement": "especes"}, headers=h("chef1")).json()
    r = client.post(f"/api/demandes-credit/{d['id']}/garants", json={"garant_client_id": garant, "montant_caution": 8000}, headers=h("chef1"))
    assert r.status_code == 201 and r.json()[0]["nom"] == "Gbeve Komla"
    assert client.post(f"/api/demandes-credit/{d['id']}/garants", json={"garant_client_id": garant, "montant_caution": 1000}, headers=h("chef1")).status_code == 409
    assert client.post(f"/api/demandes-credit/{d['id']}/garants", json={"garant_client_id": emprunteur, "montant_caution": 1000}, headers=h("chef1")).status_code == 422
    assert client.post(f"/api/demandes-credit/{d['id']}/garants", json={"garant_client_id": base["autre"]["id"], "montant_caution": 1000}, headers=h("chef1")).status_code == 422
    assert client.get(f"/api/demandes-credit/{d['id']}/garants", headers=h("chef2")).status_code == 404
    assert len(client.get(f"/api/demandes-credit/{d['id']}/garants", headers=h("chef1")).json()) == 1
