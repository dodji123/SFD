import types

import pytest

from app import totp
from app.config import settings
from tests.helpers import PWD, make_user

# Module sous test : app/totp.py, routers/totp.py, routers/auth.py (login en deux temps), routers/utilisateurs.py (réinitialisation)


@pytest.fixture()
def horloge(monkeypatch):
    """Horloge TOTP maîtrisée : chaque connexion se fait dans un nouveau pas de 30 s (le rejeu est refusé dans un même pas)."""
    h = types.SimpleNamespace(t=1_800_000_000.0)
    monkeypatch.setattr(totp, "time", types.SimpleNamespace(time=lambda: h.t))
    h.avance = lambda pas=1: setattr(h, "t", h.t + 30 * pas)
    return h


@pytest.fixture()
def totp_oblige(monkeypatch):
    monkeypatch.setattr(settings, "totp_obligatoire", True)


def _login(client, login, pwd=PWD):
    return client.post("/api/auth/login", json={"login": login, "mot_de_passe": pwd})


def _hdr(token):
    return {"Authorization": "Bearer " + token}


def _enroler(client, horloge, login):
    """Connexion, enrôlement et activation. Retourne (secret, codes de secours, en-têtes)."""
    r = _login(client, login)
    assert r.status_code == 200, r.text
    hdr = _hdr(r.json()["access_token"])
    secret = client.post("/api/auth/totp/preparer", headers=hdr).json()["secret"]
    a = client.post("/api/auth/totp/activer", json={"code": totp.code_a(secret, horloge.t)}, headers=hdr)
    assert a.status_code == 200, a.text
    return secret, a.json()["codes_secours"], hdr


def _connecter(client, horloge, login, secret):
    horloge.avance()
    d = _login(client, login).json()
    assert d.get("totp_requis") is True and "access_token" not in d
    return client.post("/api/auth/login/totp", json={"defi": d["defi"], "code": totp.code_a(secret, horloge.t)})


def test_rfc_6238_vecteur():
    # RFC 4226/6238 : secret "12345678901234567890", t = 59 s -> compteur 1 -> 287082 sur 6 chiffres
    import base64
    s = base64.b32encode(b"12345678901234567890").decode()
    assert totp.code_a(s, 59) == "287082"
    assert totp.verifier(s, "287082", 0, 59) == 1
    assert totp.verifier(s, "287082", 1, 59) is None                    # rejeu du même pas
    assert totp.verifier(s, "287082", 0, 59 + 120) is None              # hors de la fenêtre
    assert totp.verifier(s, "12345", 0, 59) is None and totp.verifier(s, "abcdef", 0, 59) is None


def test_role_sensible_doit_enroler_avant_tout(client, sql, agences, horloge, totp_oblige):
    make_user(sql, "totp-chef1", "chef_agence", agences["a1"])
    r = _login(client, "totp-chef1")
    assert r.status_code == 200 and r.json()["user"]["totp_a_enroler"] is True
    hdr = _hdr(r.json()["access_token"])
    bloque = client.get("/api/produits-credit", headers=hdr)
    assert bloque.status_code == 403 and "second facteur" in bloque.json()["detail"]
    assert client.get("/api/auth/me", headers=hdr).status_code == 200
    assert client.get("/api/auth/totp", headers=hdr).json() == {
        "actif": False, "obligatoire": True, "a_enroler": True, "enrolement_en_cours": False, "codes_secours_restants": 0}
    prep = client.post("/api/auth/totp/preparer", headers=hdr).json()
    assert prep["uri"].startswith("otpauth://totp/SFD:totp-chef1?secret=" + prep["secret"])
    assert client.post("/api/auth/totp/activer", json={"code": "000000"}, headers=hdr).status_code == 422
    assert client.get("/api/produits-credit", headers=hdr).status_code == 403            # pas encore actif
    a = client.post("/api/auth/totp/activer", json={"code": totp.code_a(prep["secret"], horloge.t)}, headers=hdr)
    assert a.status_code == 200 and len(a.json()["codes_secours"]) == 10
    assert client.get("/api/produits-credit", headers=hdr).status_code == 200            # débloqué aussitôt
    assert client.post("/api/auth/totp/preparer", headers=hdr).status_code == 409        # déjà actif
    ev = {e["evenement"] for e in sql("SELECT evenement FROM journal_connexion WHERE login = 'totp-chef1'")}
    assert "totp_active" in ev


def test_roles_hors_liste_non_concernes(client, sql, agences, totp_oblige):
    make_user(sql, "totp-cais1", "caissier", agences["a1"])
    r = _login(client, "totp-cais1")
    assert r.status_code == 200 and r.json()["user"]["totp_a_enroler"] is False
    assert client.get("/api/produits-credit", headers=_hdr(r.json()["access_token"])).status_code == 200


def test_connexion_en_deux_temps(client, sql, agences, horloge, totp_oblige):
    make_user(sql, "totp-comp1", "comptable")
    secret, _, _ = _enroler(client, horloge, "totp-comp1")
    # secret chiffré en base : ni en clair, ni lisible sans la clé
    stocke = sql("SELECT secret_chiffre FROM utilisateur_totp WHERE utilisateur_id = (SELECT id FROM utilisateur WHERE login = 'totp-comp1')")[0]["secret_chiffre"]
    assert secret not in stocke and stocke.startswith("v1:") and totp.dechiffrer(stocke) == secret
    horloge.avance()
    d = _login(client, "totp-comp1").json()
    assert d["totp_requis"] is True and "access_token" not in d
    # le défi n'ouvre aucune route
    assert client.get("/api/auth/me", headers=_hdr(d["defi"])).status_code == 401
    assert client.post("/api/auth/login/totp", json={"defi": d["defi"], "code": "123456"}).status_code == 401
    ok = client.post("/api/auth/login/totp", json={"defi": d["defi"], "code": totp.code_a(secret, horloge.t)})
    assert ok.status_code == 200 and ok.json()["user"]["totp_actif"] is True
    assert client.get("/api/produits-credit", headers=_hdr(ok.json()["access_token"])).status_code == 200
    # rejeu du même code : refusé
    rejeu = client.post("/api/auth/login/totp", json={"defi": d["defi"], "code": totp.code_a(secret, horloge.t)})
    assert rejeu.status_code == 401
    # mauvais mot de passe : pas de défi
    assert _login(client, "totp-comp1", "mauvais-mauvais").status_code == 401
    assert client.post("/api/auth/login/totp", json={"defi": "x" * 20, "code": "123456"}).status_code == 401


def test_echecs_du_second_facteur_verrouillent(client, sql, agences, horloge, totp_oblige):
    make_user(sql, "totp-verrou", "directeur")
    secret, _, _ = _enroler(client, horloge, "totp-verrou")
    horloge.avance()
    d = _login(client, "totp-verrou").json()["defi"]
    for _ in range(5):
        assert client.post("/api/auth/login/totp", json={"defi": d, "code": "000000"}).status_code == 401
    bon = client.post("/api/auth/login/totp", json={"defi": d, "code": totp.code_a(secret, horloge.t)})
    assert bon.status_code == 429                                                       # verrouillé, même avec le bon code
    ev = [e["evenement"] for e in sql("SELECT evenement FROM journal_connexion WHERE login = 'totp-verrou' ORDER BY id")]
    assert ev.count("totp_echec") == 5 and "verrouille" in ev
    assert sql("SELECT count(*) AS n FROM alerte_securite WHERE type = 'verrouillage' AND detail LIKE 'Compte totp-verrou%'")[0]["n"] == 1


def test_codes_de_secours(client, sql, agences, horloge, totp_oblige):
    make_user(sql, "totp-sec1", "admin")
    secret, codes, hdr = _enroler(client, horloge, "totp-sec1")
    assert len(set(codes)) == 10 and all(len(c) == 11 and c[5] == "-" for c in codes)
    stockes = {r["code_hash"] for r in sql("SELECT code_hash FROM code_secours_totp WHERE utilisateur_id = (SELECT id FROM utilisateur WHERE login = 'totp-sec1')")}
    assert all(c not in stockes for c in codes) and len(stockes) == 10                  # seuls les hachés sont conservés
    horloge.avance()
    d = _login(client, "totp-sec1").json()["defi"]
    ok = client.post("/api/auth/login/totp", json={"defi": d, "code": codes[0].lower()})   # insensible à la casse
    assert ok.status_code == 200
    assert client.post("/api/auth/login/totp", json={"defi": d, "code": codes[0]}).status_code == 401   # usage unique
    assert any(e["evenement"] == "totp_secours" for e in sql("SELECT evenement FROM journal_connexion WHERE login = 'totp-sec1'"))
    # régénération : exige un code TOTP, invalide les anciens
    nh = _hdr(ok.json()["access_token"])
    horloge.avance()
    assert client.post("/api/auth/totp/codes-secours", json={"code": "000000"}, headers=nh).status_code == 422
    nouveaux = client.post("/api/auth/totp/codes-secours", json={"code": totp.code_a(secret, horloge.t)}, headers=nh).json()["codes_secours"]
    assert len(nouveaux) == 10 and not set(nouveaux) & set(codes)
    horloge.avance()
    d2 = _login(client, "totp-sec1").json()["defi"]
    assert client.post("/api/auth/login/totp", json={"defi": d2, "code": codes[1]}).status_code == 401   # ancien code
    assert client.post("/api/auth/login/totp", json={"defi": d2, "code": nouveaux[0]}).status_code == 200


def test_alerte_quand_les_codes_de_secours_s_epuisent(client, sql, agences, horloge, totp_oblige):
    uid = make_user(sql, "totp-sec2", "chef_agence", agences["a1"])
    _, codes, _ = _enroler(client, horloge, "totp-sec2")
    for c in codes[:8]:
        horloge.avance()
        d = _login(client, "totp-sec2").json()["defi"]
        assert client.post("/api/auth/login/totp", json={"defi": d, "code": c}).status_code == 200
    assert sql("SELECT count(*) AS n FROM alerte_securite WHERE type = 'totp_secours_bas' AND utilisateur_id = %s", (uid,))[0]["n"] == 1


def test_reinitialisation_par_un_responsable(client, h, sql, agences, horloge, monkeypatch):
    uid = make_user(sql, "totp-perdu", "comptable")
    monkeypatch.setattr(settings, "totp_obligatoire", True)
    secret, _, ancien = _enroler(client, horloge, "totp-perdu")
    assert client.get("/api/auth/me", headers=ancien).status_code == 200
    monkeypatch.setattr(settings, "totp_obligatoire", False)      # les responsables de test n'ont pas de second facteur
    # droits : le caissier ne peut pas, personne ne se réinitialise soi-même, motif obligatoire
    assert client.post(f"/api/utilisateurs/{uid}/totp/reinitialiser", json={"motif": "Téléphone perdu"}, headers=h("caissier1")).status_code == 403
    assert client.post(f"/api/utilisateurs/{uid}/totp/reinitialiser", json={"motif": "x"}, headers=h("admin")).status_code == 422
    admin_id = sql("SELECT id FROM utilisateur WHERE login = 'admin'")[0]["id"]
    assert client.post(f"/api/utilisateurs/{admin_id}/totp/reinitialiser", json={"motif": "Moi-même"}, headers=h("admin")).status_code == 422
    # le directeur réinitialise un comptable mais pas un administrateur
    make_user(sql, "totp-admin2", "admin")
    autre = sql("SELECT id FROM utilisateur WHERE login = 'totp-admin2'")[0]["id"]
    sql("INSERT INTO utilisateur_totp(utilisateur_id, secret_chiffre) VALUES (%s, %s)", (autre, totp.chiffrer(totp.nouveau_secret())))
    assert client.post(f"/api/utilisateurs/{autre}/totp/reinitialiser", json={"motif": "Téléphone perdu"}, headers=h("directeur")).status_code == 403
    r = client.post(f"/api/utilisateurs/{uid}/totp/reinitialiser", json={"motif": "Téléphone perdu, codes épuisés"}, headers=h("directeur"))
    assert r.status_code == 204
    assert client.post(f"/api/utilisateurs/{uid}/totp/reinitialiser", json={"motif": "Deuxième fois"}, headers=h("directeur")).status_code == 404
    # sessions coupées, journal et alerte, rien ne reste
    assert client.get("/api/auth/me", headers=ancien).status_code == 401
    assert sql("SELECT count(*) AS n FROM utilisateur_totp WHERE utilisateur_id = %s", (uid,))[0]["n"] == 0
    assert sql("SELECT count(*) AS n FROM code_secours_totp WHERE utilisateur_id = %s", (uid,))[0]["n"] == 0
    assert sql("SELECT count(*) AS n FROM alerte_securite WHERE type = 'totp_reinit' AND utilisateur_id = %s", (uid,))[0]["n"] == 1
    assert any("directeur" in (e["detail"] or "") for e in sql("SELECT detail FROM journal_connexion WHERE evenement = 'totp_reinit' AND utilisateur_id = %s", (uid,)))
    # prochaine connexion : session sans droits jusqu'au nouvel enrôlement
    monkeypatch.setattr(settings, "totp_obligatoire", True)
    nouveau = _login(client, "totp-perdu")
    assert nouveau.json()["user"]["totp_a_enroler"] is True
    assert client.get("/api/produits-credit", headers=_hdr(nouveau.json()["access_token"])).status_code == 403


def test_desactivation_possible_seulement_hors_roles_obligatoires(client, sql, agences, horloge, totp_oblige):
    make_user(sql, "totp-cais2", "caissier", agences["a1"])
    secret, _, hdr = _enroler(client, horloge, "totp-cais2")
    horloge.avance()
    assert client.post("/api/auth/totp/desactiver", json={"mot_de_passe": "faux", "code": totp.code_a(secret, horloge.t)}, headers=hdr).status_code == 403
    assert client.post("/api/auth/totp/desactiver", json={"mot_de_passe": PWD, "code": totp.code_a(secret, horloge.t)}, headers=hdr).status_code == 204
    assert _login(client, "totp-cais2").json().get("access_token")                      # plus de défi
    make_user(sql, "totp-chef3", "chef_agence", agences["a1"])
    secret2, _, hdr2 = _enroler(client, horloge, "totp-chef3")
    horloge.avance()
    r = client.post("/api/auth/totp/desactiver", json={"mot_de_passe": PWD, "code": totp.code_a(secret2, horloge.t)}, headers=hdr2)
    assert r.status_code == 403 and "obligatoire" in r.json()["detail"]


def test_compte_a_totp_actif_hors_obligation_est_aussi_protege(client, sql, agences, horloge, totp_oblige):
    """Un caissier qui choisit d'activer le second facteur doit ensuite le fournir à chaque connexion."""
    make_user(sql, "totp-cais3", "caissier", agences["a1"])
    secret, _, _ = _enroler(client, horloge, "totp-cais3")
    assert _connecter(client, horloge, "totp-cais3", secret).status_code == 200


def test_etat_securite_signale_les_comptes_sans_second_facteur(client, h, sql, agences, totp_oblige):
    make_user(sql, "totp-chef4", "chef_agence", agences["a1"])
    etat = client.get("/api/securite/etat", headers=h("auditeur")).json()
    assert etat["comptes_sans_totp"] >= 1
    assert any("second facteur" in c["texte"] and c["gravite"] == "elevee" for c in etat["constats"])
    assert etat["politique"]["totp_obligatoire"] is True and "comptable" in etat["politique"]["totp_roles"]


def test_utilisateurs_liste_indique_le_second_facteur(client, h):
    assert all("totp_actif" in u for u in client.get("/api/utilisateurs", headers=h("admin")).json())
