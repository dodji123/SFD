import pytest

from app import capacite

# Module sous test : app/capacite.py (calcul pur). Dossier d'exemple de l'outil d'analyse de crédit : commerçante, 26 jours d'activité, 3e crédit.
CHARGES = [
    {"libelle": "Loyer", "categorie": "activite", "montant": 30000, "periode": "mois"},
    {"libelle": "Transport", "categorie": "activite", "montant": 1500, "periode": "jourouvre"},       # x 26 = 39 000
    {"libelle": "Électricité et eau", "categorie": "activite", "montant": 12000, "periode": "mois"},
    {"libelle": "Taxe municipale", "categorie": "activite", "montant": 15000, "periode": "trimestre"},   # / 3 = 5 000
    {"libelle": "Nourriture", "categorie": "menage", "montant": 2500, "periode": "jour7"},              # x 30 = 75 000
    {"libelle": "Scolarité", "categorie": "menage", "montant": 60000, "periode": "trimestre"},          # / 3 = 20 000
    {"libelle": "Santé", "categorie": "menage", "montant": 15000, "periode": "mois"},
]
GARANTIES = [
    {"libelle": "Matériel", "type": "materiel", "valeur": 300000, "decote": 50},
    {"libelle": "Moto", "type": "vehicule", "valeur": 400000, "decote": 40},
    {"libelle": "Épargne bloquée", "type": "epargne", "valeur": 100000, "decote": 0},
]
BASE = dict(montant=600000, nb_echeances=12, taux_annuel=0.18, periodicite_jours=30, methode="annuite_constante",
            ventes=900000, achats=600000, autres_revenus=0, jours_activite=26, charges=CHARGES,
            anciennete_mois=36, cycle=3, caution="perso", historique="bon", garanties=GARANTIES, frais_pct=2)


def test_conversion_des_charges_en_mensuel():
    f = capacite.charge_mensuelle
    assert f(1500, "jourouvre", 26) == 39000 and f(2500, "jour7", 26) == 75000 and f(15000, "trimestre", 26) == 5000
    assert f(600, "semestre", 26) == 100 and f(120000, "an", 26) == 10000 and f(52, "semaine", 26) == pytest.approx(225.333, abs=1e-3)
    with pytest.raises(ValueError):
        f(1, "decennie", 26)


def test_echeancier_comme_la_base():
    # annuité constante : 600 000 à 1,5 %/mois sur 12 mois = 55 008 ; capital constant : 50 000 + intérêts sur le restant dû
    a = capacite.echeancier(600000, 12, 0.18, 30, "annuite_constante")
    assert round(a[0][0] + a[0][1]) == 55008 and round(sum(c for c, _ in a)) == 600000
    c = capacite.echeancier(600000, 12, 0.18, 30, "capital_constant")
    assert round(c[0][0]) == 50000 and round(c[0][1]) == 9000 and round(c[-1][1]) == 750        # dernier intérêt : 50 000 x 1,5 %
    assert capacite.echeancier(120000, 4, 0, 30, "annuite_constante")[0] == (30000, 0)        # taux nul : capital constant
    with pytest.raises(ValueError):
        capacite.echeancier(1, 1, 0.1, 30, "inconnu")


def test_modes_plat_in_fine_et_differe():
    plat = capacite.echeancier(600000, 12, 0.18, 30, "plat")
    assert all(round(i) == 9000 for _, i in plat) and round(plat[0][0]) == 50000                # intérêts sur le capital initial
    fin = capacite.echeancier(600000, 12, 0.18, 30, "infine")
    assert [c for c, _ in fin[:-1]] == [0.0] * 11 and round(fin[-1][0]) == 600000 and round(fin[0][1]) == 9000
    cf = capacite.charge_credit(600000, 12, 0.18, 30, "infine")
    assert round(cf["mensuelle"]) == 9000 + 50000                                                # intérêt mensuel + provision capital / durée
    # différé de 2 échéances : intérêts seuls, puis capital réparti sur les 10 suivantes
    d = capacite.echeancier(600000, 12, 0.18, 30, "capital_constant", differe=2)
    assert d[0][0] == 0 and d[1][0] == 0 and round(d[2][0]) == 60000 and round(sum(c for c, _ in d)) == 600000
    cd = capacite.charge_credit(600000, 12, 0.18, 30, "capital_constant", differe=2)
    assert round(cd["echeance"]) == 69000 and round(cd["mensuelle"]) == 69000                    # la charge retenue est celle d'après le différé


def test_dossier_d_exemple():
    r = capacite.analyser(**BASE)
    assert (r["charges_activite"], r["charges_menage"], r["marge_brute"], r["revenus"], r["revenu_disponible"]) == (86000, 110000, 300000, 214000, 104000)
    assert r["charge_mensuelle"] == 55008 and r["mise_journaliere"] == 2116
    assert r["taux_endettement"] == pytest.approx(0.257, abs=1e-3)       # 55 008 / 214 000
    assert r["couverture"] == pytest.approx(1.891, abs=1e-3)              # 104 000 / 55 008
    assert r["conforme"] is True
    assert r["baisse_ventes_tolere"] == pytest.approx(0.1633, abs=1e-3)   # (104 000 - 55 008) / 300 000
    assert r["montant_max_conseille"] == pytest.approx(756254, abs=300)  # 104 000 / 1,5 = 69 333 par mois (sous 33 % x 214 000), plafond du cycle 3 : 800 000
    assert r["plafond_cycle"] == 800000 and r["depasse_plafond"] is False
    # garanties : 150 000 + 240 000 + 100 000 = 490 000 retenus sur 600 000 = 81,7 %
    assert (r["garanties_brutes"], r["garanties_retenues"]) == (800000, 490000) and r["couverture_garanties"] == pytest.approx(0.8167, abs=1e-3)
    assert r["conforme_garanties"] is False and any("Garanties retenues" in a for a in r["alertes"])
    # score : 93,4 x 35 % + 97,2 x 20 % + 96,7 x 15 % + 100 x 15 % + 100 x 15 % ≈ 96,6 -> favorable
    assert r["sous_scores"] == {"capacite": 93, "endettement": 97, "garanties": 97, "anciennete": 100, "historique": 100}
    assert r["score"] == pytest.approx(96.6, abs=0.3) and r["avis"] == "Favorable" and r["niveau"] == "bon" and r["poids"] == [35, 20, 15, 15, 15]
    # coût : 2 % de frais, TEG au-dessus du taux nominal de 19,56 % (taux effectif annuel du 1,5 %/mois)
    assert r["frais"] == 12000 and r["interets_total"] == pytest.approx(60099, abs=5) and r["cout_total"] == r["interets_total"] + 12000
    assert r["teg"] > 0.2195 and len(r["echeancier_mensuel"]) == 12 and r["echeancier_mensuel"][-1]["solde"] == 0


def test_dettes_en_cours_et_limites():
    dette = [{"libelle": "Crédit ailleurs", "categorie": "dette", "montant": 40000, "periode": "mois"}]
    r = capacite.analyser(**{**BASE, "charges": CHARGES + dette})
    assert r["dettes_en_cours"] == 40000 and r["revenu_disponible"] == 64000
    assert r["taux_endettement"] == pytest.approx((55008 + 40000) / 214000, abs=1e-3)       # 44,4 % > 33 %
    assert r["conforme_endettement"] is False and r["conforme_couverture"] is False and r["conforme"] is False
    assert any("endettement" in a for a in r["alertes"]) and any("Couverture" in a for a in r["alertes"])
    assert r["avis"] != "Favorable"
    # les dettes déjà dues à l'institution s'ajoutent aux dettes saisies
    r2 = capacite.analyser(**{**BASE, "dettes_internes_mensuelles": 20000})
    assert r2["dettes_internes"] == 20000 and r2["dettes_en_cours"] == 20000 and r2["revenu_disponible"] == 84000
    # seuils paramétrables
    large = capacite.analyser(**{**BASE, "charges": CHARGES + dette, "endettement_max_pct": 50, "couverture_min": 1.0})
    assert large["conforme"] is True


def test_regles_de_l_institution_et_avis():
    # plafond du cycle dépassé : un avis favorable passe sous conditions
    r = capacite.analyser(**{**BASE, "cycle": 1})
    assert r["depasse_plafond"] is True and r["avis"] == "Sous conditions" and r["montant_max_conseille"] == 300000
    # historique grave : au mieux risqué ; nouveau client : note de 60 ; caution aucune : alerte
    assert capacite.analyser(**{**BASE, "historique": "grave"})["avis"] == "Risqué"
    assert capacite.analyser(**{**BASE, "historique": "nouveau"})["sous_scores"]["historique"] == 60
    assert any("Aucune caution" in a for a in capacite.analyser(**{**BASE, "caution": "aucune"})["alertes"])
    # couverture inférieure à 1 : défavorable quel que soit le score
    d = capacite.analyser(**{**BASE, "montant": 2000000, "cycle": 5})
    assert d["couverture"] < 1 and d["avis"] == "Défavorable" and d["niveau"] == "mauvais"
    # seuils et pondérations paramétrables : tout le poids sur l'historique, seuil favorable abaissé
    pol = {"poids": [0, 0, 0, 0, 100], "seuils": [90, 55, 35]}
    assert capacite.analyser(**{**BASE, "politique": pol})["score"] == 100.0
    assert capacite.analyser(**{**BASE, "politique": {"poids": [0, 0, 0, 0, 0]}})["poids"] == [35, 20, 15, 15, 15]     # poids nuls : repli sur les poids par défaut
    with pytest.raises(ValueError):
        capacite.analyser(**{**BASE, "caution": "voisin"})
    with pytest.raises(ValueError):
        capacite.analyser(**{**BASE, "historique": "inconnu"})


def test_ventes_saisonnieres():
    # 6 mois à 1 200 000 et 6 mois à 600 000 : moyenne 900 000 ; marge de 33,3 % ; le mois faible garde 200 000 - 196 000...
    ventes = [1200000] * 6 + [600000] * 6
    r = capacite.analyser(**{**BASE, "ventes_mois": ventes})
    assert r["ventes_moyennes"] == 900000 and r["revenu_disponible"] == 104000                     # la moyenne ne change pas l'annuel
    assert r["pire_mois"] == 7 and r["mois"][6]["disponible"] == 600000 / 3 - 86000 - 110000       # 600 000 x 1/3 de marge - charges
    assert r["mois"][6]["apres_charge"] == r["mois"][6]["disponible"] - 55008 and r["nb_mois_defaut"] == 6
    assert any("mois sur 12" in a for a in r["alertes"])
    # la couverture du score est la moyenne de la couverture moyenne et de celle du pire mois
    pire = r["mois"][6]["disponible"] / 55008
    assert r["couverture_effective"] == pytest.approx((1.891 + pire) / 2, abs=2e-3)
    with pytest.raises(ValueError):
        capacite.analyser(**{**BASE, "ventes_mois": [1] * 11})


def test_scenarios_et_groupe():
    r = capacite.analyser(**{**BASE, "scenarios": [
        {"libelle": "Montant réduit", "montant": 400000, "nb_echeances": 12, "taux_annuel": 0.18, "methode": "annuite_constante"},
        {"libelle": "Différé", "montant": 600000, "nb_echeances": 12, "taux_annuel": 0.18, "methode": "capital_constant", "differe": 2}]})
    s = r["scenarios"]
    assert [x["libelle"] for x in s] == ["Montant réduit", "Différé"] and s[0]["charge_mensuelle"] == 36672 and s[1]["charge_mensuelle"] == 69000
    assert sum(1 for x in s if x["meilleur"]) == 1 and max(s, key=lambda x: x["score"])["meilleur"] is True
    g = capacite.analyser_groupe(
        [{"nom": "Membre 1", "montant": 150000, "disponible": 45000}, {"nom": "Membre 2", "montant": 200000, "disponible": 26000},
         {"nom": "Membre 3", "montant": 250000, "disponible": 22000}, {"nom": "Membre 4", "montant": 100000, "disponible": 30000}],
        nb_echeances=12, taux_annuel=0.18, periodicite_jours=30, methode="annuite_constante", cycle=3)
    unite = 55008 / 600000
    assert g["membres"][0]["charge_mensuelle"] == round(150000 * unite) and g["total_montant"] == 700000
    assert [m["niveau"] for m in g["membres"]] == ["bon", "limite", "insuffisant", "bon"]           # couvertures 3,27 / 1,42 / 0,96 / 3,27
    assert g["membres"][2]["couverture"] < 1 and g["couverture_groupe"] == pytest.approx(123000 / (700000 * unite), abs=1e-2)
    assert g["avis"] == "Sous conditions" and any("solidarité" in a for a in g["alertes"])          # le groupe couvre ensemble (1,92 fois) malgré un membre fragile
    assert capacite.analyser_groupe([], nb_echeances=12, taux_annuel=0.18, periodicite_jours=30, methode="capital_constant")["avis"] is None


def test_cas_degeneres():
    sans_revenu = capacite.analyser(**{**BASE, "ventes": 0, "achats": 0})
    assert sans_revenu["taux_endettement"] is None and sans_revenu["conforme"] is False and sans_revenu["montant_max_conseille"] == 0
    assert any("Revenus nuls" in a for a in sans_revenu["alertes"]) and sans_revenu["avis"] == "Défavorable"
    aucune = capacite.analyser(**{**BASE, "charges": []})
    assert any("Aucune charge" in a for a in aucune["alertes"])
    with pytest.raises(ValueError):
        capacite.analyser(**{**BASE, "charges": [{"libelle": "x", "categorie": "autre", "montant": 1, "periode": "mois"}]})
    # remboursement hebdomadaire : 52 échéances de l'année ramenées au mois (30 / 7)
    hebdo = capacite.analyser(**{**BASE, "periodicite_jours": 7, "nb_echeances": 52})
    assert hebdo["charge_mensuelle"] == pytest.approx(hebdo["echeance_periode"] * 30 / 7, abs=2)
    assert capacite.teg_annuel(0, [100], 12) == 0 and capacite.teg_annuel(100, [], 12) == 0
