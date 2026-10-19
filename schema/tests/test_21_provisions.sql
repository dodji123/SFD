SET search_path = mf, public;

-- Module sous test : 21_provisions.sql (classification des créances, provisions réglementaires et internes, pièces de dotation et de reprise)
INSERT INTO agence(code,libelle) VALUES ('LOM','Lomé Centre'),('KPA','Kpalimé');
INSERT INTO utilisateur(agence_id,login,nom,role) VALUES (1,'compta','Comptable','comptable');
INSERT INTO exercice_comptable(code,date_debut,date_fin) VALUES ('2026','2026-01-01','2026-12-31'),('2027','2027-01-01','2027-12-31');
INSERT INTO produit_epargne(code,libelle,categorie) VALUES ('CL','Compte classique','classique');
INSERT INTO client(agence_id,numero,nom) VALUES (1,'C1','Sain'),(1,'C2','Retard 60 j'),(1,'C3','Retard 150 j'),(1,'C4','Retard 270 j'),(1,'C5','Retard 500 j'),(1,'C6','Retard 800 j');

-- Un crédit de 100000 par client, sans aucun remboursement. 1re échéance = déblocage + 30 jours ; au 31/12/2026 le retard vaut
-- (31/12 - déblocage - 30) : 0, 60, 150, 270, 500 et 800 jours.
INSERT INTO credit(agence_id,numero,client_id,type,montant_accorde,taux,date_deblocage,nb_echeances,mode_remboursement)
SELECT 1, 'CR-' || c.id, c.id, 'sans_epargne', 100000, 0.12, DATE '2026-12-31' - (j.jours + 30), 12, 'especes'
  FROM client c JOIN (VALUES (1, 0), (2, 60), (3, 150), (4, 270), (5, 500), (6, 800)) AS j(client, jours) ON j.client = c.id;
SELECT generer_echeancier(id) FROM credit ORDER BY id;
-- Le client 3 a 20000 de dépôt en garantie
INSERT INTO compte_epargne(agence_id,client_id,produit_id,numero) VALUES (1,3,1,'CE-3');
INSERT INTO garantie_compte(credit_id,compte_id,montant_bloque,montant_restant) VALUES ((SELECT id FROM credit WHERE numero = 'CR-3'), 1, 20000, 20000);

-- ===== A. Classification =====
SELECT t.eq('A anciennetés et classes', string_agg(numero || ':' || jours_retard || ':' || classe, ' ' ORDER BY jours_retard DESC),
            'CR-6:800:irrecouvrable CR-5:500:12_24 CR-4:270:6_12 CR-3:150:3_6 CR-2:60:0_3 CR-1:0:sain') FROM classification_creances(1::smallint,'2026-12-31');
SELECT t.eq('A déclassement : seuls les crédits de plus de 3 mois (0 à 3 mois facultatif)', string_agg(numero || '=' || COALESCE(compte_encours, '-'), ' ' ORDER BY numero),
            'CR-1=- CR-2=- CR-3=2922 CR-4=293 CR-5=294 CR-6=294') FROM classification_creances(1::smallint,'2026-12-31');
SELECT t.eq('A solde restant dû = encours - dépôt de garantie', solde_restant_du::text, '80000') FROM classification_creances(1::smallint,'2026-12-31') WHERE numero = 'CR-3';

-- ===== B. Provisions réglementaires : 40 %, 80 %, 100 % du solde restant dû =====
SELECT t.eq('B provisions par crédit', string_agg(numero || ':' || provision_retenue || ':' || COALESCE(compte_provision, '-'), ' ' ORDER BY numero),
            'CR-1:0:- CR-2:0:- CR-3:32000:29912 CR-4:80000:2992 CR-5:100000:2993 CR-6:100000:2993') FROM classification_creances(1::smallint,'2026-12-31');
SELECT t.eq('B créance de plus de 24 mois : à passer en perte', string_agg(numero, ','), 'CR-6') FROM classification_creances(1::smallint,'2026-12-31') WHERE a_passer_en_perte;
SELECT t.eq('B rapport : provision totale 312000, 6 classes', sum(provision_retenue)::text || '/' || count(*), '312000/6') FROM rapport_provisions(1::smallint,'2026-12-31');
SELECT t.eq('B rapport : classe 3 à 6 mois', nb_credits || ' ' || encours || ' ' || solde_restant_du || ' ' || provision_retenue, '1 100000 80000 32000') FROM rapport_provisions(1::smallint,'2026-12-31') WHERE classe = '3_6';
SELECT t.eq('B réseau entier = agence 1 (l''agence 2 est vide)', sum(provision_retenue)::text, '312000') FROM rapport_provisions(NULL,'2026-12-31');

-- ===== C. Options facultatives de la tranche 0 à 3 mois =====
UPDATE parametre SET valeur = 'oui' WHERE cle = 'prov_declasser_0_3m' AND agence_id IS NULL;
SELECT t.eq('C déclassement facultatif activé : CR-2 en 2921, sans provision', compte_encours || ' ' || provision_retenue, '2921 0') FROM classification_creances(1::smallint,'2026-12-31') WHERE numero = 'CR-2';
UPDATE parametre SET valeur = 'oui' WHERE cle = 'prov_provisionner_0_3m' AND agence_id IS NULL;
SELECT t.eq('C provision facultative activée : 40 % de 100000 au compte 29911', provision_retenue || ' ' || compte_provision, '40000 29911') FROM classification_creances(1::smallint,'2026-12-31') WHERE numero = 'CR-2';
UPDATE parametre SET valeur = 'non' WHERE cle IN ('prov_declasser_0_3m', 'prov_provisionner_0_3m') AND agence_id IS NULL;

-- ===== D. Règle interne plus stricte : la plus élevée des deux est retenue, les deux sont affichées =====
INSERT INTO parametre(cle,valeur,description) VALUES ('prov_interne_3_6m', '60', 'règle interne');
SELECT t.eq('D règle interne 60 % : réglementaire 32000, interne 48000, retenue 48000', provision_reglementaire || '/' || provision_interne || '/' || provision_retenue, '32000/48000/48000')
  FROM classification_creances(1::smallint,'2026-12-31') WHERE numero = 'CR-3';
UPDATE parametre SET valeur = '30' WHERE cle = 'prov_interne_3_6m';
SELECT t.eq('D règle interne plus clémente : la règle réglementaire s''impose', provision_retenue::text, '32000') FROM classification_creances(1::smallint,'2026-12-31') WHERE numero = 'CR-3';
DELETE FROM parametre WHERE cle = 'prov_interne_3_6m';

-- ===== E. Écarts et pièce de dotation =====
SELECT t.eq('E aucune provision constituée : écart = provision requise', string_agg(compte || ':' || delta, ' ' ORDER BY compte), '29911:0 29912:32000 2992:80000 2993:200000') FROM ecarts_provisions(1::smallint,'2026-12-31');
SELECT t.eq('E pièce de dotation passée', (generer_provisions(1::smallint,'2026-12-31', 1) IS NOT NULL)::text, 'true');
SELECT t.eq('E pièce équilibrée : total des débits = total des crédits = 312000', sum(debit)::text || '/' || sum(credit)::text, '312000/312000')
  FROM ecriture e JOIN piece_comptable p ON p.id = e.piece_id WHERE p.evenement = 'provision_creances';
SELECT t.eq('E dotations aux bons comptes', string_agg(compte_code || ':' || debit, ' ' ORDER BY compte_code), '66412:32000 6642:80000 6643:200000')
  FROM ecriture e JOIN piece_comptable p ON p.id = e.piece_id WHERE p.evenement = 'provision_creances' AND debit > 0;
SELECT t.eq('E provisions constituées', string_agg(compte || ':' || montant, ' ' ORDER BY compte), '29911:0 29912:32000 2992:80000 2993:200000') FROM provisions_constituees(1::smallint,'2026-12-31');
SELECT t.eq('E plus aucun écart', count(*)::text, '0') FROM ecarts_provisions(1::smallint,'2026-12-31') WHERE delta <> 0;
SELECT t.refuse('E même jour : provisions déjà passées', 'SELECT mf.generer_provisions(1::smallint, ''2026-12-31'', 1)');

-- ===== F. Reprise : la provision requise baisse =====
UPDATE parametre SET valeur = '50' WHERE cle = 'prov_taux_24m' AND agence_id IS NULL;
SELECT t.eq('F écart négatif sur 2993 : reprise de 100000', delta::text, '-100000') FROM ecarts_provisions(1::smallint,'2027-01-05') WHERE compte = '2993';
SELECT t.eq('F pièce de reprise passée', (generer_provisions(1::smallint,'2027-01-05', 1) IS NOT NULL)::text, 'true');
SELECT t.eq('F reprise : débit du compte de provision, crédit du compte de reprises', (SELECT debit::text FROM ecriture e JOIN piece_comptable p ON p.id = e.piece_id WHERE p.date_piece = '2027-01-05' AND e.compte_code = '2993')
            || '/' || (SELECT credit::text FROM ecriture e JOIN piece_comptable p ON p.id = e.piece_id WHERE p.date_piece = '2027-01-05' AND e.compte_code = '7643'), '100000/100000');
SELECT t.eq('F solde du compte 2993 après reprise', montant::text, '100000') FROM provisions_constituees(1::smallint,'2027-01-05') WHERE compte = '2993';
UPDATE parametre SET valeur = '100' WHERE cle = 'prov_taux_24m' AND agence_id IS NULL;

-- ===== G. Garde-fous =====
SELECT t.refuse('G agence obligatoire pour passer les écritures', 'SELECT mf.generer_provisions(NULL, ''2026-12-31'')');
SELECT t.refuse('G exercice comptable absent', 'SELECT mf.generer_provisions(1::smallint, ''2030-01-31'')');
SELECT t.eq('G agence sans crédit : rien à passer', (generer_provisions(2::smallint,'2026-12-31') IS NULL)::text, 'true');

-- ===== H. Mode manuel ou automatique =====
-- Entre le 31/12/2026 et le 10/02/2027 les créances ont vieilli de 41 jours (changements de tranche) : un écart existe.
SELECT t.eq('H mode par défaut : manuel', mf.param('prov_mode'), 'manuel');
SELECT t.eq('H manuel : la tâche automatique ne fait rien', generer_provisions_auto(1::smallint,'2027-02-10')::text, '0');
SELECT t.eq('H manuel : aucune pièce créée à cette date', count(*)::text, '0') FROM piece_comptable WHERE date_piece = '2027-02-10';
UPDATE parametre SET valeur = 'automatique' WHERE cle = 'prov_mode' AND agence_id IS NULL;
SELECT t.eq('H automatique : la tâche passe la pièce du jour', generer_provisions_auto(1::smallint,'2027-02-10')::text, '1');
SELECT t.eq('H automatique : une seule pièce de provisions ce jour', count(*)::text, '1') FROM piece_comptable WHERE date_piece = '2027-02-10' AND evenement = 'provision_creances';
SELECT t.eq('H automatique : pièce équilibrée', (sum(e.debit) = sum(e.credit) AND sum(e.debit) > 0)::text, 'true')
  FROM ecriture e JOIN piece_comptable p ON p.id = e.piece_id WHERE p.date_piece = '2027-02-10' AND p.evenement = 'provision_creances';
SELECT t.eq('H automatique : le niveau constitué rejoint le niveau requis', count(*)::text, '0') FROM ecarts_provisions(1::smallint,'2027-02-10') WHERE delta <> 0;
SELECT t.eq('H automatique : rejeu du même jour sans doublon', generer_provisions_auto(1::smallint,'2027-02-10')::text, '0');
SELECT t.eq('H automatique : lendemain sans changement de tranche, rien à passer', generer_provisions_auto(1::smallint,'2027-02-11')::text, '0');
SELECT t.refuse('H automatique : sans exercice ouvert, l''erreur remonte', 'SELECT mf.generer_provisions_auto(1::smallint, ''2031-03-01'')');
UPDATE parametre SET valeur = 'manuel' WHERE cle = 'prov_mode' AND agence_id IS NULL;
INSERT INTO execution_tache(agence_id, date_tache, tache, statut, nb_traites) VALUES (1, '2027-02-10', 'generer_provisions_auto', 'ok', 1);
SELECT t.eq('H le journal du planificateur accepte la tâche', count(*)::text, '1') FROM execution_tache WHERE tache = 'generer_provisions_auto';
