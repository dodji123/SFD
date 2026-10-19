# Plateforme de gestion intégrée des SFD (UMOA)

Trois couches, de bas en haut :

| Dossier | Contenu | Vérification |
|---|---|---|
| `schema/` | Base PostgreSQL `mf` : toutes les règles de gestion (tontine, écarts, crédit, caisse, RH, comptabilité, rapports). Voir `schema/LISEZ-MOI.md` | `bash schema/tools/run_tests.sh` : 635 assertions |
| `api/` | API FastAPI : authentification, rôles, cloisonnement par agence, routes fines au-dessus des fonctions SQL | `cd api && python -m pytest` : 116 tests |
| `web/` | Interface React + TypeScript (Vite) : tableau de bord, clients (KYC, consentements, espace client, transferts de zone et d'agence), conformité LBC/FT, espace client `/espace` pour les clients eux-mêmes, cycles et livret, collecte du jour, retraits et écarts, crédits, caisse, trésorerie, rapports (journaliers, portefeuille et PAR, activité de crédit, rapport financier), comptabilité (dont bilan), états financiers (par agence et consolidés du réseau), RH, administration | `cd web && npm run build` (types + build) |

## Démarrer en local

Prérequis : Docker (PostgreSQL 16), Python 3.12, Node 22+.

```bash
# 1. Base : conteneur déjà utilisé par le projet (sfd-pg, port 5440), sinon :
docker run -d --name sfd-pg -e POSTGRES_PASSWORD=sfd -p 5440:5432 postgres:16

# 2. API : base de développement + schéma + données de démonstration
cd api
pip install -r requirements.txt
#   api/.env fixe l'URL de la base (valeurs de développement local uniquement)
python -m app.cli init-schema          # sur une base VIERGE
python -m app.cli donnees-demo         # refusé si SFD_ENV=prod
python -m uvicorn app.main:app --port 8100

# 3. Interface
cd ../web && npm install && npm run dev      # http://localhost:5173 (relaye /api vers le port 8100)
```

Comptes de démonstration (mot de passe `Demo-Passe-2026!`, modifiable par `SFD_DEMO_PASSWORD`) :
`admin`, `directeur`, `comptable`, `auditeur` (siège, avec sélecteur d'agence), `chef.lom`, `caissier.lom`, `agent.lom`, `rh.lom` (agence de Lomé).
**Ne jamais charger ces données en production.**

Créer le premier administrateur réel : `python -m app.cli creer-utilisateur --login ... --nom ... --role admin` (le mot de passe est demandé, jamais passé en argument).

Inventaire des fonctionnalités avec leur niveau de maturité : voir `FONCTIONNALITES.md`.

## Rôles et droits

Contrôlés **côté API** (`api/app/perms.py`) ; l'interface ne fait que masquer ce qui est interdit.

| Rôle | Peut |
|---|---|
| admin | tout, dont utilisateurs, agences, paramètres, transfert de client entre agences |
| directeur | lecture générale, décisions de crédit, écarts, audit, trésorerie, transferts de clients (zone et agence) |
| chef_agence | gestion de l'agence : référentiels, collecte, écarts, retraits, crédits, caisse, trésorerie, transfert de zone, tâches du jour, lecture compta |
| caissier | dépôts / retraits d'épargne, versements de tournée, exécution des retraits, déblocage et remboursement de crédits, caisse |
| comptable | comptabilité (pièces, exercices, contrepassation), états financiers par agence et consolidés, rapports, caisse en lecture |
| agent / collectrice | saisie de la collecte (un agent ne saisit que ses propres collectes), demandes de crédit et de retrait |
| rh | employés, contrats, rubriques, commissions, bulletins |
| auditeur | lecture seule partout, piste d'audit |

Cloisonnement : un utilisateur d'agence ne voit et ne modifie que son agence (une ligne d'une autre agence répond « introuvable »). Seuls admin, directeur, comptable et auditeur peuvent être au siège.

## Sécurité en place

Voir `SECURITE.md` pour la grille complète (ce qui est fait, ce qui reste à faire) et la description de l'espace client.


- Mots de passe hachés (bcrypt), 10 caractères minimum ; verrouillage 15 minutes après 5 échecs ; réponse identique pour identifiant inconnu et mot de passe faux.
- Jeton JWT de 8 h, **relu en base à chaque requête** : un compte désactivé perd l'accès immédiatement. Gardé en `sessionStorage` côté navigateur.
- Requêtes SQL toutes paramétrées ; tables et fonctions dynamiques issues de listes blanches.
- Les règles métier restent dans la base (le schéma refuse les opérations incohérentes) : l'API ne les duplique pas.
- Piste d'audit : l'API transmet l'utilisateur à la base ; chaque modification des tables sensibles est tracée avec valeurs avant / après (page Administration).
- Documentation interactive de l'API désactivée si `SFD_ENV=prod`. `SFD_JWT_SECRET` est obligatoire hors développement.

## À faire avant une mise en production

- Valider avec le client les valeurs provisoires et les interprétations listées dans `schema/LISEZ-MOI.md` (taux de commission, pénalités, points de fidélité, comptes comptables).
- Saisir les taux de cotisations et d'impôt sur salaire (rubriques de paie) et l'exercice comptable ; activer la comptabilisation automatique seulement après validation des règles par le comptable.
- Planifier les traitements quotidiens (prélèvements, retards et pénalités, saisie des garanties, clôture des cycles échus, purge des dates, commissions) : ils existent en routes `/api/taches/*` et `/api/collecte/*` mais rien ne les déclenche seul. Un planificateur externe (cron, tâche planifiée) doit les appeler chaque jour. Le planificateur existe (`schema/12_planificateur.sql`, `api/app/planificateur.py`, `python -m app.cli planifier`) : testé pour la tâche des provisions, à lancer chaque jour sur le serveur ; il porte aussi le mode automatique des provisions.
- Transfert d'agence : prévoir avec le comptable le règlement inter-agences de l'épargne déplacée (aucune écriture automatique, voir `schema/LISEZ-MOI.md`).
- HTTPS devant l'API et l'interface, sauvegardes de la base, mots de passe et secrets réels hors dépôt.
- Aucun test automatisé de l'interface (seulement `tsc`, build et vérification manuelle dans le navigateur).

## Feuille de route (d'après le document « Sprint 1 »)

Fait : états par agence et consolidés ; provisions sur créances ; rapprochement fiches / comptabilité ; états réglementaires par postes (bilan, compte de résultat, hors-bilan) ; ratios prudentiels I à IX avec historique ; KYC et LBC/FT ; espace client sécurisé ; PAR et taux de recouvrement (rapports de crédit).
À faire, par priorité : alertes sur dépassement de seuil (une fois par dépassement) ; rappels SMS (J-3, J-1, J, J+1, J+7, J+30) avec modèles, plages horaires et consentement ; exports PDF et Excel avec filigrane et journal d'export ; dossier d'audit exportable ; relance J+30 ouvrant un dossier de recouvrement. Les formats exacts des états BCEAO doivent être fournis par le client.

## Pas fait

PDF et Excel des rapports (export CSV disponible, impression par le navigateur) ; états de synthèse réglementaires (bilan, hors bilan) ; intérêts de l'épargne classique ; remboursement anticipé, restructuration, contentieux, provisionnement ; à-nouveaux de clôture d'exercice ; application mobile native (l'interface s'adapte aux écrans étroits) ; changement de mot de passe par l'utilisateur dans l'interface (la route `/api/auth/mot-de-passe` existe) ; tests de charge et de concurrence.
