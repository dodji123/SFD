import datetime as dt

import pytest

# Module sous test : routers/operations_caisse.py (opérations standard de caisse / hors caisse, transferts de fonds) + schema/50_operations_standard.sql


@pytest.fixture(scope="module")
def base(sql, agences):
    jour = dt.date.today()
    ids = {}
    for cle, ag, code in (("c1", agences["a1"], "OP-C1"), ("c1b", agences["a1"], "OP-C1B"), ("c2", agences["a2"], "OP-C2")):
        k = sql("INSERT INTO caisse(agence_id, code, type) VALUES (%s, %s, 'principale') RETURNING id", (ag, code))[0]["id"]
        sql("INSERT INTO session_caisse(caisse_id, date_session, solde_ouverture) VALUES (%s, %s, 1000000)", (k, jour))
        ids[cle] = k
    return ids


def test_catalogue_droits_et_parametrage(client, h, base):
    cat = client.get("/api/operations-standard", headers=h("auditeur")).json()
    assert {o["famille"] for o in cat} == {"caisse", "hors_caisse"} and any(o["code"] == "paiement_loyer" for o in cat)
    assert client.get("/api/operations-standard", headers=h("agent1")).status_code == 403
    nouveau = {"code": "achat_petit_materiel", "libelle": "Achat de petit matériel", "famille": "caisse", "categorie": "charge", "sens": "sortie",
               "compte_debit": "6228", "compte_credit": "1011", "journal_code": "CAI", "justificatif_obligatoire": True, "seuil_validation": 30000}
    assert client.post("/api/operations-standard", json=nouveau, headers=h("chef1")).status_code == 403
    ok = client.post("/api/operations-standard", json=nouveau, headers=h("comptable"))
    assert ok.status_code == 201 and ok.json()["comptes_valides"] is False
    assert client.post("/api/operations-standard", json={**nouveau, "code": "mauvais_compte", "compte_credit": "33211"}, headers=h("comptable")).status_code == 422   # une sortie de caisse crédite la caisse
    assert client.post("/api/operations-standard", json={**nouveau, "code": "hors", "famille": "hors_caisse"}, headers=h("comptable")).status_code == 422          # hors caisse sur 1011
    assert client.post("/api/operations-standard/achat_petit_materiel/valider-comptes", headers=h("chef1")).status_code == 403
    assert client.post("/api/operations-standard/achat_petit_materiel/valider-comptes", headers=h("comptable")).json()["comptes_valides"] is True
    maj = client.patch("/api/operations-standard/achat_petit_materiel", json={"compte_debit": "6214", "compte_credit": "1011"}, headers=h("comptable")).json()
    assert maj["compte_debit"] == "6214" and maj["comptes_valides"] is False                         # modifier les comptes remet la validation à zéro
    assert client.get("/api/operations-standard", params={"famille": "hors_caisse"}, headers=h("comptable")).json()[0]["famille"] == "hors_caisse"


def test_saisie_validation_et_hors_caisse(client, h, base, agences):
    corps = {"code_operation": "achat_fournitures", "montant": 10000, "reference_justificatif": "FAC-API-1", "tiers": "Papeterie", "caisse_id": base["c1"]}
    assert client.post("/api/operations-generales", json=corps, headers=h("auditeur")).status_code == 403
    assert client.post("/api/operations-generales", json={**corps, "caisse_id": None}, headers=h("caissier1")).status_code == 422                 # caisse à choisir
    assert client.post("/api/operations-generales", json={**corps, "reference_justificatif": None}, headers=h("caissier1")).status_code == 422   # justificatif obligatoire
    assert client.post("/api/operations-generales", json={**corps, "caisse_id": base["c2"]}, headers=h("caissier1")).status_code == 403            # autre agence
    petit = client.post("/api/operations-generales", json={**corps, "cle": "cle-op-0001"}, headers=h("caissier1"))
    assert petit.status_code == 201, petit.text
    assert petit.json()["statut"] == "valide" and petit.json()["operation_caisse_id"] and petit.json()["famille"] == "caisse"
    assert client.post("/api/operations-generales", json={**corps, "cle": "cle-op-0001"}, headers=h("caissier1")).json()["id"] == petit.json()["id"]   # idempotent
    gros = client.post("/api/operations-generales", json={**corps, "montant": 80000, "cle": "cle-op-0002"}, headers=h("caissier1")).json()
    assert gros["statut"] == "a_valider" and gros["operation_caisse_id"] is None
    assert client.post(f"/api/operations-generales/{gros['id']}/decider", json={"valide": True}, headers=h("caissier1")).status_code == 403           # pas le droit de valider
    assert client.post(f"/api/operations-generales/{gros['id']}/decider", json={"valide": False}, headers=h("chef1")).status_code == 422            # rejet non motivé
    ok = client.post(f"/api/operations-generales/{gros['id']}/decider", json={"valide": True, "commentaire": "Facture contrôlée"}, headers=h("chef1"))
    assert ok.status_code == 200 and ok.json()["statut"] == "valide" and ok.json()["operation_caisse_id"]
    assert client.post(f"/api/operations-generales/{gros['id']}/decider", json={"valide": True}, headers=h("chef1")).status_code == 422             # déjà décidée
    assert client.post(f"/api/operations-generales/{gros['id']}/decider", json={"valide": True}, headers=h("chef2")).status_code == 404            # hors périmètre
    # hors caisse : aucun mouvement d'espèces, agence désignée par le comptable (siège)
    hc = client.post("/api/operations-generales", json={"code_operation": "virement_fournisseur", "montant": 300000, "reference_justificatif": "VIR-9", "agence_id": agences["a1"]}, headers=h("comptable"))
    assert hc.status_code == 201 and hc.json()["famille"] == "hors_caisse" and hc.json()["operation_caisse_id"] is None
    assert client.post("/api/operations-generales", json={"code_operation": "virement_fournisseur", "montant": 1000, "reference_justificatif": "V", "caisse_id": base["c1"]}, headers=h("chef1")).status_code == 201   # le champ caisse est ignoré pour le hors caisse
    liste = client.get("/api/operations-generales", params={"famille": "caisse", "q": "Papeterie"}, headers=h("auditeur")).json()
    assert len(liste) == 2 and all(o["famille"] == "caisse" for o in liste)
    assert client.get("/api/operations-generales", headers=h("chef2")).json() == []


def test_transfert_de_fonds_accuse_de_reception(client, h, base):
    corps = {"caisse_source_id": base["c1"], "caisse_dest_id": base["c2"], "montant": 200000, "motif": "Approvisionnement agence 2"}
    assert client.post("/api/transferts-fonds", json=corps, headers=h("auditeur")).status_code == 403
    assert client.post("/api/transferts-fonds", json={**corps, "caisse_dest_id": base["c1"]}, headers=h("chef1")).status_code == 422             # même caisse
    assert client.post("/api/transferts-fonds", json={**corps, "montant": 5_000_000}, headers=h("chef1")).status_code == 422                     # fonds insuffisants
    assert client.post("/api/transferts-fonds", json={**corps, "caisse_source_id": base["c2"], "caisse_dest_id": base["c1"]}, headers=h("chef1")).status_code == 403   # pas sa caisse
    t = client.post("/api/transferts-fonds", json=corps, headers=h("chef1"))
    assert t.status_code == 201, t.text
    tid = t.json()["id"]
    assert t.json()["statut"] == "envoye" and t.json()["reference"].startswith("TF-") and t.json()["en_retard"] is False
    assert client.post(f"/api/transferts-fonds/{tid}/recevoir", json={"montant_recu": 200000}, headers=h("chef1")).status_code == 403            # revient à la destination
    assert client.get("/api/transferts-fonds", params={"statut": "envoye"}, headers=h("chef2")).json()[0]["id"] == tid                          # visible côté destinataire
    assert client.post(f"/api/transferts-fonds/{tid}/recevoir", json={"montant_recu": 190000}, headers=h("chef2")).status_code == 422             # écart non expliqué
    ok = client.post(f"/api/transferts-fonds/{tid}/recevoir", json={"montant_recu": 190000, "commentaire": "Une liasse de 10 000 F manquante"}, headers=h("chef2"))
    assert ok.status_code == 200 and ok.json()["statut"] == "recu" and float(ok.json()["ecart"]) == -10000 and ok.json()["recu_par_nom"]
    assert client.post(f"/api/transferts-fonds/{tid}/recevoir", json={"montant_recu": 190000, "commentaire": "Deuxième fois"}, headers=h("chef2")).status_code == 422   # déjà réceptionné
    # refus avec retour à la caisse d'origine
    t2 = client.post("/api/transferts-fonds", json={**corps, "montant": 50000, "motif": "Envoi refusé"}, headers=h("chef1")).json()
    assert client.post(f"/api/transferts-fonds/{t2['id']}/refuser", json={"motif": "ok"}, headers=h("chef2")).status_code == 422                  # motif trop court
    r = client.post(f"/api/transferts-fonds/{t2['id']}/refuser", json={"motif": "Fonds non attendus, retour à l'envoyeur"}, headers=h("chef2"))
    assert r.status_code == 200 and r.json()["statut"] == "refuse"
    assert client.get("/api/transferts-fonds", params={"statut": "envoye"}, headers=h("chef1")).json() == []
