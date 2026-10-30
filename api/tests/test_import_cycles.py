import io

from openpyxl import Workbook


def _xlsx(lignes):
    wb = Workbook()
    ws = wb.active
    ws.append(["numero", "client_numero", "produit_code", "date_debut", "date_fin", "mise"])
    for l in lignes:
        ws.append(l)
    buf = io.BytesIO()
    wb.save(buf)
    return buf.getvalue()


def test_controle_sans_ecriture_et_erreurs_par_ligne(client, h, produits):
    cl = client.post("/api/clients", json={"nom": "Import Client"}, headers=h("chef1")).json()
    fichier = _xlsx([
        ["IMP-OK-1", cl["numero"], "P1", "2026-10-01", "2026-11-30", 1000],
        ["IMP-FIN-AVANT", cl["numero"], "P1", "2026-11-30", "2026-10-01", 1000],
        ["IMP-MISE", cl["numero"], "P1", "2026-10-01", "2026-11-30", 0],
        ["IMP-CLIENT", "INCONNU", "P1", "2026-10-01", "2026-11-30", 1000],
        ["IMP-OK-1", cl["numero"], "P1", "2026-10-01", "2026-11-30", 1000],
    ])
    r = client.post("/api/import/cycles/verifier", files={"fichier": ("cycles.xlsx", fichier, "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet")}, headers=h("chef1"))
    assert r.status_code == 200, r.text
    d = r.json()
    assert d["lignes_lues"] == 5
    assert d["lignes_valides"] == 1 and d["apercu"][0]["numero"] == "IMP-OK-1"
    champs = {(e["ligne"], e["champ"]) for e in d["erreurs"]}
    assert (3, "date_fin") in champs and (4, "mise") in champs and (5, "client_numero") in champs and (6, "numero") in champs


def test_colonne_manquante_refusee(client, h):
    wb = Workbook()
    wb.active.append(["numero", "client_numero"])
    buf = io.BytesIO()
    wb.save(buf)
    r = client.post("/api/import/cycles/verifier", files={"fichier": ("x.xlsx", buf.getvalue(), "application/octet-stream")}, headers=h("chef1"))
    assert r.status_code == 422 and "Colonnes manquantes" in r.json()["detail"]
