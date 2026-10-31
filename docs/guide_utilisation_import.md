# Guide d'utilisation et d'importation — SFD

Ce guide décrit l'ordre de mise en place d'une base vide, puis l'import des données du terrain. Il s'appuie sur les écrans et les contrôles réellement présents dans l'application.

## 1. Ordre de mise en place

Une base vide doit être remplie dans cet ordre, car chaque étape s'appuie sur la précédente :

1. **Compte superutilisateur** : `admin` (conservé). Connexion obligatoire avant tout le reste.
2. **Agence** : déjà présente dans la base de développement.
3. **Zones** : à créer avant les clients. Un client se rattache à une zone de son agence.
4. **Utilisateurs** : à créer depuis l'écran d'administration (gestion des utilisateurs et des droits).
5. **Produits d'épargne** : à créer avant les cycles. Un cycle se rattache à un produit (codes P1, P2, P3… dans l'import).
6. **Clients** : import Excel (page **Import des clients**).
7. **Cycles** : import Excel (page **Import des cycles**). Un cycle se rattache à un client déjà importé.
8. **Collectes et relevés** : saisie au fil de l'eau, puis relevés du carnet (page **Relevés carnet et rapprochement**).

## 2. Zones et produits

- **Zone** : un code court (par exemple `Z1`) et un libellé. Le code est repris dans le fichier clients (colonne `zone_code`).
- **Produit** : un code (par exemple `P1`), un libellé, un type de cycle (1, 2 ou 3) et un nombre de pages du livret. Le code est repris dans les fichiers clients et cycles (`produit_code`).

Les produits sont obligatoires : sans eux, aucun cycle ne peut être créé.

## 3. Import des clients

**Page** : *Import des clients* (`/import-clients`). Droit : `ref:write`.

**Procédure** :
1. Cliquer sur **Télécharger le fichier type**. Le fichier contient les onglets Clients, Notice, Zones et Produits : utilisez les codes de ces onglets.
2. Remplir l'onglet **Clients**.
3. Sélectionner le fichier : le contrôle s'affiche, sans rien enregistrer.
4. Corriger les erreurs signalées ligne par ligne.
5. Cliquer sur **Créer les clients**, puis confirmer.

**Colonnes** :

| Colonne | Obligatoire | Règle |
|---|---|---|
| `numero` | oui | Numéro client du terrain, conservé tel quel. Unique dans l'agence. |
| `nom` | oui | Nom tel qu'il doit apparaître dans l'application. |
| `zone_code` | oui | Code d'une zone de l'agence. |
| `produit_code` | oui | Code d'un produit existant. |
| `telephone` | non | Numéro de téléphone. |

**Client qui souscrit à plusieurs produits** : mettez une ligne par produit, avec le même numéro, le même nom et la même zone. La fiche n'est créée qu'une fois. Une ligne avec un nom ou une zone différents est refusée. Le produit n'est pas enregistré sur la fiche : il sert au contrôle et se retrouve dans les cycles.

**Refus courants** :
- « le client existe déjà dans l'agence » : le numéro est déjà en base. Le fichier ne l'écrase pas.
- « zone inconnue » : la zone n'existe pas encore dans l'agence.
- « produit inconnu » : le code produit n'existe pas.

## 4. Import des cycles

**Page** : *Import des cycles* (`/import-cycles`). Droit : `livret:controler` (gérant ou contrôleur).

**Procédure** : identique à l'import des clients, avec le bouton **Télécharger le fichier type** puis **Créer les cycles**.

**Colonnes** :

| Colonne | Obligatoire | Règle |
|---|---|---|
| `numero` | oui | Numéro du cycle, unique dans l'agence. |
| `client_numero` | oui | Numéro d'un client **déjà importé**. |
| `produit_code` | oui | Code d'un produit existant. |
| `date_debut` | oui | Format AAAA-MM-JJ ou date Excel. |
| `date_fin` | oui | Pas avant la date de début. |
| `mise` | oui | Entier positif, en francs CFA. |
| `objectif` | non | Calculé automatiquement si absent (mise × nombre de lignes). |
| `type_cycle` | non | Repris du produit si absent. |

**Règle à respecter** : **un seul cycle en cours par client et par produit**. Si un client a déjà un cycle en cours pour P1, un second cycle P1 est refusé à la création, avec le motif « clôturer le cycle existant d'abord ».

Pour un client avec deux produits, il faut donc deux lignes : une par produit (P1 et P2, par exemple).

**Ce que fait le contrôle** : il vérifie les colonnes, les dates, la mise, l'existence du client et du produit, et les doublons de numéro. Il ne vérifie **pas** encore la règle « un cycle en cours par produit » : une ligne acceptée au contrôle peut donc être refusée à la création. Pour éviter cela, ne gardez qu'un cycle par client et par produit dans le fichier, ou clôturez le cycle existant avant l'import.

## 5. Relevés du carnet

**Page** : *Relevés carnet et rapprochement* (`/releves-carnet`).

1. Choisir le cycle à relever, puis **Saisir le relevé**.
2. Reporter les dates et la mise du carnet, puis le total non retiré de chaque page.
3. Enregistrer. Le relevé ne se modifie plus ensuite.

Le rapprochement signale les écarts (dates, mise, total) sans bloquer le cycle. L'annulation d'un relevé demande un motif d'au moins 5 caractères.

## 6. Vérifications avant de commencer

- Au moins un produit et une zone existent.
- Les clients sont importés avant les cycles.
- Le contrôle du fichier ne retourne aucune erreur, puis la création est lancée.
- Les compteurs affichés après création correspondent au nombre de lignes acceptées.

## 7. Points à valider avant une mise en production

- Le produit n'est pas stocké sur la fiche client : aucune vue « produits du client » n'existe pour l'instant.
- L'import de l'historique des collectes depuis Excel n'existe pas : les collectes passent par l'application mobile ou la saisie directe.
- Le contrôle des cycles ne vérifie pas encore la règle « un cycle en cours par produit ».
