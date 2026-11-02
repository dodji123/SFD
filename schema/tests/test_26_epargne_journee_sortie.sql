SET search_path = mf, public;

-- Module sous test : 26_epargne_journee_sortie.sql (annulation par contre-passation sur la date ouverte, sortie d'un membre)
INSERT INTO agence(code,libelle) VALUES ('LOM','Lomé Centre');
INSERT INTO utilisateur(agence_id,login,nom,role) VALUES (1,'chef','Chef','chef_agence');
INSERT INTO produit_epargne(code,libelle,categorie,solde_minimum) VALUES ('CL','Classique','classique',1000);
INSERT INTO produit_epargne(code,libelle,categorie,type_cycle) VALUES ('T1','Tontine','collecte',1);
INSERT INTO client(agence_id,nom) VALUES (1,'Membre un'),(1,'Membre deux');
INSERT INTO compte_epargne(agence_id,client_id,produit_id) VALUES (1,1,1),(1,2,1);

-- ===== A. Annulation par contre-passation : seulement sur la date d'opération ouverte =====
SELECT t.ouvrir(current_date - 3);
INSERT INTO mouvement_epargne(compte_id,type,montant,date_operation) VALUES (1,'depot',20000,current_date - 3),(1,'depot',4000,current_date - 3);
SELECT t.ouvrir(current_date - 2);
INSERT INTO mouvement_epargne(compte_id,type,montant,date_operation) VALUES (1,'retrait',5000,current_date - 2);
SELECT t.eq('A solde de départ', solde::text, '19000') FROM v_solde_compte_epargne WHERE compte_id = 1;
SELECT t.refuse('A annulation d''un mouvement d''une date close refusée', 'SELECT mf.annuler_mouvement_epargne(2, 1)');
SELECT annuler_mouvement_epargne(3, 1);
SELECT t.eq('A l''annulation d''un retrait rend les fonds', solde::text, '24000') FROM v_solde_compte_epargne WHERE compte_id = 1;
SELECT t.eq('A contre-passation de même date et référencée', type || '/' || montant || '/' || reference || '/' || (date_operation = current_date - 2)::text, 'depot/5000/annulation:3/true')
  FROM mouvement_epargne WHERE reference = 'annulation:3';
SELECT t.refuse('A double annulation', 'SELECT mf.annuler_mouvement_epargne(3, 1)');
SELECT t.refuse('A une annulation ne s''annule pas', 'SELECT mf.annuler_mouvement_epargne((SELECT id FROM mf.mouvement_epargne WHERE reference = ''annulation:3''), 1)');
SELECT t.refuse('A mouvement inconnu', 'SELECT mf.annuler_mouvement_epargne(999, 1)');

-- ===== B. Saisie sur la date d'opération ouverte uniquement =====
SELECT t.ouvrir(current_date);
SELECT t.refuse('B dépôt sur une date close refusé', 'INSERT INTO mf.mouvement_epargne(compte_id,type,montant,date_operation) VALUES (2, ''depot'', 500, current_date - 1)');
INSERT INTO mouvement_epargne(compte_id,type,montant,date_operation) VALUES (2,'depot',500,current_date),(2,'depot',700,current_date);
SELECT t.eq('B saisies sur la date ouverte', count(*)::text, '2') FROM mouvement_epargne WHERE compte_id = 2;

-- ===== C. Sortie d'un membre : compte, adhésion et parts (module 27) =====
INSERT INTO adhesion(agence_id,client_id,compte_id,date_adhesion,droit_adhesion) VALUES (1,2,2,current_date - 10,2000);
SELECT souscrire_parts_compte(2, 3, current_date - 10, 1);
SELECT t.refuse('C solde encore présent', 'SELECT mf.radier_adhesion_compte(2, current_date, 1)');
UPDATE produit_epargne SET solde_minimum = 0 WHERE code = 'CL';   -- la clôture du compte libère le solde minimum
INSERT INTO mouvement_epargne(compte_id,type,montant,date_operation) VALUES (2,'retrait',1200,current_date);
SELECT t.eq('C solde vidé', solde::text, '0') FROM v_solde_compte_epargne WHERE compte_id = 2;
SELECT t.refuse('C sortie à une date future', 'SELECT mf.radier_adhesion_compte(2, current_date + 1, 1)');
SELECT t.eq('C parts remboursées : 3 x 5000', radier_adhesion_compte(2, current_date, 1)::text, '15000');
SELECT t.eq('C adhésion radiée et compte clos', a.statut || '/' || r.montant || '/' || ce.statut, 'radiee/15000/clos')
  FROM adhesion a JOIN remboursement_part r ON r.adhesion_id = a.id JOIN compte_epargne ce ON ce.id = a.compte_id WHERE a.compte_id = 2;
SELECT t.refuse('C déjà radiée', 'SELECT mf.radier_adhesion_compte(2, current_date, 1)');

-- ===== D. Date close : plus aucune saisie d'épargne =====
SELECT cloturer_date_operation();
SELECT t.refuse('D dépôt refusé une fois la date close', 'INSERT INTO mf.mouvement_epargne(compte_id,type,montant,date_operation) VALUES (1,''depot'',100,current_date)');
