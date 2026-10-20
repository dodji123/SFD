import datetime as dt
import re

import pytest

from tests.helpers import PWD, make_user

# Module sous test : routers/auth.py (mot de passe temporaire, politique, récupération), routers/securite.py,
# app/securite.py (journal, alertes, session glissante)

FORT = "Un-Bon-Passe-123"


def _login(client, login, pwd):
    return client.post("/api/auth/login", json={"login": login, "mot_de_passe": pwd})


def _hdr(r):
    return {"Authorization": "Bearer " + r.json()["access_token"]}


def test_mot_de_passe_temporaire_bloque_jusqu_au_changement(client, h, agences):
    corps = {"login": "temp-sec", "nom": "Temp", "role": "caissier", "agence_id": agences["a1"], "mot_de_passe": FORT}
    assert client.post("/api/utilisateurs", json=corps, headers=h("admin")).status_code == 201
    r = _login(client, "temp-sec", FORT)
    assert r.status_code == 200 and r.json()["user"]["doit_changer_mdp"] is True
    hdr = _hdr(r)
    assert client.get("/api/auth/me", headers=hdr).status_code == 200                      # profil accessible
    bloque = client.get("/api/produits-credit", headers=hdr)
    assert bloque.status_code == 403 and "mot de passe temporaire" in bloque.json()["detail"]
    assert client.post("/api/auth/mot-de-passe", json={"ancien": FORT, "nouveau": "Autre-Passe-456"}, headers=hdr).status_code == 204
    hdr2 = _hdr(_login(client, "temp-sec", "Autre-Passe-456"))
    assert client.get("/api/produits-credit", headers=hdr2).status_code == 200            # débloqué après changement


@pytest.mark.parametrize("faible", ["court1A!", "toutenminuscule1!", "TOUTENMAJUSCULE1!", "SansChiffre-Aucun", "SansSpecial12345"])
def test_politique_de_mot_de_passe(client, h, agences, faible):
    corps = {"login": "politique1", "nom": "X", "role": "caissier", "agence_id": agences["a1"], "mot_de_passe": faible}
    assert client.post("/api/utilisateurs", json=corps, headers=h("admin")).status_code == 422


def test_politique_refuse_l_identifiant_dans_le_mot_de_passe(client, h, agences):
    corps = {"login": "dupont", "nom": "X", "role": "caissier", "agence_id": agences["a1"], "mot_de_passe": "Dupont-Passe-123"}
    r = client.post("/api/utilisateurs", json=corps, headers=h("admin"))
    assert r.status_code == 422 and "identifiant" in r.json()["detail"]


def test_historique_interdit_la_reutilisation(client, sql, agences):
    make_user(sql, "histo1", "caissier", agences["a1"])
    hdr = _hdr(_login(client, "histo1", PWD))
    assert client.post("/api/auth/mot-de-passe", json={"ancien": PWD, "nouveau": PWD}, headers=hdr).status_code == 422
    assert client.post("/api/auth/mot-de-passe", json={"ancien": PWD, "nouveau": "Second-Passe-22"}, headers=hdr).status_code == 204
    hdr = _hdr(_login(client, "histo1", "Second-Passe-22"))
    r = client.post("/api/auth/mot-de-passe", json={"ancien": "Second-Passe-22", "nouveau": PWD}, headers=hdr)
    assert r.status_code == 422 and "déjà été utilisé" in r.json()["detail"]


def _dernier_jeton(sql, user_id):
    corps = sql("SELECT corps FROM message_personnel WHERE utilisateur_id = %s ORDER BY id DESC LIMIT 1", (user_id,))[0]["corps"]
    return re.search(r"jeton=([\w-]+)", corps).group(1)


def test_recuperation_du_mot_de_passe(client, sql, agences):
    uid = make_user(sql, "oubli1", "caissier", agences["a1"], email="oubli1@exemple.tg")
    a = client.post("/api/auth/mot-de-passe-oublie", json={"login": "oubli1"})
    b = client.post("/api/auth/mot-de-passe-oublie", json={"login": "inconnu-total"})
    assert a.status_code == b.status_code == 202 and a.json() == b.json()                  # pas d'énumération des comptes
    jeton = _dernier_jeton(sql, uid)
    stocke = sql("SELECT jeton_hash FROM jeton_reinit_mdp WHERE utilisateur_id = %s", (uid,))
    assert stocke and jeton not in stocke[0]["jeton_hash"] and len(stocke[0]["jeton_hash"]) == 64   # seul le haché est conservé

    assert client.post("/api/auth/reinitialiser-mot-de-passe", json={"jeton": jeton, "nouveau": "faible"}).status_code == 422
    assert client.post("/api/auth/reinitialiser-mot-de-passe", json={"jeton": "jeton-invalide-xyz", "nouveau": FORT}).status_code == 400
    assert client.post("/api/auth/reinitialiser-mot-de-passe", json={"jeton": jeton, "nouveau": FORT}).status_code == 204
    assert client.post("/api/auth/reinitialiser-mot-de-passe", json={"jeton": jeton, "nouveau": "Encore-Un-456"}).status_code == 400   # usage unique
    assert _login(client, "oubli1", FORT).status_code == 200 and _login(client, "oubli1", PWD).status_code == 401
    ev = {r["evenement"] for r in sql("SELECT evenement FROM journal_connexion WHERE login = 'oubli1'")}
    assert {"mdp_oublie", "mdp_reinitialise", "succes"} <= ev


def test_recuperation_jeton_expire_et_limite(client, sql, agences):
    uid = make_user(sql, "oubli2", "caissier", agences["a1"], email="oubli2@exemple.tg")
    client.post("/api/auth/mot-de-passe-oublie", json={"login": "oubli2"})
    jeton = _dernier_jeton(sql, uid)
    sql("UPDATE jeton_reinit_mdp SET expire_le = now() - interval '1 minute' WHERE utilisateur_id = %s", (uid,))
    assert client.post("/api/auth/reinitialiser-mot-de-passe", json={"jeton": jeton, "nouveau": FORT}).status_code == 400   # expiré
    for _ in range(5):
        client.post("/api/auth/mot-de-passe-oublie", json={"login": "oubli2"})
    assert sql("SELECT count(*) AS n FROM jeton_reinit_mdp WHERE utilisateur_id = %s", (uid,))[0]["n"] == 3        # 3 demandes par heure au plus


def test_compte_sans_contact_ne_recoit_rien(client, sql, agences):
    uid = make_user(sql, "oubli3", "caissier", agences["a1"])
    assert client.post("/api/auth/mot-de-passe-oublie", json={"login": "oubli3"}).status_code == 202
    assert sql("SELECT count(*) AS n FROM jeton_reinit_mdp WHERE utilisateur_id = %s", (uid,))[0]["n"] == 0


def test_verrouillage_journal_et_alerte(client, h, sql, agences):
    uid = make_user(sql, "verrou-sec", "caissier", agences["a1"])
    for _ in range(5):
        assert _login(client, "verrou-sec", "mauvais-mauvais").status_code == 401
    assert _login(client, "verrou-sec", PWD).status_code == 429
    ev = [r["evenement"] for r in sql("SELECT evenement FROM journal_connexion WHERE login = 'verrou-sec' ORDER BY id")]
    assert ev.count("echec") == 5 and "verrouille" in ev
    assert sql("SELECT count(*) AS n FROM alerte_securite WHERE type = 'verrouillage' AND utilisateur_id = %s", (uid,))[0]["n"] == 1
    # lecture du journal et des alertes : auditeur oui, caissier non
    j = client.get("/api/securite/connexions?login=verrou-sec", headers=h("auditeur"))
    assert j.status_code == 200 and len(j.json()) >= 6
    assert client.get("/api/securite/connexions", headers=h("caissier1")).status_code == 403
    al = client.get("/api/securite/alertes", headers=h("auditeur")).json()
    mine = next(a for a in al if a["utilisateur_id"] == uid)
    assert client.post(f"/api/securite/alertes/{mine['id']}/traiter", json={"commentaire": "ok"}, headers=h("auditeur")).status_code == 422
    t = client.post(f"/api/securite/alertes/{mine['id']}/traiter", json={"commentaire": "Appel de l'agent, erreur de saisie"}, headers=h("auditeur"))
    assert t.status_code == 200 and t.json()["traitee_le"] is not None
    assert client.post(f"/api/securite/alertes/{mine['id']}/traiter", json={"commentaire": "Déjà traité"}, headers=h("auditeur")).status_code == 404


def test_session_glissante_et_duree_courte(client, sql, agences):
    make_user(sql, "session1", "caissier", agences["a1"])
    r = _login(client, "session1", PWD)
    assert r.json()["session_minutes"] == 15
    me = client.get("/api/auth/me", headers=_hdr(r))
    nouveau = me.headers.get("X-Nouveau-Jeton")
    assert nouveau and client.get("/api/auth/me", headers={"Authorization": "Bearer " + nouveau}).status_code == 200
    import jwt
    from app.config import settings
    p = jwt.decode(r.json()["access_token"], settings.secret(), algorithms=["HS256"])
    assert p["exp"] - p["iat"] == 15 * 60


def test_connexion_hors_heures_alerte(client, sql, agences, monkeypatch):
    from app.config import settings
    uid = make_user(sql, "nuit1", "caissier", agences["a1"])
    monkeypatch.setattr(settings, "heures_ouvrables", "00-00")           # plage vide : toujours hors heures
    assert _login(client, "nuit1", PWD).status_code == 200
    assert sql("SELECT count(*) AS n FROM alerte_securite WHERE type = 'connexion_hors_heures' AND utilisateur_id = %s", (uid,))[0]["n"] == 1


def test_mot_de_passe_perime_force_le_changement(client, sql, agences):
    uid = make_user(sql, "perime1", "caissier", agences["a1"])
    sql("UPDATE utilisateur SET mdp_change_le = now() - interval '120 days' WHERE id = %s", (uid,))
    r = _login(client, "perime1", PWD)
    assert r.status_code == 200 and r.json()["user"]["doit_changer_mdp"] is True


def test_reinitialisation_par_admin_est_temporaire_et_alerte(client, h, sql, agences):
    uid = make_user(sql, "reinit-adm", "caissier", agences["a1"])
    assert client.post(f"/api/utilisateurs/{uid}/mot-de-passe", json={"mot_de_passe": "faible"}, headers=h("admin")).status_code == 422
    assert client.post(f"/api/utilisateurs/{uid}/mot-de-passe", json={"mot_de_passe": FORT}, headers=h("admin")).status_code == 204
    assert _login(client, "reinit-adm", FORT).json()["user"]["doit_changer_mdp"] is True
    assert sql("SELECT count(*) AS n FROM alerte_securite WHERE type = 'mdp_reinit_admin' AND utilisateur_id = %s", (uid,))[0]["n"] == 1
    assert client.post(f"/api/utilisateurs/{uid}/deverrouiller", headers=h("caissier1")).status_code == 403
    assert client.post(f"/api/utilisateurs/{uid}/deverrouiller", headers=h("admin")).status_code == 204


def test_sauvegardes_et_etat(client, h, sql):
    sql("DELETE FROM sauvegarde")
    etat = client.get("/api/securite/etat", headers=h("auditeur")).json()
    textes = " ".join(c["texte"] for c in etat["constats"])
    assert "Aucune sauvegarde" in textes and "test de restauration" in textes
    futur = (dt.datetime.now(dt.timezone.utc) + dt.timedelta(days=2)).isoformat()
    assert client.post("/api/securite/sauvegardes", json={"effectuee_le": futur, "support": "Disque coffre"}, headers=h("admin")).status_code == 422
    hier = (dt.datetime.now(dt.timezone.utc) - dt.timedelta(hours=20)).isoformat()
    s = client.post("/api/securite/sauvegardes", json={"effectuee_le": hier, "support": "Disque coffre", "taille_mo": 512.5}, headers=h("admin"))
    assert s.status_code == 201, s.text
    sid = s.json()["id"]
    assert client.post("/api/securite/sauvegardes", json={"effectuee_le": hier, "support": "x"}, headers=h("auditeur")).status_code == 403   # l'auditeur ne sauvegarde pas
    assert client.post(f"/api/securite/sauvegardes/{sid}/test", json={"resultat": "reussi"}, headers=h("admin")).status_code == 403          # ni l'admin ne teste
    t = client.post(f"/api/securite/sauvegardes/{sid}/test", json={"resultat": "reussi", "commentaire": "Restaurée sur machine de test"}, headers=h("auditeur"))
    assert t.status_code == 200 and t.json()["test_resultat"] == "reussi"
    assert client.post(f"/api/securite/sauvegardes/{sid}/test", json={"resultat": "reussi"}, headers=h("auditeur")).status_code == 404       # déjà testée
    etat = client.get("/api/securite/etat", headers=h("auditeur")).json()
    assert not any("sauvegarde" in c["texte"].lower() and c["gravite"] == "elevee" for c in etat["constats"])
    assert etat["politique"]["session_minutes"] == 15
    assert len(client.get("/api/securite/sauvegardes", headers=h("directeur")).json()) == 1


def test_changement_de_mot_de_passe_invalide_les_anciennes_sessions(client, sql, agences):
    make_user(sql, "invalide1", "caissier", agences["a1"])
    ancien = _hdr(_login(client, "invalide1", PWD))
    r = client.post("/api/auth/mot-de-passe", json={"ancien": PWD, "nouveau": "Nouveau-Passe-77"}, headers=ancien)
    assert r.status_code == 204 and r.headers.get("X-Nouveau-Jeton")
    assert client.get("/api/auth/me", headers=ancien).status_code == 401                                   # ancienne session coupée
    assert client.get("/api/auth/me", headers={"Authorization": "Bearer " + r.headers["X-Nouveau-Jeton"]}).status_code == 200


def test_coordinateur_sans_acces_aux_donnees_de_securite(client, h):
    assert client.get("/api/securite/etat", headers=h("directeur")).status_code == 200
    from app.perms import PERMS
    assert "coordinateur" not in PERMS["securite:read"] and "coordinateur" not in PERMS["sauvegarde:tester"]
