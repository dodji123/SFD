import datetime as dt

import pytest

# Module sous test : routers/depots.py (dépôt de garantie, dépôt à terme, déblocages) et le contrôle d'adhésion du guichet


@pytest.fixture(scope="module")
def base(client, h, sql, agences, produits):
    c = client.post("/api/clients", json={"nom": "Deposant Test"}, headers=h("chef1")).json()
    cpt = client.post("/api/comptes-epargne", json={"client_id": c["id"], "produit_id": produits["CL"]}, headers=h("caissier1")).json()
    assert client.post(f"/api/comptes-epargne/{cpt['id']}/depot", json={"montant": 800000}, headers=h("caissier1")).status_code == 201
    return {"client": c, "compte": cpt, "a1": agences["a1"]}


def _compte(client, h, base):
    return client.get(f"/api/comptes-epargne/{base['compte']['id']}", headers=h("caissier1")).json()


def test_depot_de_garantie_bloque_puis_debloque(client, h, sql, base):
    cid = base["compte"]["id"]
    dispo0 = _compte(client, h, base)["disponible"]
    assert client.post("/api/depots/garanties", json={"compte_id": cid, "montant": 100000}, headers=h("agent1")).status_code == 403
    assert client.post("/api/depots/garanties", json={"compte_id": cid, "montant": 100000}, headers=h("caissier2")).status_code == 404       # autre agence
    assert client.post("/api/depots/garanties", json={"compte_id": cid, "montant": 5000, "date": "2999-01-01"}, headers=h("caissier1")).status_code == 422
    r = client.post("/api/depots/garanties", json={"compte_id": cid, "montant": 100000, "motif": "garantie crédit à venir"}, headers=h("caissier1"))
    assert r.status_code == 201, r.text
    g = r.json()
    assert g["numero"].startswith("DG-T1-") and g["statut"] == "bloque" and g["client"] == "Deposant Test"
    c = _compte(client, h, base)
    assert c["solde"] == 900000 and c["disponible"] == dispo0                      # le solde monte, le disponible ne bouge pas : la somme est bloquée
    assert client.post(f"/api/comptes-epargne/{cid}/retrait", json={"montant": dispo0 + 1}, headers=h("caissier1")).status_code == 422
    # déblocage : réservé au chef / admin
    assert client.post(f"/api/depots/garanties/{g['id']}/liberer", json={}, headers=h("caissier1")).status_code == 403
    assert client.post(f"/api/depots/garanties/{g['id']}/liberer", json={}, headers=h("chef2")).status_code == 404
    lib = client.post(f"/api/depots/garanties/{g['id']}/liberer", json={}, headers=h("chef1"))
    assert lib.status_code == 200 and lib.json()["statut"] == "libere"
    assert _compte(client, h, base)["disponible"] == dispo0 + 100000
    assert client.post(f"/api/depots/garanties/{g['id']}/liberer", json={}, headers=h("chef1")).status_code == 422                     # déjà libéré
    # rattachée à un crédit non soldé : déblocage refusé tant que le crédit n'est pas soldé
    crid = sql("INSERT INTO credit(agence_id, numero, client_id, type, montant_accorde, taux, date_deblocage, nb_echeances, mode_remboursement) "
               "VALUES (%s, 'DEP-CR-1', %s, 'sans_epargne', 50000, 0.12, '2026-09-01', 6, 'especes') RETURNING id", (base["a1"], base["client"]["id"]))[0]["id"]
    g2 = client.post("/api/depots/garanties", json={"compte_id": cid, "montant": 20000, "credit_id": crid}, headers=h("caissier1")).json()
    assert g2["credit"] == "DEP-CR-1"
    r = client.post(f"/api/depots/garanties/{g2['id']}/liberer", json={}, headers=h("chef1"))
    assert r.status_code == 422 and "crédit" in r.json()["detail"]
    sql("UPDATE credit SET statut = 'solde', date_solde = current_date WHERE id = %s", (crid,))
    assert client.post(f"/api/depots/garanties/{g2['id']}/liberer", json={}, headers=h("chef1")).status_code == 200
    bloques = client.get("/api/depots/garanties", params={"statut": "bloque"}, headers=h("caissier1")).json()
    assert all(x["statut"] == "bloque" for x in bloques) and g["id"] not in [x["id"] for x in bloques]
    assert client.get("/api/depots/garanties", headers=h("auditeur")).status_code == 400                                              # le siège désigne l'agence


def test_depot_a_terme_echeance_et_rupture(client, h, base):
    cid = base["compte"]["id"]
    p = client.get("/api/depots/parametres", headers=h("caissier1")).json()
    assert p["taux_annuel"] == 0.04 and p["duree_min_mois"] == 3 and p["montant_min"] == 50000 and p["penalite_rupture_pct"] == 100
    place = lambda corps, login="caissier1": client.post("/api/depots/terme", json={"compte_id": cid, **corps}, headers=h(login))
    assert place({"montant": 100000, "duree_mois": 6}, "agent1").status_code == 403
    assert place({"montant": 10000, "duree_mois": 6}).status_code == 422                        # sous le montant minimal
    assert place({"montant": 100000, "duree_mois": 1}).status_code == 422                       # sous la durée minimale
    assert place({"montant": 99999999, "duree_mois": 6}).status_code == 422                     # fonds insuffisants
    avant = _compte(client, h, base)["solde"]
    ancien = (dt.date.today() - dt.timedelta(days=200)).isoformat()
    r = place({"montant": 120000, "duree_mois": 6, "date": ancien})
    assert r.status_code == 201, r.text
    d = r.json()
    assert d["numero"].startswith("DT-T1-") and d["interets_prevus"] == 2400 and float(d["taux_annuel"]) == 0.04 and d["echu"] is True
    assert _compte(client, h, base)["solde"] == avant - 120000
    # échu : la rupture anticipée est refusée, le déblocage est réservé au chef
    assert client.post(f"/api/depots/terme/{d['id']}/rompre", json={}, headers=h("chef1")).status_code == 422
    assert client.post(f"/api/depots/terme/{d['id']}/debloquer", json={}, headers=h("caissier1")).status_code == 403
    assert client.post(f"/api/depots/terme/{d['id']}/debloquer", json={}, headers=h("chef2")).status_code == 404
    v = client.post(f"/api/depots/terme/{d['id']}/debloquer", json={}, headers=h("chef1"))
    assert v.status_code == 200 and v.json()["statut"] == "verse" and v.json()["interets_verses"] == 2400
    assert _compte(client, h, base)["solde"] == avant + 2400
    assert client.post(f"/api/depots/terme/{d['id']}/debloquer", json={}, headers=h("chef1")).status_code == 422                     # déjà soldé
    # taux saisi, dépôt en cours : déblocage avant l'échéance refusé, rupture anticipée sans intérêts (pénalité 100 %)
    r2 = place({"montant": 100000, "duree_mois": 12, "taux_annuel": 0.06, "date": (dt.date.today() - dt.timedelta(days=30)).isoformat()})
    d2 = r2.json()
    assert r2.status_code == 201 and d2["interets_prevus"] == 6000 and d2["echu"] is False
    assert client.post(f"/api/depots/terme/{d2['id']}/debloquer", json={}, headers=h("chef1")).status_code == 422
    rp = client.post(f"/api/depots/terme/{d2['id']}/rompre", json={}, headers=h("chef1"))
    assert rp.status_code == 200 and rp.json()["statut"] == "rompu" and rp.json()["interets_verses"] == 0
    assert _compte(client, h, base)["solde"] == avant + 2400                                                                         # capital rendu


def test_page_des_deblocages(client, h, base):
    cid = base["compte"]["id"]
    g = client.post("/api/depots/garanties", json={"compte_id": cid, "montant": 15000, "motif": "à débloquer"}, headers=h("caissier1")).json()
    t = client.post("/api/depots/terme", json={"compte_id": cid, "montant": 60000, "duree_mois": 12}, headers=h("caissier1")).json()
    d = client.get("/api/depots/deblocages", headers=h("chef1")).json()
    assert g["id"] in [x["id"] for x in d["garanties"]] and t["id"] in [x["id"] for x in d["termes"]] and isinstance(d["credits"], list)
    assert all(x["statut"] == "en_cours" for x in d["termes"]) and all(x["statut"] == "bloque" for x in d["garanties"])
    mine = client.get("/api/depots/deblocages", headers=h("chef2")).json()
    assert g["id"] not in [x["id"] for x in mine["garanties"]] and t["id"] not in [x["id"] for x in mine["termes"]]                 # cloisonnement par agence
    assert client.get("/api/depots/deblocages", headers=h("auditeur")).status_code == 400                                            # le siège désigne l'agence
