SET search_path = mf, public;

-- aides locales : retrouver un cycle ou un agent par son numéro (les ids de séquence ne sont pas stables)
CREATE OR REPLACE FUNCTION t.cy(p_numero text) RETURNS integer LANGUAGE sql AS $$ SELECT id FROM mf.cycle WHERE numero = p_numero $$;
CREATE OR REPLACE FUNCTION t.ag(p_matricule text) RETURNS integer LANGUAGE sql AS $$ SELECT id FROM mf.agent WHERE matricule = p_matricule $$;
CREATE OR REPLACE FUNCTION t.re(p_cycle text) RETURNS integer LANGUAGE sql AS $$
  SELECT id FROM mf.retrait WHERE cycle_id = t.cy(p_cycle) AND nature <> 'regularisation' $$;

-- ===== Données de base =====
INSERT INTO agence(code,libelle) VALUES ('LOM','Lomé Centre');
INSERT INTO zone(agence_id,code,libelle) VALUES (1,'Z1','Zone Marché');
INSERT INTO agent(agence_id,matricule,nom) VALUES (1,'A03','Ama'),(1,'A04','Kossi'),(1,'A05','Yao');
INSERT INTO client(agence_id,zone_id,numero,nom) VALUES
  (1,1,'C001','Un'),(1,1,'C002','Deux'),(1,1,'C003','Trois');
INSERT INTO produit_epargne(code,libelle,categorie,type_cycle,nb_pages_livret) VALUES ('P1','Tontine','collecte',1,1);

-- ===== S. Livret > machine : surplus de la date exacte d'abord, le reste est une perte =====
INSERT INTO cycle(agence_id,numero,client_id,produit_id,type_cycle,mise_initiale,mise_courante,objectif,date_debut,date_fin)
VALUES (1,'S1',1,1,1,1000,1000,31000,'2026-10-01','2026-10-31');
INSERT INTO ligne_collecte(cycle_id,page,no_ligne,date_collecte,agent_id,montant_collecte)
SELECT t.cy('S1'),1,g,'2026-10-01'::date+g-1,t.ag('A03'),1000 FROM generate_series(1,5) g;

SELECT enregistrer_versement(t.ag('A03'),'2026-10-01',1000);                     -- sans écart
SELECT enregistrer_versement(t.ag('A03'),'2026-10-02',800);                      -- manquant 200
SELECT enregistrer_versement(t.ag('A03'),'2026-10-03',1300);                     -- surplus 300
SELECT t.refuse('S versement déjà saisi', format('SELECT mf.enregistrer_versement(%s,''2026-10-03'',1000)', t.ag('A03')));
SELECT t.eq('S manquant au débit', solde::text, '-200') FROM v_solde_compte_agent WHERE agent_id = t.ag('A03');
SELECT t.eq('S surplus créé', montant::text, '300') FROM surplus WHERE agent_id = t.ag('A03');
SELECT t.eq('S surplus bloqué (cycle non retiré)', bloque::text, 'true') FROM v_surplus WHERE agent_id = t.ag('A03');

SELECT demander_retrait_cycle(t.cy('S1'),'retrait_client','2026-10-10');
SELECT t.eq('S net machine', montant::text, '4000') FROM retrait WHERE id = t.re('S1');
SELECT t.refuse('S machine différente du collecté',
  format('SELECT mf.enregistrer_ecart_retrait(%s, 5500, 4999, ''[{"date":"2026-10-03","montant":500}]'')', t.re('S1')));
SELECT t.refuse('S somme des dates différente de l''écart',
  format('SELECT mf.enregistrer_ecart_retrait(%s, 5500, 5000, ''[{"date":"2026-10-03","montant":400}]'')', t.re('S1')));
SELECT t.refuse('S date sans collecte sur le cycle',
  format('SELECT mf.enregistrer_ecart_retrait(%s, 5500, 5000, ''[{"date":"2026-10-20","montant":500}]'')', t.re('S1')));
SELECT t.refuse('S écart nul', format('SELECT mf.enregistrer_ecart_retrait(%s, 5000, 5000, ''[{"date":"2026-10-03","montant":1}]'')', t.re('S1')));
SELECT enregistrer_ecart_retrait(t.re('S1'), 5500, 5000,
  jsonb_build_array(jsonb_build_object('date','2026-10-03','montant',500,'agent_id',t.ag('A03'))));
SELECT t.eq('S statut après constat', statut, 'ecart_en_traitement') FROM retrait WHERE id = t.re('S1');
SELECT t.refuse('S exécution avant traitement', format('SELECT mf.executer_retrait(%s)', t.re('S1')));
SELECT t.eq('S perte imputée (500 - surplus 300)', traiter_ecart_retrait((SELECT id FROM ecart_retrait WHERE cycle_id = t.cy('S1')))::text, '200');
SELECT t.eq('S perte au compte de l''agent', montant::text, '200') FROM compte_agent WHERE agent_id = t.ag('A03') AND type = 'perte_retrait';
SELECT t.eq('S date de la perte', date_operation::text, '2026-10-10') FROM compte_agent WHERE type = 'perte_retrait';
SELECT t.eq('S surplus consommé', montant_utilise::text || '/' || statut, '300/solde') FROM surplus WHERE agent_id = t.ag('A03');
SELECT t.eq('S détail par date', surplus_utilise::text || '/' || perte::text, '300/200') FROM ecart_retrait_date;
SELECT t.refuse('S écart déjà traité', format('SELECT mf.traiter_ecart_retrait(%s)', (SELECT id FROM ecart_retrait WHERE cycle_id = t.cy('S1'))));
SELECT executer_retrait(t.re('S1'));
SELECT t.eq('S client payé selon le livret', montant_paye::text, '4500') FROM retrait WHERE id = t.re('S1');
SELECT t.eq('S cycle retiré', statut, 'retire') FROM cycle WHERE id = t.cy('S1');
SELECT t.eq('S surplus plus bloqué', bloque::text, 'false') FROM v_surplus WHERE agent_id = t.ag('A03');
SELECT t.refuse('S deuxième exécution', format('SELECT mf.executer_retrait(%s)', t.re('S1')));
SELECT t.eq('S solde agent (manquant 200 + perte 200)', solde::text, '-400') FROM v_solde_compte_agent WHERE agent_id = t.ag('A03');

-- ===== N. Retrait sans écart =====
INSERT INTO cycle(agence_id,numero,client_id,produit_id,type_cycle,mise_initiale,mise_courante,objectif,date_debut,date_fin)
VALUES (1,'N1',2,1,1,1000,1000,31000,'2026-12-01','2026-12-31');
INSERT INTO ligne_collecte(cycle_id,page,no_ligne,date_collecte,agent_id,montant_collecte)
SELECT t.cy('N1'),1,g,'2026-12-01'::date+g-1,t.ag('A05'),1000 FROM generate_series(1,10) g;
SELECT demander_retrait_cycle(t.cy('N1'),'retrait_client','2026-12-20');
SELECT t.refuse('N exécution sans constat', format('SELECT mf.executer_retrait(%s)', t.re('N1')));
SELECT constater_sans_ecart(t.re('N1'));
SELECT t.refuse('N double constat', format('SELECT mf.constater_sans_ecart(%s)', t.re('N1')));
SELECT executer_retrait(t.re('N1'));
SELECT t.eq('N payé = machine', montant_paye::text || '/' || ecart::text, '9000/0') FROM retrait WHERE id = t.re('N1');

-- ===== M. Machine > livret : excédent à régulariser, surplus réel à la purge =====
INSERT INTO cycle(agence_id,numero,client_id,produit_id,type_cycle,mise_initiale,mise_courante,objectif,date_debut,date_fin)
VALUES (1,'M1',3,1,1,1000,1000,31000,'2026-11-01','2026-11-30');
INSERT INTO ligne_collecte(cycle_id,page,no_ligne,date_collecte,agent_id,montant_collecte)
SELECT t.cy('M1'),1,g,'2026-11-01'::date+g-1,t.ag('A04'),1000 FROM generate_series(1,4) g;
SELECT demander_retrait_cycle(t.cy('M1'),'retrait_client','2026-11-20');
SELECT enregistrer_ecart_retrait(t.re('M1'), 3800, 4000,
  jsonb_build_array(jsonb_build_object('date','2026-11-02','montant',200,'agent_id',t.ag('A04'))));
SELECT t.eq('M fonds disponibles sans traitement', statut, 'fonds_disponibles') FROM retrait WHERE id = t.re('M1');
SELECT t.eq('M excédent à régulariser', statut || '/' || montant::text, 'a_regulariser/200') FROM excedent_regularisation;
SELECT t.eq('M retrait de régularisation sans décaissement', nature || '/' || decaissement::text || '/' || montant::text, 'regularisation/false/200')
  FROM retrait WHERE cycle_id = t.cy('M1') AND nature = 'regularisation';
SELECT t.eq('M aucun surplus réel avant purge', count(*)::text, '1') FROM surplus;   -- seulement celui de la tournée du 3/10
SELECT t.eq('M purge refusée (cycle non retiré)', purger_date(1::smallint,'2026-11-02')::text, 'false');
SELECT executer_retrait(t.re('M1'));
SELECT t.eq('M client payé selon le livret', montant_paye::text, '2800') FROM retrait WHERE id = t.re('M1');
SELECT t.eq('M purge acceptée', purger_date(1::smallint,'2026-11-02')::text, 'true');
SELECT t.eq('M excédent régularisé', statut, 'regularise') FROM excedent_regularisation;
SELECT t.eq('M surplus réel créé', montant::text || '/' || origine, '200/regularisation') FROM surplus WHERE agent_id = t.ag('A04');
SELECT t.eq('M purge déjà faite', purger_date(1::smallint,'2026-11-02')::text, 'false');
SELECT t.eq('M dates purgeables restantes (5 en octobre + 3 en novembre)', purger_dates(1::smallint,'2026-11-30')::text, '8');
SELECT t.eq('M rien de plus à purger', purger_dates(1::smallint,'2026-11-30')::text, '0');

-- ===== V. Versement, retenue sur commission, règlement =====
SELECT enregistrer_versement(t.ag('A05'),'2026-12-05',400);                       -- manquant 600
SELECT t.eq('V solde agent', solde::text, '-600') FROM v_solde_compte_agent WHERE agent_id = t.ag('A05');
SELECT t.eq('V retenue plafonnée à 50 % de 1000', retenue_sur_commission(t.ag('A05'), 1000, '2026-12-31')::text, '500');
SELECT t.eq('V solde après retenue', solde::text, '-100') FROM v_solde_compte_agent WHERE agent_id = t.ag('A05');
SELECT regler_compte_agent(t.ag('A05'), 100, '2027-01-05');
SELECT t.eq('V compte soldé', solde::text, '0') FROM v_solde_compte_agent WHERE agent_id = t.ag('A05');
SELECT t.eq('V retenue sans dette = 0', retenue_sur_commission(t.ag('A05'), 1000, '2027-01-31')::text, '0');
SELECT t.eq('V retenue limitée à la dette (A03 doit 400)', retenue_sur_commission(t.ag('A03'), 5000, '2026-12-31')::text, '400');
