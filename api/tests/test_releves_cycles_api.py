import datetime as dt

import pytest

# Module sous test : tri / filtre par produit des cycles, clôture manuelle par sélection (collecte.py), relevé de compte (releves.py)


@pytest.fixture(scope="module")
def base(client, h, produits):
    ag = client.post("/api/agents", json={"matricule": "REL-A1", "nom": "Agent Relevé"}, headers=h("chef1")).json()
    c = client.post("/api/clients", json={"nom": "Cliente Relevé"}, headers=h("chef1")).json()
    cycles = {}
    for cle, produit, mise in (("p1", "P1", 1000), ("p2", "P2", 2000)):
        r = client.post("/api/cycles", json={"client_id": c["id"], "produit_id": produits[produit], "mise": mise,
                                             "date_debut": "2026-10-01", "date_fin": "2026-10-31"}, headers=h("chef1"))
        assert r.status_code == 201, r.text
        cycles[cle] = r.json()
        lignes = [{"date_collecte": str(dt.date(2026, 10, 1) + dt.timedelta(days=i)), "montant_collecte": mise, "agent_id": ag["id"]} for i in range(3)]
        assert client.post(f"/api/cycles/{cycles[cle]['id']}/lignes", json={"lignes": lignes}, headers=h("chef1")).status_code == 201
    return {"client": c, "cycles": cycles, "produits": produits, "agent": ag}


def test_tri_et_filtre_par_produit(client, h, base):
    liste = client.get("/api/cycles", params={"client_id": base["client"]["id"], "tri": "produit"}, headers=h("chef1")).json()
    assert [c["produit"] for c in liste] == sorted(c["produit"] for c in liste) and {c["produit"] for c in liste} == {"P1", "P2"}
    seul = client.get("/api/cycles", params={"client_id": base["client"]["id"], "produit_id": base["produits"]["P2"]}, headers=h("chef1")).json()
    assert len(seul) == 1 and seul[0]["produit"] == "P2"
    assert client.get("/api/cycles", params={"tri": "nimporte"}, headers=h("chef1")).status_code == 422


def test_cloture_manuelle_par_selection(client, h, base):
    ids = [base["cycles"]["p1"]["id"], base["cycles"]["p2"]["id"], 999999]
    assert client.post("/api/cycles/cloturer-selection", json={"cycle_ids": ids}, headers=h("caissier1")).status_code == 403      # collecte:admin seulement
    assert client.post("/api/cycles/cloturer-selection", json={"cycle_ids": ids}, headers=h("chef2")).json()["clotures"] == []      # autre agence
    r = client.post("/api/cycles/cloturer-selection", json={"cycle_ids": ids, "date": "2026-10-04"}, headers=h("chef1")).json()
    assert sorted(r["clotures"]) == sorted(ids[:2]) and [x["cycle_id"] for x in r["refuses"]] == [999999]
    clos = client.get("/api/cycles", params={"client_id": base["client"]["id"], "statut": "clos"}, headers=h("chef1")).json()
    assert len(clos) == 2
    again = client.post("/api/cycles/cloturer-selection", json={"cycle_ids": ids[:1]}, headers=h("chef1")).json()
    assert again["clotures"] == [] and len(again["refuses"]) == 1                                                                   # déjà clos


def test_releve_de_compte(client, h, base, produits):
    cid = base["client"]["id"]
    cpt = client.post("/api/comptes-epargne", json={"client_id": cid, "produit_id": produits["CL"]}, headers=h("chef1")).json()
    client.post(f"/api/comptes-epargne/{cpt['id']}/depot", json={"montant": 50000, "date_operation": "2026-09-01"}, headers=h("chef1"))
    client.post(f"/api/comptes-epargne/{cpt['id']}/depot", json={"montant": 20000, "date_operation": "2026-10-02"}, headers=h("chef1"))
    client.post(f"/api/comptes-epargne/{cpt['id']}/retrait", json={"montant": 5000, "date_operation": "2026-10-03"}, headers=h("chef1"))
    r = client.get(f"/api/clients/{cid}/releve", params={"du": "2026-10-01", "au": "2026-10-31"}, headers=h("chef1"))
    assert r.status_code == 200, r.text
    d = r.json()
    c = next(x for x in d["comptes"] if x["id"] == cpt["id"])
    assert c["solde_ouverture"] == 50000 and c["solde_fin"] == 65000 and c["total_entrees"] == 20000 and c["total_sorties"] == 5000
    assert [m["solde"] for m in c["mouvements"]] == [70000, 65000]                         # solde courant ligne par ligne
    assert len(d["cycles"]) == 2 and all(cy["total_periode"] > 0 for cy in d["cycles"])
    assert d["institution"]["raison_sociale"] and d["agence"]["code"]
    assert client.get(f"/api/clients/{cid}/releve", headers=h("chef2")).status_code == 404                  # autre agence
    assert client.get(f"/api/clients/{cid}/releve", params={"du": "2026-11-01", "au": "2026-10-01"}, headers=h("chef1")).status_code == 422
