import datetime as dt

import pytest

# Module sous test : routers/pieces.py (pièces justificatives) et leur génération par les routes d'opération


@pytest.fixture(scope="module")
def base(client, h, sql, agences, produits):
    c = client.post("/api/clients", json={"nom": "Pieces Test"}, headers=h("chef1")).json()
    cpt = client.post("/api/comptes-epargne", json={"client_id": c["id"], "produit_id": produits["CL"], "nb_parts": 2}, headers=h("caissier1")).json()
    return {"client": c, "compte": cpt, "produits": produits, "a1": agences["a1"]}


def _piece(client, h, pid, login="caissier1"):
    r = client.get(f"/api/pieces/{pid}", headers=h(login))
    assert r.status_code == 200, r.text
    return r.json()


def test_ouverture_de_compte_adhesion_et_parts_sur_une_piece(client, h, base):
    pid = base["compte"]["piece_id"]
    p = _piece(client, h, pid)
    assert p["type"] == "adhesion" and p["numero"].startswith("PJ-T1-") and p["client"] == "Pieces Test" and p["compte"] == base["compte"]["numero"]
    assert len(p["lignes"]) == 2 and p["montant"] == 12000 and p["titre"] == "Reçu d'adhésion"          # droit d'adhésion + 2 parts
    # parts supplémentaires : leur propre pièce
    r = client.post("/api/adhesions/parts", json={"compte_id": base["compte"]["id"], "nb_parts": 1}, headers=h("caissier1"))
    assert r.status_code == 201 and r.json()["piece_id"] not in (None, pid)
    p2 = _piece(client, h, r.json()["piece_id"])
    assert p2["type"] == "souscription_parts" and p2["montant"] == 5000 and len(p2["lignes"]) == 1
    # autre agence : introuvable
    assert client.get(f"/api/pieces/{pid}", headers=h("caissier2")).status_code == 404


def test_depot_et_retrait_d_epargne_ont_leur_piece(client, h, base):
    cid = base["compte"]["id"]
    d = client.post(f"/api/comptes-epargne/{cid}/depot", json={"montant": 90000, "libelle": "salaire"}, headers=h("caissier1")).json()
    p = _piece(client, h, d["piece_id"])
    assert p["type"] == "depot_epargne" and p["montant"] == 90000 and "salaire" in p["lignes"][0]["libelle"] and p["utilisateur"] == "caissier1"
    r = client.post(f"/api/comptes-epargne/{cid}/retrait", json={"montant": 10000}, headers=h("caissier1")).json()
    assert _piece(client, h, r["piece_id"])["type"] == "retrait_epargne"
    # la pièce d'une opération est unique : la redemander renvoie la même
    again = client.post("/api/pieces/operation", json={"source": "mouvement_epargne", "id": d["mouvement"]["id"]}, headers=h("caissier1"))
    assert again.status_code == 201 and again.json()["id"] == d["piece_id"]
    assert client.post("/api/pieces/operation", json={"source": "mouvement_epargne", "id": d["mouvement"]["id"]}, headers=h("caissier2")).status_code == 422   # autre agence
    assert client.post("/api/pieces/operation", json={"source": "mouvement_epargne", "id": d["mouvement"]["id"]}, headers=h("agent1")).status_code == 403
    assert client.post("/api/pieces/operation", json={"source": "ligne_collecte", "id": 1}, headers=h("caissier1")).status_code == 422                       # pas de pièce pour la collecte


def test_garantie_et_depot_a_terme(client, h, base):
    cid = base["compte"]["id"]
    g = client.post("/api/depots/garanties", json={"compte_id": cid, "montant": 20000, "motif": "garantie"}, headers=h("caissier1")).json()
    assert _piece(client, h, g["piece_id"])["type"] == "depot_garantie"
    lib = client.post(f"/api/depots/garanties/{g['id']}/liberer", json={}, headers=h("chef1")).json()
    pl = _piece(client, h, lib["piece_id"])
    assert pl["type"] == "liberation_garantie" and pl["montant"] == 20000 and lib["piece_id"] != g["piece_id"]
    ancien = (dt.date.today() - dt.timedelta(days=200)).isoformat()
    t = client.post("/api/depots/terme", json={"compte_id": cid, "montant": 60000, "duree_mois": 6, "date": ancien}, headers=h("caissier1")).json()
    assert _piece(client, h, t["piece_id"])["type"] == "depot_terme"
    v = client.post(f"/api/depots/terme/{t['id']}/debloquer", json={}, headers=h("chef1")).json()
    pv = _piece(client, h, v["piece_id"])
    assert pv["type"] == "deblocage_terme" and [l["montant"] for l in pv["lignes"]] == [60000, 1200] and pv["montant"] == 61200          # capital + intérêts


def test_retraits_de_plusieurs_cycles_sur_une_seule_piece(client, h, sql, base):
    cl, p1 = base["client"], base["produits"]["P1"]
    cycles = [client.post("/api/cycles", json={"client_id": cl["id"], "produit_id": p1, "mise": 500, "date_debut": "2026-01-01", "date_fin": "2026-01-31"}, headers=h("chef1")).json() for _ in range(3)]
    sql("UPDATE cycle SET statut = 'retire' WHERE id = ANY(%s)", ([c["id"] for c in cycles],))
    ids = [sql("INSERT INTO retrait(agence_id, cycle_id, nature, montant, decaissement, statut, date_demande, date_operation, montant_paye) "
               "VALUES (%s, %s, 'retrait_client', %s, true, 'execute', '2026-02-02', '2026-02-02', %s) RETURNING id", (base["a1"], c["id"], m, m))[0]["id"]
           for c, m in zip(cycles, (14500, 9000, 3000))]
    url = "/api/pieces/retraits-tontine"
    assert client.post(url, json={"retrait_ids": ids}, headers=h("agent1")).status_code == 403
    assert client.post(url, json={"retrait_ids": ids}, headers=h("caissier2")).status_code == 404                           # autre agence
    assert client.post(url, json={"retrait_ids": []}, headers=h("caissier1")).status_code == 422
    r = client.post(url, json={"retrait_ids": ids}, headers=h("caissier1"))
    assert r.status_code == 201, r.text
    p = r.json()
    assert p["type"] == "retrait_tontine" and len(p["lignes"]) == 3 and p["montant"] == 26500 and p["client"] == "Pieces Test"
    assert [l["montant"] for l in p["lignes"]] == [14500, 9000, 3000] and all("cycle" in l["libelle"] for l in p["lignes"])
    # un retrait ne figure que sur une pièce
    assert client.post(url, json={"retrait_ids": [ids[0]]}, headers=h("caissier1")).status_code == 422
    # retrait non exécuté ou d'un autre client : refusé
    autre = client.post("/api/clients", json={"nom": "Autre Client"}, headers=h("chef1")).json()
    cy = client.post("/api/cycles", json={"client_id": autre["id"], "produit_id": p1, "mise": 500, "date_debut": "2026-01-01", "date_fin": "2026-01-31"}, headers=h("chef1")).json()
    sql("UPDATE cycle SET statut = 'retire' WHERE id = %s", (cy["id"],))
    rid = sql("INSERT INTO retrait(agence_id, cycle_id, nature, montant, decaissement, statut, date_demande) VALUES (%s, %s, 'retrait_client', 100, true, 'demande', '2026-02-02') RETURNING id", (base["a1"], cy["id"]))[0]["id"]
    assert client.post(url, json={"retrait_ids": [rid]}, headers=h("caissier1")).status_code == 422
    # consultation : liste filtrée, aucune pièce de collecte
    liste = client.get("/api/pieces", params={"client_id": cl["id"]}, headers=h("caissier1")).json()
    assert p["id"] in [x["id"] for x in liste] and all(x["type"] != "collecte" for x in liste)
    assert client.get("/api/pieces", params={"type": "retrait_tontine"}, headers=h("caissier1")).json()[0]["nb_lignes"] == 3
    assert client.get("/api/pieces", headers=h("auditeur")).status_code == 400                                                # le siège désigne l'agence
