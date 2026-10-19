import datetime as dt

import pytest


@pytest.fixture(scope="module")
def base(client, h, agences, produits):
    """Agence 1 : zone, agents, clients, compte classique garni, caisse et session ouverte."""
    z = client.post("/api/zones", json={"code": "ZR", "libelle": "Zone retraits"}, headers=h("chef1")).json()
    agents = [client.post("/api/agents", json={"matricule": f"R-A{i}", "nom": f"Agent R{i}"}, headers=h("chef1")).json() for i in (1, 2)]
    clients = [client.post("/api/clients", json={"nom": f"Cli Retrait {i}", "zone_id": z["id"]}, headers=h("chef1")).json() for i in (1, 2, 3, 4)]
    compte = client.post("/api/comptes-epargne", json={"client_id": clients[0]["id"], "produit_id": produits["CL"]}, headers=h("caissier1")).json()
    client.post(f"/api/comptes-epargne/{compte['id']}/depot", json={"montant": 100000}, headers=h("caissier1"))
    caisse = client.post("/api/caisses", json={"code": "CP-R"}, headers=h("chef1")).json()
    session = client.post(f"/api/caisses/{caisse['id']}/sessions", json={"date_session": "2026-10-10", "solde_ouverture": 1000000}, headers=h("caissier1")).json()
    return {"zone": z, "ag": agents, "cl": clients, "compte": compte, "session": session, "produits": produits}


def _cycle_avec_lignes(client, h, base, cl_idx, n, mise=1000, ag_idx=0, debut="2026-10-01", fin="2026-10-31", produit="P1"):
    c = client.post("/api/cycles", json={"client_id": base["cl"][cl_idx]["id"], "produit_id": base["produits"][produit], "mise": mise,
                                         "date_debut": debut, "date_fin": fin}, headers=h("chef1")).json()
    d0 = dt.date.fromisoformat(debut)
    lignes = [{"date_collecte": str(d0 + dt.timedelta(days=i)), "montant_collecte": mise, "agent_id": base["ag"][ag_idx]["id"]} for i in range(n)]
    r = client.post(f"/api/cycles/{c['id']}/lignes", json={"lignes": lignes}, headers=h("chef1"))
    assert r.status_code == 201, r.text
    return c


def test_livret_superieur_a_la_machine_surplus_puis_perte(client, h, base):
    ag = base["ag"][0]["id"]
    c = _cycle_avec_lignes(client, h, base, 0, 5)
    # versements de fin de tournée : sans écart, manquant 200, surplus 300
    v1 = client.post(f"/api/agents/{ag}/versement", json={"date_tournee": "2026-10-01", "montant_verse": 1000}, headers=h("caissier1"))
    assert v1.status_code == 201 and v1.json()["ecart"] == 0
    assert client.post(f"/api/agents/{ag}/versement", json={"date_tournee": "2026-10-02", "montant_verse": 800}, headers=h("caissier1")).json()["ecart"] == 200
    assert client.post(f"/api/agents/{ag}/versement", json={"date_tournee": "2026-10-03", "montant_verse": 1300}, headers=h("caissier1")).json()["ecart"] == -300
    assert client.post(f"/api/agents/{ag}/versement", json={"date_tournee": "2026-10-03", "montant_verse": 1}, headers=h("caissier1")).status_code == 409
    assert client.post(f"/api/agents/{ag}/versement", json={"date_tournee": "2026-10-04", "montant_verse": 1000}, headers=h("agent1")).status_code == 403
    compte = client.get(f"/api/agents/{ag}/compte", headers=h("chef1")).json()
    assert compte["solde"] == -200
    s = client.get("/api/surplus", params={"agent_id": ag}, headers=h("chef1")).json()
    assert len(s) == 1 and s[0]["montant"] == 300 and s[0]["bloque"] is True

    # demande de retrait : clôture anticipée du cycle, net machine = 5000 - mise
    r = client.post(f"/api/cycles/{c['id']}/retrait", json={"nature": "retrait_client", "date": "2026-10-10"}, headers=h("caissier1"))
    assert r.status_code == 201, r.text
    rid = r.json()["id"]
    assert (r.json()["montant"], r.json()["statut"], r.json()["decaissement"]) == (4000, "demande", True)
    assert client.post(f"/api/retraits/{rid}/executer", json={"session_id": base["session"]["id"]}, headers=h("caissier1")).status_code == 422  # pas constaté
    # le caissier ne constate pas les écarts : c'est le rôle du responsable
    corps = {"montant_livret": 5500, "montant_machine": 5000, "details": [{"date": "2026-10-03", "montant": 500, "agent_id": ag}]}
    assert client.post(f"/api/retraits/{rid}/ecart", json=corps, headers=h("caissier1")).status_code == 403
    assert client.post(f"/api/retraits/{rid}/ecart", json={**corps, "montant_machine": 4999}, headers=h("chef1")).status_code == 422
    r = client.post(f"/api/retraits/{rid}/ecart", json=corps, headers=h("chef1"))
    assert r.status_code == 201 and r.json()["statut"] == "ecart_en_traitement" and r.json()["ecart"] == 500
    assert r.json()["ecarts"][0]["details"][0]["montant"] == 500
    assert client.post(f"/api/retraits/{rid}/executer", json={"session_id": base["session"]["id"]}, headers=h("caissier1")).status_code == 422

    ecart_id = r.json()["ecarts"][0]["id"]
    t = client.post(f"/api/ecarts/{ecart_id}/traiter", json={}, headers=h("chef1"))
    assert t.status_code == 200 and t.json()["perte_imputee_aux_agents"] == 200 and t.json()["retrait"]["statut"] == "fonds_disponibles"
    assert client.get(f"/api/agents/{ag}/compte", headers=h("chef1")).json()["solde"] == -400     # manquant 200 + perte 200
    assert client.post(f"/api/ecarts/{ecart_id}/traiter", json={}, headers=h("chef1")).status_code == 422

    # paiement en espèces : session de caisse obligatoire
    assert client.post(f"/api/retraits/{rid}/executer", json={}, headers=h("caissier1")).status_code == 422
    avant = client.get(f"/api/sessions/{base['session']['id']}", headers=h("caissier1")).json()["solde_theorique"]
    e = client.post(f"/api/retraits/{rid}/executer", json={"session_id": base["session"]["id"]}, headers=h("caissier1"))
    assert e.status_code == 200 and e.json()["montant_paye"] == 4500 and e.json()["statut"] == "execute"
    apres = client.get(f"/api/sessions/{base['session']['id']}", headers=h("caissier1")).json()
    assert avant - apres["solde_theorique"] == 4500                     # le client est payé selon le livret
    assert client.get(f"/api/cycles/{c['id']}", headers=h("chef1")).json()["statut"] == "retire"
    assert client.get("/api/surplus", params={"agent_id": ag}, headers=h("chef1")).json()[0]["statut"] == "solde"


def test_retrait_virement_vers_epargne(client, h, base):
    c = _cycle_avec_lignes(client, h, base, 0, 10, ag_idx=1, debut="2026-11-01", fin="2026-11-30")
    r = client.post(f"/api/cycles/{c['id']}/retrait", json={"nature": "virement_vers_epargne"}, headers=h("caissier1"))
    assert r.status_code == 422                                      # compte obligatoire
    r = client.post(f"/api/cycles/{c['id']}/retrait", json={"nature": "virement_vers_epargne", "compte_id": base["compte"]["id"], "date": "2026-11-20"}, headers=h("caissier1"))
    assert r.status_code == 201 and r.json()["decaissement"] is False and r.json()["virement"]["statut"] == "demande"
    rid = r.json()["id"]
    assert client.post(f"/api/retraits/{rid}/constat-sans-ecart", headers=h("caissier1")).status_code == 403
    assert client.post(f"/api/retraits/{rid}/constat-sans-ecart", headers=h("chef1")).status_code == 200
    solde_avant = client.get(f"/api/comptes-epargne/{base['compte']['id']}", headers=h("caissier1")).json()["solde"]
    e = client.post(f"/api/retraits/{rid}/executer", json={}, headers=h("caissier1"))        # sans décaissement : pas de session requise
    assert e.status_code == 200 and e.json()["virement"]["statut"] == "execute" and e.json()["virement"]["montant_credite"] == 9000
    assert client.get(f"/api/comptes-epargne/{base['compte']['id']}", headers=h("caissier1")).json()["solde"] == solde_avant + 9000


def test_machine_superieure_au_livret_excedent_puis_purge(client, h, base):
    ag = base["ag"][1]["id"]
    c = _cycle_avec_lignes(client, h, base, 1, 4, ag_idx=1, debut="2026-12-01", fin="2026-12-31")
    rid = client.post(f"/api/cycles/{c['id']}/retrait", json={"nature": "retrait_client", "date": "2026-12-20"}, headers=h("caissier1")).json()["id"]
    r = client.post(f"/api/retraits/{rid}/ecart", json={"montant_livret": 3800, "montant_machine": 4000,
                                                       "details": [{"date": "2026-12-02", "montant": 200}]}, headers=h("chef1"))
    assert r.status_code == 201 and r.json()["statut"] == "fonds_disponibles"                  # pas d'écart à traiter côté agent
    assert client.post("/api/collecte/purger-dates", json={"jusqu_au": "2026-12-31"}, headers=h("caissier1")).status_code == 403
    assert client.post(f"/api/retraits/{rid}/executer", json={"session_id": base["session"]["id"]}, headers=h("caissier1")).json()["montant_paye"] == 2800
    p = client.post("/api/collecte/purger-dates", json={"jusqu_au": "2026-12-31"}, headers=h("chef1"))
    assert p.status_code == 200 and p.json()["dates_purgees"] >= 1
    s = [x for x in client.get("/api/surplus", params={"agent_id": ag}, headers=h("chef1")).json() if x["origine"] == "regularisation"]
    assert len(s) == 1 and s[0]["montant"] == 200


def test_virement_epargne_vers_tontine(client, h, base):
    cy = client.post("/api/cycles", json={"client_id": base["cl"][0]["id"], "produit_id": base["produits"]["P1"], "mise": 500,
                                          "date_debut": "2026-10-01", "date_fin": "2026-10-31"}, headers=h("chef1")).json()
    corps = {"compte_id": base["compte"]["id"], "cycle_id": cy["id"], "montant": 3000, "date": "2026-10-10"}
    solde0 = client.get(f"/api/comptes-epargne/{base['compte']['id']}", headers=h("caissier1")).json()["solde"]
    r = client.post("/api/virements/epargne-vers-tontine", json=corps, headers=h("caissier1"))
    assert r.status_code == 201 and r.json()["statut"] == "execute"
    d = client.get(f"/api/cycles/{cy['id']}", headers=h("chef1")).json()
    assert d["nb_lignes"] == 6 and d["montant_collecte"] == 3000 and {l["origine"] for l in d["lignes"]} == {"virement"}
    assert client.get(f"/api/comptes-epargne/{base['compte']['id']}", headers=h("caissier1")).json()["solde"] == solde0 - 3000
    assert client.post("/api/virements/epargne-vers-tontine", json={**corps, "montant": 3100}, headers=h("caissier1")).status_code == 422   # pas un multiple de la mise
    assert client.post("/api/virements/epargne-vers-tontine", json={**corps, "montant": 99000000}, headers=h("caissier1")).status_code == 422  # fonds insuffisants
    assert client.post("/api/virements/epargne-vers-tontine", json=corps, headers=h("agent1")).status_code == 403
    assert len(client.get("/api/virements", params={"cycle_id": cy["id"]}, headers=h("chef1")).json()) == 1


def test_isolation_et_droits(client, h, base):
    c = _cycle_avec_lignes(client, h, base, 3, 3, debut="2027-01-01", fin="2027-01-31")
    rid = client.post(f"/api/cycles/{c['id']}/retrait", json={"nature": "retrait_client"}, headers=h("chef1")).json()["id"]
    assert client.get(f"/api/retraits/{rid}", headers=h("chef2")).status_code == 404
    assert client.get(f"/api/retraits/{rid}", headers=h("auditeur")).status_code == 200
    assert client.post(f"/api/retraits/{rid}/constat-sans-ecart", headers=h("auditeur")).status_code == 403
    assert client.post(f"/api/retraits/{rid}/constat-sans-ecart", headers=h("chef2")).status_code == 404
    assert rid in [x["id"] for x in client.get("/api/retraits", params={"statut": "demande"}, headers=h("chef1")).json()]
    assert client.get("/api/retraits", headers=h("chef2")).json() == []
    # une session de caisse d'une autre agence est refusée
    autre = client.post("/api/caisses", json={"code": "CP-2"}, headers=h("chef2")).json()
    s2 = client.post(f"/api/caisses/{autre['id']}/sessions", json={"date_session": "2027-01-10", "solde_ouverture": 10}, headers=h("caissier2")).json()
    client.post(f"/api/retraits/{rid}/constat-sans-ecart", headers=h("chef1"))
    assert client.post(f"/api/retraits/{rid}/executer", json={"session_id": s2["id"]}, headers=h("caissier1")).status_code == 404


def test_reglement_du_compte_agent(client, h, base):
    ag = base["ag"][0]["id"]
    avant = client.get(f"/api/agents/{ag}/compte", headers=h("chef1")).json()["solde"]
    assert avant < 0
    r = client.post(f"/api/agents/{ag}/compte/reglement", json={"montant": -avant}, headers=h("caissier1"))
    assert r.status_code == 201 and r.json()["solde"] == 0
    assert client.post(f"/api/agents/{ag}/compte/reglement", json={"montant": 0}, headers=h("caissier1")).status_code == 422
