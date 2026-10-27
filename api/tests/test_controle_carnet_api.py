import datetime as dt

import pytest


@pytest.fixture(scope="module")
def cycle_carnet(client, h, produits):
    """Agent, cycle de 5 collectes de 1 000 F (1er au 5 octobre)."""
    z = client.post("/api/zones", json={"code": "ZC", "libelle": "Zone carnet"}, headers=h("chef1")).json()
    ag = client.post("/api/agents", json={"matricule": "C-A1", "nom": "Agent C1"}, headers=h("chef1")).json()
    cl = client.post("/api/clients", json={"nom": "Cli Carnet", "zone_id": z["id"]}, headers=h("chef1")).json()
    c = client.post("/api/cycles", json={"client_id": cl["id"], "produit_id": produits["P1"], "mise": 1000,
                                         "date_debut": "2026-10-01", "date_fin": "2026-10-31"}, headers=h("chef1")).json()
    d0 = dt.date(2026, 10, 1)
    lignes = [{"date_collecte": str(d0 + dt.timedelta(days=i)), "montant_collecte": 1000, "agent_id": ag["id"]} for i in range(5)]
    assert client.post(f"/api/cycles/{c['id']}/lignes", json={"lignes": lignes}, headers=h("chef1")).status_code == 201
    return {"cycle": c, "client": cl}


def test_cycles_de_la_periode_par_produit(client, h, cycle_carnet, produits):
    r = client.get("/api/controle-carnet/cycles", params={"du": "2026-10-01", "au": "2026-10-31", "produit_id": produits["P1"]},
                   headers=h("chef1"))
    assert r.status_code == 200, r.text
    assert any(x["id"] == cycle_carnet["cycle"]["id"] and x["dernier_controle"] is None for x in r.json())


def test_lignes_du_cycle_dans_l_ordre_du_tableau(client, h, cycle_carnet):
    lignes = client.get(f"/api/controle-carnet/cycles/{cycle_carnet['cycle']['id']}/lignes", headers=h("chef1")).json()
    assert len(lignes) == 5
    assert [l["date_collecte"] for l in lignes] == sorted(l["date_collecte"] for l in lignes)


def test_controle_incomplet_refusé(client, h, cycle_carnet):
    cid = cycle_carnet["cycle"]["id"]
    lignes = client.get(f"/api/controle-carnet/cycles/{cid}/lignes", headers=h("chef1")).json()
    r = client.post(f"/api/controle-carnet/cycles/{cid}/controles",
                    json={"lignes": [{"ligne_id": l["id"], "montant_carnet": 1000} for l in lignes[:4]]}, headers=h("chef1"))
    assert r.status_code == 422, r.text


def test_caissier_ne_controle_pas(client, h, cycle_carnet):
    cid = cycle_carnet["cycle"]["id"]
    lignes = client.get(f"/api/controle-carnet/cycles/{cid}/lignes", headers=h("chef1")).json()
    r = client.post(f"/api/controle-carnet/cycles/{cid}/controles",
                    json={"lignes": [{"ligne_id": l["id"], "montant_carnet": 1000} for l in lignes]}, headers=h("caissier1"))
    assert r.status_code == 403


def test_controle_complet_enregistre_les_ecarts(client, h, cycle_carnet):
    cid = cycle_carnet["cycle"]["id"]
    lignes = client.get(f"/api/controle-carnet/cycles/{cid}/lignes", headers=h("chef1")).json()
    saisie = [{"ligne_id": l["id"], "montant_carnet": 2000 if i == 0 else 1000} for i, l in enumerate(lignes)]
    r = client.post(f"/api/controle-carnet/cycles/{cid}/controles",
                    json={"date_controle": "2026-10-15", "lignes": saisie, "commentaire": "contrôle test"}, headers=h("chef1"))
    assert r.status_code == 201, r.text
    assert r.json()["total_collecte"] == 5000 and r.json()["total_carnet"] == 6000 and r.json()["ecart_collecte"] == 1000

    historique = client.get(f"/api/controle-carnet/cycles/{cid}/controles", headers=h("chef1")).json()
    assert historique[0]["date_controle"] == "2026-10-15"
    assert [l["ecart"] for l in historique[0]["lignes"]].count(1000) == 1
    assert sum(1 for l in historique[0]["lignes"] if l["ecart"] == 0) == 4


def test_cycle_controle_affiche_sa_date(client, h, cycle_carnet, produits):
    r = client.get("/api/controle-carnet/cycles", params={"du": "2026-10-01", "au": "2026-10-31", "produit_id": produits["P1"]},
                   headers=h("chef1")).json()
    ligne = next(x for x in r if x["id"] == cycle_carnet["cycle"]["id"])
    assert ligne["dernier_controle"] == "2026-10-15"


def test_periode_inversee_renvoie_vide(client, h, cycle_carnet):
    r = client.get("/api/controle-carnet/cycles", params={"du": "2026-10-31", "au": "2026-10-01"}, headers=h("chef1"))
    assert r.status_code == 200 and r.json() == []


def test_montant_carnet_multiple_de_la_mise(client, h, cycle_carnet):
    cid = cycle_carnet["cycle"]["id"]
    lignes = client.get(f"/api/controle-carnet/cycles/{cid}/lignes", headers=h("chef1")).json()
    r = client.post(f"/api/controle-carnet/cycles/{cid}/controles",
                    json={"lignes": [{"ligne_id": l["id"], "montant_carnet": 1500} for l in lignes]}, headers=h("chef1"))
    assert r.status_code == 422, r.text


def test_un_seul_controle_par_cycle_puis_modification_de_valeurs(client, h, cycle_carnet):
    cid = cycle_carnet["cycle"]["id"]
    lignes = client.get(f"/api/controle-carnet/cycles/{cid}/lignes", headers=h("chef1")).json()
    saisie = [{"ligne_id": l["id"], "montant_carnet": 2000 if i == 0 else 1000} for i, l in enumerate(lignes)]
    assert client.post(f"/api/controle-carnet/cycles/{cid}/controles", json={"lignes": saisie}, headers=h("chef1")).status_code == 422
    assert client.put(f"/api/controle-carnet/cycles/{cid}/controle", json={"motif": "ok", "lignes": saisie}, headers=h("chef1")).status_code == 422
    # valeurs inchangées : la modification est acceptée, l'écart reste celui du contrôle initial (1 000)
    r = client.put(f"/api/controle-carnet/cycles/{cid}/controle", json={"motif": "relecture du contrôle", "lignes": saisie}, headers=h("chef1"))
    assert r.status_code == 200, r.text
    assert r.json()["ecart_collecte"] == 1000


def test_recherche_du_client_par_nom_ou_numero(client, h, cycle_carnet, produits):
    base = {"du": "2026-10-01", "au": "2026-10-31", "produit_id": produits["P1"]}
    par_nom = client.get("/api/controle-carnet/cycles", params={**base, "q": "carnet"}, headers=h("chef1")).json()
    assert [x["id"] for x in par_nom] == [cycle_carnet["cycle"]["id"]]
    par_numero = client.get("/api/controle-carnet/cycles", params={**base, "q": cycle_carnet["client"]["numero"]}, headers=h("chef1")).json()
    assert [x["id"] for x in par_numero] == [cycle_carnet["cycle"]["id"]]
    assert client.get("/api/controle-carnet/cycles", params={**base, "q": "introuvable"}, headers=h("chef1")).json() == []


def test_annulation_du_controle_en_vigueur(client, h, cycle_carnet):
    cid = cycle_carnet["cycle"]["id"]
    assert client.post(f"/api/controle-carnet/cycles/{cid}/controle/annuler", json={"motif": "trop court"}, headers=h("caissier1")).status_code == 403
    r = client.post(f"/api/controle-carnet/cycles/{cid}/controle/annuler", json={"motif": "contrôle remplacé"}, headers=h("chef1"))
    assert r.status_code == 200, r.text
    historique = client.get(f"/api/controle-carnet/cycles/{cid}/controles", headers=h("chef1")).json()
    assert historique[0]["annule"] is True and historique[0]["motif_annulation"] == "contrôle remplacé"
    assert client.put(f"/api/controle-carnet/cycles/{cid}/controle", json={"motif": "après annulation", "lignes": [
        {"ligne_id": l["id"], "montant_carnet": 1000} for l in client.get(f"/api/controle-carnet/cycles/{cid}/lignes", headers=h("chef1")).json()
    ]}, headers=h("chef1")).status_code == 404


def test_reglement_des_manquants_du_controle(client, h, cycle_carnet):
    cid = cycle_carnet["cycle"]["id"]
    controle_id = client.get(f"/api/controle-carnet/cycles/{cid}/controles", headers=h("chef1")).json()[0]["id"]
    r = client.post(f"/api/controle-carnet/controles/{controle_id}/regler-manquants", headers=h("chef1"))
    assert r.status_code == 200, r.text
    assert r.json()["impute_a_l_agent"] == 1000   # pas de surplus pour cet agent : le manquant de 1 000 est imputé
    lignes = client.get(f"/api/controle-carnet/cycles/{cid}/controles", headers=h("chef1")).json()[0]["lignes"]
    assert [l["impute_agent"] for l in lignes if l["ecart"] > 0] == [1000]
    assert client.post(f"/api/controle-carnet/controles/{controle_id}/regler-manquants", headers=h("chef1")).json()["impute_a_l_agent"] == 0
