"""Session de caisse pour les dépôts et retraits d'épargne en espèces : chaque utilisateur en ouvre une, choisie explicitement."""
import uuid

_sessions: dict = {}
_compteur = [0]
_jeton = uuid.uuid4().hex[:6].upper()   # codes de caisse uniques d'une exécution à l'autre


def session_especes(client, h, login: str) -> int:
    """Session ouverte par `login` sur une caisse dédiée de test (créée une fois par utilisateur)."""
    if login not in _sessions:
        _compteur[0] += 1
        chef = "chef2" if login.endswith("2") else "chef1"
        caisse = client.post("/api/caisses", json={"code": f"T{_jeton}{_compteur[0]}"}, headers=h(chef)).json()
        s = client.post(f"/api/caisses/{caisse['id']}/sessions",
                        json={"date_session": "2026-01-01", "solde_ouverture": 1000000000}, headers=h(login)).json()
        # un utilisateur sans droit d'ouverture de caisse n'a pas de session : la requête sera refusée par ses droits
        _sessions[login] = s.get("id")
    return _sessions[login]
