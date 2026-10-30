import io

from openpyxl import Workbook, load_workbook

MIME = "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"


def _xlsx(lignes):
    wb = Workbook()
    ws = wb.active
    ws.append(["numero", "nom", "zone_code", "produit_code", "telephone"])
    for l in lignes:
        ws.append(l)
    buf = io.BytesIO()
    wb.save(buf)
    return buf.getvalue()


def _zone(client, h, code):
    r = client.post("/api/zones", json={"code": code, "libelle": f"Zone {code}"}, headers=h("chef1"))
    assert r.status_code == 201, r.text


def test_modele_clients(client, h, produits):
    _zone(client, h, "ZMC")
    r = client.get("/api/import/clients/modele", headers=h("chef1"))
    assert r.status_code == 200, r.text
    classeur = load_workbook(io.BytesIO(r.content))
    assert classeur.sheetnames == ["Clients", "Notice", "Zones", "Produits"]
    assert [c.value for c in classeur["Clients"][1]][:4] == ["numero", "nom", "zone_code", "produit_code"]
    assert "ZMC" in [row[0].value for row in classeur["Zones"].iter_rows(min_row=2)]


def test_controle_sans_ecriture(client, h, produits):
    _zone(client, h, "ZCC")
    fichier = _xlsx([
        ["CL-IMP-1", "Ama Test", "ZCC", "P1", "90000001"],
        ["CL-IMP-2", "", "ZCC", "P1", None],
        ["CL-IMP-3", "Kossi Test", "ZINCONNUE", "P1", None],
        ["CL-IMP-4", "Afi Test", "ZCC", "PX", None],
        ["CL-IMP-1", "Doublon", "ZCC", "P1", None],
    ])
    r = client.post("/api/import/clients/verifier", files={"fichier": ("clients.xlsx", fichier, MIME)}, headers=h("chef1"))
    assert r.status_code == 200, r.text
    d = r.json()
    assert d["lignes_lues"] == 5 and d["lignes_valides"] == 1
    champs = {(e["ligne"], e["champ"]) for e in d["erreurs"]}
    assert {(3, "nom"), (4, "zone_code"), (5, "produit_code"), (6, "numero")} <= champs
    assert client.get("/api/clients", params={"q": "CL-IMP-1"}, headers=h("chef1")).json() == []


def test_valider_garde_les_numeros_du_terrain(client, h, produits):
    _zone(client, h, "ZVC")
    fichier = _xlsx([["TER-0001", "Ama Valide", "ZVC", "P1", "90000002"], ["TER-0002", "Kodjo Valide", "ZVC", "P1", None]])
    r = client.post("/api/import/clients/valider", files={"fichier": ("clients.xlsx", fichier, MIME)}, headers=h("chef1"))
    assert r.status_code == 200, r.text
    assert r.json()["crees"] == 2 and r.json()["numeros"] == ["TER-0001", "TER-0002"]
    trouve = client.get("/api/clients", params={"q": "TER-0001"}, headers=h("chef1")).json()
    assert [c["numero"] for c in trouve] == ["TER-0001"] and trouve[0]["nom"] == "Ama Valide"
    # rejouer le même fichier : les numéros existent, rien n'est dupliqué ni écrasé
    r2 = client.post("/api/import/clients/valider", files={"fichier": ("clients.xlsx", fichier, MIME)}, headers=h("chef1"))
    assert r2.json()["crees"] == 0 and len(r2.json()["refus"]) == 2


def test_import_clients_refuse_sans_permission(client, h):
    fichier = _xlsx([["X-1", "Test", "ZVC", "P1", None]])
    assert client.post("/api/import/clients/valider", files={"fichier": ("c.xlsx", fichier, MIME)}, headers=h("caissier1")).status_code == 403
