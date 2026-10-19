SET search_path = mf, public;

-- Module sous test : 17_kyc_lbc.sql (KYC, garants, liste de surveillance, alertes LBC/FT, garde-fous du crédit)
INSERT INTO agence(code,libelle) VALUES ('LOM','Lomé Centre');
INSERT INTO utilisateur(agence_id,login,nom,role) VALUES (1,'chef','Chef','chef_agence');
INSERT INTO produit_credit_epargne(code,libelle,type,taux_annuel,frais_dossier_taux,periodicite_jours,methode)
VALUES ('PCS1','Crédit sans épargne','sans_epargne',0.12,0,30,'capital_constant');
INSERT INTO client(agence_id,numero,nom,telephone) VALUES
  (1,'C1','Ama Josiane Kouassi','90000001'),(1,'C2','Koffi Mensah','90000002'),(1,'C3','Société Agro SARL','90000003'),(1,'C4','Yaovi Agbeko','90000004');

-- ===== A. Complétude du KYC =====
SELECT t.eq('A client neuf : incomplet', statut_kyc, 'incomplet') FROM client WHERE id = 1;
SELECT t.eq('A éléments manquants', array_to_string(kyc_manquants(1), ' / '), 'date de naissance / sexe / adresse / pièce d''identité valide');
SELECT t.refuse('A validation refusée tant qu''incomplet', 'SELECT mf.valider_kyc(1, 1)');
UPDATE client SET date_naissance = '1985-03-02', sexe = 'F', adresse = 'Quartier Bè, Lomé', profession = 'commerçante',
                  latitude_domicile = 6.13, longitude_domicile = 1.22 WHERE id = 1;
INSERT INTO piece_identite(client_id,type,numero,date_emission,date_expiration) VALUES (1,'cni','TG123456','2020-01-01','2020-12-31');
SELECT t.eq('A pièce expirée ne compte pas', array_to_string(kyc_manquants(1), ' / '), 'pièce d''identité valide');
INSERT INTO piece_identite(client_id,type,numero,date_emission,date_expiration) VALUES (1,'passeport','P998877','2024-01-01','2034-01-01');
SELECT t.eq('A rien ne manque', cardinality(kyc_manquants(1))::text, '0');
SELECT valider_kyc(1, 1, '2026-10-19');
SELECT t.eq('A client validé', statut_kyc || ' ' || kyc_valide_le || ' ' || kyc_valide_par, 'complet 2026-10-19 1') FROM client WHERE id = 1;
SELECT t.refuse('A même pièce sur deux clients', 'INSERT INTO mf.piece_identite(client_id,type,numero) VALUES (2,''passeport'',''P998877'')');
SELECT t.refuse('A latitude hors plage', 'UPDATE mf.client SET latitude_domicile = 95 WHERE id = 1');
SELECT t.refuse('A type de client inconnu', 'UPDATE mf.client SET type_client = ''xyz'' WHERE id = 1');

-- Personne morale : document d'existence légale à la place de la pièce d'identité
UPDATE client SET type_client = 'personne_morale', adresse = 'Zone industrielle' WHERE id = 3;
SELECT t.eq('A personne morale : document légal exigé', array_to_string(kyc_manquants(3), ' / '), 'document d''existence légale valide');
INSERT INTO piece_identite(client_id,type,numero) VALUES (3,'registre_commerce','RCCM-TG-2020-B-1234');
SELECT t.eq('A personne morale complète', cardinality(kyc_manquants(3))::text, '0');
SELECT valider_kyc(3, 1);

-- Expiration : la tâche quotidienne repasse un client à incomplet
UPDATE piece_identite SET date_expiration = current_date - 1, date_emission = '2020-01-01' WHERE numero = 'P998877';
SELECT t.eq('A tâche d''expiration : un client rétrogradé', maj_statut_kyc()::text, '1');
SELECT t.eq('A client rétrogradé', statut_kyc, 'incomplet') FROM client WHERE id = 1;
SELECT t.eq('A pièces à renouveler (expirées)', count(*)::text, '2') FROM v_pieces_a_renouveler;
UPDATE piece_identite SET date_expiration = '2034-01-01' WHERE numero = 'P998877';
SELECT valider_kyc(1, 1);

-- ===== B. Liens entre clients =====
INSERT INTO lien_client(client_id,lie_a_id,type) VALUES (1,2,'famille');
SELECT t.refuse('B lien d''un client avec lui-même', 'INSERT INTO mf.lien_client(client_id,lie_a_id,type) VALUES (1,1,''famille'')');
SELECT t.refuse('B lien en double', 'INSERT INTO mf.lien_client(client_id,lie_a_id,type) VALUES (1,2,''famille'')');

-- ===== C. Filtrage LBC/FT =====
INSERT INTO liste_surveillance(source,categorie,nom,date_naissance,pays,reference) VALUES
  ('ONU','sanction','KOUASSI Ama Josiane',NULL,'TG','UN-001'),
  ('Liste nationale','ppe','Mensah Koffi',NULL,'TG','PPE-7'),
  ('ONU','sanction','Josiane Kouassi Ama','1970-05-05','CI','UN-002'),
  ('ONU','sanction','Ibrahim Traoré',NULL,'ML','UN-003');
SELECT t.eq('C ordre des mots et accents indifférents', cle_nom('Kouassi  Ama-Josiane'), cle_nom('AMA JOSIANE KOUASSÎ'));
SELECT t.eq('C rapprochement du client existant', string_agg(type || ':' || statut, ' ' ORDER BY type), 'sanction:a_examiner') FROM alerte_lbc WHERE client_id = 1;
SELECT t.eq('C date de naissance différente : pas d''alerte (UN-002 écartée)', count(*)::text, '1') FROM alerte_lbc WHERE client_id = 1;
SELECT t.eq('C PPE détecté sur le client 2', string_agg(type, ','), 'ppe') FROM alerte_lbc WHERE client_id = 2;
SELECT t.eq('C aucune alerte sans ressemblance', count(*)::text, '0') FROM alerte_lbc WHERE client_id IN (3, 4);
INSERT INTO client(agence_id,numero,nom) VALUES (1,'C5','Ibrahim TRAORE');
SELECT t.eq('C nouveau client filtré à la création', string_agg(type, ','), 'sanction') FROM alerte_lbc WHERE client_id = 5;
SELECT t.eq('C KYC bloqué par l''alerte ouverte', array_to_string(kyc_manquants(1), ' / '), 'alerte LBC/FT à examiner');

-- ===== D. Garde-fous du crédit =====
SELECT t.refuse('D demande refusée avec alerte de sanction ouverte', 'SELECT mf.nouvelle_demande_credit(1,NULL,1,10000,2,0.12,0,''especes'',''x'')');
SELECT t.refuse('D écarter sans justification', 'SELECT mf.traiter_alerte_lbc(1, ''ecartee'')');
SELECT t.refuse('D décision inconnue', 'SELECT mf.traiter_alerte_lbc(1, ''peut-etre'', ''x'')');
SELECT traiter_alerte_lbc((SELECT id FROM alerte_lbc WHERE client_id = 1), 'ecartee', 'homonyme : date de naissance et ville différentes', 1);
SELECT t.eq('D alerte écartée tracée', statut || ' ' || decide_par, 'ecartee 1') FROM alerte_lbc WHERE client_id = 1;
SELECT t.refuse('D alerte déjà traitée', format('SELECT mf.traiter_alerte_lbc(%s, ''confirmee'', ''x'')', (SELECT id FROM alerte_lbc WHERE client_id = 1)));
SELECT t.eq('D demande acceptée après examen', (nouvelle_demande_credit(1,NULL,1,10000,2,0.12,0,'especes','x') IS NOT NULL)::text, 'true');

-- Confirmation d'une PPE : le client est marqué ; confirmation d'une sanction : KYC remis à incomplet et crédit bloqué
SELECT traiter_alerte_lbc((SELECT id FROM alerte_lbc WHERE client_id = 2), 'confirmee', 'ancien ministre', 1);
SELECT t.eq('D client PPE', ppe::text, 'true') FROM client WHERE id = 2;
SELECT traiter_alerte_lbc((SELECT id FROM alerte_lbc WHERE client_id = 5), 'confirmee', 'identité confirmée', 1);
SELECT t.eq('D sanction confirmée : KYC incomplet', (array_to_string(kyc_manquants(5), ' / ') LIKE '%sanction confirmée%')::text, 'true');
SELECT t.refuse('D demande refusée avec sanction confirmée', 'SELECT mf.nouvelle_demande_credit(5,NULL,1,10000,2,0.12,0,''especes'',''x'')');

-- KYC obligatoire pour le crédit (paramètre)
UPDATE parametre SET valeur = 'oui' WHERE cle = 'kyc_obligatoire_credit' AND agence_id IS NULL;
SELECT t.refuse('D KYC incomplet refusé quand obligatoire', 'SELECT mf.nouvelle_demande_credit(4,NULL,1,10000,2,0.12,0,''especes'',''x'')');
SELECT t.eq('D KYC complet accepté quand obligatoire', (nouvelle_demande_credit(1,NULL,1,12000,2,0.12,0,'especes','y') IS NOT NULL)::text, 'true');
UPDATE parametre SET valeur = 'non' WHERE cle = 'kyc_obligatoire_credit' AND agence_id IS NULL;

-- ===== E. Garants =====
INSERT INTO garant_credit(demande_id,garant_client_id,montant_caution) VALUES ((SELECT min(id) FROM demande_credit), 3, 5000);
SELECT t.eq('E garant enregistré', count(*)::text, '1') FROM garant_credit;
SELECT t.refuse('E auto-garantie', 'INSERT INTO mf.garant_credit(demande_id,garant_client_id,montant_caution) VALUES ((SELECT min(id) FROM mf.demande_credit),1,5000)');
SELECT t.refuse('E garant sans KYC complet', 'INSERT INTO mf.garant_credit(demande_id,garant_client_id,montant_caution) VALUES ((SELECT min(id) FROM mf.demande_credit),4,5000)');
SELECT t.refuse('E même garant deux fois', 'INSERT INTO mf.garant_credit(demande_id,garant_client_id,montant_caution) VALUES ((SELECT min(id) FROM mf.demande_credit),3,1000)');
SELECT t.refuse('E sans demande ni crédit', 'INSERT INTO mf.garant_credit(garant_client_id,montant_caution) VALUES (3,1000)');
SELECT t.eq('E audit des alertes', (count(*) >= 3)::text, 'true') FROM audit_log WHERE table_name = 'alerte_lbc';
