SET search_path = mf, public;

-- Module sous test : 67_postes_z_et_q1j.sql (Z01 = compte 191, Z02 = compte 291, Q1J = comptes 376)
INSERT INTO agence(code,libelle) VALUES ('LOM','Lomé Centre');
INSERT INTO exercice_comptable(code,date_debut,date_fin) VALUES ('2026','2026-01-01','2026-12-31');
CREATE FUNCTION pg_temp.ac(p text) RETURNS text LANGUAGE sql AS $$ SELECT min(code) FROM mf.compte_comptable WHERE code LIKE p || '%' AND imputable $$;

-- Prêt immobilisé de 5 000 F (compte 191) contre trésorerie (compte 5)
INSERT INTO piece_comptable(agence_id,journal_id,exercice_id,date_piece,numero,libelle,origine)
VALUES (1,(SELECT id FROM journal WHERE code='OD'),(SELECT id FROM exercice_comptable LIMIT 1),'2026-03-31',
        mf.prochain_numero('piece',1::smallint,'2026-03-31','PC'),'test z01','manuelle');
INSERT INTO ecriture(piece_id,ligne,compte_code,debit,credit)
SELECT p.id, v.l, v.c, v.d, v.k FROM piece_comptable p,
  (VALUES (1, pg_temp.ac('191'), 5000::numeric, 0::numeric), (2, pg_temp.ac('5'), 0::numeric, 5000::numeric)) AS v(l, c, d, k)
 WHERE p.libelle = 'test z01';

SELECT t.eq('Z01 prêts immobilisés = 5 000', montant::text, '5000') FROM valeurs_postes(1::smallint, '2026-12-31', '2026-12-31') WHERE code = 'Z01';
SELECT t.eq('Z02 crédits immobilisés = 0', montant::text, '0') FROM valeurs_postes(1::smallint, '2026-12-31', '2026-12-31') WHERE code = 'Z02';
SELECT t.eq('Q1J présent dans la nomenclature', count(*)::text, '1') FROM poste_etat WHERE code = 'Q1J';
