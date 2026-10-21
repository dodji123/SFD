# Application mobile du collecteur — PWA

## Cadrage

- **Problème** : les agents et collectrices saisissent aujourd'hui leurs collectes sur l'interface bureau (`Collecte.tsx`), qui suppose un écran large et un réseau continu. Sur le terrain, le réseau manque souvent : une collecte non saisie est une collecte perdue ou ressaisie le soir (risque d'erreur et de doublon).
- **Objectif** : une application installable sur téléphone, écrans étroits, où l'agent/collectrice se connecte, voit les cycles à collecter, saisit une collecte en quelques secondes, **même hors réseau**, et voit à tout moment ce qui reste « à synchroniser » ou ce qui a été refusé.
- **Approche la plus simple** : une PWA dans `web/` (pas de dépôt mobile, pas de React Native) sous la route `/m`, qui réutilise `lib/api.ts`, la session JWT et les endpoints existants de lecture (`GET /api/cycles`, `GET /api/collecte/jour`). Les saisies hors ligne vont dans une file IndexedDB ; un seul endpoint nouveau côté API, `POST /api/collecte/sync`, applique un lot de façon idempotente.
- **Hors périmètre de cette étape** : création de cycles, retraits, changement de mise, validation de journée (restent sur le bureau) ; notifications push ; connexion hors ligne (la connexion exige le réseau).

## Cadrage v2 — zone, création sur le terrain, validation (2026-10-21)

- **Problème** : v1 écrit directement dans les données vives et montre tous les cycles de l'agence. Or l'agent ne doit voir que sa zone, peut créer clients/cycles et clôturer sur le terrain, et rien ne doit entrer dans les données sans contrôle d'un opérateur de saisie.
- **Objectif** : l'agent (lié à une zone) voit seulement ses clients ; il enregistre un client, ouvre un cycle (type 1/2/3 libre), collecte et clôture, hors ligne. À la synchro, tout arrive dans une **file de validation** ; le chef/caissier valide (lot ou opération) ou rejette avec motif ; l'agent voit le statut de chaque opération.
- **Approche la plus simple** : on réutilise `operation_mobile` (clé idempotente) en y ajoutant type, contenu (JSON), statut `en_attente/validee/rejetee`, motif, décideur. `POST /api/collecte/sync` ne fait plus que **mettre en attente** (contrôles de forme, de zone et d'agence) ; `POST /api/collecte/validations/valider` rejoue dans l'ordre client → cycle → collecte → clôture dans une transaction par opération (délai de grâce, cycle clos, etc. contrôlés par le schéma à ce moment). Un client/cycle créé hors ligne a un identifiant local (sa clé) remplacé par l'identifiant réel à la validation ; une opération dont la dépendance n'est pas validée est rejetée.
- **Décisions** : zone de l'agent = zones dont il est l'agent, ou affectées à sa collectrice (affectation en cours) ; nouvelle permission `collecte:valider` (admin, chef, caissier) ; la PWA lit `GET /api/collecte/mobile/tournee` (zones, clients, cycles, produits, statuts) ; écran bureau « Synchronisations à valider ».

## Décisions (v1)

| Sujet | Décision |
|---|---|
| Idempotence | Chaque saisie reçoit côté client une clé d'opération (UUID) conservée jusqu'à l'accusé du serveur. L'API enregistre la clé (`mf.operation_mobile`) dans la même transaction que la ligne : rejouer la clé renvoie le résultat d'origine (`doublon`) sans créer de seconde ligne. |
| Isolation des refus | Chaque opération du lot a sa propre transaction : un refus n'annule pas les autres. Une opération refusée n'est pas mémorisée côté serveur (elle peut être rejouée après correction, par ex. prolongation du cycle). |
| Motifs de refus | `cycle_clos`, `hors_delai` (après fin + délai de grâce), `avant_debut`, `droit_agence` (cycle d'une autre agence / autre agent), `montant_invalide`, `date_future`, `cycle_introuvable`, `autre`. |
| Erreurs réseau / 5xx | L'opération reste « à synchroniser » et sera retentée (retour du réseau, bouton, reprise périodique). |
| Session | Jeton JWT 15 min glissant inchangé. Une 401 pendant la synchro suspend la file (rien n'est perdu) jusqu'à la reconnexion. La file survit à la déconnexion ; le cache des clients est purgé. |
| Schéma | Un nouveau module `schema/45_sync_mobile.sql` (une table). Aucun module existant n'est modifié ; `mf_schema_complet.sql` sera à régénérer avec `tools/build_schema_complet.sh` quand le travail GRH/cycles en cours sera stabilisé. |

## Incréments

1. Cadrage (ce document).
2. API : `POST /api/collecte/sync` + table + tests pytest.
3. PWA : manifest, service worker, icônes, route `/m`, connexion.
4. Liste du jour, saisie rapide, file IndexedDB, indicateur « à synchroniser ».
5. Synchro automatique, écran des refus/conflits.
6. Vérification : `tsc -p tsconfig.app.json`, pytest, démonstration hors ligne dans le navigateur.

## État

Livré le 2026-10-21 (rien n'est commité) :

- API : `POST /api/collecte/sync` (`api/app/routers/collecte_sync.py`), table `mf.operation_mobile` (`schema/45_sync_mobile.sql`), tests `api/tests/test_collecte_sync.py` (10). Suite complète : 217 tests verts.
- Web : route `/m` (`web/src/mobile/` : `MobileApp.tsx`, `file.ts`, `mobile.css`), `manifest.webmanifest`, `sw.js`, icônes ; `tsc -p tsconfig.app.json` propre.
- Démonstration vérifiée : saisie hors réseau → file IndexedDB « à synchroniser » → retour du réseau → synchro automatique (2 acceptées, 2 refusées : cycle clos, hors délai) ; accusé perdu puis renvoi → une seule ligne ; « Réessayer » après prolongation ; arrêt réel de l'API puis reprise automatique ; service worker : application ouverte avec le serveur web arrêté (Chrome).

### v2 — zone, création sur le terrain, validation (2026-10-21)

- Schéma : `schema/46_validation_mobile.sql` (+ `schema/tests/test_46_validation_mobile.sql`, vérifié sur une base jetable), appliqué à `sfd_dev`, `mf_schema_complet.sql` régénéré.
- API (`collecte_sync.py`) : `GET /api/collecte/mobile/tournee` (zones, clients, cycles, produits, statuts) ; `POST /api/collecte/sync` met en attente (zone, agence, format) sans rien écrire ; `GET /api/collecte/validations`, `POST …/valider`, `POST …/rejeter` (permission `collecte:valider` : admin, chef, caissier). Tests : `test_collecte_sync.py` (9) ; suite complète 219 verts.
- Web : PWA réécrite (onglets Cycles / Clients / Suivi, nouveau client, nouveau cycle à type libre, clôture, statut de chaque opération) ; écran bureau « Synchronisations à valider » (`pages/SyncValidation.tsx`, menu Tontine et collecte).
- Démonstration vérifiée : agent limité à sa zone (6 cycles sur 12) ; hors ligne : nouveau client + son cycle (type 2, produit sans type) + collecte dessus + collecte + clôture ; synchro → « en attente de validation », rien dans les données ; l'opérateur rejette une collecte (motif visible sur le téléphone) et valide le lot : client numéroté CL-LOM-2026-000013, cycle CY-…013, collecte et clôture appliqués dans l'ordre, identifiants locaux remplacés.
- Notes : une opération que le schéma refuse à la validation (cycle clos, hors délai…) est rejetée automatiquement avec le message de la base ; une opération dont la dépendance attend encore est « différée ». `vite.config.ts` lit `SFD_API_URL` (défaut 8100). Le service worker n'a pas été revérifié après la v2 (inchangé).

### v3 — contrôle des livrets sur le terrain (2026-10-21)

- Pour les rôles ayant `livret:controler` (chef d'agence, directeur, coordinateur, admin) la PWA `/m` ouvre l'écran **Contrôle des livrets** (`web/src/mobile/Controle.tsx`, file `fileConstats.ts`, IndexedDB `sfd_controles`) ; les agents/collectrices gardent l'écran de collecte. Aucun fichier API/SQL ajouté : on utilise `POST /api/controles-livrets` (clé d'opération = idempotence), `GET /api/cycles`, `GET /api/cycles/{id}`.
- Fonctions : scan du QR `SFD|CY|…` (ou saisie du numéro, recherche client/produit ; QR client `SFD|CL|…` demande le réseau), comparaison avec les lignes du système, constat avec écarts (règles du contrat contrôlées avant envoi), « Préparer hors ligne » (télécharge les lignes des livrets affichés), file locale, envoi automatique, suivi À valider / Validé / Rejeté (+ commentaire du responsable). La décision reste côté bureau.
- Vérifié : 12 livrets préparés, hors ligne scan (saisie de repli) + 2 constats (un incomplet avec écart sur la ligne 3, un conforme) ; au retour du réseau, reçus (écart de montant −500 F calculé par le serveur) ; validation/rejet par le directeur reflétés sur le téléphone. Non testé : lecture caméra réelle du QR, rejeu d'un accusé perdu sur ce flux.

Limites connues :
- La connexion exige le réseau ; la session vit dans sessionStorage : fermer l'application hors réseau oblige à se reconnecter (la file est conservée, un PIN local serait la suite).
- Le service worker n'est actif qu'en build de production ; il est enregistré pour toute l'origine (le bureau aussi, ressources hachées seulement).
- La liste des cycles est celle de l'agence (pas encore filtrée par tournée/zone).
- `schema/mf_schema_complet.sql` n'est pas régénéré (voir Décisions).
- Pas d'installation testée sur un vrai téléphone ; manifeste et service worker validés dans Chrome bureau seulement.
