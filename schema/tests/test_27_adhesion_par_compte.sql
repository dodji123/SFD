SET search_path = mf, public;

-- Module sous test : 24 + 27 (adhésion et parts sociales par compte d'épargne)
INSERT INTO agence(code,libelle) VALUES ('LOM','Lomé Centre');
INSERT INTO utilisateur(agence_id,login,nom,role) VALUES (1,'caisse','Caissier','caissier');
INSERT INTO produit_epargne(code,libelle,categorie) VALUES ('CL','Classique','classique'),('CL2','Classique 2','classique');
INSERT INTO produit_epargne(code,libelle,categorie,type_cycle) VALUES ('T1','Tontine','collecte',1);
INSERT INTO client(agence_id,nom) VALUES (1,'Membre un'),(1,'Membre deux');

SELECT t.eq('A paramètres par défaut', mf.param_num('part_valeur_nominale', 1::smallint)::text || '/' || mf.param_num('droit_adhesion', 1::smallint)::text || '/' || mf.param_num('parts_minimum', 1::smallint)::text, '5000/2000/1');

-- ===== A. Ouverture d'un compte avec son adhésion et ses parts =====
SELECT t.refuse('A zéro part', 'SELECT mf.ouvrir_compte_adherent(1, 1, 0, current_date, 1)');
SELECT t.refuse('A parts absentes', 'SELECT mf.ouvrir_compte_adherent(1, 1, NULL, current_date, 1)');
SELECT t.refuse('A produit de tontine refusé', 'SELECT mf.ouvrir_compte_adherent(1, 3, 1, current_date, 1)');
SELECT t.eq('A rien n''a été créé par les refus', (SELECT count(*) FROM compte_epargne)::text || '/' || (SELECT count(*) FROM adhesion)::text, '0/0');
SELECT ouvrir_compte_adherent(1, 1, 3, current_date, 1);
SELECT t.eq('A compte, adhésion et 3 parts de 5000 créés ensemble', ce.numero || ' ' || m.numero || ' ' || m.nb_parts || '/' || m.capital_souscrit,
            'CE-LOM-' || extract(year FROM current_date) || '-000001 AD-LOM-' || extract(year FROM current_date) || '-000001 3/15000')
  FROM compte_epargne ce JOIN v_membre m ON m.compte_id = ce.id;
SELECT t.eq('A droit d''adhésion enregistré', droit_adhesion::text, '2000') FROM adhesion;
SELECT t.eq('A compte en règle', membre_en_regle(1)::text, 'true');

-- ===== B. Un autre compte du même client a sa propre adhésion =====
SELECT t.eq('B second compte du même client', (ouvrir_compte_adherent(1, 2, 1, current_date, 1) = 2)::text, 'true');
SELECT t.eq('B deux adhésions distinctes pour le client', count(*)::text, '2') FROM adhesion WHERE client_id = 1;
SELECT t.eq('B parts propres à chaque compte', string_agg(nb_parts::text, ',' ORDER BY compte_id), '3,1') FROM v_membre;
SELECT t.refuse('B adhésion déjà existante sur le compte', 'SELECT mf.adherer_compte(1, current_date, 1)');

-- ===== C. Compte ouvert sans adhésion (données antérieures) et parts supplémentaires =====
INSERT INTO compte_epargne(agence_id,client_id,produit_id) VALUES (1,2,1);
SELECT t.eq('C compte sans adhésion : pas en règle', membre_en_regle(3)::text, 'false');
SELECT t.refuse('C parts sans adhésion', 'SELECT mf.souscrire_parts_compte(3, 1, current_date, 1)');
SELECT t.refuse('C adhésion future', 'SELECT mf.adherer_compte(3, current_date + 1, 1)');
SELECT adherer_compte(3, current_date, 1);
SELECT t.eq('C adhérent sans part : pas en règle', membre_en_regle(3)::text, 'false');
SELECT t.refuse('C zéro part', 'SELECT mf.souscrire_parts_compte(3, 0, current_date, 1)');
SELECT t.refuse('C part future', 'SELECT mf.souscrire_parts_compte(3, 1, current_date + 1, 1)');
SELECT souscrire_parts_compte(3, 2, current_date, 1);
SELECT t.eq('C en règle avec 2 parts', membre_en_regle(3)::text, 'true');
UPDATE parametre SET valeur = '10000' WHERE cle = 'part_valeur_nominale';
SELECT souscrire_parts_compte(3, 1, current_date, 1);
SELECT t.eq('C ancienne souscription conserve sa valeur (2 x 5000 + 1 x 10000)', capital_souscrit::text, '20000') FROM v_membre WHERE compte_id = 3;
UPDATE parametre SET valeur = '5000' WHERE cle = 'part_valeur_nominale';
UPDATE parametre SET valeur = '4' WHERE cle = 'parts_minimum';
SELECT t.eq('C minimum relevé à 4 : 3 parts ne suffisent plus', membre_en_regle(3)::text, 'false');
SELECT t.refuse('C ouverture refusée sous le minimum relevé', 'SELECT mf.ouvrir_compte_adherent(2, 1, 3, current_date, 1)');
UPDATE parametre SET valeur = '1' WHERE cle = 'parts_minimum';

-- ===== D. Sortie : parts remboursées, adhésion radiée, compte clos =====
INSERT INTO mouvement_epargne(compte_id,type,montant,date_operation) VALUES (2,'depot',3000,current_date);
SELECT t.refuse('D solde encore présent', 'SELECT mf.radier_adhesion_compte(2, current_date, 1)');
SELECT t.refuse('D date future', 'SELECT mf.radier_adhesion_compte(1, current_date + 1, 1)');
INSERT INTO cycle(agence_id,client_id,produit_id,type_cycle,mise_initiale,mise_courante,objectif,nb_lignes_prevues,date_debut,date_fin)
VALUES (1,1,3,1,500,500,15500,31,current_date - 5,current_date + 25);
SELECT lier_cycle_compte(1, 1, 1);
SELECT t.refuse('D tontine en cours reliée au compte', 'SELECT mf.radier_adhesion_compte(1, current_date, 1)');
SELECT delier_cycle_compte(1);
SELECT t.eq('D parts remboursées : 3 x 5000', radier_adhesion_compte(1, current_date, 1)::text, '15000');
SELECT t.eq('D adhésion radiée, remboursement enregistré, compte clos', a.statut || '/' || r.nb_parts || '/' || r.montant || '/' || ce.statut, 'radiee/3/15000/clos')
  FROM adhesion a JOIN remboursement_part r ON r.adhesion_id = a.id JOIN compte_epargne ce ON ce.id = a.compte_id WHERE a.compte_id = 1;
SELECT t.eq('D le compte radié n''est plus en règle', membre_en_regle(1)::text, 'false');
SELECT t.eq('D l''autre compte du client reste en règle', membre_en_regle(2)::text, 'true');
SELECT t.refuse('D déjà radiée', 'SELECT mf.radier_adhesion_compte(1, current_date, 1)');
SELECT t.refuse('D parts sur adhésion radiée', 'SELECT mf.souscrire_parts_compte(1, 1, current_date, 1)');
