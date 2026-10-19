SET search_path = mf, public;

-- ===== Données de base =====
INSERT INTO agence(code,libelle) VALUES ('LOM','Lomé Centre'),('KPA','Kpalimé');
INSERT INTO zone(agence_id,code,libelle) VALUES (1,'Z1','Zone Marché'),(1,'Z1B','Zone Gare'),(2,'ZK','Zone Kpalimé');
INSERT INTO agent(agence_id,matricule,nom) VALUES (1,'A1','Ama');
INSERT INTO collectrice(agence_id,matricule,nom) VALUES (1,'K1','Kofi'),(1,'K2','Akou');
INSERT INTO affectation_zone(zone_id,collectrice_id,date_debut) VALUES (1,1,'2026-10-01'),(2,2,'2026-10-01');
UPDATE parametre SET valeur = 'date_fin_client' WHERE cle = 'mode_cloture' AND agence_id IS NULL;
INSERT INTO client(agence_id,zone_id,numero,nom) VALUES
  (1,1,'C1','Un'),(1,1,'C2','Deux'),(1,1,'C3','Trois'),(1,1,'C4','Quatre');
INSERT INTO produit_epargne(code,libelle,categorie,type_cycle) VALUES ('P1','Tontine','collecte',1);
INSERT INTO produit_epargne(code,libelle,categorie) VALUES ('CL','Compte classique','classique');

-- ===== A. Historique initial =====
SELECT t.eq('A une ligne d''historique par client', count(*)::text, '4') FROM client_zone_historique;
SELECT t.eq('A zone à une date quelconque', zone_client_a_date(1, '2026-01-01')::text, '1');

-- Collecte du client 1 : 3 lignes en zone 1 (K1), puis transfert en zone 2 (K2) le 10/10, 2 lignes
INSERT INTO cycle(agence_id,numero,client_id,produit_id,type_cycle,mise_initiale,mise_courante,objectif,date_debut,date_fin)
VALUES (1,'CY1',1,1,1,500,500,15500,'2026-10-01','2026-10-31');
INSERT INTO ligne_collecte(cycle_id,page,no_ligne,date_collecte,agent_id,montant_collecte) VALUES
  (1,1,1,'2026-10-02',1,500),(1,1,2,'2026-10-03',1,500),(1,1,3,'2026-10-04',1,500);

-- ===== B. Transfert de zone =====
SELECT transferer_client_zone(1, 2, '2026-10-10', 'déménagement');
INSERT INTO ligne_collecte(cycle_id,page,no_ligne,date_collecte,agent_id,montant_collecte) VALUES
  (1,1,4,'2026-10-12',1,500),(1,1,5,'2026-10-13',1,500);
SELECT t.eq('B zone actuelle', zone_id::text, '2') FROM client WHERE id = 1;
SELECT t.eq('B zone avant le changement', zone_client_a_date(1, '2026-10-09')::text, '1');
SELECT t.eq('B zone le jour du changement', zone_client_a_date(1, '2026-10-10')::text, '2');
SELECT t.eq('B production K1 : seulement ce qui a été collecté en zone 1', production_collectrice(1, '2026-10-01', '2026-10-31')::text, '1500');
SELECT t.eq('B production K2 : seulement ce qui a été collecté en zone 2', production_collectrice(2, '2026-10-01', '2026-10-31')::text, '1000');
SELECT t.eq('B rapport du 03/10 : la collecte est en zone Z1', string_agg(zone || ':' || montant_collecte::text, ' ' ORDER BY zone), 'Z1:500 Z1B:0') FROM rapport_journalier_zone(1::smallint, '2026-10-03');
SELECT t.eq('B rapport du 12/10 : la collecte est en zone Z1B', string_agg(zone || ':' || montant_collecte::text, ' ' ORDER BY zone), 'Z1:0 Z1B:500') FROM rapport_journalier_zone(1::smallint, '2026-10-12');
SELECT t.eq('B journal du transfert', type || ' ' || zone_source_id || '>' || zone_dest_id || ' ' || motif, 'zone 1>2 déménagement') FROM client_transfert WHERE client_id = 1;
SELECT t.refuse('B même zone', 'SELECT mf.transferer_client_zone(1, 2, ''2026-10-15'')');
SELECT t.refuse('B zone d''une autre agence', 'SELECT mf.transferer_client_zone(1, 3, ''2026-10-15'')');
SELECT t.refuse('B date non postérieure au dernier changement', 'SELECT mf.transferer_client_zone(1, 1, ''2026-10-10'')');
SELECT t.refuse('B date dans le futur', format('SELECT mf.transferer_client_zone(1, 1, %L)', (current_date + 1)::text));
SELECT t.refuse('B zone inconnue', 'SELECT mf.transferer_client_zone(1, 99, ''2026-10-15'')');
SELECT t.refuse('B changement direct de zone interdit', 'UPDATE mf.client SET zone_id = 1 WHERE id = 1');
SELECT t.refuse('B changement direct d''agence interdit', 'UPDATE mf.client SET agence_id = 2 WHERE id = 1');
SELECT t.eq('B échecs : un seul transfert enregistré', count(*)::text, '1') FROM client_transfert;

-- ===== C. Transfert d'agence : refus tant qu'une opération est en cours =====
SELECT t.refuse('C cycle de collecte en cours', 'SELECT mf.transferer_client_agence(1, 2::smallint, 3, ''2026-10-15'')');
INSERT INTO credit(agence_id,numero,client_id,type,montant_accorde,taux,date_deblocage,nb_echeances,mode_remboursement)
VALUES (1,'CR-4',4,'sans_epargne',30000,0.12,'2026-10-01',3,'especes');
SELECT generer_echeancier(id) FROM credit WHERE numero = 'CR-4';
SELECT t.refuse('C crédit non soldé', 'SELECT mf.transferer_client_agence(4, 2::smallint, 3, ''2026-10-15'')');
SELECT t.refuse('C même agence', 'SELECT mf.transferer_client_agence(3, 1::smallint)');
SELECT t.refuse('C agence inconnue', 'SELECT mf.transferer_client_agence(3, 9::smallint)');
SELECT t.refuse('C zone d''une autre agence que la destination', 'SELECT mf.transferer_client_agence(3, 2::smallint, 1, ''2026-10-15'')');

-- ===== D. Transfert d'agence d'un client sans opération en cours =====
INSERT INTO compte_epargne(agence_id,client_id,produit_id,numero) VALUES (1,3,2,'CE-3');
INSERT INTO mouvement_epargne(compte_id,type,montant,date_operation) VALUES (1,'depot',100000,'2026-10-05');
SELECT transferer_client_agence(3, 2::smallint, 3, '2026-10-15', 'mutation');
SELECT t.eq('D client déplacé dans la zone de destination', agence_id || '/' || zone_id, '2/3') FROM client WHERE id = 3;
SELECT t.eq('D numéro régénéré dans l''agence d''arrivée', (numero LIKE 'CL-KPA-%')::text, 'true') FROM client WHERE id = 3;
SELECT t.eq('D compte d''épargne déplacé et renuméroté', agence_id || ' ' || (numero LIKE 'CE-KPA-%'), '2 true') FROM compte_epargne WHERE id = 1;
SELECT t.eq('D solde d''épargne intact', solde::text, '100000') FROM v_solde_compte_epargne WHERE compte_id = 1;
SELECT t.eq('D journal : anciens numéros et solde à régler entre agences', ancien_numero || ' ' || solde_epargne || ' ' || (comptes -> 0 ->> 'ancien'), 'C3 100000 CE-3') FROM client_transfert WHERE client_id = 3;
SELECT t.eq('D zone avant la mutation', zone_client_a_date(3, '2026-10-14')::text, '1');
SELECT t.eq('D zone après la mutation', zone_client_a_date(3, '2026-10-15')::text, '3');
INSERT INTO mouvement_epargne(compte_id,type,montant,date_operation) VALUES (1,'depot',500,'2026-10-16');
SELECT t.eq('D le compte fonctionne dans la nouvelle agence', solde::text, '100500') FROM v_solde_compte_epargne WHERE compte_id = 1;
SELECT t.refuse('D nouveau transfert à une date antérieure', 'SELECT mf.transferer_client_agence(3, 1::smallint, 1, ''2026-10-14'')');

-- ===== E. Retour dans la première agence ; piste d'audit =====
SELECT transferer_client_agence(3, 1::smallint, 2, '2026-10-17', 'retour');
SELECT t.eq('E retour : agence et zone', agence_id || '/' || zone_id, '1/2') FROM client WHERE id = 3;
SELECT t.eq('E deux transferts d''agence dans le journal', count(*)::text, '2') FROM client_transfert WHERE client_id = 3 AND type = 'agence';
SELECT t.eq('E transferts tracés dans l''audit', (count(*) >= 3)::text, 'true') FROM audit_log WHERE table_name = 'client_transfert';
