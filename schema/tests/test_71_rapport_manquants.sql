SET search_path = mf, public;

-- Module sous test : 71_rapport_manquants.sql (rapport des manquants non payés, période du / au)
-- Fichiers voisins : tests/test_02_ecarts.sql (manquants et règlements du compte agent).

INSERT INTO agence(code,libelle) VALUES ('LOM','Lomé Centre');
INSERT INTO zone(agence_id,code,libelle) VALUES (1,'Z1','Zone Marché');
INSERT INTO agent(agence_id,matricule,nom) VALUES (1,'A04','Kossi'),(1,'A05','Yao');
INSERT INTO client(agence_id,zone_id,numero,nom) VALUES (1,1,'C001','Un');
INSERT INTO produit_epargne(code,libelle,categorie,type_cycle,nb_pages_livret) VALUES ('P1','Tontine','collecte',1,1);
INSERT INTO cycle(agence_id,numero,client_id,produit_id,type_cycle,mise_initiale,mise_courante,objectif,date_debut,date_fin)
VALUES (1,'R1',1,1,1,1000,1000,31000,'2026-10-01','2026-10-31');
INSERT INTO ligne_collecte(cycle_id,page,no_ligne,date_collecte,agent_id,montant_collecte)
SELECT (SELECT id FROM cycle WHERE numero = 'R1'),1,g,'2026-10-01'::date+g-1,(SELECT id FROM agent WHERE matricule = 'A04'),1000
  FROM generate_series(1,5) g;

-- Versements : manquant de 200 le 2 octobre (800 versés pour 1 000 collectés)
SELECT enregistrer_versement((SELECT id FROM agent WHERE matricule = 'A04'),'2026-10-01',1000);
SELECT enregistrer_versement((SELECT id FROM agent WHERE matricule = 'A04'),'2026-10-02',800);
SELECT enregistrer_versement((SELECT id FROM agent WHERE matricule = 'A04'),'2026-10-03',1000);
SELECT enregistrer_versement((SELECT id FROM agent WHERE matricule = 'A04'),'2026-10-04',1000);
SELECT enregistrer_versement((SELECT id FROM agent WHERE matricule = 'A04'),'2026-10-05',1000);

-- Règlement partiel de 50 le 20 octobre
SELECT regler_compte_agent((SELECT id FROM agent WHERE matricule = 'A04'), 50, '2026-10-20', 'règlement partiel');

-- Octobre : manquant 200, recouvré 50, reste dû 150
SELECT t.eq('R octobre : manquant de la période', manquants::text, '200') FROM rapport_manquants(1::smallint,'2026-10-01','2026-10-31') WHERE matricule = 'A04';
SELECT t.eq('R octobre : recouvré', recouvre::text, '50') FROM rapport_manquants(1::smallint,'2026-10-01','2026-10-31') WHERE matricule = 'A04';
SELECT t.eq('R octobre : reste dû en fin de période', reste_du::text, '150') FROM rapport_manquants(1::smallint,'2026-10-01','2026-10-31') WHERE matricule = 'A04';
SELECT t.eq('R octobre : agent sans écart absent du rapport', count(*)::text, '0') FROM rapport_manquants(1::smallint,'2026-10-01','2026-10-31') WHERE matricule = 'A05';

-- Novembre : rien de nouveau, mais le reste dû de 150 reste à payer
SELECT t.eq('R novembre : pas de manquant nouveau', manquants::text, '0') FROM rapport_manquants(1::smallint,'2026-11-01','2026-11-30') WHERE matricule = 'A04';
SELECT t.eq('R novembre : reste dû reporté', reste_du::text, '150') FROM rapport_manquants(1::smallint,'2026-11-01','2026-11-30') WHERE matricule = 'A04';

-- Une période antérieure au manquant : pas de reste dû à la fin de septembre
SELECT t.eq('R septembre : aucune ligne', count(*)::text, '0') FROM rapport_manquants(1::smallint,'2026-09-01','2026-09-30');

-- Autre agence : aucune ligne
SELECT t.eq('R autre agence : aucune ligne', count(*)::text, '0') FROM rapport_manquants(2::smallint,'2026-10-01','2026-10-31');
