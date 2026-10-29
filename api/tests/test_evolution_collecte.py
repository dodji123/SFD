import datetime as dt


def test_evolution_par_defaut_mois_en_cours(client, h):
    """Sans dates : le mois calendaire en cours, comparé à la période précédente de même durée."""
    r = client.get("/api/rapports/collecte-evolution", headers=h("chef1"))
    assert r.status_code == 200, r.text
    d = r.json()
    today = dt.date.today()
    assert d["du"] == today.replace(day=1).isoformat() and d["au"] == today.isoformat()
    duree = (today - today.replace(day=1)).days + 1
    assert (dt.date.fromisoformat(d["au"]) - dt.date.fromisoformat(d["du"])).days + 1 == duree
    assert dt.date.fromisoformat(d["precedent_au"]) == today.replace(day=1) - dt.timedelta(days=1)


def test_totaux_coherents_global_jour_et_agent(client, h):
    """Le total de la période égale la somme des jours et la somme des agents."""
    d = client.get("/api/rapports/collecte-evolution", params={"du": "2026-10-01", "au": "2026-10-31"}, headers=h("chef1")).json()
    assert d["total"] == sum(j["total"] for j in d["jours"]) == sum(a["total"] for a in d["agents"])
    for a in d["agents"]:
        assert a["total"] == sum(j["total"] for j in a["jours"])


def test_periode_inversee_refusee(client, h):
    r = client.get("/api/rapports/collecte-evolution", params={"du": "2026-10-31", "au": "2026-10-01"}, headers=h("chef1"))
    assert r.status_code == 422


def test_droits_requis(client, h):
    assert client.get("/api/rapports/collecte-evolution", headers=h("agent1")).status_code == 403
