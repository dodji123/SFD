SET search_path = mf, public;

INSERT INTO agence(code,libelle) VALUES ('LOM','Lomé Centre'),('KPA','Kpalimé'),('ABC','Sans activité'),('XYZ','Produits seulement');
INSERT INTO exercice_comptable(code,date_debut,date_fin) VALUES ('2026','2026-01-01','2026-12-31');
CREATE FUNCTION pg_temp.piece(p_agence smallint, p_date date, p_debit text, p_credit text, p_montant numeric) RETURNS void LANGUAGE plpgsql AS $$
DECLARE v bigint;
BEGIN
  INSERT INTO mf.piece_comptable(agence_id,journal_id,exercice_id,date_piece,numero,libelle,origine)
  VALUES (p_agence,(SELECT id FROM mf.journal WHERE code='OD'),(SELECT id FROM mf.exercice_comptable LIMIT 1),p_date,
          mf.prochain_numero('piece',p_agence,p_date,'PC'),'test','manuelle') RETURNING id INTO v;
  INSERT INTO mf.ecriture(piece_id,ligne,compte_code,debit,credit) VALUES (v,1,p_debit,p_montant,0),(v,2,p_credit,0,p_montant);
END $$;

-- Agence 1 (LOM) : dépôts 100000, crédit 30000, loyer 5000, intérêts 2000 (octobre) ; loyer 1000 en novembre
SELECT pg_temp.piece(1::smallint,'2026-10-05','1011','25111',100000);
SELECT pg_temp.piece(1::smallint,'2026-10-05','202211','1011',30000);
SELECT pg_temp.piece(1::smallint,'2026-10-05','6212','1011',5000);
SELECT pg_temp.piece(1::smallint,'2026-10-05','1011','70212',2000);
SELECT pg_temp.piece(1::smallint,'2026-11-20','6212','1011',1000);
-- Agence 2 (KPA) : dépôts 50000, intérêts 3000, loyer 1000
SELECT pg_temp.piece(2::smallint,'2026-10-06','1011','25111',50000);
SELECT pg_temp.piece(2::smallint,'2026-10-06','1011','70212',3000);
SELECT pg_temp.piece(2::smallint,'2026-10-06','6212','1011',1000);

-- Agence 4 (XYZ) : uniquement des produits, en décembre
SELECT pg_temp.piece(4::smallint,'2026-12-15','1011','70212',700);

-- ===== A. Compte de résultat par agence =====
SELECT t.eq('A LOM octobre', string_agg(cote || ':' || code || ':' || montant::text, ' ' ORDER BY cote DESC, code), 'produit:70:2000 charge:62:5000')
  FROM etat_resultat_par_agence(1::smallint,'2026-10-01','2026-10-31');
SELECT t.eq('A KPA octobre', string_agg(cote || ':' || code || ':' || montant::text, ' ' ORDER BY cote DESC, code), 'produit:70:3000 charge:62:1000')
  FROM etat_resultat_par_agence(2::smallint,'2026-10-01','2026-10-31');
SELECT t.eq('A période : seul le loyer de novembre', string_agg(cote || ':' || code || ':' || montant::text, ' '), 'charge:62:1000')
  FROM etat_resultat_par_agence(1::smallint,'2026-11-01','2026-11-30');
SELECT t.eq('A libellé du compte de niveau 2 renseigné', (min(libelle) IS NOT NULL AND min(libelle) <> '70')::text, 'true')
  FROM etat_resultat_par_agence(1::smallint,'2026-10-01','2026-10-31') WHERE code = '70';
SELECT t.eq('A période sans écriture', count(*)::text, '0') FROM etat_resultat_par_agence(1::smallint,'2025-01-01','2025-12-31');

-- ===== B. Consolidé du compte de résultat =====
SELECT t.eq('B toutes agences : une ligne par agence et par compte', string_agg(agence || ':' || cote || ':' || code || ':' || montant::text, ' ' ORDER BY cote DESC, code, agence),
            'KPA:produit:70:3000 LOM:produit:70:2000 KPA:charge:62:1000 LOM:charge:62:5000')
  FROM etat_resultat_par_agence(NULL,'2026-10-01','2026-10-31');
SELECT t.eq('B produits consolidés', sum(montant)::text, '5000') FROM etat_resultat_par_agence(NULL,'2026-10-01','2026-10-31') WHERE cote = 'produit';

-- ===== C. Bilan par agence =====
SELECT t.eq('C LOM : caisse, crédits, dépôts, résultat négatif à l''actif', string_agg(code || ':' || solde::text, ' ' ORDER BY code), '10:67000 20:30000 25:-100000 RES:3000')
  FROM bilan_par_agence(1::smallint,'2026-10-31');
SELECT t.eq('C KPA : le bénéfice est au passif', string_agg(code || ':' || solde::text, ' ' ORDER BY code), '10:52000 25:-50000 RES:-2000')
  FROM bilan_par_agence(2::smallint,'2026-10-31');
SELECT t.eq('C date postérieure : le loyer de novembre diminue la caisse', solde::text, '66000') FROM bilan_par_agence(1::smallint,'2026-11-30') WHERE code = '10';
SELECT t.eq('C avant toute écriture', count(*)::text, '0') FROM bilan_par_agence(1::smallint,'2026-01-01');
SELECT t.eq('C consolidé : la somme des soldes est nulle (bilan équilibré)', sum(solde)::text, '0') FROM bilan_par_agence(NULL,'2026-10-31');
SELECT t.eq('C consolidé : caisse des deux agences', sum(solde)::text, '119000') FROM bilan_par_agence(NULL,'2026-10-31') WHERE code = '10';

-- ===== D. Synthèse par agence =====
SELECT t.eq('D synthèse', string_agg(agence || ':' || produits || '/' || charges || '/' || resultat || '/' || total_actif || '/' || total_passif || '/' || ecart, ' ' ORDER BY agence),
            'ABC:0/0/0/0/0/0 KPA:3000/1000/2000/52000/52000/0 LOM:2000/5000/-3000/100000/100000/0 XYZ:0/0/0/0/0/0')
  FROM synthese_agences('2026-10-01','2026-10-31');
SELECT t.eq('D résultat de la période = produits - charges (consolidé)', sum(resultat)::text, '-1000') FROM synthese_agences('2026-10-01','2026-10-31');
SELECT t.eq('D agence avec produits seulement : résultat = produits', produits || '/' || charges || '/' || resultat, '700/0/700') FROM synthese_agences('2026-12-01','2026-12-31') WHERE agence = 'XYZ';
SELECT t.eq('D les agences sont toutes équilibrées', (bool_and(ecart = 0))::text, 'true') FROM synthese_agences('2026-01-01','2026-12-31');
