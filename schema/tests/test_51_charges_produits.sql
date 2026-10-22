SET search_path = mf, public;

-- Module sous test : 51_charges_produits.sql (tiers, budget prévu/réalisé, opérations récurrentes, alertes)
INSERT INTO agence(code,libelle) VALUES ('LOM','Lomé Centre'),('KPA','Kpalimé');
INSERT INTO utilisateur(login,nom,role,agence_id) VALUES ('saisie','Comptable','comptable',NULL),('valid','Chef','chef_agence',1);
INSERT INTO caisse(agence_id,code,type) VALUES (1,'LOM-P','principale');
INSERT INTO session_caisse(caisse_id,date_session,solde_ouverture) VALUES (1,'2026-11-10',1000000);

-- ===== A. Tiers =====
INSERT INTO tiers(nom,type,agence_id) VALUES ('Bailleur Agbodjan','bailleur',1),('Papeterie Kodjo','fournisseur',NULL);
SELECT t.refuse('A même nom dans la même agence', 'INSERT INTO mf.tiers(nom,type,agence_id) VALUES (''bailleur agbodjan'',''bailleur'',1)');
INSERT INTO tiers(nom,type,agence_id) VALUES ('Bailleur Agbodjan','bailleur',2);
SELECT t.refuse('A type inconnu', 'INSERT INTO mf.tiers(nom,type) VALUES (''X Y'',''inconnu'')');
SELECT saisir_operation_generale(1::smallint, 'facture_loyer_a_payer', '2026-10-01', 100000, NULL, 'LOY-OCT', NULL, NULL, 1, 'k-a-1', (SELECT id FROM tiers WHERE agence_id = 1));
SELECT t.eq('A tiers relié, nom repris', (tiers_id = (SELECT id FROM tiers WHERE agence_id = 1))::text || '/' || tiers, 'true/Bailleur Agbodjan') FROM operation_generale WHERE cle = 'k-a-1';
SELECT t.refuse('A tiers d''une autre agence', 'SELECT mf.saisir_operation_generale(1::smallint, ''facture_loyer_a_payer'', ''2026-10-02'', 1000, NULL, ''X'', NULL, NULL, 1, NULL, (SELECT id FROM mf.tiers WHERE agence_id = 2))');
SELECT t.refuse('A tiers inconnu', 'SELECT mf.saisir_operation_generale(1::smallint, ''facture_loyer_a_payer'', ''2026-10-02'', 1000, NULL, ''X'', NULL, NULL, 1, NULL, 999999)');
SELECT t.eq('A la vue expose le tiers', tiers_nom, 'Bailleur Agbodjan') FROM v_operation_generale WHERE cle = 'k-a-1';
SELECT t.eq('A la saisie à 10 arguments reste possible', (saisir_operation_generale(1::smallint, 'facture_entretien_a_payer', '2026-10-05', 30000, 'Plombier', 'FAC-PL', NULL, NULL, 1, 'k-a-2') IS NOT NULL)::text, 'true');

-- ===== B. Budget prévu / réalisé =====
INSERT INTO budget_ligne(agence_id,annee,mois,code_operation,montant_prevu,cree_par) VALUES (1,2026,10,'facture_loyer_a_payer',90000,1),(1,2026,10,'facture_entretien_a_payer',50000,1);
SELECT t.refuse('B une seule ligne par agence, mois et opération', 'INSERT INTO mf.budget_ligne(agence_id,annee,mois,code_operation,montant_prevu) VALUES (1,2026,10,''facture_loyer_a_payer'',1)');
SELECT t.refuse('B budget sur une opération qui n''est ni charge ni produit', 'INSERT INTO mf.budget_ligne(agence_id,annee,mois,code_operation,montant_prevu) VALUES (1,2026,10,''virement_fournisseur'',1)');
SELECT t.refuse('B mois invalide', 'INSERT INTO mf.budget_ligne(agence_id,annee,mois,code_operation,montant_prevu) VALUES (1,2026,13,''facture_loyer_a_payer'',1)');
SELECT t.eq('B loyer : prévu, réalisé, écart, taux', prevu::text || '/' || realise::text || '/' || ecart::text || '/' || taux::text, '90000/100000/10000/111.1') FROM v_budget_realise WHERE agence_id = 1 AND mois = 10 AND code_operation = 'facture_loyer_a_payer';
SELECT t.eq('B dépassement signalé', depassement::text, 'true') FROM v_budget_realise WHERE agence_id = 1 AND mois = 10 AND code_operation = 'facture_loyer_a_payer';
SELECT t.eq('B entretien dans le budget', depassement::text || '/' || taux::text, 'false/60.0') FROM v_budget_realise WHERE agence_id = 1 AND mois = 10 AND code_operation = 'facture_entretien_a_payer';
SELECT t.eq('B alerte de dépassement', count(*)::text, '1') FROM v_alerte_charge_produit WHERE type = 'depassement_budget' AND agence_id = 1;
SELECT saisir_operation_generale(1::smallint, 'frais_communication', '2026-10-20', 7000, 'Togocel', NULL, NULL, 1, 1, 'k-b-1');
SELECT t.eq('B réalisé sans budget : ligne présente, prévu nul', prevu::text || '/' || realise::text || '/' || COALESCE(taux::text, 'sans taux'), '0/7000/sans taux') FROM v_budget_realise WHERE agence_id = 1 AND mois = 10 AND code_operation = 'frais_communication';
SELECT saisir_operation_generale(1::smallint, 'produit_divers', '2026-10-21', 25000, 'Vente de vieux papiers', NULL, NULL, 1, 1, 'k-b-2');
SELECT t.eq('B produits et charges du mois', sum(realise) FILTER (WHERE categorie = 'produit')::text || '/' || sum(realise) FILTER (WHERE categorie = 'charge')::text, '25000/137000') FROM v_budget_realise WHERE agence_id = 1 AND mois = 10;
SELECT saisir_operation_generale(1::smallint, 'paiement_loyer', '2026-10-22', 150000, 'Bailleur', 'QUIT-9', NULL, 1, 1, 'k-b-3');
SELECT t.eq('B opération au-dessus du seuil en attente : hors réalisé', count(*)::text, '0') FROM v_realise_mensuel WHERE code_operation = 'paiement_loyer';
UPDATE operation_generale SET saisi_le = now() - interval '5 days' WHERE cle = 'k-b-3';
SELECT t.eq('B alerte d''opération en attente depuis trop longtemps', count(*)::text, '1') FROM v_alerte_charge_produit WHERE type = 'operation_a_valider';

SELECT t.refuse('B clé d''opération rejouée par un autre utilisateur', 'SELECT mf.saisir_operation_generale(1::smallint, ''frais_communication'', ''2026-10-20'', 7000, ''Togocel'', NULL, NULL, 1, 2, ''k-b-1'')');

-- ===== C. Opérations récurrentes =====
SELECT t.refuse('C opération de caisse non récurrente', 'INSERT INTO mf.operation_recurrente(agence_id,code_operation,montant,periodicite,prochaine_date) VALUES (1,''paiement_loyer'',100000,''mensuelle'',''2026-09-01'')');
SELECT t.refuse('C jour du mois invalide', 'INSERT INTO mf.operation_recurrente(agence_id,code_operation,montant,periodicite,prochaine_date,jour_du_mois) VALUES (1,''facture_loyer_a_payer'',100000,''mensuelle'',''2026-09-01'',29)');
SELECT t.refuse('C tiers d''une autre agence', 'INSERT INTO mf.operation_recurrente(agence_id,code_operation,montant,tiers_id,periodicite,prochaine_date) VALUES (1,''facture_loyer_a_payer'',1000,(SELECT id FROM mf.tiers WHERE agence_id = 2),''mensuelle'',''2026-09-01'')');
SELECT t.refuse('C périodicité inconnue', 'INSERT INTO mf.operation_recurrente(agence_id,code_operation,montant,periodicite,prochaine_date) VALUES (1,''facture_loyer_a_payer'',100000,''hebdomadaire'',''2026-09-01'')');
INSERT INTO operation_recurrente(agence_id,code_operation,montant,tiers_id,libelle,periodicite,jour_du_mois,prochaine_date,cree_par) VALUES (1,'facture_loyer_a_payer',100000,(SELECT id FROM tiers WHERE agence_id = 1),'Loyer du bureau','mensuelle',1,'2026-07-01',1);
SELECT t.refuse('C génération sans utilisateur', 'SELECT mf.generer_operations_recurrentes(''2026-09-15'')');
SELECT t.eq('C échéances de juillet, août, septembre générées', generer_operations_recurrentes('2026-09-15', 1)::text, '3');
SELECT t.eq('C opérations créées avec leur tiers', count(*)::text, '3') FROM operation_generale WHERE cle LIKE 'rec-%' AND tiers_id = (SELECT id FROM tiers WHERE agence_id = 1);
SELECT t.eq('C prochaine échéance', prochaine_date::text, '2026-10-01') FROM operation_recurrente;
SELECT t.eq('C rejeu sans effet', generer_operations_recurrentes('2026-09-15', 1)::text, '0');
SELECT t.eq('C octobre généré à son échéance', generer_operations_recurrentes('2026-10-01', 1)::text, '1');
SELECT t.eq('C prochaine échéance après octobre', prochaine_date::text, '2026-11-01') FROM operation_recurrente;
-- série trimestrielle bornée : janvier, avril, juillet (fin le 15 juillet)
INSERT INTO operation_recurrente(agence_id,code_operation,montant,periodicite,jour_du_mois,prochaine_date,date_fin,cree_par) VALUES (1,'facture_entretien_a_payer',20000,'trimestrielle',15,'2026-01-15','2026-07-15',1);
SELECT generer_operations_recurrentes('2026-10-01', 1);
SELECT t.eq('C trimestrielle : 3 échéances jusqu''à la date de fin', count(*)::text, '3') FROM operation_generale o JOIN operation_recurrente r ON o.cle LIKE 'rec-' || r.id || '-%' WHERE r.periodicite = 'trimestrielle';
SELECT t.eq('C la série terminée est désactivée', actif::text, 'false') FROM operation_recurrente WHERE periodicite = 'trimestrielle';
-- retard
UPDATE operation_recurrente SET prochaine_date = current_date - 10 WHERE periodicite = 'mensuelle';
SELECT t.eq('C alerte de récurrente en retard', count(*)::text, '1') FROM v_alerte_charge_produit WHERE type = 'recurrente_en_retard';
