import datetime as dt

import pytest

from tests.helpers import make_user

# Module sous test : synchronisation par lot des saisies mobiles (routers/collecte_sync.py, schema/45_sync_mobile.sql)

AUJ = dt.date.today()


def iso(delta: int = 0) -> str:
    return str(AUJ + dt.timedelta(days=delta))


@pytest.fixture(scope="module")
def base(client, h, sql, agences, produits):
    a1 = agences["a1"]
    ag1 = client.post("/api/agents", json={"matricule": "SY-A1", "nom": "Agent Sync"}, headers=h("chef1")).json()
    ag2 = client.post("/api/agents", json={"matricule": "SY-A2", "nom": "Autre Agent"}, headers=h("chef1")).json()
    make_user(sql, "agent_sync", "agent", a1, agent_id=ag1["id"])
    make_user(sql, "agent_sync_bis", "agent", a1, agent_id=ag2["id"])
    clients = [client.post("/api/clients", json={"nom": f"Cli Sync {i}"}, headers=h("chef1")).json() for i in range(12)]
    return {"ag1": ag1, "ag2": ag2, "clients": clients, "p1": produits["P1"], "n": iter(range(100))}


def _cycle(client, h, base, debut=-10, fin=20, mise=1000):
    c = base["clients"][next(base["n"])]
    r = client.post("/api/cycles", json={"client_id": c["id"], "produit_id": base["p1"], "mise": mise,
                                         "date_debut": iso(debut), "date_fin": iso(fin)}, headers=h("chef1"))
    assert r.status_code == 201, r.text
    return r.json()


def _hdr(client, login):
    r = client.post("/api/auth/login", json={"login": login, "mot_de_passe": "MotDePasse-Test-1"})
    return {"Authorization": "Bearer " + r.json()["access_token"]}


def _op(cle, cycle_id, montant=1000, date=None, **kw):
    return {"cle": cle, "cycle_id": cycle_id, "date_collecte": date or iso(-1), "montant_collecte": montant, **kw}


def _sync(client, hdr, *ops):
    r = client.post("/api/collecte/sync", json={"operations": list(ops)}, headers=hdr)
    assert r.status_code == 200, r.text
    return r.json()["resultats"]


def _nb_lignes(client, h, cycle_id):
    return client.get(f"/api/cycles/{cycle_id}", headers=h("chef1")).json()["nb_lignes"]


def test_lot_applique_puis_rejoue_sans_doublon(client, h, base):
    c = _cycle(client, h, base)
    hdr = _hdr(client, "agent_sync")
    lot = [_op("cle-test-a0001", c["id"], 1000), _op("cle-test-a0002", c["id"], 2000, date=iso(-2))]
    r1 = _sync(client, hdr, *lot)
    assert [x["statut"] for x in r1] == ["appliquee", "appliquee"] and all(x["ligne_id"] for x in r1)
    d = client.get(f"/api/cycles/{c['id']}", headers=h("chef1")).json()
    assert (d["nb_lignes"], d["montant_collecte"]) == (2, 3000)
    assert {l["agent_id"] for l in d["lignes"]} == {base["ag1"]["id"]}            # agent déduit du compte
    # le téléphone n'a pas reçu l'accusé : il renvoie le même lot
    r2 = _sync(client, hdr, *lot)
    assert [x["statut"] for x in r2] == ["doublon", "doublon"]
    assert [x["ligne_id"] for x in r2] == [x["ligne_id"] for x in r1]            # même ligne, aucune nouvelle
    assert _nb_lignes(client, h, c["id"]) == 2


def test_meme_cle_deux_fois_dans_le_meme_lot(client, h, base):
    c = _cycle(client, h, base)
    r = _sync(client, _hdr(client, "agent_sync"), _op("cle-test-b0001", c["id"]), _op("cle-test-b0001", c["id"]))
    assert [x["statut"] for x in r] == ["appliquee", "doublon"] and _nb_lignes(client, h, c["id"]) == 1


def test_un_refus_n_annule_pas_les_autres(client, h, base):
    c = _cycle(client, h, base)
    r = _sync(client, _hdr(client, "agent_sync"),
              _op("cle-test-c0001", c["id"], 1000),
              _op("cle-test-c0002", c["id"], 1500),                                 # pas un multiple de la mise
              _op("cle-test-c0003", c["id"], 1000, date=iso(-3)))
    assert [x["statut"] for x in r] == ["appliquee", "refusee", "appliquee"]
    assert r[1]["code"] == "montant_invalide" and "multiple" in r[1]["motif"]
    assert _nb_lignes(client, h, c["id"]) == 2


def test_refus_cycle_clos(client, h, base):
    c = _cycle(client, h, base)
    assert client.post(f"/api/cycles/{c['id']}/cloturer", json={}, headers=h("chef1")).status_code == 200
    r = _sync(client, _hdr(client, "agent_sync"), _op("cle-test-d0001", c["id"]))
    assert r[0]["statut"] == "refusee" and r[0]["code"] == "cycle_clos"
    assert _nb_lignes(client, h, c["id"]) == 0


def test_refus_hors_delai_de_grace(client, h, base):
    c = _cycle(client, h, base, debut=-40, fin=-20)                                # fini depuis 20 jours, grâce 0
    hdr = _hdr(client, "agent_sync")
    r = _sync(client, hdr, _op("cle-test-e0001", c["id"], date=iso(-1)), _op("cle-test-e0002", c["id"], date=iso(-25)))
    assert (r[0]["statut"], r[0]["code"]) == ("refusee", "hors_delai") and "prolongation" in r[0]["motif"]
    assert r[1]["statut"] == "appliquee"                                           # dans la période : acceptée


def test_refus_avant_debut_et_date_future(client, h, base):
    c = _cycle(client, h, base, debut=-5, fin=20)
    r = _sync(client, _hdr(client, "agent_sync"),
              _op("cle-test-f0001", c["id"], date=iso(-9)), _op("cle-test-f0002", c["id"], date=iso(1)))
    assert [(x["statut"], x["code"]) for x in r] == [("refusee", "avant_debut"), ("refusee", "date_future")]


def test_refus_montant_et_reste(client, h, base):
    c = _cycle(client, h, base, mise=1000)                                         # objectif 31 000
    hdr = _hdr(client, "agent_sync")
    r = _sync(client, hdr, _op("cle-test-g0001", c["id"], 0), _op("cle-test-g0002", c["id"], 32000))
    assert [(x["statut"], x["code"]) for x in r] == [("refusee", "montant_invalide"), ("refusee", "depasse_reste")]


def test_refus_droit_agence(client, h, base):
    c = _cycle(client, h, base)
    # chef de l'autre agence : le cycle lui est invisible
    r = _sync(client, h("chef2"), _op("cle-test-h0001", c["id"], agent_id=base["ag1"]["id"]))
    assert (r[0]["statut"], r[0]["code"]) == ("refusee", "droit_agence")
    r = _sync(client, _hdr(client, "agent_sync"), _op("cle-test-h0002", 99999999))   # cycle inexistant
    assert (r[0]["statut"], r[0]["code"]) == ("refusee", "droit_agence")
    # un agent ne saisit pas pour un autre agent
    r = _sync(client, _hdr(client, "agent_sync"), _op("cle-test-h0003", c["id"], agent_id=base["ag2"]["id"]))
    assert (r[0]["statut"], r[0]["code"]) == ("refusee", "droit_agence")
    assert _nb_lignes(client, h, c["id"]) == 0


def test_cle_d_un_autre_utilisateur_et_refus_rejouable(client, h, base):
    c = _cycle(client, h, base)
    assert _sync(client, _hdr(client, "agent_sync"), _op("cle-test-i0001", c["id"]))[0]["statut"] == "appliquee"
    r = _sync(client, _hdr(client, "agent_sync_bis"), _op("cle-test-i0001", c["id"]))
    assert (r[0]["statut"], r[0]["code"]) == ("refusee", "cle_conflit")
    # un refus n'est pas mémorisé : la même clé peut être rejouée une fois la cause levée
    c2 = _cycle(client, h, base)
    hdr = _hdr(client, "agent_sync")
    assert _sync(client, hdr, _op("cle-test-i0002", c2["id"], 1500))[0]["statut"] == "refusee"
    assert _sync(client, hdr, _op("cle-test-i0002", c2["id"], 2000))[0]["statut"] == "appliquee"


def test_chef_precise_l_agent_et_droits(client, h, base):
    c = _cycle(client, h, base)
    r = _sync(client, h("chef1"), _op("cle-test-j0001", c["id"]))
    assert (r[0]["statut"], r[0]["code"]) == ("refusee", "droit_agence")             # chef sans agent_id
    assert _sync(client, h("chef1"), _op("cle-test-j0002", c["id"], agent_id=base["ag2"]["id"]))[0]["statut"] == "appliquee"
    r = _sync(client, h("chef1"), _op("cle-test-j0004", c["id"], agent_id=99999999))      # agent inexistant / d'une autre agence
    assert (r[0]["statut"], r[0]["code"]) == ("refusee", "droit_agence")
    corps = {"operations": [_op("cle-test-j0003", c["id"])]}
    assert client.post("/api/collecte/sync", json=corps, headers=h("caissier1")).status_code == 403
    assert client.post("/api/collecte/sync", json=corps).status_code == 401
    assert client.post("/api/collecte/sync", json={"operations": []}, headers=h("chef1")).status_code == 422
    assert client.post("/api/collecte/sync", json={"operations": [_op("court", c["id"])]}, headers=h("chef1")).status_code == 422
