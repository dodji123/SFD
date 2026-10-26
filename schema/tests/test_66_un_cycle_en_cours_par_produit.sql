SET search_path = mf, public;

-- Module sous test : 66_un_cycle_en_cours_par_produit.sql (un seul cycle en cours par client et par produit)
INSERT INTO agence(code,libelle) VALUES ('LOM','Lomé Centre');
INSERT INTO zone(agence_id,code,libelle) VALUES (1,'Z1','Zone Marché');
INSERT INTO client(agence_id,zone_id,numero,nom) VALUES (1,1,'C001','Un');
INSERT INTO produit_epargne(code,libelle,categorie,type_cycle,nb_pages_livret) VALUES ('P1','Tontine 1','collecte',1,1),('P2','Tontine 2','collecte',1,1);

-- un premier cycle en cours pour le produit P1
INSERT INTO cycle(agence_id,numero,client_id,produit_id,type_cycle,mise_initiale,mise_courante,objectif,date_debut,date_fin)
VALUES (1,'Q1',1,1,1,1000,1000,31000,'2026-10-01','2026-10-31');

-- même client, même produit, cycle en cours : refusé
SELECT t.refuse('second cycle en cours pour le même produit refusé',
  'INSERT INTO mf.cycle(agence_id,numero,client_id,produit_id,type_cycle,mise_initiale,mise_courante,objectif,date_debut,date_fin) VALUES (1,''Q2'',1,1,1,1000,1000,31000,''2026-11-01'',''2026-11-30'')');

-- même client, autre produit : accepté
INSERT INTO cycle(agence_id,numero,client_id,produit_id,type_cycle,mise_initiale,mise_courante,objectif,date_debut,date_fin)
VALUES (1,'Q3',1,2,1,1000,1000,31000,'2026-11-01','2026-11-30');
SELECT t.eq('autre produit accepté pour le même client', count(*)::text, '2') FROM cycle WHERE numero IN ('Q1','Q3');

-- un cycle clôturé ne compte pas : il n'empêche pas un nouveau cycle en cours sur P1
INSERT INTO cycle(agence_id,numero,client_id,produit_id,type_cycle,mise_initiale,mise_courante,objectif,date_debut,date_fin,statut,date_cloture)
VALUES (1,'Q4',1,1,1,1000,1000,31000,'2026-01-01','2026-01-31','clos','2026-01-31');
SELECT t.eq('cycle clôturé n''empêche pas un nouveau cycle en cours', count(*)::text, '1') FROM cycle WHERE numero = 'Q4' AND statut = 'clos';
