import pytest

# Module sous test : type de cycle libre à chaque cycle, délai de grâce, prolongation autorisée, suppression tracée
# (routers/collecte.py, referentiels.py, admin.py)


@pytest.fixture(scope="module")
def base(client, h):
    p = client.post("/api/produits-epargne", json={"code": "TSOUP", "libelle": "Tontine souple", "categorie": "collecte"}, headers=h("chef1"))
    assert p.status_code == 201, p.text
    ag = client.post("/api/agents", json={"matricule": "SOUP-A1", "nom": "Agent souple"}, headers=h("chef1")).json()
    c1 = client.post("/api/clients", json={"nom": "Souple un"}, headers=h("chef1")).json()
    c2 = client.post("/api/clients", json={"nom": "Souple deux"}, headers=h("chef1")).json()
    return {"produit": p.json(), "agent": ag, "c1": c1, "c2": c2}


def _cycle(client, h, base, cle="c1", **kw):
    corps = {"client_id": base[cle]["id"], "produit_id": base["produit"]["id"], "mise": 1000, "date_debut": "2026-10-01", "date_fin": "2026-10-10", **kw}
    return client.post("/api/cycles", json=corps, headers=h("chef1"))


def test_produit_sans_type_et_type_libre_a_chaque_cycle(client, h, base):
    assert base["produit"]["type_cycle"] is None
    propose = {"client_id": base["c1"]["id"], "produit_id": base["produit"]["id"]}
    assert client.get("/api/cycles/type-propose", params=propose, headers=h("chef1")).json() == {"type_cycle": None, "impose_par": None}
    assert _cycle(client, h, base).status_code == 422                                           # le type est obligatoire
    ok = _cycle(client, h, base, type_cycle=2)
    assert ok.status_code == 201 and ok.json()["type_cycle"] == 2
    assert client.get("/api/cycles/type-propose", params=propose, headers=h("chef1")).json() == {"type_cycle": None, "impose_par": None}   # rien n'est verrouillé
    suite = _cycle(client, h, base, type_cycle=3, date_debut="2026-11-01", date_fin="2026-11-30")
    assert suite.status_code == 201 and suite.json()["type_cycle"] == 3                       # un autre type au cycle suivant
    libre = _cycle(client, h, base, cle="c2", type_cycle=3)
    assert libre.status_code == 201 and libre.json()["type_cycle"] == 3 and libre.json()["objectif"] is None                 # un autre client choisit librement


def test_delai_de_grace_et_prolongation(client, h, base):
    pid = base["produit"]["id"]
    assert client.patch(f"/api/produits-epargne/{pid}", json={"delai_grace_jours": 120}, headers=h("chef1")).status_code == 422
    assert client.patch(f"/api/produits-epargne/{pid}", json={"delai_grace_jours": 3}, headers=h("chef1")).json()["delai_grace_jours"] == 3
    cy = _cycle(client, h, base, cle="c2", type_cycle=3, date_debut="2026-12-01", date_fin="2026-12-10")
    assert cy.status_code == 201, cy.text
    cid = cy.json()["id"]
    assert cy.json()["delai_grace"] == 3 and cy.json()["date_limite"] == "2026-12-13"

    def ligne(d):
        return client.post(f"/api/cycles/{cid}/lignes", json={"lignes": [{"date_collecte": d, "montant_collecte": 1000, "agent_id": base["agent"]["id"]}]}, headers=h("chef1"))
    assert ligne("2026-12-12").status_code == 201                                             # dans le délai de grâce
    assert ligne("2026-12-14").status_code == 422                                             # au-delà de fin + grâce
    # prolongation : demandée par l'agent, autorisée par le chef
    assert client.post(f"/api/cycles/{cid}/prolongation", json={"nouvelle_fin": "2026-12-20", "motif": "court"}, headers=h("agent1")).status_code == 422
    d = client.post(f"/api/cycles/{cid}/prolongation", json={"nouvelle_fin": "2026-12-20", "motif": "Cliente absente pour deuil"}, headers=h("agent1"))
    assert d.status_code == 201 and d.json()["statut"] == "demandee" and d.json()["ancienne_fin"] == "2026-12-10"
    pr = d.json()["id"]
    assert client.post(f"/api/prolongations/{pr}/decider", json={"autorise": True}, headers=h("agent1")).status_code == 403   # pas de droit d'autoriser
    assert client.post(f"/api/prolongations/{pr}/decider", json={"autorise": False}, headers=h("chef1")).status_code == 422    # refus non motivé
    ok = client.post(f"/api/prolongations/{pr}/decider", json={"autorise": True, "commentaire": "Accord"}, headers=h("chef1"))
    assert ok.status_code == 200 and ok.json()["statut"] == "autorisee" and ok.json()["decide_par_nom"]
    assert client.get(f"/api/cycles/{cid}", headers=h("chef1")).json()["date_fin"] == "2026-12-20"
    assert ligne("2026-12-14").status_code == 201                                             # désormais possible
    assert client.post(f"/api/prolongations/{pr}/decider", json={"autorise": True}, headers=h("chef1")).status_code == 422     # déjà décidée
    assert client.get("/api/prolongations", params={"statut": "autorisee"}, headers=h("chef1")).json()[0]["cycle"]
    assert client.get("/api/prolongations", headers=h("chef2")).json() == []
    # le demandeur n'autorise pas sa propre demande
    d2 = client.post(f"/api/cycles/{cid}/prolongation", json={"nouvelle_fin": "2026-12-30", "motif": "Deuxième prolongation utile"}, headers=h("chef1")).json()
    assert client.post(f"/api/prolongations/{d2['id']}/decider", json={"autorise": True}, headers=h("chef1")).status_code == 422
    assert client.post(f"/api/prolongations/{d2['id']}/annuler", headers=h("chef1")).json()["statut"] == "annulee"


def test_suppression_tracee_et_masquee(client, h, base):
    cy = _cycle(client, h, base, cle="c1", type_cycle=2, date_debut="2027-01-01", date_fin="2027-01-31")
    assert cy.status_code == 201, cy.text
    cid = cy.json()["id"]
    lignes = [{"date_collecte": "2027-01-05", "montant_collecte": 2000, "agent_id": base["agent"]["id"]}, {"date_collecte": "2027-01-06", "montant_collecte": 2000, "agent_id": base["agent"]["id"]}]
    ids = [x["id"] for x in client.post(f"/api/cycles/{cid}/lignes", json={"lignes": lignes}, headers=h("chef1")).json()["lignes"]]
    assert client.delete(f"/api/collecte/lignes/{ids[0]}", headers=h("chef1")).status_code == 422                       # motif obligatoire
    assert client.delete(f"/api/collecte/lignes/{ids[0]}", params={"motif": "Saisie en double"}, headers=h("chef2")).status_code == 404
    assert client.delete(f"/api/collecte/lignes/{ids[0]}", params={"motif": "Saisie en double"}, headers=h("chef1")).status_code == 200
    detail = client.get(f"/api/cycles/{cid}", headers=h("chef1")).json()
    assert [x["id"] for x in detail["lignes"]] == [ids[1]] and detail["montant_collecte"] == 2000                         # la ligne supprimée n'apparaît plus
    trace = client.get("/api/audit/operations-supprimees", headers=h("auditeur")).json()
    t = next(x for x in trace if x["ligne_id"] == str(ids[0]))
    assert t["nature"] == "ligne_collecte" and t["supprime_par"] == "chef1" and t["motif"] == "Saisie en double" and t["donnees"]["montant_collecte"] == 2000
    assert t["cycle"] == cy.json()["numero"] and t["agence"]
    assert client.get("/api/audit/operations-supprimees", headers=h("chef1")).status_code == 403
    assert client.get("/api/audit/operations-supprimees", params={"nature": "retrait"}, headers=h("auditeur")).json() == []


def test_recherche_cycles_par_produit_numero_client(client, h, base):
    tous = client.get("/api/cycles", headers=h("chef1")).json()
    assert tous
    un = next(c for c in tous if c["produit"] == "TSOUP")
    par_produit = client.get("/api/cycles", params={"q": "souple"}, headers=h("chef1")).json()              # libellé du produit
    assert par_produit and all(c["produit"] == "TSOUP" or "souple" in c["client"].lower() for c in par_produit)
    assert any(c["id"] == un["id"] for c in client.get("/api/cycles", params={"q": "TSOUP"}, headers=h("chef1")).json())    # code du produit
    assert any(c["id"] == un["id"] for c in client.get("/api/cycles", params={"q": un["numero"]}, headers=h("chef1")).json())  # numéro de cycle
    num_client = client.get(f"/api/clients/{un['client_id']}", headers=h("chef1")).json()["numero"]
    assert any(c["id"] == un["id"] for c in client.get("/api/cycles", params={"q": num_client}, headers=h("chef1")).json())   # numéro de client (contenu du QR)
