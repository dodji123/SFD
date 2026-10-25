SET search_path = mf, public;

-- aides locales
CREATE OR REPLACE FUNCTION t.cy(p_numero text) RETURNS integer LANGUAGE sql AS $$ SELECT id FROM mf.cycle WHERE numero = p_numero $$;

-- Cycles Q1 et Q2 : 5 collectes de 1 000 F, mise 1 000 F => net 4 000 F chacun.
INSERT INTO agence(code,libelle) VALUES ('LOM','Lomé Centre');
INSERT INTO zone(agence_id,code,libelle) VALUES (1,'Z1','Zone Marché');
INSERT INTO agent(agence_id,matricule,nom) VALUES (1,'A03','Ama');
INSERT INTO client(agence_id,zone_id,numero,nom) VALUES (1,1,'C001','Un');
INSERT INTO produit_epargne(code,libelle,categorie,type_cycle,nb_pages_livret) VALUES ('P1','Tontine','collecte',1,1);
INSERT INTO cycle(agence_id,numero,client_id,produit_id,type_cycle,mise_initiale,mise_courante,objectif,date_debut,date_fin)
VALUES (1,'Q1',1,1,1,1000,1000,31000,'2026-10-01','2026-10-31'),
       (1,'Q2',1,1,1,1000,1000,31000,'2026-10-01','2026-10-31');
INSERT INTO ligne_collecte(cycle_id,page,no_ligne,date_collecte,agent_id,montant_collecte)
SELECT t.cy('Q1'),1,g,'2026-10-01'::date+g-1,(SELECT id FROM agent WHERE matricule='A03'),1000 FROM generate_series(1,5) g;
INSERT INTO ligne_collecte(cycle_id,page,no_ligne,date_collecte,agent_id,montant_collecte)
SELECT t.cy('Q2'),1,g,'2026-10-01'::date+g-1,(SELECT id FROM agent WHERE matricule='A03'),1000 FROM generate_series(1,5) g;

-- 1. cycle en cours, retrait partiel d'urgence sans clôture
SELECT demander_retrait_cycle(t.cy('Q1'),'retrait_client','2026-10-10',1500,false);
SELECT t.eq('Q1 partiel sans clôture : reste en cours', statut, 'en_cours') FROM cycle WHERE id = t.cy('Q1');
SELECT t.eq('Q1 solde après partiel', solde_disponible_cycle(t.cy('Q1'))::text, '2500');

-- 2. cycle en cours, retrait partiel avec clôture demandée
SELECT demander_retrait_cycle(t.cy('Q2'),'retrait_client','2026-10-10',1500,true);
SELECT t.eq('Q2 partiel avec clôture : clos', statut, 'clos') FROM cycle WHERE id = t.cy('Q2');
SELECT t.eq('Q2 solde restant après partiel clôturé', solde_disponible_cycle(t.cy('Q2'))::text, '2500');

-- 3. cycle clôturé : un nouveau retrait partiel reste possible, le cycle reste clôturé
SELECT demander_retrait_cycle(t.cy('Q2'),'retrait_client','2026-10-20',1000,NULL);
SELECT t.eq('Q2 partiel sur cycle clôturé : reste clos', statut, 'clos') FROM cycle WHERE id = t.cy('Q2');
SELECT t.eq('Q2 solde après second partiel', solde_disponible_cycle(t.cy('Q2'))::text, '1500');
SELECT t.refuse('Q2 montant supérieur au solde refusé',
  format('SELECT mf.demander_retrait_cycle(%s,''retrait_client'',''2026-10-20'',2000,NULL)', t.cy('Q2')));

-- 4. retrait total du cycle en cours : clôture automatique, sans choix explicite
SELECT demander_retrait_cycle(t.cy('Q1'),'retrait_client','2026-10-20',NULL,NULL);
SELECT t.eq('Q1 retrait total : clos', statut, 'clos') FROM cycle WHERE id = t.cy('Q1');
SELECT t.eq('Q1 solde épuisé après retrait total', solde_disponible_cycle(t.cy('Q1'))::text, '0');
