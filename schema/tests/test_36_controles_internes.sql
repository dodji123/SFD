SET search_path = mf, public;

-- Module sous test : 36_controles_internes.sql (seuils de retrait, fractionnement, comptes dormants, journal en ajout seul)
INSERT INTO agence(code,libelle) VALUES ('LOM','Lomé Centre');
INSERT INTO client(agence_id,nom) VALUES (1,'Client un'),(1,'Client deux');
INSERT INTO produit_epargne(code,libelle,categorie) VALUES ('CL','Compte classique','classique');
INSERT INTO compte_epargne(agence_id,client_id,produit_id,numero,ouvert_le) VALUES
  (1,1,1,'C1', current_date - 400), (1,2,1,'C2', current_date - 10);
INSERT INTO mouvement_epargne(compte_id,type,montant,date_operation) VALUES
  (1,'depot',1000000, current_date - 380), (2,'depot',800000, current_date - 5);

-- ===== A. Seuils par rôle =====
SELECT t.eq('A seuil caissier', seuil_retrait('caissier', 1::smallint)::text, '500000');
SELECT t.eq('A seuil chef', seuil_retrait('chef_agence', 1::smallint)::text, '5000000');
SELECT t.eq('A direction sans plafond', COALESCE(seuil_retrait('directeur', 1::smallint)::text, 'NULL'), 'NULL');
SELECT t.eq('A un agent n''a aucune autonomie', seuil_retrait('agent', 1::smallint)::text, '0');
INSERT INTO parametre(cle, valeur, agence_id, description) VALUES ('retrait_seuil_caissier', '200000', 1, 'seuil local');
SELECT t.eq('A seuil surchargé par agence', seuil_retrait('caissier', 1::smallint)::text, '200000');

-- ===== B. Verdicts : seuil et fractionnement =====
SELECT t.eq('B petit retrait accepté', (SELECT statut FROM controle_seuil_retrait('caissier', 2, 1::smallint, 100000)), 'ok');
SELECT t.eq('B retrait au-dessus du seuil', (SELECT statut FROM controle_seuil_retrait('caissier', 2, 1::smallint, 250000)), 'seuil');
SELECT t.eq('B la direction n''est jamais bloquée', (SELECT statut FROM controle_seuil_retrait('directeur', 2, 1::smallint, 9000000)), 'ok');
SELECT t.eq('B le chef peut ce que le caissier ne peut pas', (SELECT statut FROM controle_seuil_retrait('chef_agence', 2, 1::smallint, 250000)), 'ok');
INSERT INTO mouvement_epargne(compte_id,type,montant,date_operation) VALUES (2,'retrait',150000, current_date);
SELECT t.eq('B cumul du jour du client', retraits_du_jour(2)::text, '150000');
SELECT t.eq('B fractionnement détecté (150 000 + 100 000 > 200 000)', (SELECT statut FROM controle_seuil_retrait('caissier', 2, 1::smallint, 100000)), 'fractionnement');
SELECT t.eq('B le cumul est par client', retraits_du_jour(1)::text, '0');
SELECT t.eq('B un autre jour repart à zéro', retraits_du_jour(2, current_date - 1)::text, '0');
SELECT t.eq('B le verdict donne seuil et cumul', (SELECT seuil::text || '/' || cumul::text FROM controle_seuil_retrait('caissier', 2, 1::smallint, 100000)), '200000/150000');

-- ===== C. Comptes dormants =====
SELECT t.eq('C compte sans mouvement depuis 380 jours : dormant', (SELECT numero || '/' || jours_inactif FROM v_compte_dormant), 'C1/380');
SELECT t.eq('C solde du compte dormant', (SELECT solde::text FROM v_compte_dormant), '1000000');
INSERT INTO parametre(cle, valeur, agence_id, description) VALUES ('dormance_jours', '3', 1, 'test');
SELECT t.eq('C dormance à 3 jours : seul C1 (C2 a bougé ce jour)', (SELECT count(*)::text FROM v_compte_dormant WHERE dernier_mouvement < current_date), '1');

-- ===== D. Journal des connexions en ajout seul =====
INSERT INTO journal_connexion(login, evenement) VALUES ('x', 'succes');
SELECT t.refuse('D modification du journal refusée', 'UPDATE mf.journal_connexion SET login = ''y''');
SELECT t.refuse('D suppression du journal refusée', 'DELETE FROM mf.journal_connexion');
SELECT t.refuse('D vidage du journal refusé', 'TRUNCATE mf.journal_connexion');
