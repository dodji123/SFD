import pytest

# Module sous test : contrôle des livrets sur le terrain (routers/controle_livrets.py, schema/47_controle_livrets.sql)


@pytest.fixture(scope="module")
def base(client, h):
    p = client.post("/api/produits-epargne", json={"code": "TLIV", "libelle": "Tontine livret", "categorie": "collecte"}, headers=h("chef1"))
    assert p.status_code == 201, p.text
    ag = client.post("/api/agents", json={"matricule": "LIV-A1", "nom": "Agent livret"}, headers=h("chef1")).json()
    cl = client.post("/api/clients", json={"nom": "Cliente livret"}, headers=h("chef1")).json()
    cy = client.post("/api/cycles", json={"client_id": cl["id"], "produit_id": p.json()["id"], "mise": 1000, "type_cycle": 2, "date_debut": "2026-10-01", "date_fin": "2026-10-31"}, headers=h("chef1"))
    assert cy.status_code == 201, cy.text
    lignes = [{"date_collecte": f"2026-10-0{i}", "montant_collecte": 1000, "agent_id": ag["id"]} for i in (2, 3, 4)]
    assert client.post(f"/api/cycles/{cy.json()['id']}/lignes", json={"lignes": lignes}, headers=h("chef1")).status_code == 201
    return {"cycle": cy.json(), "client": cl}


def _controle(client, h, base, login="chef1", **kw):
    corps = {"cycle_id": base["cycle"]["id"], "etat_livret": "conforme", "nb_lignes_constatees": 3, "total_constate": 3000, **kw}
    return client.post("/api/controles-livrets", json=corps, headers=h(login))


def test_enregistrement_droits_et_idempotence(client, h, base):
    assert _controle(client, h, base, login="agent1").status_code == 403                                  # un agent n'est pas contrôleur
    assert _controle(client, h, base, login="chef2").status_code in (403, 404)                            # autre agence
    ok = _controle(client, h, base, cle="cle-livret-1")
    assert ok.status_code == 201, ok.text
    c = ok.json()
    assert c["statut"] == "a_valider" and c["nb_lignes_systeme"] == 3 and float(c["total_systeme"]) == 3000 and float(c["ecart_montant"]) == 0
    rejoue = _controle(client, h, base, cle="cle-livret-1")
    assert rejoue.status_code == 201 and rejoue.json()["id"] == c["id"]                                    # rejouer ne crée rien
    assert _controle(client, h, base, login="directeur", cle="cle-livret-1").status_code == 409            # clé d'un autre contrôleur
    assert _controle(client, h, base, total_constate=4000).status_code == 422                              # conforme avec un écart
    assert _controle(client, h, base, etat_livret="perdu", nb_lignes_constatees=None, total_constate=None).status_code == 422   # perdu non commenté


def test_ecarts_validation_et_filtres(client, h, base):
    ecarts = [{"no_ligne": 3, "date_collecte": "2026-10-04", "montant_systeme": 1000, "nature": "absente_livret"}]
    r = _controle(client, h, base, etat_livret="incomplet", nb_lignes_constatees=2, total_constate=2000, commentaire="Ligne du 4/10 absente du livret", ecarts=ecarts, cle="cle-livret-2")
    assert r.status_code == 201, r.text
    cid = r.json()["id"]
    assert float(r.json()["ecart_montant"]) == -1000 and len(r.json()["ecarts"]) == 1
    # séparation des tâches et droits
    assert client.post(f"/api/controles-livrets/{cid}/decider", json={"valide": True}, headers=h("chef1")).status_code == 422     # son propre contrôle
    assert client.post(f"/api/controles-livrets/{cid}/decider", json={"valide": True}, headers=h("auditeur")).status_code == 403
    assert client.post(f"/api/controles-livrets/{cid}/decider", json={"valide": False}, headers=h("directeur")).status_code == 422  # rejet non motivé
    assert client.get(f"/api/controles-livrets/{cid}", headers=h("chef2")).status_code == 404
    ok = client.post(f"/api/controles-livrets/{cid}/decider", json={"valide": True, "commentaire": "Constat confirmé"}, headers=h("directeur"))
    assert ok.status_code == 200 and ok.json()["statut"] == "valide" and ok.json()["decide_par_nom"]
    assert client.post(f"/api/controles-livrets/{cid}/decider", json={"valide": True}, headers=h("directeur")).status_code == 422   # déjà décidé
    # consultation filtrée
    assert any(x["id"] == cid for x in client.get("/api/controles-livrets", params={"statut": "valide"}, headers=h("auditeur")).json())
    assert not any(x["id"] == cid for x in client.get("/api/controles-livrets", params={"statut": "a_valider"}, headers=h("auditeur")).json())
    avec_ecart = client.get("/api/controles-livrets", params={"avec_ecart": "true", "q": "TLIV"}, headers=h("chef1")).json()
    assert [x["id"] for x in avec_ecart] == [cid] and avec_ecart[0]["nb_ecarts_lignes"] == 1
    assert client.get("/api/controles-livrets", headers=h("chef2")).json() == []
    assert client.get("/api/controles-livrets", headers=h("agent1")).status_code == 403
