import pytest

from app.routers import espace as mod_espace

# Module sous test : routers/espace.py (espace client sécurisé : connexion PIN + code SMS, isolation, verrouillage, journal)


@pytest.fixture(autouse=True)
def _sans_limite_ip(sql):
    mod_espace._tentatives.clear()
    sql("DELETE FROM client_otp")                       # la limite « 3 codes par quart d'heure » est testée à part
    yield
    mod_espace._tentatives.clear()


def _kyc(client, h, cid, piece, tel):
    assert client.put(f"/api/clients/{cid}/profil", json={"sexe": "F", "date_naissance": "1988-08-08", "adresse": "Lomé"}, headers=h("chef1")).status_code == 200
    assert client.post(f"/api/clients/{cid}/pieces", json={"type": "cni", "numero": piece, "date_expiration": "2041-01-01"}, headers=h("chef1")).status_code == 201
    assert client.post(f"/api/clients/{cid}/kyc/valider", headers=h("chef1")).status_code == 200


def _client_actif(client, h, nom, piece, tel="90001111"):
    c = client.post("/api/clients", json={"nom": nom, "telephone": tel}, headers=h("chef1")).json()
    _kyc(client, h, c["id"], piece, tel)
    assert client.post(f"/api/clients/{c['id']}/consentements", json={"finalite": "portail", "accorde": True, "canal": "papier"}, headers=h("chef1")).status_code == 201
    r = client.post(f"/api/clients/{c['id']}/acces/activer", headers=h("chef1"))
    assert r.status_code == 201, r.text
    return c, r.json()["pin_provisoire"]


def _connexion(client, numero, pin):
    r = client.post("/api/espace/connexion", json={"numero": numero, "pin": pin})
    assert r.status_code == 200, r.text
    o = client.post("/api/espace/otp", json={"numero": numero, "code": r.json()["otp_dev"]})
    assert o.status_code == 200, o.text
    return o.json()


def _hdr(jeton):
    return {"Authorization": "Bearer " + jeton}


@pytest.fixture(scope="module")
def base(client, h, sql, agences, produits):
    a, pin_a = _client_actif(client, h, "Esp Alpha Doe", "ESP-A-1")
    b, pin_b = _client_actif(client, h, "Esp Bravo Roe", "ESP-B-1", "90002222")
    ce = sql("INSERT INTO compte_epargne(agence_id, client_id, produit_id) VALUES (%s,%s,%s) RETURNING id, numero", (agences["a1"], a["id"], produits["CL"]))[0]
    sql("INSERT INTO mouvement_epargne(compte_id, type, montant, date_operation) VALUES (%s,'depot',80000,'2026-10-05')", (ce["id"],))
    ceb = sql("INSERT INTO compte_epargne(agence_id, client_id, produit_id) VALUES (%s,%s,%s) RETURNING id", (agences["a1"], b["id"], produits["CL"]))[0]["id"]
    ag = sql("INSERT INTO agent(agence_id, matricule, nom) VALUES (%s,'ESP-A','Agent E') RETURNING id", (agences["a1"],))[0]["id"]
    cy = sql("INSERT INTO cycle(agence_id, client_id, produit_id, type_cycle, mise_initiale, mise_courante, objectif, date_debut, date_fin) "
             "VALUES (%s,%s,%s,1,500,500,15500,'2026-10-01','2026-10-31') RETURNING id", (agences["a1"], a["id"], produits["P1"]))[0]["id"]
    sql("INSERT INTO ligne_collecte(cycle_id,page,no_ligne,date_collecte,agent_id,montant_collecte) VALUES (%s,1,1,'2026-10-02',%s,500)", (cy, ag))
    cr = sql("INSERT INTO credit(agence_id, numero, client_id, type, montant_accorde, taux, date_deblocage, nb_echeances, mode_remboursement) "
             "VALUES (%s,'CR-ESP-0001',%s,'sans_epargne',30000,0.12,'2026-10-01',3,'especes') RETURNING id", (agences["a1"], a["id"]))[0]["id"]
    sql("SELECT generer_echeancier(%s)", (cr,))
    return {"a": a, "pin_a": pin_a, "b": b, "pin_b": pin_b, "ce": ce, "ceb": ceb, "cy": cy, "cr": cr}


def test_parcours_complet_et_pin_provisoire(client, h, base):
    a, pin = base["a"], base["pin_a"]
    s = _connexion(client, a["numero"], pin)
    assert s["pin_provisoire"] is True
    t = _hdr(s["access_token"])
    assert client.get("/api/espace/moi", headers=t).json()["pin_provisoire"] is True
    assert client.get("/api/espace/comptes", headers=t).status_code == 403                     # PIN provisoire à changer d'abord
    assert client.post("/api/espace/pin", json={"ancien": pin, "nouveau": "123456"}, headers=t).status_code == 422
    assert client.post("/api/espace/pin", json={"ancien": pin, "nouveau": "111111"}, headers=t).status_code == 422
    assert client.post("/api/espace/pin", json={"ancien": pin, "nouveau": "12ab56"}, headers=t).status_code == 422
    assert client.post("/api/espace/pin", json={"ancien": "000000", "nouveau": "482916"}, headers=t).status_code == 403
    assert client.post("/api/espace/pin", json={"ancien": pin, "nouveau": "482916"}, headers=t).status_code == 204
    base["pin_a"] = "482916"
    s2 = _connexion(client, a["numero"], "482916")
    assert s2["pin_provisoire"] is False
    t2 = _hdr(s2["access_token"])
    comptes = client.get("/api/espace/comptes", headers=t2).json()
    assert len(comptes) == 1 and comptes[0]["solde"] == 80000 and comptes[0]["numero"].startswith("****") and base["ce"]["numero"] not in str(comptes)
    mv = client.get(f"/api/espace/comptes/{base['ce']['id']}/mouvements", headers=t2).json()
    assert mv[0]["montant"] == 80000 and mv[0]["type"] == "depot"
    assert client.get("/api/espace/cycles", headers=t2).json()[0]["montant_collecte"] == 500
    assert client.get(f"/api/espace/cycles/{base['cy']}/carnet", headers=t2).json()[0]["montant_collecte"] == 500
    cr = client.get("/api/espace/credits", headers=t2).json()
    assert cr[0]["montant_prochaine_echeance"] > 0 and cr[0]["numero"].startswith("****")
    ech = client.get(f"/api/espace/credits/{base['cr']}/echeances", headers=t2).json()
    assert len(ech) == 3 and ech[0]["reste_a_payer"] > 0
    j = client.get("/api/espace/journal", headers=t2).json()
    assert {x["evenement"] for x in j} >= {"connexion_ok", "pin_change"}
    assert client.post("/api/espace/deconnexion", headers=t2).status_code == 204


def test_isolation_entre_clients(client, h, base):
    sa = _connexion(client, base["a"]["numero"], base["pin_a"])
    # le client B doit changer son PIN provisoire avant tout ; on prépare sa session via le SQL du personnel serait contourner : on le fait proprement
    sb = _connexion(client, base["b"]["numero"], base["pin_b"])
    tb = _hdr(sb["access_token"])
    assert client.post("/api/espace/pin", json={"ancien": base["pin_b"], "nouveau": "703815"}, headers=tb).status_code == 204
    base["pin_b"] = "703815"
    ta = _hdr(sa["access_token"])
    # A ne peut ni lire le compte de B ni le cycle / crédit d'un autre
    assert client.get(f"/api/espace/comptes/{base['ceb']}/mouvements", headers=ta).status_code == 404
    assert client.get(f"/api/espace/cycles/{base['cy'] + 1000}/carnet", headers=ta).status_code == 404
    sb2 = _connexion(client, base["b"]["numero"], base["pin_b"])
    tb2 = _hdr(sb2["access_token"])
    assert client.get(f"/api/espace/cycles/{base['cy']}/carnet", headers=tb2).status_code == 404            # cycle de A
    assert client.get(f"/api/espace/credits/{base['cr']}/echeances", headers=tb2).status_code == 404         # crédit de A
    assert client.get("/api/espace/credits", headers=tb2).json() == []


def test_jetons_non_interchangeables(client, h, base):
    jeton_client = _connexion(client, base["a"]["numero"], base["pin_a"])["access_token"]
    assert client.get("/api/auth/me", headers=_hdr(jeton_client)).status_code == 401              # jeton client refusé côté personnel
    assert client.get("/api/clients", headers=_hdr(jeton_client)).status_code == 401
    assert client.get("/api/espace/moi", headers=h("admin")).status_code == 401                   # jeton du personnel refusé côté client
    assert client.get("/api/espace/moi").status_code == 401
    assert client.get("/api/espace/moi", headers={"Authorization": "Bearer n-importe-quoi"}).status_code == 401


def test_connexion_sans_enumeration_et_verrouillage(client, h, base, sql):
    inconnu = client.post("/api/espace/connexion", json={"numero": "CL-INCONNU-0000", "pin": "482916"})
    faux = client.post("/api/espace/connexion", json={"numero": base["a"]["numero"], "pin": "999888"})
    assert inconnu.status_code == faux.status_code == 401 and inconnu.json() == faux.json()          # réponses indiscernables
    for _ in range(4):
        assert client.post("/api/espace/connexion", json={"numero": base["a"]["numero"], "pin": "999888"}).status_code == 401
    # 5 échecs cumulés : verrouillé, même avec le bon PIN
    assert client.post("/api/espace/connexion", json={"numero": base["a"]["numero"], "pin": base["pin_a"]}).status_code == 429
    ev = {r["evenement"] for r in sql("SELECT evenement FROM acces_client_log WHERE client_id = %s", (base["a"]["id"],))}
    assert {"echec_pin", "verrouillage", "connexion_verrouillee"} <= ev
    sql("UPDATE client_acces SET echecs = 0, verrouille_jusqua = NULL WHERE client_id = %s", (base["a"]["id"],))      # simule l'expiration du verrou


def test_code_sms_usage_unique_et_limites(client, h, base, sql):
    a = base["a"]
    sql("DELETE FROM client_otp WHERE client_id = %s", (a["id"],))
    r = client.post("/api/espace/connexion", json={"numero": a["numero"], "pin": base["pin_a"]}).json()
    code = r["otp_dev"]
    faux = "000000" if code != "000000" else "111111"
    for _ in range(3):
        assert client.post("/api/espace/otp", json={"numero": a["numero"], "code": faux}).status_code == 401
    assert client.post("/api/espace/otp", json={"numero": a["numero"], "code": code}).status_code == 401       # code consommé par les essais
    # nouveau code accepté une fois seulement
    code2 = client.post("/api/espace/connexion", json={"numero": a["numero"], "pin": base["pin_a"]}).json()["otp_dev"]
    assert client.post("/api/espace/otp", json={"numero": a["numero"], "code": code2}).status_code == 200
    assert client.post("/api/espace/otp", json={"numero": a["numero"], "code": code2}).status_code == 401       # pas de rejeu
    assert client.post("/api/espace/otp", json={"numero": a["numero"], "code": "12ab"}).status_code == 422
    # limite de 3 codes par quart d'heure : 2 déjà demandés, le 3e passe, le 4e est refusé
    assert client.post("/api/espace/connexion", json={"numero": a["numero"], "pin": base["pin_a"]}).status_code == 200
    assert client.post("/api/espace/connexion", json={"numero": a["numero"], "pin": base["pin_a"]}).status_code == 429
    sql("DELETE FROM client_otp WHERE client_id = %s", (a["id"],))


def test_blocage_effet_immediat_et_reactivation(client, h, base, sql):
    b = base["b"]
    jeton = _connexion(client, b["numero"], base["pin_b"])["access_token"]
    assert client.get("/api/espace/moi", headers=_hdr(jeton)).status_code == 200
    assert client.post(f"/api/clients/{b['id']}/acces/bloquer", json={"motif": "téléphone perdu"}, headers=h("caissier1")).status_code == 403
    assert client.post(f"/api/clients/{b['id']}/acces/bloquer", json={"motif": "téléphone perdu"}, headers=h("chef1")).status_code == 200
    assert client.get("/api/espace/moi", headers=_hdr(jeton)).status_code == 401                 # le jeton déjà émis cesse de fonctionner
    assert client.post("/api/espace/connexion", json={"numero": b["numero"], "pin": base["pin_b"]}).status_code == 401
    # retrait du consentement : réactivation impossible tant qu'il n'est pas redonné
    assert client.post(f"/api/clients/{b['id']}/consentements", json={"finalite": "portail", "accorde": False}, headers=h("chef1")).status_code == 201
    assert client.post(f"/api/clients/{b['id']}/acces/activer", headers=h("chef1")).status_code == 422
    assert client.post(f"/api/clients/{b['id']}/consentements", json={"finalite": "portail", "accorde": True, "canal": "papier"}, headers=h("chef1")).status_code == 201
    nouveau = client.post(f"/api/clients/{b['id']}/acces/activer", headers=h("chef1")).json()["pin_provisoire"]
    assert _connexion(client, b["numero"], nouveau)["pin_provisoire"] is True
    etat = client.get(f"/api/clients/{b['id']}/acces", headers=h("chef1")).json()
    assert etat["existe"] and etat["actif"] and {"acces_bloque", "acces_active", "connexion_ok"} <= {x["evenement"] for x in etat["journal"]}


def test_conditions_d_ouverture_et_droits(client, h, base, sql):
    c = client.post("/api/clients", json={"nom": "Esp Sans Kyc", "telephone": "90003333"}, headers=h("chef1")).json()
    assert client.post(f"/api/clients/{c['id']}/consentements", json={"finalite": "portail", "accorde": True, "canal": "papier"}, headers=h("chef1")).status_code == 201
    r = client.post(f"/api/clients/{c['id']}/acces/activer", headers=h("chef1"))
    assert r.status_code == 422 and "KYC" in r.json()["detail"]
    assert client.post(f"/api/clients/{c['id']}/acces/activer", headers=h("caissier1")).status_code == 403
    assert client.post(f"/api/clients/{c['id']}/acces/activer", headers=h("chef2")).status_code == 404
    assert client.get(f"/api/clients/{c['id']}/acces", headers=h("chef2")).status_code == 404
    assert client.post(f"/api/clients/{c['id']}/consentements", json={"finalite": "portail", "accorde": True}, headers=h("agent1")).status_code == 403


def test_aucun_secret_dans_les_traces_et_en_tetes(client, h, base, sql):
    secrets_ = sql("SELECT pin_hash FROM client_acces")
    assert secrets_ and all(not r["pin_hash"].startswith("000") for r in secrets_)
    audit = sql("SELECT apres::text AS a, avant::text AS b FROM audit_log WHERE table_name = 'client_acces'")
    assert audit and all("pin_hash" not in (x["a"] or "") and "pin_hash" not in (x["b"] or "") for x in audit)
    assert all(pin not in str(sql("SELECT * FROM acces_client_log")) for pin in (base["pin_a"], base["pin_b"]))
    r = client.get("/api/espace/moi")
    assert r.headers["cache-control"] == "no-store" and r.headers["x-frame-options"] == "DENY" and r.headers["x-content-type-options"] == "nosniff"
    for ligne in sql("SELECT message FROM sms_outbox WHERE type = 'otp'"):
        assert not any(ch.isdigit() for ch in ligne["message"].replace("5 min", ""))               # le code n'est pas conservé dans la file
