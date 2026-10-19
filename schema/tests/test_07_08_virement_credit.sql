-- Version « avec assertions » du script tests_virement_credit.sql du client (mêmes données, mêmes valeurs attendues).
SET search_path = mf, public;

-- ===== Données de base =====
INSERT INTO agence(code,libelle) VALUES ('LOM','Lomé Centre');
INSERT INTO zone(agence_id,code,libelle) VALUES (1,'Z1','Zone Marché');
INSERT INTO agent(agence_id,matricule,nom) VALUES (1,'A01','Ama');
INSERT INTO client(agence_id,zone_id,numero,nom) VALUES (1,1,'C001','Client Un'),(1,1,'C002','Client Deux');
INSERT INTO produit_epargne(code,libelle,categorie,type_cycle,nb_pages_livret) VALUES
  ('P1','Tontine normale','collecte',1,1),('P3','Tontine libre','collecte',3,1);
INSERT INTO produit_epargne(code,libelle,categorie,taux_interet,solde_minimum) VALUES ('CL','Compte classique','classique',0.02,5000);
INSERT INTO compte_epargne(agence_id,client_id,produit_id,numero) VALUES (1,1,3,'CE001'),(1,2,3,'CE002');
INSERT INTO mouvement_epargne(compte_id,type,montant) VALUES (1,'depot',100000),(2,'depot',50000);

-- ===== T1 : épargne -> tontine =====
INSERT INTO cycle(agence_id,numero,client_id,produit_id,type_cycle,mise_initiale,mise_courante,objectif,date_debut,date_fin)
VALUES (1,'CY1',1,1,1,500,500,15500,'2026-10-01','2026-10-31');
SELECT virement_epargne_vers_tontine(1,1,3000,'2026-10-10');
SELECT t.eq('T1 lignes', count(*)::text || '/' || sum(montant_collecte)::text || '/' || min(origine) || '/' || coalesce(min(agent_id)::text,'NULL'), '6/3000/virement/NULL') FROM ligne_collecte WHERE cycle_id=1;
SELECT t.eq('T1 situation', montant_collecte::text || '/' || montant_previsionnel::text || '/' || reste_a_collecter::text, '3000/15500/12500') FROM v_cycle_situation WHERE cycle_id=1;
SELECT t.eq('T1 compte', solde::text || '/' || solde_disponible(1)::text, '97000/92000') FROM v_solde_compte_epargne WHERE compte_id=1;
SELECT t.refuse('T1 montant non multiple de la mise', 'SELECT mf.virement_epargne_vers_tontine(1,1,3100,''2026-10-10'')');
SELECT t.refuse('T1 compte d''un autre client', 'SELECT mf.virement_epargne_vers_tontine(2,1,500,''2026-10-10'')');
SELECT t.refuse('T1 retrait au-delà du disponible', 'INSERT INTO mf.mouvement_epargne(compte_id,type,montant) VALUES (1,''retrait'',99999)');
SELECT t.refuse('T1 virement sans fonds suffisants', 'SELECT mf.virement_epargne_vers_tontine(1,1,500000,''2026-10-10'')');
SELECT t.eq('T1 aucune ligne ajoutée par les refus', count(*)::text, '6') FROM ligne_collecte WHERE cycle_id=1;

-- ===== T2 : tontine -> épargne, sans écart =====
INSERT INTO cycle(agence_id,numero,client_id,produit_id,type_cycle,mise_initiale,mise_courante,objectif,date_debut,date_fin)
VALUES (1,'CY2',1,1,1,1000,1000,31000,'2026-10-01','2026-10-31');
INSERT INTO ligne_collecte(cycle_id,page,no_ligne,date_collecte,agent_id,montant_collecte)
SELECT 2,1,g,'2026-10-01'::date+g-1,1,1000 FROM generate_series(1,10) g;
SELECT demander_virement_cycle_vers_epargne(2,1,NULL,'2026-10-20');
SELECT t.eq('T2 retrait', nature || '/' || montant::text || '/' || decaissement::text || '/' || statut, 'virement_vers_epargne/9000/false/demande') FROM retrait WHERE cycle_id=2;
SELECT t.refuse('T2 exécution avant constat', 'SELECT mf.executer_retrait((SELECT id FROM mf.retrait WHERE cycle_id=2))');
SELECT constater_sans_ecart((SELECT id FROM retrait WHERE cycle_id=2));
SELECT executer_retrait((SELECT id FROM retrait WHERE cycle_id=2));
SELECT t.eq('T2 virement', sens || '/' || montant::text || '/' || montant_credite::text || '/' || statut, 'cycle_vers_epargne/9000/9000/execute') FROM virement WHERE cycle_id=2;
SELECT t.eq('T2 cycle retiré', statut, 'retire') FROM cycle WHERE id=2;
SELECT t.eq('T2 compte', solde::text, '106000') FROM v_solde_compte_epargne WHERE compte_id=1;

-- ===== T2b : livret > machine (le client est crédité selon le livret) =====
INSERT INTO cycle(agence_id,numero,client_id,produit_id,type_cycle,mise_initiale,mise_courante,objectif,date_debut,date_fin)
VALUES (1,'CY3',1,1,1,1000,1000,31000,'2026-10-01','2026-10-31');
INSERT INTO ligne_collecte(cycle_id,page,no_ligne,date_collecte,agent_id,montant_collecte)
SELECT 3,1,g,'2026-10-01'::date+g-1,1,1000 FROM generate_series(1,5) g;
SELECT demander_virement_cycle_vers_epargne(3,1,NULL,'2026-10-21');
SELECT enregistrer_ecart_retrait((SELECT id FROM retrait WHERE cycle_id=3), 5500, 5000, '[{"date":"2026-10-03","montant":500,"agent_id":1}]');
SELECT t.eq('T2b statut avant traitement', statut, 'ecart_en_traitement') FROM retrait WHERE cycle_id=3;
SELECT t.refuse('T2b exécution avant traitement des écarts', 'SELECT mf.executer_retrait((SELECT id FROM mf.retrait WHERE cycle_id=3))');
SELECT traiter_ecart_retrait((SELECT id FROM ecart_retrait WHERE cycle_id=3));
SELECT executer_retrait((SELECT id FROM retrait WHERE cycle_id=3));
SELECT t.eq('T2b virement (net machine / crédité)', montant::text || '/' || montant_credite::text, '4000/4500') FROM virement WHERE cycle_id=3;
SELECT t.eq('T2b perte agent', type || '/' || montant::text, 'perte_retrait/500') FROM compte_agent;
SELECT t.eq('T2b compte', solde::text, '110500') FROM v_solde_compte_epargne WHERE compte_id=1;

-- ===== T2c : machine > livret =====
INSERT INTO cycle(agence_id,numero,client_id,produit_id,type_cycle,mise_initiale,mise_courante,objectif,date_debut,date_fin)
VALUES (1,'CY4',1,1,1,1000,1000,31000,'2026-10-01','2026-10-31');
INSERT INTO ligne_collecte(cycle_id,page,no_ligne,date_collecte,agent_id,montant_collecte)
SELECT 4,1,g,'2026-10-01'::date+g-1,1,1000 FROM generate_series(1,4) g;
SELECT demander_virement_cycle_vers_epargne(4,1,NULL,'2026-10-22');
SELECT enregistrer_ecart_retrait((SELECT id FROM retrait WHERE cycle_id=4 AND nature='virement_vers_epargne'), 3800, 4000, '[{"date":"2026-10-02","montant":200,"agent_id":1}]');
SELECT executer_retrait((SELECT id FROM retrait WHERE cycle_id=4 AND nature='virement_vers_epargne'));
SELECT t.eq('T2c virement', montant::text || '/' || montant_credite::text, '3000/2800') FROM virement WHERE cycle_id=4;
SELECT t.eq('T2c excédent', statut || '/' || montant::text, 'a_regulariser/200') FROM excedent_regularisation;
SELECT t.eq('T2c compte', solde::text, '113300') FROM v_solde_compte_epargne WHERE compte_id=1;

-- ===== T3 : crédit sur épargne classique, garantie, déblocage sur compte =====
INSERT INTO produit_credit_epargne(code,libelle,type,taux_annuel,frais_dossier_taux,periodicite_jours,methode) VALUES
  ('PCE1','Crédit sur épargne','sur_epargne',0.12,0.01,30,'capital_constant'),
  ('PCS1','Crédit sans épargne','sans_epargne',0.12,0,30,'capital_constant');
SELECT t.refuse('T3 crédit sur épargne sans garantie', 'SELECT mf.nouvelle_demande_credit(1,1,1,30000,3,NULL,0)');
SELECT t.eq('T3 demande', nouvelle_demande_credit(1,1,1,30000,3,NULL,20000,'prelevement_compte','Garantie négociée à 20 000')::text, '1');
SELECT approuver_demande(1,NULL,true,'dossier complet');
SELECT t.eq('T3 crédit', debloquer_credit(1,'2026-11-01','compte')::text, '1');
SELECT t.eq('T3 échéances', string_agg(capital::text || '+' || interet::text, ',' ORDER BY no_echeance), '10000+300,10000+200,10000+100') FROM echeance WHERE credit_id=1;
SELECT t.eq('T3 dates des échéances', string_agg(date_prevue::text, ',' ORDER BY no_echeance), '2026-12-01,2026-12-31,2027-01-30') FROM echeance WHERE credit_id=1;
SELECT t.eq('T3 garantie', montant_bloque::text || '/' || montant_restant::text || '/' || statut, '20000/20000/bloquee') FROM garantie_compte;
SELECT t.eq('T3 compte (30000 débloqués - 300 de frais)', solde::text || '/' || solde_disponible(1)::text, '143000/118000') FROM v_solde_compte_epargne WHERE compte_id=1;
SELECT t.refuse('T3 retrait dans la garantie', 'INSERT INTO mf.mouvement_epargne(compte_id,type,montant) VALUES (1,''retrait'',125000)');

-- ===== T4 : prélèvements, retard, saisie de la garantie =====
SELECT t.eq('T4 prélèvement échéance 1', prelever_echeances_compte(1::smallint,'2026-12-01')::text, '1');
SELECT t.eq('T4 prélèvement échéance 2', prelever_echeances_compte(1::smallint,'2026-12-31')::text, '1');
SELECT t.eq('T4 points à temps', string_agg(points::text, ',' ORDER BY id), '10,10') FROM points_fidelite;
INSERT INTO mouvement_epargne(compte_id,type,montant) VALUES (1,'retrait', solde_disponible(1) - 5000);
SELECT t.eq('T4 fonds insuffisants à 5 jours de retard', prelever_echeances_compte(1::smallint,'2027-02-04')::text, '0');
SELECT maj_statuts_credit(1::smallint,'2027-02-04');
SELECT t.eq('T4 échéance 3 échue, pénalité 50', statut || '/' || penalite_due::text, 'echue/50') FROM echeance WHERE credit_id=1 AND no_echeance=3;
SELECT t.eq('T4 crédit en retard', statut, 'en_retard') FROM credit WHERE id=1;
SELECT t.eq('T4 saisie trop tôt (5 j <= 30)', saisir_garantie_echeances(1::smallint,'2027-02-04')::text, '0');
SELECT t.eq('T4 saisie à 40 jours', saisir_garantie_echeances(1::smallint,'2027-03-11')::text, '1');
SELECT t.eq('T4 échéance 3 payée avec 400 de pénalité', statut || '/' || penalite_due::text || '/' || penalite_payee::text, 'payee/400/400') FROM echeance WHERE credit_id=1 AND no_echeance=3;
SELECT t.eq('T4 crédit soldé', statut, 'solde') FROM credit WHERE id=1;
SELECT t.eq('T4 garantie : saisie puis libération du reste', montant_bloque::text || '/' || montant_saisi::text || '/' || montant_restant::text || '/' || statut, '20000/10500/0/liberee') FROM garantie_compte;
SELECT t.eq('T4 points 10 + 10 - 16', points::text, '4') FROM v_points_client WHERE client_id=1;

-- ===== T5 : crédit sans épargne, espèces =====
INSERT INTO caisse(agence_id,code,type) VALUES (1,'CP','principale');
INSERT INTO session_caisse(caisse_id,date_session,solde_ouverture) VALUES (1,'2026-11-05',1000000);
SELECT t.eq('T5 demande', nouvelle_demande_credit(2,2,2,10000,2,0.12,0,'especes','sans garantie')::text, '2');
SELECT approuver_demande(2,NULL,true);
SELECT t.eq('T5 crédit', debloquer_credit(2,'2026-11-05','especes',1)::text, '2');
SELECT rembourser_echeance_especes((SELECT id FROM echeance WHERE credit_id=2 AND no_echeance=1), 2000, 1, '2026-12-05');
SELECT t.eq('T5 partielle', statut || '/' || capital_paye::text, 'partielle/2000') FROM echeance WHERE credit_id=2 AND no_echeance=1;
SELECT t.refuse('T5 échéance 2 avant la 1', 'SELECT mf.rembourser_echeance_especes((SELECT id FROM mf.echeance WHERE credit_id=2 AND no_echeance=2), 100, 1, ''2026-12-05'')');
SELECT rembourser_echeance_especes((SELECT id FROM echeance WHERE credit_id=2 AND no_echeance=1), 3100, 1, '2026-12-05');
SELECT t.eq('T5 soldée', statut || '/' || capital_paye::text || '/' || interet_paye::text, 'payee/5000/100') FROM echeance WHERE credit_id=2 AND no_echeance=1;
SELECT t.eq('T5 caisse', encaissements::text || '/' || decaissements::text || '/' || solde_theorique::text, '5100/10000/995100') FROM v_session_caisse_solde;
SELECT t.refuse('T5 espèces sur un crédit à prélèvement', 'SELECT mf.rembourser_echeance_especes(1, 100, 1, ''2026-12-05'')');

-- ===== T6 : annuité constante =====
INSERT INTO credit(agence_id,numero,client_id,type,montant_accorde,taux,date_deblocage,nb_echeances,mode_remboursement)
VALUES (1,'CR-ANN',2,'sans_epargne',100000,0.12,'2026-11-01',12,'especes');
SELECT generer_echeancier(3,30,'annuite_constante');
SELECT t.eq('T6 annuité', count(*)::text || '/' || sum(capital)::text || '/' || (min(capital+interet) BETWEEN 8880 AND 8890)::text || '/' || (max(capital+interet) BETWEEN 8880 AND 8890)::text, '12/100000/true/true') FROM echeance WHERE credit_id=3;

-- ===== T7 : vues et rapports, reproductibles pour une date passée =====
SELECT t.eq('T7 situation des crédits', string_agg(numero || ':' || capital_restant::text || ':' || statut, ' ' ORDER BY credit_id),
            'CR-LOM-2026-000001:0:solde CR-LOM-2026-000002:5000:en_cours CR-ANN:100000:en_cours') FROM v_credit_epargne_situation;
SELECT t.eq('T7 rapport 20/10 : virement tontine -> épargne', valeur::text, '9000') FROM rapport_journalier_global(1::smallint,'2026-10-20') WHERE rubrique='virements_tontine_vers_epargne';
SELECT t.eq('T7 rapport 20/10 : cycles clôturés', valeur::text, '1') FROM rapport_journalier_global(1::smallint,'2026-10-20') WHERE rubrique='cycles_clotures';
SELECT t.eq('T7 rapport 01/12 : prélèvement', valeur::text, '10300') FROM rapport_journalier_global(1::smallint,'2026-12-01') WHERE rubrique='remboursements_prelevement';
SELECT t.eq('T7 rapport 01/12 : capital et intérêts', string_agg(rubrique || '=' || valeur::text, ',' ORDER BY rubrique), 'remboursements_capital=10000,remboursements_interets=300')
  FROM rapport_journalier_global(1::smallint,'2026-12-01') WHERE rubrique IN ('remboursements_capital','remboursements_interets');
SELECT t.eq('T7 rapport agent 01/10 (virements exclus)', montant_collecte::text, '3000') FROM rapport_journalier_agent(1::smallint,'2026-10-01') WHERE agent='Ama';
SELECT t.eq('T7 rapport zone 01/10', montant_collecte::text || '/' || nb_lignes::text, '3000/3') FROM rapport_journalier_zone(1::smallint,'2026-10-01') WHERE zone='Z1';

-- reproductibilité : les opérations postérieures (saisie du 11/03/2027, etc.) ne changent pas l'état au 04/02/2027
SELECT t.eq('T7 échus au 04/02/2027 : échéance 3 du crédit 1', credit || ':' || jours_retard::text || ':' || du::text || ':' || penalite::text,
            'CR-LOM-2026-000001:5:10100:50') FROM remboursements_echus(1::smallint,'2027-02-04') WHERE credit = 'CR-LOM-2026-000001';
SELECT t.eq('T7 statut du crédit 1 au 04/02/2027 (rapport rejoué)', statut_a_date || '/' || capital_restant::text || '/' || garantie_bloquee::text, 'en_retard/10000/20000')
  FROM situation_credits(1::smallint,'2027-02-04') WHERE credit = 'CR-LOM-2026-000001';
SELECT t.eq('T7 statut du crédit 1 au 11/03/2027', statut_a_date || '/' || capital_restant::text || '/' || garantie_bloquee::text, 'solde/0/0')
  FROM situation_credits(1::smallint,'2027-03-11') WHERE credit = 'CR-LOM-2026-000001';
SELECT t.eq('T7 à venir au 25/12/2026 (7 jours : échéances du 31/12)', string_agg(credit || '#' || no_echeance::text, ',' ORDER BY date_prevue, credit), 'CR-ANN#2,CR-LOM-2026-000001#2')
  FROM remboursements_a_venir(1::smallint,'2026-12-25') WHERE credit IN ('CR-LOM-2026-000001','CR-ANN');
