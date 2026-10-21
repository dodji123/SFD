SET search_path = mf, public;

-- Module sous test : 44_cycles_souplesse.sql (type à la première mise, délai de grâce, prolongation, suppressions tracées)
INSERT INTO agence(code,libelle) VALUES ('LOM','Lomé Centre');
INSERT INTO agent(agence_id,matricule,nom) VALUES (1,'A01','Agent un');
INSERT INTO client(agence_id,nom) VALUES (1,'Cliente un'),(1,'Cliente deux');
INSERT INTO utilisateur(login,nom,role,agence_id) VALUES ('chef','Chef','chef_agence',1),('cais','Caissier','caissier',1);
-- produit de tontine SANS type imposé
INSERT INTO produit_epargne(code,libelle,categorie) VALUES ('TON','Tontine souple','collecte');
INSERT INTO produit_epargne(code,libelle,categorie,type_cycle) VALUES ('TON1','Tontine type 1 imposé','collecte',1);

-- ===== A. Type de cycle choisi à la première mise =====
SELECT t.refuse('A épargne classique avec un type de cycle', 'INSERT INTO mf.produit_epargne(code,libelle,categorie,type_cycle) VALUES (''CL'',''Classique'',''classique'',1)');
INSERT INTO cycle(agence_id,numero,client_id,produit_id,type_cycle,mise_initiale,mise_courante,objectif,date_debut,date_fin)
  VALUES (1,'CY-1',1,1,2,1000,1000,31000,'2026-10-01','2026-10-31');
SELECT t.eq('A première mise : type 2 choisi', type_cycle::text, '2') FROM cycle WHERE numero = 'CY-1';
UPDATE cycle SET statut = 'clos', date_cloture = '2026-10-31', mise_finale = 1000 WHERE numero = 'CY-1';
SELECT t.refuse('A le type reste celui de la première mise', 'INSERT INTO mf.cycle(agence_id,numero,client_id,produit_id,type_cycle,mise_initiale,mise_courante,date_debut,date_fin) VALUES (1,''CY-2'',1,1,3,1000,1000,''2026-11-01'',''2026-11-30'')');
INSERT INTO cycle(agence_id,numero,client_id,produit_id,type_cycle,mise_initiale,mise_courante,objectif,date_debut,date_fin)
  VALUES (1,'CY-3',1,1,2,2000,2000,62000,'2026-11-01','2026-11-30');
INSERT INTO cycle(agence_id,numero,client_id,produit_id,type_cycle,mise_initiale,mise_courante,date_debut,date_fin)
  VALUES (1,'CY-4',2,1,3,1000,1000,'2026-11-01','2026-11-30');
SELECT t.eq('A un autre client choisit librement : type 3', type_cycle::text, '3') FROM cycle WHERE numero = 'CY-4';
SELECT t.refuse('A produit à type imposé : le type du produit prévaut', 'INSERT INTO mf.cycle(agence_id,numero,client_id,produit_id,type_cycle,mise_initiale,mise_courante,date_debut,date_fin) VALUES (1,''CY-5'',2,2,2,1000,1000,''2026-11-01'',''2026-11-30'')');

-- ===== B. Délai de grâce =====
UPDATE produit_epargne SET delai_grace_jours = 5 WHERE code = 'TON';
SELECT t.eq('B grâce du produit', delai_grace_cycle((SELECT id FROM cycle WHERE numero = 'CY-3'))::text, '5');
SELECT t.eq('B date limite = fin + grâce', date_limite_cycle((SELECT id FROM cycle WHERE numero = 'CY-3'))::text, '2026-12-05');
INSERT INTO ligne_collecte(cycle_id,page,no_ligne,date_collecte,agent_id,montant_collecte) SELECT id,1,1,'2026-12-04',1,2000 FROM cycle WHERE numero = 'CY-3';
SELECT t.eq('B saisie acceptée dans le délai de grâce', count(*)::text, '1') FROM ligne_collecte;
SELECT t.refuse('B saisie refusée après fin + grâce', 'INSERT INTO mf.ligne_collecte(cycle_id,page,no_ligne,date_collecte,agent_id,montant_collecte) SELECT id,1,2,''2026-12-06'',1,2000 FROM mf.cycle WHERE numero = ''CY-3''');
SELECT t.eq('B pas de clôture automatique pendant la grâce', cloturer_cycles_echus(1::smallint, '2026-12-03')::text, '0');
SELECT t.eq('B clôture automatique après fin + grâce', cloturer_cycles_echus(1::smallint, '2026-12-06')::text, '2');
SELECT t.refuse('B grâce hors bornes', 'UPDATE mf.produit_epargne SET delai_grace_jours = 120 WHERE code = ''TON''');
UPDATE produit_epargne SET delai_grace_jours = NULL WHERE code = 'TON';
INSERT INTO parametre(cle, valeur, agence_id, description) VALUES ('cycle_delai_grace_jours', '2', 1, 'grâce agence');
SELECT t.eq('B grâce par défaut : paramètre de l''agence', delai_grace_cycle((SELECT id FROM cycle WHERE numero = 'CY-3'))::text, '2');

-- ===== C. Prolongation avec autorisation =====
INSERT INTO cycle(agence_id,numero,client_id,produit_id,type_cycle,mise_initiale,mise_courante,objectif,date_debut,date_fin)
  VALUES (1,'CY-6',2,1,3,1000,1000,NULL,'2026-12-01','2026-12-31');
SELECT t.refuse('C prolongation sans motif', 'INSERT INTO mf.prolongation_cycle(cycle_id,ancienne_fin,nouvelle_fin,motif) SELECT id,date_fin,date_fin+10,''court'' FROM mf.cycle WHERE numero = ''CY-6''');
SELECT t.refuse('C prolongation trop longue (> 60 jours)', 'INSERT INTO mf.prolongation_cycle(cycle_id,ancienne_fin,nouvelle_fin,motif) SELECT id,date_fin,date_fin+90,''Retard de livraison de la clientèle'' FROM mf.cycle WHERE numero = ''CY-6''');
SELECT t.refuse('C cycle clos non prolongeable', 'INSERT INTO mf.prolongation_cycle(cycle_id,ancienne_fin,nouvelle_fin,motif) SELECT id,date_fin,date_fin+10,''Retard de livraison de la clientèle'' FROM mf.cycle WHERE numero = ''CY-3''');
INSERT INTO prolongation_cycle(cycle_id,ancienne_fin,nouvelle_fin,motif,demande_par)
  SELECT id,date_fin,date_fin+15,'Cliente malade, collecte reportée',(SELECT id FROM utilisateur WHERE login='cais') FROM cycle WHERE numero = 'CY-6';
SELECT t.eq('C date de fin du cycle au moment de la demande', ancienne_fin::text, '2026-12-31') FROM prolongation_cycle;
SELECT t.refuse('C une seule demande en attente', 'INSERT INTO mf.prolongation_cycle(cycle_id,ancienne_fin,nouvelle_fin,motif) SELECT id,date_fin,date_fin+5,''Deuxième demande simultanée'' FROM mf.cycle WHERE numero = ''CY-6''');
SELECT t.refuse('C le demandeur n''autorise pas', 'UPDATE mf.prolongation_cycle SET statut = ''autorisee'', decide_par = demande_par');
SELECT t.refuse('C autorisation sans auteur', 'UPDATE mf.prolongation_cycle SET statut = ''autorisee''');
UPDATE prolongation_cycle SET statut = 'autorisee', decide_par = (SELECT id FROM utilisateur WHERE login='chef');
SELECT t.eq('C date de fin du cycle prolongée', date_fin::text, '2027-01-15') FROM cycle WHERE numero = 'CY-6';
SELECT t.refuse('C prolongation décidée non modifiable', 'UPDATE mf.prolongation_cycle SET nouvelle_fin = ''2027-02-01''');
INSERT INTO prolongation_cycle(cycle_id,ancienne_fin,nouvelle_fin,motif,demande_par) SELECT id,date_fin,date_fin+10,'Deuxième prolongation justifiée',(SELECT id FROM utilisateur WHERE login='cais') FROM cycle WHERE numero = 'CY-6';
UPDATE prolongation_cycle SET statut = 'autorisee', decide_par = (SELECT id FROM utilisateur WHERE login='chef') WHERE statut = 'demandee';
SELECT t.refuse('C plafond de prolongations (2)', 'INSERT INTO mf.prolongation_cycle(cycle_id,ancienne_fin,nouvelle_fin,motif) SELECT id,date_fin,date_fin+5,''Troisième prolongation demandée'' FROM mf.cycle WHERE numero = ''CY-6''');

-- ===== D. Suppression tracée =====
INSERT INTO ligne_collecte(cycle_id,page,no_ligne,date_collecte,agent_id,montant_collecte) SELECT id,1,1,'2026-12-10',1,1000 FROM cycle WHERE numero = 'CY-6';
SET mf.utilisateur = 'chef';
SET mf.motif_suppression = 'Saisie en double';
DELETE FROM ligne_collecte WHERE cycle_id = (SELECT id FROM cycle WHERE numero = 'CY-6');
SELECT t.eq('D la ligne a disparu des données vives', count(*)::text, '0') FROM ligne_collecte WHERE cycle_id = (SELECT id FROM cycle WHERE numero = 'CY-6');
SELECT t.eq('D trace : qui, pourquoi, quoi', nature || '/' || supprime_par || '/' || motif || '/' || (donnees ->> 'montant_collecte'), 'ligne_collecte/chef/Saisie en double/1000') FROM operation_supprimee;
SELECT t.eq('D agence retrouvée par le cycle', agence_id::text, '1') FROM operation_supprimee;
SELECT t.refuse('D la trace est inaltérable (modification)', 'UPDATE mf.operation_supprimee SET motif = ''autre''');
SELECT t.refuse('D la trace est inaltérable (suppression)', 'DELETE FROM mf.operation_supprimee');
SELECT t.refuse('D la trace est inaltérable (vidage)', 'TRUNCATE mf.operation_supprimee');
