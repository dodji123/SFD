SET search_path = mf, public;

-- Module sous test : 22_rapprochement.sql (rapprochement fiches / comptabilité, validation par le comptable)
INSERT INTO agence(code,libelle) VALUES ('LOM','Lomé Centre'),('KPA','Kpalimé');
INSERT INTO utilisateur(agence_id,login,nom,role) VALUES (1,'compta','Comptable','comptable');
INSERT INTO exercice_comptable(code,date_debut,date_fin) VALUES ('2025','2025-01-01','2025-12-31');
INSERT INTO produit_epargne(code,libelle,categorie) VALUES ('CL','Compte classique','classique');
INSERT INTO client(agence_id,numero,nom) VALUES (1,'C1','Sain'),(1,'C2','Retard 150 j'),(1,'C3','Épargnant');
CREATE FUNCTION pg_temp.ac(p text) RETURNS text LANGUAGE sql AS $$ SELECT min(code) FROM mf.compte_comptable WHERE code LIKE p || '%' AND imputable $$;
CREATE FUNCTION pg_temp.piece(p_agence smallint, p_date date, p_debit text, p_credit text, p_montant numeric) RETURNS void LANGUAGE plpgsql AS $$
DECLARE v bigint;
BEGIN
  INSERT INTO mf.piece_comptable(agence_id,journal_id,exercice_id,date_piece,numero,libelle,origine)
  VALUES (p_agence,(SELECT id FROM mf.journal WHERE code='OD'),(SELECT id FROM mf.exercice_comptable LIMIT 1),p_date,
          mf.prochain_numero('piece',p_agence,p_date,'PC'),'test','manuelle') RETURNING id INTO v;
  INSERT INTO mf.ecriture(piece_id,ligne,compte_code,debit,credit) VALUES (v,1,p_debit,p_montant,0),(v,2,p_credit,0,p_montant);
END $$;
CREATE FUNCTION pg_temp.r(p_code text) RETURNS TABLE (inventaire numeric, comptabilite numeric, ecart numeric, conforme boolean) LANGUAGE sql AS $$
  SELECT r.inventaire, r.comptabilite, r.ecart, r.conforme FROM mf.rapprochement(1::smallint, DATE '2025-12-31') r WHERE r.code = p_code $$;

-- Deux crédits de 100000 (un sain, un en retard de 150 jours) et 40000 d'épargne (dépôt 50000, retrait 10000)
INSERT INTO credit(agence_id,numero,client_id,type,montant_accorde,taux,date_deblocage,nb_echeances,mode_remboursement) VALUES
  (1,'CR-1',1,'sans_epargne',100000,0.12,DATE '2025-12-31' - 30,12,'especes'),
  (1,'CR-2',2,'sans_epargne',100000,0.12,DATE '2025-12-31' - 180,12,'especes');
SELECT generer_echeancier(id) FROM credit ORDER BY id;
INSERT INTO compte_epargne(agence_id,client_id,produit_id,numero) VALUES (1,3,1,'CE-3');
INSERT INTO mouvement_epargne(compte_id,type,montant,date_operation) VALUES (1,'depot',50000,'2025-12-20'),(1,'retrait',10000,'2025-12-28'),(1,'depot',700,'2026-01-05');

-- ===== A. Comptabilité vide : tous les écarts apparaissent =====
SELECT t.eq('A crédits sains : fiches 100000, comptabilité 0', inventaire || '/' || comptabilite || '/' || ecart || '/' || conforme, '100000/0/100000/false') FROM pg_temp.r('credits_sains');
SELECT t.eq('A crédits en souffrance : 100000 / 0', inventaire || '/' || comptabilite || '/' || conforme, '100000/0/false') FROM pg_temp.r('credits_souffrance');
SELECT t.eq('A provisions : 40000 / 0', inventaire || '/' || comptabilite || '/' || conforme, '40000/0/false') FROM pg_temp.r('provisions');
SELECT t.eq('A épargne : 40000 à la date (le dépôt de janvier est exclu)', inventaire || '/' || comptabilite || '/' || conforme, '40000/0/false') FROM pg_temp.r('epargne');
SELECT t.eq('A quatre rubriques rapprochées', count(*)::text, '4') FROM rapprochement(1::smallint,'2025-12-31');

-- ===== B. Validation : une justification est obligatoire en cas d'écart =====
SELECT t.refuse('B validation sans justification malgré l''écart', 'SELECT mf.valider_rapprochement(1::smallint, ''2025-12-31'', 1)');
SELECT t.refuse('B justification vide', 'SELECT mf.valider_rapprochement(1::smallint, ''2025-12-31'', 1, ''   '')');
SELECT t.eq('B validation avec justification', (valider_rapprochement(1::smallint, '2025-12-31', 1, 'comptabilisation automatique non activée : écritures à passer') IS NOT NULL)::text, 'true');
SELECT t.eq('B statut et écart total enregistrés', statut || ' ' || ecart_total, 'ecart_justifie 280000') FROM rapprochement_validation ORDER BY id DESC LIMIT 1;

-- ===== C. Après les écritures, plus aucun écart =====
SELECT pg_temp.piece(1::smallint,'2025-12-01', pg_temp.ac('20221'), pg_temp.ac('1011'), 100000);   -- crédit sain
SELECT pg_temp.piece(1::smallint,'2025-12-01', pg_temp.ac('2922'),  pg_temp.ac('1011'), 100000);   -- crédit déclassé
SELECT pg_temp.piece(1::smallint,'2025-12-20', pg_temp.ac('1011'),  pg_temp.ac('25111'), 40000);   -- épargne
SELECT t.eq('C provisions passées par le module Provisions', (generer_provisions(1::smallint,'2025-12-31', 1) IS NOT NULL)::text, 'true');
SELECT t.eq('C tous les écarts sont nuls', string_agg(code || ':' || ecart || ':' || conforme, ' ' ORDER BY code), 'credits_sains:0:true credits_souffrance:0:true epargne:0:true provisions:0:true') FROM rapprochement(1::smallint,'2025-12-31');
SELECT t.eq('C validation conforme sans justification', (valider_rapprochement(1::smallint, '2025-12-31', 1) IS NOT NULL)::text, 'true');
SELECT t.eq('C statut conforme, écart total nul', statut || ' ' || ecart_total, 'conforme 0') FROM rapprochement_validation ORDER BY id DESC LIMIT 1;

-- ===== D. Tolérance paramétrable =====
INSERT INTO mouvement_epargne(compte_id,type,montant,date_operation) VALUES (1,'depot',300,'2025-12-29');
SELECT t.eq('D écart de 300 sur l''épargne : signalé avec la tolérance nulle', ecart || ' ' || conforme, '300 false') FROM pg_temp.r('epargne');
UPDATE parametre SET valeur = '500' WHERE cle = 'rapprochement_tolerance' AND agence_id IS NULL;
SELECT t.eq('D même écart sous une tolérance de 500 : accepté', ecart || ' ' || conforme, '300 true') FROM pg_temp.r('epargne');
UPDATE parametre SET valeur = '0' WHERE cle = 'rapprochement_tolerance' AND agence_id IS NULL;

-- ===== E. État par agence avant consolidation =====
SELECT t.eq('E agence 1 validée, agence 2 non validée', string_agg(agence || ':' || validee, ' ' ORDER BY agence), 'KPA:false LOM:true') FROM etat_rapprochement_agences('2025-12-31');
SELECT t.eq('E la dernière validation du jour fait foi (conforme)', statut, 'conforme') FROM etat_rapprochement_agences('2025-12-31') WHERE agence = 'LOM';
SELECT t.eq('E aucune validation à une autre date', count(*) FILTER (WHERE validee)::text, '0') FROM etat_rapprochement_agences('2025-11-30');

-- ===== F. Garde-fous =====
SELECT t.refuse('F agence obligatoire', 'SELECT mf.valider_rapprochement(NULL, ''2025-12-31'', 1)');
SELECT t.refuse('F date d''arrêté dans le futur', format('SELECT mf.valider_rapprochement(1::smallint, %L, 1)', (current_date + 1)::text));
SELECT t.refuse('F validation non modifiable', 'UPDATE mf.rapprochement_validation SET statut = ''conforme''');
SELECT t.refuse('F validation non supprimable', 'DELETE FROM mf.rapprochement_validation');
SELECT t.refuse('F écart justifié sans justification refusé par la base', 'INSERT INTO mf.rapprochement_validation(agence_id,date_arrete,statut,ecart_total) VALUES (1,''2025-12-31'',''ecart_justifie'',5)');
SELECT t.eq('F validations tracées dans l''audit', (count(*) >= 2)::text, 'true') FROM audit_log WHERE table_name = 'rapprochement_validation';
