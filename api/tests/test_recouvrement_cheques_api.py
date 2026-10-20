import pytest

# Module sous test : routers/recouvrement.py et routers/procurations_cheques.py (+ action « dormant » de epargne.py)


@pytest.fixture(scope="module")
def base(client, h, sql, produits, agences, utilisateurs):
    a1 = agences["a1"]
    c = client.post("/api/clients", json={"nom": "Débiteur recouvrement"}, headers=h("chef1")).json()
    p = client.post("/api/produits-credit", json={"code": "PREC", "libelle": "Crédit recouvrement", "type": "sans_epargne", "taux_annuel": 0.18}, headers=h("chef1")).json()
    sql("INSERT INTO demande_credit(agence_id,client_id,produit_id,montant,nb_echeances,taux,mode_remboursement,statut) VALUES (%s,%s,%s,300000,3,0.18,'especes','debloquee')", (a1, c["id"], p["id"]))
    did = sql("SELECT max(id) AS i FROM demande_credit")[0]["i"]
    sql("INSERT INTO credit(agence_id,numero,client_id,type,montant_accorde,taux,date_deblocage,nb_echeances,mode_remboursement,statut) "
        "VALUES (%s,'CR-REC-1',%s,'sans_epargne',300000,0.18,current_date - 600,3,'especes','en_retard')", (a1, c["id"]))
    cid = sql("SELECT max(id) AS i FROM credit")[0]["i"]
    sql("UPDATE demande_credit SET credit_id = %s WHERE id = %s", (cid, did))
    sql("INSERT INTO echeance(credit_id,no_echeance,date_prevue,capital,interet,statut) VALUES (%s,1,current_date - 570,300000,4500,'echue')", (cid,))
    compte = client.post("/api/comptes-epargne", json={"client_id": c["id"], "produit_id": produits["CL"]}, headers=h("chef1")).json()
    client.post(f"/api/comptes-epargne/{compte['id']}/depot", json={"montant": 300000}, headers=h("chef1"))
    sql("INSERT INTO compte_banque(agence_id,code,libelle) VALUES (%s,'BQREC','Banque test')", (a1,))
    return {"credit": cid, "client": c, "compte": compte, "banque": sql("SELECT id FROM compte_banque WHERE code = 'BQREC'")[0]["id"], "u": utilisateurs}


def test_recouvrement_de_bout_en_bout(client, h, base):
    cid = base["credit"]
    assert any(x["id"] == cid for x in client.get("/api/recouvrement/credits-en-retard", headers=h("chef1")).json())
    r = client.post("/api/recouvrement/dossiers", json={"credit_id": cid, "agent_id": base["u"]["agent1"]}, headers=h("chef1"))
    assert r.status_code == 201, r.text
    did = r.json()["id"]
    assert r.json()["jours_retard"] == 570 and r.json()["capital_restant"] == 300000
    assert client.get(f"/api/recouvrement/dossiers/{did}", headers=h("chef2")).status_code == 404
    assert client.post("/api/recouvrement/dossiers", json={"credit_id": cid}, headers=h("chef1")).status_code in (409, 422)
    act = f"/api/recouvrement/dossiers/{did}/actions"
    assert client.post(act, json={"type": "mise_en_demeure"}, headers=h("agent1")).status_code == 422                    # amiable d'abord
    assert client.post(act, json={"type": "relance", "resultat": "SMS"}, headers=h("agent1")).status_code == 201
    assert client.post(act, json={"type": "mise_en_demeure", "resultat": "Courrier"}, headers=h("agent1")).status_code == 201
    assert client.post(act, json={"type": "vente_garantie"}, headers=h("agent1")).status_code == 422                       # évaluation obligatoire
    assert client.post(act, json={"type": "vente_garantie", "valeur_estimee": 90000}, headers=h("agent1")).status_code == 201
    perte = f"/api/recouvrement/dossiers/{did}/perte"
    motif = {"motif": "Créance irrécouvrable après toutes les démarches"}
    assert client.post(perte, json=motif, headers=h("agent1")).status_code == 403                                           # droit réservé
    assert client.post(perte, json=motif, headers=h("directeur")).status_code == 422                                        # visite manquante
    assert client.post(act, json={"type": "visite", "resultat": "Insolvable"}, headers=h("agent1")).status_code == 201
    p = client.post(perte, json=motif, headers=h("directeur"))
    assert p.status_code == 200 and p.json()["statut"] == "perte"
    d = client.get(f"/api/recouvrement/dossiers/{did}", headers=h("chef1")).json()
    assert d["radiation"]["capital_restant"] == 300000 and len(d["actions"]) == 4


def test_documents_de_credit(client, h, base, sql):
    cid = base["credit"]
    c = client.get(f"/api/documents-credit/{cid}/contrat", headers=h("chef1")).json()
    assert c["credit"]["numero"] == "CR-REC-1" and len(c["echeances"]) == 1 and c["institution"]["raison_sociale"]
    assert client.get(f"/api/documents-credit/{cid}/contrat", headers=h("chef2")).status_code == 404
    assert client.get(f"/api/documents-credit/{cid}/certificat-cloture", headers=h("chef1")).status_code == 422             # pas soldé
    sql("UPDATE credit SET statut = 'solde', date_solde = current_date WHERE id = %s", (cid,))
    ok = client.get(f"/api/documents-credit/{cid}/certificat-cloture", headers=h("chef1"))
    assert ok.status_code == 200 and ok.json()["credit"]["client"] == "Débiteur recouvrement"


def test_reechelonnement(client, h, base, sql, agences):
    c = base["client"]
    p = sql("SELECT id FROM produit_credit_epargne WHERE code = 'PREC'")[0]["id"]
    sql("INSERT INTO demande_credit(agence_id,client_id,produit_id,montant,nb_echeances,taux,mode_remboursement,statut) VALUES (%s,%s,%s,60000,2,0.18,'especes','debloquee')", (agences["a1"], c["id"], p))
    did = sql("SELECT max(id) AS i FROM demande_credit")[0]["i"]
    sql("INSERT INTO credit(agence_id,numero,client_id,type,montant_accorde,taux,date_deblocage,nb_echeances,mode_remboursement,statut) VALUES (%s,'CR-REC-2',%s,'sans_epargne',60000,0.18,current_date - 90,2,'especes','en_retard')", (agences["a1"], c["id"]))
    cid = sql("SELECT max(id) AS i FROM credit")[0]["i"]
    sql("UPDATE demande_credit SET credit_id = %s WHERE id = %s", (cid, did))
    r = client.post(f"/api/recouvrement/credits/{cid}/reechelonner", json={"nb_echeances": 6}, headers=h("chef1"))
    assert r.status_code == 201 and r.json()["montant"] == 60000 and r.json()["reechelonne_de"] == cid and r.json()["statut"] == "demandee"
    assert client.post(f"/api/recouvrement/credits/{cid}/reechelonner", json={"nb_echeances": 6}, headers=h("chef1")).status_code == 422


def test_procuration(client, h, base):
    cpt = base["compte"]["id"]
    r = client.post("/api/procurations", json={"compte_id": cpt, "mandataire_nom": "Mandataire Test", "mandataire_piece": "CNI 1234", "plafond": 50000}, headers=h("caissier1"))
    assert r.status_code == 201, r.text
    pid = r.json()["id"]
    assert client.post(f"/api/procurations/{pid}/valider", headers=h("caissier1")).status_code == 403                       # le caissier ne valide pas

    def retrait(m):
        return client.post(f"/api/comptes-epargne/{cpt}/retrait", json={"montant": m, "procuration_id": pid}, headers=h("chef1"))
    assert retrait(10000).status_code == 422                                                                                  # pas encore validée
    assert client.post(f"/api/procurations/{pid}/valider", headers=h("chef1")).json()["statut"] == "validee"
    assert retrait(10000).status_code == 201
    assert retrait(60000).status_code == 422                                                                                  # plafond de la procuration
    assert client.post(f"/api/procurations/{pid}/revoquer", headers=h("chef1")).status_code == 200
    assert retrait(10000).status_code == 422
    assert client.get("/api/procurations", headers=h("chef2")).json() == []


def test_cheques_signatures(client, h, base):
    b = base["banque"]
    r = client.post("/api/cheques", json={"compte_banque_id": b, "numero_cheque": "9001", "beneficiaire": "Fournisseur", "objet": "Facture", "montant": 200000}, headers=h("chef1"))
    assert r.status_code == 201, r.text
    cid = r.json()["id"]
    assert r.json()["trois_signatures"] is False
    assert client.post(f"/api/cheques/{cid}/emettre", headers=h("chef1")).status_code == 422                                  # aucune signature
    assert client.post(f"/api/cheques/{cid}/signer", headers=h("chef1")).status_code == 403                                   # le chef ne signe pas
    assert client.post(f"/api/cheques/{cid}/signer", headers=h("directeur")).status_code == 200
    assert client.post(f"/api/cheques/{cid}/signer", headers=h("directeur")).status_code in (409, 422)                        # une fois seulement
    assert client.post(f"/api/cheques/{cid}/emettre", headers=h("chef1")).status_code == 422
    assert client.post(f"/api/cheques/{cid}/signer", headers=h("comptable")).status_code == 200
    e = client.post(f"/api/cheques/{cid}/emettre", headers=h("chef1"))
    assert e.status_code == 200 and e.json()["statut"] == "emis" and len(e.json()["signatures"]) == 2
    gros = client.post("/api/cheques", json={"compte_banque_id": b, "numero_cheque": "9002", "beneficiaire": "Fournisseur", "objet": "Gros achat", "montant": 2500000}, headers=h("chef1")).json()
    assert gros["trois_signatures"] is True
    for login in ("directeur", "comptable"):
        client.post(f"/api/cheques/{gros['id']}/signer", headers=h(login))
    assert client.post(f"/api/cheques/{gros['id']}/emettre", headers=h("chef1")).status_code == 422                          # il manque le président
    assert client.post(f"/api/cheques/{gros['id']}/signer", headers=h("admin")).status_code == 200
    assert client.post(f"/api/cheques/{gros['id']}/emettre", headers=h("chef1")).json()["statut"] == "emis"
    assert client.get("/api/cheques", headers=h("chef2")).json() == []
    assert client.get("/api/cheques", headers=h("caissier1")).status_code == 403


def test_compte_dormant_action(client, h, base, sql):
    c = client.post("/api/clients", json={"nom": "Client dormant"}, headers=h("chef1")).json()
    cpt = sql("INSERT INTO compte_epargne(agence_id,client_id,produit_id,numero,ouvert_le) SELECT agence_id,%s,produit_id,'DORM-1',current_date - 700 FROM compte_epargne WHERE id = %s RETURNING id", (c["id"], base["compte"]["id"]))[0]["id"]
    sql("INSERT INTO mouvement_epargne(compte_id,type,montant,date_operation) VALUES (%s,'depot',80000,current_date - 600)", (cpt,))
    assert client.post(f"/api/comptes-epargne/{cpt}/dormant?action=clore", headers=h("chef1")).status_code == 422             # solde non nul
    assert client.post(f"/api/comptes-epargne/{cpt}/dormant?action=bloquer", headers=h("caissier1")).status_code == 403
    assert client.post(f"/api/comptes-epargne/{cpt}/dormant?action=bloquer", headers=h("chef1")).json() == {"statut": "bloque"}
