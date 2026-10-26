# Fiche de suivi des tests manuels

Dernière mise à jour : 26/10/2026. Cocher ☑ le résultat et noter l'anomalie dans la dernière colonne.

## Prérequis

- Docker Desktop lancé (le conteneur `sfd-pg` doit tourner).
- Lancer `demarrer_sfd.bat` (API sur 8100, application sur 5173).
- Adresse de test : http://localhost:5173 (sur le réseau : http://<IP du PC>:5173).
- Comptes de démonstration : mot de passe `Demo-Passe-2026!` pour `admin`, `directeur`, `comptable`, `auditeur`, `chef.lom`, `caissier.lom`, `agent.lom`, `rh.lom`, `coord.sud`.
- `totp-test` : mot de passe `Definitif-Totp-2026!`, et un code de l'application d'authentification.

## 1. Journée de l'agence (menu Caisse)

| N° | Étapes | Résultat attendu | ☐ | Anomalie / commentaire |
|---|---|---|---|---|
| J1 | Se connecter en `chef.lom`, ouvrir « Journée de l'agence ». | La page s'affiche, avec « Aucune journée ouverte » et l'historique. | ☐ | |
| J2 | Ouvrir la journée d'aujourd'hui. | « Journée ouverte » ; une seconde ouverture est refusée. | ☐ | |
| J3 | Clôturer la journée alors que des sessions de caisse sont ouvertes. | Refus avec le message « des sessions de caisse sont encore ouvertes ». | ☐ | |
| J4 | Fermer les sessions de caisse, puis clôturer. | La journée passe à « Close ». | ☐ | |
| J5 | En `admin` ou `chef.lom`, rouvrir la journée sans motif, puis avec motif. | Sans motif : refus. Avec motif : la journée repasse « Ouverte ». | ☐ | |
| J6 | Se connecter en `caissier.lom`, ouvrir la page. | Le bouton de réouverture n'apparaît pas. | ☐ | |

## 2. Retrait de tontine au guichet (menu Tontine et collecte, « Demande de retrait »)

| N° | Étapes | Résultat attendu | ☐ | Anomalie / commentaire |
|---|---|---|---|---|
| R1 | Choisir le produit TON1, saisir « Selom ». | Les cycles avec un solde (au moins 2 caractères) s'affichent. | ☐ | |
| R2 | Cocher un cycle, puis « Tout cocher ». | Le total et le bouton « Retirer » se mettent à jour. | ☐ | |
| R3 | Modifier le montant d'un cycle à une valeur inférieure au solde. | L'effet affiché est « Retrait partiel… ». Une case « Clôturer le cycle » apparaît si le cycle est en cours. | ☐ | |
| R4 | Saisir un montant supérieur au solde. | L'effet affiche « Montant invalide » et le bouton reste désactivé. | ☐ | |
| R5 | Retirer le solde entier d'un cycle en cours. | Le cycle est clôturé puis retiré ; la caissière apparaît dans « Retraits du jour ». | ☐ | |
| R6 | Retirer une partie sans cocher « Clôturer le cycle ». | Le cycle reste en cours ; le solde restant est diminué. | ☐ | |
| R7 | Cliquer sur une ligne de cycle. | La fiche s'ouvre dans le même onglet, avec les cases du livret. | ☐ | |
| R8 | Sur la fiche, cliquer « ← Retour au retrait ». | La page de retrait revient avec le produit et la recherche conservés. | ☐ | |
| R9 | Sans session de caisse ouverte, tenter un retrait en espèces. | Refus : « Ouvrez une session de caisse ». | ☐ | |
| R10 | Sur un cycle dont le contrôle du livret relève un écart non validé, tenter un retrait. | Refus : le carnet reste au contrôle. | ☐ | |
| R11 | Vérifier le récapitulatif en bas de page. | Totaux par zone et par type de retrait cohérents avec les retraits du jour. | ☐ | |

## 3. Fiche d'un cycle (menu Cycles de tontine)

| N° | Étapes | Résultat attendu | ☐ | Anomalie / commentaire |
|---|---|---|---|---|
| C1 | Ouvrir un cycle clôturé. | Le titre indique « début … · fin réelle … · fin prévue … ». | ☐ | |
| C2 | Ouvrir un cycle en cours. | La fin réelle indique « cycle en cours ». | ☐ | |
| C3 | Consulter « Contrôles du livret ». | Date, contrôleur, état, lignes et totaux constatés et système, écarts, décision. | ☐ | |
| C4 | Consulter « Détail des collectes ». | Une ligne par collecte : page, case, date, montant, mise, origine, agent. | ☐ | |
| C5 | Cliquer « ← Retour au retrait » sur la fiche. | Retour à la page de retrait (si ouvert depuis elle). | ☐ | |

## 4. Type de cycle libre (menu Tontine et collecte, « Cycles de tontine », puis « Nouvelle mise »)

| N° | Étapes | Résultat attendu | ☐ | Anomalie / commentaire |
|---|---|---|---|---|
| T1 | Ouvrir un nouveau cycle pour le produit TON1. | Le type se choisit librement (1, 2 ou 3) ; il n'est plus marqué « verrouillé ». | ☐ | |
| T2 | Créer le cycle avec le type 2 sur le produit TON1. | Le cycle est créé avec le type 2. | ☐ | |

## 5. États financiers : bilan au format du modèle (menu États financiers, onglet « États réglementaires »)

| N° | Étapes | Résultat attendu | ☐ | Anomalie / commentaire |
|---|---|---|---|---|
| B1 | Ouvrir l'onglet, choisir la date de fin. | Le bloc « Bilan au format du modèle » s'affiche, avec brut, amortissements / provisions et net. | ☐ | |
| B2 | Comparer le net du bloc et le total E90 de l'état par postes. | Les deux totaux sont identiques. | ☐ | |
| B3 | Vérifier une ligne d'actif : brut moins amortissements = net. | Égalité pour chaque poste. | ☐ | |

## 6. Connexion, rôles et autres menus

| N° | Étapes | Résultat attendu | ☐ | Anomalie / commentaire |
|---|---|---|---|---|
| A1 | Se connecter avec un mauvais mot de passe. | Message d'identifiants incorrects. | ☐ | |
| A2 | Se connecter en `totp-test` avec le mot de passe et le code. | Le tableau de bord s'ouvre ; le bloc « Droits insuffisants » n'apparaît pas. | ☐ | |
| A3 | Ouvrir « Aide et manuel ». | Les chapitres s'affichent ; le bouton « Imprimer ce chapitre » fonctionne. | ☐ | |
| A4 | En `chef.lom`, ouvrir « Immobilisations et maintenance ». | Registre, pannes et interventions, alertes et coûts s'affichent. | ☐ | |
| A5 | En `admin`, ouvrir « Rôles et droits ». | Les onglets Affectations, Matrice des droits et Rôles s'affichent. | ☐ | |

## Synthèse

| Date | Testeur | Parcours testés | Anomalies ouvertes | Décision |
|---|---|---|---|---|
| | | | | |
