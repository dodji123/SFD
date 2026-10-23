# Stock des fournitures et sécurité renforcée — cadrage

## Ce qui manque à la PWA collecteur (hors tests)

1. Connexion hors réseau impossible : après fermeture de l'application sans réseau, il faut se reconnecter (la file est conservée). Suite : code PIN local + appareil enregistré (voir sécurité).
2. Session 15 min : une longue inactivité sur le terrain déconnecte ; à arbitrer avec la politique de sécurité.
3. Pas de prolongation de cycle, retrait, changement de mise ni versement de fin de journée depuis le mobile.
4. Service worker vérifié sur Chrome bureau seulement (pas sur téléphone ni en HTTPS réel) ; lecture caméra du QR non testée.
5. `mf_schema_complet.sql` et `SECURITE.md` à tenir à jour ; test d'intrusion avant production.

## A. Stock des fournitures (consommables + immobilisations)

**Statut : fait** (modules 57 et 58, routeur `stock.py`, écran « Stock des fournitures », commit `2110625`). Tests SQL des modules 55 à 58 : 111 assertions OK ; tests API du stock passent.

- **Problème** : livrets, reçus, papeterie, matériel (téléphones, ordinateurs, coffres) ne sont pas suivis ; ruptures, pertes et sorties non justifiées.
- **Objectif** : catalogue d'articles, stock par lieu (siège, agence, agent), entrées/sorties/transferts/inventaire tracés, seuil d'alerte, valorisation ; immobilisations avec numéro, affectation à un agent, amortissement, sortie/mise au rebut ; pièces comptables.
- **Approche simple** : un module SQL (articles, lieux, mouvements en ajout seul, solde par vue), un routeur `stock.py`, un écran web « Stock » ; les mouvements sensibles (sortie, rebut, ajustement d'inventaire) exigent la validation d'une autre personne.

## B. Sécurité renforcée

**Statut** :
- (1) Second facteur TOTP : **fait** (module 55, commit `2110625`). Flux vérifié dans le navigateur : mot de passe temporaire, enrôlement, codes de secours, rejet d'un code rejoué, connexion avec code. Les codes de secours et la réinitialisation sont couverts par les tests API seulement.
- (2) Appareils mobiles : module 56 présent dans le commit `2110625`. **Parcours mobile non vérifié.**
- (3) Revue trimestrielle des droits, double validation des opérations sensibles, alertes d'anomalies : **à faire**.
- (4) Durcissement API (limitation de débit partagée, politique de mots de passe, rotation des clés, CSP) : **à faire**.

- **Problème** : voir `SECURITE.md` (second facteur du personnel, appareils mobiles, revue des droits, limitation de débit en mémoire).
- **Objectif** : (1) second facteur TOTP obligatoire pour admin/directeur/chef/comptable, codes de secours ; (2) appareils mobiles enregistrés, jeton lié à l'appareil, révocation, effacement du cache à distance ; (3) revue trimestrielle des droits, double validation des opérations sensibles, alertes d'anomalies ; (4) durcissement API : limitation de débit partagée (base), politique de mots de passe, rotation des clés, CSP.
- **Approche simple** : incréments indépendants, chacun avec son module SQL numéroté (prochain numéro libre), ses tests pytest et sa mise à jour de `SECURITE.md` ; ordre : TOTP, appareils, revue des droits, durcissement.

Les deux chantiers touchent des fichiers différents (stock : nouveau module, routeur et page ; sécurité : `auth.py`, `securite.py`, sessions) et peuvent avancer en parallèle.
