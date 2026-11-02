SET search_path = mf, public;

-- Module sous test : 23_validation_collecte.sql (correction des lignes sur la date d'opération, zone/agent)
INSERT INTO agence(code,libelle) VALUES ('LOM','Lomé Centre');
INSERT INTO utilisateur(agence_id,login,nom,role) VALUES (1,'chef','Chef','chef_agence');
INSERT INTO agent(agence_id,matricule,nom) VALUES (1,'A1','Agent un'),(1,'A2','Agent deux');
INSERT INTO zone(agence_id,code,libelle,agent_id) VALUES (1,'Z1','Zone un',1);
INSERT INTO produit_epargne(code,libelle,categorie,type_cycle) VALUES ('T1','Tontine','collecte',1);
INSERT INTO client(agence_id,zone_id,numero,nom) VALUES (1,1,'C1','Client un');
INSERT INTO cycle(agence_id,numero,client_id,produit_id,type_cycle,mise_initiale,mise_courante,objectif,nb_lignes_prevues,date_debut,date_fin)
VALUES (1,'CY1',1,1,1,500,500,15500,31,'2025-01-01','2025-12-31');

-- ===== A. Zone et agent =====
SELECT t.eq('A la zone connaît son agent', (SELECT agent_id::text FROM zone WHERE code = 'Z1'), '1');

-- ===== B. Saisie et correction sur la date d'opération ouverte =====
SELECT ouvrir_date_operation('2025-03-03');
INSERT INTO ligne_collecte(cycle_id,page,no_ligne,date_collecte,agent_id,montant_collecte) VALUES
  (1,1,1,'2025-03-03',1,500),(1,1,2,'2025-03-03',1,1000),(1,1,3,'2025-03-03',1,500);
SELECT modifier_ligne_collecte((SELECT id FROM ligne_collecte WHERE no_ligne = 2), 1500);
SELECT t.eq('B montant modifié', montant_collecte::text, '1500') FROM ligne_collecte WHERE no_ligne = 2;
SELECT t.refuse('B montant nul refusé', 'SELECT mf.modifier_ligne_collecte((SELECT id FROM mf.ligne_collecte WHERE no_ligne = 2), 0)');
SELECT supprimer_ligne_collecte((SELECT id FROM ligne_collecte WHERE no_ligne = 3));
SELECT t.eq('B il reste deux lignes', count(*)::text, '2') FROM ligne_collecte;

-- ===== C. Clôture de la date : plus de correction ni de saisie sur cette date =====
SELECT cloturer_date_operation();
SELECT t.refuse('C modification refusée après clôture', 'SELECT mf.modifier_ligne_collecte((SELECT id FROM mf.ligne_collecte WHERE no_ligne = 2), 500)');
SELECT t.refuse('C suppression refusée après clôture', 'SELECT mf.supprimer_ligne_collecte((SELECT id FROM mf.ligne_collecte WHERE no_ligne = 1))');
SELECT t.refuse('C saisie refusée sur une date close', 'INSERT INTO mf.ligne_collecte(cycle_id,page,no_ligne,date_collecte,agent_id,montant_collecte) VALUES (1,1,9,''2025-03-03'',1,500)');

-- ===== D. La date suivante : saisie acceptée, anciennes lignes figées =====
SELECT ouvrir_date_operation('2025-03-04');
INSERT INTO ligne_collecte(cycle_id,page,no_ligne,date_collecte,agent_id,montant_collecte) VALUES (1,1,4,'2025-03-04',1,500);
SELECT t.eq('D saisie acceptée sur la date ouverte', count(*)::text, '1') FROM ligne_collecte WHERE date_collecte = '2025-03-04';
SELECT t.refuse('D correction d''une ligne d''une date close', 'SELECT mf.modifier_ligne_collecte((SELECT id FROM mf.ligne_collecte WHERE no_ligne = 2), 500)');
SELECT modifier_ligne_collecte((SELECT id FROM ligne_collecte WHERE no_ligne = 4), 600);
SELECT t.eq('D correction sur la date ouverte', montant_collecte::text, '600') FROM ligne_collecte WHERE no_ligne = 4;

-- ===== E. Tournée déjà versée : correction refusée =====
SELECT enregistrer_versement(1, '2025-03-04', 600, 1);
SELECT t.refuse('E ligne d''une tournée versée', 'SELECT mf.modifier_ligne_collecte((SELECT id FROM mf.ligne_collecte WHERE no_ligne = 4), 500)');
