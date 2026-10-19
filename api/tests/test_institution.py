import pytest

# Modules sous test : routers/institution.py (fiche de l'institution, coordonnées des agences) et l'en-tête des pièces justificatives

PNG = "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg=="


def _fiche(**kw):
    return {"raison_sociale": "Caisse de Test", "sigle": "CDT", "agrement": "Agrément n° 123", "immatriculation": "RCCM TG-LOM-2020-B-1234",
            "adresse": "12 rue du Commerce", "ville": "Lomé", "telephone": "+228 22 00 00 00", "email": "contact@cdt.tg", "site_web": "www.cdt.tg",
            "logo": PNG, "pied_de_page": "Merci de conserver cette pièce", **kw}


def test_fiche_de_l_institution(client, h):
    assert client.get("/api/institution", headers=h("chef1")).status_code == 200                 # lisible par le personnel
    assert client.put("/api/institution", json=_fiche(), headers=h("chef1")).status_code == 403   # modifiable par l'administrateur seul
    assert client.put("/api/institution", json=_fiche(raison_sociale=""), headers=h("admin")).status_code == 422
    assert client.put("/api/institution", json=_fiche(logo="data:text/html;base64,PHNjcmlwdD4="), headers=h("admin")).status_code == 422        # pas de HTML
    assert client.put("/api/institution", json=_fiche(logo="data:image/svg+xml;base64,PHN2Zz4="), headers=h("admin")).status_code == 422        # ni de SVG
    assert client.put("/api/institution", json=_fiche(logo="data:image/png;base64," + "A" * 400001), headers=h("admin")).status_code == 422      # trop lourd
    r = client.put("/api/institution", json=_fiche(), headers=h("admin"))
    assert r.status_code == 200, r.text
    d = client.get("/api/institution", headers=h("chef1")).json()
    assert d["raison_sociale"] == "Caisse de Test" and d["sigle"] == "CDT" and d["logo"] == PNG and d["pied_de_page"] == "Merci de conserver cette pièce"


def test_coordonnees_des_agences(client, h, agences):
    a1 = agences["a1"]
    assert client.patch(f"/api/agences/{a1}", json={"adresse": "x"}, headers=h("chef1")).status_code == 403
    assert client.patch(f"/api/agences/{a1}", json={}, headers=h("admin")).status_code == 422
    assert client.patch(f"/api/agences/{a1}", json={"libelle": None}, headers=h("admin")).status_code == 422
    assert client.patch("/api/agences/9999", json={"adresse": "x"}, headers=h("admin")).status_code == 404
    r = client.patch(f"/api/agences/{a1}", json={"adresse": "Boulevard du Mono", "ville": "Lomé", "telephone": "+228 90 00 00 01", "email": "lome@cdt.tg"}, headers=h("admin"))
    assert r.status_code == 200 and r.json()["adresse"] == "Boulevard du Mono" and r.json()["telephone"] == "+228 90 00 00 01"
    # un champ non transmis ne change pas
    r = client.patch(f"/api/agences/{a1}", json={"ville": "Kpalimé"}, headers=h("admin"))
    assert r.json()["ville"] == "Kpalimé" and r.json()["adresse"] == "Boulevard du Mono"
    mes = client.get("/api/agences", headers=h("chef1")).json()
    assert mes[0]["telephone"] == "+228 90 00 00 01"


def test_la_piece_porte_l_entete_de_l_institution_et_de_l_agence(client, h, produits, agences):
    client.put("/api/institution", json=_fiche(), headers=h("admin"))
    client.patch(f"/api/agences/{agences['a1']}", json={"adresse": "Boulevard du Mono", "ville": "Lomé", "telephone": "+228 90 00 00 01"}, headers=h("admin"))
    c = client.post("/api/clients", json={"nom": "Entete Test"}, headers=h("chef1")).json()
    cpt = client.post("/api/comptes-epargne", json={"client_id": c["id"], "produit_id": produits["CL"]}, headers=h("caissier1")).json()
    d = client.post(f"/api/comptes-epargne/{cpt['id']}/depot", json={"montant": 15000}, headers=h("caissier1")).json()
    p = client.get(f"/api/pieces/{d['piece_id']}", headers=h("caissier1")).json()
    assert p["institution"]["raison_sociale"] == "Caisse de Test" and p["institution"]["logo"] == PNG and p["institution"]["pied_de_page"]
    assert p["agence_adresse"] == "Boulevard du Mono" and p["agence_telephone"] == "+228 90 00 00 01" and p["agence_code"] == "T1"
