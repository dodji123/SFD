SET search_path = mf, public;

-- Module sous test : 38_procuration_cheques.sql (procurations, chèques à signatures multiples, comptes dormants)
INSERT INTO agence(code,libelle) VALUES ('LOM','Lomé Centre');
INSERT INTO client(agence_id,nom) VALUES (1,'Client un');
INSERT INTO produit_epargne(code,libelle,categorie) VALUES ('CL','Compte classique','classique');
INSERT INTO compte_epargne(agence_id,client_id,produit_id,numero,ouvert_le) VALUES (1,1,1,'C1', current_date - 500);
INSERT INTO utilisateur(login,nom,role,agence_id) VALUES ('cais','Caissier','caissier',1),('chef','Chef','chef_agence',1);
INSERT INTO utilisateur(login,nom,role) VALUES ('dir','Directeur','directeur'),('cpt','Comptable','comptable'),('adm','Admin','admin');
INSERT INTO mouvement_epargne(compte_id,type,montant,date_operation) VALUES (1,'depot',500000, current_date - 450);
INSERT INTO compte_banque(agence_id,code,libelle) VALUES (1,'BQ','Banque');

-- ===== A. Procurations =====
INSERT INTO procuration(agence_id,compte_id,mandataire_nom,mandataire_piece,plafond,cree_par)
  VALUES (1,1,'Mandataire','CNI 123456',100000,(SELECT id FROM utilisateur WHERE login='cais'));
SELECT t.refuse('A retrait avec procuration non validée', 'INSERT INTO mf.mouvement_epargne(compte_id,type,montant,procuration_id) VALUES (1,''retrait'',50000,1)');
SELECT t.refuse('A validation par le créateur', 'SELECT mf.valider_procuration(1, (SELECT id FROM mf.utilisateur WHERE login=''cais''))');
SELECT valider_procuration(1, (SELECT id FROM utilisateur WHERE login='chef'));
INSERT INTO mouvement_epargne(compte_id,type,montant,procuration_id) VALUES (1,'retrait',50000,1);
SELECT t.eq('A retrait par mandataire accepté', count(*)::text, '1') FROM mouvement_epargne WHERE procuration_id = 1;
SELECT t.refuse('A au-dessus du plafond de la procuration', 'INSERT INTO mf.mouvement_epargne(compte_id,type,montant,procuration_id) VALUES (1,''retrait'',150000,1)');
SELECT t.refuse('A procuration sur un dépôt', 'INSERT INTO mf.mouvement_epargne(compte_id,type,montant,procuration_id) VALUES (1,''depot'',1000,1)');
UPDATE procuration SET fin = current_date - 1, debut = current_date - 30 WHERE id = 1;
SELECT t.refuse('A procuration expirée', 'INSERT INTO mf.mouvement_epargne(compte_id,type,montant,procuration_id) VALUES (1,''retrait'',10000,1)');
UPDATE procuration SET statut = 'revoquee' WHERE id = 1;
SELECT t.refuse('A procuration révoquée', 'INSERT INTO mf.mouvement_epargne(compte_id,type,montant,date_operation,procuration_id) VALUES (1,''retrait'',10000,current_date - 5,1)');

-- ===== B. Chèques =====
INSERT INTO cheque_emission(agence_id,compte_banque_id,numero_cheque,beneficiaire,objet,montant,cree_par)
  VALUES (1,1,'0001','Fournisseur','Facture',300000,(SELECT id FROM utilisateur WHERE login='cais'));
SELECT t.eq('B deux signatures sous le plafond', trois_signatures::text, 'false') FROM cheque_emission WHERE numero_cheque = '0001';
SELECT t.refuse('B émission sans signature', 'SELECT mf.emettre_cheque(1)');
SELECT t.refuse('B le caissier ne signe pas en directeur', 'INSERT INTO mf.cheque_signature(cheque_id,utilisateur_id,fonction) VALUES (1,(SELECT id FROM mf.utilisateur WHERE login=''cais''),''directeur'')');
INSERT INTO cheque_signature(cheque_id,utilisateur_id,fonction) VALUES (1,(SELECT id FROM utilisateur WHERE login='dir'),'directeur');
SELECT t.refuse('B une seule signature : insuffisant', 'SELECT mf.emettre_cheque(1)');
SELECT t.refuse('B signature du président non requise sous le plafond', 'INSERT INTO mf.cheque_signature(cheque_id,utilisateur_id,fonction) VALUES (1,(SELECT id FROM mf.utilisateur WHERE login=''adm''),''president_ca'')');
INSERT INTO cheque_signature(cheque_id,utilisateur_id,fonction) VALUES (1,(SELECT id FROM utilisateur WHERE login='cpt'),'comptable');
SELECT emettre_cheque(1);
SELECT t.eq('B chèque émis', statut, 'emis') FROM cheque_emission WHERE id = 1;
SELECT t.refuse('B plus de signature après émission', 'INSERT INTO mf.cheque_signature(cheque_id,utilisateur_id,fonction) VALUES (1,(SELECT id FROM mf.utilisateur WHERE login=''adm''),''comptable'')');
INSERT INTO cheque_emission(agence_id,compte_banque_id,numero_cheque,beneficiaire,objet,montant,cree_par)
  VALUES (1,1,'0002','Fournisseur','Gros achat',2000000,(SELECT id FROM utilisateur WHERE login='cais'));
SELECT t.eq('B trois signatures au-delà du plafond', trois_signatures::text, 'true') FROM cheque_emission WHERE numero_cheque = '0002';
INSERT INTO cheque_signature(cheque_id,utilisateur_id,fonction) SELECT c.id,u.id,'directeur' FROM cheque_emission c, utilisateur u WHERE c.numero_cheque='0002' AND u.login='dir';
INSERT INTO cheque_signature(cheque_id,utilisateur_id,fonction) SELECT c.id,u.id,'comptable' FROM cheque_emission c, utilisateur u WHERE c.numero_cheque='0002' AND u.login='cpt';
SELECT t.refuse('B deux signatures sur trois requises', 'SELECT mf.emettre_cheque((SELECT id FROM mf.cheque_emission WHERE numero_cheque = ''0002''))');
INSERT INTO cheque_signature(cheque_id,utilisateur_id,fonction) SELECT c.id,u.id,'president_ca' FROM cheque_emission c, utilisateur u WHERE c.numero_cheque='0002' AND u.login='adm';
SELECT emettre_cheque((SELECT id FROM cheque_emission WHERE numero_cheque = '0002'));
SELECT t.refuse('B le montant d''un chèque ne change pas', 'UPDATE mf.cheque_emission SET montant = 1 WHERE numero_cheque = ''0001''');

-- ===== C. Comptes dormants =====
INSERT INTO compte_epargne(agence_id,client_id,produit_id,numero,ouvert_le) VALUES (1,1,1,'C2', current_date - 600);
INSERT INTO mouvement_epargne(compte_id,type,montant,date_operation) VALUES (2,'depot',200000, current_date - 500);
SELECT t.eq('C compte dormant avec solde', solde::text, '200000') FROM v_compte_dormant;
SELECT t.refuse('C clôture avec solde', 'SELECT mf.traiter_compte_dormant(2, ''clore'')');
SELECT t.refuse('C le compte récemment actif n''est pas dormant', 'SELECT mf.traiter_compte_dormant(1, ''bloquer'')');
SELECT t.eq('C blocage', traiter_compte_dormant(2, 'bloquer'), 'bloque');
SELECT t.eq('C compte bloqué n''est plus dormant', count(*)::text, '0') FROM v_compte_dormant;
