import datetime as dt

import pytest

# Module sous test : routers/comites.py (comité de gestion du crédit : périmètre, séances, votes, décision, PV, délégations)


@pytest.fixture(scope="module")
def base(client, h, sql, utilisateurs, agences):
    c = client.post("/api/clients", json={"nom": "Client comité"}, headers=h("chef1")).json()
    p = client.post("/api/produits-credit", json={"code": "PCOM", "libelle": "Crédit comité", "type": "sans_epargne", "taux_annuel": 0.18}, headers=h("chef1")).json()
    demandes = {}
    for cle, montant in (("d1", 300000), ("d2", 800000), ("d3", 3000000), ("d4", 200000), ("d5", 200000), ("d6", 300000)):
        r = client.post("/api/demandes-credit", json={"client_id": c["id"], "produit_id": p["id"], "montant": montant, "nb_echeances": 12, "mode_remboursement": "especes"}, headers=h("chef1"))
        assert r.status_code == 201, r.text
        demandes[cle] = r.json()
    sql("UPDATE institution SET raison_sociale = 'Caisse Comité Test' WHERE id = 1")
    yield {"client": c, "demandes": demandes, "u": utilisateurs, "a1": agences["a1"], "a2": agences["a2"]}
    sql("DELETE FROM parametre WHERE cle = 'comite_credit_obligatoire'")


@pytest.fixture(scope="module")
def comite(client, h, base):
    r = client.post("/api/comites", json={"code": "CCA1", "libelle": "Comité agence T1", "agence_id": base["a1"], "montant_max": 1000000, "quorum": 3}, headers=h("chef1"))
    assert r.status_code == 201, r.text
    cid = r.json()["id"]
    for login, fonction, voix in (("chef1", "president", True), ("caissier1", "secretaire", True), ("agent1", "membre", True),
                                  ("coll1", "membre", True), ("rh1", "membre", False)):
        m = client.post(f"/api/comites/{cid}/membres", json={"utilisateur_id": base["u"][login], "fonction": fonction, "avec_voix": voix}, headers=h("chef1"))
        assert m.status_code == 201, m.text
    return cid


def test_perimetre_et_droits_de_gestion(client, h, base, comite):
    assert client.post("/api/comites", json={"code": "X", "libelle": "x", "agence_id": base["a1"]}, headers=h("caissier1")).status_code == 403
    assert client.post("/api/comites", json={"code": "X2", "libelle": "x", "agence_id": base["a2"]}, headers=h("chef1")).status_code == 403     # autre agence
    assert client.post("/api/comites", json={"code": "X3", "libelle": "x"}, headers=h("chef1")).status_code == 403                               # comité central : siège seul
    assert client.get(f"/api/comites/{comite}", headers=h("chef2")).status_code == 404
    assert all(c["id"] != comite for c in client.get("/api/comites", headers=h("chef2")).json())
    assert any(c["id"] == comite and c["nb_membres"] == 5 for c in client.get("/api/comites", headers=h("chef1")).json())
    # un membre d'une autre agence ne peut pas siéger au comité d'agence
    r = client.post(f"/api/comites/{comite}/membres", json={"utilisateur_id": base["u"]["chef2"], "fonction": "membre"}, headers=h("chef1"))
    assert r.status_code == 422
    # un second président est refusé par la base
    r = client.post(f"/api/comites/{comite}/membres", json={"utilisateur_id": base["u"]["rh1"], "fonction": "president"}, headers=h("chef1"))
    assert r.status_code == 409
    assert client.get(f"/api/comites/{comite}", headers=h("agent1")).json()["membres"][0]["fonction"] == "president"


def test_demandes_a_examiner_respecte_la_competence(client, h, base, comite):
    liste = client.get(f"/api/comites/demandes/a-examiner?comite_id={comite}", headers=h("chef1")).json()
    ids = {d["id"] for d in liste}
    assert base["demandes"]["d1"]["id"] in ids and base["demandes"]["d2"]["id"] in ids
    assert base["demandes"]["d3"]["id"] not in ids                                                              # 3 000 000 > plafond du comité


@pytest.fixture(scope="module")
def seance(client, h, base, comite):
    d = base["demandes"]
    s = client.post("/api/comites/seances", json={"comite_id": comite, "date_seance": (dt.datetime.now(dt.timezone.utc) + dt.timedelta(days=3)).isoformat(), "lieu": "Salle du conseil"}, headers=h("chef1"))
    assert s.status_code == 201, s.text
    sid = s.json()["id"]
    assert client.post(f"/api/comites/seances/{sid}/dossiers", json={"demande_id": d["d3"]["id"]}, headers=h("chef1")).status_code == 422      # hors compétence
    dos = {}
    for cle in ("d1", "d2", "d4"):
        r = client.post(f"/api/comites/seances/{sid}/dossiers", json={"demande_id": d[cle]["id"], "rapporteur_id": base["u"]["agent1"], "analyse_individuelle": f"Analyse de {cle} : activité régulière."}, headers=h("chef1"))
        assert r.status_code == 201, r.text
        dos[cle] = r.json()["id"]
    return {"id": sid, "dos": dos}


def test_conduite_de_la_seance_jusqu_a_la_decision(client, h, base, comite, seance):
    sid, dos, d, u = seance["id"], seance["dos"], base["demandes"], base["u"]
    assert client.post(f"/api/comites/seances/{sid}/convoquer", headers=h("agent1")).status_code == 403                  # simple membre : pas d'animation
    assert client.post(f"/api/comites/seances/{sid}/convoquer", headers=h("chef1")).status_code == 422                   # pas d'ordre du jour
    assert client.patch(f"/api/comites/seances/{sid}", json={"ordre_du_jour": "1. D1, D2, D4"}, headers=h("chef1")).status_code == 200
    conv = client.post(f"/api/comites/seances/{sid}/convoquer", headers=h("chef1"))
    assert conv.status_code == 200 and conv.json()["statut"] == "convoquee" and len(conv.json()["membres"]) == 5
    # présences
    assert client.post(f"/api/comites/seances/{sid}/ouvrir", headers=h("chef1")).status_code == 422                      # présences incomplètes
    for login, present in (("chef1", True), ("caissier1", True), ("agent1", True), ("coll1", False), ("rh1", True)):
        r = client.post(f"/api/comites/seances/{sid}/presences", json={"utilisateur_id": u[login], "present": present, "motif_absence": None if present else "Mission"}, headers=h("chef1"))
        assert r.status_code == 200, r.text
    ouverte = client.post(f"/api/comites/seances/{sid}/ouvrir", headers=h("chef1"))
    assert ouverte.status_code == 200 and ouverte.json()["quorum_atteint"] is True                                         # 3 présents avec voix sur 4

    # votes : l'absente et le membre consultatif sont refusés
    v = {"vote": "acceptation", "motif": "Dossier solide, remboursement possible"}
    assert client.post(f"/api/comites/dossiers/{dos['d1']}/vote", json=v, headers=h("coll1")).status_code == 422
    assert client.post(f"/api/comites/dossiers/{dos['d1']}/vote", json=v, headers=h("rh1")).status_code == 422
    assert client.post(f"/api/comites/dossiers/{dos['d1']}/vote", json={"vote": "rejet"}, headers=h("agent1")).status_code == 422   # motif obligatoire
    assert client.post(f"/api/comites/dossiers/{dos['d1']}/vote", json=v, headers=h("agent1")).status_code == 201
    # secret du vote : l'autre membre ne voit pas le vote d'agent1 avant la décision
    detail = client.get(f"/api/comites/seances/{sid}", headers=h("caissier1")).json()
    d1 = next(x for x in detail["dossiers"] if x["id"] == dos["d1"])
    assert d1["nb_votes"] == 1 and d1["votes"] == []
    assert client.post(f"/api/comites/dossiers/{dos['d1']}/decider", json={"motif": "Accord à la majorité des membres"}, headers=h("agent1")).status_code == 403
    assert client.post(f"/api/comites/dossiers/{dos['d1']}/decider", json={"motif": "Accord à la majorité des membres"}, headers=h("chef1")).status_code == 422   # tous n'ont pas voté
    for login in ("chef1", "caissier1"):
        assert client.post(f"/api/comites/dossiers/{dos['d1']}/vote", json=v, headers=h(login)).status_code == 201
    r = client.post(f"/api/comites/dossiers/{dos['d1']}/decider", json={"motif": "Accord unanime des membres présents", "montant_accorde": 250000, "conditions": "Garantie à constituer"}, headers=h("caissier1"))
    assert r.status_code == 200, r.text
    assert r.json()["decision_calculee"] == "acceptation" and r.json()["montant_accorde"] == 250000
    dem = client.get(f"/api/demandes-credit/{d['d1']['id']}", headers=h("chef1")).json()
    assert dem["statut"] == "approuvee" and dem["montant"] == 250000
    # après décision, les votes sont publics dans le dossier
    d1 = next(x for x in client.get(f"/api/comites/seances/{sid}", headers=h("agent1")).json()["dossiers"] if x["id"] == dos["d1"])
    assert len(d1["votes"]) == 3 and d1["decision"] == "acceptation"

    # D2 : visite obligatoire (800 000), puis rejet à la majorité
    for login in ("chef1", "caissier1", "agent1"):
        assert client.post(f"/api/comites/dossiers/{dos['d2']}/vote", json={"vote": "rejet", "motif": "Garantie insuffisante pour ce montant"}, headers=h(login)).status_code == 201
    dec = {"motif": "Rejet : garantie insuffisante pour le montant"}
    assert client.post(f"/api/comites/dossiers/{dos['d2']}/decider", json=dec, headers=h("chef1")).status_code == 422       # visite préalable manquante
    assert client.patch(f"/api/comites/dossiers/{dos['d2']}", json={"visite_le": dt.date.today().isoformat()}, headers=h("chef1")).status_code == 422   # personne manquante
    assert client.patch(f"/api/comites/dossiers/{dos['d2']}", json={"visite_le": dt.date.today().isoformat(), "visite_par": u["agent1"]}, headers=h("chef1")).status_code == 200
    assert client.post(f"/api/comites/dossiers/{dos['d2']}/decider", json=dec, headers=h("chef1")).json()["decision_calculee"] == "rejet"
    assert client.get(f"/api/demandes-credit/{d['d2']['id']}", headers=h("chef1")).json()["statut"] == "refusee"

    # D4 : ajournement (récusation d'agent1 + deux avis opposés)
    assert client.post(f"/api/comites/dossiers/{dos['d4']}/recusation", json={"motif": "Parent du demandeur"}, headers=h("agent1")).status_code == 201
    assert client.post(f"/api/comites/dossiers/{dos['d4']}/vote", json={"vote": "acceptation", "motif": "Plutôt favorable"}, headers=h("agent1")).status_code == 422     # récusé
    assert client.post(f"/api/comites/dossiers/{dos['d4']}/vote", json={"vote": "ajournement", "motif": "Pièces à compléter"}, headers=h("chef1")).status_code == 201
    assert client.post(f"/api/comites/dossiers/{dos['d4']}/vote", json={"vote": "acceptation", "motif": "Plutôt favorable"}, headers=h("caissier1")).status_code == 201
    r = client.post(f"/api/comites/dossiers/{dos['d4']}/decider", json={"motif": "Ajourné : pièces à compléter avant décision"}, headers=h("chef1"))
    assert r.status_code == 200 and r.json()["decision_calculee"] == "ajournement"
    assert client.get(f"/api/demandes-credit/{d['d4']['id']}", headers=h("chef1")).json()["statut"] == "demandee"        # reste en attente


def test_proces_verbal_signature_et_figement(client, h, base, comite, seance):
    sid = seance["id"]
    assert client.post(f"/api/comites/seances/{sid}/cloturer", headers=h("chef1")).status_code == 422                     # non signé
    assert client.post(f"/api/comites/seances/{sid}/signer", headers=h("agent1")).status_code == 422                      # simple membre
    assert client.post(f"/api/comites/seances/{sid}/signer", headers=h("chef1")).json()["signe_en_tant_que"] == "president"
    assert client.post(f"/api/comites/seances/{sid}/signer", headers=h("caissier1")).json()["signe_en_tant_que"] == "secretaire"
    cl = client.post(f"/api/comites/seances/{sid}/cloturer", headers=h("chef1"))
    assert cl.status_code == 200 and cl.json()["statut"] == "close"
    pv = client.get(f"/api/comites/seances/{sid}/pv", headers=h("agent1")).json()
    assert pv["institution"]["raison_sociale"] == "Caisse Comité Test" and pv["agence"]["code"] == "T1"
    assert pv["signataires"]["president"] and pv["signataires"]["secretaire"] and pv["pv_signe_president"] and pv["pv_signe_secretaire"]
    assert {x["decision"] for x in pv["dossiers"]} == {"acceptation", "rejet", "ajournement"}
    assert pv["analyse_globale"]["nb_acceptes"] == 1 and pv["analyse_globale"]["nb_rejetes"] == 1 and pv["analyse_globale"]["nb_ajournes"] == 1
    assert all(len(x["votes"]) >= 2 for x in pv["dossiers"])
    # tout est figé
    assert client.patch(f"/api/comites/seances/{sid}", json={"lieu": "Ailleurs"}, headers=h("chef1")).status_code == 422
    assert client.post(f"/api/comites/dossiers/{seance['dos']['d1']}/vote", json={"vote": "rejet", "motif": "Changement d'avis"}, headers=h("agent1")).status_code == 422
    hist = client.get(f"/api/comites/demandes/{base['demandes']['d4']['id']}/historique", headers=h("chef1")).json()
    assert len(hist) == 1 and hist[0]["decision"] == "ajournement"
    # le dossier ajourné peut revenir devant une nouvelle séance
    nouvelle = client.post("/api/comites/seances", json={"comite_id": comite, "date_seance": (dt.datetime.now(dt.timezone.utc) + dt.timedelta(days=10)).isoformat()}, headers=h("chef1")).json()
    assert client.post(f"/api/comites/seances/{nouvelle['id']}/dossiers", json={"demande_id": base["demandes"]["d4"]["id"]}, headers=h("chef1")).status_code == 201
    assert client.post(f"/api/comites/seances/{nouvelle['id']}/annuler", json={"motif": "Report"}, headers=h("chef1")).json()["statut"] == "annulee"
    assert client.get(f"/api/comites/seances/liste?statut=close", headers=h("chef1")).json()[0]["nb_dossiers"] == 3
    assert client.get(f"/api/comites/seances/liste", headers=h("chef2")).json() == []


def test_comite_obligatoire_et_delegations(client, h, sql, base):
    d = base["demandes"]
    # par défaut : l'ancienne décision directe fonctionne
    sql("DELETE FROM parametre WHERE cle = 'comite_credit_obligatoire' AND agence_id IS NOT NULL")
    ok = client.post(f"/api/demandes-credit/{d['d5']['id']}/decision", json={"approuve": True, "commentaire": "Direct"}, headers=h("chef1"))
    assert ok.status_code == 200 and ok.json()["statut"] == "approuvee"
    # mode comité obligatoire pour l'agence T1
    sql("INSERT INTO parametre(cle, valeur, agence_id, description) VALUES ('comite_credit_obligatoire', '1', %s, 'test')", (base["a1"],))
    refus = client.post(f"/api/demandes-credit/{d['d6']['id']}/decision", json={"approuve": True}, headers=h("chef1"))
    assert refus.status_code == 422 and "comité de crédit" in refus.json()["detail"]
    # délégation : le chef d'agence peut décider seul jusqu'à 250 000 par crédit, 400 000 par mois
    corps = {"utilisateur_id": base["u"]["chef1"], "montant_max_credit": 250000, "montant_max_periode": 400000, "periode": "mois", "motif": "Délégation de la direction générale"}
    assert client.post("/api/comites/delegations", json=corps, headers=h("chef1")).status_code == 403                    # on ne s'auto-délègue pas (droit absent)
    assert client.post("/api/comites/delegations", json={**corps, "utilisateur_id": base["u"]["chef2"]}, headers=h("directeur")).status_code == 201
    g = client.post("/api/comites/delegations", json=corps, headers=h("directeur"))
    assert g.status_code == 201, g.text
    # D6 = 300 000 > 250 000 par crédit : toujours refusé ; une demande de 200 000 passe
    assert client.post(f"/api/demandes-credit/{d['d6']['id']}/decision", json={"approuve": True}, headers=h("chef1")).status_code == 422
    petite = client.post("/api/demandes-credit", json={"client_id": base["client"]["id"], "produit_id": d["d6"]["produit_id"], "montant": 200000, "nb_echeances": 6, "mode_remboursement": "especes"}, headers=h("chef1")).json()
    assert client.post(f"/api/demandes-credit/{petite['id']}/decision", json={"approuve": True}, headers=h("chef1")).status_code == 200
    # fin de délégation
    liste = client.get("/api/comites/delegations/liste", headers=h("chef1")).json()
    mienne = next(x for x in liste if x["id"] == g.json()["id"])
    assert mienne["active"] is True
    assert client.post(f"/api/comites/delegations/{mienne['id']}/terminer", headers=h("directeur")).status_code == 200
    autre = client.post("/api/demandes-credit", json={"client_id": base["client"]["id"], "produit_id": d["d6"]["produit_id"], "montant": 100000, "nb_echeances": 6, "mode_remboursement": "especes"}, headers=h("chef1")).json()
    assert client.post(f"/api/demandes-credit/{autre['id']}/decision", json={"approuve": True}, headers=h("chef1")).status_code == 422
