SET search_path = mf, public;

-- Module sous test : 73_reglement_manquant_collecte.sql (règlement des manquants de collecte du contrôle au carnet)
-- Fichiers voisins : tests/test_72_controle_carnet.sql (le contrôle), tests/test_02_ecarts.sql (surplus, compte agent).
INSERT INTO agence(code,libelle) VALUES ('LOM','Lomé Centre');
INSERT INTO zone(agence_id,code,libelle) VALUES (1,'Z1','Zone Marché');
INSERT INTO agent(agence_id,matricule,nom) VALUES (1,'A04','Kossi');
INSERT INTO client(agence_id,zone_id,numero,nom) VALUES (1,1,'C001','Un');
INSERT INTO produit_epargne(code,libelle,categorie,type_cycle,nb_pages_livret) VALUES ('P1','Tontine','collecte',1,1);
INSERT INTO utilisateur(login,nom,role,agence_id) VALUES ('ctrl','Contrôleur','chef_agence',1);
INSERT INTO cycle(agence_id,numero,client_id,produit_id,type_cycle,mise_initiale,mise_courante,objectif,date_debut,date_fin)
VALUES (1,'M1',1,1,1,1000,1000,31000,'2026-10-01','2026-10-31');
INSERT INTO ligne_collecte(cycle_id,page,no_ligne,date_collecte,agent_id,montant_collecte)
SELECT (SELECT id FROM cycle WHERE numero = 'M1'),1,g,'2026-10-01'::date+g-1,(SELECT id FROM agent WHERE matricule = 'A04'),1000
  FROM generate_series(1,5) g;

-- Surplus de versement de l'agent : 100 le 1er octobre, 300 le 2 octobre (total 400)
INSERT INTO surplus(agence_id,agent_id,date_surplus,montant,origine)
VALUES (1,(SELECT id FROM agent WHERE matricule = 'A04'),'2026-10-01',100,'versement'),
       (1,(SELECT id FROM agent WHERE matricule = 'A04'),'2026-10-02',300,'versement');

-- Contrôle au carnet : ligne 3 (3 octobre) à 1 500 pour 1 000 : manquant de 500 ; ligne 4 à 1 200 : manquant de 200 ;
-- ligne 5 à 800 : excédent de 200 (pas un manquant) ; lignes 1 et 2 conformes.
SELECT enregistrer_controle_carnet((SELECT id FROM cycle WHERE numero = 'M1'), (SELECT id FROM utilisateur WHERE login = 'ctrl'), '2026-10-15',
  (SELECT jsonb_agg(jsonb_build_object('ligne_id', id, 'montant_carnet', CASE no_ligne WHEN 3 THEN 1500 WHEN 4 THEN 1200 WHEN 5 THEN 800 ELSE 1000 END))
     FROM ligne_collecte WHERE cycle_id = (SELECT id FROM cycle WHERE numero = 'M1')));

-- Une ligne qui n'est pas un manquant ne se règle pas
SELECT t.refuse('R ligne sans manquant refusée', 'SELECT mf.regler_manquant_collecte((SELECT l.id FROM mf.controle_carnet_ligne l JOIN mf.ligne_collecte c ON c.id = l.ligne_collecte_id WHERE c.no_ligne = 5))');
SELECT t.refuse('R ligne conforme refusée', 'SELECT mf.regler_manquant_collecte((SELECT l.id FROM mf.controle_carnet_ligne l JOIN mf.ligne_collecte c ON c.id = l.ligne_collecte_id WHERE c.no_ligne = 1))');

-- Règlement du contrôle : 500 + 200 = 700 de manquants ; le surplus (400) est consommé entièrement, le reste (300) est imputé
SELECT t.eq('R total imputé à l''agent', regler_manquants_controle((SELECT id FROM controle_carnet ORDER BY id DESC LIMIT 1), '2026-10-16')::text, '300');
SELECT t.eq('R deux règlements', count(*)::text, '2') FROM reglement_manquant_collecte;
SELECT t.eq('R surplus utilisé au total', sum(surplus_utilise)::text, '400') FROM reglement_manquant_collecte;
SELECT t.eq('R manquant de 500 : surplus 400 puis 100 imputé', surplus_utilise::text || '/' || impute_agent::text, '400/100')
  FROM reglement_manquant_collecte r JOIN controle_carnet_ligne l ON l.id = r.controle_ligne_id JOIN ligne_collecte c ON c.id = l.ligne_collecte_id WHERE c.no_ligne = 3;
SELECT t.eq('R manquant de 200 : tout imputé', surplus_utilise::text || '/' || impute_agent::text, '0/200')
  FROM reglement_manquant_collecte r JOIN controle_carnet_ligne l ON l.id = r.controle_ligne_id JOIN ligne_collecte c ON c.id = l.ligne_collecte_id WHERE c.no_ligne = 4;
SELECT t.eq('R surplus du 1er soldé', montant_utilise::text || '/' || statut, '100/solde') FROM surplus WHERE date_surplus = '2026-10-01';
SELECT t.eq('R surplus du 2 soldé', montant_utilise::text || '/' || statut, '300/solde') FROM surplus WHERE date_surplus = '2026-10-02';
SELECT t.eq('R compte agent débité du reste (-300)', solde::text, '-300') FROM v_solde_compte_agent WHERE matricule = 'A04';
SELECT t.eq('R écriture de manquant au compte agent', count(*)::text, '2') FROM compte_agent WHERE type = 'manquant_versement';

-- Pas de double règlement
SELECT t.refuse('R manquant déjà réglé refusé', 'SELECT mf.regler_manquant_collecte((SELECT l.id FROM mf.controle_carnet_ligne l JOIN mf.ligne_collecte c ON c.id = l.ligne_collecte_id WHERE c.no_ligne = 3))');
SELECT t.eq('R relance sans effet', regler_manquants_controle((SELECT id FROM controle_carnet ORDER BY id DESC LIMIT 1), '2026-10-17')::text, '0');
SELECT t.eq('R solde inchangé après relance', solde::text, '-300') FROM v_solde_compte_agent WHERE matricule = 'A04';

-- Sans surplus : le manquant est imputé en totalité
INSERT INTO agent(agence_id,matricule,nom) VALUES (1,'A05','Yao');
INSERT INTO client(agence_id,zone_id,numero,nom) VALUES (1,1,'C002','Deux');
INSERT INTO cycle(agence_id,numero,client_id,produit_id,type_cycle,mise_initiale,mise_courante,objectif,date_debut,date_fin)
VALUES (1,'M2',(SELECT id FROM client WHERE numero = 'C002'),1,1,1000,1000,31000,'2026-10-01','2026-10-31');
INSERT INTO ligne_collecte(cycle_id,page,no_ligne,date_collecte,agent_id,montant_collecte)
SELECT (SELECT id FROM cycle WHERE numero = 'M2'),1,g,'2026-10-01'::date+g-1,(SELECT id FROM agent WHERE matricule = 'A05'),1000
  FROM generate_series(1,2) g;
SELECT enregistrer_controle_carnet((SELECT id FROM cycle WHERE numero = 'M2'), (SELECT id FROM utilisateur WHERE login = 'ctrl'), '2026-10-15',
  (SELECT jsonb_agg(jsonb_build_object('ligne_id', id, 'montant_carnet', CASE no_ligne WHEN 1 THEN 1000 ELSE 1100 END))
     FROM ligne_collecte WHERE cycle_id = (SELECT id FROM cycle WHERE numero = 'M2')));
SELECT t.eq('R sans surplus : imputé en totalité', regler_manquants_controle((SELECT id FROM controle_carnet ORDER BY id DESC LIMIT 1), '2026-10-16')::text, '100');
SELECT t.eq('R solde de l''agent sans surplus (-100)', solde::text, '-100') FROM v_solde_compte_agent WHERE matricule = 'A05';
