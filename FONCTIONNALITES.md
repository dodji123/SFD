# Fonctionnalités et niveau de fonctionnalité

État au 19/10/2026. Vérifié par 635 assertions SQL, 116 tests API, `tsc` et build web ; les écrans ont été essayés dans le navigateur sauf mention contraire. Aucun test automatique de l'interface ; parcours de bout en bout vérifié à la main dans Chrome le 19/10/2026 (voir ci-dessous).

**Niveaux**
- **A – Complet** : règles dans la base, API, écran, tests automatiques.
- **B – Fonctionnel** : utilisable de bout en bout, avec des limites connues (indiquées).
- **C – Partiel** : une partie seulement (par exemple l'API sans écran, ou une règle incomplète).
- **D – Ébauche** : structure posée, non branchée ou non testée.
- **E – Absent**.

## Clients et conformité
| Fonctionnalité | Niveau | Précisions |
|---|---|---|
| Fiche client, numérotation, recherche, zones | A | |
| Transfert de client entre zones | A | La zone compte à la date de l'opération (rapports et commissions) |
| Transfert de client entre agences | B | Écran du transfert non essayé dans le navigateur ; aucune écriture comptable inter-agences (solde d'épargne noté pour règlement manuel) |
| KYC : type de client, profil, pièces, liens, validation | B | Expiration des pièces : la tâche existe mais n'est pas planifiée ; pas de téléversement de fichier ni de photo |
| Garants d'un crédit | C | Règles et API ; pas d'écran de saisie |
| LBC/FT : listes, filtrage des noms, alertes, décision, blocage du crédit | B | Aucune liste officielle fournie (à importer) ; la déclaration de soupçon à la CENTIF se fait hors du logiciel |
| Consentements du client (espace client, SMS, données) | A | Historique non modifiable |
| Espace client en ligne (PIN, code SMS, comptes, carnet, échéances, journal d'accès) | B | Passerelle SMS non branchée ; consultation seule |
| Biométrie, identification par empreinte | E | |

## Épargne et tontine
| Fonctionnalité | Niveau | Précisions |
|---|---|---|
| Comptes d'épargne classiques : dépôt, retrait, solde minimum, garantie bloquée | A | Page de guichet « Épargne classique » (n° d'ordre du client, tableau du jour) ; pas de correction ni de validation de journée pour l'épargne |
| Virements tontine ↔ épargne | A | |
| Intérêts de l'épargne, frais de tenue de compte | E | Le taux existe, aucun calcul |
| Dépôts à terme, épargne bloquée, comptes dormants | C | Dépôt de garantie (bloqué, rattachable à un crédit) et dépôt à terme (taux, échéance, déblocage, rupture anticipée avec pénalité) avec pages de saisie et de déblocage. Non couvert : renouvellement automatique, retenue fiscale, comptes dormants, écritures comptables spécifiques |
| Cycles de tontine (types 1, 2, 3), livret de 31 lignes, changement de mise, clôture | A | Valeurs de calcul à faire valider par le client |
| Collecte du jour, versement de fin de tournée, écarts des agents, surplus | A | |
| Retraits de tontine avec écarts, exécution et régularisation | A | |
| Commission des collectrices | B | Taux et plafond provisoires |
| Tontine rotative, à enchères, groupes solidaires avec bureau et parts | E | Le type de client « groupe » existe seulement dans la fiche |
| Application mobile du collecteur hors ligne, reçus, géolocalisation des collectes | E | L'interface s'adapte aux écrans étroits |
| Collecte par mobile money | E | |
| Plafond de fonds détenus par collecteur, alertes de doublons et de retards | E | |

## Crédit
| Fonctionnalité | Niveau | Précisions |
|---|---|---|
| Produits, demande, approbation, déblocage, échéancier | A | |
| Remboursement : espèces, prélèvement sur compte, sur la collecte | A | |
| Pénalités, saisie de garantie après 30 jours, points de fidélité | A | Valeurs provisoires |
| Crédit sur épargne et crédit sans épargne | A | |
| Suivi du portefeuille : PAR 1/30/60/90, retards, activité de période, taux de recouvrement | A | |
| Circuit de validation par niveaux (comités) | C | Un seuil de validation unique |
| Classification des créances et provisionnement (40 %, 80 %, 100 % du solde restant dû, règle interne plus stricte, pièces de dotation et de reprise), au choix **manuel (clic)** ou **automatique (traitement quotidien)** | B | Le mode automatique exige que `python -m app.cli planifier` soit planifié sur le serveur ; Le déclassement comptable (transfert vers les comptes 2921 à 294) et le passage en perte ne sont pas automatisés ; un mois = 30 jours |
| Remboursement anticipé, rééchelonnement, contentieux, passage en perte, relances | E | |
| Scoring de crédit | E | |

## Caisse et trésorerie
| Fonctionnalité | Niveau | Précisions |
|---|---|---|
| Sessions de caisse, billetage, clôture, plusieurs caisses | A | |
| Transferts entre caisses, comptes bancaires, rapprochement | A | |
| Position de trésorerie et prévision | A | |
| Opérations inter-agences | E | |

## Comptabilité et états
| Fonctionnalité | Niveau | Précisions |
|---|---|---|
| Plan de comptes SFD UMOA (1 440 comptes), pièces, balance, grand livre, exercices | A | Libellés extraits d'un PDF, non relus un par un |
| Comptabilisation automatique des opérations | C | Désactivée par défaut ; règles et comptes à faire valider par le comptable |
| Clôture d'exercice avec à-nouveaux | E | |
| Bilan simplifié, états par agence et consolidés | A | Consolidation = somme des agences |
| États réglementaires par postes (bilan, compte de résultat, hors-bilan) | B | Montants nets seulement ; sans tableaux annexes, soldes intermédiaires de gestion ni version allégée |
| Ratios prudentiels I à IX, seuils paramétrables, historique, saisies complémentaires | B | Hypothèses de calcul paramétrables et validables par le comptable ; durées résiduelles saisies à la main |
| Rapprochement des fiches (crédits, épargne, provisions) avec la comptabilité, validation par le comptable, signalement avant consolidation | B | Intérêts courus, tontine et comptes d'attente non rapprochés ; la régularisation d'un écart reste une saisie du comptable |
| Exports PDF et Excel au format officiel, dépôt BCEAO | E | CSV et impression disponibles |
| Rapport financier opérationnel (produits, charges, résultat) | A | Document de travail |

## Pilotage, alertes et communication
| Fonctionnalité | Niveau | Précisions |
|---|---|---|
| Rapports journaliers (global, par agent, par zone) | A | |
| Tableau de bord d'agence | C | Compteurs d'exploitation uniquement |
| Indicateurs de productivité, d'autosuffisance, de performance sociale | E | |
| Alertes de dépassement de seuil (ratios, PAR, écarts de caisse), e-mails | E | |
| Rappels de paiement par SMS (J-3, J-1, J, J+1, J+7, J+30) | D | File des SMS et règle anti-doublon posées ; pas de planification, de modèles ni de passerelle |
| Planificateur des traitements quotidiens | C | Testé pour la tâche de provisions (rejeu sans doublon, échecs journalisés) ; les autres tâches n'ont pas de test dédié et rien ne le déclenche seul : à planifier sur le serveur |

## Ressources humaines
| Fonctionnalité | Niveau | Précisions |
|---|---|---|
| Employés, contrats, rubriques, commissions, bulletins de paie | B | Taux de cotisations et d'impôt non fournis |

## Sécurité et administration
| Fonctionnalité | Niveau | Précisions |
|---|---|---|
| Comptes, rôles, droits par fonction, cloisonnement par agence | A | |
| Verrouillage après échecs, jeton court, désactivation immédiate | A | |
| Piste d'audit non modifiable, journal des accès clients | A | |
| Paramétrage (taux, plafonds, seuils, hypothèses) | B | Écran d'administration pour les paramètres ; les produits se créent par l'API ou l'administration |
| Authentification forte du personnel (second facteur) | E | |
| Principe des quatre yeux généralisé, alertes d'opérations atypiques | E | |
| Sauvegardes, chiffrement au repos, TLS, plan de reprise | E | Relèvent de l'hébergement ; décrits dans SECURITE.md |

## Spécifique UEMOA
| Fonctionnalité | Niveau | Précisions |
|---|---|---|
| Multi-agences avec siège et consolidation | A | |
| Formes juridiques et organes (assemblée, conseil, comité) | E | |
| Plafond de l'usure et taux effectif global | E | |
| Analyse de capacité de remboursement (taux d'endettement, couverture, mise journalière, score et avis, garanties avec décote, ventes saisonnières, scénarios, groupe solidaire, rapport imprimable) | A | Rattachée à chaque demande de crédit ; politique paramétrable (seuils, pondérations, plafonds par cycle) ; dettes déjà dues à l'institution reprises automatiquement ; indicative (ne bloque pas l'approbation). Les valeurs de départ de la politique sont des repères à remplacer |
| Parts sociales, dividendes, ristournes | C | Chaque compte d'épargne a sa propre adhésion (droit d'adhésion) et sa souscription de parts, ouvertes avec le compte ; écran de guichet ; sortie du compte avec remboursement des parts ; opérations refusées sur un compte sans adhésion en règle (paramétrable). Non couvert : remboursement des parts à la sortie, dividendes, ristournes, libération échelonnée, écritures de capital |
| Réseaux et faîtières (consolidation d'unions) | C | Consolidation du réseau d'une institution seulement |
| Finance islamique | E | |
| Multilingue, langues locales ; hors ligne ; multi-devises | E | Français et franc CFA uniquement |

## Vérification de bout en bout dans Chrome (19/10/2026)
Parcours joué à la main avec les comptes de démonstration, sur la base de développement : connexion du personnel ; passage dans les 14 pages du menu sans erreur de console ; création d'un client ; profil, pièce d'identité et validation du KYC ; consentement ; ouverture de l'accès à l'espace client et affichage unique du PIN provisoire ; connexion du client (PIN, code SMS, refus d'un PIN trop simple, message identique pour un mauvais PIN, changement obligatoire du PIN) ; ouverture d'un compte d'épargne et dépôt par l'agence, visible ensuite dans l'espace du client avec le numéro de compte masqué ; journal des accès côté agence ; fermeture automatique de la session client après 5 minutes d'inactivité ; blocage de l'accès par l'agence avec coupure immédiate de la session du client ; onglets des ratios, du rapprochement et des provisions. Non rejoué dans Chrome : crédit (demande, déblocage, remboursement), tontine et collecte, caisse, paie, transfert d'agence.
