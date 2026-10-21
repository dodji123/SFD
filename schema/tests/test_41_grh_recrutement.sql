SET search_path = mf, public;

-- Module sous test : 41_grh_recrutement.sql (besoin, candidatures, entretiens, embauche)
INSERT INTO agence(code,libelle) VALUES ('LOM','Lomé Centre');
INSERT INTO utilisateur(login,nom,role,agence_id) VALUES ('chef','Chef','chef_agence',1),('rh','RH','rh',1),('dir','Directeur','directeur',NULL);
INSERT INTO poste(code,libelle,salaire_min,salaire_max) VALUES ('CAIS','Caissier',100000,200000);

-- ===== A. Besoin =====
INSERT INTO besoin_recrutement(agence_id,poste_id,motif,nb_postes,demandeur_id)
  VALUES (1,(SELECT id FROM poste WHERE code='CAIS'),'Départ d''un caissier',2,(SELECT id FROM utilisateur WHERE login='chef'));
SELECT t.refuse('A candidature sur un besoin non approuvé', 'INSERT INTO mf.candidat(nom,telephone) VALUES (''X'',''1''); INSERT INTO mf.candidature(besoin_id,candidat_id) VALUES (1,(SELECT max(id) FROM mf.candidat))');
SELECT t.refuse('A le demandeur décide de son besoin', 'UPDATE mf.besoin_recrutement SET statut = ''approuve'', decide_par = demandeur_id');
SELECT t.refuse('A refus non motivé', 'UPDATE mf.besoin_recrutement SET statut = ''refuse'', decide_par = (SELECT id FROM mf.utilisateur WHERE login=''dir'')');
UPDATE besoin_recrutement SET statut = 'approuve', decide_par = (SELECT id FROM utilisateur WHERE login='dir');
SELECT t.eq('A besoin approuvé', statut, 'approuve') FROM besoin_recrutement;
SELECT t.refuse('A pas de retour en arrière', 'UPDATE mf.besoin_recrutement SET statut = ''soumis''');

CREATE FUNCTION t.cdt(n text) RETURNS integer LANGUAGE sql AS 'SELECT ca.id FROM mf.candidature ca JOIN mf.candidat c ON c.id = ca.candidat_id WHERE c.nom = n';

-- ===== B. Candidatures et entretiens =====
SELECT t.refuse('B candidat sans contact', 'INSERT INTO mf.candidat(nom) VALUES (''Sans contact'')');
INSERT INTO candidat(nom,telephone,source) VALUES ('Akouvi','90000001','annonce'),('Kossi','90000002','annonce'),('Yawo','90000003','spontanee');
INSERT INTO candidature(besoin_id,candidat_id) SELECT 1, id FROM candidat;
SELECT t.refuse('B une candidature par candidat et par besoin', 'INSERT INTO mf.candidature(besoin_id,candidat_id) SELECT 1, id FROM mf.candidat WHERE nom = ''Akouvi''');
SELECT t.refuse('B retenue sans entretien', 'UPDATE mf.candidature SET statut = ''retenue'' WHERE id = t.cdt(''Akouvi'')');
SELECT t.refuse('B note hors de 0-10', 'INSERT INTO mf.entretien(candidature_id,date_entretien,note,decision) VALUES (t.cdt(''Akouvi''),current_date,11,''favorable'')');
INSERT INTO entretien(candidature_id,date_entretien,note,decision,evaluateur_id) VALUES (t.cdt('Akouvi'),current_date,5.5,'favorable',(SELECT id FROM utilisateur WHERE login='rh'));
SELECT t.eq('B l''entretien fait avancer la candidature', statut, 'entretien') FROM candidature WHERE id = t.cdt('Akouvi');
SELECT t.refuse('B note insuffisante (5,5 < 6)', 'UPDATE mf.candidature SET statut = ''retenue'' WHERE id = t.cdt(''Akouvi'')');
INSERT INTO entretien(candidature_id,date_entretien,note,decision) VALUES (t.cdt('Akouvi'),current_date,8,'favorable'),(t.cdt('Kossi'),current_date,9,'defavorable');
UPDATE candidature SET statut = 'retenue' WHERE id = t.cdt('Akouvi');
SELECT t.refuse('B défavorable : pas retenue', 'UPDATE mf.candidature SET statut = ''retenue'' WHERE id = t.cdt(''Kossi'')');
SELECT t.refuse('B refus sans motif', 'UPDATE mf.candidature SET statut = ''refusee'' WHERE id = t.cdt(''Kossi'')');
UPDATE candidature SET statut = 'refusee', motif_refus = 'Entretien défavorable' WHERE id = t.cdt('Kossi');

-- ===== C. Embauche =====
SELECT t.refuse('C embauche d''un candidat non retenu', 'SELECT mf.embaucher_candidat(t.cdt(''Yawo''), ''E9'', current_date, 150000)');
SELECT t.refuse('C salaire hors fourchette', 'SELECT mf.embaucher_candidat(t.cdt(''Akouvi''), ''E1'', current_date, 250000)');
SELECT embaucher_candidat(t.cdt('Akouvi'), 'E1', '2026-11-01', 150000, 'cdi', NULL, '2027-02-01');
SELECT t.eq('C employé créé avec son poste et son contrat', e.nom || '/' || e.matricule || '/' || p.code || '/' || c.salaire_base, 'Akouvi/E1/CAIS/150000')
  FROM employe e JOIN poste p ON p.id = e.poste_id JOIN contrat c ON c.employe_id = e.id;
SELECT t.eq('C candidature embauchée liée à l''employé', statut || '/' || (employe_id IS NOT NULL)::text, 'embauchee/true') FROM candidature WHERE id = t.cdt('Akouvi');
SELECT t.eq('C besoin encore ouvert (1 poste sur 2)', statut, 'approuve') FROM besoin_recrutement;
SELECT t.refuse('C candidature embauchée close', 'UPDATE mf.candidature SET statut = ''desistement'' WHERE id = t.cdt(''Akouvi'')');
INSERT INTO entretien(candidature_id,date_entretien,note,decision) VALUES (t.cdt('Yawo'),current_date,7,'favorable');
UPDATE candidature SET statut = 'retenue' WHERE id = t.cdt('Yawo');
SELECT embaucher_candidat(t.cdt('Yawo'), 'E2', '2026-11-01', 120000);
SELECT t.eq('C besoin pourvu au dernier poste', statut, 'pourvu') FROM besoin_recrutement;
SELECT t.eq('C entonnoir', candidatures || '/' || retenues || '/' || embauches, '3/0/2') FROM v_recrutement;
