# Application mobile du collecteur — PWA

## Cadrage

- **Problème** : les agents et collectrices saisissent aujourd'hui leurs collectes sur l'interface bureau (`Collecte.tsx`), qui suppose un écran large et un réseau continu. Sur le terrain, le réseau manque souvent : une collecte non saisie est une collecte perdue ou ressaisie le soir (risque d'erreur et de doublon).
- **Objectif** : une application installable sur téléphone, écrans étroits, où l'agent/collectrice se connecte, voit les cycles à collecter, saisit une collecte en quelques secondes, **même hors réseau**, et voit à tout moment ce qui reste « à synchroniser » ou ce qui a été refusé.
- **Approche la plus simple** : une PWA dans `web/` (pas de dépôt mobile, pas de React Native) sous la route `/m`, qui réutilise `lib/api.ts`, la session JWT et les endpoints existants de lecture (`GET /api/cycles`, `GET /api/collecte/jour`). Les saisies hors ligne vont dans une file IndexedDB ; un seul endpoint nouveau côté API, `POST /api/collecte/sync`, applique un lot de façon idempotente.
- **Hors périmètre de cette étape** : création de cycles, retraits, changement de mise, validation de journée (restent sur le bureau) ; notifications push ; connexion hors ligne (la connexion exige le réseau).

## Décisions

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

Limites connues :
- La connexion exige le réseau ; la session vit dans sessionStorage : fermer l'application hors réseau oblige à se reconnecter (la file est conservée, un PIN local serait la suite).
- Le service worker n'est actif qu'en build de production ; il est enregistré pour toute l'origine (le bureau aussi, ressources hachées seulement).
- La liste des cycles est celle de l'agence (pas encore filtrée par tournée/zone).
- `schema/mf_schema_complet.sql` n'est pas régénéré (voir Décisions).
- Pas d'installation testée sur un vrai téléphone ; manifeste et service worker validés dans Chrome bureau seulement.
