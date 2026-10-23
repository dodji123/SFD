SET search_path = mf, public;

-- Module sous test : 56_appareils_mobiles.sql (appareils mobiles agréés)
INSERT INTO agence(code,libelle) VALUES ('LOM','Lomé Centre');
INSERT INTO utilisateur(login,nom,role,agence_id) VALUES
  ('agent1','Agent 1','agent',1), ('agent2','Agent 2','agent',1), ('chef1','Chef','chef_agence',1), ('chef2','Chef bis','chef_agence',1);

-- ===== A. Enregistrement =====
SELECT t.refuse('A un appareil naît en attente', 'INSERT INTO mf.appareil_mobile(utilisateur_id, nom, empreinte, statut, agree_par, agree_le) SELECT id, ''Tel'', repeat(''0'', 64), ''agree'', id, now() FROM mf.utilisateur WHERE login = ''chef1''');
SELECT t.refuse('A nom trop court', 'INSERT INTO mf.appareil_mobile(utilisateur_id, nom, empreinte) SELECT id, ''x'', repeat(''1'', 64) FROM mf.utilisateur WHERE login = ''agent1''');
INSERT INTO appareil_mobile(utilisateur_id, nom, empreinte) SELECT id, 'Tecno Spark', repeat('a', 64) FROM utilisateur WHERE login = 'agent1';
SELECT t.eq('A appareil créé en attente', statut, 'en_attente') FROM appareil_mobile;
SELECT t.refuse('A un seul appareil actif par agent', 'INSERT INTO mf.appareil_mobile(utilisateur_id, nom, empreinte) SELECT id, ''Autre'', repeat(''b'', 64) FROM mf.utilisateur WHERE login = ''agent1''');
SELECT t.refuse('A empreinte unique', 'INSERT INTO mf.appareil_mobile(utilisateur_id, nom, empreinte) SELECT id, ''Autre'', repeat(''a'', 64) FROM mf.utilisateur WHERE login = ''agent2''');

-- ===== B. Agrément =====
SELECT t.refuse('B pas d''agrément sans responsable', 'UPDATE mf.appareil_mobile SET statut = ''agree''');
SELECT t.refuse('B on n''agrée pas son propre appareil', 'UPDATE mf.appareil_mobile SET statut = ''agree'', agree_par = utilisateur_id, agree_le = now()');
UPDATE appareil_mobile SET statut = 'agree', agree_par = (SELECT id FROM utilisateur WHERE login = 'chef1'), agree_le = now();
SELECT t.eq('B agréé par le chef', statut, 'agree') FROM appareil_mobile;
SELECT t.refuse('B l''agrément ne se réécrit pas', 'UPDATE mf.appareil_mobile SET agree_par = (SELECT id FROM mf.utilisateur WHERE login = ''chef2'')');
SELECT t.refuse('B le propriétaire ne change pas', 'UPDATE mf.appareil_mobile SET utilisateur_id = (SELECT id FROM mf.utilisateur WHERE login = ''agent2'')');
SELECT t.refuse('B l''empreinte ne change pas', 'UPDATE mf.appareil_mobile SET empreinte = repeat(''c'', 64)');
SELECT t.refuse('B pas de suppression', 'DELETE FROM mf.appareil_mobile');
SELECT t.refuse('B pas de retour en attente', 'UPDATE mf.appareil_mobile SET statut = ''en_attente'', agree_par = NULL, agree_le = NULL');

-- ===== C. Révocation et effacement à distance =====
SELECT t.refuse('C révocation sans motif', 'UPDATE mf.appareil_mobile SET statut = ''revoque'', decide_par = (SELECT id FROM mf.utilisateur WHERE login = ''chef1''), decide_le = now()');
SELECT t.refuse('C on ne révoque pas son propre appareil', 'UPDATE mf.appareil_mobile SET statut = ''revoque'', decide_par = utilisateur_id, decide_le = now(), motif_decision = ''Je le perds moi-même''');
SELECT t.refuse('C effacement demandé sans révocation', 'UPDATE mf.appareil_mobile SET efface_demande = true');
UPDATE appareil_mobile SET statut = 'revoque', decide_par = (SELECT id FROM utilisateur WHERE login = 'chef1'), decide_le = now(), motif_decision = 'Téléphone volé', efface_demande = true;
SELECT t.eq('C révoqué avec effacement demandé', statut || '/' || efface_demande::text, 'revoque/true') FROM appareil_mobile;
SELECT t.refuse('C un appareil révoqué ne se réactive pas', 'UPDATE mf.appareil_mobile SET statut = ''agree'', agree_par = (SELECT id FROM mf.utilisateur WHERE login = ''chef2''), agree_le = now()');
SELECT t.refuse('C la demande d''effacement ne s''annule pas', 'UPDATE mf.appareil_mobile SET efface_demande = false');
UPDATE appareil_mobile SET efface_confirme_le = now(), derniere_activite = now();
SELECT t.eq('C effacement confirmé', (efface_confirme_le IS NOT NULL)::text, 'true') FROM appareil_mobile;
SELECT t.refuse('C la confirmation ne se réécrit pas', 'UPDATE mf.appareil_mobile SET efface_confirme_le = now() + interval ''1 day''');

-- ===== D. Remplacement, refus, journal, permissions =====
INSERT INTO appareil_mobile(utilisateur_id, nom, empreinte) SELECT id, 'Nouveau tel', repeat('d', 64) FROM utilisateur WHERE login = 'agent1';
SELECT t.eq('D après révocation, un nouvel appareil est possible', count(*)::text, '1') FROM appareil_mobile WHERE statut = 'en_attente';
SELECT t.refuse('D refus sans motif', 'UPDATE mf.appareil_mobile SET statut = ''refuse'', decide_par = (SELECT id FROM mf.utilisateur WHERE login = ''chef1''), decide_le = now() WHERE empreinte = repeat(''d'', 64)');
UPDATE appareil_mobile SET statut = 'refuse', decide_par = (SELECT id FROM utilisateur WHERE login = 'chef2'), decide_le = now(), motif_decision = 'Appareil personnel non conforme' WHERE empreinte = repeat('d', 64);
SELECT t.eq('D refusé', statut, 'refuse') FROM appareil_mobile WHERE empreinte = repeat('d', 64);
INSERT INTO journal_connexion(login, utilisateur_id, evenement) SELECT login, id, 'appareil_revoque' FROM utilisateur WHERE login = 'agent1';
INSERT INTO alerte_securite(type, gravite, utilisateur_id, detail) SELECT 'appareil_revoque_usage', 'moyenne', id, 'test' FROM utilisateur WHERE login = 'agent1';
SELECT t.eq('D événement et alerte acceptés', (SELECT count(*) FROM journal_connexion WHERE evenement = 'appareil_revoque') || '/' || (SELECT count(*) FROM alerte_securite WHERE type = 'appareil_revoque_usage'), '1/1');
SELECT t.eq('D droit de gestion des appareils', string_agg(role_code, ',' ORDER BY role_code), 'admin,chef_agence,coordinateur,directeur') FROM droit_role WHERE perm = 'appareil:gerer';
SELECT t.eq('D droit de lecture des appareils', string_agg(role_code, ',' ORDER BY role_code), 'admin,auditeur,chef_agence,coordinateur,directeur') FROM droit_role WHERE perm = 'appareil:read';
