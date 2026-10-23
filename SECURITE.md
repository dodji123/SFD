# Sécurité : ce qui est en place, ce qui reste à faire

Grille : les sept niveaux du document « Sprint 1 – États financiers, ratios, alertes et rappels de paiement ».
Les textes légaux cités (loi togolaise 2019-014, instructions BCEAO) n'ont pas été relus dans leur version officielle : à confirmer avec la Cellule de Surveillance et un juriste avant la mise en production.

| Niveau | En place dans le logiciel | À faire (hors logiciel ou non encore développé) |
|---|---|---|
| Gouvernance | – | Politique de sécurité écrite, responsable sécurité, analyse de risques annuelle, audit externe, charte informatique |
| Application | Requêtes SQL paramétrées, droits vérifiés côté API, cloisonnement par agence (réponse « introuvable » hors périmètre), docs API désactivées en production, en-têtes de sécurité (nosniff, anti-cadre, no-store), tests automatisés | Revue de code, test d'intrusion avant production, séparation des environnements, protection contre les attaques de débit au niveau du proxy |
| Données | Mots de passe et PIN hachés (bcrypt), codes SMS hachés (HMAC), numéros masqués côté client, aucun secret dans la piste d'audit, **journal d'audit et journal des accès clients en ajout seul** (modification, suppression et vidage refusés par la base), consentements historisés | Chiffrement au repos (disque ou base), TLS 1.2+ sur le serveur, conservation 10 ans (politique de sauvegarde et d'archivage), déclaration à l'IPDCP, masquage dans les futurs exports |
| Réseau et hébergement | – | Pare-feu, VPN entre agences, sauvegardes hors site, plan de continuité testé, hébergement dans le pays |
| Accès et identités | Rôles par fonction, mot de passe de 10 caractères minimum, verrouillage après 5 échecs, réponse identique pour identifiant inconnu ou faux, désactivation immédiate d'un compte, validation de crédit par un responsable, KYC d'un client PPE validé par la direction seulement, **second facteur TOTP du personnel** (obligatoire pour administrateur, directeur, chef d'agence et comptable ; voir plus bas) | Principe des quatre yeux généralisé, revue trimestrielle des droits |
| Exploitation | Piste d'audit des tables sensibles (valeurs avant et après, utilisateur), journal des accès clients (réussites, échecs, verrouillages, blocages), erreurs sans détail technique | Sauvegardes quotidiennes avec test de restauration, supervision et alertes de sécurité, procédure de gestion et de déclaration des incidents |
| Terrain | – | Application mobile avec base chiffrée, effacement à distance, appareil enregistré, clés d'API opérateurs hors dépôt |

## Espace client (`/espace`)

- **Ouverture par l'agence seulement** : client actif, KYC complet, téléphone renseigné, consentement « espace client » recueilli, aucune alerte de sanction. Le PIN provisoire est affiché une fois au personnel, à remettre en main propre.
- **Connexion en deux temps** : numéro + PIN, puis code à 6 chiffres envoyé par SMS (valable 5 minutes, 3 essais, usage unique, 3 codes maximum par quart d'heure).
- **Première connexion** : changement de PIN obligatoire (6 à 8 chiffres, sans suite ni répétition).
- **Verrouillage** après 5 PIN erronés ; limitation des tentatives par adresse IP.
- **Session courte** (15 minutes) et fermeture après 5 minutes d'inactivité ; jeton de type « client », refusé par toutes les routes du personnel (et l'inverse).
- **Coupure immédiate** : blocage par l'agence, retrait du consentement, client désactivé ou alerte de sanction interrompent aussi les sessions déjà ouvertes.
- **Cloisonnement** : l'identifiant du client vient du jeton ; un client ne peut lire ni le compte, ni le carnet, ni le crédit d'un autre (réponse « introuvable »).
- **Consultation seulement** : aucune opération financière n'est possible depuis l'espace client.
- **Journal** : chaque accès est tracé (non modifiable) ; le client voit ses 20 derniers accès pour repérer une connexion suspecte.
- **SMS** : aucune passerelle n'est branchée (mode « console » en développement, refus en production). Brancher le fournisseur dans `api/app/sms.py` avant d'ouvrir l'espace client. Le SMS de code ne contient jamais de solde, et la file `sms_outbox` n'en conserve pas le code.
- **Limites connues** : la limitation par IP est en mémoire (un seul processus) ; la preuve de possession du téléphone repose sur le SMS (échange de SIM possible) ; pas d'enregistrement d'appareil ; pas de biométrie.

## Second facteur du personnel (TOTP, module 55)

- **Qui** : obligatoire pour `admin`, `directeur`, `chef_agence`, `comptable` (réglable : `SFD_TOTP_ROLES`) ; facultatif pour les autres rôles (qui peuvent l'activer). Coupure possible en développement seulement : `SFD_TOTP_OBLIGATOIRE=false` (c'est `true` par défaut ; le `.env` de développement le désactive).
- **Connexion en deux temps** : mot de passe, puis code à 6 chiffres (RFC 6238, SHA-1, pas de 30 s, tolérance ±1 pas) ou code de secours. Entre les deux, l'API ne délivre qu'un « défi » de 5 minutes qui n'ouvre aucune route ; aucun jeton de session avant le second code. Les échecs du second facteur comptent dans le même compteur que le mot de passe (verrouillage après 5, alerte, journal `totp_echec`).
- **Enrôlement obligatoire** : un rôle sensible sans second facteur obtient une session qui n'ouvre que `/api/auth/totp/*` et `/api/auth/me` ; toute autre route répond 403 jusqu'à l'activation (écran « Second facteur obligatoire » sur le bureau et sur la PWA `/m`). Le secret n'est actif qu'après la preuve de possession (premier code valide).
- **Codes de secours** : 10 codes à usage unique, montrés une seule fois, hachés en base (SHA-256) ; régénération sur présentation d'un code TOTP (les anciens meurent) ; alerte `totp_secours_bas` quand il en reste 2 ou moins.
- **Secret** : chiffré (Fernet) avant d'aller en base, clé `SFD_TOTP_KEY` (à défaut dérivée de `SFD_JWT_SECRET`) ; format `v1:…` pour permettre une rotation de clé. **Anti-rejeu** : un pas accepté ne se rejoue pas (le déclencheur SQL refuse tout recul de `dernier_pas`).
- **Réinitialisation (téléphone perdu, codes épuisés)** : par un responsable (`totp:reinitialiser` : administrateur, directeur) avec motif obligatoire ; jamais pour soi-même ; seul un administrateur réinitialise un administrateur ou un directeur. Les sessions ouvertes sont coupées (`sessions_depuis`), l'événement `totp_reinit` est journalisé et une alerte est levée. Un rôle sensible ne peut pas retirer lui-même son second facteur.
- **Espace client** : inchangé (PIN + SMS). Les jetons « client » et « défi » sont refusés par toutes les routes du personnel.
- **Reste à faire / hors logiciel** : pas de QR code (saisie manuelle de la clé ou lien `otpauth://`) ; pas de clé matérielle (WebAuthn) ; procédure d'identification d'une personne avant réinitialisation (à écrire) ; la double validation de la réinitialisation arrivera avec les « quatre yeux » (incrément suivant) ; sauvegarde sécurisée de `SFD_TOTP_KEY` (sans elle, tous les secrets deviennent illisibles).
