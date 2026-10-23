import pytest

# Module sous test : routers/stock.py (articles, entrées, transferts, demandes validées par une autre personne, soldes, alertes, valorisation,
# immobilisations affectées aux agents) + schema/57_stock.sql et 58_permissions_stock.sql

SIEGE = {"type": "siege"}


def agence(a):
    return {"type": "agence", "agence_id": a}


@pytest.fixture(scope="module")
def base(client, h, agences, utilisateurs):
    art = client.post("/api/stock/articles", json={"code": "LIVRET-T", "designation": "Livret de collecte", "type": "consommable", "unite": "livret", "seuil_alerte": 20},
                      headers=h("chef1"))
    assert art.status_code == 201, art.text
    r = client.post("/api/stock/entrees", json={"article_id": art.json()["id"], "lieu": SIEGE, "quantite": 100, "cout_unitaire": 500, "reference_facture": "F-1"},
                    headers=h("directeur"))
    assert r.status_code == 201, r.text
    return {"article": art.json()["id"], "a1": agences["a1"], "a2": agences["a2"], "u": utilisateurs}


def solde(client, h, login, article, lieu_type, agence_id=None):
    rows = client.get("/api/stock/soldes", params={"article_id": article, "lieu_type": lieu_type, **({"agence_id": agence_id} if agence_id else {})}, headers=h(login)).json()
    return sum(float(x["quantite"]) for x in rows)


def test_droits_catalogue(client, h, base):
    assert client.get("/api/stock/articles", headers=h("agent1")).status_code == 403
    assert client.get("/api/stock/articles", headers=h("auditeur")).status_code == 200
    body = {"code": "STYLO-T", "designation": "Stylo bleu", "type": "consommable"}
    assert client.post("/api/stock/articles", json=body, headers=h("auditeur")).status_code == 403
    assert client.post("/api/stock/articles", json=body, headers=h("caissier1")).status_code == 403
    assert client.post("/api/stock/articles", json={**body, "code": "stylo"}, headers=h("chef1")).status_code == 422                         # code en minuscules
    assert client.post("/api/stock/articles", json={**body, "type": "immobilisable"}, headers=h("chef1")).status_code == 422                 # catégorie obligatoire
    assert client.post("/api/stock/articles", json=body, headers=h("chef1")).status_code == 201
    assert client.post("/api/stock/articles", json=body, headers=h("chef1")).status_code == 409                                              # doublon
    liste = client.get("/api/stock/articles", params={"q": "livret"}, headers=h("chef1")).json()
    assert [a["code"] for a in liste] == ["LIVRET-T"] and liste[0]["quantite"] == 0                                                          # le chef ne voit pas le stock du siège


def test_entree_siege_reservee_au_siege_et_cout_moyen(client, h, base):
    a = base["article"]
    assert client.post("/api/stock/entrees", json={"article_id": a, "lieu": SIEGE, "quantite": 5, "cout_unitaire": 500}, headers=h("chef1")).status_code == 403
    assert client.post("/api/stock/entrees", json={"article_id": a, "lieu": SIEGE, "quantite": 5, "cout_unitaire": 0}, headers=h("directeur")).status_code == 422
    assert client.post("/api/stock/entrees", json={"article_id": a, "lieu": SIEGE, "quantite": 100, "cout_unitaire": 700}, headers=h("directeur")).status_code == 201
    art = [x for x in client.get("/api/stock/articles", headers=h("directeur")).json() if x["id"] == a][0]
    assert float(art["cout_moyen"]) == 600 and float(art["quantite"]) == 200 and int(art["valeur"]) == 120000
    assert solde(client, h, "directeur", a, "siege") == 200


def test_transferts_et_cloisonnement(client, h, base):
    a = base["article"]
    t = client.post("/api/stock/transferts", json={"article_id": a, "source": SIEGE, "destination": agence(base["a1"]), "quantite": 60, "motif": "Dotation de l'agence"}, headers=h("directeur"))
    assert t.status_code == 201 and len(t.json()) == 2
    # le chef de l'agence 1 voit son stock, pas celui du siège ni de l'agence 2
    assert solde(client, h, "chef1", a, "agence") == 60
    assert client.get("/api/stock/soldes", params={"article_id": a}, headers=h("chef2")).json() == []
    assert all(x["lieu_type"] != "siege" for x in client.get("/api/stock/soldes", params={"article_id": a}, headers=h("chef1")).json())
    # un chef ne puise pas dans le siège ni dans une autre agence
    assert client.post("/api/stock/transferts", json={"article_id": a, "source": SIEGE, "destination": agence(base["a1"]), "quantite": 1, "motif": "Prélèvement"}, headers=h("chef1")).status_code == 403
    assert client.post("/api/stock/transferts", json={"article_id": a, "source": agence(base["a1"]), "destination": agence(base["a2"]), "quantite": 1, "motif": "Prélèvement"},
                       headers=h("chef1")).status_code == 403
    assert client.post("/api/stock/transferts", json={"article_id": a, "source": agence(base["a1"]), "destination": agence(base["a1"]), "quantite": 1, "motif": "Même lieu"},
                       headers=h("chef1")).status_code == 422
    # transfert vers un agent de l'agence 1, puis refus d'un agent d'une autre agence
    agent = {"type": "agent", "utilisateur_id": base["u"]["agent1"]}
    assert client.post("/api/stock/transferts", json={"article_id": a, "source": agence(base["a1"]), "destination": agent, "quantite": 25, "motif": "Dotation agent"},
                       headers=h("chef1")).status_code == 201
    assert client.post("/api/stock/transferts", json={"article_id": a, "source": agence(base["a1"]), "destination": {"type": "agent", "utilisateur_id": base["u"]["caissier2"]},
                                                      "quantite": 1, "motif": "Autre agence"}, headers=h("chef1")).status_code == 404
    assert client.post("/api/stock/transferts", json={"article_id": a, "source": agence(base["a1"]), "destination": agent, "quantite": 36, "motif": "Trop"}, headers=h("chef1")).status_code == 422
    assert solde(client, h, "chef1", a, "agence") == 35 and solde(client, h, "chef1", a, "agent") == 25
    dest = client.get("/api/stock/destinations", headers=h("chef1")).json()
    assert not any(d["type"] == "siege" for d in dest) and all(d["agence_id"] == base["a1"] for d in dest)


def test_sortie_validee_par_une_autre_personne(client, h, base):
    a = base["article"]
    d = client.post("/api/stock/demandes", json={"type": "sortie", "article_id": a, "lieu": agence(base["a1"]), "quantite": 10, "motif": "Livrets remis aux collectrices"}, headers=h("caissier1"))
    assert d.status_code == 201 and d.json()["statut"] == "en_attente"
    did = d.json()["id"]
    assert solde(client, h, "chef1", a, "agence") == 35                                                       # rien ne bouge avant la décision
    assert client.post(f"/api/stock/demandes/{did}/decider", json={"valider": True}, headers=h("caissier1")).status_code == 403   # pas le droit de décider
    assert client.post(f"/api/stock/demandes/{did}/decider", json={"valider": True}, headers=h("chef2")).status_code == 404       # autre agence
    assert client.post(f"/api/stock/demandes/{did}/decider", json={"valider": False}, headers=h("chef1")).status_code == 422       # rejet sans motif
    ok = client.post(f"/api/stock/demandes/{did}/decider", json={"valider": True}, headers=h("chef1"))
    assert ok.status_code == 200 and ok.json()["statut"] == "validee" and ok.json()["decide_par_nom"]
    assert solde(client, h, "chef1", a, "agence") == 25
    assert client.post(f"/api/stock/demandes/{did}/decider", json={"valider": True}, headers=h("chef1")).status_code == 422       # déjà décidée
    # le demandeur ne valide pas sa propre demande, même s'il en a le droit
    d2 = client.post("/api/stock/demandes", json={"type": "rebut", "article_id": a, "lieu": agence(base["a1"]), "quantite": 5, "motif": "Livrets mouillés"}, headers=h("chef1")).json()["id"]
    assert client.post(f"/api/stock/demandes/{d2}/decider", json={"valider": True}, headers=h("chef1")).status_code == 403
    assert solde(client, h, "chef1", a, "agence") == 25
    # le comptable (siège) peut valider la demande d'une agence
    assert client.post(f"/api/stock/demandes/{d2}/decider", json={"valider": True}, headers=h("comptable")).json()["statut"] == "validee"
    assert solde(client, h, "chef1", a, "agence") == 20
    # un rejet motivé ne touche pas au stock
    d3 = client.post("/api/stock/demandes", json={"type": "sortie", "article_id": a, "lieu": agence(base["a1"]), "quantite": 3, "motif": "Prélèvement douteux"}, headers=h("caissier1")).json()["id"]
    rej = client.post(f"/api/stock/demandes/{d3}/decider", json={"valider": False, "motif": "Pas justifié"}, headers=h("chef1"))
    assert rej.json()["statut"] == "rejetee" and solde(client, h, "chef1", a, "agence") == 20
    # une sortie supérieure au stock échoue à la validation et la demande reste en attente
    d4 = client.post("/api/stock/demandes", json={"type": "sortie", "article_id": a, "lieu": agence(base["a1"]), "quantite": 21, "motif": "Trop gros prélèvement"}, headers=h("caissier1")).json()["id"]
    assert client.post(f"/api/stock/demandes/{d4}/decider", json={"valider": True}, headers=h("chef1")).status_code == 422
    assert [x for x in client.get("/api/stock/demandes", headers=h("chef1")).json() if x["id"] == d4][0]["statut"] == "en_attente"
    # le caissier de l'autre agence ne peut ni demander ni voir
    assert client.post("/api/stock/demandes", json={"type": "sortie", "article_id": a, "lieu": agence(base["a1"]), "quantite": 1, "motif": "Autre agence"}, headers=h("caissier2")).status_code == 403
    assert all(x["id"] != did for x in client.get("/api/stock/demandes", headers=h("chef2")).json())


def test_inventaire_mouvements_valorisation_et_alertes(client, h, base):
    a = base["article"]
    d = client.post("/api/stock/demandes", json={"type": "inventaire", "article_id": a, "lieu": agence(base["a1"]), "quantite": 18, "motif": "Comptage physique de l'agence"}, headers=h("caissier1")).json()["id"]
    assert client.post(f"/api/stock/demandes/{d}/decider", json={"valider": True}, headers=h("chef1")).status_code == 200
    assert solde(client, h, "chef1", a, "agence") == 18
    mv = client.get("/api/stock/mouvements", params={"article_id": a}, headers=h("chef1")).json()
    assert {m["type"] for m in mv} >= {"transfert", "sortie", "rebut", "inventaire"} and all(m["agence_id"] == base["a1"] for m in mv)
    inv = [m for m in mv if m["type"] == "inventaire"][0]
    assert float(inv["quantite"]) == -2 and int(inv["valeur"]) == 1200 and float(inv["cout_unitaire"]) == 600
    assert len(client.get("/api/stock/mouvements", params={"article_id": a}, headers=h("chef2")).json()) == 0
    val = client.get("/api/stock/valorisation", headers=h("chef1")).json()
    assert val["total"] >= (18 + 25) * 600 and all(x["agence_id"] == base["a1"] for x in val["lignes"])
    assert client.get("/api/stock/valorisation", headers=h("directeur")).json()["total"] >= 140 * 600 + 43 * 600
    # alerte : le siège passe sous le seuil de 20 livrets
    assert not any(x["article_id"] == a for x in client.get("/api/stock/alertes", headers=h("directeur")).json())
    d5 = client.post("/api/stock/demandes", json={"type": "rebut", "article_id": a, "lieu": SIEGE, "quantite": 125, "motif": "Lot détruit"}, headers=h("comptable")).json()["id"]
    assert client.post(f"/api/stock/demandes/{d5}/decider", json={"valider": True}, headers=h("directeur")).status_code == 200
    al = [x for x in client.get("/api/stock/alertes", headers=h("directeur")).json() if x["article_id"] == a]
    assert len(al) == 1 and al[0]["agence_id"] is None and float(al[0]["quantite"]) == 15 and not al[0]["rupture"]
    assert client.get("/api/stock/alertes", headers=h("chef2")).json() == []


def test_immobilisations_affectees(client, h, base):
    u = base["u"]
    art = client.post("/api/stock/articles", json={"code": "TEL-T", "designation": "Téléphone Android", "type": "immobilisable", "categorie_immobilisation": "materiel_informatique"},
                      headers=h("chef1"))
    assert art.status_code == 201, art.text
    aid = art.json()["id"]
    # un article immobilisable n'a pas de quantité
    assert client.post("/api/stock/entrees", json={"article_id": aid, "lieu": agence(base["a1"]), "quantite": 1, "cout_unitaire": 90000}, headers=h("chef1")).status_code == 422
    unite = {"article_id": aid, "designation": "Téléphone Android n° 1", "date_acquisition": "2026-02-01", "date_mise_en_service": "2026-02-01", "valeur_acquisition": 90000,
             "numero_serie": "IMEI-1"}
    assert client.post("/api/stock/immobilisations", json=unite, headers=h("caissier1")).status_code == 403
    r = client.post("/api/stock/immobilisations", json={**unite, "utilisateur_id": u["agent1"]}, headers=h("chef1"))
    assert r.status_code == 201, r.text
    imm = r.json()
    assert imm["numero"].startswith("IMM-") and imm["affecte_a_id"] == u["agent1"] and imm["article_code"] == "TEL-T"
    assert client.post("/api/stock/immobilisations", json={**unite, "utilisateur_id": u["caissier2"]}, headers=h("chef1")).status_code == 422     # agent d'une autre agence
    # filtre par agent, cloisonnement
    assert [x["id"] for x in client.get("/api/stock/immobilisations", params={"affecte_a": u["agent1"]}, headers=h("chef1")).json()] == [imm["id"]]
    assert client.get("/api/stock/immobilisations", headers=h("chef2")).json() == []
    assert client.post(f"/api/stock/immobilisations/{imm['id']}/affecter", json={"utilisateur_id": u["agent1"]}, headers=h("chef2")).status_code == 404
    assert client.post(f"/api/stock/immobilisations/{imm['id']}/affecter", json={"utilisateur_id": u["agent1"]}, headers=h("chef1")).status_code == 422   # déjà à cet agent
    re = client.post(f"/api/stock/immobilisations/{imm['id']}/affecter", json={"utilisateur_id": u["coll1"], "motif": "Reprise de la tournée"}, headers=h("chef1"))
    assert re.status_code == 200 and re.json()["affecte_a_id"] == u["coll1"]
    hist = client.get(f"/api/stock/immobilisations/{imm['id']}/affectations", headers=h("chef1")).json()
    assert len(hist) == 2 and sum(1 for x in hist if x["date_fin"] is None) == 1
    assert client.post(f"/api/stock/immobilisations/{imm['id']}/restituer", json={}, headers=h("chef1")).json()["affecte_a_id"] is None
    assert client.post(f"/api/stock/immobilisations/{imm['id']}/restituer", json={}, headers=h("chef1")).status_code == 422
    client.post(f"/api/stock/immobilisations/{imm['id']}/affecter", json={"utilisateur_id": u["agent1"]}, headers=h("chef1"))
    # mise au rebut : demandée par le caissier, décidée par une autre personne
    d = client.post("/api/stock/demandes", json={"type": "rebut_immobilisation", "immobilisation_id": imm["id"], "motif": "Écran cassé, irréparable"}, headers=h("caissier1"))
    assert d.status_code == 201, d.text
    did = d.json()["id"]
    assert client.post("/api/stock/demandes", json={"type": "rebut_immobilisation", "immobilisation_id": imm["id"], "motif": "Autre agence"}, headers=h("caissier2")).status_code == 404
    assert client.get(f"/api/immobilisations/{imm['id']}", headers=h("chef1")).json()["statut"] == "en_service"
    assert client.post(f"/api/stock/demandes/{did}/decider", json={"valider": True}, headers=h("caissier1")).status_code == 403
    ok = client.post(f"/api/stock/demandes/{did}/decider", json={"valider": True}, headers=h("chef1"))
    assert ok.status_code == 200 and ok.json()["statut"] == "validee"
    sortie = client.get(f"/api/immobilisations/{imm['id']}", headers=h("chef1")).json()
    assert sortie["statut"] == "sortie" and sortie["type_sortie"] == "rebut"
    assert client.get("/api/stock/immobilisations", params={"statut": "sortie"}, headers=h("chef1")).json()[0]["affecte_a_id"] is None      # affectation close à la sortie
