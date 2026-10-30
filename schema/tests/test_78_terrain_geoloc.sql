SET search_path = mf, public;

-- Module sous test : 78_terrain_geoloc.sql (positions GPS des lieux de travail et visites terrain)
INSERT INTO agence(code,libelle) VALUES ('LOM','Lomé Centre');
INSERT INTO zone(agence_id,code,libelle) VALUES (1,'Z1','Zone Marché');
INSERT INTO client(agence_id,zone_id,numero,nom) VALUES (1,1,'C001','Un'),(1,1,'C002','Deux');
INSERT INTO utilisateur(agence_id,login,nom,role) VALUES (1,'agent.terrain','Agent terrain','agent');
INSERT INTO credit(agence_id,numero,client_id,type,montant_accorde,taux,date_deblocage,nb_echeances,mode_remboursement)
VALUES (1,'CR-T1',1,'sans_epargne',30000,0.12,'2026-10-01',3,'especes');

-- Position du lieu de travail de l'emprunteur
SELECT t.eq('G position enregistrée', (enregistrer_localisation(1,'lieu_travail',6.137500,1.212200,'Marché de Hédzranawoé',12.5,1) > 0)::text, 'true');
SELECT t.eq('G position rattachée au bon client et à l''agence', count(*)::text, '1') FROM localisation WHERE client_id = 1 AND role = 'lieu_travail' AND agence_id = 1;

-- Coordonnées hors plage refusées
SELECT t.refuse('G latitude hors plage refusée', 'SELECT mf.enregistrer_localisation(1,''lieu_travail'',91,1.2,NULL,NULL,1)');
SELECT t.refuse('G longitude hors plage refusée', 'SELECT mf.enregistrer_localisation(1,''caution'',6.1,181,NULL,NULL,1)');
SELECT t.refuse('G rôle inconnu refusé', 'SELECT mf.enregistrer_localisation(1,''domicile'',6.1,1.2,NULL,NULL,1)');

-- Visite de recouvrement sur le crédit, avec la position du lieu visité
SELECT enregistrer_visite_terrain(
  (SELECT id FROM credit WHERE numero = 'CR-T1'), 'recouvrement', (SELECT id FROM utilisateur WHERE login = 'agent.terrain'),
  (SELECT id FROM localisation WHERE client_id = 1 LIMIT 1), 'Promesse de paiement vendredi', '2026-10-30');
SELECT t.eq('G visite de recouvrement enregistrée', count(*)::text, '1') FROM visite_terrain WHERE type = 'recouvrement' AND credit_id = (SELECT id FROM credit WHERE numero = 'CR-T1');

-- Position d'un autre client : refusée pour la visite du crédit du client 1
SELECT enregistrer_localisation(2,'caution',6.140000,1.200000,'Atelier',NULL,1);
SELECT t.refuse('G position d''un autre client refusée sur la visite', format('SELECT mf.enregistrer_visite_terrain(%s,''visite'',%s,(SELECT id FROM localisation WHERE client_id = 2),NULL,''2026-10-31'')',
  (SELECT id FROM credit WHERE numero = 'CR-T1'), (SELECT id FROM utilisateur WHERE login = 'agent.terrain')));

-- Type de visite inconnu refusé
SELECT t.refuse('G type de visite inconnu refusé', format('SELECT mf.enregistrer_visite_terrain(%s,''contrôle'',%s,NULL,NULL,''2026-10-31'')',
  (SELECT id FROM credit WHERE numero = 'CR-T1'), (SELECT id FROM utilisateur WHERE login = 'agent.terrain')));

-- Synchronisation rejouée : même identifiant mobile, pas de doublon
SELECT t.eq('G position rejouée : même identifiant', (enregistrer_localisation(1,'caution',6.1,1.2,'Atelier',NULL,1,'CLE-A') = enregistrer_localisation(1,'caution',6.1,1.2,'Atelier',NULL,1,'CLE-A'))::text, 'true');
SELECT t.eq('G position rejouée : une seule ligne', count(*)::text, '1') FROM localisation WHERE cle = 'CLE-A';
SELECT enregistrer_visite_terrain((SELECT id FROM credit WHERE numero='CR-T1'),'visite',(SELECT id FROM utilisateur WHERE login='agent.terrain'),NULL,NULL,'2026-10-31','VIS-A');
SELECT enregistrer_visite_terrain((SELECT id FROM credit WHERE numero='CR-T1'),'visite',(SELECT id FROM utilisateur WHERE login='agent.terrain'),NULL,NULL,'2026-10-31','VIS-A');
SELECT t.eq('G visite rejouée : une seule ligne', count(*)::text, '1') FROM visite_terrain WHERE cle = 'VIS-A';
