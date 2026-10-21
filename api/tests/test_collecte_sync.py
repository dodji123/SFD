import datetime as dt

import pytest

from tests.helpers import make_user

# Module sous test : tournée, synchronisation et file de validation de l'application mobile
# (routers/collecte_sync.py, schema/45_sync_mobile.sql, schema/46_validation_mobile.sql)

AUJ = dt.date.today()


def iso(delta: int = 0) -> str:
    return str(AUJ + dt.timedelta(days=delta))


@pytest.fixture(scope="module")
def base(client, h, sql, agences, produits):
    a1, a2 = agences["a1"], agences["a2"]
    ag1 = client.post("/api/agents", json={"matricule": "SY-A1", "nom": "Agent Sync"}, headers=h("chef1")).json()
    ag2 = client.post("/api/agents", json={"matricule": "SY-A2", "nom": "Autre Agent"}, headers=h("chef1")).json()
    ag3 = client.post("/api/agents", json={"matricule": "SY-A3", "nom": "Agent Collectrice"}, headers=h("chef1")).json()
    ag4 = client.post("/api/agents", json={"matricule": "SY-A4", "nom": "Agent sans zone"}, headers=h("chef1")).json()
    z1 = sql("INSERT INTO zone(agence_id, code, libelle, agent_id) VALUES (%s, 'SYZ1', 'Zone sync 1', %s) RETURNING id", (a1, ag1["id"]))[0]["id"]
    z2 = sql("INSERT INTO zone(agence_id, code, libelle, agent_id) VALUES (%s, 'SYZ2', 'Zone sync 2', %s) RETURNING id", (a1, ag2["id"]))[0]["id"]
    z3 = sql("INSERT INTO zone(agence_id, code, libelle) VALUES (%s, 'SYZ3', 'Zone de la collectrice') RETURNING id", (a1,))[0]["id"]
    k = sql("INSERT INTO collectrice(agence_id, matricule, nom, agent_id) VALUES (%s, 'SYK1', 'Collectrice Sync', %s) RETURNING id", (a1, ag3["id"]))[0]["id"]
    sql("INSERT INTO affectation_zone(zone_id, collectrice_id, date_debut) VALUES (%s, %s, %s)", (z3, k, iso(-30)))
    make_user(sql, "agent_sync", "agent", a1, agent_id=ag1["id"])
    make_user(sql, "agent_sync_bis", "agent", a1, agent_id=ag2["id"])
    make_user(sql, "coll_sync", "collectrice", a1, collectrice_id=k)
    make_user(sql, "agent_sans_zone", "agent", a1, agent_id=ag4["id"])
    cl = lambda nom, z: client.post("/api/clients", json={"nom": nom, "zone_id": z}, headers=h("chef1")).json()
    p = client.post("/api/produits-epargne", json={"code": "TMOBIL", "libelle": "Tontine mobile", "categorie": "collecte"}, headers=h("chef1"))
    assert p.status_code == 201, p.text
    return {"ag1": ag1, "ag2": ag2, "z1": z1, "z2": z2, "z3": z3, "p1": produits["P1"], "libre": p.json()["id"],
            "dans": [cl(f"Cli Zone1 {i}", z1) for i in range(8)], "autre": cl("Cli Zone2", z2), "coll": cl("Cli Zone3", z3),
            "n": iter(range(100)), "a2": a2}


def _cycle(client, h, base, debut=-10, fin=20, mise=1000, zone="dans"):
    c = base[zone][next(base["n"])] if zone == "dans" else base[zone]
    r = client.post("/api/cycles", json={"client_id": c["id"], "produit_id": base["p1"], "mise": mise,
                                         "date_debut": iso(debut), "date_fin": iso(fin)}, headers=h("chef1"))
    assert r.status_code == 201, r.text
    return r.json()


def _hdr(client, login):
    r = client.post("/api/auth/login", json={"login": login, "mot_de_passe": "MotDePasse-Test-1"})
    return {"Authorization": "Bearer " + r.json()["access_token"]}


def _col(cle, cycle, montant=1000, date=None):
    return {"cle": cle, "type": "collecte", "payload": {"cycle": cycle, "date_collecte": date or iso(-1), "montant_collecte": montant}}


def _sync(client, hdr, *ops):
    r = client.post("/api/collecte/sync", json={"operations": list(ops)}, headers=hdr)
    assert r.status_code == 200, r.text
    return r.json()["resultats"]


def _valider(client, hdr, *cles):
    r = client.post("/api/collecte/validations/valider", json={"cles": list(cles)}, headers=hdr)
    assert r.status_code == 200, r.text
    return {x["cle"]: x for x in r.json()["resultats"]}


def _cycle_detail(client, h, cid):
    return client.get(f"/api/cycles/{cid}", headers=h("chef1")).json()


# ------------------------------------------------------------------ tournée : l'agent ne voit que sa zone
def test_tournee_limitee_a_la_zone(client, h, base):
    c_ok = _cycle(client, h, base)
    c_autre = _cycle(client, h, base, zone="autre")
    t = client.get("/api/collecte/mobile/tournee", headers=_hdr(client, "agent_sync")).json()
    assert [z["id"] for z in t["zones"]] == [base["z1"]]
    assert {c["zone_id"] for c in t["clients"]} == {base["z1"]} and len(t["clients"]) == 8
    assert c_ok["id"] in {c["id"] for c in t["cycles"]} and c_autre["id"] not in {c["id"] for c in t["cycles"]}
    assert any(p["code"] == "TMOBIL" and p["type_cycle"] is None for p in t["produits"])
    # un autre agent : sa propre zone ; une collectrice : la zone qui lui est affectée ; sans zone : rien
    assert [c["nom"] for c in client.get("/api/collecte/mobile/tournee", headers=_hdr(client, "agent_sync_bis")).json()["clients"]] == ["Cli Zone2"]
    assert [c["nom"] for c in client.get("/api/collecte/mobile/tournee", headers=_hdr(client, "coll_sync")).json()["clients"]] == ["Cli Zone3"]
    vide = client.get("/api/collecte/mobile/tournee", headers=_hdr(client, "agent_sans_zone")).json()
    assert vide["zones"] == [] and vide["clients"] == [] and vide["cycles"] == []
    assert client.get("/api/collecte/mobile/tournee", headers=h("chef1")).status_code == 403


# ------------------------------------------------------------------ synchronisation = mise en attente
def test_sync_met_en_attente_sans_rien_ecrire(client, h, base):
    c = _cycle(client, h, base)
    hdr = _hdr(client, "agent_sync")
    lot = [_col("cle-sync-a0001", c["id"]), _col("cle-sync-a0002", c["id"], 2000, iso(-2))]
    r1 = _sync(client, hdr, *lot)
    assert [(x["statut"], x["etat"]) for x in r1] == [("recue", "en_attente")] * 2
    assert _cycle_detail(client, h, c["id"])["nb_lignes"] == 0                       # rien dans les données vives
    r2 = _sync(client, hdr, *lot)                                                    # accusé perdu : même lot renvoyé
    assert [(x["statut"], x["etat"]) for x in r2] == [("doublon", "en_attente")] * 2
    n = client.get("/api/collecte/validations", headers=h("chef1")).json()
    assert {o["cle"] for o in n} >= {"cle-sync-a0001", "cle-sync-a0002"} and all(o["resume"] for o in n)


def test_refus_a_la_reception(client, h, base):
    hdr = _hdr(client, "agent_sync")
    mien = _cycle(client, h, base)
    autre_zone = _cycle(client, h, base, zone="autre")
    # cycle d'une autre agence
    c2 = client.post("/api/clients", json={"nom": "Cli autre agence"}, headers=h("chef2")).json()
    cy2 = client.post("/api/cycles", json={"client_id": c2["id"], "produit_id": base["p1"], "mise": 1000, "date_debut": iso(-5), "date_fin": iso(20)}, headers=h("chef2")).json()
    r = _sync(client, hdr,
              _col("cle-sync-b0001", autre_zone["id"]),                              # hors zone
              _col("cle-sync-b0002", cy2["id"]),                                     # autre agence
              _col("cle-sync-b0003", 99999999),                                      # inexistant
              _col("cle-sync-b0004", mien["id"], 0),
              _col("cle-sync-b0005", mien["id"], 1000, iso(1)),                      # date future
              {"cle": "cle-sync-b0006", "type": "collecte", "payload": {"cycle": mien["id"]}},        # mal formée
              {"cle": "cle-sync-b0007", "type": "client", "payload": {"nom": "X", "zone_id": base["z2"]}})   # zone d'un autre agent
    assert [(x["statut"], x["code"]) for x in r] == [("refusee", c) for c in
           ("hors_zone", "droit_agence", "droit_agence", "montant_invalide", "date_future", "format", "hors_zone")]
    # une clé déjà prise par un autre agent
    assert _sync(client, hdr, _col("cle-sync-b0008", mien["id"]))[0]["statut"] == "recue"
    r = _sync(client, _hdr(client, "agent_sync_bis"), _col("cle-sync-b0008", mien["id"]))
    assert (r[0]["statut"], r[0]["code"]) == ("refusee", "cle_conflit")
    # sans zone
    r = _sync(client, _hdr(client, "agent_sans_zone"), _col("cle-sync-b0009", mien["id"]))
    assert (r[0]["statut"], r[0]["code"]) == ("refusee", "hors_zone")
    # chef, caissier, sans jeton
    corps = {"operations": [_col("cle-sync-b0010", mien["id"])]}
    assert client.post("/api/collecte/sync", json=corps, headers=h("chef1")).status_code == 403
    assert client.post("/api/collecte/sync", json=corps).status_code == 401
    assert client.post("/api/collecte/sync", json={"operations": []}, headers=_hdr(client, "agent_sync")).status_code == 422


# ------------------------------------------------------------------ validation
def test_validation_d_une_collecte_et_droits(client, h, base):
    c = _cycle(client, h, base)
    hdr = _hdr(client, "agent_sync")
    _sync(client, hdr, _col("cle-sync-c0001", c["id"], 2000), _col("cle-sync-c0002", c["id"]))
    corps = {"cles": ["cle-sync-c0001"]}
    assert client.post("/api/collecte/validations/valider", json=corps, headers=hdr).status_code == 403   # l'agent ne valide pas
    assert client.get("/api/collecte/validations", headers=hdr).status_code == 403
    r = _valider(client, h("caissier1"), "cle-sync-c0001")                           # le caissier de l'agence valide
    assert r["cle-sync-c0001"]["statut"] == "validee"
    d = _cycle_detail(client, h, c["id"])
    assert (d["nb_lignes"], d["montant_collecte"]) == (1, 2000) and d["lignes"][0]["agent_id"] == base["ag1"]["id"]
    assert _valider(client, h("caissier1"), "cle-sync-c0001")["cle-sync-c0001"]["statut"] == "ignoree"    # pas de seconde ligne
    assert _cycle_detail(client, h, c["id"])["nb_lignes"] == 1
    assert _sync(client, hdr, _col("cle-sync-c0001", c["id"], 2000))[0]["etat"] == "validee"              # l'agent voit l'état
    t = client.get("/api/collecte/mobile/tournee", headers=hdr).json()["operations"]
    assert {o["cle"]: o["statut"] for o in t}["cle-sync-c0001"] == "validee"
    assert client.post("/api/collecte/validations/valider", json={"cles": ["cle-sync-c0002"]}, headers=h("chef2")).json()["resultats"][0]["statut"] == "ignoree"  # autre agence


def test_rejet_avec_motif_et_dependance(client, h, base):
    hdr = _hdr(client, "agent_sync")
    ops = [{"cle": "cle-sync-d0001", "type": "client", "payload": {"nom": "Client à rejeter"}},
           {"cle": "cle-sync-d0002", "type": "cycle", "payload": {"client": "cle-sync-d0001", "produit_id": base["libre"], "mise": 500, "type_cycle": 2,
                                                                  "date_debut": iso(-1), "date_fin": iso(30)}}]
    assert [x["statut"] for x in _sync(client, hdr, *ops)] == ["recue", "recue"]
    assert client.post("/api/collecte/validations/rejeter", json={"cles": ["cle-sync-d0001"], "motif": "non"}, headers=h("chef1")).status_code == 422
    assert client.post("/api/collecte/validations/rejeter", json={"cles": ["cle-sync-d0001"], "motif": "Client déjà existant"}, headers=h("chef1")).json() == {"rejetees": 1}
    r = _valider(client, h("chef1"), "cle-sync-d0002")                               # sa dépendance a été rejetée
    assert (r["cle-sync-d0002"]["statut"], r["cle-sync-d0002"]["code"]) == ("rejetee", "dependance")
    t = {o["cle"]: o for o in client.get("/api/collecte/mobile/tournee", headers=hdr).json()["operations"]}
    assert (t["cle-sync-d0001"]["statut"], t["cle-sync-d0001"]["motif"]) == ("rejetee", "Client déjà existant")
    assert t["cle-sync-d0002"]["statut"] == "rejetee"
    assert client.get("/api/clients", params={"q": "Client à rejeter"}, headers=h("chef1")).json() == []


def test_chaine_hors_ligne_client_cycle_collecte_cloture(client, h, base):
    """Un client créé hors ligne reçoit un identifiant local (la clé de son opération) remplacé par l'identifiant réel à la validation."""
    hdr = _hdr(client, "agent_sync")
    desordre = [
        {"cle": "cle-sync-e0004", "type": "cloture", "payload": {"cycle": "cle-sync-e0002"}},
        _col("cle-sync-e0003", "cle-sync-e0002", 3000),
        {"cle": "cle-sync-e0002", "type": "cycle", "payload": {"client": "cle-sync-e0001", "produit_id": base["libre"], "mise": 1000, "type_cycle": 3,
                                                               "date_debut": iso(-2), "date_fin": iso(28)}},
        {"cle": "cle-sync-e0001", "type": "client", "payload": {"nom": "Nouvelle cliente terrain", "telephone": "90000000"}},
    ]
    assert [x["statut"] for x in _sync(client, hdr, *desordre)] == ["recue"] * 4
    # validation partielle : la collecte sans son cycle validé est différée, rien n'est écrit pour elle
    r = _valider(client, h("chef1"), "cle-sync-e0003")
    assert (r["cle-sync-e0003"]["statut"], r["cle-sync-e0003"]["code"]) == ("differee", "dependance_attente")
    r = _valider(client, h("chef1"), "cle-sync-e0004", "cle-sync-e0003", "cle-sync-e0002", "cle-sync-e0001")    # rejoué dans le bon ordre
    assert {k: v["statut"] for k, v in r.items()} == {f"cle-sync-e000{i}": "validee" for i in range(1, 5)}
    cl = client.get("/api/clients", params={"q": "Nouvelle cliente terrain"}, headers=h("chef1")).json()
    assert len(cl) == 1 and cl[0]["zone_id"] == base["z1"] and cl[0]["telephone"] == "90000000"   # zone de l'agent (seule zone)
    cyc = client.get("/api/cycles", params={"client_id": cl[0]["id"]}, headers=h("chef1")).json()
    assert len(cyc) == 1 and cyc[0]["type_cycle"] == 3 and cyc[0]["statut"] == "clos"
    assert _cycle_detail(client, h, cyc[0]["id"])["montant_collecte"] == 3000


def test_type_de_cycle_libre_a_chaque_cycle(client, h, base):
    """Même client, même produit : un cycle de type 1 puis un de type 2 (aucun verrou à la première mise)."""
    hdr = _hdr(client, "agent_sync")
    cl = base["dans"][7]
    mk = lambda cle, t: {"cle": cle, "type": "cycle", "payload": {"client": cl["id"], "produit_id": base["libre"], "mise": 500, "type_cycle": t,
                                                                  "date_debut": iso(-1), "date_fin": iso(30)}}
    _sync(client, hdr, mk("cle-sync-f0001", 1), mk("cle-sync-f0002", 2), {"cle": "cle-sync-f0003", "type": "cycle", "payload": {
        "client": cl["id"], "produit_id": base["libre"], "mise": 500, "date_debut": iso(-1), "date_fin": iso(30)}})        # sans type : refusé à la validation
    r = _valider(client, h("chef1"), "cle-sync-f0001", "cle-sync-f0002", "cle-sync-f0003")
    assert [r[k]["statut"] for k in ("cle-sync-f0001", "cle-sync-f0002", "cle-sync-f0003")] == ["validee", "validee", "rejetee"]
    types = sorted(c["type_cycle"] for c in client.get("/api/cycles", params={"client_id": cl["id"]}, headers=h("chef1")).json())
    assert types == [1, 2]


def test_rejet_a_la_validation_selon_le_schema(client, h, base):
    """Cycle clos ou terminé depuis l'envoi : le schéma refuse, l'opération est rejetée avec son message."""
    hdr = _hdr(client, "agent_sync")
    clos = _cycle(client, h, base)
    fini = _cycle(client, h, base, debut=-40, fin=-20)
    reste = _cycle(client, h, base, mise=1000)
    _sync(client, hdr, _col("cle-sync-g0001", clos["id"]), _col("cle-sync-g0002", fini["id"], date=iso(-1)),
          _col("cle-sync-g0003", fini["id"], date=iso(-25)), _col("cle-sync-g0004", reste["id"], 1500), _col("cle-sync-g0005", reste["id"], 32000))
    assert client.post(f"/api/cycles/{clos['id']}/cloturer", json={}, headers=h("chef1")).status_code == 200
    r = _valider(client, h("chef1"), *[f"cle-sync-g000{i}" for i in range(1, 6)])
    assert [(r[f"cle-sync-g000{i}"]["statut"], r[f"cle-sync-g000{i}"]["code"]) for i in range(1, 6)] == [
        ("rejetee", "cycle_clos"), ("rejetee", "hors_delai"), ("validee", None), ("rejetee", "montant_invalide"), ("rejetee", "depasse_reste")]
    assert "prolongation" in r["cle-sync-g0002"]["motif"]
    t = {o["cle"]: o for o in client.get("/api/collecte/mobile/tournee", headers=hdr).json()["operations"]}
    assert t["cle-sync-g0001"]["statut"] == "rejetee" and "clos" in t["cle-sync-g0001"]["motif"]


def test_validation_listee_par_agent_et_jour(client, h, base):
    c = _cycle(client, h, base)
    _sync(client, _hdr(client, "agent_sync"), _col("cle-sync-h0001", c["id"]))
    _sync(client, _hdr(client, "agent_sync_bis"), {"cle": "cle-sync-h0002", "type": "client", "payload": {"nom": "Client du bis"}})
    ops = client.get("/api/collecte/validations", params={"date": iso(0), "statut": "en_attente"}, headers=h("chef1")).json()
    par_agent = {o["agent"] for o in ops}
    assert {"Agent Sync", "Autre Agent"} <= par_agent
    seul = client.get("/api/collecte/validations", params={"agent_id": base["ag2"]["id"]}, headers=h("chef1")).json()
    assert {o["agent_id"] for o in seul} == {base["ag2"]["id"]} and any("Client du bis" in o["resume"] for o in seul)
    assert client.get("/api/collecte/validations", headers=h("chef2")).json() == [] or all(o["agent_id"] not in (base["ag1"]["id"],) for o in client.get("/api/collecte/validations", headers=h("chef2")).json())
