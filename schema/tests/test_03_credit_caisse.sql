SET search_path = mf, public;

CREATE OR REPLACE FUNCTION t.cy(p_numero text) RETURNS integer LANGUAGE sql AS $$ SELECT id FROM mf.cycle WHERE numero = p_numero $$;
CREATE OR REPLACE FUNCTION t.cr(p_numero text) RETURNS integer LANGUAGE sql AS $$ SELECT id FROM mf.credit WHERE numero = p_numero $$;
CREATE OR REPLACE FUNCTION t.ec(p_credit text, p_no integer) RETURNS integer LANGUAGE sql AS $$
  SELECT id FROM mf.echeance WHERE credit_id = t.cr(p_credit) AND no_echeance = p_no $$;
CREATE OR REPLACE FUNCTION t.rb(p_cycle text, p_no integer) RETURNS integer LANGUAGE sql AS $$
  SELECT id FROM (SELECT id, row_number() OVER (ORDER BY id) rn FROM mf.retrait
                   WHERE cycle_id = t.cy(p_cycle) AND nature = 'remboursement') x WHERE rn = p_no $$;

-- ===== Données de base =====
INSERT INTO agence(code,libelle) VALUES ('LOM','Lomé Centre');
INSERT INTO zone(agence_id,code,libelle) VALUES (1,'Z1','Zone Marché');
INSERT INTO agent(agence_id,matricule,nom) VALUES (1,'A01','Ama');
INSERT INTO client(agence_id,zone_id,numero,nom) VALUES
  (1,1,'C001','Un'),(1,1,'C002','Deux'),(1,1,'C003','Trois'),(1,1,'C004','Quatre');
INSERT INTO produit_epargne(code,libelle,categorie,type_cycle,nb_pages_livret) VALUES ('P1','Tontine','collecte',1,1);

-- ===== E. Échéanciers =====
INSERT INTO credit(agence_id,numero,client_id,type,montant_accorde,taux,date_deblocage,nb_echeances,mode_remboursement)
VALUES (1,'CR-CC',1,'sans_epargne',30000,0.12,'2026-11-01',3,'especes'),
       (1,'CR-ANN',2,'sans_epargne',100000,0.12,'2026-11-01',12,'especes'),
       (1,'CR-OK',2,'sans_epargne',10000,0.12,'2026-11-01',1,'especes');
SELECT t.eq('E nb échéances capital constant', generer_echeancier(t.cr('CR-CC'))::text, '3');
SELECT t.eq('E capital + intérêt par échéance', string_agg(capital::text || '+' || interet::text, ',' ORDER BY no_echeance), '10000+300,10000+200,10000+100')
  FROM echeance WHERE credit_id = t.cr('CR-CC');
SELECT t.eq('E dates (déblocage + 30 j x n)', min(date_prevue)::text || '/' || max(date_prevue)::text, '2026-12-01/2027-01-30')
  FROM echeance WHERE credit_id = t.cr('CR-CC');
SELECT t.refuse('E échéancier déjà généré', format('SELECT mf.generer_echeancier(%s)', t.cr('CR-CC')));
SELECT generer_echeancier(t.cr('CR-ANN'), 30, 'annuite_constante');
SELECT t.eq('E annuité : 12 échéances, capital total', count(*)::text || '/' || sum(capital)::text, '12/100000') FROM echeance WHERE credit_id = t.cr('CR-ANN');
SELECT t.eq('E annuité ~ 8885 par échéance', (min(capital+interet) BETWEEN 8880 AND 8890 AND max(capital+interet) BETWEEN 8880 AND 8890)::text, 'true')
  FROM echeance WHERE credit_id = t.cr('CR-ANN');
SELECT t.eq('E annuité : intérêt 1re échéance (100000 x 1 %)', interet::text, '1000') FROM echeance WHERE credit_id = t.cr('CR-ANN') AND no_echeance = 1;
SELECT generer_echeancier(t.cr('CR-OK'));
SELECT t.refuse('E tontine sans cycle de garantie',
  'INSERT INTO mf.credit(agence_id,numero,client_id,type,montant_accorde,taux,date_deblocage,nb_echeances,mode_remboursement) VALUES (1,''X'',1,''sans_epargne'',1000,0.1,''2026-11-01'',1,''tontine'')');

-- ===== P. Pénalité =====
SELECT t.eq('P pas de retard, pas de pénalité', calcul_penalite(10000, 10300, 0)::text, '0');
SELECT t.eq('P 5 jours sur capital 10000', calcul_penalite(10000, 10300, 5)::text, '50');
SELECT t.eq('P plafonnée à 10 % de l''échéance', calcul_penalite(10000, 10300, 200)::text, '1030');

-- ===== I. Imputation, ordre, retard, points =====
SELECT imputer_echeance(t.ec('CR-CC',1), 2000, '2026-12-01', 'especes');
SELECT t.eq('I imputation d''abord sur le capital', capital_paye::text || '/' || interet_paye::text || '/' || statut, '2000/0/partielle') FROM echeance WHERE id = t.ec('CR-CC',1);
SELECT t.refuse('I échéance 2 avant la 1', format('SELECT mf.imputer_echeance(%s, 100, ''2026-12-01'', ''especes'')', t.ec('CR-CC',2)));
SELECT t.refuse('I paiement supérieur au dû', format('SELECT mf.imputer_echeance(%s, 9000, ''2026-12-01'', ''especes'')', t.ec('CR-CC',1)));
SELECT imputer_echeance(t.ec('CR-CC',1), 8300, '2026-12-01', 'especes');
SELECT t.eq('I échéance 1 soldée à temps', capital_paye::text || '/' || interet_paye::text || '/' || statut || '/' || jours_retard::text, '10000/300/payee/0') FROM echeance WHERE id = t.ec('CR-CC',1);
SELECT t.eq('I +10 points à temps', points::text, '10') FROM v_points_client WHERE client_id = 1;
SELECT t.refuse('I échéance déjà payée', format('SELECT mf.imputer_echeance(%s, 100, ''2026-12-01'', ''especes'')', t.ec('CR-CC',1)));

-- au 05/01/2027 sont dépassées : CR-CC éch. 2, CR-ANN éch. 1 et 2, CR-OK éch. 1
SELECT t.eq('I échéances dépassées mises à jour', maj_statuts_credit(1::smallint,'2027-01-05')::text, '4');
SELECT t.eq('I échéance 2 échue, pénalité 50', statut || '/' || penalite_due::text, 'echue/50') FROM echeance WHERE id = t.ec('CR-CC',2);
SELECT t.eq('I crédit en retard', statut, 'en_retard') FROM credit WHERE id = t.cr('CR-CC');
SELECT t.eq('I dû de l''échéance 2 au 05/01 (10200 + 50)', du_echeance(t.ec('CR-CC',2), '2027-01-05')::text, '10250');
SELECT imputer_echeance(t.ec('CR-CC',2), 10200, '2027-01-05', 'especes');
SELECT t.eq('I paiement sans la pénalité : partielle', statut, 'partielle') FROM echeance WHERE id = t.ec('CR-CC',2);
SELECT imputer_echeance(t.ec('CR-CC',2), 50, '2027-01-05', 'especes');
SELECT t.eq('I pénalité payée en dernier', penalite_payee::text || '/' || statut || '/' || jours_retard::text, '50/payee/5') FROM echeance WHERE id = t.ec('CR-CC',2);
SELECT t.eq('I -2 points (1 tranche de 5 jours)', points::text, '8') FROM v_points_client WHERE client_id = 1;
SELECT imputer_echeance(t.ec('CR-CC',3), 10100, '2027-01-30', 'especes');
SELECT t.eq('I crédit soldé', statut || '/' || date_solde::text, 'solde/2027-01-30') FROM credit WHERE id = t.cr('CR-CC');
SELECT t.eq('I pas de bonus (un retard)', points::text, '18') FROM v_points_client WHERE client_id = 1;
SELECT t.eq('I paiements tracés', count(*)::text, '5') FROM paiement_echeance WHERE credit_id = t.cr('CR-CC');   -- 2 + 2 + 1

SELECT imputer_echeance(t.ec('CR-OK',1), 10100, '2026-12-01', 'prelevement');
SELECT t.eq('I crédit soldé sans retard : +10 +20', points::text, '30') FROM v_points_client WHERE client_id = 2;

-- ===== K. Caisse =====
INSERT INTO caisse(agence_id,code,type) VALUES (1,'CP','principale');
INSERT INTO session_caisse(caisse_id,date_session,solde_ouverture) VALUES (1,'2026-11-05',1000000);
SELECT caisse_operation(1,'decaissement','deblocage_credit',10000,'2026-11-05');
SELECT caisse_operation(1,'encaissement','remboursement',5100,'2026-11-05');
SELECT t.eq('K solde théorique', encaissements::text || '/' || decaissements::text || '/' || solde_theorique::text, '5100/10000/995100') FROM v_session_caisse_solde;
SELECT t.refuse('K décaissement au-delà du solde', 'SELECT mf.caisse_operation(1,''decaissement'',''retrait_client'',2000000,''2026-11-05'')');
SELECT t.eq('K écart de fermeture (compté 995000)', fermer_session_caisse(1, 995000)::text, '-100');
SELECT t.refuse('K opération sur session fermée', 'SELECT mf.caisse_operation(1,''encaissement'',''depot'',100,''2026-11-05'')');
SELECT t.refuse('K double fermeture', 'SELECT mf.fermer_session_caisse(1, 995000)');

-- ===== T. Crédit sur tontine : remboursement par seuil =====
INSERT INTO cycle(agence_id,numero,client_id,produit_id,type_cycle,mise_initiale,mise_courante,objectif,date_debut,date_fin)
VALUES (1,'T1',3,1,1,1000,1000,31000,'2026-10-01','2026-10-31');
INSERT INTO credit(agence_id,numero,client_id,type,montant_accorde,taux,date_deblocage,nb_echeances,mode_remboursement,garantie_type,cycle_garantie_id)
VALUES (1,'CR-T',3,'sur_epargne',5000,0.12,'2026-10-01',2,'tontine','cycle',t.cy('T1'));
SELECT generer_echeancier(t.cr('CR-T'));
SELECT t.eq('T échéances 2500+50 puis 2500+25', string_agg(capital::text || '+' || interet::text, ',' ORDER BY no_echeance), '2500+50,2500+25') FROM echeance WHERE credit_id = t.cr('CR-T');
INSERT INTO ligne_collecte(cycle_id,page,no_ligne,date_collecte,agent_id,montant_collecte)
SELECT t.cy('T1'),1,g,'2026-10-01'::date+g-1,1,1000 FROM generate_series(1,10) g;
SELECT t.eq('T deux remboursements déclenchés', count(*)::text, '2') FROM retrait WHERE cycle_id = t.cy('T1') AND nature = 'remboursement';
SELECT t.eq('T seuil 1 atteint le 3/10 (collecté 3000 >= 2550)', montant::text || '/' || date_atteinte::text || '/' || decaissement::text || '/' || statut,
            '2550/2026-10-03/false/demande') FROM retrait WHERE id = t.rb('T1',1);
SELECT t.eq('T seuil 2 atteint le 6/10 (collecté net de la réserve)', montant::text || '/' || date_atteinte::text, '2525/2026-10-06') FROM retrait WHERE id = t.rb('T1',2);
SELECT t.eq('T pas de doublon au rappel', declencher_remboursements(t.cy('T1'))::text, '0');
SELECT t.eq('T net du cycle (10000 - mise 1000 - 5075 rembourses)', net::text, '3925') FROM v_cycle_situation WHERE cycle_id = t.cy('T1');
SELECT t.refuse('T exécution avant constat', format('SELECT mf.executer_retrait(%s)', t.rb('T1',1)));
SELECT constater_sans_ecart(t.rb('T1',1));
SELECT constater_sans_ecart(t.rb('T1',2));
SELECT t.refuse('T échéance 2 avant l''échéance 1', format('SELECT mf.executer_retrait(%s)', t.rb('T1',2)));
SELECT executer_retrait(t.rb('T1',1));
SELECT executer_retrait(t.rb('T1',2));
SELECT t.eq('T échéance 1 payée à la date d''atteinte', statut || '/' || date_paiement::text || '/' || jours_retard::text, 'payee/2026-10-03/0') FROM echeance WHERE id = t.ec('CR-T',1);
SELECT t.eq('T crédit soldé', statut || '/' || date_solde::text, 'solde/2026-10-06') FROM credit WHERE id = t.cr('CR-T');
SELECT t.eq('T points 10 + 10 + 20', points::text, '40') FROM v_points_client WHERE client_id = 3;
SELECT t.eq('T source des paiements', string_agg(DISTINCT source, ','), 'tontine') FROM paiement_echeance WHERE credit_id = t.cr('CR-T');
SELECT t.eq('T le cycle reste en cours', statut, 'en_cours') FROM cycle WHERE id = t.cy('T1');
SELECT demander_retrait_cycle(t.cy('T1'),'retrait_client','2026-10-20');
SELECT t.eq('T retrait final = solde restant', montant::text, '3925') FROM retrait WHERE cycle_id = t.cy('T1') AND nature = 'retrait_client';

-- ===== R. Crédit sur tontine en retard : pénalité et points sur la date d'atteinte du seuil =====
INSERT INTO cycle(agence_id,numero,client_id,produit_id,type_cycle,mise_initiale,mise_courante,objectif,date_debut,date_fin)
VALUES (1,'T2',4,1,1,5000,5000,155000,'2026-09-01','2026-09-30');
INSERT INTO credit(agence_id,numero,client_id,type,montant_accorde,taux,date_deblocage,nb_echeances,mode_remboursement,garantie_type,cycle_garantie_id)
VALUES (1,'CR-T2',4,'sur_epargne',10000,0.12,'2026-08-01',1,'tontine','cycle',t.cy('T2'));
SELECT generer_echeancier(t.cr('CR-T2'));
INSERT INTO ligne_collecte(cycle_id,page,no_ligne,date_collecte,agent_id,montant_collecte)
SELECT t.cy('T2'),1,g,'2026-09-01'::date+g-1,1,5000 FROM generate_series(1,3) g;
SELECT t.eq('R seuil atteint le 3/09 : 10100 + 3 j x 10', montant::text || '/' || date_atteinte::text, '10130/2026-09-03') FROM retrait WHERE id = t.rb('T2',1);
SELECT constater_sans_ecart(t.rb('T2',1));
SELECT executer_retrait(t.rb('T2',1), '2026-09-15');   -- date d'exécution tardive : sans effet sur le retard
SELECT t.eq('R retard calculé sur la date d''atteinte', jours_retard::text || '/' || penalite_payee::text || '/' || date_paiement::text, '3/30/2026-09-03') FROM echeance WHERE id = t.ec('CR-T2',1);
SELECT t.eq('R -2 points, pas de bonus', points::text, '-2') FROM v_points_client WHERE client_id = 4;
