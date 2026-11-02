def test_ecriture_refusee_si_horloge_reculee_lecture_permise(client, h, sql):
    entetes = h("chef1")   # connexion faite avant : se connecter est une écriture, elle serait refusée ensuite
    # l'horloge enregistrée est dans le futur : la machine a reculé, donc toute écriture est refusée
    sql("UPDATE horloge_systeme SET dernier_instant = now() + interval '1 day' WHERE id = 1 RETURNING id")
    r = client.post("/api/zones", json={"code": "HZ1", "libelle": "Horloge"}, headers=entetes)
    assert r.status_code == 423, r.text
    assert "antérieure à la dernière date enregistrée" in r.json()["detail"]
    # une lecture reste possible, pour consulter les données sans agir
    assert client.get("/api/zones", headers=entetes).status_code == 200
    # horloge revenue à l'heure : l'écriture repasse
    sql("UPDATE horloge_systeme SET dernier_instant = now() WHERE id = 1 RETURNING id")
    assert client.post("/api/zones", json={"code": "HZ2", "libelle": "Horloge"}, headers=entetes).status_code == 201
