SET search_path = mf, public;

INSERT INTO agence(code,libelle) VALUES ('LOM','Lomé Centre'),('KPA','Kpalimé');

-- ===== A. Plan de comptes SFD UMOA =====
SELECT t.eq('A plan chargé', count(*)::text, '1440') FROM compte_comptable;
SELECT t.eq('A 1011 imputable (billets BCEAO)', imputable::text, 'true') FROM compte_comptable WHERE code = '1011';
SELECT t.eq('A 253 non imputable (a des sous-comptes)', imputable::text, 'false') FROM compte_comptable WHERE code = '253';
SELECT t.eq('A parent de 25391', parent, '2539') FROM compte_comptable WHERE code = '25391';
SELECT t.eq('A classes présentes', string_agg(DISTINCT classe::text, '' ORDER BY classe::text), '12345679') FROM compte_comptable;
SELECT t.eq('A aucun compte sans parent hors racines à 2 chiffres', count(*)::text, '0') FROM compte_comptable WHERE parent IS NULL AND length(code) > 2;

-- ===== B. Exercices =====
INSERT INTO exercice_comptable(code,date_debut,date_fin) VALUES ('2026','2026-01-01','2026-12-31');
SELECT t.refuse('B exercice qui chevauche', 'INSERT INTO mf.exercice_comptable(code,date_debut,date_fin) VALUES (''X'',''2026-12-01'',''2027-06-30'')');
INSERT INTO exercice_comptable(code,date_debut,date_fin) VALUES ('2027','2027-01-01','2027-12-31');

-- ===== N. Numérotation automatique =====
INSERT INTO client(agence_id,numero,nom) VALUES (1,NULL,'Auto 1');
INSERT INTO client(agence_id,numero,nom) VALUES (1,NULL,'Auto 2');
INSERT INTO client(agence_id,numero,nom) VALUES (2,NULL,'Auto K');
INSERT INTO client(agence_id,numero,nom) VALUES (1,'MANUEL','Numéro fourni');
SELECT t.eq('N premier client', (numero ~ '^CL-LOM-[0-9]{4}-000001$')::text, 'true') FROM client WHERE nom = 'Auto 1';
SELECT t.eq('N deuxième client', (numero ~ '^CL-LOM-[0-9]{4}-000002$')::text, 'true') FROM client WHERE nom = 'Auto 2';
SELECT t.eq('N compteur propre à chaque agence', (numero ~ '^CL-KPA-[0-9]{4}-000001$')::text, 'true') FROM client WHERE nom = 'Auto K';
SELECT t.eq('N numéro fourni conservé', numero, 'MANUEL') FROM client WHERE nom = 'Numéro fourni';

-- ===== R. Règles et comptabilisation =====
INSERT INTO regle_comptable(evenement,ligne,agence_id,compte_debit,compte_credit,cle_montant,journal_code,libelle) VALUES
  ('depot_test',1,NULL,'1011','25111','montant','CAI','Dépôt client'),
  ('depot_test',2,NULL,'25111','70293','frais','CAI','Frais sur dépôt'),
  ('depot_test',1,2,'1011','25311','montant','CAI','Dépôt client (livret)');   -- surcharge agence 2
SELECT t.eq('R pièce créée', (comptabiliser('depot_test',1::smallint,'2026-10-05','{"montant":10000,"frais":300}','mouvement',1) IS NOT NULL)::text, 'true');
SELECT t.eq('R numéro de pièce', (numero ~ '^PC-LOM-2026-000001$')::text, 'true') FROM piece_comptable;
SELECT t.eq('R 4 écritures, débit = crédit', count(*)::text || '/' || sum(debit)::text || '/' || sum(credit)::text, '4/10300/10300') FROM ecriture;
SELECT t.eq('R journal de caisse', j.code, 'CAI') FROM piece_comptable p JOIN journal j ON j.id = p.journal_id;
SELECT t.refuse('R même opération comptabilisée deux fois', 'SELECT mf.comptabiliser(''depot_test'',1::smallint,''2026-10-05'',''{"montant":10000}'',''mouvement'',1)');
SELECT t.eq('R montants nuls : aucune pièce', coalesce(comptabiliser('depot_test',1::smallint,'2026-10-06','{"montant":0}','mouvement',2)::text,'NULL'), 'NULL');
SELECT t.refuse('R événement sans règle', 'SELECT mf.comptabiliser(''inconnu'',1::smallint,''2026-10-05'',''{"montant":1}'')');
SELECT t.refuse('R date hors exercice', 'SELECT mf.comptabiliser(''depot_test'',1::smallint,''2025-10-05'',''{"montant":1}'')');
SELECT t.refuse('R montant négatif', 'SELECT mf.comptabiliser(''depot_test'',1::smallint,''2026-10-05'',''{"montant":-5}'',''mouvement'',9)');
SELECT comptabiliser('depot_test',2::smallint,'2026-10-07','{"montant":5000}','mouvement',3);
SELECT t.eq('R surcharge de l''agence 2', e.compte_code, '25311')
  FROM ecriture e JOIN piece_comptable p ON p.id = e.piece_id WHERE p.agence_id = 2 AND e.credit > 0;

-- ===== E. Intégrité des écritures =====
SELECT t.refuse('E pièce déséquilibrée',
  'INSERT INTO mf.piece_comptable(agence_id,journal_id,exercice_id,date_piece,numero,origine) VALUES (1,(SELECT id FROM mf.journal WHERE code=''OD''),(SELECT id FROM mf.exercice_comptable WHERE code=''2026''),''2026-10-08'',''TEST-DESEQ'',''manuelle'');
   INSERT INTO mf.ecriture(piece_id,ligne,compte_code,debit,credit) VALUES (currval(''mf.piece_comptable_id_seq''),1,''1011'',100,0);
   SET CONSTRAINTS ALL IMMEDIATE');
SELECT t.refuse('E compte non imputable (253)',
  'INSERT INTO mf.piece_comptable(agence_id,journal_id,exercice_id,date_piece,numero,origine) VALUES (1,(SELECT id FROM mf.journal WHERE code=''OD''),(SELECT id FROM mf.exercice_comptable WHERE code=''2026''),''2026-10-08'',''TEST-NI'',''manuelle'');
   INSERT INTO mf.ecriture(piece_id,ligne,compte_code,debit,credit) VALUES (currval(''mf.piece_comptable_id_seq''),1,''253'',100,0)');
SELECT t.refuse('E débit et crédit sur la même ligne',
  'INSERT INTO mf.ecriture(piece_id,ligne,compte_code,debit,credit) VALUES ((SELECT min(id) FROM mf.piece_comptable),99,''1011'',100,100)');
SELECT t.refuse('E modification d''écriture', 'UPDATE mf.ecriture SET debit = 1 WHERE id = (SELECT min(id) FROM mf.ecriture)');
SELECT t.refuse('E suppression d''écriture', 'DELETE FROM mf.ecriture WHERE id = (SELECT min(id) FROM mf.ecriture)');
SELECT t.refuse('E suppression de pièce', 'DELETE FROM mf.piece_comptable');
-- pièce manuelle équilibrée en une transaction
BEGIN;
INSERT INTO piece_comptable(agence_id,journal_id,exercice_id,date_piece,numero,libelle,origine)
VALUES (1,(SELECT id FROM journal WHERE code='OD'),(SELECT id FROM exercice_comptable WHERE code='2026'),'2026-10-08','MAN-1','Charge de loyer','manuelle');
INSERT INTO ecriture(piece_id,ligne,compte_code,debit,credit) VALUES
  (currval('piece_comptable_id_seq'),1,'6212',50000,0),(currval('piece_comptable_id_seq'),2,'1011',0,50000);
COMMIT;
SELECT t.eq('E pièce manuelle équilibrée acceptée', count(*)::text, '2') FROM ecriture e JOIN piece_comptable p ON p.id = e.piece_id WHERE p.numero = 'MAN-1';

-- ===== S. États =====
SELECT t.eq('S balance équilibrée (agence 1)', sum(debit)::text || '=' || sum(credit)::text, '60300=60300') FROM balance(1::smallint,'2026-01-01','2026-12-31');
SELECT t.eq('S solde du compte 25111', solde_crediteur::text, '9700') FROM balance(1::smallint,'2026-01-01','2026-12-31') WHERE compte = '25111';
SELECT t.eq('S grand livre 25111 : cumuls', string_agg(solde_cumule::text, ',' ORDER BY solde_cumule), '-10000,-9700') FROM grand_livre('25111',1::smallint,'2026-01-01','2026-12-31');
SELECT t.eq('S toutes agences', sum(debit)::text, '65300') FROM balance(NULL,'2026-01-01','2026-12-31');
SELECT t.eq('S résultat = produits 300 - charges 50000', resultat(1::smallint,'2026-01-01','2026-12-31')::text, '-49700');

-- ===== C. Contrepassation et clôture =====
SELECT contrepasser_piece((SELECT id FROM piece_comptable WHERE reference_id = 1 AND evenement = 'depot_test'),'2026-10-20','erreur de saisie');
SELECT t.eq('C solde 25111 après contrepassation', coalesce((SELECT solde_crediteur - solde_debiteur FROM balance(1::smallint,'2026-01-01','2026-12-31') WHERE compte = '25111'), 0)::text, '0');
SELECT t.refuse('C deuxième contrepassation', format('SELECT mf.contrepasser_piece(%s)', (SELECT id FROM piece_comptable WHERE reference_id = 1 AND evenement = 'depot_test')));
SELECT t.refuse('C contrepasser une contrepassation', format('SELECT mf.contrepasser_piece(%s)', (SELECT id FROM piece_comptable WHERE origine = 'contrepassation')));
SELECT cloturer_exercice((SELECT id FROM exercice_comptable WHERE code = '2026'));
SELECT t.refuse('C écriture sur exercice clôturé', 'SELECT mf.comptabiliser(''depot_test'',1::smallint,''2026-11-01'',''{"montant":10}'',''mouvement'',77)');
SELECT t.refuse('C double clôture', format('SELECT mf.cloturer_exercice(%s)', (SELECT id FROM exercice_comptable WHERE code = '2026')));
SELECT t.eq('C exercice suivant ouvert', (comptabiliser('depot_test',1::smallint,'2027-01-10','{"montant":10}','mouvement',78) IS NOT NULL)::text, 'true');
