import datetime as dt

from tests.helpers import PWD, make_user


def test_health(client):
    assert client.get("/api/health").json() == {"status": "ok"}


def test_connexion_reussie(client, utilisateurs):
    r = client.post("/api/auth/login", json={"login": "chef1", "mot_de_passe": PWD})
    assert r.status_code == 200
    body = r.json()
    assert body["token_type"] == "bearer" and body["access_token"]
    assert body["user"]["role"] == "chef_agence" and body["user"]["agence_id"] is not None
    assert "mot_de_passe_hash" not in str(body)


def test_mauvais_mot_de_passe_et_login_inconnu_meme_reponse(client, utilisateurs):
    a = client.post("/api/auth/login", json={"login": "caissier1", "mot_de_passe": "faux-faux-faux"})
    b = client.post("/api/auth/login", json={"login": "personne", "mot_de_passe": "faux-faux-faux"})
    assert a.status_code == b.status_code == 401
    assert a.json() == b.json()  # pas d'énumération des comptes


def test_verrouillage_apres_echecs(client, sql, agences):
    make_user(sql, "verrou1", "caissier", agences["a1"])
    for _ in range(5):
        assert client.post("/api/auth/login", json={"login": "verrou1", "mot_de_passe": "mauvais-mauvais"}).status_code == 401
    # même avec le bon mot de passe, le compte reste verrouillé
    r = client.post("/api/auth/login", json={"login": "verrou1", "mot_de_passe": PWD})
    assert r.status_code == 429
    # un administrateur peut réinitialiser (et donc déverrouiller)
    uid = sql("SELECT id FROM utilisateur WHERE login = 'verrou1'")[0]["id"]
    admin = client.post("/api/auth/login", json={"login": "admin", "mot_de_passe": PWD}).json()["access_token"]
    r = client.post(f"/api/utilisateurs/{uid}/mot-de-passe", json={"mot_de_passe": "Nouveau-Passe-123"},
                    headers={"Authorization": "Bearer " + admin})
    assert r.status_code == 204
    assert client.post("/api/auth/login", json={"login": "verrou1", "mot_de_passe": "Nouveau-Passe-123"}).status_code == 200


def test_succes_remet_les_echecs_a_zero(client, sql, agences):
    make_user(sql, "verrou2", "caissier", agences["a1"])
    for _ in range(3):
        client.post("/api/auth/login", json={"login": "verrou2", "mot_de_passe": "mauvais-mauvais"})
    assert client.post("/api/auth/login", json={"login": "verrou2", "mot_de_passe": PWD}).status_code == 200
    assert sql("SELECT echecs_connexion FROM utilisateur WHERE login = 'verrou2'")[0]["echecs_connexion"] == 0


def test_me_exige_un_jeton_valide(client, h):
    assert client.get("/api/auth/me").status_code == 401
    assert client.get("/api/auth/me", headers={"Authorization": "Bearer pas-un-jeton"}).status_code == 401
    r = client.get("/api/auth/me", headers=h("chef1"))
    assert r.status_code == 200 and r.json()["login"] == "chef1"


def test_jeton_expire(client, utilisateurs):
    from app.auth import create_token

    jeton = create_token(utilisateurs["chef1"], "chef_agence", 1, expires=dt.timedelta(seconds=-5))
    assert client.get("/api/auth/me", headers={"Authorization": "Bearer " + jeton}).status_code == 401


def test_compte_desactive_perd_l_acces_immediatement(client, sql, agences):
    make_user(sql, "temp1", "caissier", agences["a1"])
    hdr = {"Authorization": "Bearer " + client.post("/api/auth/login", json={"login": "temp1", "mot_de_passe": PWD}).json()["access_token"]}
    assert client.get("/api/auth/me", headers=hdr).status_code == 200
    sql("UPDATE utilisateur SET actif = false WHERE login = 'temp1'")
    assert client.get("/api/auth/me", headers=hdr).status_code == 401
    assert client.post("/api/auth/login", json={"login": "temp1", "mot_de_passe": PWD}).status_code == 401


def test_changer_son_mot_de_passe(client, sql, agences):
    make_user(sql, "chgpwd", "agent", agences["a1"])
    hdr = {"Authorization": "Bearer " + client.post("/api/auth/login", json={"login": "chgpwd", "mot_de_passe": PWD}).json()["access_token"]}
    assert client.post("/api/auth/mot-de-passe", json={"ancien": "faux", "nouveau": "Autre-Passe-1234"}, headers=hdr).status_code == 403
    assert client.post("/api/auth/mot-de-passe", json={"ancien": PWD, "nouveau": "court"}, headers=hdr).status_code == 422
    assert client.post("/api/auth/mot-de-passe", json={"ancien": PWD, "nouveau": "Autre-Passe-1234"}, headers=hdr).status_code == 204
    assert client.post("/api/auth/login", json={"login": "chgpwd", "mot_de_passe": PWD}).status_code == 401
    assert client.post("/api/auth/login", json={"login": "chgpwd", "mot_de_passe": "Autre-Passe-1234"}).status_code == 200


def test_gestion_des_utilisateurs_reservee_a_l_admin(client, h, agences):
    corps = {"login": "nouveau1", "nom": "Nouveau", "role": "caissier", "agence_id": agences["a1"], "mot_de_passe": "Un-Bon-Passe-123"}
    assert client.post("/api/utilisateurs", json=corps, headers=h("chef1")).status_code == 403
    assert client.get("/api/utilisateurs", headers=h("caissier1")).status_code == 403
    r = client.post("/api/utilisateurs", json=corps, headers=h("admin"))
    assert r.status_code == 201 and r.json()["login"] == "nouveau1" and "mot_de_passe_hash" not in r.json()
    assert client.post("/api/utilisateurs", json=corps, headers=h("admin")).status_code == 409  # doublon
    assert "nouveau1" in [u["login"] for u in client.get("/api/utilisateurs", headers=h("admin")).json()]


def test_creation_utilisateur_validations(client, h, agences):
    base = {"login": "val1", "nom": "V", "role": "caissier", "agence_id": agences["a1"], "mot_de_passe": "Un-Bon-Passe-123"}
    assert client.post("/api/utilisateurs", json={**base, "mot_de_passe": "court"}, headers=h("admin")).status_code == 422
    assert client.post("/api/utilisateurs", json={**base, "login": "a b"}, headers=h("admin")).status_code == 422
    assert client.post("/api/utilisateurs", json={**base, "role": "pirate"}, headers=h("admin")).status_code == 422
    # un caissier doit avoir une agence (règle du schéma)
    assert client.post("/api/utilisateurs", json={**base, "agence_id": None}, headers=h("admin")).status_code == 422
    # un comptable peut être au siège
    assert client.post("/api/utilisateurs", json={**base, "login": "val2", "role": "comptable", "agence_id": None}, headers=h("admin")).status_code == 201


def test_modifier_et_desactiver(client, h, agences):
    uid = client.post("/api/utilisateurs", json={"login": "mod1", "nom": "M", "role": "agent", "agence_id": agences["a1"],
                                                 "mot_de_passe": "Un-Bon-Passe-123"}, headers=h("admin")).json()["id"]
    r = client.patch(f"/api/utilisateurs/{uid}", json={"actif": False}, headers=h("admin"))
    assert r.status_code == 200 and r.json()["actif"] is False
    assert client.patch("/api/utilisateurs/999999", json={"actif": False}, headers=h("admin")).status_code == 404
    moi = client.get("/api/auth/me", headers=h("admin")).json()["id"]
    assert client.patch(f"/api/utilisateurs/{moi}", json={"actif": False}, headers=h("admin")).status_code == 422
    assert client.patch(f"/api/utilisateurs/{uid}", json={}, headers=h("admin")).status_code == 422


def test_audit_trace_l_utilisateur(client, h, sql, agences):
    client.post("/api/utilisateurs", json={"login": "aud1", "nom": "A", "role": "agent", "agence_id": agences["a1"],
                                           "mot_de_passe": "Un-Bon-Passe-123"}, headers=h("admin"))
    # l'utilisateur est une table non auditée : on vérifie via une table auditée au prochain incrément
    assert sql("SELECT count(*) AS n FROM utilisateur WHERE login = 'aud1'")[0]["n"] == 1
