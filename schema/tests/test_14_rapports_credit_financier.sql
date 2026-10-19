SET search_path = mf, public;

-- ===== Données de base =====
INSERT INTO agence(code,libelle) VALUES ('LOM','Lomé Centre'),('KPA','Kpalimé');
INSERT INTO zone(agence_id,code,libelle) VALUES (1,'Z1','Zone');
INSERT INTO agent(agence_id,matricule,nom) VALUES (1,'A1','Ama');
INSERT INTO collectrice(agence_id,matricule,nom) VALUES (1,'K1','Kofi');
INSERT INTO client(agence_id,zone_id,numero,nom) VALUES (1,1,'C1','Un'),(1,1,'C2','Deux'),(1,1,'C3','Trois'),(1,1,'C4','Quatre'),(1,1,'C5','Cinq');
INSERT INTO produit_epargne(code,libelle,categorie,type_cycle) VALUES ('P1','Tontine','collecte',1);

-- A : aucun paiement (retard 35 j au 05/11) ; B : à jour ; C : retard 127 j ; D : récent ; E : soldé le 15/10
INSERT INTO credit(agence_id,numero,client_id,type,montant_accorde,taux,date_deblocage,nb_echeances,mode_remboursement) VALUES
  (1,'CR-A',1,'sans_epargne',30000,0.12,'2026-09-01',3,'especes'),
  (1,'CR-B',2,'sans_epargne',30000,0.12,'2026-09-01',3,'especes'),
  (1,'CR-C',3,'sans_epargne',20000,0.12,'2026-06-01',2,'especes'),
  (1,'CR-D',4,'sans_epargne',10000,0.12,'2026-10-20',1,'especes'),
  (1,'CR-E',5,'sans_epargne',10000,0.12,'2026-09-15',1,'especes');
SELECT generer_echeancier(id) FROM credit ORDER BY id;
SELECT imputer_echeance((SELECT e.id FROM echeance e JOIN credit c ON c.id=e.credit_id WHERE c.numero='CR-B' AND e.no_echeance=1), 10300, '2026-10-01', 'especes');
SELECT imputer_echeance((SELECT e.id FROM echeance e JOIN credit c ON c.id=e.credit_id WHERE c.numero='CR-B' AND e.no_echeance=2), 10200, '2026-10-31', 'prelevement');
SELECT imputer_echeance((SELECT e.id FROM echeance e JOIN credit c ON c.id=e.credit_id WHERE c.numero='CR-E' AND e.no_echeance=1), 10100, '2026-10-15', 'especes');

-- ===== P. Portefeuille à une date =====
SELECT t.eq('P crédits actifs au 05/11 (E soldé)', valeur::text, '4') FROM rapport_portefeuille(1::smallint,'2026-11-05') WHERE rubrique = 'credits_actifs';
SELECT t.eq('P encours', valeur::text, '70000') FROM rapport_portefeuille(1::smallint,'2026-11-05') WHERE rubrique = 'encours_capital';
SELECT t.eq('P jours de retard par crédit', string_agg(numero || ':' || jours_retard::text, ' ' ORDER BY numero), 'CR-A:35 CR-B:0 CR-C:127 CR-D:0') FROM portefeuille_a_date(1::smallint,'2026-11-05');
SELECT t.eq('P montant en retard A (10300 + 10200) et C (10200 + 10100)', string_agg(numero || ':' || montant_en_retard::text, ' ' ORDER BY numero), 'CR-A:20500 CR-B:0 CR-C:20300 CR-D:0') FROM portefeuille_a_date(1::smallint,'2026-11-05');
SELECT t.eq('P PAR 1 jour / 30 / 60 / 90 (montants)', string_agg(valeur::text, '/' ORDER BY ordre), '50000/50000/20000/20000')
  FROM (SELECT valeur, CASE rubrique WHEN 'par_1_jour' THEN 1 WHEN 'par_30_jours' THEN 2 WHEN 'par_60_jours' THEN 3 ELSE 4 END ordre
          FROM rapport_portefeuille(1::smallint,'2026-11-05') WHERE rubrique IN ('par_1_jour','par_30_jours','par_60_jours','par_90_jours')) x;
SELECT t.eq('P PAR 30 jours en %', valeur::text, '71.43') FROM rapport_portefeuille(1::smallint,'2026-11-05') WHERE rubrique = 'par_30_jours_pct';
SELECT t.eq('P PAR 90 jours en %', valeur::text, '28.57') FROM rapport_portefeuille(1::smallint,'2026-11-05') WHERE rubrique = 'par_90_jours_pct';
SELECT t.eq('P impayé total', valeur::text, '40800') FROM rapport_portefeuille(1::smallint,'2026-11-05') WHERE rubrique = 'impaye_capital_interets';
SELECT t.eq('P reproductibilité : au 10/10, E est encore actif et D pas encore débloqué', string_agg(numero, ',' ORDER BY numero), 'CR-A,CR-B,CR-C,CR-E') FROM portefeuille_a_date(1::smallint,'2026-10-10');
SELECT t.eq('P encours au 10/10 (30000 + 20000 + 20000 + 10000)', sum(capital_restant)::text, '80000') FROM portefeuille_a_date(1::smallint,'2026-10-10');
SELECT t.eq('P agence sans crédit : zéros et pas de pourcentage', coalesce(valeur::text, 'NULL'), 'NULL') FROM rapport_portefeuille(2::smallint,'2026-11-05') WHERE rubrique = 'par_30_jours_pct';

-- ===== T. Retard par tranche, répartition =====
SELECT t.eq('T tranches (nb:capital:retard)', string_agg(nb_credits::text || ':' || capital_restant::text || ':' || montant_en_retard::text, ' ' ORDER BY ordre),
            '2:20000:0 0:0:0 1:30000:20500 0:0:0 1:20000:20300 0:0:0') FROM rapport_retard_par_tranche(1::smallint,'2026-11-05');
SELECT t.eq('T répartition par type', cle || '/' || nb_credits::text || '/' || encours::text || '/' || encours_en_retard::text, 'sans_epargne/4/70000/50000') FROM portefeuille_repartition(1::smallint,'2026-11-05','type');
SELECT t.eq('T répartition par mode', cle || '/' || nb_credits::text, 'especes/4') FROM portefeuille_repartition(1::smallint,'2026-11-05','mode');
SELECT t.refuse('T critère inconnu', 'SELECT * FROM mf.portefeuille_repartition(1::smallint, current_date, ''couleur'')');

-- ===== U. Activité d'une période =====
SELECT t.eq('U crédits débloqués en octobre', (SELECT valeur::text FROM rapport_credits_periode(1::smallint,'2026-10-01','2026-10-31') WHERE rubrique='credits_debloques_nb') || '/' ||
                                              (SELECT valeur::text FROM rapport_credits_periode(1::smallint,'2026-10-01','2026-10-31') WHERE rubrique='credits_debloques_montant'), '1/10000');
SELECT t.eq('U remboursements capital / intérêts', (SELECT valeur::text FROM rapport_credits_periode(1::smallint,'2026-10-01','2026-10-31') WHERE rubrique='remboursements_capital') || '/' ||
                                                   (SELECT valeur::text FROM rapport_credits_periode(1::smallint,'2026-10-01','2026-10-31') WHERE rubrique='remboursements_interets'), '30000/600');
SELECT t.eq('U remboursements par origine (especes 20400 / prélèvement 10200)', (SELECT valeur::text FROM rapport_credits_periode(1::smallint,'2026-10-01','2026-10-31') WHERE rubrique='remboursements_en_especes') || '/' ||
                                                   (SELECT valeur::text FROM rapport_credits_periode(1::smallint,'2026-10-01','2026-10-31') WHERE rubrique='remboursements_par_prelevement'), '20400/10200');
SELECT t.eq('U crédits soldés', valeur::text, '1') FROM rapport_credits_periode(1::smallint,'2026-10-01','2026-10-31') WHERE rubrique = 'credits_soldes';
SELECT t.eq('U échéances attendues en octobre (A, B, E)', valeur::text, '51100') FROM rapport_credits_periode(1::smallint,'2026-10-01','2026-10-31') WHERE rubrique = 'echeances_attendues';
SELECT t.eq('U échéances recouvrées à fin octobre', valeur::text, '30600') FROM rapport_credits_periode(1::smallint,'2026-10-01','2026-10-31') WHERE rubrique = 'echeances_recouvrees';
SELECT t.eq('U taux de recouvrement', valeur::text, '59.9') FROM rapport_credits_periode(1::smallint,'2026-10-01','2026-10-31') WHERE rubrique = 'taux_recouvrement_pct';

-- ===== F. Rapport financier opérationnel (octobre 2026) =====
-- mise de tontine : un cycle clôturé et retiré le 20/10
INSERT INTO cycle(agence_id,numero,client_id,produit_id,type_cycle,mise_initiale,mise_courante,objectif,date_debut,date_fin) VALUES (1,'CY1',1,1,1,1000,1000,31000,'2026-10-01','2026-10-31');
INSERT INTO ligne_collecte(cycle_id,page,no_ligne,date_collecte,agent_id,montant_collecte) SELECT 1,1,g,'2026-10-01'::date+g-1,1,1000 FROM generate_series(1,5) g;
SELECT demander_retrait_cycle(1,'retrait_client','2026-10-20');
SELECT constater_sans_ecart((SELECT id FROM retrait WHERE cycle_id = 1));
SELECT executer_retrait((SELECT id FROM retrait WHERE cycle_id = 1), '2026-10-20');
-- manquant de caisse de 100
INSERT INTO caisse(agence_id,code,type) VALUES (1,'CP','principale');
SELECT ouvrir_session_caisse(1, '2026-10-10', 1000);
SELECT fermer_session_caisse((SELECT id FROM session_caisse), 900);
-- frais bancaires 5000 (après un dépôt externe)
INSERT INTO compte_banque(agence_id,code,libelle) VALUES (1,'BQ','Banque');
INSERT INTO mouvement_banque(compte_banque_id,date_operation,type,montant) VALUES (1,'2026-10-02','depot_externe',20000),(1,'2026-10-25','frais',5000);
-- salaire 100000 validé, commission brute 60
INSERT INTO employe(agence_id,matricule,nom,date_embauche) VALUES (1,'E1','Salarié','2026-01-01');
INSERT INTO contrat(employe_id,type,date_debut,salaire_base) VALUES (1,'cdi','2026-01-01',100000);
SELECT valider_bulletin(generer_bulletin(1,'2026-10-01'));
INSERT INTO commission_collectrice(agence_id,collectrice_id,periode_debut,periode_fin,production,taux,commission_brute,commission_nette) VALUES (1,1,'2026-10-01','2026-10-31',3000,0.02,60,60);

SELECT t.eq('F produits par rubrique', string_agg(rubrique || '=' || valeur::text, ' ' ORDER BY rubrique), 'excedents_caisse=0 frais_dossier=0 interets_bancaires=0 interets_credits=600 mises_tontine=1000 penalites=0')
  FROM rapport_financier(1::smallint,'2026-10-01','2026-10-31') WHERE section = 'produit';
SELECT t.eq('F charges par rubrique', string_agg(rubrique || '=' || valeur::text, ' ' ORDER BY rubrique), 'charges_patronales=0 commissions_collectrices=60 frais_bancaires=5000 manquants_caisse=100 salaires=100000')
  FROM rapport_financier(1::smallint,'2026-10-01','2026-10-31') WHERE section = 'charge';
SELECT t.eq('F résultat = 1600 - 105160', valeur::text, '-103560') FROM rapport_financier(1::smallint,'2026-10-01','2026-10-31') WHERE rubrique = 'resultat';
SELECT t.eq('F encours en fin de période', valeur::text, '70000') FROM rapport_financier(1::smallint,'2026-10-01','2026-10-31') WHERE rubrique = 'encours_credits';
SELECT t.eq('F période sans activité : résultat nul', valeur::text, '0') FROM rapport_financier(1::smallint,'2025-01-01','2025-01-31') WHERE rubrique = 'resultat';
SELECT t.eq('F l''autre agence ne voit rien', valeur::text, '0') FROM rapport_financier(2::smallint,'2026-10-01','2026-10-31') WHERE rubrique = 'total_produits';

-- ===== B. Bilan simplifié issu de la comptabilité =====
INSERT INTO exercice_comptable(code,date_debut,date_fin) VALUES ('2026','2026-01-01','2026-12-31');
CREATE FUNCTION pg_temp.piece(p_libelle text, p_debit text, p_credit text, p_montant numeric) RETURNS void LANGUAGE plpgsql AS $$
DECLARE v bigint;
BEGIN
  INSERT INTO mf.piece_comptable(agence_id,journal_id,exercice_id,date_piece,numero,libelle,origine)
  VALUES (1,(SELECT id FROM mf.journal WHERE code='OD'),(SELECT id FROM mf.exercice_comptable LIMIT 1),'2026-10-05',mf.prochain_numero('piece',1::smallint,'2026-10-05','PC'),p_libelle,'manuelle') RETURNING id INTO v;
  INSERT INTO mf.ecriture(piece_id,ligne,compte_code,debit,credit) VALUES (v,1,p_debit,p_montant,0),(v,2,p_credit,0,p_montant);
END $$;
SELECT pg_temp.piece('Dépôts clients','1011','25111',100000);
SELECT pg_temp.piece('Crédit débloqué','202211','1011',30000);
SELECT pg_temp.piece('Loyer','6212','1011',5000);
SELECT pg_temp.piece('Intérêts perçus','1011','70212',2000);
SELECT t.eq('B actif = passif', (SELECT sum(montant) FILTER (WHERE cote='actif') FROM bilan_simplifie(1::smallint,'2026-12-31'))::text || '=' ||
                                (SELECT sum(montant) FILTER (WHERE cote='passif') FROM bilan_simplifie(1::smallint,'2026-12-31'))::text, '100000=100000');
SELECT t.eq('B actif : caisse 67000, crédits 30000, résultat négatif 3000', string_agg(code || ':' || montant::text, ' ' ORDER BY code), '10:67000 20:30000 RES:3000')
  FROM bilan_simplifie(1::smallint,'2026-12-31') WHERE cote = 'actif';
SELECT t.eq('B passif : dépôts de la clientèle', string_agg(code || ':' || montant::text, ' '), '25:100000') FROM bilan_simplifie(1::smallint,'2026-12-31') WHERE cote = 'passif';
SELECT t.eq('B toutes agences confondues', sum(montant)::text, '200000') FROM bilan_simplifie(NULL,'2026-12-31');
SELECT t.eq('B avant toute écriture', count(*)::text, '0') FROM bilan_simplifie(1::smallint,'2026-01-01');
