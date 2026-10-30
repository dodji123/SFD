SET search_path = mf, public;

-- Module sous test : 79_solde_a_retirer_date.sql (soldes à retirer à une date donnée)
INSERT INTO agence(code,libelle) VALUES ('LOM','Lomé Centre');
INSERT INTO zone(agence_id,code,libelle) VALUES (1,'Z1','Zone Marché');
INSERT INTO agent(agence_id,matricule,nom) VALUES (1,'A01','Agent Un');
INSERT INTO client(agence_id,zone_id,numero,nom) VALUES (1,1,'C1','Un');
INSERT INTO produit_epargne(code,libelle,categorie,type_cycle,nb_pages_livret) VALUES ('P1','Tontine','collecte',1,1);
INSERT INTO cycle(agence_id,numero,client_id,produit_id,type_cycle,mise_initiale,mise_courante,objectif,date_debut,date_fin) VALUES
  (1,'S1',(SELECT id FROM client WHERE numero = 'C1'),(SELECT id FROM produit_epargne WHERE code = 'P1'),1,1000,1000,31000,'2026-10-01','2026-11-30');
-- collectes : 3 000 le 1er, 2 000 le 15
INSERT INTO ligne_collecte(cycle_id,page,no_ligne,date_collecte,agent_id,montant_collecte)
VALUES ((SELECT id FROM cycle WHERE numero='S1'),1,1,'2026-10-01',(SELECT id FROM agent WHERE matricule='A01'),3000),
       ((SELECT id FROM cycle WHERE numero='S1'),1,2,'2026-10-15',(SELECT id FROM agent WHERE matricule='A01'),2000);

-- À la date du 10 : 3 000 - 1 000 de mise = 2 000 (la collecte du 15 n'est pas encore faite)
SELECT t.eq('D solde à la date : collecte jusqu''au 10 moins la mise', solde::text, '2000')
  FROM rapport_solde_a_retirer_date(1::smallint, '2026-10-10', NULL) WHERE cycle = 'S1';

-- À la fin du mois : 5 000 - 1 000 = 4 000
SELECT t.eq('D solde à la date : fin du mois', solde::text, '4000')
  FROM rapport_solde_a_retirer_date(1::smallint, '2026-10-31', NULL) WHERE cycle = 'S1';

-- Avant l'ouverture du cycle : rien
SELECT t.eq('D avant l''ouverture : aucune ligne', count(*)::text, '0') FROM rapport_solde_a_retirer_date(1::smallint, '2026-09-30', NULL);

-- Un retrait daté après la date n'est pas compté ; un retrait daté avant est déduit
INSERT INTO retrait(agence_id,cycle_id,nature,montant,decaissement,statut,date_demande)
VALUES (1,(SELECT id FROM cycle WHERE numero='S1'),'retrait_client',1500,true,'execute','2026-10-20');
SELECT t.eq('D retrait postérieur à la date ignoré', solde::text, '2000') FROM rapport_solde_a_retirer_date(1::smallint, '2026-10-10', NULL) WHERE cycle = 'S1';
SELECT t.eq('D retrait antérieur déduit', solde::text, '2500') FROM rapport_solde_a_retirer_date(1::smallint, '2026-10-31', NULL) WHERE cycle = 'S1';
