SET search_path = mf, public;

-- Module sous test : 35_comite_credit.sql (comité de gestion du crédit : séances, quorum, votes, délégations)
INSERT INTO agence(code,libelle) VALUES ('LOM','Lomé Centre');
INSERT INTO client(agence_id,nom) VALUES (1,'Client un');
INSERT INTO produit_credit_epargne(code,libelle,type,taux_annuel) VALUES ('PC','Produit','sans_epargne',0.18);
INSERT INTO utilisateur(login,nom,role,agence_id) VALUES
  ('pres','Président','chef_agence',1), ('sec','Secrétaire','comptable',1), ('m1','Membre 1','agent',1),
  ('m2','Membre 2','agent',1), ('cons','Consultant','agent',1), ('autre','Étranger','caissier',1);
INSERT INTO comite_credit(code,libelle,agence_id,montant_min,montant_max,quorum) VALUES ('CA1','Comité agence Lomé',1,0,1000000,3);
INSERT INTO comite_membre(comite_id,utilisateur_id,fonction,avec_voix) VALUES
  (1,(SELECT id FROM utilisateur WHERE login='pres'),'president',true),
  (1,(SELECT id FROM utilisateur WHERE login='sec'),'secretaire',true),
  (1,(SELECT id FROM utilisateur WHERE login='m1'),'membre',true),
  (1,(SELECT id FROM utilisateur WHERE login='m2'),'membre',true),
  (1,(SELECT id FROM utilisateur WHERE login='cons'),'membre',false);
SELECT t.refuse('A deuxième président actif refusé', 'INSERT INTO mf.comite_membre(comite_id,utilisateur_id,fonction) VALUES (1,(SELECT id FROM mf.utilisateur WHERE login=''autre''),''president'')');

-- demandes : D1 300 000, D2 800 000 (visite requise), D3 3 000 000 (hors compétence), D4 300 000
INSERT INTO demande_credit(agence_id,client_id,produit_id,montant,nb_echeances,taux,mode_remboursement) VALUES
  (1,1,1,300000,12,0.18,'especes'),(1,1,1,800000,12,0.18,'especes'),(1,1,1,3000000,12,0.18,'especes'),(1,1,1,300000,12,0.18,'especes');

CREATE FUNCTION t.dos(n integer) RETURNS integer LANGUAGE sql AS 'SELECT id FROM mf.seance_dossier WHERE demande_id = n ORDER BY id LIMIT 1';

-- ===== A. Séance, compétence, convocation =====
INSERT INTO seance_comite(comite_id,date_seance,lieu) VALUES (1, now() + interval '3 days', 'Salle de réunion');
SELECT t.eq('A numéro de séance', (numero ~ '^CC-CA1-[0-9]{4}-00001$')::text, 'true') FROM seance_comite;
SELECT t.refuse('A hors compétence (montant > plafond)', 'INSERT INTO mf.seance_dossier(seance_id,demande_id) VALUES (1,3)');
INSERT INTO seance_dossier(seance_id,demande_id,rapporteur_id,analyse_individuelle) VALUES
  (1,1,(SELECT id FROM utilisateur WHERE login='m1'),'Client régulier, capacité confirmée.'),
  (1,2,(SELECT id FROM utilisateur WHERE login='m2'),'Commerce de détail, garantie suffisante.'),
  (1,4,(SELECT id FROM utilisateur WHERE login='m1'),'Dossier récent, informations à compléter.');
INSERT INTO seance_comite(comite_id,date_seance) VALUES (1, now() + interval '10 days');
SELECT t.refuse('A même demande dans deux séances non décidées', 'INSERT INTO mf.seance_dossier(seance_id,demande_id) VALUES (2,1)');
SELECT t.refuse('A convocation sans ordre du jour', 'SELECT mf.convoquer_seance(1)');
UPDATE seance_comite SET ordre_du_jour = '1. Dossiers de crédit D1, D2, D4' WHERE id = 1;
UPDATE seance_comite SET date_seance = now() + interval '2 hours' WHERE id = 1;
SELECT t.refuse('A délai de convocation insuffisant', 'SELECT mf.convoquer_seance(1)');
UPDATE seance_comite SET date_seance = now() + interval '3 days' WHERE id = 1;
SELECT convoquer_seance(1, (SELECT id FROM utilisateur WHERE login='pres'));
SELECT t.eq('A séance convoquée, 5 convoqués', statut || '/' || (SELECT count(*) FROM seance_presence WHERE seance_id = 1), 'convoquee/5') FROM seance_comite WHERE id = 1;
SELECT t.refuse('A on ne reconvoque pas', 'SELECT mf.convoquer_seance(1)');

-- ===== B. Présences, quorum, ouverture =====
SELECT t.refuse('B ouverture avec présences incomplètes', 'SELECT mf.ouvrir_seance(1)');
SELECT pointer_presence(1,(SELECT id FROM utilisateur WHERE login='pres'),true);
SELECT pointer_presence(1,(SELECT id FROM utilisateur WHERE login='sec'),true);
SELECT pointer_presence(1,(SELECT id FROM utilisateur WHERE login='m1'),false,'Maladie');
SELECT pointer_presence(1,(SELECT id FROM utilisateur WHERE login='m2'),false,'Mission');
SELECT pointer_presence(1,(SELECT id FROM utilisateur WHERE login='cons'),true);
SELECT t.eq('B quorum non atteint (2 présents avec voix sur 4)', mf.seance_quorum(1)::text, 'false');
SELECT t.refuse('B ouverture sans quorum', 'SELECT mf.ouvrir_seance(1)');
SELECT t.refuse('B pointage d''un non-convoqué', 'SELECT mf.pointer_presence(1,(SELECT id FROM mf.utilisateur WHERE login=''autre''),true)');
SELECT pointer_presence(1,(SELECT id FROM utilisateur WHERE login='m1'),true);
SELECT t.eq('B quorum atteint (3 sur 4, majorité)', mf.seance_quorum(1)::text, 'true');
SELECT ouvrir_seance(1);
SELECT t.eq('B séance ouverte', statut, 'ouverte') FROM seance_comite WHERE id = 1;

-- ===== C. Votes =====
SELECT t.refuse('C membre absent ne vote pas', 'INSERT INTO mf.seance_vote(dossier_id,utilisateur_id,vote,motif) VALUES (t.dos(1),(SELECT id FROM mf.utilisateur WHERE login=''m2''),''acceptation'',''Dossier solide'')');
SELECT t.refuse('C voix consultative ne vote pas', 'INSERT INTO mf.seance_vote(dossier_id,utilisateur_id,vote,motif) VALUES (t.dos(1),(SELECT id FROM mf.utilisateur WHERE login=''cons''),''acceptation'',''Dossier solide'')');
SELECT t.refuse('C étranger au comité ne vote pas', 'INSERT INTO mf.seance_vote(dossier_id,utilisateur_id,vote,motif) VALUES (t.dos(1),(SELECT id FROM mf.utilisateur WHERE login=''autre''),''acceptation'',''Dossier solide'')');
SELECT t.refuse('C vote sans motif refusé', 'INSERT INTO mf.seance_vote(dossier_id,utilisateur_id,vote) VALUES (t.dos(1),(SELECT id FROM mf.utilisateur WHERE login=''m1''),''rejet'')');
SELECT t.refuse('C décision avant les votes', 'SELECT mf.decider_dossier(t.dos(1), ''Motif de décision suffisant'')');

-- D1 : pour / pour / contre => acceptation à 250 000
INSERT INTO seance_vote(dossier_id,utilisateur_id,vote,motif) VALUES
  (t.dos(1),(SELECT id FROM utilisateur WHERE login='pres'),'acceptation','Capacité de remboursement établie'),
  (t.dos(1),(SELECT id FROM utilisateur WHERE login='sec'),'acceptation','Historique correct'),
  (t.dos(1),(SELECT id FROM utilisateur WHERE login='m1'),'rejet','Montant trop élevé');
SELECT t.refuse('C montant accordé > demandé', 'SELECT mf.decider_dossier(t.dos(1), ''Montant trop élevé pour le client'', 400000)');
SELECT t.eq('C D1 acceptation', mf.decider_dossier(t.dos(1), 'Accord à la majorité, montant réduit', 250000, 'Garantie à constituer avant déblocage'), 'acceptation');
SELECT t.eq('C D1 : demande approuvée, montant réduit, validateur = président',
  d.statut || '/' || d.montant || '/' || (u.login), 'approuvee/250000/pres')
  FROM demande_credit d JOIN utilisateur u ON u.id = d.validateur_id WHERE d.id = 1;
SELECT t.refuse('C vote après décision refusé', 'UPDATE mf.seance_vote SET vote = ''rejet'', motif = ''Nouveau motif valable''');
SELECT t.refuse('C décision modifiable à la main', 'UPDATE mf.seance_dossier SET decision = ''rejet'', decide_le = now() WHERE id = t.dos(1)');

-- D2 : visite obligatoire (800 000 >= 500 000)
INSERT INTO seance_recusation(dossier_id,utilisateur_id,motif) VALUES (t.dos(2),(SELECT id FROM utilisateur WHERE login='m1'),'Parent du demandeur');
SELECT t.refuse('C membre récusé ne vote pas', 'INSERT INTO mf.seance_vote(dossier_id,utilisateur_id,vote,motif) VALUES (t.dos(2),(SELECT id FROM mf.utilisateur WHERE login=''m1''),''acceptation'',''Dossier solide'')');
INSERT INTO seance_vote(dossier_id,utilisateur_id,vote,motif) VALUES
  (t.dos(2),(SELECT id FROM utilisateur WHERE login='pres'),'acceptation','Activité solide, garantie suffisante'),
  (t.dos(2),(SELECT id FROM utilisateur WHERE login='sec'),'rejet','Stock insuffisant');
SELECT t.refuse('C visite préalable obligatoire', 'SELECT mf.decider_dossier(t.dos(2), ''Égalité tranchée par le président'')');
UPDATE seance_dossier SET visite_le = current_date, visite_par = (SELECT id FROM utilisateur WHERE login='sec') WHERE id = t.dos(2);
SELECT t.refuse('C contre-visite par la même personne refusée', 'UPDATE mf.seance_dossier SET contre_visite_le = current_date, contre_visite_par = visite_par WHERE id = t.dos(2)');
SELECT t.eq('C D2 égalité : voix prépondérante du président', mf.decider_dossier(t.dos(2), 'Égalité tranchée par le président'), 'acceptation');

-- D4 : trois avis différents => ajournement, la demande reste en attente
INSERT INTO seance_vote(dossier_id,utilisateur_id,vote,motif) VALUES
  (t.dos(4),(SELECT id FROM utilisateur WHERE login='pres'),'acceptation','Plutôt favorable au dossier'),
  (t.dos(4),(SELECT id FROM utilisateur WHERE login='sec'),'rejet','Informations insuffisantes'),
  (t.dos(4),(SELECT id FROM utilisateur WHERE login='m1'),'ajournement','Compléter le dossier');
SELECT t.eq('C D4 ajournement', mf.decider_dossier(t.dos(4), 'Pièces à compléter avant nouvel examen'), 'ajournement');
SELECT t.eq('C D4 demande toujours en attente', statut, 'demandee') FROM demande_credit WHERE id = 4;

-- ===== D. Procès-verbal et clôture =====
SELECT t.refuse('D clôture sans signatures', 'SELECT mf.cloturer_seance(1)');
SELECT t.refuse('D signature par un simple membre', 'SELECT mf.signer_pv(1,(SELECT id FROM mf.utilisateur WHERE login=''m1''))');
SELECT t.eq('D signature président', signer_pv(1,(SELECT id FROM utilisateur WHERE login='pres')), 'president');
SELECT t.refuse('D clôture avec une seule signature', 'SELECT mf.cloturer_seance(1)');
SELECT t.eq('D signature secrétaire', signer_pv(1,(SELECT id FROM utilisateur WHERE login='sec')), 'secretaire');
SELECT cloturer_seance(1);
SELECT t.eq('D séance close', statut, 'close') FROM seance_comite WHERE id = 1;
SELECT t.refuse('D séance close : présence figée', 'UPDATE mf.seance_presence SET present = false');
SELECT t.refuse('D séance close : dossier figé', 'UPDATE mf.seance_dossier SET motif = ''modifié'' WHERE id = t.dos(1)');
SELECT t.refuse('D séance close : vote figé', 'DELETE FROM mf.seance_vote');
SELECT t.refuse('D séance close : séance figée', 'UPDATE mf.seance_comite SET lieu = ''ailleurs''');
SELECT t.eq('D analyse globale', total_demande || '/' || total_accorde || '/' || nb_acceptes || '/' || nb_ajournes || '/' || nb_rejetes,
  '1400000/1050000/2/1/0') FROM v_seance_analyse_globale WHERE seance_id = 1;

-- D4 peut être réinscrit à une nouvelle séance (la précédente est décidée)
INSERT INTO seance_dossier(seance_id,demande_id,analyse_individuelle) VALUES (2,4,'Pièces complétées');
SELECT t.eq('D réinscription après ajournement', count(*)::text, '1') FROM seance_dossier WHERE seance_id = 2;

-- ===== E. Comité obligatoire et délégations =====
INSERT INTO demande_credit(agence_id,client_id,produit_id,montant,nb_echeances,taux,mode_remboursement) VALUES
  (1,1,1,200000,12,0.18,'especes'),(1,1,1,200000,12,0.18,'especes'),(1,1,1,200000,12,0.18,'especes');
SELECT t.eq('E sans le mode obligatoire, décision directe possible', 'ok', 'ok') FROM (SELECT mf.approuver_demande(5, (SELECT id FROM mf.utilisateur WHERE login='pres'), true, 'ok')) x;
INSERT INTO parametre(cle, valeur, agence_id, description) VALUES ('comite_credit_obligatoire','1',1,'actif');
SELECT t.refuse('E décision directe refusée en mode comité', 'SELECT mf.approuver_demande(6, (SELECT id FROM mf.utilisateur WHERE login=''pres''), true, ''direct'')');
SELECT t.refuse('E auto-délégation refusée', 'INSERT INTO mf.delegation_credit(utilisateur_id,montant_max_credit,motif,accordee_par) SELECT id,500000,''auto'',id FROM mf.utilisateur WHERE login=''pres''');
INSERT INTO delegation_credit(utilisateur_id,montant_max_credit,montant_max_periode,periode,motif,accordee_par) VALUES
  ((SELECT id FROM utilisateur WHERE login='m2'),250000,350000,'mois','Délégation du directeur',(SELECT id FROM utilisateur WHERE login='autre'));
SELECT t.eq('E délégation ne couvre pas 300 000', mf.delegation_couvre((SELECT id FROM utilisateur WHERE login='m2'), 1::smallint, 300000)::text, 'false');
SELECT approuver_demande(6, (SELECT id FROM utilisateur WHERE login='m2'), true, 'Sous délégation');
SELECT t.eq('E décision sous délégation', statut, 'approuvee') FROM demande_credit WHERE id = 6;
SELECT t.refuse('E plafond de période de la délégation dépassé (cumul 400 000 > 350 000)', 'SELECT mf.approuver_demande(7, (SELECT id FROM mf.utilisateur WHERE login=''m2''), true, ''trop'')');
SELECT t.refuse('E utilisateur sans délégation refusé', 'SELECT mf.approuver_demande(7, (SELECT id FROM mf.utilisateur WHERE login=''m1''), true, ''aucun droit'')');
