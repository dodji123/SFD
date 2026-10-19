import pytest

from tests.helpers import PWD, make_user


@pytest.fixture(scope="module")
def agence3(client, h, sql):
    """Agence T3 avec cinq crédits au profil de retard connu (mêmes données que le test SQL du module 14)."""
    a3 = sql("INSERT INTO agence(code, libelle) VALUES ('T9', 'Agence test 9') RETURNING id")[0]["id"]
    make_user(sql, "chef3", "chef_agence", a3)
    sql("INSERT INTO zone(agence_id, code, libelle) VALUES (%s, 'Z', 'Zone')", (a3,))
    clients = [sql("INSERT INTO client(agence_id, numero, nom) VALUES (%s, %s, %s) RETURNING id", (a3, f"C{i}", f"Client {i}"))[0]["id"] for i in range(1, 6)]
    spec = [("CR-A", 30000, "2026-09-01", 3), ("CR-B", 30000, "2026-09-01", 3), ("CR-C", 20000, "2026-06-01", 2),
            ("CR-D", 10000, "2026-10-20", 1), ("CR-E", 10000, "2026-09-15", 1)]
    for (num, mt, dep, n), cid in zip(spec, clients):
        cr = sql("INSERT INTO credit(agence_id, numero, client_id, type, montant_accorde, taux, date_deblocage, nb_echeances, mode_remboursement) "
                 "VALUES (%s, %s, %s, 'sans_epargne', %s, 0.12, %s, %s, 'especes') RETURNING id", (a3, num, cid, mt, dep, n))[0]["id"]
        sql("SELECT generer_echeancier(%s)", (cr,))

    def pay(numero, no, montant, jour, source):
        sql("SELECT imputer_echeance((SELECT e.id FROM echeance e JOIN credit c ON c.id = e.credit_id WHERE c.numero = %s AND c.agence_id = %s AND e.no_echeance = %s), %s, %s, %s)",
            (numero, a3, no, montant, jour, source))

    pay("CR-B", 1, 10300, "2026-10-01", "especes")
    pay("CR-B", 2, 10200, "2026-10-31", "prelevement")
    pay("CR-E", 1, 10100, "2026-10-15", "especes")
    return a3


def test_portefeuille_et_par(client, h, agence3):
    r = client.get("/api/rapports/credits/portefeuille", params={"date": "2026-11-05"}, headers=_hdr(client, "chef3"))
    assert r.status_code == 200, r.text
    d = r.json()
    ind = d["indicateurs"]
    assert ind["credits_actifs"] == 4 and ind["encours_capital"] == 70000 and ind["credits_en_retard"] == 2
    assert (ind["par_1_jour"], ind["par_30_jours"], ind["par_60_jours"], ind["par_90_jours"]) == (50000, 50000, 20000, 20000)
    assert ind["par_30_jours_pct"] == 71.43 and ind["par_90_jours_pct"] == 28.57 and ind["impaye_capital_interets"] == 40800
    assert [(t["tranche"], t["nb_credits"], t["capital_restant"]) for t in d["tranches"]] == [
        ("À jour", 2, 20000), ("1 à 30 jours", 0, 0), ("31 à 60 jours", 1, 30000), ("61 à 90 jours", 0, 0), ("91 à 180 jours", 1, 20000), ("Plus de 180 jours", 0, 0)]
    assert d["repartition"]["type"][0]["cle"] == "sans_epargne" and d["repartition"]["type"][0]["encours"] == 70000


def _hdr(client, login):
    r = client.post("/api/auth/login", json={"login": login, "mot_de_passe": PWD})
    return {"Authorization": "Bearer " + r.json()["access_token"]}


def test_credits_en_retard(client, h, agence3):
    hd = _hdr(client, "chef3")
    r = client.get("/api/rapports/credits/retards", params={"date": "2026-11-05"}, headers=hd).json()
    assert [(x["numero"], x["jours_retard"], x["montant_en_retard"]) for x in r] == [("CR-C", 127, 20300), ("CR-A", 35, 20500)]
    # reproductible : une date antérieure donne un autre état
    r = client.get("/api/rapports/credits/retards", params={"date": "2026-10-10"}, headers=hd).json()
    assert [(x["numero"], x["jours_retard"]) for x in r] == [("CR-C", 101), ("CR-A", 9)]


def test_activite_de_la_periode(client, agence3):
    r = client.get("/api/rapports/credits/periode", params={"du": "2026-10-01", "au": "2026-10-31"}, headers=_hdr(client, "chef3"))
    assert r.status_code == 200
    v = r.json()["rubriques"]
    assert v["credits_debloques_nb"] == 1 and v["credits_debloques_montant"] == 10000
    assert v["remboursements_capital"] == 30000 and v["remboursements_interets"] == 600
    assert v["remboursements_en_especes"] == 20400 and v["remboursements_par_prelevement"] == 10200
    assert v["credits_soldes"] == 1 and v["taux_recouvrement_pct"] == 59.9


def test_rapport_financier(client, agence3):
    hd = _hdr(client, "chef3")
    r = client.get("/api/rapports/financier", params={"du": "2026-10-01", "au": "2026-10-31"}, headers=hd)
    assert r.status_code == 200
    lignes = {l["rubrique"]: l for l in r.json()["lignes"]}
    assert lignes["interets_credits"]["valeur"] == 600 and lignes["interets_credits"]["section"] == "produit"
    assert lignes["total_produits"]["valeur"] == 600 and lignes["resultat"]["valeur"] == 600
    assert lignes["encours_credits"]["valeur"] == 70000
    # une autre période sans activité
    vide = {l["rubrique"]: l["valeur"] for l in client.get("/api/rapports/financier", params={"du": "2020-01-01", "au": "2020-01-31"}, headers=hd).json()["lignes"]}
    assert vide["resultat"] == 0


def test_droits_et_cloisonnement(client, h, agence3, agences):
    p = {"date": "2026-11-05"}
    assert client.get("/api/rapports/credits/portefeuille", params=p, headers=h("agent1")).status_code == 403
    assert client.get("/api/rapports/credits/portefeuille", params=p, headers=h("admin")).status_code == 400              # le siège désigne l'agence
    assert client.get("/api/rapports/credits/portefeuille", params={**p, "agence_id": agence3}, headers=h("auditeur")).status_code == 200
    assert client.get("/api/rapports/credits/portefeuille", params={**p, "agence_id": agence3}, headers=h("chef1")).status_code == 403
    # chef1 obtient les chiffres de SON agence, jamais ceux de l'agence 3 (les crédits de l'agence 3 sont au nombre de 4 actifs, 70000 d'encours)
    r1 = client.get("/api/rapports/credits/portefeuille", params=p, headers=h("chef1")).json()
    assert r1["agence_id"] == agences["a1"] and not (r1["indicateurs"]["credits_actifs"] == 4 and r1["indicateurs"]["encours_capital"] == 70000)
    assert client.get("/api/rapports/financier", params={"du": "2026-10-01"}, headers=h("chef1")).status_code == 422


def test_bilan_simplifie(client, h, agence3):
    """Exercice 2032 : quatre pièces saisies par le comptable ; le bilan est équilibré."""
    assert client.post("/api/compta/exercices", json={"code": "2032", "date_debut": "2032-01-01", "date_fin": "2032-12-31"}, headers=h("comptable")).status_code == 201
    for libelle, d, c, m in (("Dépôts clients", "1011", "25111", 100000), ("Crédit débloqué", "202211", "1011", 30000),
                             ("Loyer", "6212", "1011", 5000), ("Intérêts perçus", "1011", "70212", 2000)):
        r = client.post("/api/compta/pieces", json={"agence_id": agence3, "journal": "OD", "date_piece": "2032-05-05", "libelle": libelle,
                                                    "lignes": [{"compte_code": d, "debit": m}, {"compte_code": c, "credit": m}]}, headers=h("comptable"))
        assert r.status_code == 201, r.text
    b = client.get("/api/compta/bilan", params={"au": "2032-12-31", "agence_id": agence3}, headers=h("comptable"))
    assert b.status_code == 200
    d = b.json()
    assert d["total_actif"] == d["total_passif"] == 100000
    assert {l["code"]: l["montant"] for l in d["actif"]} == {"10": 67000, "20": 30000, "RES": 3000}      # résultat négatif à l'actif
    assert {l["code"]: l["montant"] for l in d["passif"]} == {"25": 100000}
    assert client.get("/api/compta/bilan", params={"au": "2032-12-31", "agence_id": agence3}, headers=h("agent1")).status_code == 403
    assert client.get("/api/compta/bilan", params={"au": "2032-12-31", "agence_id": agence3}, headers=h("chef1")).status_code == 403
    avant = client.get("/api/compta/bilan", params={"au": "2031-12-31", "agence_id": agence3}, headers=h("comptable")).json()
    assert avant["actif"] == [] and avant["passif"] == []
