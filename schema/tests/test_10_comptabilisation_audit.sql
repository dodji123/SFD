SET search_path = mf, public;

-- solde d'un compte (débit - crédit) pour l'agence 1 sur 2026
CREATE OR REPLACE FUNCTION t.sd(p_compte text) RETURNS text LANGUAGE sql AS $$
  SELECT COALESCE((SELECT (solde_debiteur - solde_crediteur)::text FROM mf.balance(1::smallint,'2026-01-01','2026-12-31') WHERE compte = p_compte), '0') $$;

-- ===== Données de base =====
INSERT INTO agence(code,libelle) VALUES ('LOM','Lomé Centre'),('KPA','Kpalimé');
INSERT INTO zone(agence_id,code,libelle) VALUES (1,'Z1','Zone Marché');
INSERT INTO agent(agence_id,matricule,nom) VALUES (1,'A01','Ama');
INSERT INTO client(agence_id,zone_id,numero,nom) VALUES (1,1,'C001','Un'),(1,1,'C002','Deux'),(2,NULL,'C101','Kpalimé');
INSERT INTO produit_epargne(code,libelle,categorie,type_cycle,nb_pages_livret) VALUES ('P1','Tontine','collecte',1,1);
INSERT INTO produit_epargne(code,libelle,categorie,taux_interet,solde_minimum) VALUES ('CL','Compte classique',  'classique',0.02,5000);
INSERT INTO compte_epargne(agence_id,client_id,produit_id,numero) VALUES (1,1,2,'CE001'),(1,2,2,'CE002'),(2,3,2,'CE101');
INSERT INTO produit_credit_epargne(code,libelle,type,taux_annuel,frais_dossier_taux,periodicite_jours,methode) VALUES
  ('PCE1','Crédit sur épargne','sur_epargne',0.12,0.01,30,'capital_constant'),
  ('PCS1','Crédit sans épargne','sans_epargne',0.12,0,30,'capital_constant');
INSERT INTO exercice_comptable(code,date_debut,date_fin) VALUES ('2026','2026-01-01','2026-12-31');

-- ===== A. Désactivée par défaut, activable par agence =====
INSERT INTO mouvement_epargne(compte_id,type,montant,date_operation) VALUES (1,'depot',1000,'2026-09-01');
SELECT t.eq('A rien n''est comptabilisé tant que le paramètre est à « non »', count(*)::text, '0') FROM piece_comptable;
INSERT INTO parametre(agence_id,cle,valeur) VALUES (1,'comptabilisation_auto','oui');
INSERT INTO mouvement_epargne(compte_id,type,montant,date_operation) VALUES (3,'depot',7000,'2026-09-02');   -- agence 2, toujours « non »
SELECT t.eq('A agence 2 non concernée', count(*)::text, '0') FROM piece_comptable;
-- on repart d'un compte vide pour des soldes lisibles
INSERT INTO mouvement_epargne(compte_id,type,montant,date_operation) VALUES (1,'depot',99000,'2026-10-01');   -- solde 100000 au total
SELECT t.eq('A dépôt agence 1 comptabilisé', count(*)::text, '1') FROM piece_comptable;
SELECT t.eq('A pièce du journal de caisse, débit 1011 / crédit 25111', (t.sd('1011') = '99000' AND t.sd('25111') = '-99000')::text, 'true');

-- ===== B. Tournées : cash versé, manquant, surplus =====
INSERT INTO cycle(agence_id,numero,client_id,produit_id,type_cycle,mise_initiale,mise_courante,objectif,date_debut,date_fin)
VALUES (1,'CYA',1,1,1,1000,1000,31000,'2026-10-01','2026-10-31');
INSERT INTO ligne_collecte(cycle_id,page,no_ligne,date_collecte,agent_id,montant_collecte)
SELECT (SELECT id FROM cycle WHERE numero='CYA'),1,g,'2026-10-01'::date+g-1,1,1000 FROM generate_series(1,5) g;
SELECT enregistrer_versement(1,'2026-10-01',1000);
SELECT enregistrer_versement(1,'2026-10-02',800);     -- manquant 200
SELECT enregistrer_versement(1,'2026-10-03',1300);    -- surplus 300
SELECT enregistrer_versement(1,'2026-10-04',1000);
SELECT enregistrer_versement(1,'2026-10-05',1000);
SELECT t.eq('B tontine créditée de la collecte (5 x 1000)', t.sd('25391'), '-5000');
SELECT t.eq('B manquant : créance sur l''agent', t.sd('3316'), '200');
SELECT t.eq('B surplus : dette envers l''agent', t.sd('3327'), '-300');
SELECT t.eq('B espèces reçues = 5100', (SELECT (t.sd('1011')::numeric - 99000)::text), '5100');

-- ===== C. Retrait client avec écart livret > machine : surplus de la date d'abord, puis perte =====
SELECT demander_retrait_cycle((SELECT id FROM cycle WHERE numero='CYA'),'retrait_client','2026-10-10');
SELECT enregistrer_ecart_retrait((SELECT id FROM retrait WHERE nature='retrait_client'), 5500, 5000,
  jsonb_build_array(jsonb_build_object('date','2026-10-03','montant',500,'agent_id',1)));
SELECT traiter_ecart_retrait((SELECT id FROM ecart_retrait));
SELECT executer_retrait((SELECT id FROM retrait WHERE nature='retrait_client'));
SELECT t.eq('C liabilité de la tontine soldée', t.sd('25391'), '0');
SELECT t.eq('C créance sur l''agent = manquant 200 + perte 200', t.sd('3316'), '400');
SELECT t.eq('C surplus consommé', t.sd('3327'), '0');
SELECT t.eq('C mise = commission de l''institution', t.sd('70293'), '-1000');
SELECT t.eq('C espèces : 5100 reçus - 4500 payés', (SELECT (t.sd('1011')::numeric - 99000)::text), '600');

-- ===== D. Compte agent : retenue sur commission puis règlement =====
SELECT t.eq('D retenue plafonnée à 50 % de 600', retenue_sur_commission(1, 600, '2026-10-31')::text, '300');
SELECT regler_compte_agent(1, 100, '2026-11-02');
SELECT t.eq('D créance sur l''agent soldée', t.sd('3316'), '0');
SELECT t.eq('D charge de commission', t.sd('641'), '300');

-- ===== E. Crédit sur épargne avec prélèvement =====
SELECT nouvelle_demande_credit(1,1,1,30000,3,NULL,20000,'prelevement_compte');
SELECT approuver_demande(1,NULL,true);
SELECT debloquer_credit(1,'2026-11-01','compte');
SELECT prelever_echeances_compte(1::smallint,'2026-12-01');
SELECT t.eq('E crédits', t.sd('202211'), '20000');
SELECT t.eq('E intérêts', t.sd('70212'), '-300');
SELECT t.eq('E commissions : mise 1000 + frais de dossier 300', t.sd('70293'), '-1300');

-- ===== F. Crédit en espèces, remboursement, écart de caisse =====
INSERT INTO caisse(agence_id,code,type) VALUES (1,'CP','principale');
INSERT INTO session_caisse(caisse_id,date_session,solde_ouverture) VALUES (1,'2026-11-05',1000000);
SELECT nouvelle_demande_credit(2,2,2,10000,2,0.12,0,'especes');
SELECT approuver_demande(2,NULL,true);
SELECT debloquer_credit(2,'2026-11-05','especes',1);
SELECT rembourser_echeance_especes((SELECT id FROM echeance WHERE credit_id = (SELECT id FROM credit WHERE type='sans_epargne') AND no_echeance=1), 5100, 1, '2026-12-05');
SELECT t.eq('F écart de caisse à la fermeture', fermer_session_caisse(1, 995000)::text, '-100');   -- théorique : 1000000 - 10000 + 5100 = 995100
SELECT t.eq('F perte sur écart de caisse', t.sd('6716'), '100');
SELECT t.eq('F crédits en cours', t.sd('202211'), '25000');
SELECT t.eq('F intérêts', t.sd('70212'), '-400');

-- ===== G. Paie =====
INSERT INTO employe(agence_id,matricule,nom,date_embauche) VALUES (1,'E1','Salarié','2026-01-01');
INSERT INTO contrat(employe_id,type,date_debut,salaire_base) VALUES (1,'cdi','2026-01-01',100000);
INSERT INTO rubrique_paie(code,libelle,type,mode,valeur,base) VALUES ('COT','Cotisation','retenue_salariale','pourcentage',0.04,'brut');
SELECT generer_bulletin(1,'2026-10-01');
SELECT valider_bulletin((SELECT id FROM bulletin_paie));
SELECT t.eq('G net à payer', t.sd('3322'), '-96000');
SELECT t.eq('G retenues salariales', t.sd('3323'), '-4000');
SELECT t.eq('G charge de personnel (100000 + 300 de commission retenue)', t.sd('641'), '100300');

-- ===== H. Cohérence d'ensemble =====
SELECT t.eq('H balance équilibrée', sum(debit)::text || '=' || sum(credit)::text, (SELECT sum(debit)::text || '=' || sum(credit)::text FROM balance(1::smallint,'2026-01-01','2026-12-31')))
  FROM balance(1::smallint,'2026-01-01','2026-12-31');
SELECT t.eq('H débit = crédit', (sum(debit) = sum(credit))::text, 'true') FROM balance(1::smallint,'2026-01-01','2026-12-31');
-- le dépôt de 1000 du 01/09 a été saisi avant l'activation (test A) : il n'est volontairement pas comptabilisé
SELECT t.eq('H le compte 25111 égale la somme des soldes d''épargne (hors dépôt non comptabilisé de 1000)',
            (-t.sd('25111')::numeric)::text, (SELECT (sum(solde) - 1000)::text FROM v_solde_compte_epargne WHERE agence_id = 1));
-- 99000 dépôt + 5100 versements - 4500 retrait + 100 règlement agent - 10000 crédit + 5100 remboursement - 100 écart de caisse
SELECT t.eq('H espèces : solde du compte 1011', t.sd('1011'), '94700');
SELECT t.eq('H aucune pièce pour l''agence 2', count(*)::text, '0') FROM piece_comptable WHERE agence_id = 2;
SELECT t.refuse('H une opération ne se comptabilise qu''une fois',
  'SELECT mf.comptabiliser(''epargne_depot'',1::smallint,''2026-10-01'',''{"montant":1}'',''mouvement_epargne'',(SELECT min(id) FROM mf.mouvement_epargne WHERE compte_id = 1 AND montant = 99000))');

-- ===== I. Piste d'audit =====
SELECT t.eq('I retraits audités', (count(*) > 0)::text, 'true') FROM audit_log WHERE table_name = 'retrait' AND operation = 'UPDATE';
SELECT t.eq('I crédits audités', (count(*) > 0)::text, 'true') FROM audit_log WHERE table_name = 'credit' AND operation = 'INSERT';
SELECT t.eq('I compte agent audité', (count(*) >= 3)::text, 'true') FROM audit_log WHERE table_name = 'compte_agent';
SET mf.utilisateur = 'caissier1';
UPDATE parametre SET valeur = '0.03' WHERE cle = 'taux_commission' AND agence_id IS NULL;
RESET mf.utilisateur;
SELECT t.eq('I utilisateur et valeurs avant / après', utilisateur || ':' || (avant->>'valeur') || '->' || (apres->>'valeur'), 'caissier1:0.02->0.03')
  FROM audit_log WHERE table_name = 'parametre' AND operation = 'UPDATE' ORDER BY id DESC LIMIT 1;
