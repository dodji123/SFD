SET search_path = mf, public;

-- Module sous test : 46_validation_mobile.sql (file de validation des opérations mobiles)
INSERT INTO agence(code,libelle) VALUES ('LOM','Lomé Centre');
INSERT INTO agent(agence_id,matricule,nom) VALUES (1,'A01','Agent un');
INSERT INTO utilisateur(login,nom,role,agence_id) VALUES ('chef','Chef','chef_agence',1);

-- par défaut une opération reçue est en attente
INSERT INTO operation_mobile(cle, utilisateur_id, agence_id, agent_id, type, payload, rang)
  VALUES ('cle-client-0001', 1, 1, 1, 'client', '{"nom":"Nouveau client"}', 1);
SELECT t.eq('A reçue : en attente', statut, 'en_attente') FROM operation_mobile WHERE cle = 'cle-client-0001';
SELECT t.eq('A pas de cycle pour une création de client', coalesce(cycle_id::text, 'null'), 'null') FROM operation_mobile WHERE cle = 'cle-client-0001';

-- type inconnu et statut inconnu refusés
SELECT t.refuse('A type inconnu', 'INSERT INTO mf.operation_mobile(cle, utilisateur_id, type) VALUES (''cle-type-0001'', 1, ''virement'')');
SELECT t.refuse('A statut inconnu', 'UPDATE mf.operation_mobile SET statut = ''perdue'' WHERE cle = ''cle-client-0001''');

-- un rejet exige un motif
SELECT t.refuse('B rejet sans motif', 'UPDATE mf.operation_mobile SET statut = ''rejetee'', decide_le = now() WHERE cle = ''cle-client-0001''');
UPDATE operation_mobile SET statut = 'rejetee', motif = 'Doublon d''un client existant', decide_par = 1, decide_le = now() WHERE cle = 'cle-client-0001';
SELECT t.eq('B rejet avec motif', statut, 'rejetee') FROM operation_mobile WHERE cle = 'cle-client-0001';

-- la clé reste unique
SELECT t.refuse('C clé déjà reçue', 'INSERT INTO mf.operation_mobile(cle, utilisateur_id) VALUES (''cle-client-0001'', 1)');
