SET search_path = mf, public;

-- Module sous test : 42_grh_formation_evaluation.sql (formations, évaluations de performance)
INSERT INTO agence(code,libelle) VALUES ('LOM','Lomé Centre');
INSERT INTO utilisateur(login,nom,role,agence_id) VALUES ('chef','Chef','chef_agence',1),('rh','RH','rh',1),('emp','Employé','caissier',1);
INSERT INTO employe(agence_id,matricule,nom,date_embauche,utilisateur_id) VALUES
  (1,'E1','Chef de service','2020-01-01',(SELECT id FROM utilisateur WHERE login='chef')),
  (1,'E2','Employé deux','2022-01-01',(SELECT id FROM utilisateur WHERE login='emp')),
  (1,'E3','Employé trois','2023-01-01',NULL);
UPDATE employe SET superieur_id = 1 WHERE matricule IN ('E2','E3');

-- ===== A. Formation =====
INSERT INTO formation(code,titre,duree_heures,cout_unitaire) VALUES ('LBC','Lutte contre le blanchiment',8,25000);
INSERT INTO session_formation(formation_id,date_debut,date_fin,capacite) VALUES (1, current_date - 2, current_date - 1, 2);
INSERT INTO session_formation(formation_id,date_debut,date_fin,capacite) VALUES (1, current_date + 30, current_date + 31, 5);
SELECT t.refuse('A dates inversées', 'INSERT INTO mf.session_formation(formation_id,date_debut,date_fin) VALUES (1, current_date, current_date - 1)');
INSERT INTO participation_formation(session_id,employe_id) SELECT s.id, e.id FROM session_formation s, employe e WHERE s.date_debut < current_date AND e.matricule IN ('E2','E3');
SELECT t.refuse('A session complète', 'INSERT INTO mf.participation_formation(session_id,employe_id) SELECT s.id, e.id FROM mf.session_formation s, mf.employe e WHERE s.date_debut < current_date AND e.matricule = ''E1''');
SELECT t.refuse('A validation sans présence', 'UPDATE mf.participation_formation SET statut = ''valide'', certificat_ref = ''C1'' WHERE employe_id = (SELECT id FROM mf.employe WHERE matricule = ''E2'')');
UPDATE participation_formation SET statut = 'present' WHERE employe_id = (SELECT id FROM employe WHERE matricule = 'E2');
SELECT t.refuse('A validation sans certificat', 'UPDATE mf.participation_formation SET statut = ''valide'' WHERE employe_id = (SELECT id FROM mf.employe WHERE matricule = ''E2'')');
UPDATE participation_formation SET statut = 'valide', certificat_ref = 'CERT-1', note = 16 WHERE employe_id = (SELECT id FROM employe WHERE matricule = 'E2');
INSERT INTO participation_formation(session_id,employe_id) SELECT s.id, e.id FROM session_formation s, employe e WHERE s.date_debut > current_date AND e.matricule = 'E1';
SELECT t.refuse('A présence d''une session à venir', 'UPDATE mf.participation_formation SET statut = ''present'' WHERE session_id = (SELECT id FROM mf.session_formation WHERE date_debut > current_date)');
SELECT t.eq('A heures et validations par employé', formations_validees || '/' || heures_suivies, '1/8.0') FROM v_formation_employe WHERE matricule = 'E2';
-- congé approuvé pendant la session
INSERT INTO conge(employe_id,type,date_debut,date_fin,statut,decide_par) VALUES ((SELECT id FROM employe WHERE matricule='E3'),'annuel', current_date + 30, current_date + 31, 'approuve', (SELECT id FROM utilisateur WHERE login='chef'));
SELECT t.refuse('A inscription pendant un congé approuvé', 'INSERT INTO mf.participation_formation(session_id,employe_id) SELECT s.id, e.id FROM mf.session_formation s, mf.employe e WHERE s.date_debut > current_date AND e.matricule = ''E3''');

-- ===== B. Évaluation =====
INSERT INTO campagne_evaluation(libelle,periode_debut,periode_fin) VALUES ('Évaluation annuelle', '2026-01-01', '2026-12-31');
SELECT t.eq('B évaluations ouvertes pour les employés ayant un supérieur', ouvrir_evaluations(1)::text, '2');
SELECT t.eq('B ouverture idempotente', ouvrir_evaluations(1)::text, '0');
SELECT t.refuse('B on ne s''évalue pas soi-même', 'INSERT INTO mf.evaluation(campagne_id,employe_id,evaluateur_id) VALUES (1,1,1)');
CREATE FUNCTION t.ev(m text) RETURNS integer LANGUAGE sql AS 'SELECT ev.id FROM mf.evaluation ev JOIN mf.employe e ON e.id = ev.employe_id WHERE e.matricule = m';
INSERT INTO objectif_evaluation(evaluation_id,libelle,poids) VALUES (t.ev('E2'),'Qualité de la collecte',60),(t.ev('E2'),'Relation client',30);
SELECT t.refuse('B poids ne totalisant pas 100', 'UPDATE mf.evaluation SET statut = ''evalue'' WHERE id = t.ev(''E2'')');
INSERT INTO objectif_evaluation(evaluation_id,libelle,poids) VALUES (t.ev('E2'),'Ponctualité',10);
SELECT t.refuse('B objectifs non notés', 'UPDATE mf.evaluation SET statut = ''evalue'' WHERE id = t.ev(''E2'')');
UPDATE objectif_evaluation SET note = 8 WHERE libelle = 'Qualité de la collecte';
UPDATE objectif_evaluation SET note = 6 WHERE libelle = 'Relation client';
UPDATE objectif_evaluation SET note = 10 WHERE libelle = 'Ponctualité';
UPDATE evaluation SET statut = 'evalue', points_forts = 'Régulière' WHERE id = t.ev('E2');
SELECT t.eq('B note globale pondérée (8x60 + 6x30 + 10x10)/100', note_globale::text, '7.60') FROM evaluation WHERE id = t.ev('E2');
SELECT t.refuse('B validation sans décision', 'UPDATE mf.evaluation SET statut = ''validee'', validee_par = (SELECT id FROM mf.utilisateur WHERE login=''rh'') WHERE id = t.ev(''E2'')');
SELECT t.refuse('B l''évaluateur ne valide pas', 'UPDATE mf.evaluation SET statut = ''validee'', decision = ''maintien'', validee_par = (SELECT id FROM mf.utilisateur WHERE login=''chef'') WHERE id = t.ev(''E2'')');
SELECT t.refuse('B l''évalué ne valide pas', 'UPDATE mf.evaluation SET statut = ''validee'', decision = ''maintien'', validee_par = (SELECT id FROM mf.utilisateur WHERE login=''emp'') WHERE id = t.ev(''E2'')');
UPDATE evaluation SET statut = 'validee', decision = 'augmentation', validee_par = (SELECT id FROM utilisateur WHERE login='rh') WHERE id = t.ev('E2');
SELECT t.eq('B validée et horodatée', statut || '/' || (validee_le IS NOT NULL)::text, 'validee/true') FROM evaluation WHERE id = t.ev('E2');
SELECT t.refuse('B évaluation validée figée', 'UPDATE mf.evaluation SET points_forts = ''modifié'' WHERE id = t.ev(''E2'')');
SELECT t.refuse('B objectifs figés après validation', 'UPDATE mf.objectif_evaluation SET note = 1 WHERE evaluation_id = t.ev(''E2'')');
UPDATE campagne_evaluation SET statut = 'close';
SELECT t.refuse('B campagne close', 'INSERT INTO mf.evaluation(campagne_id,employe_id,evaluateur_id) VALUES (1,1,2)');
