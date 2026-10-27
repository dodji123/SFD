SET search_path = mf, public;

-- Module sous test : 69_postes_z_hors_bilan_et_prudentiel.sql
INSERT INTO agence(code,libelle) VALUES ('LOM','Lomé Centre');
INSERT INTO exercice_comptable(code,date_debut,date_fin) VALUES ('2026','2026-01-01','2026-12-31');

-- Engagement de financement donné de 5 000 (901) face à un engagement reçu de même montant (902)
INSERT INTO piece_comptable(agence_id,journal_id,exercice_id,date_piece,numero,libelle,origine)
VALUES (1,(SELECT id FROM journal WHERE code='OD'),(SELECT id FROM exercice_comptable LIMIT 1),'2026-03-31',
        mf.prochain_numero('piece',1::smallint,'2026-03-31','PC'),'test z11 hors bilan','manuelle');
INSERT INTO ecriture(piece_id,ligne,compte_code,debit,credit)
SELECT p.id, v.l, v.c, v.d, v.k FROM piece_comptable p,
  (VALUES (1, '901', 5000::numeric, 0::numeric), (2, '902', 0::numeric, 5000::numeric)) AS v(l, c, d, k)
 WHERE p.libelle = 'test z11 hors bilan';

-- Dotation de provision de 2 000 : 1921 débit, 511 crédit (passif)
INSERT INTO piece_comptable(agence_id,journal_id,exercice_id,date_piece,numero,libelle,origine)
VALUES (1,(SELECT id FROM journal WHERE code='OD'),(SELECT id FROM exercice_comptable LIMIT 1),'2026-03-31',
        mf.prochain_numero('piece',1::smallint,'2026-03-31','PC'),'test z51 provision','manuelle');
INSERT INTO ecriture(piece_id,ligne,compte_code,debit,credit)
SELECT p.id, v.l, v.c, v.d, v.k FROM piece_comptable p,
  (VALUES (1, '1921', 2000::numeric, 0::numeric), (2, '511', 0::numeric, 2000::numeric)) AS v(l, c, d, k)
 WHERE p.libelle = 'test z51 provision';

SELECT t.eq('Z11 engagements de financement donnés = 5 000', montant::text, '5000') FROM valeurs_postes(1::smallint, '2026-12-31', '2026-12-31') WHERE code = 'Z11';
SELECT t.eq('Z12 engagements de financement reçus = 5 000', montant::text, '5000') FROM valeurs_postes(1::smallint, '2026-12-31', '2026-12-31') WHERE code = 'Z12';
SELECT t.eq('Z13 garanties données = 0', montant::text, '0') FROM valeurs_postes(1::smallint, '2026-12-31', '2026-12-31') WHERE code = 'Z13';
SELECT t.eq('Z51 provisions pour risques = 2 000', montant::text, '2000') FROM valeurs_postes(1::smallint, '2026-12-31', '2026-12-31') WHERE code = 'Z51';
SELECT t.eq('Z52 provisions réglementées = 0', montant::text, '0') FROM valeurs_postes(1::smallint, '2026-12-31', '2026-12-31') WHERE code = 'Z52';
SELECT t.eq('Z19 pas d''écriture : 0', montant::text, '0') FROM valeurs_postes(1::smallint, '2026-12-31', '2026-12-31') WHERE code = 'Z19';
