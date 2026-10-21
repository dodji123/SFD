SET search_path = mf, public;

-- Module sous test : 40_grh_conges_absences.sql (jours ouvrés, soldes, décisions, présences, absentéisme)
INSERT INTO agence(code,libelle) VALUES ('LOM','Lomé Centre');
INSERT INTO utilisateur(login,nom,role,agence_id) VALUES ('chef','Chef','chef_agence',1),('emp','Employé','caissier',1);
INSERT INTO employe(agence_id,matricule,nom,date_embauche,utilisateur_id) VALUES
  (1,'E1','Ancien','2024-01-01',(SELECT id FROM utilisateur WHERE login='emp')),
  (1,'E2','Récent','2025-12-01',NULL);
INSERT INTO jour_ferie(date_jour,libelle) VALUES ('2026-03-04','Jour férié test');

-- ===== A. Jours ouvrés et droits =====
SELECT t.eq('A semaine avec un férié', jours_ouvres('2026-03-02','2026-03-06', 1::smallint)::text, '4');
SELECT t.eq('A week-end sans jour ouvré', jours_ouvres('2026-03-07','2026-03-08', 1::smallint)::text, '0');
SELECT t.eq('A congé acquis : 3 mois x 2,5', conge_acquis(2, '2026-03-02')::text, '7.5');
SELECT t.refuse('A férié unique par agence', 'INSERT INTO mf.jour_ferie(date_jour,libelle) VALUES (''2026-03-04'',''doublon'')');

-- ===== B. Demande et décision =====
SELECT t.refuse('B période sans jour ouvré', 'INSERT INTO mf.conge(employe_id,type,date_debut,date_fin) VALUES (1,''annuel'',''2026-03-07'',''2026-03-08'')');
INSERT INTO conge(employe_id,type,date_debut,date_fin) VALUES (1,'annuel','2026-03-02','2026-03-06');
SELECT t.eq('B jours ouvrés calculés', jours_ouvres::text, '4.0') FROM conge WHERE employe_id = 1 AND type = 'annuel';
SELECT t.refuse('B chevauchement', 'INSERT INTO mf.conge(employe_id,type,date_debut,date_fin) VALUES (1,''maladie'',''2026-03-05'',''2026-03-10'')');
SELECT t.refuse('B approbation sans auteur', 'UPDATE mf.conge SET statut = ''approuve'' WHERE employe_id = 1');
SELECT t.refuse('B on n''approuve pas son propre congé', 'UPDATE mf.conge SET statut = ''approuve'', decide_par = (SELECT id FROM mf.utilisateur WHERE login=''emp'') WHERE employe_id = 1');
UPDATE conge SET statut = 'approuve', decide_par = (SELECT id FROM utilisateur WHERE login='chef') WHERE employe_id = 1 AND type = 'annuel';
SELECT t.eq('B approuvé, décision horodatée', (decide_le IS NOT NULL)::text, 'true') FROM conge WHERE employe_id = 1 AND type = 'annuel';
SELECT t.eq('B présences « conge » posées (4 jours ouvrés)', count(*)::text, '4') FROM presence WHERE employe_id = 1 AND statut = 'conge';
SELECT t.eq('B solde après congé (acquis - 4)', round(solde_conge(1, '2026-03-02')::numeric, 1)::text, (conge_acquis(1,'2026-03-02') - 4)::text);
SELECT t.refuse('B présence contredisant le congé', 'SELECT mf.enregistrer_presence(1, ''2026-03-03'', ''present'')');

-- solde insuffisant : E2 n'a acquis que 7,5 jours
INSERT INTO conge(employe_id,type,date_debut,date_fin) VALUES (2,'annuel','2026-03-09','2026-03-20');
SELECT t.refuse('B solde insuffisant (10 jours pour 7,5)', 'UPDATE mf.conge SET statut = ''approuve'', decide_par = (SELECT id FROM mf.utilisateur WHERE login=''chef'') WHERE employe_id = 2');
SELECT t.refuse('B refus non motivé', 'UPDATE mf.conge SET statut = ''refuse'', decide_par = (SELECT id FROM mf.utilisateur WHERE login=''chef'') WHERE employe_id = 2');
UPDATE conge SET statut = 'refuse', decide_par = (SELECT id FROM utilisateur WHERE login='chef'), commentaire_decision = 'Solde insuffisant' WHERE employe_id = 2;
SELECT t.refuse('B un congé refusé ne se rouvre pas', 'UPDATE mf.conge SET statut = ''demande'' WHERE employe_id = 2');
-- un congé maladie n'est pas soumis au solde
INSERT INTO conge(employe_id,type,date_debut,date_fin,statut,decide_par) VALUES (2,'maladie','2026-03-09','2026-03-20','approuve',(SELECT id FROM utilisateur WHERE login='chef'));
SELECT t.eq('B maladie approuvé sans solde', count(*)::text, '1') FROM conge WHERE type = 'maladie' AND statut = 'approuve';

-- annulation : les présences disparaissent
UPDATE conge SET statut = 'annule' WHERE employe_id = 1 AND type = 'annuel';
SELECT t.eq('B annulation retire les présences', count(*)::text, '0') FROM presence WHERE employe_id = 1;

-- ===== C. Pointage et absentéisme =====
SELECT enregistrer_presence(1, '2026-02-02', 'present', '08:00', '17:00');
SELECT t.eq('C heures calculées', heures::text, '9.0') FROM presence WHERE employe_id = 1 AND date_jour = '2026-02-02';
SELECT enregistrer_presence(1, '2026-02-03', 'retard', '09:30', '17:00', 'Transport');
SELECT enregistrer_presence(1, '2026-02-04', 'absent');
SELECT enregistrer_presence(1, '2026-02-05', 'absent_justifie', NULL, NULL, 'Certificat médical');
SELECT enregistrer_presence(1, '2026-02-04', 'absent_justifie', NULL, NULL, 'Justifié après coup');
SELECT t.eq('C correction du jour (upsert)', count(*)::text, '4') FROM presence WHERE employe_id = 1;
SELECT t.refuse('C pointage futur', 'SELECT mf.enregistrer_presence(1, current_date + 3, ''present'')');
SELECT t.refuse('C départ avant l''arrivée', 'SELECT mf.enregistrer_presence(1, ''2026-02-06'', ''present'', ''17:00'', ''08:00'')');
SELECT t.eq('C synthèse mensuelle', jours_presents || '/' || retards || '/' || absences_justifiees || '/' || absences_injustifiees, '2/1/2/0') FROM v_absenteisme WHERE employe_id = 1 AND mois = '2026-02-01';
