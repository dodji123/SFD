"""Jeu de données de démonstration (développement uniquement) : agence de Lomé, utilisateurs par rôle,
clients, comptes, cycles de tontine avec collecte récente, un crédit, une caisse ouverte.
Mot de passe de tous les comptes de démonstration : variable SFD_DEMO_PASSWORD ou « Demo-Passe-2026! »."""
import datetime as dt
import os

from .auth import hash_password
from .cli import connect

DEMO_PASSWORD = os.environ.get("SFD_DEMO_PASSWORD", "Demo-Passe-2026!")


def reseau_et_comite(cur, lom: int, h: str) -> None:
    """Réseau « Sud » (agence de Lomé), son coordinateur, et le comité de crédit de Lomé avec ses membres."""
    cur.execute("INSERT INTO reseau(code, libelle) VALUES ('SUD', 'Réseau Sud') RETURNING id")
    reseau = cur.fetchone()[0]
    cur.execute("UPDATE agence SET reseau_id = %s WHERE id = %s", (reseau, lom))
    cur.execute("INSERT INTO utilisateur(login, nom, role, reseau_id, mot_de_passe_hash, email) "
                "VALUES ('coord.sud', 'Coordinateur du réseau Sud', 'coordinateur', %s, %s, 'coord.sud@demo.tg')", (reseau, h))
    cur.execute("INSERT INTO comite_credit(code, libelle, agence_id, montant_min, montant_max, quorum) "
                "VALUES ('LOM', 'Comité de crédit de Lomé', %s, 0, 1000000, 3) RETURNING id", (lom,))
    comite = cur.fetchone()[0]
    for login, fonction in (("chef.lom", "president"), ("caissier.lom", "secretaire"), ("agent.lom", "membre"), ("rh.lom", "membre")):
        cur.execute("INSERT INTO comite_membre(comite_id, utilisateur_id, fonction) SELECT %s, id, %s FROM utilisateur WHERE login = %s",
                    (comite, fonction, login))


def charger() -> None:
    conn = connect()
    conn.autocommit = False
    cur = conn.cursor()
    cur.execute("SELECT count(*) FROM agence")
    if cur.fetchone()[0]:
        raise SystemExit("La base contient déjà des agences : données de démonstration non chargées.")
    today = dt.date.today()
    an = today.year

    cur.execute("INSERT INTO agence(code, libelle, siege) VALUES ('LOM', 'Lomé Centre', true) RETURNING id")
    lom = cur.fetchone()[0]
    cur.execute("INSERT INTO agence(code, libelle) VALUES ('KPA', 'Kpalimé') RETURNING id")
    cur.execute("INSERT INTO exercice_comptable(code, date_debut, date_fin) VALUES (%s, %s, %s)", (str(an), f"{an}-01-01", f"{an}-12-31"))

    cur.execute("INSERT INTO zone(agence_id, code, libelle) VALUES (%s, 'Z1', 'Grand Marché'), (%s, 'Z2', 'Bè Kpota') RETURNING id", (lom, lom))
    zones = [r[0] for r in cur.fetchall()]
    cur.execute("INSERT INTO agent(agence_id, matricule, nom) VALUES (%s,'A01','Ama Koffi'),(%s,'A02','Kodjo Mensah'),(%s,'A03','Afi Adjovi') RETURNING id", (lom,) * 3)
    agents = [r[0] for r in cur.fetchall()]
    cur.execute("INSERT INTO collectrice(agence_id, matricule, nom, agent_id) VALUES (%s,'K01','Ama Koffi',%s) RETURNING id", (lom, agents[0]))
    coll = cur.fetchone()[0]
    cur.execute("INSERT INTO affectation_zone(zone_id, collectrice_id, date_debut) VALUES (%s, %s, %s)", (zones[0], coll, f"{an}-01-01"))

    h = hash_password(DEMO_PASSWORD)
    for login, nom, role, ag, ag_id in [
        ("admin", "Administrateur", "admin", None, None), ("directeur", "Directeur", "directeur", None, None),
        ("comptable", "Comptable", "comptable", None, None), ("auditeur", "Auditeur", "auditeur", None, None),
        ("chef.lom", "Chef d'agence Lomé", "chef_agence", lom, None), ("caissier.lom", "Caissier Lomé", "caissier", lom, None),
        ("agent.lom", "Ama Koffi", "agent", lom, agents[0]), ("rh.lom", "RH Lomé", "rh", lom, None),
    ]:
        cur.execute("INSERT INTO utilisateur(login, nom, role, agence_id, agent_id, mot_de_passe_hash, email) VALUES (%s,%s,%s::role_utilisateur,%s,%s,%s,%s)",
                    (login, nom, role, ag, ag_id, h, f"{login}@demo.tg"))
    reseau_et_comite(cur, lom, h)

    cur.execute("INSERT INTO produit_epargne(code, libelle, categorie, type_cycle) VALUES ('TON1','Tontine normale','collecte',1),('TON3','Tontine libre','collecte',3) RETURNING id")
    ton1, ton3 = [r[0] for r in cur.fetchall()]
    cur.execute("INSERT INTO produit_epargne(code, libelle, categorie, taux_interet, solde_minimum) VALUES ('EPG','Épargne classique','classique',0.02,5000) RETURNING id")
    epg = cur.fetchone()[0]
    cur.execute("INSERT INTO produit_credit_epargne(code, libelle, type, taux_annuel, frais_dossier_taux) VALUES "
                "('CRE1','Crédit sur épargne','sur_epargne',0.12,0.01),('CRS1','Crédit sans épargne','sans_epargne',0.18,0.02)")

    noms = ["Akouvi Mensah", "Kossi Agbodjan", "Efua Tchalla", "Yawo Amegah", "Abla Dogbe", "Komi Lawson",
            "Adjoa Kpodar", "Mawuli Sodji", "Ayaovi Fiawoo", "Dede Hounkpati", "Selom Atsou", "Sena Gbadamassi"]
    clients = []
    for i, nom in enumerate(noms):
        cur.execute("INSERT INTO client(agence_id, zone_id, numero, nom, telephone) VALUES (%s,%s,NULL,%s,%s) RETURNING id",
                    (lom, zones[i % 2], nom, f"9{i:07d}"))
        clients.append(cur.fetchone()[0])
    comptes = []
    for cid in clients[:6]:
        cur.execute("INSERT INTO compte_epargne(agence_id, client_id, produit_id, numero) VALUES (%s,%s,%s,NULL) RETURNING id", (lom, cid, epg))
        comptes.append(cur.fetchone()[0])
        cur.execute("INSERT INTO mouvement_epargne(compte_id, type, montant, date_operation) VALUES (%s,'depot',%s,%s)",
                    (comptes[-1], 50000 + 10000 * len(comptes), today - dt.timedelta(days=40)))

    debut = today - dt.timedelta(days=12)
    for i, cid in enumerate(clients):
        mise = [500, 1000, 1000, 2000][i % 4]
        cur.execute("INSERT INTO cycle(agence_id, numero, client_id, produit_id, type_cycle, mise_initiale, mise_courante, objectif, date_debut, date_fin) "
                    "VALUES (%s,NULL,%s,%s,1,%s,%s,%s,%s,%s) RETURNING id", (lom, cid, ton1, mise, mise, mise * 31, debut, debut + dt.timedelta(days=30)))
        cy = cur.fetchone()[0]
        for j in range(11):
            if (i + j) % 6 == 0:
                continue           # jours sans collecte
            cur.execute("INSERT INTO ligne_collecte(cycle_id, page, no_ligne, date_collecte, agent_id, montant_collecte) "
                        "SELECT %s, 1, COALESCE(max(no_ligne), 0) + 1, %s, %s, %s FROM ligne_collecte WHERE cycle_id = %s",
                        (cy, debut + dt.timedelta(days=j), agents[i % 3], mise, cy))

    # un crédit sur épargne débloqué sur le compte du premier client
    cur.execute("SELECT nouvelle_demande_credit(%s, %s, (SELECT id FROM produit_credit_epargne WHERE code='CRE1'), 30000, 3, NULL, 20000, 'prelevement_compte', 'démo')", (clients[0], comptes[0]))
    did = cur.fetchone()[0]
    cur.execute("SELECT approuver_demande(%s, NULL, true, 'démo')", (did,))
    cur.execute("SELECT debloquer_credit(%s, %s, 'compte')", (did, today - dt.timedelta(days=20)))
    # un crédit en espèces avec une échéance dépassée
    cur.execute("INSERT INTO caisse(agence_id, code, type) VALUES (%s,'CP','principale') RETURNING id", (lom,))
    caisse = cur.fetchone()[0]
    cur.execute("INSERT INTO session_caisse(caisse_id, date_session, solde_ouverture) VALUES (%s,%s,500000) RETURNING id", (caisse, today))
    sess = cur.fetchone()[0]
    cur.execute("SELECT nouvelle_demande_credit(%s, NULL, (SELECT id FROM produit_credit_epargne WHERE code='CRS1'), 60000, 4, NULL, 0, 'especes', 'démo')", (clients[7],))
    did2 = cur.fetchone()[0]
    cur.execute("SELECT approuver_demande(%s, NULL, true, 'démo')", (did2,))
    cur.execute("SELECT debloquer_credit(%s, %s, 'especes', %s)", (did2, today - dt.timedelta(days=45), sess))
    cur.execute("SELECT maj_statuts_credit(%s::smallint, %s)", (lom, today))
    conn.commit()
    print("données de démonstration chargées. Comptes :")
    for login in ("admin", "directeur", "comptable", "auditeur", "chef.lom", "caissier.lom", "agent.lom", "rh.lom", "coord.sud"):
        print(f"  {login}")
    print("Mot de passe : valeur de SFD_DEMO_PASSWORD (par défaut Demo-Passe-2026!)")
