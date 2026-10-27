SET search_path = mf, public;

-- Module sous test : 72_controle_carnet.sql (contrôle d'un cycle au carnet, ligne par ligne)
INSERT INTO agence(code,libelle) VALUES ('LOM','Lomé Centre');
INSERT INTO zone(agence_id,code,libelle) VALUES (1,'Z1','Zone Marché');
INSERT INTO agent(agence_id,matricule,nom) VALUES (1,'A04','Kossi');
INSERT INTO client(agence_id,zone_id,numero,nom) VALUES (1,1,'C001','Un');
INSERT INTO produit_epargne(code,libelle,categorie,type_cycle,nb_pages_livret) VALUES ('P1','Tontine','collecte',1,1);
INSERT INTO produit_epargne(code,libelle,categorie) VALUES ('LIB','Tontine libre','collecte');
INSERT INTO utilisateur(login,nom,role,agence_id) VALUES ('ctrl','Contrôleur','chef_agence',1);
INSERT INTO cycle(agence_id,numero,client_id,produit_id,type_cycle,mise_initiale,mise_courante,objectif,date_debut,date_fin)
VALUES (1,'K1',1,(SELECT id FROM produit_epargne WHERE code = 'LIB'),3,1000,1000,31000,'2026-10-01','2026-10-31');
INSERT INTO ligne_collecte(cycle_id,page,no_ligne,date_collecte,agent_id,montant_collecte)
SELECT (SELECT id FROM cycle WHERE numero = 'K1'),1,g,'2026-10-01'::date+g-1,(SELECT id FROM agent WHERE matricule = 'A04'),1000
  FROM generate_series(1,5) g;

-- Contrôle incomplet : 4 lignes sur 5 : refusé
SELECT t.refuse('K contrôle incomplet refusé', 'SELECT mf.enregistrer_controle_carnet((SELECT id FROM mf.cycle WHERE numero = ''K1''), (SELECT id FROM mf.utilisateur WHERE login = ''ctrl''), ''2026-10-15'', (SELECT jsonb_agg(jsonb_build_object(''ligne_id'', id, ''montant_carnet'', 1000)) FROM mf.ligne_collecte WHERE cycle_id = (SELECT id FROM mf.cycle WHERE numero = ''K1'') AND no_ligne < 5))');
-- Montant carnet négatif : refusé
SELECT t.refuse('K montant carnet négatif refusé', 'SELECT mf.enregistrer_controle_carnet((SELECT id FROM mf.cycle WHERE numero = ''K1''), (SELECT id FROM mf.utilisateur WHERE login = ''ctrl''), ''2026-10-15'', ''[{"ligne_id": 1, "montant_carnet": -5}]''::jsonb)');
SELECT t.eq('K aucun contrôle enregistré par les refus', count(*)::text, '0') FROM controle_carnet;

-- Contrôle complet : ligne 1 : carnet 2 000 (écart +1 000), ligne 2 : carnet 800 (écart -200), autres conformes
SELECT enregistrer_controle_carnet((SELECT id FROM cycle WHERE numero = 'K1'), (SELECT id FROM utilisateur WHERE login = 'ctrl'), '2026-10-15',
  (SELECT jsonb_agg(jsonb_build_object('ligne_id', id, 'montant_carnet', CASE no_ligne WHEN 1 THEN 2000 WHEN 2 THEN 800 ELSE 1000 END))
     FROM ligne_collecte WHERE cycle_id = (SELECT id FROM cycle WHERE numero = 'K1')),
  'contrôle de test');

SELECT t.eq('K total collecté', total_collecte::text, '5000') FROM controle_carnet;
SELECT t.eq('K total carnet', total_carnet::text, '5800') FROM controle_carnet;
SELECT t.eq('K écart total du cycle', ecart_collecte::text, '800') FROM controle_carnet;
SELECT t.eq('K date de contrôle enregistrée', date_controle::text, '2026-10-15') FROM controle_carnet;
SELECT t.eq('K écart ligne 1 (carnet 2 000 pour 1 000 collectés)', ecart::text, '1000') FROM controle_carnet_ligne l JOIN ligne_collecte c ON c.id = l.ligne_collecte_id WHERE c.no_ligne = 1;
SELECT t.eq('K écart ligne 2 (carnet 800 pour 1 000 collectés)', ecart::text, '-200') FROM controle_carnet_ligne l JOIN ligne_collecte c ON c.id = l.ligne_collecte_id WHERE c.no_ligne = 2;
SELECT t.eq('K lignes du contrôle', count(*)::text, '5') FROM controle_carnet_ligne;
SELECT t.eq('K agent porté sur chaque ligne', count(*)::text, '5') FROM controle_carnet_ligne WHERE agent_id IS NOT NULL;

-- Figé : ni modification, ni suppression
SELECT t.refuse('K contrôle non modifiable', 'UPDATE mf.controle_carnet SET commentaire = ''changé''');
SELECT t.refuse('K contrôle non supprimable', 'DELETE FROM mf.controle_carnet_ligne');

-- Cycle à mise fixe (type 1, mise 1 000) : le carnet doit être un multiple de la mise
INSERT INTO cycle(agence_id,numero,client_id,produit_id,type_cycle,mise_initiale,mise_courante,objectif,date_debut,date_fin)
VALUES (1,'K4',(SELECT id FROM client WHERE numero = 'C001'),(SELECT id FROM produit_epargne WHERE code = 'P1'),1,1000,1000,31000,'2026-10-01','2026-10-31');
INSERT INTO ligne_collecte(cycle_id,page,no_ligne,date_collecte,agent_id,montant_collecte)
VALUES ((SELECT id FROM cycle WHERE numero = 'K4'),1,1,'2026-10-01',(SELECT id FROM agent WHERE matricule = 'A04'),1000);
SELECT t.refuse('K carnet non multiple de la mise refusé', 'SELECT mf.enregistrer_controle_carnet((SELECT id FROM mf.cycle WHERE numero = ''K4''), (SELECT id FROM mf.utilisateur WHERE login = ''ctrl''), ''2026-10-15'', ''[{"ligne_id": 1, "montant_carnet": 1500}]''::jsonb)');
SELECT enregistrer_controle_carnet((SELECT id FROM cycle WHERE numero = 'K4'), (SELECT id FROM utilisateur WHERE login = 'ctrl'), '2026-10-15',
  (SELECT jsonb_agg(jsonb_build_object('ligne_id', id, 'montant_carnet', 2000)) FROM ligne_collecte WHERE cycle_id = (SELECT id FROM cycle WHERE numero = 'K4')));
SELECT t.eq('K carnet multiple de la mise accepté (écart 1 000)', ecart_collecte::text, '1000') FROM controle_carnet
 WHERE cycle_id = (SELECT id FROM cycle WHERE numero = 'K4');

-- Un cycle n'est contrôlé qu'une fois
SELECT t.refuse('K second contrôle du même cycle refusé', 'SELECT mf.enregistrer_controle_carnet((SELECT id FROM mf.cycle WHERE numero = ''K4''), (SELECT id FROM mf.utilisateur WHERE login = ''ctrl''), ''2026-10-16'', (SELECT jsonb_agg(jsonb_build_object(''ligne_id'', id, ''montant_carnet'', 2000)) FROM mf.ligne_collecte WHERE cycle_id = (SELECT id FROM mf.cycle WHERE numero = ''K4'')))');

-- Modification des valeurs : motif obligatoire, historisée, écart recalculé
SELECT t.refuse('K modification sans motif refusée', 'SELECT mf.modifier_controle_carnet((SELECT id FROM mf.controle_carnet WHERE cycle_id = (SELECT id FROM mf.cycle WHERE numero = ''K4'')), (SELECT jsonb_agg(jsonb_build_object(''ligne_id'', id, ''montant_carnet'', 1000)) FROM mf.ligne_collecte WHERE cycle_id = (SELECT id FROM mf.cycle WHERE numero = ''K4'')), (SELECT id FROM mf.utilisateur WHERE login = ''ctrl''), ''ok'')');
SELECT modifier_controle_carnet((SELECT id FROM controle_carnet WHERE cycle_id = (SELECT id FROM cycle WHERE numero = 'K4')),
  (SELECT jsonb_agg(jsonb_build_object('ligne_id', id, 'montant_carnet', 1000)) FROM ligne_collecte WHERE cycle_id = (SELECT id FROM cycle WHERE numero = 'K4')),
  (SELECT id FROM utilisateur WHERE login = 'ctrl'), 'erreur de saisie au carnet');
SELECT t.eq('K modification : écart du contrôle recalculé', ecart_collecte::text, '0') FROM controle_carnet WHERE cycle_id = (SELECT id FROM cycle WHERE numero = 'K4');
SELECT t.eq('K modification historisée (ancienne, nouvelle, motif)', ancien_montant::text || '/' || nouveau_montant::text || '/' || motif, '2000/1000/erreur de saisie au carnet')
  FROM controle_carnet_modification;
SELECT t.refuse('K modification directe refusée', 'UPDATE mf.controle_carnet_ligne SET montant_carnet = 5000');

-- Annulation du contrôle de K4 (remplacé) : il reste dans la base, il n'est plus actif, un nouveau contrôle est possible
SELECT annuler_controle_carnet((SELECT id FROM controle_carnet WHERE cycle_id = (SELECT id FROM cycle WHERE numero = 'K4')),
  (SELECT id FROM utilisateur WHERE login = 'ctrl'), 'contrôle remplacé dans le test');
SELECT t.refuse('K contrôle annulé : modification refusée', 'SELECT mf.modifier_controle_carnet((SELECT id FROM mf.controle_carnet WHERE cycle_id = (SELECT id FROM mf.cycle WHERE numero = ''K4'')), (SELECT jsonb_agg(jsonb_build_object(''ligne_id'', id, ''montant_carnet'', 1000)) FROM mf.ligne_collecte WHERE cycle_id = (SELECT id FROM mf.cycle WHERE numero = ''K4'')), (SELECT id FROM mf.utilisateur WHERE login = ''ctrl''), ''après annulation'')');
SELECT enregistrer_controle_carnet((SELECT id FROM cycle WHERE numero = 'K4'), (SELECT id FROM utilisateur WHERE login = 'ctrl'), '2026-10-17',
  (SELECT jsonb_agg(jsonb_build_object('ligne_id', id, 'montant_carnet', 1000)) FROM ligne_collecte WHERE cycle_id = (SELECT id FROM cycle WHERE numero = 'K4')));
SELECT t.eq('K nouveau contrôle après annulation : 2 contrôles, 1 annulé', count(*)::text, '2') FROM controle_carnet WHERE cycle_id = (SELECT id FROM cycle WHERE numero = 'K4');
SELECT t.eq('K annulation tracée', count(*)::text, '1') FROM controle_carnet_annulation;
