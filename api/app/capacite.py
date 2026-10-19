"""Analyse de capacité de remboursement : endettement, couverture, saisonnalité, garanties, score, avis, scénarios, groupe solidaire.

Fonctions pures (aucun accès à la base), testées sur le dossier d'exemple de l'outil d'analyse de crédit dont la méthode est reprise :
  revenus            = marge brute - charges d'activité + autres revenus du foyer
  revenu disponible  = revenus - charges du ménage - dettes en cours
  taux d'endettement = (charge mensuelle du nouveau crédit + dettes en cours) / revenus
  couverture         = revenu disponible / charge mensuelle du nouveau crédit
  score              = moyenne pondérée de cinq critères (capacité, endettement, garanties et caution, ancienneté, historique)
Les échéances suivent la convention de la base (generer_echeancier) : taux par période = taux annuel x périodicité en jours / 360 ;
s'y ajoutent le taux plat, l'in fine et le différé de capital, que propose l'outil d'analyse."""
from __future__ import annotations

import math

PERIODES = ("jourouvre", "jour7", "semaine", "mois", "trimestre", "semestre", "an")
CATEGORIES = ("activite", "menage", "dette")
METHODES = ("capital_constant", "annuite_constante", "plat", "infine")
TYPES_GARANTIE = {"terrain": 30, "batiment": 30, "vehicule": 40, "stock": 50, "materiel": 50, "betail": 50, "epargne": 0, "autre": 50}   # décotes indicatives (%)
CAUTIONS = {"aucune": 0, "perso": 15, "groupe": 25}                                                    # points ajoutés au critère garanties
HISTORIQUES = {"nouveau": 60, "bon": 100, "mineur": 45, "grave": 10}                                     # note du critère historique
POLITIQUE_DEFAUT = {
    "max_dti": 33.0, "min_couv": 1.5, "min_gar": 100.0,
    "poids": [35.0, 20.0, 15.0, 15.0, 15.0],            # capacité, endettement, garanties, ancienneté, historique
    "seuils": [75.0, 55.0, 35.0],                       # favorable, sous conditions, risqué
    "plafonds": [300000, 500000, 800000, 1200000, 2000000],   # par cycle de crédit (0 = sans plafond)
}


def _clamp(x: float, a: float, b: float) -> float:
    return min(b, max(a, x))


def charge_mensuelle(montant: float, periode: str, jours_activite: int) -> float:
    """Ramène une charge à son équivalent mensuel : jour travaillé x jours d'activité, jour (7j/7) x 30, semaine x 52 / 12, trimestre / 3, semestre / 6, an / 12."""
    if periode == "jourouvre":
        return montant * jours_activite
    if periode == "jour7":
        return montant * 30
    if periode == "semaine":
        return montant * 52 / 12
    if periode == "trimestre":
        return montant / 3
    if periode == "semestre":
        return montant / 6
    if periode == "an":
        return montant / 12
    if periode == "mois":
        return montant
    raise ValueError(f"période inconnue : {periode}")


def echeancier(montant: float, nb_echeances: int, taux_annuel: float, periodicite_jours: int, methode: str, differe: int = 0) -> list[tuple[float, float]]:
    """Liste (capital, intérêts) de chaque échéance.
    capital_constant / annuite_constante : comme generer_echeancier (intérêts sur le capital restant dû) ; plat : intérêts sur le capital initial ;
    infine : intérêts à chaque échéance, capital à la dernière. `differe` : nombre d'échéances sans remboursement de capital (hors in fine)."""
    if nb_echeances < 1:
        raise ValueError("au moins une échéance")
    if methode not in METHODES:
        raise ValueError(f"méthode inconnue : {methode}")
    i = taux_annuel * periodicite_jours / 360
    dp = 0 if methode == "infine" else min(nb_echeances - 1, max(0, int(differe)))
    na = nb_echeances - dp
    reste = float(montant)
    annuite = None
    if methode == "annuite_constante":
        annuite = montant * i / (1 - (1 + i) ** -na) if i > 0 else montant / na
    out = []
    for k in range(1, nb_echeances + 1):
        if methode == "infine":
            interet, capital = montant * i, (montant if k == nb_echeances else 0.0)
        elif k <= dp:
            interet, capital = reste * i, 0.0
        elif methode == "plat":
            interet, capital = montant * i, montant / na
        elif k == nb_echeances:
            interet, capital = reste * i, reste
        elif annuite is not None:
            interet = reste * i
            capital = min(max(annuite - interet, 0), reste)
        else:
            interet, capital = reste * i, montant / na
        out.append((capital, interet))
        reste = 0.0 if k == nb_echeances else max(0.0, reste - capital)
    return out


def teg_annuel(net: float, flux: list[float], periodes_par_an: float) -> float:
    """Taux effectif global annuel : taux par échéance qui annule la valeur actuelle des flux (net reçu, échéances payées), ramené à l'année."""
    if net <= 0 or not flux:
        return 0.0
    def vp(r: float) -> float:
        v, d, s = 1 / (1 + r), 1.0, net
        for f in flux:
            d *= v
            s -= f * d
        return s
    if vp(0) >= 0:
        return 0.0
    lo, hi = 0.0, 1.0
    for _ in range(70):
        mid = (lo + hi) / 2
        if vp(mid) > 0:
            hi = mid
        else:
            lo = mid
    return (1 + (lo + hi) / 2) ** periodes_par_an - 1


def charge_credit(montant: float, nb_echeances: int, taux_annuel: float, periodicite_jours: int, methode: str, differe: int = 0) -> dict:
    """Échéance de la première période de remboursement du capital (la plus lourde, retenue par prudence), charge mensuelle équivalente et intérêts.
    In fine : intérêt périodique + provision mensuelle de capital (capital / durée en mois)."""
    lignes = echeancier(montant, nb_echeances, taux_annuel, periodicite_jours, methode, differe)
    par_mois = 30 / periodicite_jours
    dp = 0 if methode == "infine" else min(nb_echeances - 1, max(0, int(differe)))
    premiere = lignes[min(len(lignes) - 1, dp)]
    echeance = premiere[0] + premiere[1]
    if methode == "infine":
        mensuelle = montant * (taux_annuel * periodicite_jours / 360) * par_mois + montant / (nb_echeances / par_mois)
    else:
        mensuelle = echeance * par_mois
    mois: list[dict] = []
    for k, (cap, intr) in enumerate(lignes, start=1):
        m = max(1, math.ceil(k / par_mois - 1e-9))
        if not mois or mois[-1]["mois"] != m:
            mois.append({"mois": m, "a_payer": 0.0, "capital": 0.0, "interets": 0.0})
        mois[-1]["a_payer"] += cap + intr
        mois[-1]["capital"] += cap
        mois[-1]["interets"] += intr
    solde = float(montant)
    for m in mois:
        solde = max(0.0, solde - m["capital"])
        m["solde"] = round(solde)
        for c in ("a_payer", "capital", "interets"):
            m[c] = round(m[c])
    return {"echeance": echeance, "mensuelle": mensuelle, "interets": sum(i for _, i in lignes), "flux": [c + i for c, i in lignes], "mois": mois}


def totaux_garanties(garanties: list[dict]) -> tuple[float, float]:
    """(valeur estimée, valeur retenue après décote) : la décote traduit ce que l'institution récupère réellement en cas de vente forcée."""
    brute = retenue = 0.0
    for g in garanties:
        v = float(g.get("valeur", 0))
        d = _clamp(float(g.get("decote", TYPES_GARANTIE.get(g.get("type", "autre"), 50))), 0, 100)
        brute += v
        retenue += v * (1 - d / 100)
    return brute, retenue


def _politique(p: dict | None, max_dti: float | None, couv_min: float | None) -> dict:
    pol = {**POLITIQUE_DEFAUT, **(p or {})}
    if max_dti is not None:
        pol["max_dti"] = max_dti
    if couv_min is not None:
        pol["min_couv"] = couv_min
    pol["max_dti"] = _clamp(float(pol["max_dti"]), 5, 100)
    pol["min_couv"] = max(1.05, float(pol["min_couv"]))
    return pol


def analyser(*, montant: float, nb_echeances: int, taux_annuel: float, periodicite_jours: int, methode: str,
             ventes: float, achats: float, autres_revenus: float, jours_activite: int, charges: list[dict],
             dettes_internes_mensuelles: float = 0.0, endettement_max_pct: float | None = None, couverture_min: float | None = None,
             differe: int = 0, frais_pct: float = 0.0, anciennete_mois: int = 0, cycle: int = 1, caution: str = "perso", historique: str = "bon",
             garanties: list[dict] | None = None, ventes_mois: list[float] | None = None, politique: dict | None = None, scenarios: list[dict] | None = None) -> dict:
    """Calcule l'analyse complète. `charges` : [{libelle, categorie (activite|menage|dette), montant, periode}] ;
    `garanties` : [{libelle, type, valeur, decote}] ; `ventes_mois` : les 12 mois de ventes si l'activité est saisonnière ;
    `dettes_internes_mensuelles` : remboursements déjà dus à l'institution, ajoutés aux dettes en cours."""
    pol = _politique(politique, endettement_max_pct, couverture_min)
    max_dti, min_couv = pol["max_dti"] / 100, pol["min_couv"]
    tot = {c: 0.0 for c in CATEGORIES}
    for ch in charges:
        if ch["categorie"] not in tot:
            raise ValueError(f"catégorie inconnue : {ch['categorie']}")
        tot[ch["categorie"]] += charge_mensuelle(float(ch["montant"]), ch["periode"], jours_activite)
    if caution not in CAUTIONS:
        raise ValueError(f"caution inconnue : {caution}")
    if historique not in HISTORIQUES:
        raise ValueError(f"historique inconnu : {historique}")
    if ventes_mois is not None:
        if len(ventes_mois) != 12:
            raise ValueError("les ventes par mois comptent 12 valeurs")
        ventes = sum(ventes_mois) / 12
    marge_brute = ventes - achats
    taux_marge = marge_brute / ventes if ventes > 0 else 0.0
    excedent = marge_brute - tot["activite"]
    revenus = excedent + autres_revenus
    dettes = tot["dette"] + dettes_internes_mensuelles
    disponible = revenus - tot["menage"] - dettes
    cr = charge_credit(montant, nb_echeances, taux_annuel, periodicite_jours, methode, differe)
    pay = cr["mensuelle"]
    frais = montant * frais_pct / 100
    taux_endettement = (pay + dettes) / revenus if revenus > 0 else None
    couverture = disponible / pay if pay > 0 else None
    surplus = disponible - pay
    # saisonnalité : couverture de chaque mois, mois le plus faible ; dans le score, moyenne de la couverture moyenne et de celle du pire mois
    couv_eff = couverture
    mois = None
    pire = None
    if ventes_mois is not None:
        mois = []
        for v in ventes_mois:
            marge = v * taux_marge
            dispo = marge - tot["activite"] + autres_revenus - tot["menage"] - dettes
            mois.append({"ventes": round(v), "disponible": round(dispo), "apres_charge": round(dispo - pay)})
        pire = min(range(12), key=lambda k: mois[k]["disponible"])
        couv_pire = mois[pire]["disponible"] / pay if pay > 0 else None
        if couverture is not None and couv_pire is not None:
            couv_eff = (couverture + couv_pire) / 2
    # garanties, plafond du cycle
    g_brute, g_retenue = totaux_garanties(garanties or [])
    couv_gar = g_retenue / montant if montant > 0 else 0.0
    plafond = float(pol["plafonds"][_clamp(int(cycle), 1, 5) - 1] or 0)
    depasse_plafond = plafond > 0 and montant > plafond
    # score sur 100
    c = couv_eff if couv_eff is not None else float("inf")
    s_couv = 0.0 if c <= 1 else (c - 1) / (min_couv - 1) * 70 if c <= min_couv else min(100.0, 70 + (c - min_couv) / 0.5 * 30)
    base = max_dti * 0.75758
    dti_val = taux_endettement if taux_endettement is not None else float("inf")
    s_dti = 100 * _clamp(1 - (dti_val - base) / base, 0, 1) if dti_val != float("inf") else 0.0
    s_gar = _clamp(100 * _clamp(couv_gar / (pol["min_gar"] / 100), 0, 1) + CAUTIONS[caution], 0, 100)
    s_anc = 10 + 90 * _clamp(anciennete_mois / 24, 0, 1)
    s_hist = float(HISTORIQUES[historique])
    poids = [float(w) for w in pol["poids"]]
    somme = sum(poids)
    if not somme > 0:
        poids, somme = list(POLITIQUE_DEFAUT["poids"]), 100.0
    score = (s_couv * poids[0] + s_dti * poids[1] + s_gar * poids[2] + s_anc * poids[3] + s_hist * poids[4]) / somme
    # montant maximal défendable
    unite = charge_credit(1_000_000, nb_echeances, taux_annuel, periodicite_jours, methode, differe)["mensuelle"] / 1_000_000
    pay_max = max(0.0, min(disponible / min_couv, max_dti * revenus - dettes))
    montant_max = pay_max / unite if revenus > 0 and unite > 0 else 0.0
    montant_conseille = min(montant_max, plafond) if plafond > 0 else montant_max
    # avis
    t = pol["seuils"]
    if score >= t[0]:
        niveau, avis = "bon", "Favorable"
    elif score >= t[1]:
        niveau, avis = "moyen", "Sous conditions"
    elif score >= t[2]:
        niveau, avis = "moyen", "Risqué"
    else:
        niveau, avis = "mauvais", "Défavorable"
    if historique == "grave" and avis in ("Favorable", "Sous conditions"):
        niveau, avis = "moyen", "Risqué"
    if depasse_plafond and avis == "Favorable":
        niveau, avis = "moyen", "Sous conditions"
    if couverture is not None and couverture < 1:
        niveau, avis = "mauvais", "Défavorable"
    ok_dti = taux_endettement is not None and taux_endettement <= max_dti
    ok_couv = couverture is not None and couverture >= min_couv
    ok_gar = couv_gar * 100 >= pol["min_gar"]
    alertes = []
    if revenus <= 0:
        alertes.append("Revenus nuls ou négatifs : aucune échéance n'est supportable.")
    elif not ok_dti:
        alertes.append(f"Taux d'endettement de {taux_endettement * 100:.1f} % au-dessus du maximum de {pol['max_dti']:g} %.")
    if disponible <= 0:
        alertes.append("Revenu disponible nul ou négatif avant le nouveau crédit.")
    elif not ok_couv:
        alertes.append(f"Couverture de l'échéance de {couverture:.2f} fois, sous le minimum de {min_couv:g}.")
    if mois is not None:
        nb_def = sum(1 for m in mois if m["apres_charge"] < 0)
        if nb_def:
            alertes.append(f"La charge de remboursement n'est pas couverte pendant {nb_def} mois sur 12 (mois le plus faible : mois {pire + 1}, revenu disponible {mois[pire]['disponible']} F).")
    if not ok_gar:
        alertes.append(f"Garanties retenues après décote à {couv_gar * 100:.0f} % du crédit, sous le minimum de {pol['min_gar']:g} %.")
    if caution == "aucune":
        alertes.append("Aucune caution : envisager une caution personnelle ou un groupe solidaire.")
    if historique == "grave":
        alertes.append("Historique d'impayés ou de contentieux : vérifier auprès de la centrale des risques et exiger un règlement préalable.")
    elif historique == "mineur":
        alertes.append("Retards occasionnels sur des crédits passés : analyser leur cause avant décaissement.")
    if anciennete_mois < 6:
        alertes.append("Activité de moins de 6 mois : les revenus déclarés sont peu vérifiables.")
    if depasse_plafond:
        alertes.append(f"Le montant demandé dépasse le plafond du cycle {cycle} ({round(plafond)} F).")
    if methode == "infine":
        alertes.append(f"Crédit in fine : {round(montant)} F de capital à rembourser en une fois à la dernière échéance ; une provision mensuelle de capital est retenue dans la charge.")
    elif differe > 0:
        alertes.append(f"Différé de capital de {differe} échéance(s) : seuls les intérêts sont payés au début.")
    if montant > montant_conseille > 0:
        alertes.append(f"Le montant demandé dépasse le montant conseillé de {round(montant_conseille)} F.")
    if achats > ventes > 0:
        alertes.append("Le coût d'achat dépasse les ventes : revoir les chiffres de l'activité.")
    if not charges:
        alertes.append("Aucune charge saisie : le revenu disponible est probablement surestimé.")
    res = {
        "marge_brute": round(marge_brute), "ventes_moyennes": round(ventes), "charges_activite": round(tot["activite"]), "charges_menage": round(tot["menage"]),
        "dettes_externes": round(tot["dette"]), "dettes_internes": round(dettes_internes_mensuelles), "dettes_en_cours": round(dettes),
        "excedent_activite": round(excedent), "revenus": round(revenus), "revenu_disponible": round(disponible),
        "echeance_periode": round(cr["echeance"]), "charge_mensuelle": round(pay), "interets_total": round(cr["interets"]),
        "frais": round(frais), "cout_total": round(cr["interets"] + frais), "total_a_rembourser": round(montant + cr["interets"]),
        "teg": round(teg_annuel(montant - frais, cr["flux"], 360 / periodicite_jours), 4),
        "mise_journaliere": round(pay / jours_activite) if jours_activite else 0,
        "taux_endettement": round(taux_endettement, 4) if taux_endettement is not None else None,
        "couverture": round(couverture, 3) if couverture is not None else None,
        "couverture_effective": round(couv_eff, 3) if couv_eff is not None else None,
        "surplus": round(surplus),
        "baisse_ventes_tolere": round(_clamp(surplus / marge_brute, 0, 1), 4) if marge_brute > 0 else 0.0,
        "montant_max_conseille": round(montant_conseille), "charge_max": round(pay_max), "plafond_cycle": round(plafond), "depasse_plafond": depasse_plafond,
        "garanties_brutes": round(g_brute), "garanties_retenues": round(g_retenue), "couverture_garanties": round(couv_gar, 4),
        "score": round(score, 1), "avis": avis, "niveau": niveau,
        "sous_scores": {"capacite": round(s_couv), "endettement": round(s_dti), "garanties": round(s_gar), "anciennete": round(s_anc), "historique": round(s_hist)},
        "poids": [round(w / somme * 100) for w in poids],
        "mois": mois, "pire_mois": (pire + 1) if pire is not None else None,
        "nb_mois_defaut": sum(1 for m in mois if m["apres_charge"] < 0) if mois is not None else 0,
        "echeancier_mensuel": cr["mois"],
        "endettement_max_pct": pol["max_dti"], "couverture_min": min_couv, "garantie_min_pct": pol["min_gar"],
        "conforme_endettement": ok_dti, "conforme_couverture": ok_couv, "conforme_garanties": ok_gar, "conforme": ok_dti and ok_couv,
        "alertes": alertes,
    }
    if scenarios:
        res["scenarios"] = comparer(dict(montant=montant, nb_echeances=nb_echeances, taux_annuel=taux_annuel, periodicite_jours=periodicite_jours, methode=methode,
                                        ventes=ventes, achats=achats, autres_revenus=autres_revenus, jours_activite=jours_activite, charges=charges,
                                        dettes_internes_mensuelles=dettes_internes_mensuelles, differe=differe, frais_pct=frais_pct, anciennete_mois=anciennete_mois,
                                        cycle=cycle, caution=caution, historique=historique, garanties=garanties, ventes_mois=ventes_mois, politique=pol), scenarios)
    return res


RESUME_SCENARIO = ("charge_mensuelle", "mise_journaliere", "taux_endettement", "couverture", "baisse_ventes_tolere", "teg", "cout_total", "score", "avis", "niveau", "conforme")


def comparer(base: dict, scenarios: list[dict]) -> list[dict]:
    """Compare des conditions de crédit pour le même client : chaque scénario ne change que montant, nombre d'échéances, taux, mode et différé."""
    out = []
    for s in scenarios:
        r = analyser(**{**base, "montant": float(s["montant"]), "nb_echeances": int(s["nb_echeances"]), "taux_annuel": float(s["taux_annuel"]),
                        "methode": s["methode"], "differe": int(s.get("differe", 0))})
        out.append({"libelle": s.get("libelle", ""), "montant": s["montant"], "nb_echeances": s["nb_echeances"], "taux_annuel": s["taux_annuel"],
                    "methode": s["methode"], "differe": int(s.get("differe", 0)), **{k: r[k] for k in RESUME_SCENARIO}})
    meilleur = max(range(len(out)), key=lambda k: out[k]["score"]) if out else None
    for k, s in enumerate(out):
        s["meilleur"] = k == meilleur
    return out


def analyser_groupe(membres: list[dict], *, nb_echeances: int, taux_annuel: float, periodicite_jours: int, methode: str, differe: int = 0,
                    cycle: int = 1, politique: dict | None = None) -> dict:
    """Crédit à un groupe solidaire : chaque membre est évalué aux conditions du dossier ; avis du groupe selon les membres et la couverture globale.
    Membre : {nom, montant, disponible} où `disponible` est son revenu disponible mensuel avant la nouvelle échéance."""
    pol = _politique(politique, None, None)
    min_couv = pol["min_couv"]
    unite = charge_credit(1_000_000, nb_echeances, taux_annuel, periodicite_jours, methode, differe)["mensuelle"] / 1_000_000
    plafond = float(pol["plafonds"][_clamp(int(cycle), 1, 5) - 1] or 0)
    g = {"total_montant": 0.0, "total_charge": 0.0, "total_disponible": 0.0, "insuffisants": 0, "limites": 0, "hors_plafond": 0}
    liste = []
    for m in membres:
        montant, dispo = float(m["montant"]), float(m["disponible"])
        pay = montant * unite
        cov = dispo / pay if pay > 0 else None
        niveau = "bon" if (cov is None or cov >= min_couv) else "limite" if cov >= 1 else "insuffisant"
        hors = plafond > 0 and montant > plafond
        g["total_montant"] += montant
        g["total_charge"] += pay
        g["total_disponible"] += dispo
        g["insuffisants"] += niveau == "insuffisant"
        g["limites"] += niveau == "limite"
        g["hors_plafond"] += hors
        liste.append({"nom": m.get("nom", ""), "montant": round(montant), "disponible": round(dispo), "charge_mensuelle": round(pay),
                      "couverture": round(cov, 3) if cov is not None else None, "montant_max": round(max(0.0, dispo) / min_couv / unite) if unite > 0 else 0,
                      "niveau": niveau, "hors_plafond": hors})
    cov_g = g["total_disponible"] / g["total_charge"] if g["total_charge"] > 0 else None
    if not liste:
        avis = None
    elif g["insuffisants"] == 0 and g["limites"] == 0 and g["hors_plafond"] == 0:
        avis = "Favorable"
    elif cov_g is None or cov_g >= min_couv:
        avis = "Sous conditions"
    elif cov_g >= 1:
        avis = "Risqué"
    else:
        avis = "Défavorable"
    alertes = []
    for m in liste:
        if m["niveau"] == "insuffisant":
            alertes.append(f"{m['nom'] or 'Membre'} : couverture de {m['couverture']:.2f} fois, sous 1. Montant compatible avec le seuil : {m['montant_max']} F.")
        elif m["niveau"] == "limite":
            alertes.append(f"{m['nom'] or 'Membre'} : couverture de {m['couverture']:.2f} fois, sous le minimum de {min_couv:g}. Montant compatible avec le seuil : {m['montant_max']} F.")
        if m["hors_plafond"]:
            alertes.append(f"{m['nom'] or 'Membre'} : le montant dépasse le plafond du cycle ({round(plafond)} F).")
    if cov_g is not None and cov_g >= min_couv and (g["insuffisants"] + g["limites"]) > 0:
        alertes.append(f"La couverture du groupe ({cov_g:.2f} fois) atteint le seuil grâce à la solidarité : le groupe répond des membres fragiles.")
    elif cov_g is not None and cov_g < 1:
        alertes.append("Le revenu disponible total du groupe ne couvre pas la charge totale de remboursement.")
    return {"membres": liste, "total_montant": round(g["total_montant"]), "total_charge": round(g["total_charge"]), "total_disponible": round(g["total_disponible"]),
            "couverture_groupe": round(cov_g, 3) if cov_g is not None else None, "avis": avis, "alertes": alertes, "plafond_cycle": round(plafond)}
