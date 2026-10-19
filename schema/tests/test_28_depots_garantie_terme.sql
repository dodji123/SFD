SET search_path = mf, public;

-- Module sous test : 28_depots_garantie_terme.sql (dépôt de garantie, dépôt à terme, déblocage, rupture anticipée)
INSERT INTO agence(code,libelle) VALUES ('LOM','Lomé Centre');
INSERT INTO utilisateur(agence_id,login,nom,role) VALUES (1,'chef','Chef','chef_agence');
INSERT INTO produit_epargne(code,libelle,categorie,solde_minimum) VALUES ('CL','Classique','classique',1000);
INSERT INTO client(agence_id,nom) VALUES (1,'Client un'),(1,'Client deux');
INSERT INTO compte_epargne(agence_id,client_id,produit_id) VALUES (1,1,1),(1,2,1);
INSERT INTO mouvement_epargne(compte_id,type,montant,date_operation) VALUES (1,'depot',500000,current_date - 400);

CREATE FUNCTION pg_temp.dt(n integer) RETURNS integer LANGUAGE sql AS $$ SELECT id FROM mf.depot_terme ORDER BY id OFFSET n - 1 LIMIT 1 $$;   -- n-ième dépôt à terme (les refus consomment des identifiants)

-- ===== A. Dépôt de garantie : bloqué dès l'encaissement =====
SELECT t.eq('A disponible avant : 500000 - 1000', solde_disponible(1)::text, '499000');
SELECT t.refuse('A montant nul', 'SELECT mf.deposer_garantie(1, 0, current_date, ''x'', NULL, 1)');
SELECT t.refuse('A date future', 'SELECT mf.deposer_garantie(1, 1000, current_date + 1, ''x'', NULL, 1)');
SELECT deposer_garantie(1, 100000, current_date, 'garantie du crédit à venir', NULL, 1);
SELECT t.eq('A numéro attribué', numero, 'DG-LOM-' || extract(year FROM current_date) || '-000001') FROM depot_garantie;
SELECT t.eq('A le solde augmente du dépôt', solde::text, '600000') FROM v_solde_compte_epargne WHERE compte_id = 1;
SELECT t.eq('A le disponible ne bouge pas : la garantie est bloquée', solde_disponible(1)::text, '499000');
SELECT t.refuse('A retrait de la somme bloquée refusé', 'INSERT INTO mf.mouvement_epargne(compte_id,type,montant,date_operation) VALUES (1, ''retrait'', 499001, current_date)');

-- ===== B. Déblocage de la garantie =====
INSERT INTO credit(agence_id,numero,client_id,type,montant_accorde,taux,date_deblocage,nb_echeances,mode_remboursement)
VALUES (1,'CR-1',1,'sans_epargne',50000,0.12,current_date - 30,6,'especes');
SELECT t.refuse('B crédit d''un autre client', 'SELECT mf.deposer_garantie(2, 20000, current_date, ''x'', 1, 1)');
SELECT deposer_garantie(1, 20000, current_date, 'garantie du crédit CR-1', 1, 1);
SELECT t.refuse('B déblocage refusé : crédit non soldé', 'SELECT mf.liberer_depot_garantie(2, current_date, 1)');
SELECT t.refuse('B date de déblocage future', 'SELECT mf.liberer_depot_garantie(1, current_date + 1, 1)');
SELECT liberer_depot_garantie(1, current_date, 1);
SELECT t.eq('B garantie libérée', statut, 'libere') FROM depot_garantie WHERE id = 1;
SELECT t.eq('B le disponible retrouve les 100000 libérés (20000 restent bloqués)', solde_disponible(1)::text, '599000');
SELECT t.refuse('B double libération', 'SELECT mf.liberer_depot_garantie(1, current_date, 1)');
UPDATE credit SET statut = 'solde', date_solde = current_date WHERE id = 1;
SELECT liberer_depot_garantie(2, current_date, 1);
SELECT t.eq('B libération permise une fois le crédit soldé', statut, 'libere') FROM depot_garantie WHERE id = 2;
SELECT t.refuse('B crédit soldé : plus de garantie', 'SELECT mf.deposer_garantie(1, 5000, current_date, ''x'', 1, 1)');

-- ===== C. Dépôt à terme =====
SELECT t.refuse('C montant sous le minimum', 'SELECT mf.placer_depot_terme(1, 10000, 6, current_date, NULL, 1)');
SELECT t.refuse('C durée sous le minimum', 'SELECT mf.placer_depot_terme(1, 100000, 1, current_date, NULL, 1)');
SELECT t.refuse('C fonds insuffisants', 'SELECT mf.placer_depot_terme(2, 100000, 6, current_date, NULL, 1)');
SELECT t.eq('C rien n''a été enregistré par les refus', count(*)::text, '0') FROM depot_terme;
SELECT placer_depot_terme(1, 120000, 6, current_date - 200, NULL, 1);
SELECT t.eq('C échéance à 6 mois, intérêts 4 % : 120000 x 0.04 x 6/12 = 2400', (date_echeance - date_depot > 150 AND date_echeance - date_depot < 190 AND interets_prevus = 2400 AND taux_annuel = 0.04 AND numero LIKE 'DT-LOM-%')::text, 'true') FROM depot_terme;
SELECT t.eq('C le capital sort du compte (620000 - 120000)', solde::text, '500000') FROM v_solde_compte_epargne WHERE compte_id = 1;
SELECT t.eq('C placement dans le mouvement', type || '/' || montant, 'virement_sortant/120000') FROM mouvement_epargne WHERE reference = 'depot_terme:' || pg_temp.dt(1);

-- ===== D. Déblocage à l'échéance (le placement date de 200 jours : échu) =====
SELECT t.refuse('D rupture d''un dépôt échu', 'SELECT mf.rompre_depot_terme(' || pg_temp.dt(1) || ', current_date, 1)');
SELECT t.eq('D intérêts versés', debloquer_depot_terme(pg_temp.dt(1), current_date, 1)::text, '2400');
SELECT t.eq('D capital et intérêts rendus au compte', solde::text, '622400') FROM v_solde_compte_epargne WHERE compte_id = 1;
SELECT t.eq('D dépôt soldé', statut || '/' || interets_verses, 'verse/2400') FROM depot_terme WHERE id = pg_temp.dt(1);
SELECT t.refuse('D double déblocage', 'SELECT mf.debloquer_depot_terme(' || pg_temp.dt(1) || ', current_date, 1)');

-- ===== E. Rupture anticipée : pénalité 100 % par défaut, puis 50 % =====
SELECT placer_depot_terme(1, 100000, 12, current_date - 30, 0.06, 1);
SELECT t.refuse('E déblocage avant l''échéance', 'SELECT mf.debloquer_depot_terme(' || pg_temp.dt(2) || ', current_date, 1)');
SELECT t.eq('E rupture : pénalité 100 % = aucun intérêt', rompre_depot_terme(pg_temp.dt(2), current_date, 1)::text, '0');
SELECT t.eq('E dépôt rompu, capital rendu', statut || '/' || interets_verses, 'rompu/0') FROM depot_terme WHERE id = pg_temp.dt(2);
UPDATE parametre SET valeur = '50' WHERE cle = 'dat_penalite_rupture_pct';
SELECT placer_depot_terme(1, 100000, 12, current_date - 73, 0.06, 1);   -- intérêts prévus 6000 sur 365 jours : 73 jours courus = 1200, moitié = 600
SELECT t.eq('E pénalité 50 % : intérêts courus au prorata', rompre_depot_terme(pg_temp.dt(3), current_date, 1)::text, '600');
SELECT t.eq('E taux saisi conservé', taux_annuel::text, '0.06000') FROM depot_terme WHERE id = pg_temp.dt(3);

-- ===== F. Sortie du compte refusée tant qu'un dépôt est en cours =====
INSERT INTO adhesion(agence_id,client_id,compte_id,date_adhesion,droit_adhesion) VALUES (1,2,2,current_date - 10,2000);
SELECT souscrire_parts_compte(2, 1, current_date - 10, 1);
INSERT INTO mouvement_epargne(compte_id,type,montant,date_operation) VALUES (2,'depot',60000,current_date - 5);
SELECT deposer_garantie(2, 5000, current_date, 'garantie', NULL, 1);
SELECT t.refuse('F sortie refusée : garantie bloquée (et solde)', 'SELECT mf.radier_adhesion_compte(2, current_date, 1)');
SELECT placer_depot_terme(2, 55000, 6, current_date - 20, NULL, 1);
SELECT t.eq('F un dépôt à terme en cours est détecté', (SELECT count(*) FROM depot_terme WHERE compte_id = 2 AND statut = 'en_cours')::text, '1');
