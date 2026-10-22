SET search_path = mf, public;

-- Module sous test : 50_operations_standard.sql (opérations standard de caisse / hors caisse, validation, écritures, transfert de fonds)
CREATE OR REPLACE FUNCTION t.sd(p_agence int, p_compte text) RETURNS text LANGUAGE sql AS $$
  SELECT COALESCE((SELECT (solde_debiteur - solde_crediteur)::text FROM mf.balance(p_agence::smallint,'2026-01-01','2026-12-31') WHERE compte = p_compte), '0') $$;

INSERT INTO agence(code,libelle) VALUES ('LOM','Lomé Centre'),('KPA','Kpalimé');
INSERT INTO utilisateur(login,nom,role,agence_id) VALUES ('saisie','Caissier','caissier',1),('valid','Chef','chef_agence',1),('recep','Caissier Kpalimé','caissier',2);
INSERT INTO caisse(agence_id,code,type) VALUES (1,'LOM-P','principale'),(1,'LOM-G','guichet'),(2,'KPA-P','principale');
INSERT INTO session_caisse(caisse_id,date_session,solde_ouverture) VALUES (1,'2026-11-10',1000000),(2,'2026-11-10',100000),(3,'2026-11-10',200000);
INSERT INTO exercice_comptable(code,date_debut,date_fin) VALUES ('2026','2026-01-01','2026-12-31');

-- ===== A. Catalogue des opérations standard =====
SELECT t.eq('A opérations proposées : caisse / hors caisse', count(*) FILTER (WHERE famille='caisse')::text || '/' || count(*) FILTER (WHERE famille='hors_caisse')::text, '11/3') FROM operation_standard;
SELECT t.eq('A règle comptable créée pour une opération', compte_debit || '/' || compte_credit || '/' || journal_code, '6218/1011/CAI') FROM regle_comptable WHERE evenement = 'op_achat_fournitures';
SELECT t.refuse('A hors caisse sur le compte de caisse', 'INSERT INTO mf.operation_standard(code,libelle,famille,categorie,sens,compte_debit,compte_credit) VALUES (''x1'',''X'',''hors_caisse'',''charge'',''sortie'',''6218'',''1011'')');
SELECT t.refuse('A entrée de caisse sans débit de la caisse', 'INSERT INTO mf.operation_standard(code,libelle,famille,categorie,sens,compte_debit,compte_credit) VALUES (''x2'',''X'',''caisse'',''produit'',''entree'',''6218'',''7038'')');
SELECT t.refuse('A sortie de caisse sans crédit de la caisse', 'INSERT INTO mf.operation_standard(code,libelle,famille,categorie,sens,compte_debit,compte_credit) VALUES (''x3'',''X'',''caisse'',''charge'',''sortie'',''6218'',''33211'')');
SELECT t.refuse('A un seul compte renseigné', 'INSERT INTO mf.operation_standard(code,libelle,famille,categorie,sens,compte_debit) VALUES (''x4'',''X'',''caisse'',''charge'',''sortie'',''6218'')');
SELECT t.refuse('A code invalide', 'INSERT INTO mf.operation_standard(code,libelle,famille,categorie,sens) VALUES (''Code Invalide'',''X'',''caisse'',''charge'',''sortie'')');
UPDATE operation_standard SET compte_debit = '6228' WHERE code = 'achat_fournitures';
SELECT t.eq('A modification du compte suivie par la règle', compte_debit, '6228') FROM regle_comptable WHERE evenement = 'op_achat_fournitures';
UPDATE operation_standard SET compte_debit = '6218' WHERE code = 'achat_fournitures';
INSERT INTO operation_standard(code,libelle,famille,categorie,sens) VALUES ('a_parametrer','Opération à paramétrer','hors_caisse','autre','sortie');
SELECT t.eq('A opération sans comptes : pas de règle active', count(*)::text, '0') FROM regle_comptable WHERE evenement = 'op_a_parametrer' AND actif;

-- ===== B. Saisie et validation =====
SELECT t.refuse('B opération inconnue', 'SELECT mf.saisir_operation_generale(1::smallint, ''inconnue'', ''2026-11-10'', 1000, NULL, NULL, NULL, 1, 1)');
SELECT t.refuse('B justificatif obligatoire', 'SELECT mf.saisir_operation_generale(1::smallint, ''achat_fournitures'', ''2026-11-10'', 10000, NULL, NULL, NULL, 1, 1)');
SELECT t.refuse('B opération de caisse sans session', 'SELECT mf.saisir_operation_generale(1::smallint, ''achat_fournitures'', ''2026-11-10'', 10000, NULL, ''FAC-1'', NULL, NULL, 1)');
SELECT t.refuse('B hors caisse avec session', 'SELECT mf.saisir_operation_generale(1::smallint, ''virement_fournisseur'', ''2026-11-10'', 10000, NULL, ''VIR-1'', NULL, 1, 1)');
SELECT t.refuse('B caisse insuffisante', 'SELECT mf.saisir_operation_generale(1::smallint, ''depense_diverse'', ''2026-11-10'', 24000, NULL, ''F'', NULL, 2, 1); SELECT mf.saisir_operation_generale(1::smallint, ''depense_diverse'', ''2026-11-10'', 24000, NULL, ''F'', NULL, 2, 1); SELECT mf.saisir_operation_generale(1::smallint, ''depense_diverse'', ''2026-11-10'', 24000, NULL, ''F'', NULL, 2, 1); SELECT mf.saisir_operation_generale(1::smallint, ''depense_diverse'', ''2026-11-10'', 24000, NULL, ''F'', NULL, 2, 1); SELECT mf.saisir_operation_generale(1::smallint, ''depense_diverse'', ''2026-11-10'', 24000, NULL, ''F'', NULL, 2, 1)');
SELECT t.eq('B session 2 intacte après le refus', solde_theorique::text, '100000') FROM v_session_caisse_solde WHERE session_id = 2;
SELECT saisir_operation_generale(1::smallint, 'achat_fournitures', '2026-11-10', 10000, 'Papeterie Kodjo', 'FAC-1', NULL, 1, 1, 'cle-b-1');
SELECT t.eq('B sous le seuil : validée à la saisie', statut || '/' || decide_par::text, 'valide/1') FROM operation_generale WHERE cle = 'cle-b-1';
SELECT t.eq('B sortie de caisse créée', type || '/' || motif || '/' || montant, 'decaissement/achat_fournitures/10000') FROM operation_caisse WHERE id = (SELECT operation_caisse_id FROM operation_generale WHERE cle = 'cle-b-1');
SELECT t.eq('B solde de la caisse', solde_theorique::text, '990000') FROM v_session_caisse_solde WHERE session_id = 1;
SELECT t.eq('B saisie rejouée avec la même clé', (saisir_operation_generale(1::smallint, 'achat_fournitures', '2026-11-10', 10000, 'Papeterie Kodjo', 'FAC-1', NULL, 1, 1, 'cle-b-1') = (SELECT id FROM operation_generale WHERE cle = 'cle-b-1') AND (SELECT count(*) FROM operation_caisse WHERE motif = 'achat_fournitures') = 1)::text, 'true');
SELECT saisir_operation_generale(1::smallint, 'achat_fournitures', '2026-11-10', 60000, 'Papeterie Kodjo', 'FAC-2', NULL, 1, 1, 'cle-b-2');
SELECT t.eq('B au-dessus du seuil : à valider, caisse intacte', statut || '/' || COALESCE(operation_caisse_id::text, 'aucune'), 'a_valider/aucune') FROM operation_generale WHERE cle = 'cle-b-2';
SELECT t.refuse('B le saisisseur ne valide pas au-dessus du seuil', 'SELECT mf.decider_operation_generale((SELECT id FROM mf.operation_generale WHERE cle=''cle-b-2''), true, 1)');
SELECT t.refuse('B rejet non motivé', 'SELECT mf.decider_operation_generale((SELECT id FROM mf.operation_generale WHERE cle=''cle-b-2''), false, 2)');
SELECT t.eq('B validation par un second responsable', decider_operation_generale((SELECT id FROM operation_generale WHERE cle='cle-b-2'), true, 2, 'Facture contrôlée'), 'valide');
SELECT t.eq('B caisse mouvementée à la validation', solde_theorique::text, '930000') FROM v_session_caisse_solde WHERE session_id = 1;
SELECT t.refuse('B opération décidée non modifiable', 'UPDATE mf.operation_generale SET statut = ''annule'' WHERE cle = ''cle-b-2''');
SELECT t.refuse('B opération non supprimable', 'DELETE FROM mf.operation_generale WHERE cle = ''cle-b-2''');
SELECT t.refuse('B décision sur une opération déjà décidée', 'SELECT mf.decider_operation_generale((SELECT id FROM mf.operation_generale WHERE cle=''cle-b-2''), true, 2)');
SELECT saisir_operation_generale(1::smallint, 'paiement_loyer', '2026-11-10', 150000, 'Bailleur', 'QUIT-1', NULL, 1, 1, 'cle-b-3');
SELECT t.eq('B rejet motivé', decider_operation_generale((SELECT id FROM operation_generale WHERE cle='cle-b-3'), false, 2, 'Quittance illisible'), 'rejete');
SELECT t.eq('B rejet : aucune sortie de caisse', solde_theorique::text, '930000') FROM v_session_caisse_solde WHERE session_id = 1;
SELECT saisir_operation_generale(1::smallint, 'virement_fournisseur', '2026-11-10', 500000, 'Fournisseur', 'VIR-1', NULL, NULL, 1, 'cle-b-4');
SELECT t.eq('B hors caisse : aucun mouvement de caisse', (operation_caisse_id IS NULL)::text || '/' || statut, 'true/valide') FROM operation_generale WHERE cle = 'cle-b-4';

-- ===== C. Écritures comptables =====
SELECT t.eq('C rien n''est comptabilisé tant que le paramètre est à « non »', count(*)::text, '0') FROM piece_comptable;
UPDATE parametre SET valeur = 'oui' WHERE cle = 'comptabilisation_auto';
SELECT saisir_operation_generale(1::smallint, 'frais_communication', '2026-11-11', 8000, 'Togocel', NULL, NULL, 1, 1, 'cle-c-1');
SELECT t.eq('C charge de caisse : débit 6227', t.sd(1, '6227'), '8000');
SELECT t.eq('C charge de caisse : crédit 1011', t.sd(1, '1011'), '-8000');
SELECT t.eq('C pièce rattachée à l''opération', (piece_id IS NOT NULL)::text, 'true') FROM operation_generale WHERE cle = 'cle-c-1';
SELECT saisir_operation_generale(1::smallint, 'facture_loyer_a_payer', '2026-11-11', 120000, 'Bailleur', 'FAC-LOY', NULL, NULL, 1, 'cle-c-2');
SELECT t.eq('C charge à payer : débit 6212 / crédit fournisseur', t.sd(1, '6212') || '/' || t.sd(1, '33211'), '120000/-120000');
SELECT t.eq('C la caisse n''est pas touchée par le hors caisse', t.sd(1, '1011'), '-8000');

-- ===== D. Transfert de fonds avec accusé de réception =====
SELECT t.refuse('D même caisse', 'SELECT mf.envoyer_fonds(1, 1, 1000, ''x'', 1, ''2026-11-12'')');
SELECT t.refuse('D fonds insuffisants', 'SELECT mf.envoyer_fonds(2, 3, 900000, ''x'', 1, ''2026-11-12'')');
SELECT envoyer_fonds(1, 3, 300000, 'Approvisionnement de Kpalimé', 1, '2026-11-12');
SELECT t.eq('D référence et état', ((statut || '/' || reference) LIKE 'envoye/TF-%')::text, 'true') FROM transfert_fonds WHERE motif LIKE 'Approvisionnement%';
SELECT t.eq('D la caisse d''envoi est débitée', solde_theorique::text, '622000') FROM v_session_caisse_solde WHERE session_id = 1;
SELECT t.eq('D fonds en transit', nb::text || '/' || montant::text, '1/300000') FROM v_fonds_en_transit WHERE agence_id = 1;
SELECT t.eq('D envoi comptabilisé : fonds en transit 378', t.sd(1, '378'), '300000');
SELECT t.refuse('D l''expéditeur ne réceptionne pas', 'SELECT mf.recevoir_fonds((SELECT id FROM mf.transfert_fonds WHERE motif LIKE ''Approvisionnement%''), 3, 300000, 1)');
SELECT t.refuse('D mauvaise session de réception', 'SELECT mf.recevoir_fonds((SELECT id FROM mf.transfert_fonds WHERE motif LIKE ''Approvisionnement%''), 2, 300000, 3)');
SELECT t.refuse('D écart non expliqué', 'SELECT mf.recevoir_fonds((SELECT id FROM mf.transfert_fonds WHERE motif LIKE ''Approvisionnement%''), 3, 290000, 3)');
SELECT t.eq('D réception avec écart expliqué', recevoir_fonds((SELECT id FROM transfert_fonds WHERE motif LIKE 'Approvisionnement%'), 3, 290000, 3, 'Une liasse de 10 000 F manquante')::text, '-10000');
SELECT t.eq('D état après réception', statut || '/' || montant_recu::text || '/' || ecart::text, 'recu/290000/-10000') FROM transfert_fonds WHERE motif LIKE 'Approvisionnement%';
SELECT t.eq('D la caisse de réception est créditée du montant reçu', solde_theorique::text, '490000') FROM v_session_caisse_solde WHERE session_id = 3;
SELECT t.eq('D plus de fonds en transit', count(*)::text, '0') FROM v_fonds_en_transit WHERE agence_id = 1;
SELECT t.eq('D réception comptabilisée : caisse, manquant, transit soldé côté destinataire', t.sd(2, '1011') || '/' || t.sd(2, '6716') || '/' || t.sd(2, '378'), '290000/10000/-300000');
SELECT t.refuse('D transfert réceptionné non modifiable', 'UPDATE mf.transfert_fonds SET motif = ''autre'' WHERE motif LIKE ''Approvisionnement%''');
SELECT t.refuse('D transfert non supprimable', 'DELETE FROM mf.transfert_fonds');
SELECT t.refuse('D double réception', 'SELECT mf.recevoir_fonds((SELECT id FROM mf.transfert_fonds WHERE motif LIKE ''Approvisionnement%''), 3, 290000, 3)');
-- refus avec retour à la caisse d'origine
SELECT envoyer_fonds(2, 1, 50000, 'Retour de fonds du guichet', 1, '2026-11-12');
SELECT t.refuse('D refus non motivé', 'SELECT mf.refuser_fonds((SELECT id FROM mf.transfert_fonds WHERE motif LIKE ''Retour de fonds%''), 2, 2, ''x'')');
SELECT t.refuse('D retour sur une autre caisse que l''origine', 'SELECT mf.refuser_fonds((SELECT id FROM mf.transfert_fonds WHERE motif LIKE ''Retour de fonds%''), 1, 2, ''Billets suspects'')');
SELECT refuser_fonds((SELECT id FROM transfert_fonds WHERE motif LIKE 'Retour de fonds%'), 2, 2, 'Billets suspects, à vérifier');
SELECT t.eq('D refus : fonds revenus à l''origine', t.statut || '/' || v.solde_theorique::text, 'refuse/100000') FROM transfert_fonds t, v_session_caisse_solde v WHERE t.motif LIKE 'Retour de fonds%' AND v.session_id = 2;
-- retard
SELECT envoyer_fonds(1, 2, 20000, 'Transfert resté sans réponse', 1, '2026-11-12');
UPDATE transfert_fonds SET envoye_le = now() - interval '3 days' WHERE motif LIKE 'Transfert resté%';
SELECT t.eq('D alerte de transfert en retard', en_retard::text, 'true') FROM v_transfert_fonds WHERE motif LIKE 'Transfert resté%';
