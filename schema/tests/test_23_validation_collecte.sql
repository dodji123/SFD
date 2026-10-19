SET search_path = mf, public;

-- Module sous test : 23_validation_collecte.sql (correction des lignes, validation globale de la journée, zone/agent)
INSERT INTO agence(code,libelle) VALUES ('LOM','Lomé Centre');
INSERT INTO utilisateur(agence_id,login,nom,role) VALUES (1,'chef','Chef','chef_agence');
INSERT INTO agent(agence_id,matricule,nom) VALUES (1,'A1','Agent un'),(1,'A2','Agent deux');
INSERT INTO zone(agence_id,code,libelle,agent_id) VALUES (1,'Z1','Zone un',1);
INSERT INTO produit_epargne(code,libelle,categorie,type_cycle) VALUES ('T1','Tontine','collecte',1);
INSERT INTO client(agence_id,zone_id,numero,nom) VALUES (1,1,'C1','Client un');
INSERT INTO cycle(agence_id,numero,client_id,produit_id,type_cycle,mise_initiale,mise_courante,objectif,nb_lignes_prevues,date_debut,date_fin)
VALUES (1,'CY1',1,1,1,500,500,15500,31,'2025-01-01','2025-12-31');
INSERT INTO ligne_collecte(cycle_id,page,no_ligne,date_collecte,agent_id,montant_collecte) VALUES
  (1,1,1,'2025-03-03',1,500),(1,1,2,'2025-03-03',1,1000),(1,1,3,'2025-03-04',1,500);

-- ===== A. Zone et agent =====
SELECT t.eq('A la zone connaît son agent', (SELECT agent_id::text FROM zone WHERE code = 'Z1'), '1');

-- ===== B. Correction tant que la journée n'est pas validée =====
SELECT modifier_ligne_collecte((SELECT id FROM ligne_collecte WHERE no_ligne = 2), 1500);
SELECT t.eq('B montant modifié', montant_collecte::text, '1500') FROM ligne_collecte WHERE no_ligne = 2;
SELECT t.refuse('B montant nul refusé', 'SELECT mf.modifier_ligne_collecte((SELECT id FROM mf.ligne_collecte WHERE no_ligne = 2), 0)');
SELECT supprimer_ligne_collecte((SELECT id FROM ligne_collecte WHERE no_ligne = 3));
SELECT t.eq('B il reste deux lignes', count(*)::text, '2') FROM ligne_collecte;

-- ===== C. Validation globale : plus rien ne bouge ce jour-là =====
SELECT t.refuse('C journée à venir', 'SELECT mf.valider_journee_collecte(1::smallint, current_date + 1, 1)');
SELECT valider_journee_collecte(1::smallint, '2025-03-03', 1);
SELECT t.refuse('C double validation', 'SELECT mf.valider_journee_collecte(1::smallint, ''2025-03-03'', 1)');
SELECT t.refuse('C modification refusée', 'SELECT mf.modifier_ligne_collecte((SELECT id FROM mf.ligne_collecte WHERE no_ligne = 2), 500)');
SELECT t.refuse('C suppression refusée', 'SELECT mf.supprimer_ligne_collecte((SELECT id FROM mf.ligne_collecte WHERE no_ligne = 1))');
SELECT t.refuse('C saisie refusée sur la journée validée', 'INSERT INTO mf.ligne_collecte(cycle_id,page,no_ligne,date_collecte,agent_id,montant_collecte) VALUES (1,1,9,''2025-03-03'',1,500)');
INSERT INTO ligne_collecte(cycle_id,page,no_ligne,date_collecte,agent_id,montant_collecte) VALUES (1,1,5,'2025-03-05',1,500);
SELECT t.eq('C saisie acceptée un autre jour', count(*)::text, '1') FROM ligne_collecte WHERE date_collecte = '2025-03-05';

-- ===== D. Réouverture tracée =====
SELECT t.refuse('D motif obligatoire', 'SELECT mf.rouvrir_journee_collecte(1::smallint, ''2025-03-03'', ''  '', 1)');
SELECT t.refuse('D journée non validée', 'SELECT mf.rouvrir_journee_collecte(1::smallint, ''2025-03-05'', ''x'', 1)');
SELECT rouvrir_journee_collecte(1::smallint, '2025-03-03', 'erreur de saisie à corriger', 1);
SELECT modifier_ligne_collecte((SELECT id FROM ligne_collecte WHERE no_ligne = 2), 500);
SELECT t.eq('D correction à nouveau possible', montant_collecte::text, '500') FROM ligne_collecte WHERE no_ligne = 2;
SELECT t.eq('D journal : validation puis réouverture', string_agg(action, ','  ORDER BY id), 'validee,rouverte') FROM validation_collecte_journal;

-- ===== E. Tournée déjà versée : correction refusée =====
SELECT enregistrer_versement(1, '2025-03-03', 1000, 1);
SELECT t.refuse('E ligne d''une tournée versée', 'SELECT mf.modifier_ligne_collecte((SELECT id FROM mf.ligne_collecte WHERE no_ligne = 2), 500)');
