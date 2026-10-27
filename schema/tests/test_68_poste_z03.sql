SET search_path = mf, public;

-- Module sous test : 68_poste_z03.sql (Z03 = comptes 453 et 454, immobilisations acquises par réalisation de garantie)
INSERT INTO agence(code,libelle) VALUES ('LOM','Lomé Centre');
INSERT INTO exercice_comptable(code,date_debut,date_fin) VALUES ('2026','2026-01-01','2026-12-31');
CREATE FUNCTION pg_temp.ac(p text) RETURNS text LANGUAGE sql AS $$ SELECT min(code) FROM mf.compte_comptable WHERE code LIKE p || '%' AND imputable $$;

-- Immobilisation corporelle acquise par garantie de 3 000 F (compte 454) contre trésorerie (compte 5)
INSERT INTO piece_comptable(agence_id,journal_id,exercice_id,date_piece,numero,libelle,origine)
VALUES (1,(SELECT id FROM journal WHERE code='OD'),(SELECT id FROM exercice_comptable LIMIT 1),'2026-03-31',
        mf.prochain_numero('piece',1::smallint,'2026-03-31','PC'),'test z03','manuelle');
INSERT INTO ecriture(piece_id,ligne,compte_code,debit,credit)
SELECT p.id, v.l, v.c, v.d, v.k FROM piece_comptable p,
  (VALUES (1, pg_temp.ac('454'), 3000::numeric, 0::numeric), (2, pg_temp.ac('5'), 0::numeric, 3000::numeric)) AS v(l, c, d, k)
 WHERE p.libelle = 'test z03';

SELECT t.eq('Z03 immobilisations acquises par garantie = 3 000', montant::text, '3000') FROM valeurs_postes(1::smallint, '2026-12-31', '2026-12-31') WHERE code = 'Z03';
