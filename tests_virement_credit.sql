\set ON_ERROR_STOP on
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
SELECT 'T1 virement' t, mf.virement_epargne_vers_tontine(1,1,3000,'2026-10-10');
SELECT 'T1 lignes' t, count(*) nb, sum(montant_collecte) total, min(origine) origine, min(agent_id) agent FROM ligne_collecte WHERE cycle_id=1;   -- 6 / 3000 / virement / NULL
SELECT 'T1 situation' t, montant_collecte, montant_previsionnel, reste_a_collecter FROM v_cycle_situation WHERE cycle_id=1;                       -- 3000 / 15500 / 12500
SELECT 'T1 compte' t, solde, mf.solde_disponible(1) AS dispo FROM v_solde_compte_epargne WHERE compte_id=1;                                         -- 97000 / 92000
DO $$ BEGIN PERFORM mf.virement_epargne_vers_tontine(1,1,3100,'2026-10-10'); RAISE NOTICE 'T1 ERREUR : 3100 aurait dû être refusé';
  EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'T1 refus non multiple de la mise OK : %', SQLERRM; END $$;
DO $$ BEGIN PERFORM mf.virement_epargne_vers_tontine(2,1,500,'2026-10-10'); RAISE NOTICE 'T1 ERREUR : autre client accepté';
  EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'T1 refus autre client OK : %', SQLERRM; END $$;
DO $$ BEGIN INSERT INTO mf.mouvement_epargne(compte_id,type,montant) VALUES (1,'retrait',99999); RAISE NOTICE 'T1 ERREUR : retrait au-delà du disponible accepté';
  EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'T1 refus retrait > disponible OK : %', SQLERRM; END $$;

-- ===== T2 : tontine -> épargne, sans écart =====
INSERT INTO cycle(agence_id,numero,client_id,produit_id,type_cycle,mise_initiale,mise_courante,objectif,date_debut,date_fin)
VALUES (1,'CY2',1,1,1,1000,1000,31000,'2026-10-01','2026-10-31');
INSERT INTO ligne_collecte(cycle_id,page,no_ligne,date_collecte,agent_id,montant_collecte)
SELECT 2,1,g,'2026-10-01'::date+g-1,1,1000 FROM generate_series(1,10) g;
SELECT 'T2 demande' t, mf.demander_virement_cycle_vers_epargne(2,1,NULL,'2026-10-20');
SELECT 'T2 retrait' t, nature, montant, decaissement, statut FROM retrait WHERE cycle_id=2;                    -- 9000, f, demande
DO $$ BEGIN PERFORM mf.executer_retrait((SELECT id FROM mf.retrait WHERE cycle_id=2)); RAISE NOTICE 'T2 ERREUR : exécution sans constat';
  EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'T2 refus exécution avant constat OK : %', SQLERRM; END $$;
SELECT mf.constater_sans_ecart((SELECT id FROM retrait WHERE cycle_id=2));
SELECT mf.executer_retrait((SELECT id FROM retrait WHERE cycle_id=2));
SELECT 'T2 virement' t, sens, montant, montant_credite, statut FROM virement WHERE cycle_id=2;                  -- 9000 / 9000 / execute
SELECT 'T2 cycle' t, statut FROM cycle WHERE id=2;                                                              -- retire
SELECT 'T2 compte' t, solde FROM v_solde_compte_epargne WHERE compte_id=1;                                      -- 106000

-- ===== T2b : tontine -> épargne, livret > machine (le client est crédité selon le livret) =====
INSERT INTO cycle(agence_id,numero,client_id,produit_id,type_cycle,mise_initiale,mise_courante,objectif,date_debut,date_fin)
VALUES (1,'CY3',1,1,1,1000,1000,31000,'2026-10-01','2026-10-31');
INSERT INTO ligne_collecte(cycle_id,page,no_ligne,date_collecte,agent_id,montant_collecte)
SELECT 3,1,g,'2026-10-01'::date+g-1,1,1000 FROM generate_series(1,5) g;
SELECT mf.demander_virement_cycle_vers_epargne(3,1,NULL,'2026-10-21');                                          -- net machine 4000
SELECT mf.enregistrer_ecart_retrait((SELECT id FROM retrait WHERE cycle_id=3), 5500, 5000,
       '[{"date":"2026-10-03","montant":500,"agent_id":1}]');
SELECT 'T2b statut avant traitement' t, statut FROM retrait WHERE cycle_id=3;                                   -- ecart_en_traitement
DO $$ BEGIN PERFORM mf.executer_retrait((SELECT id FROM mf.retrait WHERE cycle_id=3)); RAISE NOTICE 'T2b ERREUR : exécution avant traitement';
  EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'T2b refus avant traitement des écarts OK : %', SQLERRM; END $$;
SELECT mf.traiter_ecart_retrait((SELECT id FROM ecart_retrait WHERE cycle_id=3));
SELECT mf.executer_retrait((SELECT id FROM retrait WHERE cycle_id=3));
SELECT 'T2b virement' t, montant, montant_credite, statut FROM virement WHERE cycle_id=3;                       -- 4000 / 4500
SELECT 'T2b perte agent' t, type, montant, date_operation FROM compte_agent;                                    -- perte_retrait 500
SELECT 'T2b compte' t, solde FROM v_solde_compte_epargne WHERE compte_id=1;                                     -- 110500

-- ===== T2c : tontine -> épargne, machine > livret =====
INSERT INTO cycle(agence_id,numero,client_id,produit_id,type_cycle,mise_initiale,mise_courante,objectif,date_debut,date_fin)
VALUES (1,'CY4',1,1,1,1000,1000,31000,'2026-10-01','2026-10-31');
INSERT INTO ligne_collecte(cycle_id,page,no_ligne,date_collecte,agent_id,montant_collecte)
SELECT 4,1,g,'2026-10-01'::date+g-1,1,1000 FROM generate_series(1,4) g;
SELECT mf.demander_virement_cycle_vers_epargne(4,1,NULL,'2026-10-22');                                          -- net machine 3000
SELECT mf.enregistrer_ecart_retrait((SELECT id FROM retrait WHERE cycle_id=4 AND nature='virement_vers_epargne'), 3800, 4000,
       '[{"date":"2026-10-02","montant":200,"agent_id":1}]');
SELECT mf.executer_retrait((SELECT id FROM retrait WHERE cycle_id=4 AND nature='virement_vers_epargne'));
SELECT 'T2c virement' t, montant, montant_credite FROM virement WHERE cycle_id=4;                               -- 3000 / 2800
SELECT 'T2c excedent' t, statut, montant FROM excedent_regularisation;                                          -- a_regulariser 200
SELECT 'T2c compte' t, solde FROM v_solde_compte_epargne WHERE compte_id=1;                                     -- 113300

-- ===== T3 : crédit sur épargne classique, garantie, déblocage sur compte =====
INSERT INTO produit_credit_epargne(code,libelle,type,taux_annuel,frais_dossier_taux,periodicite_jours,methode) VALUES
  ('PCE1','Crédit sur épargne','sur_epargne',0.12,0.01,30,'capital_constant'),
  ('PCS1','Crédit sans épargne','sans_epargne',0.12,0,30,'capital_constant');
DO $$ BEGIN PERFORM mf.nouvelle_demande_credit(1,1,1,30000,3,NULL,0); RAISE NOTICE 'T3 ERREUR : sur épargne sans garantie accepté';
  EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'T3 refus sans garantie OK : %', SQLERRM; END $$;
SELECT 'T3 demande' t, mf.nouvelle_demande_credit(1,1,1,30000,3,NULL,20000,'prelevement_compte','Garantie négociée à 20 000');
SELECT mf.approuver_demande(1,NULL,true,'dossier complet');
SELECT 'T3 credit' t, mf.debloquer_credit(1,'2026-11-01','compte');
SELECT 'T3 echeances' t, no_echeance, date_prevue, capital, interet FROM echeance WHERE credit_id=1 ORDER BY 2;   -- 10000+300, 10000+200, 10000+100
SELECT 'T3 garantie' t, montant_bloque, montant_restant, statut FROM garantie_compte;                             -- 20000 bloquée
SELECT 'T3 compte' t, solde, mf.solde_disponible(1) AS dispo FROM v_solde_compte_epargne WHERE compte_id=1;       -- 143000 / 118000
DO $$ BEGIN INSERT INTO mf.mouvement_epargne(compte_id,type,montant) VALUES (1,'retrait',125000); RAISE NOTICE 'T3 ERREUR : retrait dans la garantie accepté';
  EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'T3 refus retrait dans la garantie OK : %', SQLERRM; END $$;

-- ===== T4 : prélèvements automatiques, retard, saisie de la garantie =====
SELECT 'T4 prelevement éch.1' t, mf.prelever_echeances_compte(1::smallint,'2026-12-01');    -- 1 (10300)
SELECT 'T4 prelevement éch.2' t, mf.prelever_echeances_compte(1::smallint,'2026-12-31');    -- 1 (10200)
SELECT 'T4 echeances' t, no_echeance, statut, capital_paye, interet_paye FROM echeance WHERE credit_id=1 ORDER BY 2;
SELECT 'T4 points' t, motif, points FROM points_fidelite ORDER BY id;                        -- +10, +10
-- le client vide son disponible : 5 000 restent
INSERT INTO mouvement_epargne(compte_id,type,montant) VALUES (1,'retrait', mf.solde_disponible(1) - 5000);
SELECT 'T4 retard 5j' t, mf.prelever_echeances_compte(1::smallint,'2027-02-04');             -- 0 : fonds insuffisants
SELECT mf.maj_statuts_credit(1::smallint,'2027-02-04');
SELECT 'T4 echeance 3' t, statut, penalite_due FROM echeance WHERE credit_id=1 AND no_echeance=3;   -- echue / 50
SELECT 'T4 credit' t, statut FROM credit WHERE id=1;                                           -- en_retard
SELECT 'T4 saisie trop tôt' t, mf.saisir_garantie_echeances(1::smallint,'2027-02-04');       -- 0 (5 j <= 30)
SELECT 'T4 saisie à 40 j' t, mf.saisir_garantie_echeances(1::smallint,'2027-03-11');         -- 1
SELECT 'T4 echeance 3 après' t, statut, penalite_due, penalite_payee FROM echeance WHERE credit_id=1 AND no_echeance=3;   -- payee / 400 / 400
SELECT 'T4 credit après' t, statut FROM credit WHERE id=1;                                     -- solde
SELECT 'T4 garantie après' t, montant_bloque, montant_saisi, montant_restant, statut FROM garantie_compte;   -- 20000 / 10500 / 0 / liberee
SELECT 'T4 points total' t, points FROM v_points_client WHERE client_id=1;                    -- 10+10-16 = 4

-- ===== T5 : crédit sans épargne, déblocage et remboursements en espèces =====
INSERT INTO caisse(agence_id,code,type) VALUES (1,'CP','principale');
INSERT INTO session_caisse(caisse_id,date_session,solde_ouverture) VALUES (1,'2026-11-05',1000000);
SELECT 'T5 demande' t, mf.nouvelle_demande_credit(2,2,2,10000,2,0.12,0,'especes','sans garantie');
SELECT mf.approuver_demande(2,NULL,true);
SELECT 'T5 credit' t, mf.debloquer_credit(2,'2026-11-05','especes',1);
SELECT mf.rembourser_echeance_especes((SELECT id FROM echeance WHERE credit_id=2 AND no_echeance=1), 2000, 1, '2026-12-05');
SELECT 'T5 partielle' t, statut, capital_paye FROM echeance WHERE credit_id=2 AND no_echeance=1;               -- partielle / 2000
DO $$ BEGIN PERFORM mf.rembourser_echeance_especes((SELECT id FROM mf.echeance WHERE credit_id=2 AND no_echeance=2), 100, 1, '2026-12-05');
  RAISE NOTICE 'T5 ERREUR : échéance 2 payée avant la 1';
  EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'T5 refus ordre des échéances OK : %', SQLERRM; END $$;
SELECT mf.rembourser_echeance_especes((SELECT id FROM echeance WHERE credit_id=2 AND no_echeance=1), 3100, 1, '2026-12-05');
SELECT 'T5 soldée' t, statut, capital_paye, interet_paye FROM echeance WHERE credit_id=2 AND no_echeance=1;    -- payee / 5000 / 100
SELECT 'T5 caisse' t, encaissements, decaissements, solde_theorique FROM v_session_caisse_solde;                -- 5100 / 10000 / 995100

-- ===== T6 : annuité constante =====
INSERT INTO credit(agence_id,numero,client_id,type,montant_accorde,taux,date_deblocage,nb_echeances,mode_remboursement)
VALUES (1,'CR-ANN',2,'sans_epargne',100000,0.12,'2026-11-01',12,'especes');
SELECT mf.generer_echeancier(3,30,'annuite_constante');
SELECT 'T6 annuité' t, count(*) nb, sum(capital) capital, min(capital+interet) mini, max(capital+interet) maxi FROM echeance WHERE credit_id=3;   -- 12 / 100000 / ~8885

-- ===== T7 : vues et rapport =====
SELECT 'T7 situation' t, numero, type, mode_remboursement, capital_restant, garantie_bloquee, statut FROM v_credit_epargne_situation ORDER BY credit_id;
SELECT 'T7 rapport 2026-10-20' t, rubrique, valeur FROM mf.rapport_journalier_global(1::smallint,'2026-10-20') WHERE valeur <> 0;
SELECT 'T7 rapport 2026-12-01' t, rubrique, valeur FROM mf.rapport_journalier_global(1::smallint,'2026-12-01') WHERE valeur <> 0;
SELECT 'T7 rapport agent 2026-10-01' t, agent, montant_collecte FROM mf.rapport_journalier_agent(1::smallint,'2026-10-01');
