import json

import pytest

from app import mobilemoney
from app.config import settings
from app.routers import espace as mod_espace

# Module sous test : routers/espace_paiements.py (espace client : mobile money, suivi de sa collecte, demande de retrait) + schema/49_mobile_money.sql


@pytest.fixture(autouse=True)
def _sans_limite_ip(sql):
    mod_espace._tentatives.clear()
    sql("DELETE FROM client_otp")
    yield
    mod_espace._tentatives.clear()


def _client_pret(client, h, nom, piece, tel):
    c = client.post("/api/clients", json={"nom": nom, "telephone": tel}, headers=h("chef1")).json()
    cid = c["id"]
    assert client.put(f"/api/clients/{cid}/profil", json={"sexe": "F", "date_naissance": "1988-08-08", "adresse": "Lomé"}, headers=h("chef1")).status_code == 200
    assert client.post(f"/api/clients/{cid}/pieces", json={"type": "cni", "numero": piece, "date_expiration": "2041-01-01"}, headers=h("chef1")).status_code == 201
    assert client.post(f"/api/clients/{cid}/kyc/valider", headers=h("chef1")).status_code == 200
    assert client.post(f"/api/clients/{cid}/consentements", json={"finalite": "portail", "accorde": True, "canal": "papier"}, headers=h("chef1")).status_code == 201
    pin = client.post(f"/api/clients/{cid}/acces/activer", headers=h("chef1")).json()["pin_provisoire"]

    def ouvrir(p):
        r = client.post("/api/espace/connexion", json={"numero": c["numero"], "pin": p})
        o = client.post("/api/espace/otp", json={"numero": c["numero"], "code": r.json()["otp_dev"]})
        return o.json()
    s = ouvrir(pin)
    t = {"Authorization": "Bearer " + s["access_token"]}
    assert client.post("/api/espace/pin", json={"ancien": pin, "nouveau": "482916"}, headers=t).status_code == 204
    return c, {"Authorization": "Bearer " + ouvrir("482916")["access_token"]}


@pytest.fixture(scope="module")
def base(client, h, sql, agences, produits):
    a, ta = _client_pret(client, h, "Mm Alpha", "MM-A-1", "90003333")
    b, tb = _client_pret(client, h, "Mm Bravo", "MM-B-1", "90004444")
    cy = sql("INSERT INTO cycle(agence_id, client_id, produit_id, type_cycle, mise_initiale, mise_courante, objectif, date_debut, date_fin) "
             "VALUES (%s,%s,%s,1,500,500,15500,current_date - 3,current_date + 27) RETURNING id", (agences["a1"], a["id"], produits["P1"]))[0]["id"]
    cyb = sql("INSERT INTO cycle(agence_id, client_id, produit_id, type_cycle, mise_initiale, mise_courante, objectif, date_debut, date_fin) "
              "VALUES (%s,%s,%s,1,500,500,15500,current_date - 3,current_date + 27) RETURNING id", (agences["a1"], b["id"], produits["P1"]))[0]["id"]
    return {"a": a, "ta": ta, "b": b, "tb": tb, "cy": cy, "cyb": cyb}


def _paiement(client, base, montant=1500, cle="cle-mm-0001", cycle=None, jeton="ta"):
    return client.post("/api/espace/paiements", json={"cycle_id": cycle or base["cy"], "operateur": "TMONEY", "telephone": "+22890123456", "montant": montant, "cle": cle}, headers=base[jeton])


def test_paiement_simule_idempotence_et_isolation(client, h, base):
    ta, tb = base["ta"], base["tb"]
    assert client.get("/api/espace/operateurs", headers=ta).json()["mode"] == "simulation"
    assert _paiement(client, base, 1500, "cle-mm-0001", cycle=base["cyb"]).status_code == 404                # le cycle d'un autre client
    assert _paiement(client, base, 700, "cle-mm-0002").status_code == 422                                  # pas un multiple de la mise
    p = _paiement(client, base, 1500, "cle-mm-0003")
    assert p.status_code == 201, p.text
    ref = p.json()["reference"]
    assert p.json()["statut"] == "initie" and p.json()["simulation"] is True and "telephone" not in p.json()
    assert _paiement(client, base, 1500, "cle-mm-0003").json()["reference"] == ref                          # rejouer ne crée rien
    assert _paiement(client, base, 500, "cle-mm-0004").status_code == 409                                  # un seul paiement en attente par cycle
    assert client.get(f"/api/espace/paiements/{ref}", headers=tb).status_code == 404                        # isolation
    ok = client.post(f"/api/espace/paiements/{ref}/simuler", json={"issue": "succes"}, headers=ta)
    assert ok.status_code == 200 and ok.json()["statut"] == "reussi"
    assert client.post(f"/api/espace/paiements/{ref}/simuler", json={"issue": "echec"}, headers=ta).json()["statut"] == "reussi"      # issue déjà jouée
    suivi = client.get(f"/api/espace/cycles/{base['cy']}/suivi", headers=ta).json()
    assert float(suivi["montant_collecte"]) == 1500 and suivi["nb_lignes"] == 1 and suivi["lignes"][0]["origine"] == "mobile"
    assert suivi["paiements"][0]["reference"] == ref and suivi["progression"] == 10 and suivi["demande_retrait"] is None
    assert client.get(f"/api/espace/cycles/{base['cy']}/suivi", headers=tb).status_code == 404
    echec = _paiement(client, base, 500, "cle-mm-0005")
    assert client.post(f"/api/espace/paiements/{echec.json()['reference']}/simuler", json={"issue": "echec"}, headers=ta).json()["statut"] == "echoue"
    assert [x["statut"] for x in client.get("/api/espace/paiements", headers=ta).json()][:2] == ["echoue", "reussi"]
    assert client.get("/api/espace/paiements", headers=tb).json() == []


def test_simulation_interdite_et_webhook_signe(client, h, base, monkeypatch):
    p = _paiement(client, base, 500, "cle-mm-0010").json()
    monkeypatch.setattr(settings, "mobile_money_mode", "live")
    assert client.post(f"/api/espace/paiements/{p['reference']}/simuler", json={"issue": "succes"}, headers=base["ta"]).status_code == 403
    monkeypatch.setattr(settings, "mobile_money_webhook_secret", "secret-test-webhook")
    corps = json.dumps({"reference": p["reference"], "issue": "succes", "reference_operateur": "TM-777"}).encode()
    assert client.post("/api/mobile-money/webhook/TMONEY", content=corps).status_code == 401              # sans signature
    assert client.post("/api/mobile-money/webhook/TMONEY", content=corps, headers={"X-Signature": "00" * 32}).status_code == 401
    sig = mobilemoney.signature(corps, "secret-test-webhook")
    assert client.post("/api/mobile-money/webhook/FLOOZ", content=corps, headers={"X-Signature": sig}).status_code == 404      # mauvais opérateur
    ok = client.post("/api/mobile-money/webhook/TMONEY", content=corps, headers={"X-Signature": sig})
    assert ok.status_code == 200 and ok.json()["statut"] == "reussi"
    assert client.post("/api/mobile-money/webhook/TMONEY", content=corps, headers={"X-Signature": sig}).json()["statut"] == "reussi"    # rejeu sans effet
    assert client.get("/api/paiements-mobile", params={"statut": "reussi", "q": "Mm Alpha"}, headers=h("auditeur")).status_code == 200
    assert client.get("/api/paiements-mobile", headers=h("agent1")).status_code == 403
    assert client.get("/api/paiements-mobile", headers=h("chef2")).json() == []                           # autre agence


def test_demande_de_retrait_et_decision(client, h, base):
    ta, tb = base["ta"], base["tb"]
    assert client.post("/api/espace/demandes-retrait", json={"cycle_id": base["cyb"]}, headers=ta).status_code == 404          # cycle d'un autre
    assert client.post("/api/espace/demandes-retrait", json={"cycle_id": base["cy"], "canal": "mobile_money"}, headers=ta).status_code == 422   # opérateur et numéro manquants
    d = client.post("/api/espace/demandes-retrait", json={"cycle_id": base["cy"], "canal": "mobile_money", "operateur": "TMONEY", "telephone": "+22890123456", "motif": "Besoin"}, headers=ta)
    assert d.status_code == 201, d.text
    did = d.json()["id"]
    assert client.post("/api/espace/demandes-retrait", json={"cycle_id": base["cy"]}, headers=ta).status_code == 409             # une seule demande en attente
    assert client.post(f"/api/espace/demandes-retrait/{did}/annuler", headers=tb).status_code == 422                           # pas la sienne
    assert [x["statut"] for x in client.get("/api/espace/demandes-retrait", headers=ta).json()] == ["en_attente"]
    assert client.get("/api/demandes-retrait-client", params={"statut": "en_attente"}, headers=h("chef1")).json()[0]["client"] == "Mm Alpha"
    assert client.post(f"/api/demandes-retrait-client/{did}/decider", json={"accepte": True}, headers=h("agent1")).status_code == 403
    assert client.post(f"/api/demandes-retrait-client/{did}/decider", json={"accepte": False}, headers=h("chef1")).status_code == 422   # refus non motivé
    ok = client.post(f"/api/demandes-retrait-client/{did}/decider", json={"accepte": True, "commentaire": "Pièce vérifiée"}, headers=h("chef1"))
    assert ok.status_code == 200 and ok.json()["statut"] == "acceptee" and ok.json()["retrait_id"]
    suivi = client.get(f"/api/espace/cycles/{base['cy']}/suivi", headers=ta).json()
    assert suivi["statut"] == "clos" and suivi["retrait"]["statut"] == "demande" and suivi["demande_retrait"]["statut"] == "acceptee"
    assert client.post(f"/api/demandes-retrait-client/{did}/decider", json={"accepte": True}, headers=h("chef1")).status_code == 422   # déjà décidée
    assert client.post("/api/espace/demandes-retrait", json={"cycle_id": base["cy"]}, headers=ta).status_code == 422             # un retrait existe déjà
    assert _paiement(client, base, 500, "cle-mm-0020").status_code == 422                                                       # plus de versement sur un cycle clos
    assert client.get("/api/demandes-retrait-client", headers=h("chef2")).json() == []
