SET search_path = mf, public;

-- Module sous test : 37_recouvrement.sql (recouvrement par étapes, passage en perte, rééchelonnement)
INSERT INTO agence(code,libelle) VALUES ('LOM','Lomé Centre');
INSERT INTO client(agence_id,nom) VALUES (1,'Débiteur');
INSERT INTO produit_credit_epargne(code,libelle,type,taux_annuel) VALUES ('PC','Produit','sans_epargne',0.18);
INSERT INTO utilisateur(login,nom,role,agence_id) VALUES ('agentrec','Agent recouvrement','agent',1),('dir','Directeur','directeur',NULL);
INSERT INTO demande_credit(agence_id,client_id,produit_id,montant,nb_echeances,taux,mode_remboursement,statut)
  VALUES (1,1,1,300000,3,0.18,'especes','debloquee');
INSERT INTO credit(agence_id,numero,client_id,type,montant_accorde,taux,date_deblocage,nb_echeances,mode_remboursement,statut)
  VALUES (1,'CR-1',1,'sans_epargne',300000,0.18,current_date - 600,3,'especes','en_retard');
UPDATE demande_credit SET credit_id = 1;
INSERT INTO echeance(credit_id,no_echeance,date_prevue,capital,interet,statut) VALUES
  (1,1,current_date - 570,100000,4500,'echue'),(1,2,current_date - 540,100000,3000,'echue'),(1,3,current_date - 510,100000,1500,'echue');

SELECT t.eq('A jours de retard', jours_retard_credit(1)::text, '570');
INSERT INTO credit(agence_id,numero,client_id,type,montant_accorde,taux,date_deblocage,nb_echeances,mode_remboursement,statut)
  VALUES (1,'CR-2',1,'sans_epargne',50000,0.18,current_date - 10,1,'especes','en_cours');
SELECT t.refuse('A seul un crédit en retard ouvre un dossier', 'SELECT mf.ouvrir_dossier_recouvrement(2)');
SELECT ouvrir_dossier_recouvrement(1, (SELECT id FROM utilisateur WHERE login='agentrec'));
SELECT t.eq('A dossier ouvert à l''amiable, montant dû = capital restant', statut || '/' || montant_du_ouverture, 'amiable/300000') FROM dossier_recouvrement WHERE id = 1;
SELECT t.refuse('A un seul dossier ouvert par crédit', 'SELECT mf.ouvrir_dossier_recouvrement(1)');

-- ===== B. Enchaînement des étapes =====
SELECT t.refuse('B mise en demeure sans amiable', 'INSERT INTO mf.action_recouvrement(dossier_id,type) VALUES (1,''mise_en_demeure'')');
SELECT t.refuse('B vente de garantie sans mise en demeure', 'INSERT INTO mf.action_recouvrement(dossier_id,type,valeur_estimee) VALUES (1,''vente_garantie'',100000)');
SELECT t.refuse('B accord amiable sans montant ni date', 'INSERT INTO mf.action_recouvrement(dossier_id,type) VALUES (1,''accord_amiable'')');
INSERT INTO action_recouvrement(dossier_id,type,resultat) VALUES (1,'relance','SMS envoyé'),(1,'appel','Injoignable');
SELECT t.refuse('B passage en perte avant mise en demeure', 'SELECT mf.passer_en_perte(1, (SELECT id FROM mf.utilisateur WHERE login=''dir''), ''Créance irrécouvrable après démarches'')');
INSERT INTO action_recouvrement(dossier_id,type,resultat) VALUES (1,'mise_en_demeure','Courrier remis');
SELECT t.eq('B statut après mise en demeure', statut, 'mise_en_demeure') FROM dossier_recouvrement WHERE id = 1;
SELECT t.refuse('B vente de garantie sans évaluation', 'INSERT INTO mf.action_recouvrement(dossier_id,type) VALUES (1,''vente_garantie'')');
INSERT INTO action_recouvrement(dossier_id,type,valeur_estimee,resultat) VALUES (1,'vente_garantie',80000,'Vente du stock');
SELECT t.eq('B statut réalisation des garanties', statut, 'garanties') FROM dossier_recouvrement WHERE id = 1;
SELECT t.refuse('B une action est immuable', 'UPDATE mf.action_recouvrement SET resultat = ''x''');

-- ===== C. Passage en perte =====
SELECT t.refuse('C sans visite du client', 'SELECT mf.passer_en_perte(1, (SELECT id FROM mf.utilisateur WHERE login=''dir''), ''Créance irrécouvrable après démarches'')');
INSERT INTO action_recouvrement(dossier_id,type,resultat) VALUES (1,'visite','Client insolvable constaté sur place');
SELECT t.refuse('C approbateur = agent de recouvrement', 'SELECT mf.passer_en_perte(1, (SELECT id FROM mf.utilisateur WHERE login=''agentrec''), ''Créance irrécouvrable après démarches'')');
SELECT t.refuse('C motif trop court', 'SELECT mf.passer_en_perte(1, (SELECT id FROM mf.utilisateur WHERE login=''dir''), ''court'')');
UPDATE parametre SET valeur = '1000' WHERE cle = 'perte_min_retard_jours';
SELECT t.refuse('C retard insuffisant (570 < 1000)', 'SELECT mf.passer_en_perte(1, (SELECT id FROM mf.utilisateur WHERE login=''dir''), ''Créance irrécouvrable après démarches'')');
UPDATE parametre SET valeur = '365' WHERE cle = 'perte_min_retard_jours';
SELECT passer_en_perte(1, (SELECT id FROM utilisateur WHERE login='dir'), 'Créance irrécouvrable après démarches complètes');
SELECT t.eq('C radiation enregistrée', (SELECT capital_restant::text FROM radiation_credit WHERE credit_id = 1), '300000');
SELECT t.eq('C dossier clos en perte', statut, 'perte') FROM dossier_recouvrement WHERE id = 1;
SELECT t.refuse('C plus d''action sur un dossier clos', 'INSERT INTO mf.action_recouvrement(dossier_id,type) VALUES (1,''relance'')');

-- ===== D. Rééchelonnement et clôture =====
INSERT INTO credit(agence_id,numero,client_id,type,montant_accorde,taux,date_deblocage,nb_echeances,mode_remboursement,statut)
  VALUES (1,'CR-3',1,'sans_epargne',90000,0.18,current_date - 100,3,'especes','en_retard');
INSERT INTO demande_credit(agence_id,client_id,produit_id,montant,nb_echeances,taux,mode_remboursement,statut,credit_id)
  VALUES (1,1,1,90000,3,0.18,'especes','debloquee',3);
INSERT INTO echeance(credit_id,no_echeance,date_prevue,capital,interet,statut) VALUES (3,1,current_date - 30,30000,900,'echue');
SELECT reechelonner_credit(3, 6);
SELECT t.eq('D nouvelle demande liée, capital restant', (SELECT montant::text || '/' || statut || '/' || reechelonne_de FROM demande_credit WHERE reechelonne_de = 3), '90000/demandee/3');
SELECT t.refuse('D un seul rééchelonnement à la fois', 'SELECT mf.reechelonner_credit(3, 6)');
SELECT t.refuse('D crédit en cours non rééchelonnable', 'SELECT mf.reechelonner_credit(2, 6)');
SELECT ouvrir_dossier_recouvrement(3);
SELECT t.refuse('D clôture « réglé » exige un crédit soldé', 'SELECT mf.cloturer_dossier_regle((SELECT id FROM mf.dossier_recouvrement WHERE credit_id = 3))');
UPDATE credit SET statut = 'solde', date_solde = current_date WHERE id = 3;
SELECT cloturer_dossier_regle((SELECT id FROM dossier_recouvrement WHERE credit_id = 3));
SELECT t.eq('D dossier réglé', statut, 'regle') FROM dossier_recouvrement WHERE credit_id = 3;
