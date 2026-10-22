SET search_path = mf, public;

-- Module sous test : 48_carnets.sql (stock de carnets par produit, remise aux agents, attribution aux cycles, perte et remplacement)
INSERT INTO agence(code,libelle) VALUES ('LOM','Lomé Centre'),('KPA','Kpalimé');
INSERT INTO agent(agence_id,matricule,nom) VALUES (1,'A01','Agent un'),(2,'A02','Agent deux');
INSERT INTO client(agence_id,nom) VALUES (1,'Cliente un'),(1,'Cliente deux');
INSERT INTO produit_epargne(code,libelle,categorie) VALUES ('TON','Tontine normale','collecte'),('TOR','Tontine rapide','collecte');
INSERT INTO produit_epargne(code,libelle,categorie) VALUES ('EPC','Épargne classique','classique');
INSERT INTO cycle(agence_id,numero,client_id,produit_id,type_cycle,mise_initiale,mise_courante,objectif,date_debut,date_fin) VALUES
  (1,'CY-1',1,1,2,1000,1000,31000,'2026-10-01','2026-10-31'),
  (1,'CY-2',2,2,2,500,500,15500,'2026-10-01','2026-10-31');

-- ===== A. Réception d'un lot =====
SET mf.utilisateur = 'chef';
SELECT t.eq('A lot de 5 carnets reçu', recevoir_lot_carnets(1::smallint, 1, 5, 'BL-001')::text, '1');
SELECT t.eq('A carnets numérotés par produit', string_agg(numero, ',' ORDER BY ordre), 'LOM-TON-000001,LOM-TON-000002,LOM-TON-000003,LOM-TON-000004,LOM-TON-000005') FROM carnet WHERE produit_id = 1;
SELECT t.eq('A lot suivant : numérotation continue', recevoir_lot_carnets(1::smallint, 1, 2)::text, '2');
SELECT t.eq('A premier numéro du second lot', min(numero), 'LOM-TON-000006') FROM carnet WHERE lot_id = 2;
SELECT t.eq('A lot du second produit', recevoir_lot_carnets(1::smallint, 2, 3)::text, '3');
SELECT t.eq('A numérotation indépendante par produit', min(numero), 'LOM-TOR-000001') FROM carnet WHERE produit_id = 2;
SELECT t.eq('A lot d''une autre agence', recevoir_lot_carnets(2::smallint, 1, 1)::text, '4');
SELECT t.eq('A numérotation indépendante par agence', min(numero), 'KPA-TON-000001') FROM carnet WHERE agence_id = 2 AND produit_id = 1;
SELECT t.refuse('A lot pour un produit d''épargne classique', 'SELECT mf.recevoir_lot_carnets(1::smallint, 3, 2)');
SELECT t.refuse('A lot trop grand', 'SELECT mf.recevoir_lot_carnets(1::smallint, 1, 6000)');
SELECT t.eq('A mouvement de réception journalisé', count(*)::text || '/' || min(par), '11/chef') FROM carnet_mouvement WHERE de_statut IS NULL;
SELECT t.eq('A stock agence 1 / produit 1', en_stock::text || '/' || total::text, '7/7') FROM v_stock_carnets WHERE agence_id = 1 AND produit_id = 1;
SELECT t.eq('A alerte de réapprovisionnement sous le seuil', reapprovisionner::text, 'true') FROM v_stock_carnets WHERE agence_id = 1 AND produit_id = 1;

-- ===== B. Remise à un agent =====
UPDATE carnet SET statut = 'chez_agent', agent_id = 1 WHERE numero = 'LOM-TON-000001' AND agence_id = 1;
SELECT t.refuse('B remise à un agent d''une autre agence', 'UPDATE mf.carnet SET statut = ''chez_agent'', agent_id = 2 WHERE numero = ''LOM-TON-000002'' AND agence_id = 1');
SELECT t.refuse('B remise sans agent', 'UPDATE mf.carnet SET statut = ''chez_agent'' WHERE numero = ''LOM-TON-000002'' AND agence_id = 1');
SELECT t.eq('B stock : un carnet chez un agent', chez_agents::text || '/' || en_stock::text, '1/6') FROM v_stock_carnets WHERE agence_id = 1 AND produit_id = 1;

-- ===== C. Attribution à un cycle : chaque produit a son livret =====
SELECT t.refuse('C carnet d''un autre produit', 'UPDATE mf.carnet SET statut = ''attribue'', agent_id = NULL, cycle_id = (SELECT id FROM mf.cycle WHERE numero = ''CY-2'') WHERE numero = ''LOM-TON-000001'' AND agence_id = 1');
SELECT t.refuse('C carnet d''une autre agence', 'UPDATE mf.carnet SET statut = ''attribue'', cycle_id = (SELECT id FROM mf.cycle WHERE numero = ''CY-1'') WHERE agence_id = 2');
UPDATE carnet SET statut = 'attribue', agent_id = NULL, cycle_id = (SELECT id FROM cycle WHERE numero = 'CY-1') WHERE numero = 'LOM-TON-000001' AND agence_id = 1;
SELECT t.eq('C carnet attribué au cycle', cycle || '/' || client, 'CY-1/Cliente un') FROM v_carnet WHERE numero = 'LOM-TON-000001' AND agence_id = 1;
SELECT t.refuse('C un seul carnet attribué par cycle', 'UPDATE mf.carnet SET statut = ''attribue'', cycle_id = (SELECT id FROM mf.cycle WHERE numero = ''CY-1'') WHERE numero = ''LOM-TON-000002'' AND agence_id = 1');
UPDATE carnet SET statut = 'attribue', cycle_id = (SELECT id FROM cycle WHERE numero = 'CY-2') WHERE numero = 'LOM-TOR-000001';
SELECT t.refuse('C changer le cycle sans changer d''état', 'UPDATE mf.carnet SET cycle_id = (SELECT id FROM mf.cycle WHERE numero = ''CY-2'') WHERE numero = ''LOM-TON-000001'' AND agence_id = 1');

-- ===== D. Perte, remplacement et fin de vie =====
SELECT t.refuse('D perte sans motif', 'UPDATE mf.carnet SET statut = ''perdu'' WHERE numero = ''LOM-TON-000001'' AND agence_id = 1');
UPDATE carnet SET statut = 'perdu', motif = 'Perdu par la cliente au marché' WHERE numero = 'LOM-TON-000001' AND agence_id = 1;
SELECT t.eq('D motif et cycle conservés', motif || '/' || (SELECT numero FROM cycle WHERE id = carnet.cycle_id), 'Perdu par la cliente au marché/CY-1') FROM carnet WHERE numero = 'LOM-TON-000001' AND agence_id = 1;
SELECT t.refuse('D carnet perdu définitif', 'UPDATE mf.carnet SET statut = ''en_stock'' WHERE numero = ''LOM-TON-000001'' AND agence_id = 1');
SELECT t.refuse('D remplacement d''un carnet d''un autre cycle', 'UPDATE mf.carnet SET statut = ''attribue'', cycle_id = (SELECT id FROM mf.cycle WHERE numero = ''CY-1''), remplace_id = (SELECT id FROM mf.carnet WHERE numero = ''LOM-TOR-000001'') WHERE numero = ''LOM-TON-000002'' AND agence_id = 1');
UPDATE carnet SET statut = 'attribue', cycle_id = (SELECT id FROM cycle WHERE numero = 'CY-1'), remplace_id = (SELECT id FROM carnet WHERE numero = 'LOM-TON-000001' AND agence_id = 1) WHERE numero = 'LOM-TON-000002' AND agence_id = 1;
SELECT t.eq('D carnet de remplacement lié', (SELECT r.numero FROM carnet r WHERE r.id = carnet.remplace_id), 'LOM-TON-000001') FROM carnet WHERE numero = 'LOM-TON-000002' AND agence_id = 1;
UPDATE carnet SET statut = 'termine' WHERE numero = 'LOM-TOR-000001';
SELECT t.refuse('D carnet terminé définitif', 'UPDATE mf.carnet SET statut = ''attribue'' WHERE numero = ''LOM-TOR-000001''');
SELECT t.refuse('D numéro non modifiable', 'UPDATE mf.carnet SET numero = ''X-1'' WHERE numero = ''LOM-TON-000003'' AND agence_id = 1');
SELECT t.refuse('D carnet non supprimable', 'DELETE FROM mf.carnet WHERE numero = ''LOM-TON-000003'' AND agence_id = 1');

-- ===== E. Journal inaltérable =====
SELECT t.eq('E historique du carnet remplacé', string_agg(COALESCE(de_statut, '-') || '>' || a_statut, ' ' ORDER BY id), '->en_stock en_stock>chez_agent chez_agent>attribue attribue>perdu') FROM carnet_mouvement WHERE carnet_id = (SELECT id FROM carnet WHERE numero = 'LOM-TON-000001' AND agence_id = 1);
SELECT t.refuse('E journal non modifiable', 'UPDATE mf.carnet_mouvement SET motif = ''x''');
SELECT t.refuse('E journal non supprimable', 'DELETE FROM mf.carnet_mouvement');
