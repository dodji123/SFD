import pytest

from tests.helpers import make_user


@pytest.fixture(scope="module")
def base(client, h, sql, agences, produits):
    """Agence 1 : zone, deux agents (un compte « agent » lié au premier), deux clients."""
    a1 = agences["a1"]
    z = client.post("/api/zones", json={"code": "ZC", "libelle": "Zone collecte"}, headers=h("chef1")).json()
    ag1 = client.post("/api/agents", json={"matricule": "C-A1", "nom": "Agent Un"}, headers=h("chef1")).json()
    ag2 = client.post("/api/agents", json={"matricule": "C-A2", "nom": "Agent Deux"}, headers=h("chef1")).json()
    make_user(sql, "agent_lie", "agent", a1, agent_id=ag1["id"])
    c1 = client.post("/api/clients", json={"nom": "Cli Collecte 1", "zone_id": z["id"]}, headers=h("chef1")).json()
    c2 = client.post("/api/clients", json={"nom": "Cli Collecte 2", "zone_id": z["id"]}, headers=h("chef1")).json()
    return {"zone": z, "ag1": ag1, "ag2": ag2, "c1": c1, "c2": c2, "produits": produits}


def _cycle(client, h, base, client_key="c1", produit="P1", mise=1000, debut="2026-10-01", fin="2026-10-31", **kw):
    r = client.post("/api/cycles", json={"client_id": base[client_key]["id"], "produit_id": base["produits"][produit],
                                         "mise": mise, "date_debut": debut, "date_fin": fin, **kw}, headers=h("chef1"))
    assert r.status_code == 201, r.text
    return r.json()


def _lignes(client, h, cycle_id, agent_id, n, montant=1000, debut="2026-10-01", login="chef1"):
    import datetime as dt
    d0 = dt.date.fromisoformat(debut)
    corps = {"lignes": [{"date_collecte": str(d0 + dt.timedelta(days=i)), "montant_collecte": montant, "agent_id": agent_id} for i in range(n)]}
    return client.post(f"/api/cycles/{cycle_id}/lignes", json=corps, headers=h(login))


def test_creation_cycle_type1(client, h, base):
    c = _cycle(client, h, base)
    assert c["numero"].startswith("CY-T1-") and c["type_cycle"] == 1 and c["statut"] == "en_cours"
    assert c["objectif"] == 31000 and c["nb_lignes_prevues"] == 31          # défauts : 31 x mise
    assert c["montant_previsionnel"] == 31000 and c["reste_a_collecter"] == 31000 and c["net"] == -1000


def test_creation_refus(client, h, base):
    corps = {"client_id": base["c1"]["id"], "produit_id": base["produits"]["CL"], "mise": 500, "date_debut": "2026-10-01", "date_fin": "2026-10-31"}
    assert client.post("/api/cycles", json=corps, headers=h("chef1")).status_code == 422          # produit classique
    assert client.post("/api/cycles", json={**corps, "produit_id": base["produits"]["P1"], "date_fin": "2026-09-01"}, headers=h("chef1")).status_code == 422
    assert client.post("/api/cycles", json={**corps, "produit_id": base["produits"]["P1"]}, headers=h("caissier1")).status_code == 403
    assert client.post("/api/cycles", json={**corps, "produit_id": base["produits"]["P1"]}, headers=h("chef2")).status_code == 404  # client d'une autre agence


def test_saisie_du_livret_et_situation(client, h, base):
    c = _cycle(client, h, base, client_key="c2")
    r = _lignes(client, h, c["id"], base["ag1"]["id"], 6, montant=500)
    assert r.status_code == 201, r.text
    d = r.json()
    assert (d["nb_lignes"], d["montant_collecte"]) == (6, 3000)
    assert d["montant_previsionnel"] == 31000 and d["reste_a_collecter"] == 28000
    assert [(l["page"], l["no_ligne"]) for l in d["lignes"]] == [(1, i) for i in range(1, 7)]   # numérotation automatique
    assert d["lignes"][0]["mise_appliquee"] == 1000                                              # mise en vigueur, pas le montant
    # la suite du livret continue à la ligne 7
    r = _lignes(client, h, c["id"], base["ag1"]["id"], 2, montant=1000, debut="2026-10-10")
    assert [l["no_ligne"] for l in r.json()["lignes"]][-2:] == [7, 8]


def test_livret_de_31_lignes(client, h, base):
    c = _cycle(client, h, base, mise=100, debut="2026-01-01", fin="2026-03-31")
    assert _lignes(client, h, c["id"], base["ag1"]["id"], 31, montant=100, debut="2026-01-01").status_code == 201
    r = _lignes(client, h, c["id"], base["ag1"]["id"], 1, montant=100, debut="2026-02-15")
    assert r.status_code == 422 and "page" in r.json()["detail"].lower()    # la 32e ligne n'a pas de page


def test_lot_tout_ou_rien(client, h, base):
    c = _cycle(client, h, base, mise=100)
    corps = {"lignes": [{"date_collecte": "2026-10-02", "montant_collecte": 100, "agent_id": base["ag1"]["id"]},
                        {"date_collecte": "2020-01-01", "montant_collecte": 100, "agent_id": base["ag1"]["id"]}]}   # avant le début du cycle
    assert client.post(f"/api/cycles/{c['id']}/lignes", json=corps, headers=h("chef1")).status_code == 422
    assert client.get(f"/api/cycles/{c['id']}", headers=h("chef1")).json()["nb_lignes"] == 0   # la 1re ligne a été annulée aussi


def test_agent_ne_saisit_que_ses_collectes(client, h, base, utilisateurs):
    c = _cycle(client, h, base, mise=100)
    # connexion du compte lié à l'agent 1
    tok = client.post("/api/auth/login", json={"login": "agent_lie", "mot_de_passe": "MotDePasse-Test-1"}).json()["access_token"]
    hdr = {"Authorization": "Bearer " + tok}
    corps = lambda ag: {"lignes": [{"date_collecte": "2026-10-02", "montant_collecte": 100, **({"agent_id": ag} if ag else {})}]}
    assert client.post(f"/api/cycles/{c['id']}/lignes", json=corps(base["ag2"]["id"]), headers=hdr).status_code == 403
    r = client.post(f"/api/cycles/{c['id']}/lignes", json=corps(None), headers=hdr)           # agent déduit du compte
    assert r.status_code == 201 and r.json()["lignes"][0]["agent_id"] == base["ag1"]["id"]
    # un chef d'agence doit préciser l'agent
    assert client.post(f"/api/cycles/{c['id']}/lignes", json=corps(None), headers=h("chef1")).status_code == 422
    # un agent sans lien avec un agent est refusé
    assert client.post(f"/api/cycles/{c['id']}/lignes", json=corps(None), headers=h("agent1")).status_code == 403


def test_changement_de_mise(client, h, base):
    c = _cycle(client, h, base, mise=500)
    _lignes(client, h, c["id"], base["ag1"]["id"], 3, montant=500)
    r = client.post(f"/api/cycles/{c['id']}/mise", json={"mise": 1000, "date_effet": "2026-10-02"}, headers=h("chef1"))
    assert r.status_code == 422                                                     # fausserait le passé
    r = client.post(f"/api/cycles/{c['id']}/mise", json={"mise": 1000, "date_effet": "2026-10-04", "motif": "hausse"}, headers=h("chef1"))
    assert r.status_code == 200 and r.json()["mise_courante"] == 1000 and len(r.json()["mises"]) == 2
    d = _lignes(client, h, c["id"], base["ag1"]["id"], 1, montant=1000, debut="2026-10-04").json()
    assert [l["mise_appliquee"] for l in d["lignes"]] == [500, 500, 500, 1000]


def test_cloture_type3_et_refus_apres_cloture(client, h, base):
    c = _cycle(client, h, base, produit="P3", mise=500)
    assert c["objectif"] is None and c["montant_previsionnel"] is None
    _lignes(client, h, c["id"], base["ag1"]["id"], 2, montant=10000)
    r = client.post(f"/api/cycles/{c['id']}/cloturer", json={"date": "2026-10-31"}, headers=h("chef1"))
    assert r.status_code == 200 and r.json()["statut"] == "clos"
    assert r.json()["mise_finale"] == 650 and r.json()["net"] == 19350                # arrondi(20000 / 31) = 650
    assert _lignes(client, h, c["id"], base["ag1"]["id"], 1, debut="2026-10-05").status_code == 422   # cycle clos
    assert client.post(f"/api/cycles/{c['id']}/cloturer", json={}, headers=h("chef1")).status_code == 422  # déjà clos
    assert client.post(f"/api/cycles/{c['id']}/cloturer", json={}, headers=h("agent1")).status_code == 403


def test_cloture_planifiee(client, h, base, agences):
    c = _cycle(client, h, base, mise=100, debut="2025-01-01", fin="2025-01-31")
    r = client.post("/api/collecte/cloturer-echus", json={"date": "2026-10-05"}, headers=h("chef1"))
    assert r.status_code == 200 and r.json()["cycles_clotures"] >= 1
    assert client.get(f"/api/cycles/{c['id']}", headers=h("chef1")).json()["statut"] == "clos"
    # le siège doit désigner l'agence ; un autre chef d'agence ne touche pas à cette agence
    assert client.post("/api/collecte/cloturer-echus", json={}, headers=h("admin")).status_code == 400
    assert client.post("/api/collecte/cloturer-echus", json={"agence_id": agences["a1"]}, headers=h("chef2")).status_code == 403


def test_liste_isolation_et_lecture_seule(client, h, base):
    c = _cycle(client, h, base)
    assert any(x["id"] == c["id"] for x in client.get("/api/cycles", headers=h("chef1")).json())
    assert client.get("/api/cycles", headers=h("chef2")).json() == []
    assert client.get(f"/api/cycles/{c['id']}", headers=h("chef2")).status_code == 404
    assert client.get(f"/api/cycles/{c['id']}", headers=h("auditeur")).status_code == 200
    assert client.post(f"/api/cycles/{c['id']}/lignes", json={"lignes": [{"date_collecte": "2026-10-02", "montant_collecte": 1, "agent_id": 1}]},
                       headers=h("auditeur")).status_code == 403
    filtre = client.get("/api/cycles", params={"client_id": base["c1"]["id"], "statut": "en_cours"}, headers=h("chef1")).json()
    assert filtre and all(x["client_id"] == base["c1"]["id"] and x["statut"] == "en_cours" for x in filtre)


def test_feuille_de_collecte_du_jour(client, h, base):
    c = _cycle(client, h, base, client_key="c2", mise=700)
    _lignes(client, h, c["id"], base["ag2"]["id"], 1, montant=700, debut="2026-11-15")
    r = client.get("/api/collecte/journee", params={"agent_id": base["ag2"]["id"], "date": "2026-11-15"}, headers=h("caissier1"))
    assert r.status_code == 200
    j = r.json()
    assert j["total_collecte"] == 700 and j["nb_lignes"] == 1 and j["versement"] is None
    assert client.get("/api/collecte/journee", params={"agent_id": base["ag2"]["id"], "date": "2026-11-15"}, headers=h("chef2")).status_code == 404


def test_formulaire_de_saisie(client, h, base):
    """Recherche du client par son numéro, montant multiple de la mise (sauf type 3), saisie par le siège pour un agent."""
    c = _cycle(client, h, base, client_key="c1", mise=500, debut="2026-10-05", fin="2026-11-04")
    num = str(int(base["c1"]["numero"].split("-")[-1]))        # l'opérateur ne tape que le numéro d'ordre
    p = {"suffixe": num, "produit_id": base["produits"]["P1"], "date": "2026-10-06"}
    r = client.get("/api/collecte/client-cycle", params=p, headers=h("chef1"))
    assert r.status_code == 200, r.text
    d = r.json()
    assert d["client"]["nom"] == "Cli Collecte 1" and d["cycle"]["mise_courante"] == 500
    assert client.get("/api/collecte/client-cycle", params={**p, "suffixe": "987654"}, headers=h("chef1")).status_code == 404
    assert client.get("/api/collecte/client-cycle", params={**p, "zone_id": base["zone"]["id"] + 9999}, headers=h("chef1")).status_code == 422
    assert client.get("/api/collecte/client-cycle", params={**p, "produit_id": base["produits"]["P2"]}, headers=h("chef1")).status_code == 404
    corps = {"cycle_id": c["id"], "agent_id": base["ag2"]["id"], "date_collecte": "2026-10-06", "montant_collecte": 1500}
    r = client.post("/api/collecte/saisie", json={**corps, "montant_collecte": 750}, headers=h("chef1"))
    assert r.status_code == 422 and "multiple" in r.json()["detail"]
    assert client.post("/api/collecte/saisie", json={**corps, "date_collecte": "2999-01-01"}, headers=h("chef1")).status_code == 422
    ok = client.post("/api/collecte/saisie", json=corps, headers=h("chef1"))
    assert ok.status_code == 201, ok.text
    assert ok.json()["montant_collecte"] >= 1500 and ok.json()["lignes"][-1]["agent_id"] == base["ag2"]["id"]
    # type 3 : montant libre
    c3 = _cycle(client, h, base, client_key="c2", produit="P3", mise=500, debut="2026-10-05", fin="2026-11-04")
    r = client.post("/api/collecte/saisie", json={"cycle_id": c3["id"], "agent_id": base["ag1"]["id"], "date_collecte": "2026-10-06", "montant_collecte": 730}, headers=h("chef1"))
    assert r.status_code == 201, r.text


def test_tableau_correction_et_validation_de_la_journee(client, h, base):
    ag = base["ag1"]["id"]
    c = _cycle(client, h, base, client_key="c2", mise=500, debut="2026-09-01", fin="2026-09-30")
    jour = "2026-09-15"
    s = lambda m, login="chef1": client.post("/api/collecte/saisie", json={"cycle_id": c["id"], "agent_id": ag, "date_collecte": jour, "montant_collecte": m}, headers=h(login))
    assert s(1000).status_code == 201
    t = client.get("/api/collecte/jour", params={"date": jour}, headers=h("chef1")).json()
    mine = [l for l in t["lignes"] if l["cycle_id"] == c["id"]]
    assert len(mine) == 1 and mine[0]["modifiable"] is True and t["validee"] is False and mine[0]["souscription"] == c["numero"]
    lid = mine[0]["id"]
    # correction : même règle du multiple de la mise
    assert client.put(f"/api/collecte/lignes/{lid}", json={"montant_collecte": 750}, headers=h("chef1")).status_code == 422
    assert client.put(f"/api/collecte/lignes/{lid}", json={"montant_collecte": 1500}, headers=h("chef1")).status_code == 200
    assert client.put(f"/api/collecte/lignes/{lid}", json={"montant_collecte": 1500}, headers=h("chef2")).status_code == 404       # autre agence
    assert s(500).status_code == 201
    extra = [l for l in client.get("/api/collecte/jour", params={"date": jour}, headers=h("chef1")).json()["lignes"] if l["cycle_id"] == c["id"]]
    assert sorted(l["montant_collecte"] for l in extra) == [500, 1500]
    assert client.delete(f"/api/collecte/lignes/{extra[0]['id']}", headers=h("chef1")).status_code == 200
    # validation globale : réservée au chef / admin, puis plus aucune modification
    assert client.post("/api/collecte/valider-journee", json={"date": jour}, headers=h("agent_lie")).status_code == 403
    v = client.post("/api/collecte/valider-journee", json={"date": jour}, headers=h("chef1"))
    assert v.status_code == 201 and v.json()["validee"] is True and all(l["modifiable"] is False for l in v.json()["lignes"])
    assert client.delete(f"/api/collecte/lignes/{lid}", headers=h("chef1")).status_code == 422
    assert s(500).status_code == 422
    assert client.post("/api/collecte/valider-journee", json={"date": jour}, headers=h("chef1")).status_code == 422
    # réouverture : motif obligatoire
    assert client.post("/api/collecte/rouvrir-journee", json={"date": jour}, headers=h("chef1")).status_code == 422
    assert client.post("/api/collecte/rouvrir-journee", json={"date": jour, "motif": "oubli d'une collecte"}, headers=h("chef1")).status_code == 200
    assert s(500).status_code == 201


def test_zone_et_agent_responsable(client, h, base):
    z = client.patch(f"/api/zones/{base['zone']['id']}", json={"agent_id": base["ag1"]["id"]}, headers=h("chef1"))
    assert z.status_code == 200 and z.json()["agent_id"] == base["ag1"]["id"]
    zs = client.get("/api/zones", headers=h("chef1")).json()
    assert next(x for x in zs if x["id"] == base["zone"]["id"])["agent_id"] == base["ag1"]["id"]
    assert client.patch(f"/api/zones/{base['zone']['id']}", json={"agent_id": 99999}, headers=h("chef1")).status_code == 422
    assert client.patch(f"/api/zones/{base['zone']['id']}", json={"agent_id": None}, headers=h("chef1")).json()["agent_id"] is None


def test_montant_limite_a_l_encours_de_collecte(client, h, base):
    ag = base["ag1"]["id"]
    c = _cycle(client, h, base, client_key="c1", mise=500, debut="2026-10-01", fin="2026-10-31", nb_lignes_prevues=4)   # encours de départ : 4 x 500 = 2000
    s = lambda m, jour="2026-10-07": client.post("/api/collecte/saisie", json={"cycle_id": c["id"], "agent_id": ag, "date_collecte": jour, "montant_collecte": m}, headers=h("chef1"))
    r = s(2500)
    assert r.status_code == 422 and "encours" in r.json()["detail"] and "2000" in r.json()["detail"]
    assert s(2000).status_code == 201                                                       # le plein encours est accepté
    r = s(500, "2026-10-08")
    assert r.status_code == 422 and "encours" in r.json()["detail"]                         # plus rien à collecter
    # correction : le maximum tient compte de l'ancien montant de la ligne
    lid = next(l["id"] for l in client.get("/api/collecte/jour", params={"date": "2026-10-07"}, headers=h("chef1")).json()["lignes"] if l["cycle_id"] == c["id"])
    assert client.put(f"/api/collecte/lignes/{lid}", json={"montant_collecte": 2500}, headers=h("chef1")).status_code == 422
    assert client.put(f"/api/collecte/lignes/{lid}", json={"montant_collecte": 1500}, headers=h("chef1")).status_code == 200
    assert s(500, "2026-10-09").status_code == 201                                          # il reste 500 après la correction
    # type 3 : collecte libre, pas de plafond
    c3 = _cycle(client, h, base, client_key="c2", produit="P3", mise=500, debut="2026-10-01", fin="2026-10-31")
    assert client.post("/api/collecte/saisie", json={"cycle_id": c3["id"], "agent_id": ag, "date_collecte": "2026-10-07", "montant_collecte": 987654}, headers=h("chef1")).status_code == 201
