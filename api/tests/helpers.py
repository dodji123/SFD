"""Constantes et fabriques partagées par les tests."""
PWD = "MotDePasse-Test-1"


def make_user(sql, login, role, agence_id=None, pwd=PWD, **kw):
    from app.auth import hash_password

    r = sql(
        "INSERT INTO utilisateur(login, nom, role, agence_id, mot_de_passe_hash, agent_id, collectrice_id) "
        "VALUES (%s, %s, %s::role_utilisateur, %s, %s, %s, %s) RETURNING id",
        (login, login.capitalize(), role, agence_id, hash_password(pwd), kw.get("agent_id"), kw.get("collectrice_id")),
    )
    return r[0]["id"]
