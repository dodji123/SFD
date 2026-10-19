SET search_path = mf, public;

-- Module sous test : 18_espace_client.sql (consentements, accès client, coupures automatiques, journaux en ajout seul, file SMS)
INSERT INTO agence(code,libelle) VALUES ('LOM','Lomé Centre');
INSERT INTO utilisateur(agence_id,login,nom,role) VALUES (1,'chef','Chef','chef_agence');
INSERT INTO client(agence_id,numero,nom,telephone,sexe,date_naissance,adresse) VALUES
  (1,'C1','Ama Kouassi','90000001','F','1985-03-02','Bè, Lomé'),(1,'C2','Koffi Sans Kyc','90000002',NULL,NULL,NULL),(1,'C3','Yao Sans Tel',NULL,'M','1980-01-01','Kara');
INSERT INTO piece_identite(client_id,type,numero,date_expiration) VALUES (1,'cni','E-1','2040-01-01'),(3,'cni','E-3','2040-01-01');
SELECT valider_kyc(1, 1);
SELECT valider_kyc(3, 1);

-- ===== A. Conditions d'ouverture =====
SELECT t.refuse('A sans consentement', 'SELECT mf.activer_acces_client(1, ''hash'', 1)');
INSERT INTO consentement_client(client_id,finalite,accorde,canal,recueilli_par) VALUES (1,'portail',true,'papier',1),(2,'portail',true,'papier',1),(3,'portail',true,'papier',1);
SELECT t.eq('A consentement actif', consentement_actif(1, 'portail')::text, 'true');
SELECT t.eq('A finalité non consentie', consentement_actif(1, 'sms_rappel')::text, 'false');
SELECT t.refuse('A KYC incomplet', 'SELECT mf.activer_acces_client(2, ''hash'', 1)');
SELECT t.refuse('A sans téléphone (code par SMS impossible)', 'SELECT mf.activer_acces_client(3, ''hash'', 1)');
SELECT t.refuse('A client inconnu', 'SELECT mf.activer_acces_client(99, ''hash'', 1)');
SELECT activer_acces_client(1, 'hash-pin-1', 1);
SELECT t.eq('A accès ouvert avec PIN provisoire', actif::text || ' ' || pin_provisoire::text || ' ' || echecs, 'true true 0') FROM client_acces WHERE client_id = 1;
SELECT t.eq('A ouverture journalisée', evenement, 'acces_active') FROM acces_client_log WHERE client_id = 1;

-- ===== B. Coupures automatiques =====
INSERT INTO consentement_client(client_id,finalite,accorde,canal,recueilli_par) VALUES (1,'portail',false,'agence',1);
SELECT t.eq('B consentement retiré : accès coupé', actif::text, 'false') FROM client_acces WHERE client_id = 1;
SELECT t.eq('B coupure journalisée', count(*)::text, '1') FROM acces_client_log WHERE client_id = 1 AND evenement = 'acces_bloque';
SELECT t.refuse('B réactivation sans nouveau consentement', 'SELECT mf.activer_acces_client(1, ''hash2'', 1)');
INSERT INTO consentement_client(client_id,finalite,accorde,canal,recueilli_par) VALUES (1,'portail',true,'agence',1);
SELECT activer_acces_client(1, 'hash-pin-2', 1);
SELECT t.eq('B réactivé avec un nouveau PIN provisoire', actif::text || ' ' || pin_hash || ' ' || pin_provisoire::text, 'true hash-pin-2 true') FROM client_acces WHERE client_id = 1;
UPDATE client SET actif = false WHERE id = 1;
SELECT t.eq('B client désactivé : accès coupé', actif::text, 'false') FROM client_acces WHERE client_id = 1;
UPDATE client SET actif = true WHERE id = 1;
SELECT activer_acces_client(1, 'hash-pin-3', 1);
INSERT INTO liste_surveillance(source,categorie,nom) VALUES ('ONU','sanction','Kouassi Ama');
SELECT t.eq('B alerte de sanction : accès coupé', actif::text, 'false') FROM client_acces WHERE client_id = 1;
SELECT t.refuse('B réactivation refusée avec alerte de sanction', 'SELECT mf.activer_acces_client(1, ''hash4'', 1)');
SELECT traiter_alerte_lbc((SELECT id FROM alerte_lbc WHERE client_id = 1), 'ecartee', 'homonyme', 1);
SELECT valider_kyc(1, 1);
SELECT activer_acces_client(1, 'hash-pin-4', 1);
SELECT bloquer_acces_client(1, 1, 'téléphone perdu');
SELECT t.eq('B blocage manuel', actif::text, 'false') FROM client_acces WHERE client_id = 1;
SELECT t.refuse('B blocage d''un client sans accès', 'SELECT mf.bloquer_acces_client(2)');

-- ===== C. Journaux non modifiables =====
SELECT t.refuse('C modifier le journal des accès', 'UPDATE mf.acces_client_log SET detail = ''x''');
SELECT t.refuse('C supprimer du journal des accès', 'DELETE FROM mf.acces_client_log');
SELECT t.refuse('C vider le journal des accès', 'TRUNCATE mf.acces_client_log');
SELECT t.refuse('C modifier le journal d''audit', 'UPDATE mf.audit_log SET utilisateur = ''x''');
SELECT t.refuse('C supprimer du journal d''audit', 'DELETE FROM mf.audit_log');
SELECT t.refuse('C vider le journal d''audit', 'TRUNCATE mf.audit_log');
SELECT t.refuse('C modifier un consentement', 'UPDATE mf.consentement_client SET accorde = true');
SELECT t.refuse('C supprimer un consentement', 'DELETE FROM mf.consentement_client');

-- ===== D. Aucun secret dans la piste d'audit =====
SELECT t.eq('D le PIN haché n''apparaît dans aucune trace', (count(*) = 0)::text, 'true')
  FROM audit_log WHERE table_name = 'client_acces' AND (apres::text LIKE '%pin_hash%' OR avant::text LIKE '%pin_hash%');
SELECT t.eq('D mais les modifications sont tracées', (count(*) >= 4)::text, 'true') FROM audit_log WHERE table_name = 'client_acces';

-- ===== E. Codes à usage unique et SMS =====
INSERT INTO client_otp(client_id,code_hash,expire_le) VALUES (1,'h',now() - interval '2 days'),(1,'h2',now() + interval '5 minutes');
SELECT t.eq('E purge des codes expirés', purger_otp()::text, '1');
INSERT INTO sms_outbox(client_id,telephone,type,reference,message) VALUES (1,'90000001','rappel','echeance:1:J-3','Échéance dans 3 jours : 10 300 F');
SELECT t.refuse('E rappel en doublon', 'INSERT INTO mf.sms_outbox(client_id,telephone,type,reference,message) VALUES (1,''90000001'',''rappel'',''echeance:1:J-3'',''x'')');
INSERT INTO sms_outbox(client_id,telephone,type,reference,message) VALUES (1,'90000001','rappel','echeance:1:J-1','Échéance demain : 10 300 F');
INSERT INTO sms_outbox(client_id,telephone,type,message) VALUES (1,'90000001','otp','Code de connexion envoyé');
INSERT INTO sms_outbox(client_id,telephone,type,message) VALUES (1,'90000001','otp','Code de connexion envoyé');
SELECT t.eq('E messages sans référence répétables, rappels uniques', count(*)::text, '4') FROM sms_outbox;
SELECT t.refuse('E type de SMS inconnu', 'INSERT INTO mf.sms_outbox(client_id,telephone,type,message) VALUES (1,''9'',''spam'',''x'')');
