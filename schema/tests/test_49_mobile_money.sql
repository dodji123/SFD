SET search_path = mf, public;

-- Module sous test : 49_mobile_money.sql (paiement mobile money sur un cycle, confirmation idempotente, demande de retrait du client)
INSERT INTO agence(code,libelle) VALUES ('LOM','Lomé Centre');
INSERT INTO client(agence_id,nom) VALUES (1,'Cliente un'),(1,'Cliente deux');
INSERT INTO utilisateur(login,nom,role,agence_id) VALUES ('chef','Chef','chef_agence',1);
INSERT INTO produit_epargne(code,libelle,categorie) VALUES ('TON','Tontine normale','collecte');
INSERT INTO produit_epargne(code,libelle,categorie) VALUES ('TON2','Tontine 2','collecte');
INSERT INTO cycle(agence_id,numero,client_id,produit_id,type_cycle,mise_initiale,mise_courante,objectif,date_debut,date_fin) VALUES
  (1,'CY-1',1,1,2,1000,1000,31000,current_date - 5,current_date + 25),
  (1,'CY-2',2,1,2,1000,1000,31000,current_date - 5,current_date + 25),
  (1,'CY-3',1,(SELECT id FROM produit_epargne WHERE code = 'TON2'),3,500,500,NULL,current_date - 5,current_date + 25);

-- ===== A. Initiation d'un paiement =====
INSERT INTO paiement_mobile(client_id,cycle_id,operateur,telephone,montant,cle)
  VALUES (1,(SELECT id FROM cycle WHERE numero='CY-1'),'TMONEY','+22890123456',2000,'k-1');
SELECT t.eq('A référence générée, état initié, agence du cycle', reference || '/' || statut || '/' || agence_id, 'MM-00000001/initie/1') FROM paiement_mobile WHERE cle = 'k-1';
SELECT t.refuse('A un seul paiement en attente par cycle', 'INSERT INTO mf.paiement_mobile(client_id,cycle_id,operateur,telephone,montant) VALUES (1,(SELECT id FROM mf.cycle WHERE numero=''CY-1''),''TMONEY'',''+22890123456'',1000)');
SELECT t.refuse('A cycle d''un autre client', 'INSERT INTO mf.paiement_mobile(client_id,cycle_id,operateur,telephone,montant) VALUES (1,(SELECT id FROM mf.cycle WHERE numero=''CY-2''),''TMONEY'',''+22890123456'',1000)');
SELECT t.refuse('A montant non multiple de la mise', 'INSERT INTO mf.paiement_mobile(client_id,cycle_id,operateur,telephone,montant) VALUES (2,(SELECT id FROM mf.cycle WHERE numero=''CY-2''),''FLOOZ'',''+22899123456'',1500)');
SELECT t.refuse('A montant au-dessus du maximum', 'INSERT INTO mf.paiement_mobile(client_id,cycle_id,operateur,telephone,montant) VALUES (1,(SELECT id FROM mf.cycle WHERE numero=''CY-3''),''FLOOZ'',''+22899123456'',600000)');
SELECT t.refuse('A montant sous le minimum', 'INSERT INTO mf.paiement_mobile(client_id,cycle_id,operateur,telephone,montant) VALUES (1,(SELECT id FROM mf.cycle WHERE numero=''CY-3''),''FLOOZ'',''+22899123456'',50)');
SELECT t.refuse('A numéro de téléphone invalide', 'INSERT INTO mf.paiement_mobile(client_id,cycle_id,operateur,telephone,montant) VALUES (1,(SELECT id FROM mf.cycle WHERE numero=''CY-3''),''FLOOZ'',''abc'',1000)');
SELECT t.refuse('A opérateur inconnu', 'INSERT INTO mf.paiement_mobile(client_id,cycle_id,operateur,telephone,montant) VALUES (1,(SELECT id FROM mf.cycle WHERE numero=''CY-3''),''XXX'',''+22899123456'',1000)');
SELECT t.refuse('A paiement non modifiable', 'UPDATE mf.paiement_mobile SET montant = 5000 WHERE cle = ''k-1''');

-- ===== B. Confirmation par l'opérateur =====
SELECT t.eq('B confirmation inscrit le versement au livret', confirmer_paiement_mobile((SELECT id FROM paiement_mobile WHERE cle='k-1'), 'OP-123'), 'reussi');
SELECT t.eq('B ligne mobile sans agent', origine || '/' || COALESCE(agent_id::text, 'null') || '/' || montant_collecte, 'mobile/null/2000') FROM ligne_collecte WHERE cycle_id = (SELECT id FROM cycle WHERE numero='CY-1');
SELECT t.eq('B paiement relié à sa ligne', (ligne_id IS NOT NULL)::text || '/' || ref_operateur, 'true/OP-123') FROM paiement_mobile WHERE cle = 'k-1';
SELECT t.eq('B rejeu de l''opérateur sans effet', confirmer_paiement_mobile((SELECT id FROM paiement_mobile WHERE cle='k-1'), 'OP-123'), 'reussi');
SELECT t.eq('B toujours une seule ligne', count(*)::text, '1') FROM ligne_collecte WHERE cycle_id = (SELECT id FROM cycle WHERE numero='CY-1');
SELECT t.eq('B situation du cycle : collecté', montant_collecte::text, '2000') FROM v_cycle_situation WHERE numero = 'CY-1';
SELECT t.refuse('B paiement réussi non modifiable', 'UPDATE mf.paiement_mobile SET motif = ''x'' WHERE cle = ''k-1''');
SELECT t.refuse('B retour à initié impossible', 'UPDATE mf.paiement_mobile SET statut = ''initie'' WHERE cle = ''k-1''');

-- ===== C. Plafond journalier =====
INSERT INTO parametre(cle,valeur,agence_id,description) VALUES ('mm_plafond_jour','3000',1,'plafond de test');
SELECT t.refuse('C plafond journalier du client dépassé', 'INSERT INTO mf.paiement_mobile(client_id,cycle_id,operateur,telephone,montant) VALUES (1,(SELECT id FROM mf.cycle WHERE numero=''CY-3''),''TMONEY'',''+22890123456'',1500)');
DELETE FROM parametre WHERE cle = 'mm_plafond_jour';

-- ===== D. Cycle clos entre l'initiation et la confirmation =====
INSERT INTO paiement_mobile(client_id,cycle_id,operateur,telephone,montant,cle) VALUES (2,(SELECT id FROM cycle WHERE numero='CY-2'),'FLOOZ','+22899123456',3000,'k-2');
UPDATE cycle SET statut = 'clos', date_cloture = current_date, mise_finale = 1000 WHERE numero = 'CY-2';
SELECT t.eq('D versement reçu sur un cycle clos : à rembourser', confirmer_paiement_mobile((SELECT id FROM paiement_mobile WHERE cle='k-2'), 'OP-999'), 'a_rembourser');
SELECT t.eq('D motif conservé', (motif LIKE '%clos%')::text, 'true') FROM paiement_mobile WHERE cle = 'k-2';
SELECT t.eq('D aucune ligne créée', count(*)::text, '0') FROM ligne_collecte WHERE cycle_id = (SELECT id FROM cycle WHERE numero='CY-2');
UPDATE paiement_mobile SET statut = 'rembourse' WHERE cle = 'k-2';
SELECT t.refuse('D remboursé définitif', 'UPDATE mf.paiement_mobile SET statut = ''reussi'' WHERE cle = ''k-2''');
SELECT t.refuse('D paiement non supprimable', 'DELETE FROM mf.paiement_mobile');
SELECT t.refuse('D on ne verse plus sur un cycle clos', 'INSERT INTO mf.paiement_mobile(client_id,cycle_id,operateur,telephone,montant) VALUES (2,(SELECT id FROM mf.cycle WHERE numero=''CY-2''),''FLOOZ'',''+22899123456'',1000)');

-- ===== E. Échec et expiration =====
INSERT INTO paiement_mobile(client_id,cycle_id,operateur,telephone,montant,cle) VALUES (1,(SELECT id FROM cycle WHERE numero='CY-3'),'WAVE','+22891000000',700,'k-3');
SELECT t.eq('E échec signalé par l''opérateur', echouer_paiement_mobile((SELECT id FROM paiement_mobile WHERE cle='k-3'), 'Solde insuffisant'), 'echoue');
INSERT INTO paiement_mobile(client_id,cycle_id,operateur,telephone,montant,cle) VALUES (1,(SELECT id FROM cycle WHERE numero='CY-3'),'WAVE','+22891000000',700,'k-4');
UPDATE paiement_mobile SET expire_le = now() - interval '1 minute' WHERE cle = 'k-4';
SELECT t.eq('E expiration des paiements sans réponse', expirer_paiements_mobile()::text, '1');
SELECT t.eq('E confirmation tardive d''un paiement expiré sans effet', confirmer_paiement_mobile((SELECT id FROM paiement_mobile WHERE cle='k-4')), 'expire');

-- ===== F. Demande de retrait du client =====
INSERT INTO demande_retrait_client(client_id,cycle_id,canal,motif) VALUES (1,(SELECT id FROM cycle WHERE numero='CY-1'),'agence','Besoin d''argent');
SELECT t.eq('F demande en attente, agence du cycle', statut || '/' || agence_id, 'en_attente/1') FROM demande_retrait_client;
SELECT t.refuse('F une seule demande en attente par cycle', 'INSERT INTO mf.demande_retrait_client(client_id,cycle_id) VALUES (1,(SELECT id FROM mf.cycle WHERE numero=''CY-1''))');
SELECT t.refuse('F cycle d''un autre client', 'INSERT INTO mf.demande_retrait_client(client_id,cycle_id) VALUES (2,(SELECT id FROM mf.cycle WHERE numero=''CY-1''))');
SELECT t.refuse('F paiement mobile sans opérateur ni numéro', 'INSERT INTO mf.demande_retrait_client(client_id,cycle_id,canal) VALUES (1,(SELECT id FROM mf.cycle WHERE numero=''CY-3''),''mobile_money'')');
SELECT t.refuse('F acceptation sans retrait créé', 'UPDATE mf.demande_retrait_client SET statut = ''acceptee'', decide_par = (SELECT id FROM mf.utilisateur WHERE login=''chef'')');
SELECT t.refuse('F refus non motivé', 'UPDATE mf.demande_retrait_client SET statut = ''refusee'', decide_par = (SELECT id FROM mf.utilisateur WHERE login=''chef'')');
UPDATE demande_retrait_client SET statut = 'refusee', decide_par = (SELECT id FROM utilisateur WHERE login='chef'), commentaire = 'Cycle en cours : attendre la fin';
SELECT t.refuse('F demande décidée non modifiable', 'UPDATE mf.demande_retrait_client SET statut = ''annulee''');
INSERT INTO demande_retrait_client(client_id,cycle_id,canal,operateur,telephone) VALUES (1,(SELECT id FROM cycle WHERE numero='CY-1'),'mobile_money','TMONEY','+22890123456');
UPDATE demande_retrait_client SET statut = 'acceptee', decide_par = (SELECT id FROM utilisateur WHERE login='chef'),
  retrait_id = demander_retrait_cycle((SELECT id FROM cycle WHERE numero='CY-1'), 'retrait_client', current_date) WHERE statut = 'en_attente';
SELECT t.eq('F acceptée : retrait créé, cycle clos', d.statut || '/' || (d.retrait_id IS NOT NULL)::text || '/' || c.statut, 'acceptee/true/clos') FROM demande_retrait_client d JOIN cycle c ON c.id = d.cycle_id WHERE d.canal = 'mobile_money';
SELECT t.refuse('F plus de demande quand un retrait existe', 'INSERT INTO mf.demande_retrait_client(client_id,cycle_id) VALUES (1,(SELECT id FROM mf.cycle WHERE numero=''CY-1''))');
SELECT t.eq('F vue des demandes', client || '/' || produit || '/' || statut, 'Cliente un/TON/refusee') FROM v_demande_retrait_client WHERE canal = 'agence';
