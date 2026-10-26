SET search_path = mf, public;

-- =====================================================================
-- 65 : fiche de suivi des tests manuels, renseignée dans l'application.
-- Une ligne par test ; statut à faire / ok / ko ; commentaire libre ; dernier auteur de la saisie.
-- =====================================================================
CREATE TABLE fiche_test_manuel (
  id               serial PRIMARY KEY,
  section          text NOT NULL,
  numero           varchar(5) NOT NULL UNIQUE,
  parcours         text NOT NULL,
  resultat_attendu text NOT NULL,
  statut           varchar(10) NOT NULL DEFAULT 'a_faire' CHECK (statut IN ('a_faire','ok','ko')),
  commentaire      text,
  modifie_par      text,
  modifie_le       timestamptz
);

INSERT INTO fiche_test_manuel(section, numero, parcours, resultat_attendu) VALUES
('Journée de l''agence', 'J1', 'Se connecter en chef.lom, ouvrir « Journée de l''agence ».', 'La page s''affiche, avec « Aucune journée ouverte » et l''historique.'),
('Journée de l''agence', 'J2', 'Ouvrir la journée d''aujourd''hui.', '« Journée ouverte » ; une seconde ouverture est refusée.'),
('Journée de l''agence', 'J3', 'Clôturer la journée alors que des sessions de caisse sont ouvertes.', 'Refus : des sessions de caisse sont encore ouvertes.'),
('Journée de l''agence', 'J4', 'Fermer les sessions de caisse, puis clôturer.', 'La journée passe à « Close ».'),
('Journée de l''agence', 'J5', 'En admin ou chef.lom, rouvrir la journée sans motif, puis avec motif.', 'Sans motif : refus. Avec motif : la journée repasse « Ouverte ».'),
('Journée de l''agence', 'J6', 'Se connecter en caissier.lom, ouvrir la page.', 'Le bouton de réouverture n''apparaît pas.'),
('Retrait de tontine au guichet', 'R1', 'Choisir le produit TON1, saisir « Selom ».', 'Les cycles avec un solde (au moins 2 caractères) s''affichent.'),
('Retrait de tontine au guichet', 'R2', 'Cocher un cycle, puis « Tout cocher ».', 'Le total et le bouton « Retirer » se mettent à jour.'),
('Retrait de tontine au guichet', 'R3', 'Modifier le montant d''un cycle à une valeur inférieure au solde.', 'L''effet affiché est « Retrait partiel… » ; la case « Clôturer le cycle » apparaît si le cycle est en cours.'),
('Retrait de tontine au guichet', 'R4', 'Saisir un montant supérieur au solde.', 'L''effet affiche « Montant invalide » et le bouton reste désactivé.'),
('Retrait de tontine au guichet', 'R5', 'Retirer le solde entier d''un cycle en cours.', 'Le cycle est clôturé puis retiré ; la caissière apparaît dans « Retraits du jour ».'),
('Retrait de tontine au guichet', 'R6', 'Retirer une partie sans cocher « Clôturer le cycle ».', 'Le cycle reste en cours ; le solde restant est diminué.'),
('Retrait de tontine au guichet', 'R7', 'Cliquer sur une ligne de cycle.', 'La fiche s''ouvre dans le même onglet, avec les cases du livret.'),
('Retrait de tontine au guichet', 'R8', 'Sur la fiche, cliquer « ← Retour au retrait ».', 'La page de retrait revient avec le produit et la recherche conservés.'),
('Retrait de tontine au guichet', 'R9', 'Sans session de caisse ouverte, tenter un retrait en espèces.', 'Refus : « Ouvrez une session de caisse ».'),
('Retrait de tontine au guichet', 'R10', 'Sur un cycle dont le contrôle du livret relève un écart non validé, tenter un retrait.', 'Refus : le carnet reste au contrôle.'),
('Retrait de tontine au guichet', 'R11', 'Vérifier le récapitulatif en bas de page.', 'Totaux par zone et par type de retrait cohérents avec les retraits du jour.'),
('Fiche d''un cycle', 'C1', 'Ouvrir un cycle clôturé.', 'Le titre indique « début … · fin réelle … · fin prévue … ».'),
('Fiche d''un cycle', 'C2', 'Ouvrir un cycle en cours.', 'La fin réelle indique « cycle en cours ».'),
('Fiche d''un cycle', 'C3', 'Consulter « Contrôles du livret ».', 'Date, contrôleur, état, lignes et totaux constatés et système, écarts, décision.'),
('Fiche d''un cycle', 'C4', 'Consulter « Détail des collectes ».', 'Une ligne par collecte : page, case, date, montant, mise, origine, agent.'),
('Fiche d''un cycle', 'C5', 'Cliquer « ← Retour au retrait » sur la fiche.', 'Retour à la page de retrait, si la fiche a été ouverte depuis elle.'),
('Type de cycle libre', 'T1', 'Ouvrir un nouveau cycle pour le produit TON1.', 'Le type se choisit librement (1, 2 ou 3) ; il n''est plus marqué « verrouillé ».'),
('Type de cycle libre', 'T2', 'Créer le cycle avec le type 2 sur le produit TON1.', 'Le cycle est créé avec le type 2.'),
('Bilan au format du modèle', 'B1', 'Ouvrir l''onglet « États réglementaires », choisir la date de fin.', 'Le bloc « Bilan au format du modèle » s''affiche, avec brut, amortissements / provisions et net.'),
('Bilan au format du modèle', 'B2', 'Comparer le net du bloc et le total E90 de l''état par postes.', 'Les deux totaux sont identiques.'),
('Bilan au format du modèle', 'B3', 'Vérifier une ligne d''actif : brut moins amortissements = net.', 'Égalité pour chaque poste.'),
('Connexion, rôles et menus', 'A1', 'Se connecter avec un mauvais mot de passe.', 'Message d''identifiants incorrects.'),
('Connexion, rôles et menus', 'A2', 'Se connecter en totp-test avec le mot de passe et le code.', 'Le tableau de bord s''ouvre ; le bloc « Droits insuffisants » n''apparaît pas.'),
('Connexion, rôles et menus', 'A3', 'Ouvrir « Aide et manuel ».', 'Les chapitres s''affichent ; « Imprimer ce chapitre » fonctionne.'),
('Connexion, rôles et menus', 'A4', 'En chef.lom, ouvrir « Immobilisations et maintenance ».', 'Registre, pannes et interventions, alertes et coûts s''affichent.'),
('Connexion, rôles et menus', 'A5', 'En admin, ouvrir « Rôles et droits ».', 'Les onglets Affectations, Matrice des droits et Rôles s''affichent.');
