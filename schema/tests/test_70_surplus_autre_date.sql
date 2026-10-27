SET search_path = mf, public;

-- aides locales (ids de séquence non stables)
CREATE OR REPLACE FUNCTION t.cy(p_numero text) RETURNS integer LANGUAGE sql AS $$ SELECT id FROM mf.cycle WHERE numero = p_numero $$;
CREATE OR REPLACE FUNCTION t.ag(p_matricule text) RETURNS integer LANGUAGE sql AS $$ SELECT id FROM mf.agent WHERE matricule = p_matricule $$;
CREATE OR REPLACE FUNCTION t.re(p_cycle text) RETURNS integer LANGUAGE sql AS $$
  SELECT id FROM mf.retrait WHERE cycle_id = t.cy(p_cycle) AND nature <> 'regularisation' $$;

-- ===== Données : un agent, un cycle de 5 collectes de 1 000 F (1er au 5 octobre), mise 1 000 F =====
INSERT INTO agence(code,libelle) VALUES ('LOM','Lomé Centre');
INSERT INTO zone(agence_id,code,libelle) VALUES (1,'Z1','Zone Marché');
INSERT INTO agent(agence_id,matricule,nom) VALUES (1,'A04','Kossi');
INSERT INTO client(agence_id,zone_id,numero,nom) VALUES (1,1,'C001','Un');
INSERT INTO produit_epargne(code,libelle,categorie,type_cycle,nb_pages_livret) VALUES ('P1','Tontine','collecte',1,1);
INSERT INTO utilisateur(login,nom,role,agence_id) VALUES ('chef','Chef d''agence','chef_agence',1),('caissier','Caissier','caissier',1);
INSERT INTO cycle(agence_id,numero,client_id,produit_id,type_cycle,mise_initiale,mise_courante,objectif,date_debut,date_fin)
VALUES (1,'V1',1,1,1,1000,1000,31000,'2026-10-01','2026-10-31');
INSERT INTO ligne_collecte(cycle_id,page,no_ligne,date_collecte,agent_id,montant_collecte)
SELECT t.cy('V1'),1,g,'2026-10-01'::date+g-1,t.ag('A04'),1000 FROM generate_series(1,5) g;

-- Versements : exacts sauf le 5 octobre (surplus de 400 sur une autre date que l'écart)
SELECT enregistrer_versement(t.ag('A04'),'2026-10-01',1000);
SELECT enregistrer_versement(t.ag('A04'),'2026-10-02',1000);
SELECT enregistrer_versement(t.ag('A04'),'2026-10-03',1000);
SELECT enregistrer_versement(t.ag('A04'),'2026-10-04',1000);
SELECT enregistrer_versement(t.ag('A04'),'2026-10-05',1400);
SELECT t.eq('V surplus du 5 octobre = 400', montant::text, '400') FROM surplus WHERE agent_id = t.ag('A04');

-- Retrait : net machine 4 000 ; livret 4 500 (écart 500) rattaché au 3 octobre, où il n'y a pas de surplus
SELECT demander_retrait_cycle(t.cy('V1'),'retrait_client','2026-10-10');
SELECT enregistrer_ecart_retrait(t.re('V1'), 5500, 5000,
  jsonb_build_array(jsonb_build_object('date','2026-10-03','montant',500,'agent_id',t.ag('A04'))));

-- Un surplus de la même date existe, déjà soldé : il ne sert pas au règlement par validation
INSERT INTO surplus(agence_id,agent_id,date_surplus,montant,montant_utilise,origine,statut)
VALUES (1,t.ag('A04'),'2026-10-03',100,100,'versement','solde');

-- ===== Validation : seul le chef d'agence peut autoriser =====
SELECT t.refuse('V validation par un caissier refusée', 'SELECT mf.valider_surplus_autre_date((SELECT id FROM mf.ecart_retrait_date WHERE date_ecart = ''2026-10-03''), (SELECT id FROM mf.surplus WHERE date_surplus = ''2026-10-05''), 400, (SELECT id FROM mf.utilisateur WHERE login = ''caissier''), ''motif valable'')');
SELECT t.refuse('V validation sans motif refusée', 'SELECT mf.valider_surplus_autre_date((SELECT id FROM mf.ecart_retrait_date WHERE date_ecart = ''2026-10-03''), (SELECT id FROM mf.surplus WHERE date_surplus = ''2026-10-05''), 400, (SELECT id FROM mf.utilisateur WHERE login = ''chef''), ''ok'')');
SELECT t.refuse('V montant supérieur au surplus disponible', 'SELECT mf.valider_surplus_autre_date((SELECT id FROM mf.ecart_retrait_date WHERE date_ecart = ''2026-10-03''), (SELECT id FROM mf.surplus WHERE date_surplus = ''2026-10-05''), 450, (SELECT id FROM mf.utilisateur WHERE login = ''chef''), ''montant trop fort'')');
SELECT t.refuse('V surplus de la même date : pas de validation', 'SELECT mf.valider_surplus_autre_date((SELECT id FROM mf.ecart_retrait_date WHERE date_ecart = ''2026-10-03''), (SELECT id FROM mf.surplus WHERE date_surplus = ''2026-10-03''), 100, (SELECT id FROM mf.utilisateur WHERE login = ''chef''), ''meme date'')');
SELECT t.eq('V aucune validation enregistrée par les refus', count(*)::text, '0') FROM validation_surplus_autre_date;

SELECT valider_surplus_autre_date((SELECT id FROM ecart_retrait_date WHERE date_ecart = '2026-10-03'),
  (SELECT id FROM surplus WHERE date_surplus = '2026-10-05'), 400, (SELECT id FROM utilisateur WHERE login = 'chef'),
  'surplus du 5 autorisé par le chef');
SELECT t.eq('V validation enregistrée au nom du chef', valide_par::text, (SELECT id::text FROM utilisateur WHERE login = 'chef')) FROM validation_surplus_autre_date;

-- ===== Traitement : le surplus validé règle 400, la perte résiduelle est de 100 =====
SELECT t.eq('V perte après surplus validé (500 - 400)', traiter_ecart_retrait((SELECT id FROM ecart_retrait WHERE cycle_id = t.cy('V1')))::text, '100');
SELECT t.eq('V surplus du 5 octobre consommé', montant_utilise::text || '/' || statut, '400/solde') FROM surplus WHERE date_surplus = '2026-10-05';
SELECT t.eq('V validation consommée', consomme::text, '400') FROM validation_surplus_autre_date;
SELECT t.eq('V détail du 3 octobre : surplus 400, perte 100', surplus_utilise::text || '/' || perte::text, '400/100') FROM ecart_retrait_date WHERE date_ecart = '2026-10-03';
SELECT t.eq('V perte au compte de l''agent', montant::text, '100') FROM compte_agent WHERE type = 'perte_retrait';

-- ===== Après traitement : plus de validation, une validation ne se supprime pas =====
SELECT t.refuse('V validation après traitement refusée', 'SELECT mf.valider_surplus_autre_date((SELECT id FROM mf.ecart_retrait_date WHERE date_ecart = ''2026-10-03''), (SELECT id FROM mf.surplus WHERE date_surplus = ''2026-10-05''), 50, (SELECT id FROM mf.utilisateur WHERE login = ''chef''), ''trop tard'')');
SELECT t.refuse('V validation non supprimable', 'DELETE FROM mf.validation_surplus_autre_date');
