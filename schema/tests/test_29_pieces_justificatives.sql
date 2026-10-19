SET search_path = mf, public;

-- Module sous test : 29_pieces_justificatives.sql (pièces justificatives, retraits de tontine compilés)
INSERT INTO agence(code,libelle) VALUES ('LOM','Lomé Centre');
INSERT INTO utilisateur(agence_id,login,nom,role) VALUES (1,'caisse','Caissier','caissier');
INSERT INTO produit_epargne(code,libelle,categorie,type_cycle) VALUES ('T1','Tontine','collecte',1);
INSERT INTO produit_epargne(code,libelle,categorie) VALUES ('CL','Classique','classique');
INSERT INTO client(agence_id,nom) VALUES (1,'Client un'),(1,'Client deux');
INSERT INTO compte_epargne(agence_id,client_id,produit_id) VALUES (1,1,2),(1,2,2);
INSERT INTO cycle(agence_id,client_id,produit_id,type_cycle,mise_initiale,mise_courante,objectif,nb_lignes_prevues,date_debut,date_fin,statut) VALUES
  (1,1,1,1,500,500,15500,31,'2026-01-01','2026-01-31','retire'),
  (1,1,1,1,1000,1000,31000,31,'2026-02-01','2026-02-28','retire'),
  (1,1,1,1,2000,2000,62000,31,'2026-03-01','2026-03-31','retire'),
  (1,2,1,1,500,500,15500,31,'2026-01-01','2026-01-31','retire');
INSERT INTO retrait(agence_id,cycle_id,nature,montant,decaissement,statut,date_demande,date_operation,montant_paye) VALUES
  (1,1,'retrait_client',14500,true,'execute','2026-02-02','2026-02-02',14500),
  (1,2,'retrait_client',29000,true,'execute','2026-03-02','2026-03-02',29000),
  (1,3,'virement_vers_epargne',60000,false,'execute','2026-04-02','2026-04-02',60000),
  (1,4,'retrait_client',14500,true,'execute','2026-02-02','2026-02-02',14500);

-- ===== A. Pièce d'une opération =====
SELECT t.refuse('A pièce sans ligne', 'SELECT mf.creer_piece(''depot_epargne'', 1, 1, current_date, ''x'', ''[]''::jsonb, 1)');
SELECT t.refuse('A compte d''un autre client', 'SELECT mf.creer_piece(''depot_epargne'', 1, 2, current_date, ''x'', ''[{"libelle":"d","montant":100,"source":"mouvement_epargne:9"}]''::jsonb, 1)');
SELECT t.refuse('A type inconnu', 'SELECT mf.creer_piece(''collecte_tontine'', 1, NULL, current_date, ''x'', ''[{"libelle":"d","montant":100,"source":"ligne_collecte:9"}]''::jsonb, 1)');
SELECT creer_piece('depot_epargne', 1, 1, current_date, 'Dépôt sur le compte', '[{"libelle":"Dépôt","montant":25000,"source":"mouvement_epargne:1"}]'::jsonb, 1);
SELECT t.eq('A pièce numérotée, montant = somme des lignes', numero || ' ' || type || ' ' || montant, 'PJ-LOM-' || extract(year FROM current_date) || '-000001 depot_epargne 25000') FROM piece_justificative;
SELECT t.refuse('A une opération n''a qu''une pièce', 'SELECT mf.creer_piece(''depot_epargne'', 1, 1, current_date, ''x'', ''[{"libelle":"d","montant":25000,"source":"mouvement_epargne:1"}]''::jsonb, 1)');
SELECT t.eq('A pièce à plusieurs lignes : adhésion et parts', (creer_piece('adhesion', 2, 2, current_date, 'Adhésion', '[{"libelle":"Droit","montant":2000,"source":"adhesion:1"},{"libelle":"2 parts","montant":10000,"source":"souscription_part:1"}]'::jsonb, 1) > 0)::text, 'true');
SELECT t.eq('A total de la pièce d''adhésion', montant::text, '12000') FROM piece_justificative WHERE type = 'adhesion';

-- ===== B. Immuabilité =====
SELECT t.refuse('B modification refusée', 'UPDATE mf.piece_justificative SET montant = 1');
SELECT t.refuse('B suppression refusée', 'DELETE FROM mf.piece_justificative');
SELECT t.refuse('B modification d''une ligne refusée', 'UPDATE mf.piece_justificative_ligne SET montant = 1');

-- ===== C. Une seule pièce pour les retraits de plusieurs cycles =====
SELECT t.refuse('C aucun retrait', 'SELECT mf.creer_piece_retraits_tontine(ARRAY[]::integer[], current_date, 1)');
SELECT t.refuse('C retraits de deux clients', 'SELECT mf.creer_piece_retraits_tontine(ARRAY[1, 4], current_date, 1)');
SELECT t.refuse('C retrait inconnu', 'SELECT mf.creer_piece_retraits_tontine(ARRAY[1, 99], current_date, 1)');
SELECT t.refuse('C retrait en double', 'SELECT mf.creer_piece_retraits_tontine(ARRAY[1, 1], current_date, 1)');
INSERT INTO retrait(agence_id,cycle_id,nature,montant,decaissement,statut,date_demande) VALUES (1,4,'remboursement',500,false,'demande','2026-05-01');
SELECT t.refuse('C remboursement de crédit exclu', 'SELECT mf.creer_piece_retraits_tontine(ARRAY[(SELECT max(id) FROM mf.retrait)], current_date, 1)');
SELECT creer_piece_retraits_tontine(ARRAY[1, 2, 3], current_date, 1);
SELECT t.eq('C une seule pièce pour trois cycles', count(*)::text, '1') FROM piece_justificative WHERE type = 'retrait_tontine';
SELECT t.eq('C total = somme des montants payés', montant::text, '103500') FROM piece_justificative WHERE type = 'retrait_tontine';
SELECT t.eq('C une ligne par retrait, dans l''ordre demandé', string_agg(l.source, ',' ORDER BY l.ligne), 'retrait:1,retrait:2,retrait:3')
  FROM piece_justificative_ligne l JOIN piece_justificative p ON p.id = l.piece_id WHERE p.type = 'retrait_tontine';
SELECT t.eq('C le virement vers l''épargne porte le compte', (libelle LIKE 'Virement du cycle % vers le compte %')::text, 'true')
  FROM piece_justificative_ligne WHERE source = 'retrait:3';
SELECT t.refuse('C un retrait ne figure que sur une pièce', 'SELECT mf.creer_piece_retraits_tontine(ARRAY[2], current_date, 1)');
SELECT t.eq('C autre client : sa pièce à part', (creer_piece_retraits_tontine(ARRAY[4], current_date, 1) > 0)::text, 'true');
SELECT t.eq('C aucune pièce pour la collecte', count(*)::text, '0') FROM piece_justificative WHERE type NOT IN ('depot_epargne','retrait_epargne','adhesion','souscription_parts','depot_garantie','liberation_garantie','depot_terme','deblocage_terme','rupture_terme','retrait_tontine');
