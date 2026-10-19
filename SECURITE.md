# Sécurité : ce qui est en place, ce qui reste à faire

Grille : les sept niveaux du document « Sprint 1 – États financiers, ratios, alertes et rappels de paiement ».
Les textes légaux cités (loi togolaise 2019-014, instructions BCEAO) n'ont pas été relus dans leur version officielle : à confirmer avec la Cellule de Surveillance et un juriste avant la mise en production.

| Niveau | En place dans le logiciel | À faire (hors logiciel ou non encore développé) |
|---|---|---|
| Gouvernance | – | Politique de sécurité écrite, responsable sécurité, analyse de risques annuelle, audit externe, charte informatique |
| Application | Requêtes SQL paramétrées, droits vérifiés côté API, cloisonnement par agence (réponse « introuvable » hors périmètre), docs API désactivées en production, en-têtes de sécurité (nosniff, anti-cadre, no-store), tests automatisés | Revue de code, test d'intrusion avant production, séparation des environnements, protection contre les attaques de débit au niveau du proxy |
| Données | Mots de passe et PIN hachés (bcrypt), codes SMS hachés (HMAC), numéros masqués côté client, aucun secret dans la piste d'audit, **journal d'audit et journal des accès clients en ajout seul** (modification, suppression et vidage refusés par la base), consentements historisés | Chiffrement au repos (disque ou base), TLS 1.2+ sur le serveur, conservation 10 ans (politique de sauvegarde et d'archivage), déclaration à l'IPDCP, masquage dans les futurs exports |
| Réseau et hébergement | – | Pare-feu, VPN entre agences, sauvegardes hors site, plan de continuité testé, hébergement dans le pays |
| Accès et identités | Rôles par fonction, mot de passe de 10 caractères minimum, verrouillage après 5 échecs, réponse identique pour identifiant inconnu ou faux, désactivation immédiate d'un compte, validation de crédit par un responsable, KYC d'un client PPE validé par la direction seulement | Authentification forte pour les rôles sensibles (second facteur du personnel), principe des quatre yeux généralisé, revue trimestrielle des droits |
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
