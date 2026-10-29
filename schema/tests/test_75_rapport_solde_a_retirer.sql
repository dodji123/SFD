SET search_path = mf, public;

-- Module sous test : 75_rapport_solde_a_retirer.sql (soldes que les clients peuvent encore retirer, par produit)
INSERT INTO agence(code,libelle) VALUES ('LOM','Lomé Centre');
INSERT INTO zone(agence_id,code,libelle) VALUES (1,'Z1','Zone Marché');
INSERT INTO agent(agence_id,matricule,nom) VALUES (1,'A01','Agent Un');
INSERT INTO client(agence_id,zone_id,numero,nom) VALUES (1,1,'C1','Un'),(1,1,'C2','Deux');
INSERT INTO produit_epargne(code,libelle,categorie,type_cycle,nb_pages_livret) VALUES ('P1','Tontine','collecte',1,1);
INSERT INTO produit_epargne(code,libelle,categorie) VALUES ('P2','Tontine libre','collecte');

INSERT INTO cycle(agence_id,numero,client_id,produit_id,type_cycle,mise_initiale,mise_courante,objectif,date_debut,date_fin) VALUES
  (1,'S1',(SELECT id FROM client WHERE numero = 'C1'),(SELECT id FROM produit_epargne WHERE code = 'P1'),1,1000,1000,31000,'2026-10-01','2026-11-30'),
  (1,'S2',(SELECT id FROM client WHERE numero = 'C2'),(SELECT id FROM produit_epargne WHERE code = 'P1'),1,1000,1000,31000,'2026-10-01','2026-11-30'),
  (1,'S3',(SELECT id FROM client WHERE numero = 'C1'),(SELECT id FROM produit_epargne WHERE code = 'P2'),3,500,500,NULL,'2026-10-01','2026-11-30');

-- S1 : 3 collectes de 1 000 (net 2 000) ; S2 : 2 collectes de 1 000 (net 1 000) ; S3 : une collecte de 500, produit libre
INSERT INTO ligne_collecte(cycle_id,page,no_ligne,date_collecte,agent_id,montant_collecte)
SELECT (SELECT id FROM cycle WHERE numero = 'S1'),1,g,'2026-10-01'::date+g-1,(SELECT id FROM agent WHERE matricule = 'A01'),1000
  FROM generate_series(1,3) g;
INSERT INTO ligne_collecte(cycle_id,page,no_ligne,date_collecte,agent_id,montant_collecte)
SELECT (SELECT id FROM cycle WHERE numero = 'S2'),1,g,'2026-10-01'::date+g-1,(SELECT id FROM agent WHERE matricule = 'A01'),1000
  FROM generate_series(1,2) g;
INSERT INTO ligne_collecte(cycle_id,page,no_ligne,date_collecte,agent_id,montant_collecte)
VALUES ((SELECT id FROM cycle WHERE numero = 'S3'),1,1,'2026-10-01',(SELECT id FROM agent WHERE matricule = 'A01'),500);

-- Par produit : P1 a deux clients avec un solde, P2 n'en a pas
SELECT t.eq('Z P1 : deux clients avec un solde', count(*)::text, '2') FROM rapport_solde_a_retirer(1::smallint, (SELECT id FROM produit_epargne WHERE code = 'P1'));
SELECT t.eq('Z P1 : soldes 2 000 et 1 000 (total 3 000)', sum(solde)::text, '3000') FROM rapport_solde_a_retirer(1::smallint, (SELECT id FROM produit_epargne WHERE code = 'P1'));
SELECT t.eq('Z P1 : solde du client C1', solde::text, '2000') FROM rapport_solde_a_retirer(1::smallint, (SELECT id FROM produit_epargne WHERE code = 'P1')) WHERE client_numero = 'C1';
SELECT t.eq('Z produit libre sans solde : absent', count(*)::text, '0') FROM rapport_solde_a_retirer(1::smallint, (SELECT id FROM produit_epargne WHERE code = 'P2'));
SELECT t.eq('Z tous produits : deux lignes', count(*)::text, '2') FROM rapport_solde_a_retirer(1::smallint, NULL);

-- Un cycle retiré sort du rapport
UPDATE cycle SET statut = 'retire' WHERE numero = 'S2';
SELECT t.eq('Z cycle retiré : sorti du rapport', count(*)::text, '1') FROM rapport_solde_a_retirer(1::smallint, (SELECT id FROM produit_epargne WHERE code = 'P1'));
