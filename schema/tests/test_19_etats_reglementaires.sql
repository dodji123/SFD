SET search_path = mf, public;

-- Module sous test : 19_etats_reglementaires.sql + 19_postes_data.sql (postes des états financiers et concordance avec le plan)
INSERT INTO agence(code,libelle) VALUES ('LOM','Lomé Centre'),('KPA','Kpalimé');
INSERT INTO exercice_comptable(code,date_debut,date_fin) VALUES ('2026','2026-01-01','2026-12-31');
CREATE FUNCTION pg_temp.ac(p text) RETURNS text LANGUAGE sql AS $$ SELECT min(code) FROM mf.compte_comptable WHERE code LIKE p || '%' AND imputable $$;
CREATE FUNCTION pg_temp.piece(p_agence smallint, p_date date, p_debit text, p_credit text, p_montant numeric) RETURNS void LANGUAGE plpgsql AS $$
DECLARE v bigint;
BEGIN
  INSERT INTO mf.piece_comptable(agence_id,journal_id,exercice_id,date_piece,numero,libelle,origine)
  VALUES (p_agence,(SELECT id FROM mf.journal WHERE code='OD'),(SELECT id FROM mf.exercice_comptable LIMIT 1),p_date,
          mf.prochain_numero('piece',p_agence,p_date,'PC'),'test','manuelle') RETURNING id INTO v;
  INSERT INTO mf.ecriture(piece_id,ligne,compte_code,debit,credit) VALUES (v,1,p_debit,p_montant,0),(v,2,p_credit,0,p_montant);
END $$;

-- ===== A. Nomenclature chargée =====
SELECT t.eq('A postes chargés', (count(*) > 400)::text, 'true') FROM poste_etat;
SELECT t.eq('A tous les postes nécessaires aux ratios existent', count(*)::text, '71')
  FROM poste_etat WHERE code IN ('A10','A2H','A2I','A2J','A3A','A3B','A3C','A70','A60','B2D','B30','B40','B65','B70','C10','C30','C40','C55','C56','D60','D1E','D1L','D10','D1S',
       'D23','D30','D40','D24','D31','D41','D46','E05','F1A','F2A','F2D','F3E','F3F','F50','G10','G15','G2A','G30','G35','G60','G70','H10','H40','L01','L10','L20','L30','L41','L45',
       'L50','L55','L56','L59','L60','L62','L65','L70','L75','L80','N1A','N1J','N3A','Q1A','T84','X84','B01','G01');
SELECT t.eq('A aucun préfixe orphelin (poste inconnu)', count(*)::text, '0') FROM poste_compte pc LEFT JOIN poste_etat e ON e.code = pc.poste_code WHERE e.code IS NULL;
SELECT t.eq('A chaque préfixe correspond à au moins un compte du plan (ou à un parent)', count(*)::text, '0')
  FROM poste_compte pc WHERE NOT EXISTS (SELECT 1 FROM compte_comptable c WHERE c.code LIKE pc.prefixe || '%');
SELECT t.eq('A concordance : caisse = compte 10', string_agg(prefixe, ','), '10') FROM poste_compte WHERE poste_code = 'A10';
SELECT t.eq('A concordance : capital = 5711, 5712', string_agg(prefixe, ',' ORDER BY prefixe), '5711,5712') FROM poste_compte WHERE poste_code = 'L60';

-- ===== B. Écritures de l'agence 1 : capital, dépôts, crédit, intérêts ; loyer en novembre =====
SELECT pg_temp.piece(1::smallint,'2026-10-05', pg_temp.ac('1011'),  pg_temp.ac('5711'),  100000);   -- capital
SELECT pg_temp.piece(1::smallint,'2026-10-05', pg_temp.ac('1011'),  pg_temp.ac('25111'),  50000);   -- dépôts à vue
SELECT pg_temp.piece(1::smallint,'2026-10-05', pg_temp.ac('20221'), pg_temp.ac('1011'),   30000);   -- crédit à court terme
SELECT pg_temp.piece(1::smallint,'2026-10-05', pg_temp.ac('1011'),  pg_temp.ac('70212'),    3000);   -- intérêts
SELECT pg_temp.piece(1::smallint,'2026-11-10', pg_temp.ac('6212'),  pg_temp.ac('1011'),     1000);   -- loyer
-- Agence 2 : un compte « ex » débiteur (découvert d'un client)
SELECT pg_temp.piece(2::smallint,'2026-10-06', pg_temp.ac('25111'), pg_temp.ac('1011'),      700);

SELECT t.eq('B caisse (A10) au 31/10', montant::text, '123000') FROM valeurs_postes(1::smallint,'2026-10-31','2026-10-31') WHERE code = 'A10';
SELECT t.eq('B crédits à court terme (B2D)', montant::text, '30000') FROM valeurs_postes(1::smallint,'2026-10-31','2026-10-31') WHERE code = 'B2D';
SELECT t.eq('B comptes ordinaires créditeurs (G10)', montant::text, '50000') FROM valeurs_postes(1::smallint,'2026-10-31','2026-10-31') WHERE code = 'G10';
SELECT t.eq('B capital (L60) et fonds propres (L01)', string_agg(code || ':' || montant, ' ' ORDER BY code), 'L01:100000 L60:100000') FROM valeurs_postes(1::smallint,'2026-10-31','2026-10-31') WHERE code IN ('L60','L01');
SELECT t.eq('B excédent des produits (L75) au 31/10, pas de déficit', (SELECT montant FROM valeurs_postes(1::smallint,'2026-10-31','2026-10-31') WHERE code = 'L75')::text || '/' ||
            (SELECT montant FROM valeurs_postes(1::smallint,'2026-10-31','2026-10-31') WHERE code = 'E05')::text, '3000/0');
SELECT t.eq('B après le loyer (30/11) : excédent réduit', montant::text, '2000') FROM valeurs_postes(1::smallint,'2026-11-30','2026-11-30') WHERE code = 'L75';
SELECT t.eq('B caisse au 30/11', montant::text, '122000') FROM valeurs_postes(1::smallint,'2026-11-30','2026-11-30') WHERE code = 'A10';

-- ===== C. Bilan réglementaire : totaux et équilibre =====
SELECT t.eq('C total actif = total passif au 31/10', (SELECT montant FROM etat_bilan_reglementaire(1::smallint,'2026-10-31') WHERE code = 'E90')::text || '=' ||
            (SELECT montant FROM etat_bilan_reglementaire(1::smallint,'2026-10-31') WHERE code = 'L90')::text, '153000=153000');
SELECT t.eq('C total actif = total passif au 30/11', (SELECT montant FROM etat_bilan_reglementaire(1::smallint,'2026-11-30') WHERE code = 'E90')::text || '=' ||
            (SELECT montant FROM etat_bilan_reglementaire(1::smallint,'2026-11-30') WHERE code = 'L90')::text, '152000=152000');
SELECT t.eq('C aucune écriture : bilan vide', count(*)::text, '2') FROM etat_bilan_reglementaire(1::smallint,'2026-01-01');   -- seuls E90 et L90 (à zéro)

-- ===== D. Compte « ex » et consolidation =====
SELECT t.eq('D découvert d''un client : à l''actif (B2N), pas au passif (G10)', (SELECT montant FROM valeurs_postes(2::smallint,'2026-10-31','2026-10-31') WHERE code = 'B2N')::text || '/' ||
            (SELECT montant FROM valeurs_postes(2::smallint,'2026-10-31','2026-10-31') WHERE code = 'G10')::text, '700/0');
SELECT t.eq('D agence 2 : bilan équilibré', (SELECT montant FROM etat_bilan_reglementaire(2::smallint,'2026-10-31') WHERE code = 'E90')::text || '=' ||
            (SELECT montant FROM etat_bilan_reglementaire(2::smallint,'2026-10-31') WHERE code = 'L90')::text, '0=0');
SELECT t.eq('D consolidé : la caisse est la somme des agences', montant::text, '122300') FROM valeurs_postes(NULL,'2026-10-31','2026-10-31') WHERE code = 'A10';
-- en consolidé, un compte « ex » est unique pour tout le réseau : le découvert de 700 vient en déduction des 50000 de dépôts (G10 = 49300)
SELECT t.eq('D consolidé : total actif = total passif', (SELECT montant FROM etat_bilan_reglementaire(NULL,'2026-10-31') WHERE code = 'E90')::text || '=' ||
            (SELECT montant FROM etat_bilan_reglementaire(NULL,'2026-10-31') WHERE code = 'L90')::text, '152300=152300');
SELECT t.eq('D consolidé : les comptes « ex » sont compensés entre agences', (SELECT montant FROM valeurs_postes(NULL,'2026-10-31','2026-10-31') WHERE code = 'G10')::text || '/' ||
            (SELECT montant FROM valeurs_postes(NULL,'2026-10-31','2026-10-31') WHERE code = 'B2N')::text, '49300/0');

-- ===== E. Compte de résultat par période (les postes de total X84 et T84 regroupent les produits et les charges) =====
SELECT t.eq('E octobre : produits d''intérêts (V3G) et total des produits (X84)', string_agg(code || ':' || montant, ' ' ORDER BY code), 'V3G:3000 X84:3000')
  FROM etat_resultat_reglementaire(1::smallint,'2026-10-01','2026-10-31') WHERE code IN ('V3G','X84');
SELECT t.eq('E octobre : aucune charge', count(*)::text, '0') FROM etat_resultat_reglementaire(1::smallint,'2026-10-01','2026-10-31') WHERE cote = 'charge';
SELECT t.eq('E novembre : loyer en charges (T84), plus de produits', (SELECT montant FROM etat_resultat_reglementaire(1::smallint,'2026-11-01','2026-11-30') WHERE code = 'T84')::text || '/' ||
            (SELECT count(*) FROM etat_resultat_reglementaire(1::smallint,'2026-11-01','2026-11-30') WHERE cote = 'produit')::text, '1000/0');

-- ===== F. Provisions : déduites de l'actif =====
SELECT pg_temp.piece(1::smallint,'2026-11-15', pg_temp.ac('292'),  pg_temp.ac('1011'),  10000);   -- crédit douteux
SELECT pg_temp.piece(1::smallint,'2026-11-15', pg_temp.ac('6'),    pg_temp.ac('2992'),   4000);   -- provision
SELECT t.eq('F crédits en souffrance nets de provisions (B70)', montant::text, '6000') FROM valeurs_postes(1::smallint,'2026-11-30','2026-11-30') WHERE code = 'B70';
-- la dotation de 4000 fait passer le résultat de +2000 à -2000 : le déficit (E05) figure à l'actif
SELECT t.eq('F le bilan reste équilibré, le déficit est à l''actif (E05)', (SELECT montant FROM etat_bilan_reglementaire(1::smallint,'2026-11-30') WHERE code = 'E90')::text || '=' ||
            (SELECT montant FROM etat_bilan_reglementaire(1::smallint,'2026-11-30') WHERE code = 'L90')::text, '150000=150000');

SELECT t.eq('F déficit E05 et excédent L75', (SELECT montant FROM valeurs_postes(1::smallint,'2026-11-30','2026-11-30') WHERE code = 'E05')::text || '/' ||
            (SELECT montant FROM valeurs_postes(1::smallint,'2026-11-30','2026-11-30') WHERE code = 'L75')::text, '2000/0');

-- ===== G. Hors-bilan =====
SELECT pg_temp.piece(1::smallint,'2026-11-20', pg_temp.ac('901'), pg_temp.ac('911'), 20000);
SELECT t.eq('G engagement de financement donné (N1A)', string_agg(code || ':' || montant, ' ' ORDER BY code), 'N1A:20000') FROM etat_hors_bilan(1::smallint,'2026-11-30') WHERE code = 'N1A';
