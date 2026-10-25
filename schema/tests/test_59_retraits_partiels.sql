SET search_path = mf, public;

-- aides locales : retrouver un cycle, et le retrait de solde actif d'un cycle
CREATE OR REPLACE FUNCTION t.cy(p_numero text) RETURNS integer LANGUAGE sql AS $$ SELECT id FROM mf.cycle WHERE numero = p_numero $$;
CREATE OR REPLACE FUNCTION t.re_solde(p_cycle text) RETURNS integer LANGUAGE sql AS $$
  SELECT id FROM mf.retrait WHERE cycle_id = t.cy(p_cycle) AND nature = 'retrait_client' AND statut <> 'annule' ORDER BY id DESC LIMIT 1 $$;

-- ===== Données de base : cycle R1, 5 collectes de 1 000 F, mise 1 000 F => net 4 000 F =====
INSERT INTO agence(code,libelle) VALUES ('LOM','Lomé Centre');
INSERT INTO zone(agence_id,code,libelle) VALUES (1,'Z1','Zone Marché');
INSERT INTO agent(agence_id,matricule,nom) VALUES (1,'A03','Ama');
INSERT INTO client(agence_id,zone_id,numero,nom) VALUES (1,1,'C001','Un');
INSERT INTO produit_epargne(code,libelle,categorie,type_cycle,nb_pages_livret) VALUES ('P1','Tontine','collecte',1,1);
INSERT INTO cycle(agence_id,numero,client_id,produit_id,type_cycle,mise_initiale,mise_courante,objectif,date_debut,date_fin)
VALUES (1,'R1',1,1,1,1000,1000,31000,'2026-10-01','2026-10-31');
INSERT INTO ligne_collecte(cycle_id,page,no_ligne,date_collecte,agent_id,montant_collecte)
SELECT t.cy('R1'),1,g,'2026-10-01'::date+g-1,(SELECT id FROM agent WHERE matricule='A03'),1000 FROM generate_series(1,5) g;

-- ===== R. Solde disponible et retrait d'urgence pendant la collecte =====
SELECT t.eq('R solde initial = net', solde_disponible_cycle(t.cy('R1'))::text, '4000');

-- retrait d'urgence de 1 500 F : le cycle reste en cours, le solde diminue
SELECT demander_retrait_cycle(t.cy('R1'),'retrait_client','2026-10-10',1500);
SELECT t.eq('R cycle non clôturé par un retrait partiel', statut, 'en_cours') FROM cycle WHERE id = t.cy('R1');
SELECT t.eq('R solde après retrait partiel', solde_disponible_cycle(t.cy('R1'))::text, '2500');
SELECT t.refuse('R retrait supérieur au solde disponible',
  format('SELECT mf.demander_retrait_cycle(%s,''retrait_client'',''2026-10-10'',3000)', t.cy('R1')));
SELECT t.refuse('R retrait nul refusé',
  format('SELECT mf.demander_retrait_cycle(%s,''retrait_client'',''2026-10-10'',0)', t.cy('R1')));

-- constat et exécution du retrait partiel : le cycle n'est pas retiré tant que le solde n'est pas épuisé
SELECT constater_sans_ecart(t.re_solde('R1'));
SELECT executer_retrait(t.re_solde('R1'), '2026-10-10');
SELECT t.eq('R retrait partiel exécuté', statut, 'execute') FROM retrait WHERE id = t.re_solde('R1');
SELECT t.eq('R cycle toujours non retiré après retrait partiel', statut, 'en_cours') FROM cycle WHERE id = t.cy('R1');

-- ===== Retrait du reste (2 500 F) : retrait total, le cycle est clôturé puis retiré à l'exécution =====
SELECT demander_retrait_cycle(t.cy('R1'),'retrait_client','2026-10-20');
SELECT t.eq('R solde épuisé', solde_disponible_cycle(t.cy('R1'))::text, '0');
SELECT t.eq('R retrait total : cycle clôturé', statut, 'clos') FROM cycle WHERE id = t.cy('R1');
SELECT t.refuse('R retrait sur solde épuisé refusé',
  format('SELECT mf.demander_retrait_cycle(%s,''retrait_client'',''2026-10-20'')', t.cy('R1')));
SELECT constater_sans_ecart(t.re_solde('R1'));
SELECT executer_retrait(t.re_solde('R1'), '2026-10-20');
SELECT t.eq('R cycle retiré quand le solde est épuisé', statut, 'retire') FROM cycle WHERE id = t.cy('R1');
SELECT t.eq('R montant total retiré', (SELECT sum(montant_paye)::text FROM retrait WHERE cycle_id = t.cy('R1') AND statut = 'execute'), '4000');
