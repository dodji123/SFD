SET search_path = mf, public;

-- Module sous test : 74_rapport_collecte_periode.sql (rapport des collectes d'une période par produit, agent ou zone)
INSERT INTO agence(code,libelle) VALUES ('LOM','Lomé Centre');
INSERT INTO zone(agence_id,code,libelle) VALUES (1,'Z1','Zone Marché'),(1,'Z2','Zone Port');
INSERT INTO agent(agence_id,matricule,nom) VALUES (1,'A01','Agent Un'),(1,'A02','Agent Deux');
INSERT INTO collectrice(agence_id,matricule,nom) VALUES (1,'K1','Ama'),(1,'K2','Kofi');
-- la zone Z1 passe de Ama à Kofi au cours de la période
INSERT INTO affectation_zone(zone_id,collectrice_id,date_debut,date_fin) VALUES
  ((SELECT id FROM zone WHERE code = 'Z1'),(SELECT id FROM collectrice WHERE matricule = 'K1'),'2026-10-01','2026-10-15'),
  ((SELECT id FROM zone WHERE code = 'Z1'),(SELECT id FROM collectrice WHERE matricule = 'K2'),'2026-10-16',NULL);
INSERT INTO client(agence_id,zone_id,numero,nom) VALUES
  (1,(SELECT id FROM zone WHERE code = 'Z1'),'C1','Un'),
  (1,(SELECT id FROM zone WHERE code = 'Z2'),'C2','Deux');
INSERT INTO produit_epargne(code,libelle,categorie,type_cycle,nb_pages_livret) VALUES ('P1','Tontine','collecte',1,1);
INSERT INTO produit_epargne(code,libelle,categorie) VALUES ('P2','Tontine libre','collecte');

INSERT INTO cycle(agence_id,numero,client_id,produit_id,type_cycle,mise_initiale,mise_courante,objectif,date_debut,date_fin) VALUES
  (1,'R1',(SELECT id FROM client WHERE numero = 'C1'),(SELECT id FROM produit_epargne WHERE code = 'P1'),1,1000,1000,31000,'2026-10-01','2026-11-30'),
  (1,'R2',(SELECT id FROM client WHERE numero = 'C2'),(SELECT id FROM produit_epargne WHERE code = 'P2'),3,500,500,NULL,'2026-10-01','2026-11-30');

-- collectes : R1 le 5 (Agent Un, 1 000), R1 le 20 (Agent Deux, 1 000), R1 le 2 novembre (hors période),
-- R2 le 6 (Agent Un, 500, zone Z2 sans affectation)
INSERT INTO ligne_collecte(cycle_id,page,no_ligne,date_collecte,agent_id,montant_collecte) VALUES
  ((SELECT id FROM cycle WHERE numero = 'R1'),1,1,'2026-10-05',(SELECT id FROM agent WHERE matricule = 'A01'),1000),
  ((SELECT id FROM cycle WHERE numero = 'R1'),1,2,'2026-10-20',(SELECT id FROM agent WHERE matricule = 'A02'),1000),
  ((SELECT id FROM cycle WHERE numero = 'R1'),1,3,'2026-11-02',(SELECT id FROM agent WHERE matricule = 'A01'),1000),
  ((SELECT id FROM cycle WHERE numero = 'R2'),1,1,'2026-10-06',(SELECT id FROM agent WHERE matricule = 'A01'),500);

-- Par zone : Z1 regroupe les deux collectrices successives, avec leurs dates
SELECT t.eq('Z zone Z1 : deux collectes, 2 000', nb_lignes::text || '/' || montant_collecte::text, '2/2000') FROM rapport_collecte_periode(1::smallint,'2026-10-01','2026-10-31',NULL,'zone') WHERE cle = 'Z1';
SELECT t.eq('Z zone Z1 : collectrices successives avec leurs dates', collectrices, 'Ama (2026-10-01 → 2026-10-15), Kofi (2026-10-16 → en cours)') FROM rapport_collecte_periode(1::smallint,'2026-10-01','2026-10-31',NULL,'zone') WHERE cle = 'Z1';
SELECT t.eq('Z zone Z2 : sans affectation', COALESCE(collectrices, 'aucune'), 'aucune') FROM rapport_collecte_periode(1::smallint,'2026-10-01','2026-10-31',NULL,'zone') WHERE cle = 'Z2';
SELECT t.eq('Z zone Z2 : 500', montant_collecte::text, '500') FROM rapport_collecte_periode(1::smallint,'2026-10-01','2026-10-31',NULL,'zone') WHERE cle = 'Z2';

-- Par produit
SELECT t.eq('Z produit P1 : 2 000', montant_collecte::text, '2000') FROM rapport_collecte_periode(1::smallint,'2026-10-01','2026-10-31',NULL,'produit') WHERE cle = 'P1';
SELECT t.eq('Z produit P2 : 500', montant_collecte::text, '500') FROM rapport_collecte_periode(1::smallint,'2026-10-01','2026-10-31',NULL,'produit') WHERE cle = 'P2';

-- Par agent
SELECT t.eq('Z agent A01 : 1 500 (1 000 + 500)', montant_collecte::text, '1500') FROM rapport_collecte_periode(1::smallint,'2026-10-01','2026-10-31',NULL,'agent') WHERE cle = 'A01';
SELECT t.eq('Z agent A02 : 1 000', montant_collecte::text, '1000') FROM rapport_collecte_periode(1::smallint,'2026-10-01','2026-10-31',NULL,'agent') WHERE cle = 'A02';

-- Filtre produit ; période hors collectes
SELECT t.eq('Z filtre produit P2 : une seule zone', count(*)::text, '1') FROM rapport_collecte_periode(1::smallint,'2026-10-01','2026-10-31',(SELECT id FROM produit_epargne WHERE code = 'P2'),'zone');
SELECT t.eq('Z novembre : collecte du 2 novembre seule', montant_collecte::text, '1000') FROM rapport_collecte_periode(1::smallint,'2026-11-01','2026-11-30',NULL,'zone') WHERE cle = 'Z1';
SELECT t.eq('Z hors période : aucune ligne', count(*)::text, '0') FROM rapport_collecte_periode(1::smallint,'2026-12-01','2026-12-31',NULL,'zone');
