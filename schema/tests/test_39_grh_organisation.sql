SET search_path = mf, public;

-- Module sous test : 39_grh_organisation.sql (services, postes, dossier, hiérarchie, échéances, agents commerciaux)
INSERT INTO agence(code,libelle) VALUES ('LOM','Lomé Centre');
INSERT INTO agent(agence_id,matricule,nom) VALUES (1,'A01','Ama Koffi'),(1,'A02','Kodjo Mensah');
INSERT INTO zone(agence_id,code,libelle,agent_id) VALUES (1,'Z1','Grand Marché',1);
INSERT INTO client(agence_id,zone_id,nom) VALUES (1,1,'Cliente un'),(1,1,'Cliente deux');
INSERT INTO employe(agence_id,matricule,nom,date_embauche) VALUES (1,'E1','Directeur','2020-01-01'),(1,'E2','Chef','2021-01-01'),(1,'E3','Caissier','2022-01-01');

-- ===== A. Services et postes =====
INSERT INTO service_rh(code,libelle) VALUES ('DIR','Direction'),('OPS','Opérations');
UPDATE service_rh SET parent_id = 1 WHERE code = 'OPS';
SELECT t.refuse('A service parent de lui-même', 'UPDATE mf.service_rh SET parent_id = id WHERE code = ''DIR''');
SELECT t.refuse('A cycle entre services', 'UPDATE mf.service_rh SET parent_id = 2 WHERE code = ''DIR''');
SELECT t.refuse('A fourchette de salaire inversée', 'INSERT INTO mf.poste(code,libelle,salaire_min,salaire_max) VALUES (''X'',''X'',200000,100000)');
SELECT t.eq('A poste d''agent commercial fourni', libelle, 'Agent commercial') FROM poste WHERE code = 'AGENT-COM';

-- ===== B. Hiérarchie =====
UPDATE employe SET superieur_id = 1 WHERE matricule = 'E2';
UPDATE employe SET superieur_id = 2 WHERE matricule = 'E3';
SELECT t.refuse('B employé son propre supérieur', 'UPDATE mf.employe SET superieur_id = id WHERE matricule = ''E1''');
SELECT t.refuse('B hiérarchie circulaire', 'UPDATE mf.employe SET superieur_id = 3 WHERE matricule = ''E1''');
SELECT t.eq('B organigramme : niveaux', string_agg(matricule || ':' || niveau, ',' ORDER BY niveau), 'E1:0,E2:1,E3:2') FROM v_organigramme;

-- ===== C. Dossier du personnel et échéances =====
SELECT t.refuse('C sexe invalide', 'UPDATE mf.employe SET sexe = ''X'' WHERE matricule = ''E1''');
UPDATE employe SET sexe = 'F', date_naissance = '1990-05-01', telephone = '90000000', numero_cnss = 'CNSS1' WHERE matricule = 'E3';
SELECT t.refuse('C pièce expirant avant son émission', 'INSERT INTO mf.document_employe(employe_id,type,libelle,date_emission,date_expiration) VALUES (3,''identite'',''CNI'',''2025-01-01'',''2024-01-01'')');
INSERT INTO document_employe(employe_id,type,libelle,date_expiration) VALUES (3,'identite','CNI', current_date + 30),(3,'diplome','Licence', NULL);
INSERT INTO contrat(employe_id,type,date_debut,date_fin,salaire_base,periode_essai_fin) VALUES (3,'cdd','2026-01-01', current_date + 20, 150000, current_date + 5);
SELECT t.eq('C échéances : contrat, essai, pièce', string_agg(nature, ',' ORDER BY nature), 'fin_contrat,fin_essai,piece_expire') FROM v_grh_echeances;
SELECT t.refuse('C essai avant le début du contrat', 'INSERT INTO mf.contrat(employe_id,type,date_debut,salaire_base,periode_essai_fin) VALUES (1,''cdi'',''2026-01-01'',300000,''2025-12-01'')');

-- ===== D. Agents commerciaux =====
SELECT t.eq('D agent sans fiche RH', (employe_id IS NULL)::text, 'true') FROM v_agent_rh WHERE matricule = 'A01';
SELECT creer_employe_depuis_agent(1, '2023-03-01');
SELECT t.eq('D fiche RH créée avec le poste d''agent', e.matricule || '/' || p.code || '/' || e.agent_id, 'A01/AGENT-COM/1') FROM employe e JOIN poste p ON p.id = e.poste_id WHERE e.agent_id = 1;
SELECT t.refuse('D une seule fiche RH par agent', 'SELECT mf.creer_employe_depuis_agent(1)');
SELECT t.eq('D indicateurs : zones et clients', nb_zones || '/' || nb_clients, '1/2') FROM v_agent_rh WHERE matricule = 'A01';
SELECT t.eq('D les agents sans fiche restent visibles', count(*)::text, '2') FROM v_agent_rh;
