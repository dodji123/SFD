SET search_path = mf, public;

-- Module sous test : 80_releve_carnet.sql (relevé du carnet et rapprochement carnet / machine)
INSERT INTO agence(code,libelle) VALUES ('LOM','Lomé Centre');
INSERT INTO zone(agence_id,code,libelle) VALUES (1,'Z1','Zone Marché');
INSERT INTO agent(agence_id,matricule,nom) VALUES (1,'A01','Agent Un');
INSERT INTO utilisateur(agence_id,login,nom,role) VALUES (1,'ctrl.carnet','Contrôleur carnet','agent');
INSERT INTO client(agence_id,zone_id,numero,nom) VALUES (1,1,'C1','Un'),(1,1,'C2','Deux'),(1,1,'C3','Trois'),(1,1,'C4','Quatre');
INSERT INTO produit_epargne(code,libelle,categorie,type_cycle,nb_pages_livret) VALUES ('P1','Tontine','collecte',1,1);
INSERT INTO cycle(agence_id,numero,client_id,produit_id,type_cycle,mise_initiale,mise_courante,objectif,date_debut,date_fin) VALUES
  (1,'S1',(SELECT id FROM client WHERE numero='C1'),(SELECT id FROM produit_epargne WHERE code='P1'),1,1000,1000,31000,'2026-10-01','2026-11-30'),
  (1,'S2',(SELECT id FROM client WHERE numero='C2'),(SELECT id FROM produit_epargne WHERE code='P1'),1,1000,1000,31000,'2026-10-01','2026-11-30'),
  (1,'S3',(SELECT id FROM client WHERE numero='C3'),(SELECT id FROM produit_epargne WHERE code='P1'),1,1000,1000,31000,'2026-10-01','2026-11-30'),
  (1,'S4',(SELECT id FROM client WHERE numero='C4'),(SELECT id FROM produit_epargne WHERE code='P1'),1,1000,1000,31000,'2026-10-01','2026-11-30');
-- collectes : S1 = 5 000 ; S2 = aucune ; S3 = 5 000 dont 1 000 retirés
INSERT INTO ligne_collecte(cycle_id,page,no_ligne,date_collecte,agent_id,montant_collecte) VALUES
  ((SELECT id FROM cycle WHERE numero='S1'),1,1,'2026-10-01',(SELECT id FROM agent WHERE matricule='A01'),3000),
  ((SELECT id FROM cycle WHERE numero='S1'),1,2,'2026-10-15',(SELECT id FROM agent WHERE matricule='A01'),2000),
  ((SELECT id FROM cycle WHERE numero='S3'),1,1,'2026-10-01',(SELECT id FROM agent WHERE matricule='A01'),3000),
  ((SELECT id FROM cycle WHERE numero='S3'),1,2,'2026-10-15',(SELECT id FROM agent WHERE matricule='A01'),2000);
INSERT INTO retrait(agence_id,cycle_id,nature,montant,decaissement,statut)
VALUES (1,(SELECT id FROM cycle WHERE numero='S3'),'retrait_client',1000,true,'demande');

-- Relevé de S1 : dates et mise conformes, total des pages = collecte (5 000)
SELECT t.eq('R relevé S1 enregistré', (enregistrer_releve_carnet(
  (SELECT id FROM cycle WHERE numero='S1'), (SELECT id FROM utilisateur WHERE login='ctrl.carnet'),
  '2026-10-01', '2026-11-30', 1000, '[{"page":1,"montant":3000},{"page":2,"montant":2000}]'::jsonb, 'CAR-1') > 0)::text, 'true');
SELECT t.eq('R total du carnet = somme des pages', total_carnet::text, '5000') FROM releve_carnet WHERE cle = 'CAR-1';
SELECT t.eq('R deux pages enregistrées', count(*)::text, '2') FROM releve_carnet_page p JOIN releve_carnet r ON r.id = p.releve_id WHERE r.cle = 'CAR-1';
SELECT t.eq('R S1 rapproché : conforme', statut, 'conforme') FROM v_rapprochement_carnet WHERE cycle_numero = 'S1';
SELECT t.eq('R S1 : aucun écart signalé', coalesce(cardinality(ecarts),0)::text, '0') FROM v_rapprochement_carnet WHERE cycle_numero = 'S1';

-- Rejeu avec la même clé : pas de doublon
SELECT t.eq('R rejeu : même relevé', (enregistrer_releve_carnet(
  (SELECT id FROM cycle WHERE numero='S1'), (SELECT id FROM utilisateur WHERE login='ctrl.carnet'),
  '2026-10-01', '2026-11-30', 1000, '[{"page":1,"montant":3000},{"page":2,"montant":2000}]'::jsonb, 'CAR-1')
  = (SELECT id FROM releve_carnet WHERE cle = 'CAR-1'))::text, 'true');
SELECT t.eq('R rejeu : une seule ligne', count(*)::text, '1') FROM releve_carnet WHERE cle = 'CAR-1';

-- S2 : sans relevé, puis relevé avec une date de fin fausse et un total faux : écart signalé, pas bloqué
SELECT t.eq('R S2 sans relevé', statut, 'sans_releve') FROM v_rapprochement_carnet WHERE cycle_numero = 'S2';
SELECT enregistrer_releve_carnet((SELECT id FROM cycle WHERE numero='S2'), (SELECT id FROM utilisateur WHERE login='ctrl.carnet'),
  '2026-10-01', '2026-10-31', 1000, '[{"page":1,"montant":4000}]'::jsonb, 'CAR-2');
SELECT t.eq('R S2 : statut écart', statut, 'ecart') FROM v_rapprochement_carnet WHERE cycle_numero = 'S2';
SELECT t.eq('R S2 : rubriques en écart', ecarts::text, '{dates,total}') FROM v_rapprochement_carnet WHERE cycle_numero = 'S2';
SELECT t.eq('R S2 : écart total', ecart_total::text, '4000') FROM v_rapprochement_carnet WHERE cycle_numero = 'S2';

-- S3 : le total machine retranche le retrait (5 000 - 1 000) ; un relevé à 4 000 est conforme
SELECT t.eq('R S3 : total machine net du retrait', machine_total::text, '4000') FROM v_rapprochement_carnet WHERE cycle_numero = 'S3';
SELECT enregistrer_releve_carnet((SELECT id FROM cycle WHERE numero='S3'), (SELECT id FROM utilisateur WHERE login='ctrl.carnet'),
  '2026-10-01', '2026-11-30', 1000, '[{"page":1,"montant":2000},{"page":2,"montant":2000}]'::jsonb, 'CAR-3');
SELECT t.eq('R S3 rapproché : conforme', statut, 'conforme') FROM v_rapprochement_carnet WHERE cycle_numero = 'S3';

-- Refus
SELECT t.refuse('R second relevé d''un même cycle refusé', format(
  'SELECT mf.enregistrer_releve_carnet(%s,%s,''2026-10-01'',''2026-11-30'',1000,''[{"page":1,"montant":1}]''::jsonb,''CAR-X'')',
  (SELECT id FROM cycle WHERE numero='S1'), (SELECT id FROM utilisateur WHERE login='ctrl.carnet')));
SELECT t.refuse('R relevé sans page refusé', format(
  'SELECT mf.enregistrer_releve_carnet(%s,%s,''2026-10-01'',''2026-11-30'',1000,''[]''::jsonb,''CAR-Y'')',
  (SELECT id FROM cycle WHERE numero='S4'), (SELECT id FROM utilisateur WHERE login='ctrl.carnet')));
SELECT t.refuse('R date de fin avant le début refusée', format(
  'SELECT mf.enregistrer_releve_carnet(%s,%s,''2026-11-30'',''2026-10-01'',1000,''[{"page":1,"montant":1}]''::jsonb,''CAR-Z'')',
  (SELECT id FROM cycle WHERE numero='S4'), (SELECT id FROM utilisateur WHERE login='ctrl.carnet')));
SELECT t.refuse('R relevé non modifiable', 'UPDATE mf.releve_carnet SET mise = 900 WHERE cle = ''CAR-1''');
SELECT t.refuse('R relevé non supprimable', 'DELETE FROM mf.releve_carnet WHERE cle = ''CAR-1''');
SELECT t.refuse('R clé déjà utilisée pour un autre cycle refusée', format(
  'SELECT mf.enregistrer_releve_carnet(%s,%s,''2026-10-01'',''2026-11-30'',1000,''[{"page":1,"montant":1}]''::jsonb,''CAR-1'')',
  (SELECT id FROM cycle WHERE numero='S4'), (SELECT id FROM utilisateur WHERE login='ctrl.carnet')));
