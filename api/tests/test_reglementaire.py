import pytest

from tests.helpers import PWD, make_user

# Module sous test : routers/reglementaire.py (bilan, résultat, hors-bilan par postes ; ratios prudentiels ; saisies et historique)


@pytest.fixture(scope="module")
def agence7(client, h, sql):
    """Agence neuve (aucune écriture ancienne) : capital 100000, dépôts 50000, crédit CT 30000, intérêts 3000 en 2034."""
    a = sql("INSERT INTO agence(code, libelle) VALUES ('T7', 'Agence test 7') RETURNING id")[0]["id"]
    make_user(sql, "chef7", "chef_agence", a)
    assert client.post("/api/compta/exercices", json={"code": "2034", "date_debut": "2034-01-01", "date_fin": "2034-12-31"}, headers=h("comptable")).status_code == 201
    def ac(prefixe):                       # premier compte imputable sous un préfixe du plan
        return sql("SELECT min(code) AS c FROM compte_comptable WHERE code LIKE %s AND imputable", (prefixe + "%",))[0]["c"]

    for d, c, m, lib in ((ac("1011"), ac("5711"), 100000, "Capital"), (ac("1011"), ac("25111"), 50000, "Dépôts"),
                         (ac("20221"), ac("1011"), 30000, "Crédit"), (ac("1011"), ac("70212"), 3000, "Intérêts")):
        r = client.post("/api/compta/pieces", json={"agence_id": a, "journal": "OD", "date_piece": "2034-05-05", "libelle": lib,
                                                    "lignes": [{"compte_code": d, "debit": m}, {"compte_code": c, "credit": m}]}, headers=h("comptable"))
        assert r.status_code == 201, r.text
    return a


def _hdr(client, login):
    return {"Authorization": "Bearer " + client.post("/api/auth/login", json={"login": login, "mot_de_passe": PWD}).json()["access_token"]}


P = {"au": "2034-12-31"}


def test_bilan_par_postes(client, h, agence7):
    r = client.get("/api/reglementaire/bilan", params={**P, "agence_id": agence7}, headers=h("comptable"))
    assert r.status_code == 200, r.text
    d = r.json()
    postes = {l["code"]: l["montant"] for l in d["actif"] + d["passif"]}
    assert postes["A10"] == 123000 and postes["B2D"] == 30000 and postes["G10"] == 50000 and postes["L60"] == 100000 and postes["L75"] == 3000
    assert d["total_actif"] == d["total_passif"] == 153000


def test_resultat_par_postes(client, h, agence7):
    r = client.get("/api/reglementaire/resultat", params={"du": "2034-01-01", "au": "2034-12-31", "agence_id": agence7}, headers=h("comptable")).json()
    produits = {l["code"]: l["montant"] for l in r["produits"]}
    assert produits["V3G"] == 3000 and produits["X84"] == 3000 and r["charges"] == []
    assert client.get("/api/reglementaire/resultat", params={"du": "2034-12-31", "au": "2034-01-01", "agence_id": agence7}, headers=h("comptable")).status_code == 422
    assert client.get("/api/reglementaire/hors-bilan", params={**P, "agence_id": agence7}, headers=h("comptable")).json()["lignes"] == []


def test_ratios_et_non_conformites(client, h, agence7):
    r = client.get("/api/reglementaire/ratios", params={"date": "2034-12-31", "agence_id": agence7}, headers=h("comptable"))
    assert r.status_code == 200, r.text
    d = r.json()
    par = {x["ratio"]: x for x in d["ratios"]}
    assert len(par) == 9 and d["fonds_propres"] == 103000
    assert par["I"]["valeur"] == 20.0 and par["I"]["conforme"] is True and par["I"]["norme_type"] == "max" and par["I"]["norme"] == 200
    assert par["II"]["saisies_manquantes"] == ["depots_mlt"]
    assert par["VII"]["conforme"] is False and "VII" in d["non_conformes"]          # pas de réserve générale pour un excédent de 3000
    # capitalisation : fonds propres moyens (103000 en 2034, 0 fin 2033) / total actif 153000 = 33,66 %
    assert par["VIII"]["valeur"] == 33.66 and par["VIII"]["conforme"] is True


def test_saisies_complementaires_et_droits(client, h, agence7):
    corps = {"code": "depots_mlt", "date_effet": "2034-01-01", "valeur": 40000, "commentaire": "DAT à 18 mois", "agence_id": agence7}
    assert client.post("/api/reglementaire/donnees", json=corps, headers=h("caissier1")).status_code == 403
    assert client.post("/api/reglementaire/donnees", json={**corps, "valeur": -1}, headers=h("comptable")).status_code == 422
    assert client.post("/api/reglementaire/donnees", json={**corps, "code": "inconnu"}, headers=h("comptable")).status_code == 422
    assert client.post("/api/reglementaire/donnees", json=corps, headers=h("comptable")).status_code == 201
    par = {x["ratio"]: x for x in client.get("/api/reglementaire/ratios", params={"date": "2034-12-31", "agence_id": agence7}, headers=h("comptable")).json()["ratios"]}
    # aucun emploi à moyen ou long terme dans cette agence : ratio non défini, mais le numérateur intègre la saisie (100000 + 40000)
    assert par["II"]["numerateur"] == 140000 and par["II"]["valeur"] is None and par["II"]["conforme"] is True and par["II"]["saisies_manquantes"] == []
    lst = client.get("/api/reglementaire/donnees", params={"agence_id": agence7}, headers=h("comptable")).json()
    assert lst[0]["code"] == "depots_mlt" and lst[0]["valeur"] == 40000 and lst[0]["saisi_par"] == "comptable"


def test_historique_et_cloisonnement(client, h, agence7):
    p = {"date": "2034-12-31", "agence_id": agence7}
    assert client.post("/api/reglementaire/ratios/enregistrer", params=p, headers=h("caissier1")).status_code == 403
    assert client.post("/api/reglementaire/ratios/enregistrer", params=p, headers=h("comptable")).json() == {"enregistres": 9}
    hist = client.get("/api/reglementaire/ratios/historique", params={"ratio": "I", "agence_id": agence7}, headers=h("comptable")).json()
    assert hist[0]["valeur"] == 20.0 and hist[0]["conforme"] is True
    assert client.get("/api/reglementaire/ratios/historique", params={"ratio": "X", "agence_id": agence7}, headers=h("comptable")).status_code == 422
    # le chef de l'agence 7 voit son agence ; une autre agence lui est interdite ; le siège doit désigner l'agence
    hc = _hdr(client, "chef7")
    assert client.get("/api/reglementaire/ratios", params={"date": "2034-12-31"}, headers=hc).status_code == 200
    assert client.get("/api/reglementaire/ratios", params={"date": "2034-12-31", "agence_id": 1}, headers=hc).status_code == 403
    assert client.get("/api/reglementaire/ratios", params={"date": "2034-12-31"}, headers=h("comptable")).status_code == 400
    assert client.get("/api/reglementaire/bilan", params={**P}, headers=h("agent1")).status_code == 403


def test_consolide_reserve_au_siege(client, h, agence7):
    p = {"date": "2034-12-31", "consolide": "true"}
    assert client.get("/api/reglementaire/ratios", params=p, headers=_hdr(client, "chef7")).status_code == 403
    assert client.get("/api/reglementaire/bilan", params={**P, "consolide": "true"}, headers=_hdr(client, "chef7")).status_code == 403
    for login in ("admin", "directeur", "comptable", "auditeur"):
        assert client.get("/api/reglementaire/ratios", params=p, headers=h(login)).status_code == 200
    b = client.get("/api/reglementaire/bilan", params={**P, "consolide": "true"}, headers=h("comptable")).json()
    assert b["consolide"] is True and b["total_actif"] == b["total_passif"]
    assert client.post("/api/reglementaire/ratios/enregistrer", params=p, headers=h("comptable")).json() == {"enregistres": 9}
    assert len(client.get("/api/reglementaire/ratios/historique", params={"ratio": "I", "consolide": "true"}, headers=h("auditeur")).json()) == 1


def test_hypotheses_parametrables_et_validation(client, h, agence7):
    d = client.get("/api/reglementaire/hypotheses", headers=h("auditeur")).json()
    par = {x["code"]: x for x in d["hypotheses"]}
    assert set(par) == {"depots_garantie_ratio_I", "compte_A2J", "signature_ratio_IV", "normes_a_jour"}
    assert par["compte_A2J"]["valeur"] == "II_et_V" and par["compte_A2J"]["validee"] is False and par["compte_A2J"]["valeurs"] == ["II_et_V", "II_seulement", "V_seulement"]
    assert {s["cle"] for s in d["seuils"]} >= {"ratio_norme_I", "ratio_norme_V_affilie", "type_institution_liquidite"}
    # droits : l'auditeur lit, seuls direction, comptable et administrateur modifient ou valident
    assert client.put("/api/reglementaire/hypotheses/compte_A2J", json={"valeur": "V_seulement"}, headers=h("auditeur")).status_code == 403
    assert client.post("/api/reglementaire/hypotheses/compte_A2J/valider", json={}, headers=h("chef1")).status_code == 403
    # modification, valeur refusée, validation puis chute de la validation
    assert client.put("/api/reglementaire/hypotheses/compte_A2J", json={"valeur": "n-importe-quoi"}, headers=h("comptable")).status_code == 422
    assert client.put("/api/reglementaire/hypotheses/compte_A2J", json={"valeur": "V_seulement"}, headers=h("comptable")).status_code == 200
    r = client.post("/api/reglementaire/hypotheses/compte_A2J/valider", json={"commentaire": "vu avec le commissaire aux comptes"}, headers=h("comptable"))
    assert r.status_code == 201
    a2j = {x["code"]: x for x in r.json()["hypotheses"]}["compte_A2J"]
    assert a2j["validee"] is True and a2j["validee_par_login"] == "comptable" and a2j["commentaire"].startswith("vu avec")
    after = client.put("/api/reglementaire/hypotheses/compte_A2J", json={"valeur": "II_et_V"}, headers=h("comptable")).json()
    retour = {x["code"]: x for x in after["hypotheses"]}["compte_A2J"]
    assert retour["valeur"] == "II_et_V" and retour["validee"] is False                                  # cette valeur n'a jamais été validée
    assert client.put("/api/reglementaire/hypotheses/inconnue", json={"valeur": "oui"}, headers=h("comptable")).status_code == 422


def test_seuils_modifiables(client, h, agence7):
    avant = {s["cle"]: s["valeur"] for s in client.get("/api/reglementaire/hypotheses", headers=h("comptable")).json()["seuils"]}
    assert client.put("/api/reglementaire/seuils/ratio_norme_IX", json={"valeur": "20"}, headers=h("chef1")).status_code == 403
    assert client.put("/api/reglementaire/seuils/ratio_norme_IX", json={"valeur": "abc"}, headers=h("comptable")).status_code == 422
    assert client.put("/api/reglementaire/seuils/ratio_norme_IX", json={"valeur": "0"}, headers=h("comptable")).status_code == 422
    assert client.put("/api/reglementaire/seuils/taux_commission", json={"valeur": "5"}, headers=h("comptable")).status_code == 422
    assert client.put("/api/reglementaire/seuils/type_institution_liquidite", json={"valeur": "inconnu"}, headers=h("comptable")).status_code == 422
    assert client.put("/api/reglementaire/seuils/ratio_norme_IX", json={"valeur": "20,5"}, headers=h("comptable")).status_code == 200
    par = {x["ratio"]: x for x in client.get("/api/reglementaire/ratios", params={"date": "2034-12-31", "agence_id": agence7}, headers=h("comptable")).json()["ratios"]}
    assert par["IX"]["norme"] == 20.5
    assert client.put("/api/reglementaire/seuils/type_institution_liquidite", json={"valeur": "affilie"}, headers=h("comptable")).status_code == 200
    par = {x["ratio"]: x for x in client.get("/api/reglementaire/ratios", params={"date": "2034-12-31", "agence_id": agence7}, headers=h("comptable")).json()["ratios"]}
    assert par["V"]["norme"] == 80
    # retour aux valeurs d'origine (la base de test est partagée entre les fichiers)
    client.put("/api/reglementaire/seuils/ratio_norme_IX", json={"valeur": avant["ratio_norme_IX"]}, headers=h("comptable"))
    client.put("/api/reglementaire/seuils/type_institution_liquidite", json={"valeur": avant["type_institution_liquidite"]}, headers=h("comptable"))
