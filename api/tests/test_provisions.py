import datetime as dt

import pytest

from tests.helpers import PWD, make_user

# Module sous test : routers/provisions.py (classification, rapport, passage des écritures, paramètres de provisionnement)

DATE = "2035-06-30"


@pytest.fixture(scope="module")
def agence8(client, h, sql):
    """Agence neuve avec trois crédits de 100000 sans remboursement, en retard de 150, 270 et 800 jours au 30/06/2035."""
    a = sql("INSERT INTO agence(code, libelle) VALUES ('T8', 'Agence test 8') RETURNING id")[0]["id"]
    make_user(sql, "chef8", "chef_agence", a)
    assert client.post("/api/compta/exercices", json={"code": "2035", "date_debut": "2035-01-01", "date_fin": "2035-12-31"}, headers=h("comptable")).status_code == 201
    jour = dt.date.fromisoformat(DATE)
    for i, retard in enumerate((150, 270, 800), start=1):
        cid = sql("INSERT INTO client(agence_id, nom) VALUES (%s, %s) RETURNING id", (a, f"Prov Client {i}"))[0]["id"]
        crid = sql("INSERT INTO credit(agence_id, numero, client_id, type, montant_accorde, taux, date_deblocage, nb_echeances, mode_remboursement) "
                   "VALUES (%s, %s, %s, 'sans_epargne', 100000, 0.12, %s, 12, 'especes') RETURNING id", (a, f"PROV-{i}", cid, jour - dt.timedelta(days=retard + 30)))[0]["id"]
        sql("SELECT generer_echeancier(%s)", (crid,))
    return a


def _hdr(client, login):
    return {"Authorization": "Bearer " + client.post("/api/auth/login", json={"login": login, "mot_de_passe": PWD}).json()["access_token"]}


def test_classification_et_rapport(client, h, agence8):
    r = client.get("/api/provisions/classification", params={"date": DATE, "agence_id": agence8}, headers=h("comptable"))
    assert r.status_code == 200, r.text
    lignes = {x["numero"]: x for x in r.json()}
    assert [(x["classe"], x["provision_retenue"], x["compte_provision"]) for x in (lignes["PROV-1"], lignes["PROV-2"], lignes["PROV-3"])] == [
        ("3_6", 40000, "29912"), ("6_12", 80000, "2992"), ("irrecouvrable", 100000, "2993")]
    assert lignes["PROV-3"]["a_passer_en_perte"] is True and lignes["PROV-1"]["compte_encours"] == "2922"
    rap = client.get("/api/provisions/rapport", params={"date": DATE, "agence_id": agence8}, headers=h("comptable")).json()
    assert rap["total_requis"] == 220000 and rap["total_constitue"] == 0 and rap["a_doter"] == 220000 and rap["a_reprendre"] == 0
    assert rap["a_passer_en_perte"] == 100000 and len(rap["classes"]) == 6


def test_droits_et_perimetre(client, h, agence8):
    p = {"date": DATE, "agence_id": agence8}
    assert client.get("/api/provisions/rapport", params=p, headers=h("caissier1")).status_code == 403
    assert client.get("/api/provisions/rapport", params={"date": DATE}, headers=_hdr(client, "chef8")).status_code == 200
    assert client.get("/api/provisions/rapport", params={"date": DATE, "agence_id": 1}, headers=_hdr(client, "chef8")).status_code == 403
    assert client.get("/api/provisions/rapport", params={"date": DATE}, headers=h("comptable")).status_code == 400            # le siège désigne l'agence
    assert client.get("/api/provisions/rapport", params={"date": DATE, "consolide": "true"}, headers=_hdr(client, "chef8")).status_code == 403
    assert client.get("/api/provisions/rapport", params={"date": DATE, "consolide": "true"}, headers=h("auditeur")).status_code == 200
    assert client.post("/api/provisions/generer", params=p, headers=_hdr(client, "chef8")).status_code == 403                # seul le comptable passe les écritures


def test_passage_des_ecritures(client, h, agence8):
    p = {"date": DATE, "agence_id": agence8}
    r = client.post("/api/provisions/generer", params=p, headers=h("comptable"))
    assert r.status_code == 201, r.text
    assert r.json()["piece"]["montant"] == 220000
    assert client.post("/api/provisions/generer", params=p, headers=h("comptable")).status_code == 422                          # déjà passée ce jour
    rap = client.get("/api/provisions/rapport", params=p, headers=h("comptable")).json()
    assert rap["total_constitue"] == 220000 and rap["a_doter"] == 0 and rap["a_reprendre"] == 0
    # le lendemain, rien ne change : aucune pièce
    lendemain = {"date": "2035-07-01", "agence_id": agence8}
    r2 = client.post("/api/provisions/generer", params=lendemain, headers=h("comptable"))
    assert r2.status_code == 201 and r2.json()["piece"] is None
    # la pièce est visible en comptabilité et équilibrée
    pieces = client.get("/api/compta/pieces", params={"agence_id": agence8, "du": DATE, "au": DATE}, headers=h("comptable")).json()
    assert any(x["evenement"] == "provision_creances" and x["total"] == 220000 for x in pieces)


def test_parametres_provisionnement(client, h, agence8):
    avant = {x["cle"]: x["valeur"] for x in client.get("/api/provisions/parametres", headers=h("auditeur")).json()}
    assert avant["prov_taux_6m"] == "40" and avant["prov_jours_24m"] == "720"

    def put(cle, v, login="comptable"):
        return client.put(f"/api/provisions/parametres/{cle}", json={"valeur": v}, headers=h(login))

    def ligne(numero):
        return next(x for x in client.get("/api/provisions/classification", params={"date": DATE, "agence_id": agence8}, headers=h("comptable")).json() if x["numero"] == numero)

    assert put("prov_taux_6m", "50", "chef1").status_code == 403
    assert put("prov_taux_6m", "150").status_code == 422                               # taux hors de 0 à 100
    assert put("prov_taux_6m", "abc").status_code == 422
    assert put("prov_jours_6m", "50").status_code == 422                               # seuils non croissants : refusé et annulé
    assert next(x for x in client.get("/api/provisions/parametres", headers=h("auditeur")).json() if x["cle"] == "prov_jours_6m")["valeur"] == "180"
    assert put("prov_declasser_0_3m", "peut-être").status_code == 422
    assert put("inconnu", "1").status_code == 422
    # règle interne plus stricte : 60 % de 3 à 6 mois -> 60000 retenus au lieu de 40000
    assert put("prov_interne_3_6m", "60").status_code == 200
    x = ligne("PROV-1")
    assert (x["provision_reglementaire"], x["provision_interne"], x["provision_retenue"]) == (40000, 60000, 60000)
    assert client.delete("/api/provisions/parametres/prov_taux_6m", headers=h("comptable")).status_code == 422             # un taux réglementaire ne se supprime pas
    assert client.delete("/api/provisions/parametres/prov_interne_3_6m", headers=h("comptable")).status_code == 200
    x = ligne("PROV-1")
    assert x["provision_interne"] is None and x["provision_retenue"] == 40000


def test_mode_manuel_ou_automatique(client, h, agence8):
    m = client.get("/api/provisions/mode", headers=h("auditeur")).json()
    assert m["mode"] == "manuel" and m["dernieres_executions"] == []
    assert client.put("/api/provisions/mode", json={"mode": "automatique"}, headers=h("chef1")).status_code == 403
    assert client.put("/api/provisions/mode", json={"mode": "n-importe-quoi"}, headers=h("comptable")).status_code == 422
    assert client.put("/api/provisions/mode", json={"mode": "automatique"}, headers=h("comptable")).json()["mode"] == "automatique"
    assert client.put("/api/provisions/mode", json={"mode": "manuel"}, headers=h("comptable")).json()["mode"] == "manuel"
    assert "prov_mode" not in [x["cle"] for x in client.get("/api/provisions/parametres", headers=h("auditeur")).json()]


def test_planificateur_passe_les_provisions_en_mode_automatique(client, h, sql):
    from app.planificateur import planifier

    jour = dt.date.today()
    a = sql("INSERT INTO agence(code, libelle) VALUES ('T6', 'Agence test 6') RETURNING id")[0]["id"]
    exo = sql("SELECT id, statut FROM exercice_comptable WHERE %s BETWEEN date_debut AND date_fin", (jour,))
    if not exo:
        sql("INSERT INTO exercice_comptable(code, date_debut, date_fin) VALUES (%s, %s, %s)", (f"AUTO{jour.year}", dt.date(jour.year, 1, 1), dt.date(jour.year, 12, 31)))
    rouvert = None
    if exo and exo[0]["statut"] != "ouvert":                 # un autre test a pu clôturer l'exercice du jour : on le rouvre le temps du test
        rouvert = exo[0]
        sql("UPDATE exercice_comptable SET statut = 'ouvert' WHERE id = %s", (rouvert["id"],))
    for i, retard in enumerate((150, 270), start=1):
        cid = sql("INSERT INTO client(agence_id, nom) VALUES (%s, %s) RETURNING id", (a, f"Auto Client {i}"))[0]["id"]
        crid = sql("INSERT INTO credit(agence_id, numero, client_id, type, montant_accorde, taux, date_deblocage, nb_echeances, mode_remboursement) "
                   "VALUES (%s, %s, %s, 'sans_epargne', 100000, 0.12, %s, 12, 'especes') RETURNING id", (a, f"AUTO-{i}", cid, jour - dt.timedelta(days=retard + 30)))[0]["id"]
        sql("SELECT generer_echeancier(%s)", (crid,))

    def provisions_du_jour():
        return sql("SELECT count(*) AS n FROM piece_comptable WHERE agence_id = %s AND date_piece = %s AND evenement = 'provision_creances'", (a, jour))[0]["n"]

    # mode manuel : le planificateur ne passe rien
    planifier(agence_code="T6")
    assert provisions_du_jour() == 0
    # mode automatique : la pièce est passée par la tâche du jour, une seule fois
    sql("UPDATE parametre SET valeur = 'automatique' WHERE cle = 'prov_mode' AND agence_id IS NULL")
    try:
        res = [r for r in planifier(agence_code="T6", forcer=True) if r.tache == "generer_provisions_auto"]
        assert [(r.statut, r.nb) for r in res] == [("ok", 1)]
        assert provisions_du_jour() == 1
        res = [r for r in planifier(agence_code="T6") if r.tache == "generer_provisions_auto"]
        assert [r.statut for r in res] == ["deja_fait"]                       # rejeu sans doublon
        assert provisions_du_jour() == 1
        # l'écran du mode montre l'exécution
        m = client.get("/api/provisions/mode", params={"agence_id": a}, headers=h("comptable")).json()
        assert m["dernieres_executions"][0]["statut"] == "ok" and m["dernieres_executions"][0]["agence"] == "T6"
        rap = client.get("/api/provisions/rapport", params={"date": str(jour), "agence_id": a}, headers=h("comptable")).json()
        assert rap["total_constitue"] == 120000 and rap["a_doter"] == 0         # 40 % de 100000 + 80 % de 100000
    finally:
        sql("UPDATE parametre SET valeur = 'manuel' WHERE cle = 'prov_mode' AND agence_id IS NULL")
        if rouvert:
            sql("UPDATE exercice_comptable SET statut = %s WHERE id = %s", (rouvert["statut"], rouvert["id"]))
