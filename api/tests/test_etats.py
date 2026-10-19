import pytest


def _soldes(client, h, ag):
    """Solde signé par compte de niveau 2 au 31/12/2033 (le bilan est cumulé : d'autres tests ont pu écrire avant)."""
    b = client.get("/api/etats/agence", params={**{"du": "2033-01-01", "au": "2033-12-31"}, "agence_id": ag}, headers=h("comptable")).json()["bilan"]
    return {x["code"]: x["par_agence"][str(ag)] for x in b["actif"] + b["passif"]}


@pytest.fixture(scope="module")
def ecritures(client, h, agences):
    """Exercice 2033 ; agence 1 : dépôts 100000, loyer 5000, intérêts 2000 ; agence 2 : dépôts 50000, intérêts 3000.
    Retourne les soldes d'avant, pour comparer des écarts."""
    avant = {ag: _soldes(client, h, ag) for ag in agences.values()}
    assert client.post("/api/compta/exercices", json={"code": "2033", "date_debut": "2033-01-01", "date_fin": "2033-12-31"}, headers=h("comptable")).status_code == 201
    for ag, d, c, m, lib in ((agences["a1"], "1011", "25111", 100000, "Dépôts"), (agences["a1"], "6212", "1011", 5000, "Loyer"),
                             (agences["a1"], "1011", "70212", 2000, "Intérêts"), (agences["a2"], "1011", "25111", 50000, "Dépôts"),
                             (agences["a2"], "1011", "70212", 3000, "Intérêts")):
        r = client.post("/api/compta/pieces", json={"agence_id": ag, "journal": "OD", "date_piece": "2033-05-05", "libelle": lib,
                                                    "lignes": [{"compte_code": d, "debit": m}, {"compte_code": c, "credit": m}]}, headers=h("comptable"))
        assert r.status_code == 201, r.text
    return avant


P = {"du": "2033-01-01", "au": "2033-12-31"}


def test_etats_d_une_agence(client, h, agences, ecritures):
    r = client.get("/api/etats/agence", params=P, headers=h("chef1"))
    assert r.status_code == 200, r.text
    d = r.json()
    a = str(agences["a1"])
    assert d["agence"]["id"] == agences["a1"]
    cr = d["compte_resultat"]
    assert [(x["code"], x["total"]) for x in cr["produits"]] == [("70", 2000)] and [(x["code"], x["total"]) for x in cr["charges"]] == [("62", 5000)]
    assert cr["resultat"][a] == -3000 and cr["resultat"]["total"] == -3000
    b = d["bilan"]
    apres = {x["code"]: x["par_agence"][a] for x in b["actif"] + b["passif"]}
    av = ecritures[agences["a1"]]
    assert {c: apres.get(c, 0) - av.get(c, 0) for c in ("10", "25", "RES")} == {"10": 97000, "25": -100000, "RES": 3000}
    assert b["total_actif"] == b["total_passif"]


def test_cloisonnement_etats_agence(client, h, agences, ecritures):
    # le chef d'agence 2 voit son agence, jamais celle de l'agence 1
    assert client.get("/api/etats/agence", params={**P, "agence_id": agences["a1"]}, headers=h("chef2")).status_code == 403
    mine = client.get("/api/etats/agence", params=P, headers=h("chef2")).json()
    assert mine["agence"]["id"] == agences["a2"]
    assert mine["bilan"]["total_actif"] == mine["bilan"]["total_passif"]
    assert client.get("/api/etats/agence", params=P, headers=h("caissier1")).status_code == 403
    assert client.get("/api/etats/agence", params=P, headers=h("comptable")).status_code == 400            # le siège désigne l'agence
    assert client.get("/api/etats/agence", params={**P, "agence_id": agences["a2"]}, headers=h("comptable")).status_code == 200
    assert client.get("/api/etats/agence", params={"du": "2033-12-31", "au": "2033-01-01", "agence_id": agences["a1"]}, headers=h("comptable")).status_code == 422


def test_etats_consolides(client, h, agences, ecritures):
    r = client.get("/api/etats/consolide", params=P, headers=h("comptable"))
    assert r.status_code == 200, r.text
    d = r.json()
    a1, a2 = str(agences["a1"]), str(agences["a2"])
    produit = next(x for x in d["compte_resultat"]["produits"] if x["code"] == "70")
    assert produit["par_agence"][a1] == 2000 and produit["par_agence"][a2] == 3000 and produit["total"] == 5000
    assert d["compte_resultat"]["resultat"]["total"] == 0 and d["compte_resultat"]["resultat"][a1] == -3000 and d["compte_resultat"]["resultat"][a2] == 3000
    caisse = next(x for x in d["bilan"]["actif"] if x["code"] == "10")
    assert caisse["par_agence"][a1] - ecritures[agences["a1"]].get("10", 0) == 97000
    assert caisse["par_agence"][a2] - ecritures[agences["a2"]].get("10", 0) == 53000
    assert caisse["montant"] == sum(caisse["par_agence"].values())
    assert d["bilan"]["total_actif"] == d["bilan"]["total_passif"]
    assert d["controles"] == {"bilan_equilibre": True, "agences_equilibrees": True, "resultat_coherent": True}
    s = {x["agence"]: x for x in d["synthese"]}
    assert (s["T1"]["produits"], s["T1"]["charges"], s["T1"]["resultat"]) == (2000, 5000, -3000)
    assert d["consolide"]["resultat"] == 0 and d["consolide"]["produits"] == 5000


def test_consolide_reserve_au_siege(client, h, ecritures):
    assert client.get("/api/etats/consolide", params=P, headers=h("chef1")).status_code == 403          # droit absent
    assert client.get("/api/etats/consolide", params=P, headers=h("caissier1")).status_code == 403
    for login in ("admin", "directeur", "auditeur", "comptable"):
        assert client.get("/api/etats/consolide", params=P, headers=h(login)).status_code == 200
    assert client.get("/api/etats/consolide", params={"du": "2033-12-31", "au": "2033-01-01"}, headers=h("admin")).status_code == 422
