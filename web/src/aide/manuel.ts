// Manuel d'utilisation de la plateforme SFD, affiché dans la page « Aide et manuel ».
// Contenu structuré (et non Markdown) pour rester sans dépendance et s'afficher avec la charte de l'application.
// Les écrans et libellés suivent le menu réel (web/src/components/Layout.tsx). Les fonctions non livrées
// sont signalées comme telles ; voir FONCTIONNALITES.md pour le niveau de chaque fonction.

export interface Section {
  titre: string
  paragraphes?: string[]
  etapes?: string[]
  notes?: string[]
}

export interface Chapitre {
  id: string
  titre: string
  intro: string
  sections: Section[]
}

export const CHAPITRES: Chapitre[] = [
  {
    id: 'prise-en-main',
    titre: 'Prise en main',
    intro: "Connexion, navigation et règles générales qui valent pour tous les écrans.",
    sections: [
      {
        titre: 'Se connecter',
        etapes: [
          "Ouvrez l'adresse de la plateforme dans votre navigateur.",
          "Saisissez votre identifiant et votre mot de passe, puis cliquez sur « Se connecter ».",
          "Si le compte exige un second facteur (code à usage unique), saisissez le code demandé.",
        ],
        notes: [
          "Après plusieurs échecs de connexion, le compte est verrouillé temporairement. Adressez-vous à votre chef d'agence ou à l'administrateur.",
          "Le bouton « Voir » à droite du mot de passe affiche le mot de passe saisi, pour vérifier une frappe.",
        ],
      },
      {
        titre: 'Changer son mot de passe',
        paragraphes: [
          "Le changement de mot de passe invalide toutes les sessions ouvertes avant ce changement : les autres appareils doivent se reconnecter.",
        ],
      },
      {
        titre: 'Naviguer dans la plateforme',
        paragraphes: [
          "Le menu de gauche regroupe les écrans par domaine : Pilotage, Clients, Tontine et collecte, Épargne, Crédit et recouvrement, Caisse et comptabilité, Ressources humaines, Application et administration.",
          "Cliquez sur le nom d'une section pour la replier ou la déployer. Votre choix est conservé sur ce navigateur.",
          "Vous ne voyez que les écrans auxquels votre rôle donne accès. Si un écran vous manque, voyez le chapitre « Rôles et droits ».",
          "Sur téléphone ou tablette étroite, le bouton ☰ en haut ouvre le menu.",
        ],
      },
      {
        titre: "Choisir l'agence de travail",
        paragraphes: [
          "Si votre compte est rattaché à une seule agence, celle-ci s'affiche en haut de l'écran. Si vous intervenez au siège, un sélecteur « Agence » permet de choisir l'agence sur laquelle vous travaillez.",
        ],
      },
      {
        titre: 'Sessions et déconnexion',
        paragraphes: [
          "Votre session se prolonge à chaque action. Après une période d'inactivité, elle expire et il faut vous reconnecter.",
          "Pour quitter, utilisez le bouton « Déconnexion » en haut à droite. Déconnectez-vous toujours sur un poste partagé.",
        ],
      },
      {
        titre: 'Ce que l’on ne peut pas annuler',
        paragraphes: [
          "Les écritures validées (opérations de caisse, décisions de crédit, contrôles de livrets, historique des rôles) ne se modifient pas. Une erreur se corrige par une opération de régularisation ou une nouvelle décision, qui laisse une trace.",
          "La suppression d'une opération exige un motif. L'opération disparaît des écrans et des calculs, mais son contenu d'origine reste consultable dans Administration › Piste d'audit.",
        ],
      },
    ],
  },
  {
    id: 'clients',
    titre: 'Clients',
    intro: "Créer et tenir à jour la fiche client, son identification et son consentement.",
    sections: [
      {
        titre: 'Rechercher et créer un client',
        paragraphes: [
          "L'écran Clients affiche la liste des membres de votre agence ou de votre zone. Recherchez par nom, numéro ou téléphone avant toute création, pour éviter les doublons.",
          "Chaque client reçoit un numéro automatique. Les zones regroupent les clients par secteur de collecte.",
        ],
      },
      {
        titre: 'Dossier KYC (connaissance du client)',
        paragraphes: [
          "Le dossier comprend le type de client, son profil, les pièces justificatives et les liens avec d'autres personnes (par exemple un garant).",
          "Une pièce d'identité expirée doit être renouvelée avant de nouvelles opérations importantes. Le rappel automatique d'expiration n'est pas encore planifié : contrôlez les dates manuellement.",
        ],
        notes: [
          "Le téléversement de fichiers (photo, scan de pièce) n'est pas disponible : les pièces sont enregistrées comme références.",
        ],
      },
      {
        titre: 'Adhésion et pièces',
        paragraphes: [
          "Adhésion et parts : enregistre l'adhésion du client et ses parts sociales (écran de guichet).",
          "Pièces justificatives : liste et suivi des documents attachés au dossier.",
        ],
      },
      {
        titre: 'Consentements',
        paragraphes: [
          "Le client donne ou retire son consentement (espace client, SMS, traitement des données). L'historique des consentements ne peut pas être modifié.",
        ],
      },
      {
        titre: 'Transférer un client',
        paragraphes: [
          "Un client peut être transféré d'une zone à une autre. La zone retenue pour les rapports et les commissions est celle du jour de l'opération.",
          "Le transfert vers une autre agence est partiellement disponible : il n'enregistre pas d'écriture comptable entre agences, et le solde d'épargne doit être réglé à la main.",
        ],
      },
      {
        titre: 'Conformité LBC/FT',
        paragraphes: [
          "L'écran Conformité LBC/FT contrôle les noms des clients et des bénéficiaires contre les listes importées, et produit des alertes à traiter.",
          "Une alerte se décide (levée ou maintenue). Une alerte maintenue bloque l'octroi de crédit au client tant qu'elle n'est pas levée.",
        ],
        notes: [
          "Aucune liste officielle n'est fournie avec le logiciel : elle doit être importée par l'administrateur.",
          "La déclaration de soupçon auprès de la CENTIF se fait hors du logiciel.",
        ],
      },
    ],
  },
  {
    id: 'epargne-tontine',
    titre: 'Épargne, tontine et collecte',
    intro: "Le quotidien du guichet et du terrain : collecte, cycles, retraits, carnets et contrôle des livrets.",
    sections: [
      {
        titre: 'Épargne classique',
        paragraphes: [
          "Le guichet « Épargne classique » enregistre les dépôts et les retraits d'un compte d'épargne, avec le solde minimum et les éventuelles garanties bloquées.",
          "Le tableau du jour liste les opérations de la journée, classées par numéro d'ordre du client.",
        ],
        notes: [
          "Il n'existe pas encore de correction ni de validation de journée pour l'épargne classique.",
        ],
      },
      {
        titre: 'Dépôts de garantie et dépôts à terme',
        paragraphes: [
          "Le dépôt de garantie est bloqué et peut être rattaché à un crédit. Le dépôt à terme a un taux, une échéance et un déblocage ; une rupture anticipée entraîne une pénalité.",
          "Le renouvellement automatique, la retenue fiscale et les comptes dormants ne sont pas gérés.",
        ],
      },
      {
        titre: 'Cycles de tontine',
        paragraphes: [
          "Un cycle regroupe les versements d'un groupe pour une période donnée, avec un livret de 31 lignes. Le type du cycle (1, 2 ou 3) se choisit à chaque nouveau cycle.",
          "Une période de grâce peut être accordée. Une prolongation se demande lors de la saisie et doit être autorisée par un responsable.",
        ],
        notes: [
          "Les valeurs de calcul de la tontine doivent être validées avec le client avant usage.",
        ],
      },
      {
        titre: 'Collecte du jour',
        paragraphes: [
          "Chaque agent saisit les versements de ses clients dans l'écran Collecte du jour. En fin de tournée, il effectue le versement de fin de tournée : le total remis est comparé à la collecte saisie.",
          "Un écart (manque ou surplus) est enregistré pour l'agent et doit être régularisé par le responsable.",
        ],
      },
      {
        titre: 'Retraits et écarts',
        paragraphes: [
          "Un retrait de tontine est demandé par le membre, puis exécuté au guichet. Un écart constaté à l'exécution est suivi dans l'écran Retraits et écarts jusqu'à sa régularisation.",
        ],
      },
      {
        titre: 'Synchronisations à valider',
        paragraphes: [
          "Les collectes faites sur l'application mobile arrivent dans l'écran Synchronisations à valider. Un opérateur les contrôle avant qu'elles deviennent des écritures définitives.",
        ],
      },
      {
        titre: 'Mobile money',
        paragraphes: [
          "Le client peut verser par mobile money ou demander un retrait depuis son espace client. Les demandes apparaissent dans Mobile money et demandes, où elles sont traitées.",
        ],
        notes: [
          "La passerelle de paiement en production n'est pas encore branchée : les versements sont simulés tant qu'elle ne l'est pas.",
        ],
      },
      {
        titre: 'Carnets (livrets papier)',
        paragraphes: [
          "Chaque produit a son livret. Les lots reçus sont enregistrés par agence et par produit, avec des numéros continus (par exemple AGENCE-PRODUIT-000001).",
          "Un carnet est attribué à un cycle du même produit. En cas de perte ou de détérioration, un motif est demandé et un carnet de remplacement est lié à l'ancien.",
          "Une alerte de réapprovisionnement se déclenche sous le seuil paramétré.",
        ],
      },
      {
        titre: 'Contrôle des livrets sur le terrain',
        paragraphes: [
          "Le contrôleur relève l'état du livret, ses lignes et son total, puis le compare à la situation enregistrée dans le système. Les écarts sont relevés ligne à ligne.",
          "Un responsable valide le contrôle. Le contrôleur ne peut pas valider son propre contrôle. Le contrôle décidé ne se modifie plus.",
          "Le scan du QR code du livret ouvre directement le bon carnet.",
        ],
        notes: [
          "Le contrôle hors ligne est disponible dans l'application mobile ; sur le web, les contrôles se saisissent avec l'écran Contrôle des livrets.",
        ],
      },
    ],
  },
  {
    id: 'credit',
    titre: 'Crédit et recouvrement',
    intro: "De la demande de crédit au suivi du portefeuille et aux provisions.",
    sections: [
      {
        titre: 'Demande de crédit',
        paragraphes: [
          "La demande se saisit dans l'écran Crédits : produit, montant, durée et garanties. L'analyse de capacité de remboursement est établie avec la demande ; elle est indicative et ne bloque pas l'approbation.",
          "La demande suit ensuite le circuit d'approbation, puis le déblocage et l'échéancier sont générés.",
        ],
        notes: [
          "Le circuit de validation par niveaux n'est pas encore complet : il n'existe qu'un seul seuil de validation.",
        ],
      },
      {
        titre: 'Comité de crédit',
        paragraphes: [
          "Le comité examine les demandes et enregistre sa décision. Un comité ne peut pas approuver une demande qu'il a lui-même présentée.",
        ],
      },
      {
        titre: 'Remboursements',
        paragraphes: [
          "Un remboursement se fait en espèces, par prélèvement sur un compte d'épargne, ou par prélèvement sur la collecte du jour.",
          "Les pénalités de retard s'appliquent automatiquement selon le contrat. Une garantie peut être saisie après 30 jours de retard.",
        ],
        notes: [
          "Les valeurs de pénalité et de points de fidélité sont provisoires : à faire valider avant usage.",
        ],
      },
      {
        titre: 'Suivi du portefeuille',
        paragraphes: [
          "Le suivi affiche le portefeuille à risque (PAR 1, 30, 60 et 90 jours), les retards, l'activité de la période et le taux de recouvrement.",
        ],
      },
      {
        titre: 'Recouvrement',
        paragraphes: [
          "L'écran Recouvrement liste les dossiers en retard et permet de noter les relances effectuées.",
        ],
      },
      {
        titre: 'Provisions',
        paragraphes: [
          "Les créances sont classées selon leur retard, avec un provisionnement de 40 %, 80 % ou 100 % du solde restant dû, selon une règle paramétrable plus stricte si nécessaire.",
          "Le calcul se fait au choix à la main (bouton) ou automatiquement chaque jour. Le mode automatique suppose que la tâche quotidienne est planifiée sur le serveur par l'administrateur.",
        ],
        notes: [
          "Le déclassement comptable et le passage en perte ne sont pas automatisés. Un mois est compté pour 30 jours.",
        ],
      },
    ],
  },
  {
    id: 'caisse-comptabilite',
    titre: 'Caisse, opérations et comptabilité',
    intro: "Caisse, transferts, charges et produits, trésorerie et états financiers.",
    sections: [
      {
        titre: 'Caisse',
        paragraphes: [
          "La session de caisse s'ouvre au début de la journée et se clôture à la fin. Le billetage compte les espèces et le solde est comparé à la théorie.",
          "Plusieurs caisses peuvent fonctionner en même temps dans une agence.",
        ],
      },
      {
        titre: 'Opérations et transferts',
        paragraphes: [
          "Les opérations générales (versements, paiements, dépenses) se saisissent avec un libellé, un montant et un bénéficiaire. Une opération est validée par une personne autre que son auteur.",
          "Un transfert de fonds entre caisses suit trois étapes : envoi, réception puis, si besoin, refus. Un écart constaté à la réception reste visible jusqu'à sa régularisation.",
        ],
      },
      {
        titre: 'Charges et produits',
        paragraphes: [
          "Les tiers (fournisseurs, prestataires) se créent une fois, puis servent à toutes les opérations. Un budget par ligne permet de comparer le réalisé au prévu.",
          "Les opérations récurrentes (loyer, abonnement) se génèrent automatiquement à chaque échéance. Une alerte signale un écart important de charge ou de produit.",
        ],
      },
      {
        titre: 'Trésorerie',
        paragraphes: [
          "La position de trésorerie donne les soldes des caisses et des comptes bancaires. Les transferts vers les comptes bancaires et le rapprochement se font dans cet écran.",
        ],
      },
      {
        titre: 'Comptabilité et états financiers',
        paragraphes: [
          "La comptabilité présente le plan de comptes, les pièces, la balance, le grand livre et les exercices.",
          "Les états financiers (bilan simplifié, états par agence et consolidés) se consultent dans l'écran États financiers.",
          "La comptabilisation automatique des opérations est désactivée par défaut : elle doit être activée et ses règles validées par le comptable.",
        ],
        notes: [
          "Les états réglementaires par postes et les ratios prudentiels sont disponibles, mais les hypothèses de calcul doivent être validées par le comptable.",
          "Les exports PDF et Excel au format officiel ne sont pas encore disponibles : utilisez le CSV ou l'impression.",
        ],
      },
    ],
  },
  {
    id: 'immobilisations',
    titre: 'Immobilisations et maintenance',
    intro: "Registre des biens, amortissements, pannes, réparations et alertes.",
    sections: [
      {
        titre: 'Enregistrer une immobilisation',
        etapes: [
          "Ouvrez Immobilisations et maintenance dans le menu Caisse et comptabilité.",
          "Cliquez sur « Nouvelle immobilisation ».",
          "Renseignez la désignation, la catégorie, les dates d'acquisition et de mise en service, la valeur d'acquisition et, si besoin, la valeur résiduelle, la localisation et la fin de garantie.",
          "Validez. Le bien reçoit un numéro du type IMM-AGENCE-000001 et apparaît dans le registre en service.",
        ],
        notes: [
          "La durée d'amortissement dépend de la catégorie (mobilier, matériel informatique, véhicule, aménagement, installation, bâtiment). Un terrain n'est pas amorti.",
        ],
      },
      {
        titre: 'Constater les amortissements',
        etapes: [
          "Dans le registre, cliquez sur « Constater les amortissements ».",
          "Les dotations mensuelles dues à la date du jour sont créées. Relancer l'opération ne crée pas de doublon.",
        ],
      },
      {
        titre: 'Sortir un bien de l’inventaire',
        etapes: [
          "Ouvrez la fiche du bien depuis le registre, puis cliquez sur « Sortir de l’inventaire ».",
          "Choisissez le type de sortie : cession (vente, avec le prix), rebut ou perte ou vol.",
          "Indiquez la date de sortie et un motif d'au moins 5 caractères, puis confirmez.",
        ],
        notes: [
          "La sortie clôt les amortissements et les plans de maintenance du bien. Une intervention encore ouverte bloque la sortie.",
          "Une fois sorti, le bien ne peut plus recevoir de panne ni d'intervention.",
        ],
      },
      {
        titre: 'Signaler une panne',
        etapes: [
          "Ouvrez la fiche du bien, puis cliquez sur « Signaler une panne ».",
          "Décrivez la panne, choisissez la priorité (basse, normale, haute, urgente).",
          "Cochez « hors service » si le bien ne peut plus servir jusqu'à réparation : son statut passe alors à hors service.",
        ],
      },
      {
        titre: 'Traiter une intervention',
        paragraphes: [
          "L'onglet « Pannes et interventions » liste les interventions en cours. Chaque intervention suit les états : signalée, planifiée, en cours, terminée ou annulée.",
        ],
        etapes: [
          "« Démarrer » passe l'intervention en cours. Le bien passe en maintenance.",
          "« Terminer » demande la date de fin, le résultat, la main-d'œuvre et les pièces. Si un coût est saisi, la référence de la facture du prestataire est obligatoire.",
          "Une intervention terminée est figée : une erreur se corrige par une nouvelle intervention.",
        ],
        notes: [
          "Le coût est enregistré comme une dépense « entretien et réparation à payer ». Le bien revient en service à la fin de la réparation.",
        ],
      },
      {
        titre: 'Maintenance préventive',
        paragraphes: [
          "Un plan de maintenance fixe une périodicité et une échéance pour un bien. Les interventions préventives à échéance proche sont planifiées par la fonction de génération.",
        ],
      },
      {
        titre: 'Alertes et coûts',
        paragraphes: [
          "L'onglet « Alertes et coûts » signale : maintenance en retard ou à prévoir, réparation trop longue, panne urgente non prise en charge, garantie proche de sa fin, bien totalement amorti mais toujours en service.",
          "Le tableau des coûts donne, par bien, le nombre d'interventions, le coût des réparations et le coût total, à comparer à la valeur d'acquisition.",
        ],
      },
    ],
  },
  {
    id: 'stock-rh-conformite',
    titre: 'Stock, ressources humaines et conformité',
    intro: "Fournitures, personnel et contrôles réglementaires.",
    sections: [
      {
        titre: 'Stock des fournitures',
        paragraphes: [
          "L'écran Stock des fournitures suit les quantités en magasin, les entrées et les sorties de fournitures de bureau et de guichet.",
        ],
      },
      {
        titre: 'Ressources humaines et paie',
        paragraphes: [
          "GRH regroupe les employés, leurs contrats, les congés, les absences, les présences, le recrutement, la formation et les évaluations.",
          "RH et paie calcule les rubriques, les commissions et les bulletins de paie.",
        ],
        notes: [
          "Les taux de cotisations et d'impôt doivent être fournis par l'agence avant tout calcul de paie.",
        ],
      },
      {
        titre: 'Rapports et tableau de bord',
        paragraphes: [
          "Les rapports journaliers donnent le global, le détail par agent et par zone. Le tableau de bord de l'agence présente les compteurs d'exploitation.",
        ],
        notes: [
          "Les indicateurs de productivité et les alertes de dépassement de seuil par e-mail ne sont pas encore disponibles.",
        ],
      },
    ],
  },
  {
    id: 'roles',
    titre: 'Rôles et droits',
    intro: "Qui peut faire quoi, et comment obtenir un rôle temporaire.",
    sections: [
      {
        titre: 'Les rôles de base',
        paragraphes: [
          "Chaque compte a un rôle de base : Administrateur, Directeur, Chef d'agence, Caissier, Comptable, Agent, Collectrice, Ressources humaines, Auditeur ou Coordinateur de réseau.",
          "Le rôle détermine les écrans visibles et les actions possibles. Le menu n'affiche que ce qui est permis.",
        ],
      },
      {
        titre: 'Demander un rôle temporaire',
        etapes: [
          "Ouvrez Rôles et droits dans le menu Caisse et comptabilité, onglet « Affectations ».",
          "Cliquez sur « Demander un rôle temporaire », choisissez la personne, le rôle, la période (six mois au plus) et indiquez le motif, d'au moins 10 caractères.",
          "La demande reste en attente jusqu'à la décision d'un autre responsable.",
        ],
        notes: [
          "Une personne ne peut recevoir un rôle temporaire que si elle est rattachée à votre agence.",
          "On ne peut accorder que des droits qu'on possède soi-même.",
        ],
      },
      {
        titre: 'Valider ou refuser une demande',
        paragraphes: [
          "Un responsable qui a le droit de valider ouvre la demande et la valide ou la refuse, avec un commentaire facultatif. La demande ne peut pas être validée par son auteur.",
          "Une affectation active peut être révoquée à tout moment, avec un motif. La révocation prend effet immédiatement.",
        ],
      },
      {
        titre: 'Matrice des droits et rôles personnalisés',
        paragraphes: [
          "L'onglet « Matrice des droits » indique, pour chaque permission, les rôles qui la détiennent.",
          "Les administrateurs peuvent créer un rôle personnalisé, le désactiver ou le réactiver, et définir ses permissions. Le rôle Administrateur garde toujours la gestion des rôles et des utilisateurs.",
        ],
      },
    ],
  },
  {
    id: 'application-mobile',
    titre: "Application mobile du collecteur",
    intro: "Travailler sur le terrain, hors connexion, avec l'application installable.",
    sections: [
      {
        titre: 'Installer l’application',
        etapes: [
          "Ouvrez la page Application mobile du menu, ou l'adresse /m de la plateforme, sur votre téléphone.",
          "Dans le navigateur, choisissez « Ajouter à l'écran d'accueil » (ou « Installer »).",
          "Ouvrez l'application depuis l'écran d'accueil et connectez-vous avec votre compte.",
        ],
      },
      {
        titre: 'Ce que vous voyez',
        paragraphes: [
          "L'application ne montre que les clients de votre zone. Vous pouvez créer un client, ouvrir un nouveau cycle et saisir une collecte.",
          "Le contrôle des livrets se fait aussi hors connexion.",
        ],
      },
      {
        titre: 'Travailler hors connexion',
        paragraphes: [
          "Les collectes sont enregistrées sur le téléphone. Dès que la connexion revient, l'application les envoie à la plateforme.",
          "Les envois ne sont pas définitifs : un opérateur les valide dans Synchronisations à valider.",
        ],
        notes: [
          "Les reçus et la géolocalisation des collectes ne sont pas encore disponibles.",
        ],
      },
    ],
  },
  {
    id: 'administration',
    titre: 'Administration',
    intro: "Réservé aux administrateurs : comptes, paramètres et piste d'audit.",
    sections: [
      {
        titre: 'Utilisateurs',
        paragraphes: [
          "L'administrateur crée les comptes, leur attribue un rôle de base et une agence, et peut désactiver un compte. Une désactivation coupe la session de la personne immédiatement.",
        ],
      },
      {
        titre: 'Paramètres',
        paragraphes: [
          "Les taux, plafonds, seuils et hypothèses sont regroupés par rubrique : tontine, épargne, crédit, provisions, comptabilité, ressources humaines. Une recherche par texte et des filtres par rubrique facilitent la recherche.",
        ],
        notes: [
          "Toute modification de paramètre est tracée dans la piste d'audit.",
        ],
      },
      {
        titre: "Piste d'audit",
        paragraphes: [
          "La piste d'audit est inaltérable : elle enregistre les opérations, les accès et les modifications, avec l'auteur et la date. Elle contient aussi les opérations supprimées, avec leur motif et leur contenu d'origine.",
        ],
      },
    ],
  },
  {
    id: 'faq',
    titre: 'Questions fréquentes',
    intro: "Les situations les plus courantes et ce qu'il faut faire.",
    sections: [
      {
        titre: '« Accès refusé » sur un écran',
        paragraphes: [
          "Votre rôle ne donne pas accès à cet écran. Demandez un rôle temporaire (chapitre Rôles et droits) ou adressez-vous à votre chef d'agence.",
        ],
      },
      {
        titre: '« Session expirée » ou « Session invalidée »',
        paragraphes: [
          "Votre session a expiré par inactivité, ou le mot de passe a été changé depuis votre connexion. Reconnectez-vous.",
        ],
      },
      {
        titre: 'Je ne vois pas mon agence',
        paragraphes: [
          "Votre compte n'est peut-être pas rattaché à l'agence voulue. Demandez à l'administrateur de vérifier votre rattachement.",
        ],
      },
      {
        titre: 'Mot de passe oublié',
        paragraphes: [
          "Le lien « Mot de passe oublié ? » sur l'écran de connexion lance la procédure. Si elle ne fonctionne pas, adressez-vous à l'administrateur.",
        ],
      },
      {
        titre: 'Un écart de caisse ou de collecte',
        paragraphes: [
          "Un écart n'est jamais effacé. Il reste visible dans la clôture de caisse jusqu'à sa régularisation par un responsable.",
        ],
      },
    ],
  },
]
