import datetime as dt

import pytest

# Module sous test : app/controles.py et ses points d'appel (retrait classique, retrait de tontine, déblocage de crédit,
# comptes dormants) — contrôles internes du guide : seuils par niveau, anti-fractionnement, séparation des tâches


@pytest.fixture(scope="module")
def base(client, h, produits, sql, agences):
    a1 = agences["a1"]
    res = {"a1": a1}
    for cle in ("A", "B", "C"):
        c = client.post("/api/clients", json={"nom": f"Client contrôle {cle}"}, headers=h("chef1")).json()
        cpt = client.post("/api/comptes-epargne", json={"client_id": c["id"], "produit_id": produits["CL"]}, headers=h("chef1"))
        assert cpt.status_code == 201, cpt.text
        res[cle] = {"client": c, "compte": cpt.json()}
        d = client.post(f"/api/comptes-epargne/{cpt.json()['id']}/depot", json={"montant": 3000000}, headers=h("chef1"))
        assert d.status_code == 201, d.text
    yield res
    sql("DELETE FROM parametre WHERE cle = 'separation_decaissement'")


def _retrait(client, h, login, cle, base, montant):
    return client.post(f"/api/comptes-epargne/{base[cle]['compte']['id']}/retrait", json={"montant": montant}, headers=h(login))


def test_seuil_par_niveau(client, h, base):
    r = _retrait(client, h, "caissier1", "A", base, 600000)
    assert r.status_code == 403 and "plafond de 500000" in r.json()["detail"]
    assert _retrait(client, h, "caissier1", "A", base, 400000).status_code == 201          # sous le plafond du caissier
    assert _retrait(client, h, "chef1", "A", base, 600000).status_code == 201              # le chef peut aller plus loin
    assert _retrait(client, h, "directeur", "A", base, 100000).status_code == 403          # le directeur n'a pas epargne:write : droits inchangés


def test_fractionnement_refuse_et_alerte(client, h, base, sql):
    avant = sql("SELECT count(*) AS n FROM alerte_securite WHERE type = 'retraits_fractionnes'")[0]["n"]
    assert _retrait(client, h, "caissier1", "B", base, 300000).status_code == 201
    r = _retrait(client, h, "caissier1", "B", base, 300000)               # 300 000 + 300 000 > 500 000, chacun sous le plafond
    assert r.status_code == 403 and "Fractionnement" in r.json()["detail"]
    assert sql("SELECT count(*) AS n FROM alerte_securite WHERE type = 'retraits_fractionnes'")[0]["n"] == avant + 1      # l'alerte survit au refus
    al = client.get("/api/securite/alertes", headers=h("auditeur")).json()
    assert any(a["type"] == "retraits_fractionnes" and a["gravite"] == "elevee" and a["utilisateur"] == "caissier1" for a in al)
    assert sql("SELECT count(*) AS n FROM mouvement_epargne WHERE compte_id = %s AND type = 'retrait'", (base["B"]["compte"]["id"],))[0]["n"] == 1
    assert _retrait(client, h, "chef1", "B", base, 300000).status_code == 201                # le chef traite le retrait


def test_compte_dormant(client, h, base, sql):
    cid = base["C"]["compte"]["id"]
    sql("UPDATE mouvement_epargne SET date_operation = current_date - 500 WHERE compte_id = %s", (cid,))
    liste = client.get("/api/comptes-epargne/dormants", headers=h("chef1")).json()
    assert any(c["compte_id"] == cid and c["jours_inactif"] >= 500 for c in liste)
    assert client.get("/api/comptes-epargne/dormants", headers=h("chef2")).json() == [] or all(c["compte_id"] != cid for c in client.get("/api/comptes-epargne/dormants", headers=h("chef2")).json())
    r = _retrait(client, h, "caissier1", "C", base, 10000)
    assert r.status_code == 403 and "dormant" in r.json()["detail"]
    assert _retrait(client, h, "chef1", "C", base, 10000).status_code == 201                # le chef autorise ; le compte n'est plus dormant
    assert all(c["compte_id"] != cid for c in client.get("/api/comptes-epargne/dormants", headers=h("chef1")).json())


def test_separation_approbation_decaissement(client, h, base, sql):
    a1 = base["a1"]
    p = client.post("/api/produits-credit", json={"code": "PSEP", "libelle": "Crédit séparation", "type": "sans_epargne", "taux_annuel": 0.18}, headers=h("chef1")).json()
    caisse = client.post("/api/caisses", json={"code": "CP-SEP"}, headers=h("chef1")).json()
    session = client.post(f"/api/caisses/{caisse['id']}/sessions", json={"date_session": dt.date.today().isoformat(), "solde_ouverture": 5000000}, headers=h("caissier1"))
    assert session.status_code == 201, session.text
    sid = session.json()["id"]
    d = client.post("/api/demandes-credit", json={"client_id": base["A"]["client"]["id"], "produit_id": p["id"], "montant": 100000, "nb_echeances": 6, "mode_remboursement": "especes"}, headers=h("chef1")).json()
    assert client.post(f"/api/demandes-credit/{d['id']}/decision", json={"approuve": True}, headers=h("chef1")).status_code == 200
    sql("INSERT INTO parametre(cle, valeur, agence_id, description) VALUES ('separation_decaissement', '1', %s, 'test')", (a1,))
    r = client.post(f"/api/demandes-credit/{d['id']}/debloquer", json={"mode": "especes", "session_id": sid}, headers=h("chef1"))
    assert r.status_code == 403 and "Séparation des tâches" in r.json()["detail"]
    ok = client.post(f"/api/demandes-credit/{d['id']}/debloquer", json={"mode": "especes", "session_id": sid}, headers=h("caissier1"))
    assert ok.status_code == 201, ok.text
