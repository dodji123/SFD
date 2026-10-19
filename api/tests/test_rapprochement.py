import datetime as dt

import pytest

from tests.helpers import PWD, make_user

# Module sous test : routers/rapprochement.py (rapprochement fiches / comptabilité, validation, historique, signalement au consolidé)

DATE = "2025-12-31"


@pytest.fixture(scope="module")
def agence5(client, h, sql):
    """Agence neuve : un crédit sain de 100000 en fiches, aucune écriture comptable au départ."""
    a = sql("INSERT INTO agence(code, libelle) VALUES ('T5', 'Agence test 5') RETURNING id")[0]["id"]
    make_user(sql, "chef5", "chef_agence", a)
    if not sql("SELECT 1 FROM exercice_comptable WHERE %s BETWEEN date_debut AND date_fin", (dt.date.fromisoformat(DATE),)):
        assert client.post("/api/compta/exercices", json={"code": "2025", "date_debut": "2025-01-01", "date_fin": "2025-12-31"}, headers=h("comptable")).status_code == 201
    cid = sql("INSERT INTO client(agence_id, nom) VALUES (%s, 'Rapp Client') RETURNING id", (a,))[0]["id"]
    crid = sql("INSERT INTO credit(agence_id, numero, client_id, type, montant_accorde, taux, date_deblocage, nb_echeances, mode_remboursement) "
               "VALUES (%s, 'RAPP-1', %s, 'sans_epargne', 100000, 0.12, '2025-12-01', 12, 'especes') RETURNING id", (a, cid))[0]["id"]
    sql("SELECT generer_echeancier(%s)", (crid,))
    return a


def _hdr(client, login):
    return {"Authorization": "Bearer " + client.post("/api/auth/login", json={"login": login, "mot_de_passe": PWD}).json()["access_token"]}


def test_ecart_puis_validation_justifiee(client, h, agence5):
    p = {"date": DATE, "agence_id": agence5}
    r = client.get("/api/rapprochement", params=p, headers=h("comptable"))
    assert r.status_code == 200, r.text
    d = r.json()
    sains = next(x for x in d["lignes"] if x["code"] == "credits_sains")
    assert (sains["inventaire"], sains["comptabilite"], sains["ecart"], sains["conforme"]) == (100000, 0, 100000, False)
    assert d["tous_conformes"] is False and d["ecart_total"] == 100000 and d["validation"]["validee"] is False
    # droits
    assert client.post("/api/rapprochement/valider", json={"date": DATE, "agence_id": agence5, "justification": "x"}, headers=_hdr(client, "chef5")).status_code == 403
    assert client.get("/api/rapprochement", params=p, headers=h("caissier1")).status_code == 403
    # une justification est obligatoire en cas d'écart
    assert client.post("/api/rapprochement/valider", json={"date": DATE, "agence_id": agence5}, headers=h("comptable")).status_code == 422
    ok = client.post("/api/rapprochement/valider", json={"date": DATE, "agence_id": agence5, "justification": "écritures de décaissement à passer"}, headers=h("comptable"))
    assert ok.status_code == 201, ok.text
    assert ok.json()["validation"]["validee"] is True and ok.json()["validation"]["statut"] == "ecart_justifie"


def test_conforme_apres_ecritures(client, h, agence5, sql):
    def ac(prefixe):
        return sql("SELECT min(code) AS c FROM compte_comptable WHERE code LIKE %s AND imputable", (prefixe + "%",))[0]["c"]

    r = client.post("/api/compta/pieces", json={"agence_id": agence5, "journal": "OD", "date_piece": "2025-12-01", "libelle": "Décaissement",
                                                "lignes": [{"compte_code": ac("20221"), "debit": 100000}, {"compte_code": ac("1011"), "credit": 100000}]}, headers=h("comptable"))
    assert r.status_code == 201, r.text
    p = {"date": DATE, "agence_id": agence5}
    d = client.get("/api/rapprochement", params=p, headers=h("comptable")).json()
    assert d["tous_conformes"] is True and d["ecart_total"] == 0
    ok = client.post("/api/rapprochement/valider", json={"date": DATE, "agence_id": agence5}, headers=h("comptable"))
    assert ok.status_code == 201 and ok.json()["validation"]["statut"] == "conforme"
    hist = client.get("/api/rapprochement/historique", params={"agence_id": agence5}, headers=h("comptable")).json()
    assert [x["statut"] for x in hist] == ["conforme", "ecart_justifie"] and hist[1]["justification"].startswith("écritures") and hist[0]["valide_par"] == "comptable"


def test_perimetre_et_signalement_au_consolide(client, h, agence5):
    assert client.get("/api/rapprochement", params={"date": DATE}, headers=_hdr(client, "chef5")).status_code == 200            # son agence
    assert client.get("/api/rapprochement", params={"date": DATE, "agence_id": 1}, headers=_hdr(client, "chef5")).status_code == 403
    assert client.get("/api/rapprochement", params={"date": DATE}, headers=h("comptable")).status_code == 400                    # le siège désigne l'agence
    assert client.get("/api/rapprochement", params={"date": DATE, "consolide": "true"}, headers=_hdr(client, "chef5")).status_code == 403
    cons = client.get("/api/rapprochement", params={"date": DATE, "consolide": "true"}, headers=h("auditeur")).json()
    assert cons["consolide"] is True and {a["agence"]: a["validee"] for a in cons["agences"]}["T5"] is True
    # les états consolidés signalent les agences dont le rapprochement n'est pas validé (les autres agences de test ne le sont pas)
    e = client.get("/api/etats/consolide", params={"du": "2025-01-01", "au": DATE}, headers=h("comptable")).json()
    assert "T5" not in e["rapprochement"]["agences_non_validees"] and e["rapprochement"]["toutes_validees"] is False
    assert len(e["rapprochement"]["agences_non_validees"]) >= 1
