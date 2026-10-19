import datetime as dt

import pytest

from tests.helpers import make_user


@pytest.fixture(scope="module")
def base(client, h, agences, produits):
    z = client.post("/api/zones", json={"code": "ZP", "libelle": "Zone rapports"}, headers=h("chef1")).json()
    ag = client.post("/api/agents", json={"matricule": "P-A1", "nom": "Agent P"}, headers=h("chef1")).json()
    cl = client.post("/api/clients", json={"nom": "Cli Rapport", "zone_id": z["id"]}, headers=h("chef1")).json()
    k = client.post("/api/collectrices", json={"matricule": "P-K1", "nom": "Collectrice P"}, headers=h("chef1")).json()
    client.post(f"/api/zones/{z['id']}/affectations", json={"collectrice_id": k["id"], "date_debut": "2020-01-01"}, headers=h("chef1"))
    cy = client.post("/api/cycles", json={"client_id": cl["id"], "produit_id": produits["P1"], "mise": 1000,
                                          "date_debut": "2030-05-01", "date_fin": "2030-05-31"}, headers=h("chef1")).json()
    lignes = [{"date_collecte": str(dt.date(2030, 5, 5) + dt.timedelta(days=i)), "montant_collecte": 1000, "agent_id": ag["id"]} for i in range(3)]
    client.post(f"/api/cycles/{cy['id']}/lignes", json={"lignes": lignes}, headers=h("chef1"))
    return {"z": z, "ag": ag, "cl": cl, "k": k, "cy": cy}


# ------------------------------------------------------------------ rapports
def test_rapport_journalier_global_agents_zones(client, h, base, agences):
    r = client.get("/api/rapports/journalier", params={"date": "2030-05-05"}, headers=h("chef1"))
    assert r.status_code == 200
    rub = {x["rubrique"]: x["valeur"] for x in r.json()["rubriques"]}
    assert rub["collecte_montant"] == 1000 and rub["collecte_nb_lignes"] == 1 and rub["mises_collectees"] == 1000
    ag = client.get("/api/rapports/journalier/agents", params={"date": "2030-05-06"}, headers=h("chef1")).json()
    assert [(a["agent"], a["montant_collecte"]) for a in ag if a["montant_collecte"]] == [("Agent P", 1000)]
    z = client.get("/api/rapports/journalier/zones", params={"date": "2030-05-07"}, headers=h("chef1")).json()
    zp = [x for x in z if x["zone"] == "ZP"][0]
    assert (zp["collectrice"], zp["montant_collecte"], zp["nb_lignes"]) == ("Collectrice P", 1000, 1)


def test_rapport_reproductible_apres_operations_ulterieures(client, h, base):
    avant = client.get("/api/rapports/journalier", params={"date": "2030-05-05"}, headers=h("chef1")).json()["rubriques"]
    # on clôture et on retire le cycle bien après : le rapport du 05/05 ne change pas
    client.post(f"/api/cycles/{base['cy']['id']}/cloturer", json={"date": "2030-06-10"}, headers=h("chef1"))
    rid = client.post(f"/api/cycles/{base['cy']['id']}/retrait", json={"nature": "retrait_client"}, headers=h("chef1")).json()["id"]
    client.post(f"/api/retraits/{rid}/constat-sans-ecart", headers=h("chef1"))
    apres = client.get("/api/rapports/journalier", params={"date": "2030-05-05"}, headers=h("chef1")).json()["rubriques"]
    assert avant == apres


def test_rapports_droits_et_cloisonnement(client, h, agences):
    assert client.get("/api/rapports/journalier", params={"date": "2030-05-05"}, headers=h("agent1")).status_code == 403
    assert client.get("/api/rapports/journalier", params={"date": "2030-05-05"}, headers=h("admin")).status_code == 400
    assert client.get("/api/rapports/journalier", params={"date": "2030-05-05", "agence_id": agences["a1"]}, headers=h("auditeur")).status_code == 200
    r = client.get("/api/rapports/journalier", params={"date": "2030-05-05"}, headers=h("chef2")).json()
    assert {x["rubrique"]: x["valeur"] for x in r["rubriques"]}["collecte_montant"] == 0
    assert client.get("/api/rapports/journalier", params={"date": "pas-une-date"}, headers=h("chef1")).status_code == 422
    for chemin in ("echus", "a-venir", "situation"):
        assert client.get(f"/api/rapports/credits/{chemin}", params={"date": "2030-05-05"}, headers=h("chef1")).status_code == 200
    assert client.get("/api/rapports/credits/a-venir", params={"date": "2030-05-05", "jours": 0}, headers=h("chef1")).status_code == 422


def test_tableau_de_bord_et_permissions(client, h, agences):
    t = client.get("/api/tableau-de-bord", params={"date": "2030-05-05"}, headers=h("caissier1")).json()
    assert t["collecte_du_jour"] == 1000 and t["cycles_en_cours"] >= 0 and set(t) >= {"credits_en_retard", "retraits_a_traiter", "sessions_ouvertes", "dettes_agents"}
    assert client.get("/api/tableau-de-bord", headers=h("admin")).status_code == 400
    assert client.get("/api/tableau-de-bord", params={"agence_id": agences["a2"]}, headers=h("chef2")).json()["collecte_du_jour"] == 0
    p = client.get("/api/moi/permissions", headers=h("caissier1")).json()
    assert p["role"] == "caissier" and "caisse:write" in p["permissions"] and "users:manage" not in p["permissions"]
    assert client.get("/api/moi/permissions").status_code == 401


# ------------------------------------------------------------------ paramètres et audit
def test_parametres(client, h, agences):
    p = {x["cle"]: x for x in client.get("/api/parametres", headers=h("admin")).json()}
    assert p["taux_commission"]["valeur"] == "0.02" and p["comptabilisation_auto"]["valeur"] == "non"
    assert client.put("/api/parametres/taux_commission", json={"valeur": "0.03", "agence_id": agences["a1"]}, headers=h("chef1")).status_code == 403
    r = client.put("/api/parametres/taux_commission", json={"valeur": "0.03", "agence_id": agences["a1"]}, headers=h("admin"))
    assert r.status_code == 200 and r.json()["valeur"] == "0.03" and r.json()["agence_id"] == agences["a1"]
    # la surcharge d'agence est effective pour l'agence 1, pas pour l'agence 2
    eff1 = {x["cle"]: x["valeur"] for x in client.get("/api/parametres", headers=h("chef1")).json()}
    eff2 = {x["cle"]: x["valeur"] for x in client.get("/api/parametres", headers=h("chef2")).json()}
    assert eff1["taux_commission"] == "0.03" and eff2["taux_commission"] == "0.02"
    assert client.put("/api/parametres/taux_commission", json={"valeur": "abc"}, headers=h("admin")).status_code == 422
    assert client.put("/api/parametres/comptabilisation_auto", json={"valeur": "peut-etre"}, headers=h("admin")).status_code == 422
    assert client.put("/api/parametres/inexistant", json={"valeur": "1"}, headers=h("admin")).status_code == 404
    assert client.get("/api/parametres", headers=h("caissier1")).status_code == 403


def test_piste_d_audit(client, h, agences):
    client.put("/api/parametres/penalite_taux", json={"valeur": "0.002"}, headers=h("admin"))
    rows = client.get("/api/audit", params={"table_name": "parametre", "utilisateur": "admin"}, headers=h("auditeur")).json()
    assert rows and rows[0]["operation"] in ("UPDATE", "INSERT") and rows[0]["utilisateur"] == "admin"
    maj = [r for r in rows if r["operation"] == "UPDATE" and r["apres"]["cle"] == "penalite_taux"]
    assert maj and maj[0]["avant"]["valeur"] == "0.001" and maj[0]["apres"]["valeur"] == "0.002"
    assert client.get("/api/audit", headers=h("caissier1")).status_code == 403
    assert client.get("/api/audit", headers=h("directeur")).status_code == 200


# ------------------------------------------------------------------ RH et paie
def test_employes_contrats_bulletins(client, h, agences, sql):
    make_user(sql, "rh2", "rh", agences["a2"])
    h2 = {"Authorization": "Bearer " + client.post("/api/auth/login", json={"login": "rh2", "mot_de_passe": "MotDePasse-Test-1"}).json()["access_token"]}
    e = client.post("/api/employes", json={"matricule": "E1", "nom": "Salarié Un", "date_embauche": "2026-01-01"}, headers=h("rh1"))
    assert e.status_code == 201, e.text
    eid = e.json()["id"]
    assert client.post("/api/employes", json={"matricule": "E9", "nom": "x", "date_embauche": "2026-01-01"}, headers=h("caissier1")).status_code == 403
    assert client.post(f"/api/employes/{eid}/contrats", json={"type": "cdi", "date_debut": "2026-01-01", "salaire_base": 100000}, headers=h("rh1")).status_code == 201
    assert client.post(f"/api/employes/{eid}/contrats", json={"type": "cdd", "date_debut": "2026-06-01", "salaire_base": 90000}, headers=h("rh1")).status_code == 409  # chevauchement
    assert client.post(f"/api/employes/{eid}/contrats", json={"type": "cdi", "date_debut": "2030-01-01", "salaire_base": 1}, headers=h("chef2")).status_code == 403   # le chef d'agence n'a pas le droit RH
    assert client.post(f"/api/employes/{eid}/contrats", json={"type": "cdi", "date_debut": "2030-01-01", "salaire_base": 1}, headers=h2).status_code == 404  # RH d'une autre agence
    # rubriques de TEST : les vrais taux ne sont pas fournis
    for rub in ({"code": "PRIME", "libelle": "Prime", "type": "gain", "mode": "fixe", "valeur": 5000, "base": "salaire_base", "ordre": 10},
                {"code": "COT", "libelle": "Cotisation", "type": "retenue_salariale", "mode": "pourcentage", "valeur": 0.04, "ordre": 20}):
        assert client.post("/api/rubriques-paie", json=rub, headers=h("rh1")).status_code == 201
    # portée des rubriques : le RH de l'agence 2 ne crée pas de rubrique pour l'agence 1 ; la sienne est rattachée à son agence
    autre = {"code": "AUTRE", "libelle": "x", "type": "gain", "mode": "fixe", "valeur": 1}
    assert client.post("/api/rubriques-paie", json={**autre, "agence_id": agences["a1"]}, headers=h2).status_code == 403
    mienne = client.post("/api/rubriques-paie", json=autre, headers=h2)
    assert mienne.status_code == 201 and mienne.json()["agence_id"] == agences["a2"]
    assert all(r["agence_id"] in (None, agences["a2"]) for r in client.get("/api/rubriques-paie", headers=h2).json())
    assert client.post(f"/api/employes/{eid}/avances", json={"montant": 20000, "date_avance": "2026-09-15"}, headers=h("rh1")).status_code == 201
    b = client.post("/api/bulletins", json={"employe_id": eid, "periode": "2026-10-15"}, headers=h("rh1"))
    assert b.status_code == 201, b.text
    b = b.json()
    assert (b["periode"], b["brut"], b["retenues"], b["retenue_avance"], b["net_a_payer"]) == ("2026-10-01", 105000, 4200, 20000, 80800)
    assert [l["code"] for l in b["lignes"]] == ["BASE", "PRIME", "COT", "AVANCE"]
    assert client.post("/api/bulletins", json={"employe_id": eid, "periode": "2026-10-01"}, headers=h("rh1")).status_code == 422   # déjà généré
    v = client.post(f"/api/bulletins/{b['id']}/valider", headers=h("rh1"))
    assert v.status_code == 200 and v.json()["statut"] == "valide"
    assert client.post(f"/api/bulletins/{b['id']}/valider", headers=h("rh1")).status_code == 422
    assert client.get(f"/api/bulletins/{b['id']}", headers=h2).status_code == 404
    assert client.get(f"/api/bulletins/{b['id']}", headers=h("auditeur")).status_code == 200
    assert client.get("/api/bulletins", params={"periode": "2026-10-20"}, headers=h("rh1")).json()[0]["id"] == b["id"]
    n = client.post("/api/bulletins/generer-agence", json={"periode": "2026-11-01"}, headers=h("rh1")).json()
    assert n == {"bulletins_generes": 1}


def test_commission_de_collectrice(client, h, base):
    k = base["k"]["id"]
    r = client.post("/api/commissions/calculer", json={"collectrice_id": k, "du": "2030-05-01", "au": "2030-05-31"}, headers=h("rh1"))
    assert r.status_code == 201, r.text
    c = r.json()
    assert c["taux"] == 0.03          # surcharge d'agence posée par test_parametres
    assert c["statut"] == "calculee" and c["commission_brute"] == round(c["production"] * 0.03)
    assert client.post("/api/commissions/calculer", json={"collectrice_id": k, "du": "2030-05-01", "au": "2030-05-31"}, headers=h("rh1")).status_code == 422
    assert client.post("/api/commissions/calculer", json={"collectrice_id": k, "du": "2030-06-01", "au": "2030-06-30"}, headers=h("chef1")).status_code == 403
    assert len(client.get("/api/commissions", headers=h("rh1")).json()) == 1
    assert client.get("/api/commissions", headers=h("chef2")).status_code == 403
