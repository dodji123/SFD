SET search_path = mf, public;

-- Module sous test : 73_reglement_manquant_collecte.sql (règlement des manquants de collecte du contrôle au carnet)
-- Fichiers voisins : tests/test_72_controle_carnet.sql (le contrôle), tests/test_02_ecarts.sql (surplus, compte agent).
INSERT INTO agence(code,libelle) VALUES ('LOM','Lomé Centre');
INSERT INTO zone(agence_id,code,libelle) VALUES (1,'Z1','Zone Marché');
INSERT INTO agent(agence_id,matricule,nom) VALUES (1,'A04','Kossi'),(1,'A05','Yao');
INSERT INTO client(agence_id,zone_id,numero,nom) VALUES (1,1,'C001','Un'),(1,1,'C002','Deux'),(1,1,'C003','Trois');
INSERT INTO produit_epargne(code,libelle,categorie) VALUES ('LIB','Tontine libre','collecte');
INSERT INTO utilisateur(login,nom,role,agence_id) VALUES ('ctrl','Contrôleur','chef_agence',1);

-- ===== A. Cycle M1 en cours : le surplus d'une autre date ne règle pas le manquant =====
INSERT INTO cycle(agence_id,numero,client_id,produit_id,type_cycle,mise_initiale,mise_courante,objectif,date_debut,date_fin)
VALUES (1,'M1',(SELECT id FROM client WHERE numero = 'C001'),(SELECT id FROM produit_epargne WHERE code = 'LIB'),3,1000,1000,31000,'2026-10-01','2026-10-31');
INSERT INTO ligne_collecte(cycle_id,page,no_ligne,date_collecte,agent_id,montant_collecte)
SELECT (SELECT id FROM cycle WHERE numero = 'M1'),1,g,'2026-10-01'::date+g-1,(SELECT id FROM agent WHERE matricule = 'A04'),1000
  FROM generate_series(1,5) g;

-- Surplus de versement de l'agent : 100 le 1er octobre, 300 le 2 octobre
INSERT INTO surplus(agence_id,agent_id,date_surplus,montant,origine)
VALUES (1,(SELECT id FROM agent WHERE matricule = 'A04'),'2026-10-01',100,'versement'),
       (1,(SELECT id FROM agent WHERE matricule = 'A04'),'2026-10-02',300,'versement');

-- Contrôle : ligne 3 (3 octobre) à 1 500 : manquant de 500 ; ligne 4 à 1 200 : manquant de 200 ; ligne 5 à 800 : excédent
SELECT enregistrer_controle_carnet((SELECT id FROM cycle WHERE numero = 'M1'), (SELECT id FROM utilisateur WHERE login = 'ctrl'), '2026-10-15',
  (SELECT jsonb_agg(jsonb_build_object('ligne_id', id, 'montant_carnet', CASE no_ligne WHEN 3 THEN 1500 WHEN 4 THEN 1200 WHEN 5 THEN 800 ELSE 1000 END))
     FROM ligne_collecte WHERE cycle_id = (SELECT id FROM cycle WHERE numero = 'M1')));

SELECT t.refuse('R ligne sans manquant refusée', 'SELECT mf.regler_manquant_collecte((SELECT l.id FROM mf.controle_carnet_ligne l JOIN mf.ligne_collecte c ON c.id = l.ligne_collecte_id WHERE c.no_ligne = 5))');
SELECT t.refuse('R ligne conforme refusée', 'SELECT mf.regler_manquant_collecte((SELECT l.id FROM mf.controle_carnet_ligne l JOIN mf.ligne_collecte c ON c.id = l.ligne_collecte_id WHERE c.no_ligne = 1))');

-- Les collectes du 3 et du 4 octobre ne sont pas retirées : seul le surplus de la même date pourrait régler, il n'y en a pas
SELECT t.eq('R tout imputé à l''agent (700)', regler_manquants_controle((SELECT id FROM controle_carnet WHERE cycle_id = (SELECT id FROM cycle WHERE numero = 'M1')), '2026-10-16')::text, '700');
SELECT t.eq('R aucun surplus d''une autre date utilisé', COALESCE(sum(surplus_utilise),0)::text, '0') FROM reglement_manquant_collecte;
SELECT t.eq('R surplus du 1er intact', montant_utilise::text || '/' || statut, '0/a_traiter') FROM surplus WHERE date_surplus = '2026-10-01';
SELECT t.eq('R surplus du 2 intact', montant_utilise::text || '/' || statut, '0/a_traiter') FROM surplus WHERE date_surplus = '2026-10-02';
SELECT t.eq('R solde agent A04 (-700)', solde::text, '-700') FROM v_solde_compte_agent WHERE matricule = 'A04';
SELECT t.refuse('R manquant déjà réglé refusé', 'SELECT mf.regler_manquant_collecte((SELECT l.id FROM mf.controle_carnet_ligne l JOIN mf.ligne_collecte c ON c.id = l.ligne_collecte_id WHERE c.no_ligne = 3))');

-- ===== B. Agent sans surplus : le manquant est imputé en totalité =====
INSERT INTO cycle(agence_id,numero,client_id,produit_id,type_cycle,mise_initiale,mise_courante,objectif,date_debut,date_fin)
VALUES (1,'M2',(SELECT id FROM client WHERE numero = 'C002'),(SELECT id FROM produit_epargne WHERE code = 'LIB'),3,1000,1000,31000,'2026-10-01','2026-10-31');
INSERT INTO ligne_collecte(cycle_id,page,no_ligne,date_collecte,agent_id,montant_collecte)
SELECT (SELECT id FROM cycle WHERE numero = 'M2'),1,g,'2026-10-01'::date+g-1,(SELECT id FROM agent WHERE matricule = 'A05'),1000
  FROM generate_series(1,2) g;
SELECT enregistrer_controle_carnet((SELECT id FROM cycle WHERE numero = 'M2'), (SELECT id FROM utilisateur WHERE login = 'ctrl'), '2026-10-15',
  (SELECT jsonb_agg(jsonb_build_object('ligne_id', id, 'montant_carnet', CASE no_ligne WHEN 1 THEN 1000 ELSE 1100 END))
     FROM ligne_collecte WHERE cycle_id = (SELECT id FROM cycle WHERE numero = 'M2')));
SELECT t.eq('R sans surplus : imputé en totalité', regler_manquants_controle((SELECT id FROM controle_carnet WHERE cycle_id = (SELECT id FROM cycle WHERE numero = 'M2')), '2026-10-16')::text, '100');
SELECT t.eq('R solde agent A05 (-100)', solde::text, '-100') FROM v_solde_compte_agent WHERE matricule = 'A05';

-- ===== C. Toutes les collectes du 3 octobre retirées : le surplus le plus ancien d'une autre date sert =====
INSERT INTO cycle(agence_id,numero,client_id,produit_id,type_cycle,mise_initiale,mise_courante,objectif,date_debut,date_fin)
VALUES (1,'M3',(SELECT id FROM client WHERE numero = 'C003'),(SELECT id FROM produit_epargne WHERE code = 'LIB'),3,1000,1000,31000,'2026-10-03','2026-10-31');
INSERT INTO ligne_collecte(cycle_id,page,no_ligne,date_collecte,agent_id,montant_collecte)
VALUES ((SELECT id FROM cycle WHERE numero = 'M3'),1,1,'2026-10-03',(SELECT id FROM agent WHERE matricule = 'A04'),1000);
SELECT enregistrer_controle_carnet((SELECT id FROM cycle WHERE numero = 'M3'), (SELECT id FROM utilisateur WHERE login = 'ctrl'), '2026-10-15',
  (SELECT jsonb_agg(jsonb_build_object('ligne_id', id, 'montant_carnet', 1050)) FROM ligne_collecte WHERE cycle_id = (SELECT id FROM cycle WHERE numero = 'M3')));
-- la ligne de M3 est la seule du 3 octobre pour A04 ; M1 (même date) est aussi retiré
UPDATE cycle SET statut = 'retire' WHERE numero IN ('M1', 'M3');
SELECT t.eq('R toutes les collectes du 3 retirées : rien imputé', mf.regler_manquant_collecte((SELECT l.id FROM mf.controle_carnet_ligne l JOIN mf.controle_carnet k ON k.id = l.controle_id JOIN mf.cycle c ON c.id = k.cycle_id WHERE c.numero = 'M3'), '2026-10-18')::text, '0');
SELECT t.eq('R surplus du 1er utilisé pour le manquant de 50', montant_utilise::text || '/' || statut, '50/a_traiter') FROM surplus WHERE date_surplus = '2026-10-01';
