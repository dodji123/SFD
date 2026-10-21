SET search_path = mf, public;

-- Module sous test : 43_grh_discipline_sortie.sql (sanctions, sorties, solde de tout compte, indicateurs)
INSERT INTO agence(code,libelle) VALUES ('LOM','Lomé Centre');
INSERT INTO utilisateur(login,nom,role,agence_id) VALUES ('chef','Chef','chef_agence',1),('emp','Employé','caissier',1);
INSERT INTO agent(agence_id,matricule,nom) VALUES (1,'A01','Agent un');
INSERT INTO employe(agence_id,matricule,nom,date_embauche,utilisateur_id,agent_id,sexe) VALUES
  (1,'E1','Employé un','2024-01-01',(SELECT id FROM utilisateur WHERE login='emp'),1,'F'),
  (1,'E2','Employé deux','2025-06-01',NULL,NULL,'M');
INSERT INTO contrat(employe_id,type,date_debut,salaire_base) VALUES (1,'cdi','2024-01-01',220000),(2,'cdi','2025-06-01',150000);

-- ===== A. Sanctions =====
SELECT t.refuse('A mise à pied sans durée', 'INSERT INTO mf.sanction(employe_id,date_faits,type,motif) VALUES (1,current_date,''mise_a_pied'',''Retards répétés constatés'')');
SELECT t.refuse('A durée sur un blâme', 'INSERT INTO mf.sanction(employe_id,date_faits,type,motif,jours_mise_a_pied) VALUES (1,current_date,''blame'',''Retards répétés constatés'',3)');
SELECT t.refuse('A motif trop court', 'INSERT INTO mf.sanction(employe_id,date_faits,type,motif) VALUES (1,current_date,''blame'',''court'')');
INSERT INTO sanction(employe_id,date_faits,type,motif) VALUES (2,current_date - 3,'avertissement_ecrit','Retards répétés constatés cette semaine');
SELECT t.refuse('A notification sans entretien préalable', 'UPDATE mf.sanction SET statut = ''notifiee'', decide_par = (SELECT id FROM mf.utilisateur WHERE login=''chef'')');
SELECT t.refuse('A entretien avant les faits', 'UPDATE mf.sanction SET date_entretien_prealable = current_date - 10');
UPDATE sanction SET date_entretien_prealable = current_date - 1 WHERE employe_id = 2;
SELECT t.refuse('A sanction sans auteur', 'UPDATE mf.sanction SET statut = ''notifiee''');
UPDATE sanction SET statut = 'notifiee', decide_par = (SELECT id FROM utilisateur WHERE login='chef') WHERE employe_id = 2;
SELECT t.eq('A notifiée et datée', (date_notification = current_date)::text, 'true') FROM sanction WHERE employe_id = 2;
SELECT t.refuse('A sanction notifiée non modifiable', 'UPDATE mf.sanction SET motif = ''Autre motif plus long ici''');
SELECT t.refuse('A annulation sans motif', 'UPDATE mf.sanction SET statut = ''annulee''');
-- faits prescrits et auto-sanction
INSERT INTO sanction(employe_id,date_faits,type,motif,date_entretien_prealable) VALUES (2,current_date - 100,'blame','Faits anciens sans suite engagée', current_date - 95);
SELECT t.refuse('A faits prescrits', 'UPDATE mf.sanction SET statut = ''notifiee'', decide_par = (SELECT id FROM mf.utilisateur WHERE login=''chef'') WHERE type = ''blame''');
INSERT INTO sanction(employe_id,date_faits,type,motif) VALUES (1,current_date - 2,'avertissement_verbal','Comportement inapproprié en agence');
SELECT t.refuse('A on ne se sanctionne pas soi-même', 'UPDATE mf.sanction SET statut = ''notifiee'', decide_par = (SELECT id FROM mf.utilisateur WHERE login=''emp'') WHERE employe_id = 1');

-- ===== B. Sorties =====
INSERT INTO avance_salaire(employe_id,date_avance,montant,restant) VALUES (1, current_date - 40, 50000, 30000);
SELECT t.refuse('B préavis insuffisant', 'SELECT mf.preparer_sortie(1, ''demission'', current_date, current_date + 10, ''Départ volontaire'')');
SELECT t.refuse('B on ne décide pas de sa sortie', 'SELECT mf.preparer_sortie(1, ''licenciement'', current_date - 40, current_date - 5, ''Motif réel et sérieux'', (SELECT id FROM mf.utilisateur WHERE login=''emp''))');
SELECT preparer_sortie(1, 'demission', current_date - 40, current_date - 5, 'Départ volontaire');
SELECT t.refuse('B une seule sortie par employé', 'SELECT mf.preparer_sortie(1, ''demission'', current_date - 40, current_date - 5, ''Départ volontaire'')');
SELECT t.eq('B solde : congés valorisés - avance', (SELECT (indemnite_conges - retenue_avances = solde_tout_compte AND retenue_avances = 30000)::text FROM sortie_employe), 'true');
SELECT t.refuse('B sortie à date future non finalisable', 'SELECT mf.preparer_sortie(2, ''fin_cdd'', current_date, current_date + 5, ''Fin de contrat'')  AS x; UPDATE mf.sortie_employe SET date_sortie = current_date + 5; SELECT mf.finaliser_sortie((SELECT id FROM mf.sortie_employe WHERE statut = ''en_cours'' AND employe_id = 2), NULL)');
SELECT t.refuse('B on ne finalise pas sa propre sortie', 'SELECT mf.finaliser_sortie((SELECT id FROM mf.sortie_employe WHERE employe_id = 1), (SELECT id FROM mf.utilisateur WHERE login=''emp''))');
SELECT finaliser_sortie((SELECT id FROM sortie_employe WHERE employe_id = 1), (SELECT id FROM utilisateur WHERE login='chef'));
SELECT t.eq('B employé sorti', statut || '/' || date_sortie, 'sorti/' || (current_date - 5)) FROM employe WHERE matricule = 'E1';
SELECT t.eq('B contrat clôturé', date_fin::text, (current_date - 5)::text) FROM contrat WHERE employe_id = 1;
SELECT t.eq('B avance soldée', statut || '/' || restant, 'soldee/0') FROM avance_salaire WHERE employe_id = 1;
SELECT t.eq('B compte utilisateur et agent désactivés', (SELECT actif::text FROM utilisateur WHERE login='emp') || '/' || (SELECT actif::text FROM agent WHERE id = 1), 'false/false');
SELECT t.refuse('B sortie déjà finalisée', 'SELECT mf.finaliser_sortie((SELECT id FROM mf.sortie_employe WHERE employe_id = 1), NULL)');
SELECT t.refuse('B un employé sorti n''a plus de congé', 'INSERT INTO mf.conge(employe_id,type,date_debut,date_fin) VALUES (1,''annuel'',current_date + 7, current_date + 9)');

-- ===== C. Indicateurs =====
SELECT t.eq('C effectif, sexe, masse salariale', effectif || '/' || femmes || '/' || hommes || '/' || masse_salariale, '1/0/1/150000') FROM v_grh_indicateurs WHERE agence = 'LOM';
SELECT t.eq('C sorties sur 12 mois', sorties_12m::text, '1') FROM v_grh_indicateurs WHERE agence = 'LOM';
