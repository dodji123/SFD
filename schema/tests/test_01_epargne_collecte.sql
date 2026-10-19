SET search_path = mf, public;

-- ===== Données de base (agences 1 et 2) =====
INSERT INTO agence(code,libelle) VALUES ('LOM','Lomé Centre'),('KPA','Kpalimé');
INSERT INTO zone(agence_id,code,libelle) VALUES (1,'Z1','Zone Marché'),(2,'Z2','Zone Kpalimé');
INSERT INTO agent(agence_id,matricule,nom) VALUES (1,'A01','Ama'),(2,'A02','Kossi');
INSERT INTO client(agence_id,zone_id,numero,nom) VALUES
  (1,1,'C001','Client Un'),(1,1,'C002','Client Deux'),(2,2,'C101','Client Kpalimé');
INSERT INTO produit_epargne(code,libelle,categorie,type_cycle,nb_pages_livret) VALUES
  ('P1','Tontine normale','collecte',1,1),('P2','Tontine durée','collecte',2,1),('P3','Tontine libre','collecte',3,1);
INSERT INTO produit_epargne(code,libelle,categorie,taux_interet,solde_minimum) VALUES ('CL','Compte classique','classique',0.02,5000);
INSERT INTO compte_epargne(agence_id,client_id,produit_id,numero) VALUES (1,1,4,'CE001');

-- ===== A. Épargne classique : solde, disponible, refus de sortie =====
INSERT INTO mouvement_epargne(compte_id,type,montant) VALUES (1,'depot',100000);
SELECT t.eq('A solde', (SELECT solde FROM v_solde_compte_epargne WHERE compte_id=1)::text, '100000');
SELECT t.eq('A disponible (solde - minimum 5000)', solde_disponible(1)::text, '95000');
SELECT t.refuse('A retrait > disponible', 'INSERT INTO mouvement_epargne(compte_id,type,montant) VALUES (1,''retrait'',95001)');
SELECT t.refuse('A type inconnu', 'INSERT INTO mouvement_epargne(compte_id,type,montant) VALUES (1,''xyz'',10)');
INSERT INTO mouvement_epargne(compte_id,type,montant) VALUES (1,'retrait',95000);
SELECT t.eq('A disponible après retrait', solde_disponible(1)::text, '0');

-- ===== B. Cycle type 1 : prévisionnel, reste, net =====
INSERT INTO cycle(agence_id,numero,client_id,produit_id,type_cycle,mise_initiale,mise_courante,objectif,date_debut,date_fin)
VALUES (1,'CY1',1,1,1,500,500,15500,'2026-10-01','2026-10-31');
INSERT INTO ligne_collecte(cycle_id,page,no_ligne,date_collecte,agent_id,montant_collecte)
SELECT 1,1,g,'2026-10-01'::date+g-1,1,500 FROM generate_series(1,6) g;
SELECT t.eq('B collecté',     montant_collecte::text,      '3000')  FROM v_cycle_situation WHERE cycle_id=1;
SELECT t.eq('B prévisionnel', montant_previsionnel::text,  '15500') FROM v_cycle_situation WHERE cycle_id=1;
SELECT t.eq('B reste',        reste_a_collecter::text,     '12500') FROM v_cycle_situation WHERE cycle_id=1;
SELECT t.eq('B net (collecté - mise)', net::text,          '2500')  FROM v_cycle_situation WHERE cycle_id=1;
SELECT t.eq('B mise appliquée par défaut', min(mise_appliquee)::text, '500') FROM ligne_collecte WHERE cycle_id=1;

-- ===== C. Changement de mise : le passé n'est pas faussé =====
SELECT t.refuse('C changement sur une date déjà saisie', 'SELECT mf.changer_mise(1, 1000, ''2026-10-03'')');
SELECT changer_mise(1, 1000, '2026-10-07', 'hausse');
INSERT INTO ligne_collecte(cycle_id,page,no_ligne,date_collecte,agent_id,montant_collecte)
VALUES (1,1,7,'2026-10-07',1,1000);
SELECT t.eq('C mise ligne 7', mise_appliquee::text, '1000') FROM ligne_collecte WHERE cycle_id=1 AND no_ligne=7;
SELECT t.eq('C mise ligne 1 inchangée', mise_appliquee::text, '500') FROM ligne_collecte WHERE cycle_id=1 AND no_ligne=1;
SELECT t.eq('C prévisionnel (6x500 + 1x1000 + 24x1000)', montant_previsionnel::text, '28000') FROM v_cycle_situation WHERE cycle_id=1;
SELECT t.eq('C historique', count(*)::text, '2') FROM cycle_mise_historique WHERE cycle_id=1;

-- ===== D. Livret : 31 lignes par page =====
SELECT t.refuse('D ligne en double', 'INSERT INTO mf.ligne_collecte(cycle_id,page,no_ligne,date_collecte,agent_id,montant_collecte) VALUES (1,1,7,''2026-10-08'',1,1000)');
SELECT t.refuse('D no_ligne 32', 'INSERT INTO mf.ligne_collecte(cycle_id,page,no_ligne,date_collecte,agent_id,montant_collecte) VALUES (1,1,32,''2026-10-08'',1,1000)');
SELECT t.refuse('D page 2 sur livret d''une page', 'INSERT INTO mf.ligne_collecte(cycle_id,page,no_ligne,date_collecte,agent_id,montant_collecte) VALUES (1,2,1,''2026-10-08'',1,1000)');
SELECT t.refuse('D collecte sans agent', 'INSERT INTO mf.ligne_collecte(cycle_id,page,no_ligne,date_collecte,montant_collecte) VALUES (1,1,8,''2026-10-08'',1000)');
SELECT t.refuse('D agent d''une autre agence', 'INSERT INTO mf.ligne_collecte(cycle_id,page,no_ligne,date_collecte,agent_id,montant_collecte) VALUES (1,1,8,''2026-10-08'',2,1000)');
SELECT t.refuse('D date avant le début du cycle', 'INSERT INTO mf.ligne_collecte(cycle_id,page,no_ligne,date_collecte,agent_id,montant_collecte) VALUES (1,1,8,''2026-09-30'',1,1000)');
INSERT INTO ligne_collecte(cycle_id,page,no_ligne,date_collecte,origine,montant_collecte)
VALUES (1,1,8,'2026-10-08','virement',1000);   -- ligne de virement : sans agent
SELECT t.eq('D ligne virement sans agent', count(*)::text, '1') FROM ligne_collecte WHERE cycle_id=1 AND origine='virement' AND agent_id IS NULL;

-- ===== F. Type 3 : mise finale = max(arrondi(total/31), mise initiale) =====
INSERT INTO cycle(agence_id,numero,client_id,produit_id,type_cycle,mise_initiale,mise_courante,date_debut,date_fin)
VALUES (1,'CY3A',1,3,3,500,500,'2026-10-01','2026-10-31'),
       (1,'CY3B',2,3,3,500,500,'2026-10-01','2026-10-31');
INSERT INTO ligne_collecte(cycle_id,page,no_ligne,date_collecte,agent_id,montant_collecte) VALUES
  (2,1,1,'2026-10-02',1,7000),(2,1,2,'2026-10-09',1,13000);      -- total 20000 -> 645,16 -> 650
INSERT INTO ligne_collecte(cycle_id,page,no_ligne,date_collecte,agent_id,montant_collecte) VALUES
  (3,1,1,'2026-10-02',1,4000),(3,1,2,'2026-10-09',1,6000);       -- total 10000 -> 322,58 -> 325 < 500 -> 500
SELECT t.eq('F prévisionnel type 3 absent', coalesce(montant_previsionnel::text,'NULL'), 'NULL') FROM v_cycle_situation WHERE cycle_id=2;
SELECT t.eq('F mise finale 20000/31', cloturer_cycle(2,'2026-10-31')::text, '650');
SELECT t.eq('F mise finale plancher mise initiale', cloturer_cycle(3,'2026-10-31')::text, '500');
SELECT t.eq('F net type 3 (20000 - 650)', net::text, '19350') FROM v_cycle_situation WHERE cycle_id=2;
SELECT t.refuse('F cycle déjà clos', 'SELECT mf.cloturer_cycle(2)');
SELECT t.refuse('F saisie sur cycle clos', 'INSERT INTO mf.ligne_collecte(cycle_id,page,no_ligne,date_collecte,agent_id,montant_collecte) VALUES (2,1,3,''2026-10-31'',1,500)');
SELECT t.refuse('F changement de mise sur type 3', 'SELECT mf.changer_mise(2, 700)');

-- ===== G. Arrondi paramétrable =====
SELECT t.eq('G plus proche 310', arrondir(310)::text, '300');
INSERT INTO parametre(agence_id,cle,valeur) VALUES (2,'arrondi_mode','superieur');
SELECT t.eq('G supérieur 310 (agence 2)', arrondir(310, 2::smallint)::text, '325');
SELECT t.eq('G agence 1 inchangée', arrondir(310, 1::smallint)::text, '300');
UPDATE parametre SET valeur='inferieur' WHERE agence_id=2 AND cle='arrondi_mode';
SELECT t.eq('G inférieur 340 (agence 2)', arrondir(340, 2::smallint)::text, '325');

-- ===== H. Clôture planifiée : date de fin ou objectif atteint (type 1) =====
INSERT INTO cycle(agence_id,numero,client_id,produit_id,type_cycle,mise_initiale,mise_courante,objectif,date_debut,date_fin)
VALUES (1,'CY-OBJ',2,1,1,1000,1000,3000,'2026-11-01','2026-11-30'),
       (1,'CY-FIN',1,2,2,1000,1000,31000,'2026-09-01','2026-09-30');
INSERT INTO ligne_collecte(cycle_id,page,no_ligne,date_collecte,agent_id,montant_collecte)
SELECT 4,1,g,'2026-11-01'::date+g-1,1,1000 FROM generate_series(1,3) g;   -- objectif atteint avant la date de fin
SELECT t.eq('H cycles clos par la tâche (objectif atteint + fin dépassée + CY1 échu)', cloturer_cycles_echus(1::smallint,'2026-11-05')::text, '3');
SELECT t.eq('H statut CY-OBJ', statut, 'clos') FROM cycle WHERE numero='CY-OBJ';
SELECT t.eq('H statut CY-FIN', statut, 'clos') FROM cycle WHERE numero='CY-FIN';
SELECT t.eq('H date de clôture', date_cloture::text, '2026-11-05') FROM cycle WHERE numero='CY-OBJ';

-- ===== I. Demande de retrait par cycle =====
INSERT INTO cycle(agence_id,numero,client_id,produit_id,type_cycle,mise_initiale,mise_courante,objectif,date_debut,date_fin)
VALUES (1,'CY-RET',1,1,1,1000,1000,31000,'2026-12-01','2026-12-31');
INSERT INTO ligne_collecte(cycle_id,page,no_ligne,date_collecte,agent_id,montant_collecte)
SELECT 6,1,g,'2026-12-01'::date+g-1,1,1000 FROM generate_series(1,10) g;
SELECT demander_retrait_cycle(6,'retrait_client','2026-12-20');
SELECT t.eq('I montant = collecté - mise', montant::text, '9000') FROM retrait WHERE cycle_id=6;
SELECT t.eq('I décaissement client', decaissement::text, 'true') FROM retrait WHERE cycle_id=6;
SELECT t.eq('I statut demande', statut, 'demande') FROM retrait WHERE cycle_id=6;
SELECT t.eq('I cycle clôturé par la demande', statut, 'clos') FROM cycle WHERE id=6;
SELECT t.refuse('I deuxième retrait sur le même cycle', 'SELECT mf.demander_retrait_cycle(6)');

-- ===== J. Production d'une collectrice (agence 2, zone Z2) =====
INSERT INTO collectrice(agence_id,matricule,nom) VALUES (2,'K9','Akou');
INSERT INTO affectation_zone(zone_id,collectrice_id,date_debut) VALUES (2,1,'2026-01-01');
INSERT INTO cycle(agence_id,numero,client_id,produit_id,type_cycle,mise_initiale,mise_courante,objectif,date_debut,date_fin)
VALUES (2,'CY-PROD',3,1,1,1000,1000,31000,'2026-10-01','2026-10-31');
INSERT INTO ligne_collecte(cycle_id,page,no_ligne,date_collecte,agent_id,montant_collecte)
SELECT 7,1,g,'2026-10-01'::date+g-1,2,1000 FROM generate_series(1,3) g;
SELECT t.eq('J calendaire : cycle non clos, rien compté', production_collectrice(1,'2026-10-01','2026-10-31')::text, '0');
SELECT cloturer_cycle(7,'2026-10-31');
SELECT t.eq('J calendaire : après clôture', production_collectrice(1,'2026-10-01','2026-10-31')::text, '3000');
SELECT t.eq('J calendaire : hors période', production_collectrice(1,'2026-11-01','2026-11-30')::text, '0');
INSERT INTO parametre(agence_id,cle,valeur) VALUES (2,'mode_cloture','date_fin_client');
SELECT t.eq('J au fil des collectes, 1er-2 oct', production_collectrice(1,'2026-10-01','2026-10-02')::text, '2000');

-- (en fin de fichier : un INSERT refusé consomme un id de séquence et décalerait les cycles ci-dessus)
-- ===== E. Cohérence cycle / produit / client =====
SELECT t.refuse('E type 1 sur produit de type 3', 'INSERT INTO mf.cycle(agence_id,numero,client_id,produit_id,type_cycle,mise_initiale,mise_courante,date_debut,date_fin) VALUES (1,''X1'',1,3,1,500,500,''2026-10-01'',''2026-10-31'')');
SELECT t.refuse('E produit classique', 'INSERT INTO mf.cycle(agence_id,numero,client_id,produit_id,type_cycle,mise_initiale,mise_courante,date_debut,date_fin) VALUES (1,''X2'',1,4,1,500,500,''2026-10-01'',''2026-10-31'')');
SELECT t.refuse('E client d''une autre agence', 'INSERT INTO mf.cycle(agence_id,numero,client_id,produit_id,type_cycle,mise_initiale,mise_courante,date_debut,date_fin) VALUES (1,''X3'',3,1,1,500,500,''2026-10-01'',''2026-10-31'')');

