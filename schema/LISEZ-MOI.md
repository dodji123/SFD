# Schéma `mf` — plateforme de gestion intégrée des SFD (UMOA)

Reconstruit à partir de `BRIEF_CLAUDE_CODE (1).md` et du script `tests_virement_credit.sql` (les fichiers SQL d'origine n'étaient pas disponibles).
PostgreSQL 16 (testé), extension `btree_gist`. **296 assertions automatiques passent** (une base vierge par fichier de test).

## Contenu

| Fichier | Rôle |
|---|---|
| `00_noyau.sql` | agences, utilisateurs, zones, agents, collectrices, affectations sans chevauchement, `parametre` + `param()`, `audit_log` |
| `01_epargne_collecte.sql` | clients, produits, comptes et mouvements d'épargne, cycles (types 1, 2, 3), historique des mises, livret (31 lignes/page), arrondi, clôture, demande de retrait, production de collectrice |
| `02_ecarts.sql` | compte agent, versements de tournée, surplus, écarts de retrait (livret > machine / machine > livret), excédents à régulariser, purge de date, exécution des retraits |
| `03_credit_caisse.sql` | crédits, échéanciers, imputation capital → intérêts → pénalités, retard et points de fidélité, remboursement par seuil sur tontine, caisse |
| `04_rh.sql` | employés, contrats, congés, présences, rubriques et bulletins de paie, avances, commission de collectrice |
| `05_comptabilite.sql` + `05_plan_comptable_data.sql` | exercices, plan SFD UMOA (1 440 comptes), pièces et écritures équilibrées, règles, balance, grand livre, numérotation auto |
| `07_virement.sql` | virements tontine ↔ épargne classique |
| `08_credit_epargne.sql` | produits, demandes, garantie bloquée, déblocage, prélèvement, saisie de garantie, espèces |
| `09_rapports.sql` | rapport journalier (global, agent, zone), remboursements échus / à venir, situation des crédits |
| `10_comptabilisation_audit.sql` | comptabilisation automatique (désactivée par défaut) et piste d'audit |
| `11_auth.sql` | comptes utilisateurs de l'API (mot de passe haché, verrouillage) |
| `12_planificateur.sql` | journal d'exécution des traitements quotidiens (`execution_tache`) |
| `13_tresorerie.sql` | plusieurs caisses par agence, ouverture avec continuité du solde, transferts entre caisses, comptes bancaires, position et prévision de trésorerie |
| `14_rapports_credit_financier.sql` | portefeuille à une date, PAR 1/30/60/90 jours, retards par tranche, activité de crédit, rapport financier de période, bilan simplifié |
| `15_transferts_clients.sql` | transfert de client entre zones (historique : la zone compte à la date de l'opération) et entre agences |
| `16_etats_financiers.sql` | états financiers issus des écritures : compte de résultat par agence, bilan par agence, synthèse avec contrôle d'équilibre ; la consolidation du réseau est la somme des agences |
| `17_kyc_lbc.sql` | KYC (type de client, pièces, liens, garants), listes de surveillance, filtrage des noms, alertes LBC/FT, blocage du crédit |
| `18_espace_client.sql` | consentements, accès à l'espace client (PIN + code SMS), journaux en ajout seul, file des SMS |
| `19_etats_reglementaires.sql` + `19_postes_data.sql` | états financiers par postes du référentiel comptable des SFD de l'UMOA (bilan, hors-bilan, compte de résultat). Les données (446 postes, 1 143 lignes de concordance avec le plan) sont générées par `tools/extraire_postes.py` à partir du PDF |
| `20_ratios_prudentiels.sql` | ratios prudentiels I à IX du guide d'audit externe, seuils paramétrables, saisies complémentaires datées, historique des ratios |
| `21_provisions.sql` | classification des créances par ancienneté de l'impayé, provisions réglementaires (40/80/100 %) et règle interne plus stricte, pièces de dotation et de reprise |
| `22_rapprochement.sql` | rapprochement des fiches (crédits sains, crédits en souffrance, provisions, épargne) avec la comptabilité, tolérance paramétrable, validation par le comptable, état par agence avant consolidation |
| `23_validation_collecte.sql` | zone ↔ agent responsable, correction (modification, suppression) des lignes de collecte tant que la journée n'est pas validée, validation globale de la journée par agence (verrou) et réouverture tracée |
| `24_adhesion_parts.sql` | adhésion des membres (droit d'adhésion), souscription de parts sociales (valeur nominale figée à la souscription), membre en règle ; paramètres `part_valeur_nominale`, `parts_minimum`, `droit_adhesion`, `adhesion_obligatoire` |
| `25_liaison_tontine_epargne.sql` | mise en relation d'une souscription de tontine (cycle) avec le compte d'épargne classique du même client |
| `26_epargne_journee_sortie.sql` | annulation d'un dépôt ou retrait par contre-passation, validation globale de la journée d'épargne (réouverture tracée), sortie d'un membre avec remboursement des parts |
| `27_adhesion_par_compte.sql` | chaque compte d'épargne a sa propre adhésion et sa souscription de parts : ouverture du compte avec adhésion et parts en une opération, adhésion et parts supplémentaires par compte, sortie du compte (parts remboursées, compte clos) ; remplace les fonctions par client des modules 24 et 26 |
| `mf_schema_complet.sql` | concaténation de tout, générée par `tools/build_schema_complet.sh` |

À la racine de `SFD`, le fichier `mf_schema_complet.sql` est une copie de `tests_virement_credit.sql` (même taille, même contenu) : **le vrai schéma est `schema/mf_schema_complet.sql`**.

## Lancer

```bash
# base de test (conteneur Docker déjà créé : sfd-pg, port 5440)
bash schema/tools/run_tests.sh          # tous les tests ; code retour 1 au premier écart
bash schema/tools/run_tests.sh 03       # un seul module
bash schema/tools/build_schema_complet.sh
psql -v ON_ERROR_STOP=1 -f schema/mf_schema_complet.sql
```

Ton script d'origine passe aussi tel quel et donne les valeurs de ses commentaires (voir `tests/test_07_08_virement_credit.sql`, sa version avec assertions).

## Interprétations à valider (je n'ai pas pu les confirmer auprès du client)

**Déduites de tes valeurs chiffrées** (donc probables) : pénalité = capital de l'échéance × 0,001 × jours ; points : +10 à temps, −2 par tranche de 5 jours de retard entamée ; saisie de garantie quand le retard dépasse strictement 30 jours ; intérêt = capital restant × taux × jours / 360 ; frais de dossier prélevés sur le compte à la date de déblocage.

**Valeurs provisoires** (table `parametre`) : `taux_commission` 0,02 ; `plafond_retenue` 0,5 ; `penalite_plafond` 10 % de l'échéance ; `points_credit_solde` 20 ; `seuil_validation_credit` quasi désactivé.

**Choix de ma part** :
1. **Production de collectrice** (commission) : somme des mises appliquées des lignes de *collecte* (les virements, sans agent, sont exclus) ; pour un cycle de type 3, le montant collecté. Mode `calendaire_mensuel` : cycles clôturés dans la période, attribués à la collectrice de la zone à la date de clôture. Le brief dit « le code compte le montant collecté, la règle dit les mises » : j'ai appliqué la règle (les mises).
2. **Remboursement sur tontine** : se déclenche dès que le collecté du cycle, net des remboursements déjà réservés, atteint le dû de l'échéance suivante, même avant sa date d'échéance. La date d'atteinte est celle de la ligne qui franchit le seuil.
3. **Surplus** : ne couvre une perte de retrait que pour le même agent et la même date.
4. **Montant machine** d'un écart de retrait : doit être égal au collecté du cycle (sinon refus).
5. **Écriture comptable** : comptes proposés en tête de `10_comptabilisation_audit.sql` (tontine en 25391, épargne en 25111, tous les crédits en 202211 quelle que soit la durée…). **À faire valider par le comptable** avant d'activer `comptabilisation_auto`.
6. **Plan de comptes** extrait d'un PDF : aucun doublon, aucune ligne oubliée, mais les libellés n'ont pas été relus un par un. Pas de classe 8 (absente du référentiel).
7. **Paie** : aucune rubrique préchargée (taux de cotisations et d'impôt non fournis). Pas de retenue pour absence. Retenue d'avance = tout le restant dû dans la limite du net.
8. **Prélèvement automatique** : dû complet seulement ; la date de référence est celle passée à la fonction (la lancer chaque jour).
9. **Transfert d'agence** : aucune écriture comptable inter-agences n'est passée. Le solde d'épargne déplacé est conservé dans `client_transfert.solde_epargne` pour le règlement par le comptable (compte de liaison). Les cycles retirés, crédits soldés et pièces restent rattachés à l'agence d'origine. Refusé si le client a un cycle non retiré, un retrait en cours, un crédit non soldé, une demande de crédit en attente ou une garantie bloquée.
10. **Rapport financier et bilan** : documents de travail issus des opérations, pas des états réglementaires (intérêts servis sur l'épargne, provisions et amortissements non inclus).
11. **États financiers** : soldes par compte de niveau 2 (somme signée débit - crédit), documents de travail et non états réglementaires BCEAO. Le bilan est cumulé jusqu'à la date de fin et ajoute le résultat cumulé (ligne RES) ; il n'y a pas d'à-nouveaux de clôture d'exercice. Consolidé = somme des agences, sans élimination inter-agences (aucune n'est passée).

## Pas fait

- API et interface (pile proposée par le brief : FastAPI + React + JWT, non confirmée), PDF et Excel des rapports.
- Rôles et permissions, cloisonnement par agence (RLS ou filtrage applicatif), validation par un responsable au-delà du seuil.
- Planificateur : les fonctions des tâches (`cloturer_cycles_echus`, `maj_statuts_credit`, `prelever_echeances_compte`, `saisir_garantie_echeances`, `purger_dates`, `calculer_commission`) existent mais rien ne les lance.
- Caisse : générée pour le retrait client (si une session est passée), le déblocage et le remboursement en espèces. **Pas** pour le versement de fin de tournée ni pour les dépôts et retraits d'épargne.
- Intérêts de l'épargne classique (le taux existe, aucun calcul), remboursement anticipé, restructuration, contentieux, provisionnement.
- États de synthèse réglementaires (bilan, hors bilan, soldes intermédiaires), à-nouveaux de clôture d'exercice.
- Tests de concurrence, performance (solde stocké, partitionnement), gestion de migrations (Flyway, Sqitch, Alembic), sauvegardes.
- Les guides de contrôle interne, d'audit externe et de transformation institutionnelle (PDF fournis) n'ont pas été exploités.
12. **Postes réglementaires** : les signes « + » et « - » de la concordance sont traités comme comptes de contrepartie (provision déduite d'un actif) ; un compte « ex » va à l'actif s'il est débiteur, au passif s'il est créditeur, et en consolidé les comptes sont compensés entre agences. 13 préfixes absents de l'extraction du plan (ex. 33111, 2541) sont rattachés au compte parent. Seules les valeurs nettes sont produites ; pas de colonnes brut et amortissements, pas de tableaux annexes ni de soldes intermédiaires de gestion, pas de version allégée.
13. **Ratios prudentiels** (guide d'audit externe, octobre 2010) : formules reprises du tableau de l'instruction 6. Interprétations à valider : dépôts de garantie non déduits au ratio I ; A2J compté aux ratios II et V comme dans le guide ; durées résiduelles non suivies (part à plus d'un an des dépôts saisie à la main) ; « une seule signature » = un client (groupes d'intérêts non regroupés) ; ratio VII indicatif (dotation de l'exercice non isolée). Le guide date de 2010 : vérifier les seuils contre les instructions BCEAO en vigueur.
14. **Hypothèses des ratios** : les trois interprétations du point 13 (dépôts de garantie au ratio I, compte A2J, définition d'une signature) sont des paramètres modifiables depuis l'écran des ratios, que le comptable valide ; une validation tombe si la valeur change. Les seuils sont modifiables aussi ; en modifier un remet « seuils vérifiés » à « non vérifiés ».
15. **Provisions sur créances** (référentiel, comptes 29 et 299) : l'ancienneté est celle de la plus ancienne échéance impayée, le déclassement porte sur tout l'encours du crédit, la provision se calcule sur l'encours moins les dépôts de garantie. Un mois vaut 30 jours (paramètres). Le déclassement et la provision de la tranche 0 à 3 mois sont facultatifs (désactivés par défaut). Au-delà de 24 mois, la créance est signalée « à passer en charges » et reste provisionnée à 100 % : l'écriture de passage en perte (compte 6691) n'est pas automatisée, pas plus que le transfert comptable de l'encours vers les comptes 2921 à 294. Les intérêts d'un crédit déclassé ne sont pas encore suspendus dans les rapports.
16. **Mode manuel ou automatique** : le paramètre `prov_mode` choisit si les écritures de provisions sont passées par un clic du comptable (défaut) ou chaque jour par la tâche `generer_provisions_auto` du planificateur. Le mode automatique n'agit que si `python -m app.cli planifier` est lancé chaque jour (cron ou tâche planifiée Windows) ; une erreur (par exemple aucun exercice ouvert) est journalisée dans `execution_tache` et visible sur l'écran Provisions.
17. **Rapprochement** : compare l'inventaire des fiches aux comptes 20221/20231/2031/2041 (crédits sains), 291 à 294 (souffrance), 299 (provisions) et 2511/2521/2531 (épargne). Tant que la comptabilisation automatique est désactivée, les opérations non passées en comptabilité apparaissent en écart : c'est le comportement attendu. Les intérêts courus non échus, la tontine et les comptes d'attente ne sont pas rapprochés. Chaque validation est conservée ; sans écart elle est « conforme », sinon une justification est obligatoire.
