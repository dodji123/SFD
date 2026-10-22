import datetime as dt

import pytest

# Module sous test : routers/roles.py (matrice de droits, rôles personnalisés, affectations temporaires) + schema/53_roles.sql
# et le basculement de auth.require() sur la matrice en base.


@pytest.fixture(scope="module")
def base(client, h, utilisateurs, agences):
    r = client.post("/api/roles", json={"code": "superviseur", "libelle": "Superviseur de caisse"}, headers=h("admin"))
    assert r.status_code == 201, r.text
    assert client.put("/api/roles/superviseur/droits", json={"permissions": ["caisse:write", "caisse:read", "roles:demander"]}, headers=h("admin")).status_code == 200
    return {"caissier": utilisateurs["caissier1"], "agence": agences["a1"]}


def _demander(client, h, base, login="chef1", agence=None, debut=0, fin=30, motif="Remplacement pendant congé"):
    today = dt.date.today()
    return client.post("/api/affectations-roles", json={
        "utilisateur_id": base["caissier"], "role_code": "superviseur", "agence_id": agence or base["agence"],
        "date_debut": (today + dt.timedelta(days=debut)).isoformat(), "date_fin": (today + dt.timedelta(days=fin)).isoformat(), "motif": motif,
    }, headers=h(login))


def test_matrice_et_roles(client, h, base):
    assert any(u["login"] == "caissier1" for u in client.get("/api/roles/utilisateurs", headers=h("chef1")).json())
    assert all(u["login"] != "chef2" for u in client.get("/api/roles/utilisateurs", headers=h("chef1")).json())   # autre agence exclue
    assert client.get("/api/roles", headers=h("caissier1")).status_code == 403                             # lecture réservée
    roles = {r["code"]: r for r in client.get("/api/roles", headers=h("admin")).json()}
    assert roles["admin"]["systeme"] is True and roles["superviseur"]["systeme"] is False
    m = client.get("/api/roles/matrice", headers=h("chef1")).json()
    gerer = next(p for p in m["permissions"] if p["code"] == "roles:gerer")
    assert gerer["roles"] == ["admin"]
    assert len(m["permissions"]) == 99


def test_garde_fous_administrateur_et_roles(client, h, base):
    # l'administrateur ne peut pas perdre la gestion des rôles ni celle des utilisateurs
    assert client.put("/api/roles/admin/droits", json={"permissions": ["caisse:read"]}, headers=h("admin")).status_code == 422
    assert client.patch("/api/roles/admin", json={"actif": False}, headers=h("admin")).status_code == 422
    assert client.put("/api/roles/superviseur/droits", json={"permissions": ["perm:inexistante"]}, headers=h("admin")).status_code == 422
    assert client.post("/api/roles", json={"code": "superviseur", "libelle": "Doublon"}, headers=h("admin")).status_code == 409
    assert client.post("/api/roles", json={"code": "nouveau", "libelle": "Nouveau rôle"}, headers=h("chef1")).status_code == 403


def test_demande_validation_et_effet(client, h, base):
    assert _demander(client, h, base, fin=300).status_code == 422                                          # plus de six mois
    assert _demander(client, h, base, motif="court").status_code == 422
    assert _demander(client, h, base, login="chef2").status_code == 403                                    # hors de son agence
    d = _demander(client, h, base)
    assert d.status_code == 201, d.text
    aid = d.json()["id"]
    assert d.json()["statut"] == "demandee" and d.json()["demande_par_nom"]
    assert client.get("/api/roles/matrice", headers=h("caissier1")).status_code == 403                    # pas encore actif
    # séparation des tâches : celui qui demande ne valide pas
    assert client.post(f"/api/affectations-roles/{aid}/decider", json={"accepte": True}, headers=h("chef1")).status_code == 403   # ne valide pas : pas le droit roles:valider
    assert client.post(f"/api/affectations-roles/{aid}/decider", json={"accepte": False}, headers=h("directeur")).status_code == 422   # refus non motivé
    # le directeur n'a pas caisse:write : il ne peut pas accorder ce rôle
    assert client.post(f"/api/affectations-roles/{aid}/decider", json={"accepte": True}, headers=h("directeur")).status_code == 403
    ok = client.post(f"/api/affectations-roles/{aid}/decider", json={"accepte": True, "commentaire": "Pièce vérifiée"}, headers=h("admin"))
    assert ok.status_code == 200 and ok.json()["statut"] == "active" and ok.json()["valide_par_nom"]
    assert client.post(f"/api/affectations-roles/{aid}/decider", json={"accepte": True}, headers=h("admin")).status_code == 422       # déjà décidée
    # l'effet est immédiat : le caissier obtient le droit du superviseur
    assert client.get("/api/roles/matrice", headers=h("caissier1")).status_code == 200
    assert client.get("/api/affectations-roles", params={"statut": "active"}, headers=h("chef1")).json()[0]["id"] == aid
    base["affectation"] = aid


def test_pas_d_escalade_ni_hors_perimetre(client, h, base, utilisateurs):
    today = dt.date.today()
    dates = {"date_debut": today.isoformat(), "date_fin": (today + dt.timedelta(days=10)).isoformat(), "motif": "Tentative d'escalade"}
    # un chef ne demande pas le rôle administrateur
    assert client.post("/api/affectations-roles", json={**dates, "utilisateur_id": base["caissier"], "role_code": "admin", "agence_id": base["agence"]}, headers=h("chef1")).status_code == 403
    # ni une personne hors de son agence
    assert client.post("/api/affectations-roles", json={**dates, "utilisateur_id": utilisateurs["caissier2"], "role_code": "superviseur", "agence_id": base["agence"]}, headers=h("chef1")).status_code == 403


def test_revocation_et_perimetre(client, h, base):
    aid = base["affectation"]
    assert client.post(f"/api/affectations-roles/{aid}/revoquer", json={"motif": "ok"}, headers=h("directeur")).status_code == 422          # motif trop court
    assert client.post(f"/api/affectations-roles/{aid}/revoquer", json={"motif": "Fin du remplacement"}, headers=h("auditeur")).status_code == 403
    rev = client.post(f"/api/affectations-roles/{aid}/revoquer", json={"motif": "Fin du remplacement"}, headers=h("directeur"))
    assert rev.status_code == 200 and rev.json()["statut"] == "revoquee"
    assert client.get("/api/roles/matrice", headers=h("caissier1")).status_code == 403                    # droit retiré aussitôt
    # un chef d'une autre agence ne voit pas les affectations de l'agence 1
    assert client.get("/api/affectations-roles", params={"agence_id": base["agence"]}, headers=h("chef2")).status_code == 403
    assert client.get("/api/affectations-roles", headers=h("chef2")).json() == []
    assert client.post(f"/api/affectations-roles/{aid}/decider", json={"accepte": True}, headers=h("admin")).status_code == 422       # plus en attente
