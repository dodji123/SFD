import pytest

JOUR = "2031-03-10"
LENDEMAIN = "2031-03-11"


@pytest.fixture(scope="module")
def base(client, h, agences):
    """Agence 2 : un coffre, deux guichets et un compte bancaire."""
    def caisse(code, type_, **kw):
        r = client.post("/api/caisses", json={"code": code, "type": type_, **kw}, headers=h("chef2"))
        assert r.status_code == 201, r.text
        return r.json()

    coffre = caisse("TCF", "coffre", libelle="Coffre test", plafond=2000000)
    g1 = caisse("TG1", "guichet", libelle="Guichet test 1", plafond=150000)
    g2 = caisse("TG2", "guichet")
    banque = client.post("/api/banques", json={"code": "TBQ", "libelle": "Compte test", "banque": "Banque X"}, headers=h("chef2"))
    assert banque.status_code == 201, banque.text
    return {"coffre": coffre, "g1": g1, "g2": g2, "banque": banque.json()}


def _ouvrir(client, h, caisse, jour, solde, login="caissier2", **kw):
    return client.post(f"/api/caisses/{caisse['id']}/sessions", json={"date_session": jour, "solde_ouverture": solde, **kw}, headers=h(login))


def _session_ouverte(client, h, code):
    return [s for s in client.get("/api/sessions", params={"statut": "ouverte"}, headers=h("caissier2")).json() if s["caisse"] == code][0]


def test_ouverture_continuite_et_fermeture(client, h, base):
    cf = base["coffre"]
    r = _ouvrir(client, h, cf, JOUR, 1000000)
    assert r.status_code == 201 and r.json()["ecart_ouverture"] == 0
    sid = r.json()["id"]
    assert _ouvrir(client, h, cf, LENDEMAIN, 1000000).status_code == 422                 # une session est déjà ouverte
    assert client.post(f"/api/sessions/{sid}/fermer", json={"solde_compte": 1000000}, headers=h("caissier2")).status_code == 200
    r = _ouvrir(client, h, cf, LENDEMAIN, 990000)
    assert r.status_code == 422 and "diffère du solde compté" in r.json()["detail"]
    r = _ouvrir(client, h, cf, LENDEMAIN, 990000, accepter_ecart=True)
    assert r.status_code == 201 and r.json()["ecart_ouverture"] == -10000                  # écart accepté et tracé
    assert _ouvrir(client, h, cf, JOUR, 1).status_code == 422                              # date antérieure
    assert _ouvrir(client, h, cf, "2031-03-12", 5, login="agent1").status_code == 403


def test_transfert_entre_caisses(client, h, base, agences):
    g1 = base["g1"]
    s_g1 = _ouvrir(client, h, g1, LENDEMAIN, 50000).json()
    s_cf = _session_ouverte(client, h, "TCF")
    r = client.post("/api/sessions/transfert", json={"session_source": s_cf["id"], "session_dest": s_g1["id"], "montant": 200000,
                                                    "date": LENDEMAIN, "motif": "approvisionnement"}, headers=h("caissier2"))
    assert r.status_code == 201 and r.json()["caisse_source"] == "TCF" and r.json()["caisse_dest"] == "TG1"
    assert client.get(f"/api/sessions/{s_cf['id']}", headers=h("caissier2")).json()["solde_theorique"] == 790000
    assert client.get(f"/api/sessions/{s_g1['id']}", headers=h("caissier2")).json()["solde_theorique"] == 250000
    # refus : même session, au-delà du solde, droits, autre agence
    assert client.post("/api/sessions/transfert", json={"session_source": s_cf["id"], "session_dest": s_cf["id"], "montant": 1}, headers=h("caissier2")).status_code == 422
    assert client.post("/api/sessions/transfert", json={"session_source": s_cf["id"], "session_dest": s_g1["id"], "montant": 9000000}, headers=h("caissier2")).status_code == 422
    assert client.post("/api/sessions/transfert", json={"session_source": s_cf["id"], "session_dest": s_g1["id"], "montant": 10}, headers=h("agent1")).status_code == 403
    assert client.post("/api/sessions/transfert", json={"session_source": s_cf["id"], "session_dest": s_g1["id"], "montant": 10}, headers=h("caissier1")).status_code == 404
    lst = client.get("/api/transferts-caisse", params={"du": LENDEMAIN}, headers=h("chef2")).json()
    assert len(lst) == 1 and lst[0]["montant"] == 200000 and lst[0]["motif"] == "approvisionnement"
    assert all(t["agence_id"] == agences["a1"] for t in client.get("/api/transferts-caisse", headers=h("chef1")).json())


def test_banque_versement_retrait_rapprochement(client, h, base):
    banque = base["banque"]
    sid = _session_ouverte(client, h, "TG1")["id"]
    r = client.post(f"/api/sessions/{sid}/versement-banque", json={"compte_banque_id": banque["id"], "montant": 100000, "date": LENDEMAIN}, headers=h("caissier2"))
    assert r.status_code == 201 and r.json()["type"] == "versement_caisse"
    assert client.get(f"/api/sessions/{sid}", headers=h("caissier2")).json()["solde_theorique"] == 150000
    r = client.post(f"/api/sessions/{sid}/retrait-banque", json={"compte_banque_id": banque["id"], "montant": 30000, "date": LENDEMAIN}, headers=h("caissier2"))
    assert r.status_code == 201
    assert client.post(f"/api/sessions/{sid}/retrait-banque", json={"compte_banque_id": banque["id"], "montant": 900000}, headers=h("caissier2")).status_code == 422
    assert client.post(f"/api/sessions/{sid}/versement-banque", json={"compte_banque_id": banque["id"], "montant": 99999999}, headers=h("caissier2")).status_code == 422
    # mouvements sans caisse : le caissier n'y a pas droit, le chef d'agence oui
    ext = {"type": "frais", "montant": 5000, "date": LENDEMAIN, "libelle": "Frais de tenue"}
    assert client.post(f"/api/banques/{banque['id']}/mouvements", json=ext, headers=h("caissier2")).status_code == 403
    r = client.post(f"/api/banques/{banque['id']}/mouvements", json=ext, headers=h("chef2"))
    assert r.status_code == 201
    mid = r.json()["id"]
    assert client.post(f"/api/banques/{banque['id']}/mouvements", json={**ext, "montant": 99999999}, headers=h("chef2")).status_code == 422   # pas de découvert
    soldes = {b["code"]: b for b in client.get("/api/banques", headers=h("chef2")).json()}
    assert soldes["TBQ"]["solde"] == 65000 and soldes["TBQ"]["non_rapproches"] == 3         # 100000 - 30000 - 5000
    assert client.post(f"/api/banques/mouvements/{mid}/rapprocher", json={}, headers=h("chef2")).json()["rapproche"] is True
    assert client.post(f"/api/banques/mouvements/{mid}/rapprocher", json={}, headers=h("chef1")).status_code == 404
    mv = client.get(f"/api/banques/{banque['id']}/mouvements", headers=h("chef2")).json()
    assert [m["type"] for m in mv] == ["frais", "retrait_caisse", "versement_caisse"] and mv[0]["rapproche"] is True
    assert client.get(f"/api/banques/{banque['id']}/mouvements", headers=h("chef1")).status_code == 404
    assert "TBQ" not in {b["code"] for b in client.get("/api/banques", headers=h("chef1")).json()}


def test_etat_des_caisses_position_et_prevision(client, h, base, agences):
    r = client.get("/api/caisses/etat", params={"date": LENDEMAIN}, headers=h("chef2"))
    assert r.status_code == 200
    etat = {c["code"]: c for c in r.json()}
    assert etat["TCF"]["etat"] == "ouverte" and etat["TCF"]["solde"] == 790000
    assert etat["TG1"]["solde"] == 180000 and etat["TG1"]["depassement_plafond"] == 30000          # plafond 150000
    assert etat["TG2"]["etat"] == "non_ouverte"
    pos = client.get("/api/tresorerie/position", params={"date": LENDEMAIN}, headers=h("chef2")).json()
    liq = {l["code"]: l["solde"] for l in pos["liquidites"]}
    assert liq["TCF"] == 790000 and liq["TG1"] == 180000 and liq["TBQ"] == 65000
    assert pos["indicateurs"]["liquidites_totales"] >= 790000 + 180000 + 65000
    assert pos["indicateurs"]["depassement_plafonds_caisses"] >= 30000
    prev = client.get("/api/tresorerie/prevision", params={"date": LENDEMAIN, "jours": 30, "pas": 10}, headers=h("chef2")).json()
    assert len(prev) == 3 and prev[0]["debut"] == LENDEMAIN
    assert client.get("/api/tresorerie/prevision", params={"date": LENDEMAIN, "jours": 0}, headers=h("chef2")).status_code == 422
    # droits et cloisonnement
    assert client.get("/api/tresorerie/position", params={"date": LENDEMAIN}, headers=h("agent1")).status_code == 403
    assert client.get("/api/tresorerie/position", params={"date": LENDEMAIN}, headers=h("admin")).status_code == 400       # le siège désigne l'agence
    assert client.get("/api/caisses/etat", params={"date": LENDEMAIN, "agence_id": agences["a1"]}, headers=h("chef2")).status_code == 403
    assert "TCF" not in {c["code"] for c in client.get("/api/caisses/etat", params={"date": LENDEMAIN}, headers=h("chef1")).json()}


def test_gestion_des_caisses(client, h, base, utilisateurs):
    cid = base["g2"]["id"]
    r = client.patch(f"/api/caisses/{cid}", json={"libelle": "Guichet 2", "plafond": 500000, "responsable_id": utilisateurs["caissier2"]}, headers=h("chef2"))
    assert r.status_code == 200 and r.json()["plafond"] == 500000
    assert client.patch(f"/api/caisses/{cid}", json={"plafond": 1}, headers=h("caissier2")).status_code == 403
    assert client.patch(f"/api/caisses/{cid}", json={"responsable_id": utilisateurs["caissier1"]}, headers=h("chef2")).status_code == 422   # responsable d'une autre agence
    assert client.patch(f"/api/caisses/{cid}", json={}, headers=h("chef2")).status_code == 422
    lst = {c["code"]: c for c in client.get("/api/caisses", headers=h("chef2")).json()}
    assert lst["TG2"]["responsable"] == "Caissier2"
    # on ne désactive pas une caisse dont la session est ouverte
    assert client.patch(f"/api/caisses/{base['coffre']['id']}", json={"actif": False}, headers=h("chef2")).status_code == 422
    assert client.patch(f"/api/caisses/{cid}", json={"actif": False}, headers=h("chef2")).json()["actif"] is False
    assert _ouvrir(client, h, base["g2"], "2031-04-01", 10).status_code == 422                  # caisse désactivée
