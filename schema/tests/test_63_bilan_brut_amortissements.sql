SET search_path = mf, public;

-- Module sous test : 63_bilan_brut_amortissements.sql (brut, amortissements / provisions, net par poste)
INSERT INTO agence(code,libelle) VALUES ('LOM','Lomé Centre');
INSERT INTO exercice_comptable(code,date_debut,date_fin) VALUES ('2026','2026-01-01','2026-12-31');
CREATE FUNCTION pg_temp.ac(p text) RETURNS text LANGUAGE sql AS $$ SELECT min(code) FROM mf.compte_comptable WHERE code LIKE p || '%' AND imputable $$;

-- Créance brute de 10 000 F (compte 192), provision de 2 000 F (compte 1991), charge 2 000 F, trésorerie 10 000 F.
INSERT INTO piece_comptable(agence_id,journal_id,exercice_id,date_piece,numero,libelle,origine)
VALUES (1,(SELECT id FROM journal WHERE code='OD'),(SELECT id FROM exercice_comptable LIMIT 1),'2026-03-31',
        mf.prochain_numero('piece',1::smallint,'2026-03-31','PC'),'test brut','manuelle');
INSERT INTO ecriture(piece_id,ligne,compte_code,debit,credit)
SELECT p.id, v.l, v.c, v.d, v.k FROM piece_comptable p,
  (VALUES (1, pg_temp.ac('192'), 10000::numeric, 0::numeric), (2, pg_temp.ac('1991'), 0::numeric, 2000::numeric),
          (3, pg_temp.ac('6'), 2000::numeric, 0::numeric), (4, pg_temp.ac('5'), 0::numeric, 10000::numeric)) AS v(l, c, d, k)
 WHERE p.libelle = 'test brut';

SELECT t.eq('A71 brut = créance', brut::text, '10000') FROM valeurs_postes_detail(1::smallint, '2026-12-31') WHERE code = 'A71';
SELECT t.eq('A71 amortissements / provisions', amort::text, '2000') FROM valeurs_postes_detail(1::smallint, '2026-12-31') WHERE code = 'A71';
SELECT t.eq('A71 net = brut - provision', net::text, '8000') FROM valeurs_postes_detail(1::smallint, '2026-12-31') WHERE code = 'A71';
SELECT t.eq('cohérence : brut - amortissements = net pour tous les postes actifs', count(*)::text, '0')
  FROM valeurs_postes_detail(1::smallint, '2026-12-31') WHERE cote = 'actif' AND brut - amort <> net;
