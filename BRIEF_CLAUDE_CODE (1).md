# Brief de reprise : logiciel de microfinance (collecte, épargne, crédit, caisse, RH, comptabilité OHADA)

À donner à Claude Code avec les fichiers SQL du dossier `schema/`. Ce document contient le contexte, les règles de gestion déjà validées avec le client, l'état exact de l'existant et tout ce qui reste à faire.

## 1. Contexte

Institution de microfinance multi-agences, espace OHADA / UMOA (monnaie XOF, pas de décimales en pratique), qui propose :
- **Épargne tontine (collecte journalière)** : des agents commerciaux collectent chez les clients, sur un livret de 31 lignes par page. Un livret est lié à un **cycle**.
- **Épargne classique** : le client dépose et retire directement ; produits multiples.
- **Crédit** sur épargne (garanti) et sans épargne, sur tontine et sur épargne classique.
- **Caisse, RH/paie, comptabilité** en partie double.

Base de données : **PostgreSQL 14+** (testé sur 16), schéma `mf`, extension `btree_gist` requise.

## 2. Contenu du dossier `schema/`

Ordre de chargement (le fichier 06 est devenu 09 car le rapport dépend des modules 07 et 08) :

| Fichier | Contenu |
|---|---|
| `00_noyau.sql` | Types énumérés, agences, utilisateurs, zones, agents, collectrices, affectations (sans chevauchement), paramètres avec surcharge par agence (`param()`), journal d'audit (table seule) |
| `01_epargne_collecte.sql` | Clients, produits, comptes classiques et mouvements, cycles (types 1, 2, 3), historique des mises, lignes de collecte, arrondi, clôture, retraits, commission |
| `02_ecarts.sql` | Compte agent, versements, surplus, écarts de retrait, excédents à régulariser, purge de date |
| `03_credit_caisse.sql` | Crédits, échéances, `imputer_echeance()`, remboursement par seuil (retrait sans décaissement), fidélité, caisse |
| `04_rh.sql` | Employés, contrats, congés, présences, paie, `calculer_commission()` |
| `05_comptabilite.sql` | Exercices, comptes, journaux, pièces, écritures équilibrées par trigger, règles comptables, balance |
| `07_virement.sql` | Virements tontine ↔ épargne classique |
| `08_credit_epargne.sql` | Crédit sur épargne classique : produits, demandes, garantie bloquée, prélèvement, saisie, espèces |
| `09_rapports.sql` | Rapport journalier par agent, par zone, global |
| `mf_schema_complet.sql` | Concaténation de tout ce qui précède, dans l'ordre 00 à 05, 07, 08, 09 |
| `tests_scenarios.sql`, `tests_virement_credit.sql` | Scénarios de test avec les valeurs attendues en commentaire |
| `archive_version_alternative/` | Une version concurrente des modules 07/08, non utilisée et incompatible. À supprimer après confirmation du client |

Un test de chargement à vide (`psql -v ON_ERROR_STOP=1 -f mf_schema_complet.sql`) et les deux fichiers de tests passent.

## 3. Règles de gestion validées

### 3.1 Cycles de collecte
- Un cycle a un **numéro**, est lié à un **client** et à un **produit**. Le retrait se fait **par cycle**.
- **Type 1** : mise (ex. 500 F) × 31 lignes. Clôture quand l'objectif est atteint **ou** que la date de fin est atteinte.
- **Type 2** : tient compte de la durée. La mise est fixe, avec historique de modifications. Clôture à la date de fin.
- **Type 3** : pas de mise cible, collecte aléatoire sur une période. À la clôture : `mise_finale = max(arrondi(total / 31), mise_initiale)`. Diviseur toujours 31 (paramètre `diviseur_type3`).
- **Arrondi** paramétrable (`arrondi_mode`, `arrondi_multiple`), défaut : plus proche, multiple de 25.
- Chaque ligne enregistre la **mise appliquée à sa date** : une hausse ou une baisse de mise ne fausse pas le passé.
- **Écran de collecte** : prévisionnel (mises passées + lignes restantes × mise courante), collecté, reste à collecter, **net = collecté − mise du cycle**.

### 3.2 Zones, collectrices, commission
- Une zone est administrée par une collectrice, avec affectation datée.
- **Production** = total des mises de la période ; **commission = production × x %** (taux unique).
- `mode_cloture` paramétrable :
  - `calendaire_mensuel` : production comptée **après la clôture** des cycles.
  - `date_fin_client` : production comptée **au fil des collectes**.
- Chaque ligne de collecte porte l'`agent_id` de celui qui a collecté. Les pertes et surplus sont imputés à cet agent, pas à la collectrice actuelle de la zone.

### 3.3 Écarts
- **Écart de versement** (fin de tournée) = collecté (saisie du jour) − versé. Manquant : débit du compte de l'agent. Surplus : table `surplus`, statut « à traiter ».
- **Écart de retrait, livret > machine** : le client est payé selon le livret. L'écart est toujours rattaché à une ou plusieurs **dates** (montant saisi par date). Pour chaque date : le surplus de **cette date exacte** est utilisé d'abord ; le reste est une perte au débit du compte de l'agent de la collecte ; le surplus diminue d'autant.
- **Écart de retrait, machine > livret** : ce n'est **pas** un surplus réel. L'excédent reste « à régulariser » et un retrait de régularisation (sans décaissement) est créé. Il devient surplus réel de l'agent **seulement quand la date est purgée** : tous les retraits des cycles ayant une ligne à cette date sont faits, et aucun écart n'est ouvert sur cette date.
- Un surplus reste bloqué tant qu'un cycle lié à sa date n'est pas retiré.
- Le compte de l'agent est soldé par versement ou par **retenue sur commission**, plafonnée par `plafond_retenue`.

### 3.4 Crédit
- Deux types : sur épargne (garantie : cycle tontine ou compte classique) et sans épargne. Montant, taux, frais et garantie sont **négociés**, sans plafond en pourcentage.
- Les échéances se règlent **dans l'ordre**. Imputation : **capital, puis intérêts, puis pénalités**.
- **Crédit sur tontine** : le remboursement se déclenche quand le collecté du cycle atteint le dû de l'échéance. Il est tout fait sur la **mise de collecte**, sans commission supplémentaire.
- Le remboursement est un **retrait de nature « remboursement », sans décaissement**, qui passe par la gestion des écarts. Statuts : demandé → écart en traitement → fonds disponibles → exécuté. **Pas d'exécution partielle** : on traite d'abord les écarts.
- **Retard, pénalité et points** se calculent sur la **date d'atteinte du seuil** (pas sur la date d'exécution).
- **Points de fidélité** par échéance : à temps +X ; en retard −Y par tranche de jours ; crédit soldé sans retard +Z. Valeurs paramétrables.
- Écrans de crédit par jour : remboursements **échus**, remboursements **à venir**, **situation des crédits**.

### 3.5 Virements tontine ↔ épargne classique
- **Tontine → épargne** : retrait de cycle sans décaissement, avec le même circuit d'écarts. Le compte est crédité **selon le livret** (montant ± écart). Le cycle passe à « retiré ».
- **Épargne → tontine** : lignes de livret d'origine « virement », sans agent. Types 1 et 2 : montant multiple de la mise, une ligne par mise. Type 3 : une ligne. Même client obligatoire.

### 3.6 Crédit sur épargne classique
- **Garantie bloquée** sur le compte : le solde disponible = solde − solde minimum du produit − garanties bloquées. Un trigger refuse toute sortie au-delà.
- Remboursement : **prélèvement automatique** sur le compte (dû complet seulement) ou **espèces** à la caisse (paiement partiel accepté).
- **Saisie de la garantie** après `jours_saisie_garantie` de retard (30 par défaut). **Libération** quand le crédit est soldé.
- Échéancier : capital constant ou annuité constante ; intérêt par période = capital restant × taux annuel × jours / 360.

### 3.7 Rapport journalier
Par jour, par zone, par agent : collecte, mises, versements et écarts, retraits, remboursements, crédits (échus et à venir), comptes de gestion, fidélité, caisse. Trois sorties **identiques** : écran, PDF, Excel (un onglet par section). Une date passée doit être **reproductible** à partir des écritures datées.

## 4. À faire, par priorité

### P0. Choix à faire avec le client avant de coder
1. **Pile technique** (rien n'est imposé). Proposition par défaut : API REST (FastAPI ou NestJS) + front web (React), PostgreSQL, auth JWT. À confirmer.
2. **Plan comptable à charger** : SYSCOHADA révisé ou plan comptable des SFD de l'UMOA. Fournir le fichier officiel.
3. **Valeurs par défaut** à valider dans `parametre` : `taux_commission` (0,02 provisoire), points X/Y/Z, pénalité (mode, taux, plafond), `plafond_retenue`, `jours_saisie_garantie`.
4. **Production en mode `date_fin_client`** : le code compte le **montant collecté**, pas la **mise**. À confirmer avec le client (voir 5.1).
5. Fournir les **taux de cotisations sociales et d'impôt sur salaire** à paramétrer dans `rubrique_paie`.

### P1. Back-end : brancher les règles métier
1. **Déclenchement automatique** de `declencher_remboursements(cycle)` après chaque saisie de ligne de collecte, puis `constater_sans_ecart()` si aucun écart.
2. **Tâches planifiées** (cron ou job applicatif), par agence et par jour :
   - `cloturer_cycles_echus()` (fin de mois en mode calendaire) ;
   - `maj_statuts_credit()` ;
   - `prelever_echeances_compte()` ;
   - `saisir_garantie_echeances()` (ou après validation d'un responsable) ;
   - `purger_date()` pour chaque date purgeable ;
   - `calculer_commission()` par collectrice en fin de période.
3. **Comptabilité automatique** : remplir `regle_comptable` et appeler `comptabiliser()` pour chaque événement : versement agent, dépôt et retrait d'épargne, retrait de cycle, déblocage de crédit, remboursement (capital, intérêts, pénalités), manquant et perte agent, surplus réel, commission, salaire, frais de dossier, virements. Aucune écriture n'est générée aujourd'hui.
4. **Caisse** : générer les `operation_caisse` pour versement agent, dépôt, retrait client, déblocage, remboursement espèces ; les liens existent (`caisse_operation_id`) mais ne sont pas alimentés partout.
5. **Retrait client** (`nature = retrait_client`) : `executer_retrait()` ne tient pas compte de l'écart pour le montant payé, contrairement au virement. Aligner (client payé selon le livret).
6. **Intérêts de l'épargne classique** : `produit_epargne.taux_interet` existe, aucun calcul d'intérêt n'est fait.
7. **Numérotation automatique** des cycles, clients, comptes, crédits, pièces.
8. **Paie** : fonction de génération des bulletins (salaire de base, commission nette de retenue, rubriques paramétrées, retenue d'avances). Seule `calculer_commission()` existe.
9. **Remboursement anticipé, restructuration, contentieux, provisionnement** des crédits : non modélisés.

### P2. Sécurité et exploitation
1. **Rôles et permissions** (admin, directeur, chef d'agence, caissier, comptable, agent, collectrice, RH, auditeur). La colonne `utilisateur.role` existe, aucun contrôle n'est appliqué.
2. **Cloisonnement par agence** : row-level security PostgreSQL ou filtrage applicatif. Le siège voit toutes les agences.
3. **Validation par un responsable** des régularisations, saisies de garantie et approbations de crédit (le paramètre `validateur` existe, pas de seuil).
4. **Piste d'audit** : la table `audit_log` existe mais aucun trigger ne l'alimente. Cibler au minimum retraits, écarts, surplus, compte agent, crédits, écritures.
5. **Gestion des migrations** (Flyway, Sqitch ou Alembic) à la place du fichier unique. Attention : `ALTER TYPE ... ADD VALUE` ne s'emploie pas dans la même transaction que son usage.
6. **Sauvegardes**, journalisation, comptes de service à droits minimaux.

### P3. Écrans et sorties
- Écrans : collecte (prévisionnel, collecté, reste, net), saisie du livret, versement de fin de tournée, retrait et constat des écarts, régularisation, purge, virements, crédits (demande, décision, déblocage, échéancier), remboursements échus et à venir, situation des crédits, caisse (ouverture, billetage, fermeture), RH et paie, comptabilité (saisie, grand livre, balance).
- **Rapport journalier** : unifier écran, PDF et Excel sur les mêmes requêtes. Ajouter par zone les écarts, retraits et remboursements (aujourd'hui seule la collecte l'est).
- Sorties comptables réglementaires (balance, grand livre, états de synthèse) selon le référentiel choisi.

### P4. Qualité
- Transformer les scénarios `tests_*.sql` en **tests automatisés** (pgTAP ou tests d'intégration de l'API) avec exécution en CI sur un PostgreSQL vierge.
- Ajouter des tests de **concurrence** (deux saisies simultanées sur un même cycle, deux retraits) et des tests aux limites (31e ligne, changement de page, cycle clos, solde minimum).
- Mesurer la performance : `v_solde_compte_epargne` est recalculée à chaque appel de `solde_disponible()` ; envisager un solde stocké et un index. Envisager un partitionnement de `ligne_collecte` par date.

## 5. Points fragiles connus (à corriger ou confirmer)

1. **Production au fil des collectes** : le code additionne le montant collecté ; la règle dit « total des mises ». Les lignes de virement entrent aussi dans ce total.
2. **Rapports et dates passées** : plusieurs sections s'appuient sur `cree_le::date` ou `execute_le::date` (horodatage système) plutôt que sur la date d'opération. Une opération saisie après coup fausse un rapport passé. À corriger pour la reproductibilité exigée.
3. **Écart sur une date n'ayant que des lignes de virement** : ces lignes n'ont pas d'agent, donc l'imputation d'une perte est impossible. Règle à définir (par exemple : imputation à l'agence, ou interdiction).
4. **Prélèvement automatique** : dû complet seulement, jamais partiel. Confirmer avec le client.
5. **Pénalité et retard sur les crédits sur compte** : la date de référence est celle du prélèvement (premier jour où le solde disponible suffit), par analogie avec la date d'atteinte du seuil. À confirmer.
6. **Taux de commission** à 0,02 : valeur provisoire, à fixer par le client.
7. Dans `mouvement_epargne`, les types ont été élargis (`varchar(25)`). Si d'autres types s'ajoutent, mettre à jour la contrainte `CHECK` et la vue `v_solde_compte_epargne`.
8. Des fonctions à deux paramètres de date existent avec des valeurs par défaut `current_date` : en production, passer la date de traitement explicitement, surtout pour les reprises de traitement.

## 6. Comment travailler avec ce dossier
1. Charger `mf_schema_complet.sql` dans une base vide, puis lancer `tests_scenarios.sql` et `tests_virement_credit.sql` (chaque fichier de test suppose une base fraîche).
2. Lire d'abord les commentaires en tête de chaque module : ils décrivent la règle implémentée.
3. Toute nouvelle règle de gestion doit être ajoutée avec son scénario de test et sa valeur attendue chiffrée.
4. Ne pas modifier une règle de la section 3 sans confirmation du client : elles ont été arbitrées une à une.
