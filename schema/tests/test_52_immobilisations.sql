SET search_path = mf, public;

-- Module sous test : 52_immobilisations.sql (catégories, registre, amortissement, sortie, maintenance, interventions, alertes)
CREATE OR REPLACE FUNCTION t.sd(p_agence int, p_compte text) RETURNS text LANGUAGE sql AS $$
  SELECT COALESCE((SELECT (solde_debiteur - solde_crediteur)::text FROM mf.balance(p_agence::smallint,'2026-01-01','2026-12-31') WHERE compte = p_compte), '0') $$;

INSERT INTO agence(code,libelle) VALUES ('LOM','Lomé Centre'),('KPA','Kpalimé');
INSERT INTO utilisateur(login,nom,role,agence_id) VALUES ('saisie','Comptable','comptable',NULL),('tech','Technicien','chef_agence',1);
INSERT INTO exercice_comptable(code,date_debut,date_fin) VALUES ('2026','2026-01-01','2026-12-31');
INSERT INTO tiers(nom,type,agence_id) VALUES ('Garage Mensah','prestataire',1),('Prestataire Kpalimé','prestataire',2);

-- ===== A. Catégories =====
SELECT t.eq('A catégories proposées', count(*)::text, '7') FROM categorie_immobilisation;
SELECT t.eq('A règle d''acquisition', compte_debit || '/' || compte_credit, '442134/33212') FROM regle_comptable WHERE evenement = 'immo_acq_mobilier_bureau';
SELECT t.eq('A règle de dotation', compte_debit || '/' || compte_credit, '66112/442834') FROM regle_comptable WHERE evenement = 'immo_amort_mobilier_bureau';
SELECT t.eq('A règles de sortie : amortissements cumulés puis valeur nette', string_agg(compte_debit || '>' || compte_credit, ' ' ORDER BY ligne), '442834>442134 62392>442134') FROM regle_comptable WHERE evenement = 'immo_sortie_mobilier_bureau';
SELECT t.eq('A terrain : pas de dotation', count(*)::text, '0') FROM regle_comptable WHERE evenement = 'immo_amort_terrain';
SELECT t.refuse('A durée sans comptes d''amortissement', 'INSERT INTO mf.categorie_immobilisation(code,libelle,compte_immobilisation,duree_annees) VALUES (''x'',''X'',''442134'',5)');
SELECT t.refuse('A comptes d''amortissement sans durée', 'INSERT INTO mf.categorie_immobilisation(code,libelle,compte_immobilisation,compte_amortissement,compte_dotation) VALUES (''y'',''Y'',''442134'',''442834'',''66112'')');

-- ===== B. Registre =====
INSERT INTO immobilisation(agence_id,designation,categorie,date_acquisition,date_mise_en_service,valeur_acquisition,date_fin_garantie) VALUES (1,'Mobilier du bureau principal','mobilier_bureau','2026-01-10','2026-01-15',600000,NULL);
INSERT INTO immobilisation(agence_id,designation,categorie,date_acquisition,date_mise_en_service,valeur_acquisition,valeur_residuelle) VALUES (1,'Ordinateur de la direction','materiel_informatique','2026-02-01','2026-02-01',100000,10000);
INSERT INTO immobilisation(agence_id,designation,categorie,date_acquisition,date_mise_en_service,valeur_acquisition) VALUES (2,'Armoire de Kpalimé','mobilier_bureau','2026-03-01','2026-03-01',80000);
INSERT INTO immobilisation(agence_id,designation,categorie,date_acquisition,date_mise_en_service,valeur_acquisition,duree_annees) VALUES (1,'Terrain de l''agence','terrain','2026-03-05','2026-03-05',5000000,10);
SELECT t.eq('B numéros par agence', string_agg(numero, ' ' ORDER BY id), 'IMM-LOM-000001 IMM-LOM-000002 IMM-KPA-000001 IMM-LOM-000003') FROM immobilisation;
SELECT t.eq('B durée reprise de la catégorie', duree_annees::text, '5') FROM immobilisation WHERE numero = 'IMM-LOM-000001';
SELECT t.eq('B terrain non amortissable', COALESCE(duree_annees::text, 'aucune'), 'aucune') FROM immobilisation WHERE numero = 'IMM-LOM-000003';
SELECT t.refuse('B mise en service avant l''acquisition', 'INSERT INTO mf.immobilisation(agence_id,designation,categorie,date_acquisition,date_mise_en_service,valeur_acquisition) VALUES (1,''X Y Z'',''mobilier_bureau'',''2026-03-01'',''2026-02-01'',1000)');
SELECT t.refuse('B valeur résiduelle supérieure à la valeur', 'INSERT INTO mf.immobilisation(agence_id,designation,categorie,date_acquisition,date_mise_en_service,valeur_acquisition,valeur_residuelle) VALUES (1,''X Y Z'',''mobilier_bureau'',''2026-03-01'',''2026-03-01'',1000,2000)');
SELECT t.refuse('B catégorie inconnue', 'INSERT INTO mf.immobilisation(agence_id,designation,categorie,date_acquisition,date_mise_en_service,valeur_acquisition) VALUES (1,''X Y Z'',''inconnue'',''2026-03-01'',''2026-03-01'',1000)');
SELECT t.refuse('B fournisseur d''une autre agence', 'INSERT INTO mf.immobilisation(agence_id,designation,categorie,date_acquisition,date_mise_en_service,valeur_acquisition,tiers_id) VALUES (1,''X Y Z'',''mobilier_bureau'',''2026-03-01'',''2026-03-01'',1000,(SELECT id FROM mf.tiers WHERE agence_id = 2))');
UPDATE immobilisation SET localisation = 'Bureau 2' WHERE numero = 'IMM-LOM-000001';
SELECT t.refuse('B valeur d''acquisition non modifiable', 'UPDATE mf.immobilisation SET valeur_acquisition = 1 WHERE numero = ''IMM-LOM-000001''');
SELECT t.refuse('B catégorie non modifiable', 'UPDATE mf.immobilisation SET categorie = ''batiment'' WHERE numero = ''IMM-LOM-000001''');

-- ===== C. Amortissement linéaire mensuel =====
SELECT t.eq('C amortissements de janvier à mars (3 + 2 mois)', calculer_amortissements(1::smallint, '2026-03-31', 1)::text, '5');
SELECT t.eq('C mensualité du mobilier : 600000 / 60 mois', montant::text, '10000') FROM amortissement_immobilisation WHERE immobilisation_id = (SELECT id FROM immobilisation WHERE numero = 'IMM-LOM-000001') AND mois = 3;
SELECT t.eq('C ordinateur : (100000 - 10000) / 36 mois', montant::text, '2500') FROM amortissement_immobilisation WHERE immobilisation_id = (SELECT id FROM immobilisation WHERE numero = 'IMM-LOM-000002') AND mois = 2;
SELECT t.eq('C rejeu sans effet', calculer_amortissements(1::smallint, '2026-03-31', 1)::text, '0');
SELECT t.eq('C cumul et valeur nette', cumul_amortissement::text || '/' || valeur_nette::text, '30000/570000') FROM v_immobilisation WHERE numero = 'IMM-LOM-000001';
SELECT t.eq('C l''agence 2 n''est pas amortie par l''agence 1', count(*)::text, '0') FROM amortissement_immobilisation WHERE immobilisation_id = (SELECT id FROM immobilisation WHERE numero = 'IMM-KPA-000001');
SELECT t.eq('C rattrapage de l''agence 2', calculer_amortissements(2::smallint, '2026-05-31', 1)::text, '3');
SELECT t.refuse('C amortissement non modifiable', 'UPDATE mf.amortissement_immobilisation SET montant = 1');
SELECT t.refuse('C amortissement non supprimable', 'DELETE FROM mf.amortissement_immobilisation');
-- dernier mois : solde de l'écart d'arrondi
INSERT INTO immobilisation(agence_id,designation,categorie,date_acquisition,date_mise_en_service,valeur_acquisition,duree_annees) VALUES (2,'Petit matériel arrondi','mobilier_bureau','2026-01-01','2026-01-01',100000,3);
SELECT calculer_amortissements(2::smallint, '2030-01-31', 1);
SELECT t.eq('C série complète : 35 mensualités, cumul exact', count(*)::text || '/' || sum(montant)::text, '35/100000') FROM amortissement_immobilisation WHERE immobilisation_id = (SELECT id FROM immobilisation WHERE designation = 'Petit matériel arrondi');
SELECT t.eq('C totalement amortie', totalement_amortie::text, 'true') FROM v_immobilisation WHERE designation = 'Petit matériel arrondi';
SELECT t.eq('C alerte : totalement amortie et en service', count(*)::text, '1') FROM v_alerte_immobilisation WHERE type = 'totalement_amortie' AND reference = 'IMM-KPA-000002';

-- ===== D. Sortie de l'inventaire =====
SELECT t.refuse('D sortie avant la mise en service', 'SELECT mf.sortir_immobilisation((SELECT id FROM mf.immobilisation WHERE numero = ''IMM-LOM-000001''), ''2026-01-01'', ''rebut'', NULL, ''Matériel hors d''''usage'', 1)');
SELECT t.refuse('D sortie sans motif', 'SELECT mf.sortir_immobilisation((SELECT id FROM mf.immobilisation WHERE numero = ''IMM-LOM-000001''), ''2026-06-30'', ''rebut'', NULL, ''x'', 1)');
SELECT t.refuse('D cession sans prix', 'SELECT mf.sortir_immobilisation((SELECT id FROM mf.immobilisation WHERE numero = ''IMM-LOM-000001''), ''2026-06-30'', ''cession'', NULL, ''Vendu à un tiers'', 1)');
SELECT t.refuse('D type de sortie inconnu', 'SELECT mf.sortir_immobilisation((SELECT id FROM mf.immobilisation WHERE numero = ''IMM-LOM-000001''), ''2026-06-30'', ''vol'', NULL, ''Disparu du bureau'', 1)');
SELECT t.eq('D cession : valeur nette comptable après dotations jusqu''en juin', sortir_immobilisation((SELECT id FROM immobilisation WHERE numero = 'IMM-LOM-000001'), '2026-06-30', 'cession', 400000, 'Vendu à un tiers', 1)::text, '540000');
SELECT t.eq('D immobilisation sortie', statut || '/' || date_sortie::text || '/' || type_sortie, 'sortie/2026-06-30/cession') FROM immobilisation WHERE numero = 'IMM-LOM-000001';
SELECT calculer_amortissements(1::smallint, '2026-12-31', 1);
SELECT t.eq('D plus de dotation après la sortie', count(*)::text, '0') FROM amortissement_immobilisation WHERE immobilisation_id = (SELECT id FROM immobilisation WHERE numero = 'IMM-LOM-000001') AND mois > 6;
SELECT t.refuse('D immobilisation sortie non modifiable', 'UPDATE mf.immobilisation SET localisation = ''autre'' WHERE numero = ''IMM-LOM-000001''');
SELECT t.refuse('D double sortie', 'SELECT mf.sortir_immobilisation((SELECT id FROM mf.immobilisation WHERE numero = ''IMM-LOM-000001''), ''2026-07-30'', ''rebut'', NULL, ''Deuxième sortie'', 1)');

-- ===== E. Écritures comptables =====
UPDATE parametre SET valeur = 'oui' WHERE cle = 'comptabilisation_auto';
INSERT INTO immobilisation(agence_id,designation,categorie,date_acquisition,date_mise_en_service,valeur_acquisition) VALUES (1,'Serveur','materiel_informatique','2026-07-01','2026-07-01',300000);
SELECT t.eq('E acquisition : immobilisation débitée, fournisseur d''investissement crédité', t.sd(1, '442138') || '/' || t.sd(1, '33212'), '300000/-300000');
SELECT calculer_amortissements(1::smallint, '2026-07-31', 1);
SELECT t.eq('E dotation de juillet : 66112 / 442838', t.sd(1, '66112') || '/' || t.sd(1, '442838'), '8333/-8333');
SELECT sortir_immobilisation((SELECT id FROM immobilisation WHERE designation = 'Serveur'), '2026-09-15', 'rebut', NULL, 'Serveur hors d''usage', 1);
SELECT t.eq('E sortie : l''immobilisation et ses amortissements sont soldés', t.sd(1, '442138') || '/' || t.sd(1, '442838'), '0/0');
SELECT t.eq('E sortie : dotations jusqu''en septembre et valeur nette en charge', t.sd(1, '66112') || '/' || t.sd(1, '62392'), '24999/275001');
UPDATE parametre SET valeur = 'non' WHERE cle = 'comptabilisation_auto';

-- ===== F. Maintenance préventive =====
INSERT INTO plan_maintenance(immobilisation_id,libelle,periodicite_mois,prochaine_echeance,tiers_id) VALUES ((SELECT id FROM immobilisation WHERE numero = 'IMM-LOM-000002'),'Nettoyage et mise à jour de l''ordinateur',6,'2026-04-10',(SELECT id FROM tiers WHERE agence_id = 1));
SELECT t.refuse('F périodicité hors bornes', 'INSERT INTO mf.plan_maintenance(immobilisation_id,libelle,periodicite_mois,prochaine_echeance) VALUES (1,''Plan X'',0,''2026-04-10'')');
SELECT t.eq('F échéance hors préavis : rien à planifier', generer_interventions_preventives('2026-03-01', 1)::text, '0');
SELECT t.eq('F échéance dans le préavis : intervention planifiée', generer_interventions_preventives('2026-04-01', 1)::text, '1');
SELECT t.eq('F rejeu sans doublon', generer_interventions_preventives('2026-04-01', 1)::text, '0');
SELECT t.eq('F intervention préventive planifiée', type || '/' || statut || '/' || date_planifiee::text, 'preventive/planifiee/2026-04-10') FROM intervention;
SELECT t.refuse('F planifiée -> terminée directement', 'UPDATE mf.intervention SET statut = ''terminee'', date_fin = ''2026-04-10'', resultat = ''Fait'' WHERE type = ''preventive''');
UPDATE intervention SET statut = 'en_cours', date_debut = '2026-04-10' WHERE type = 'preventive';
SELECT t.eq('F immobilisation en maintenance', statut, 'en_maintenance') FROM immobilisation WHERE numero = 'IMM-LOM-000002';
SELECT t.refuse('F clôture sans date de fin', 'UPDATE mf.intervention SET statut = ''terminee'', resultat = ''Nettoyage effectué'' WHERE type = ''preventive''');
SELECT t.refuse('F clôture sans résultat', 'UPDATE mf.intervention SET statut = ''terminee'', date_fin = ''2026-04-10'' WHERE type = ''preventive''');
UPDATE intervention SET statut = 'terminee', date_fin = '2026-04-10', resultat = 'Nettoyage effectué' WHERE type = 'preventive';
SELECT t.eq('F plan reporté de 6 mois', derniere_realisation::text || '/' || prochaine_echeance::text, '2026-04-10/2026-10-10') FROM plan_maintenance;
SELECT t.eq('F sans coût : aucune dépense créée', count(*)::text, '0') FROM operation_generale WHERE cle LIKE 'int-%';
SELECT t.eq('F immobilisation de nouveau en service', statut, 'en_service') FROM immobilisation WHERE numero = 'IMM-LOM-000002';

-- ===== G. Réparation corrective et coûts =====
SELECT signaler_panne((SELECT id FROM immobilisation WHERE numero = 'IMM-LOM-000002'), 'Écran fissuré après une chute', 'urgente', true, 1);
SELECT t.eq('G panne urgente : immobilisation hors service', statut, 'hors_service') FROM immobilisation WHERE numero = 'IMM-LOM-000002';
SELECT t.eq('G alerte de panne urgente', count(*)::text, '1') FROM v_alerte_immobilisation WHERE type = 'panne_urgente' AND reference = 'IMM-LOM-000002';
SELECT t.refuse('G planification sans date', 'UPDATE mf.intervention SET statut = ''planifiee'' WHERE type = ''corrective''');
SELECT t.refuse('G panne signalée sur une immobilisation inconnue', 'SELECT mf.signaler_panne(99999, ''Panne quelconque'', ''haute'', false, 1)');
SELECT t.refuse('G description trop courte', 'SELECT mf.signaler_panne((SELECT id FROM mf.immobilisation WHERE numero = ''IMM-LOM-000002''), ''x'', ''haute'', false, 1)');
UPDATE intervention SET statut = 'en_cours', tiers_id = (SELECT id FROM tiers WHERE agence_id = 1) WHERE type = 'corrective';
SELECT t.refuse('G coût sans référence de facture', 'UPDATE mf.intervention SET statut = ''terminee'', date_fin = current_date, resultat = ''Écran remplacé'', cout_main_oeuvre = 20000, cout_pieces = 15000 WHERE type = ''corrective''');
UPDATE intervention SET statut = 'terminee', date_fin = current_date, resultat = 'Écran remplacé', cout_main_oeuvre = 20000, cout_pieces = 15000, reference_facture = 'FAC-REP-1' WHERE type = 'corrective';
SELECT t.eq('G coût total', cout_total::text, '35000') FROM intervention WHERE type = 'corrective';
SELECT t.eq('G dépense « entretien et réparation à payer » créée avec le prestataire', o.montant::text || '/' || o.code_operation || '/' || o.statut || '/' || (o.tiers_id = x.tiers_id)::text, '35000/facture_entretien_a_payer/valide/true') FROM intervention x JOIN operation_generale o ON o.id = x.operation_id WHERE x.type = 'corrective';
SELECT t.eq('G immobilisation de nouveau en service', statut, 'en_service') FROM immobilisation WHERE numero = 'IMM-LOM-000002';
SELECT t.eq('G coût de maintenance cumulé', cout_total::text || '/' || cout_reparations::text || '/' || nb_interventions::text, '35000/35000/2') FROM v_cout_maintenance WHERE numero = 'IMM-LOM-000002';
SELECT t.refuse('G intervention terminée non modifiable', 'UPDATE mf.intervention SET description = ''autre description'' WHERE type = ''corrective''');
SELECT t.refuse('G intervention non supprimable', 'DELETE FROM mf.intervention');

-- ===== H. Alertes et sorties avec interventions ouvertes =====
INSERT INTO plan_maintenance(immobilisation_id,libelle,periodicite_mois,prochaine_echeance) VALUES ((SELECT id FROM immobilisation WHERE numero = 'IMM-KPA-000001'),'Révision de l''armoire',12,current_date - 3);
INSERT INTO plan_maintenance(immobilisation_id,libelle,periodicite_mois,prochaine_echeance) VALUES ((SELECT id FROM immobilisation WHERE numero = 'IMM-KPA-000002'),'Contrôle annuel',12,current_date + 5);
SELECT t.eq('H maintenance en retard : la révision de l''armoire est signalée', count(*)::text, '1') FROM v_alerte_immobilisation WHERE type = 'maintenance_en_retard' AND reference = 'IMM-KPA-000001';
SELECT t.eq('H maintenance à prévoir', count(*)::text, '1') FROM v_alerte_immobilisation WHERE type = 'maintenance_a_prevoir';
UPDATE immobilisation SET date_fin_garantie = current_date + 10 WHERE numero = 'IMM-KPA-000002';
SELECT t.eq('H garantie proche de la fin', count(*)::text, '1') FROM v_alerte_immobilisation WHERE type = 'garantie_proche_fin';
SELECT signaler_panne((SELECT id FROM immobilisation WHERE numero = 'IMM-KPA-000002'), 'Plateau rayé et tiroir bloqué', 'normale', false, 1);
UPDATE intervention SET date_signalement = current_date - 30 WHERE description LIKE 'Plateau rayé%';
SELECT t.eq('H réparation trop longue', count(*)::text, '1') FROM v_alerte_immobilisation WHERE type = 'reparation_longue';
SELECT t.refuse('H sortie avec une intervention ouverte', 'SELECT mf.sortir_immobilisation((SELECT id FROM mf.immobilisation WHERE numero = ''IMM-KPA-000002''), ''2026-12-01'', ''rebut'', NULL, ''Mobilier hors d''''usage'', 1)');
UPDATE intervention SET statut = 'annulee' WHERE description LIKE 'Plateau rayé%';
SELECT t.eq('H sortie possible une fois l''intervention annulée', (sortir_immobilisation((SELECT id FROM immobilisation WHERE numero = 'IMM-KPA-000002'), '2026-12-01', 'rebut', NULL, 'Mobilier hors d''usage', 1) >= 0)::text, 'true');
SELECT t.eq('H la sortie désactive les plans de maintenance', count(*)::text, '0') FROM plan_maintenance WHERE immobilisation_id = (SELECT id FROM immobilisation WHERE numero = 'IMM-KPA-000002') AND actif;
