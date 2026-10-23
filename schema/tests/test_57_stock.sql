SET search_path = mf, public;

-- Module sous test : 57_stock.sql (articles, lieux, mouvements en ajout seul, demandes validées par une autre personne, affectations)
INSERT INTO agence(code,libelle) VALUES ('LOM','Lomé Centre'),('KPA','Kpalimé');
INSERT INTO utilisateur(login,nom,role,agence_id) VALUES ('chef','Chef','chef_agence',1),('caiss','Caissier','caissier',1),('agt','Agent','agent',1),('agt2','Agent Kpalimé','agent',2),('compta','Comptable','comptable',NULL);
INSERT INTO exercice_comptable(code,date_debut,date_fin) VALUES ('2026','2026-01-01','2026-12-31');
INSERT INTO tiers(nom,type,agence_id) VALUES ('Papeterie Centrale','prestataire',NULL);

CREATE OR REPLACE FUNCTION t.u(p text) RETURNS integer LANGUAGE sql AS $$ SELECT id FROM mf.utilisateur WHERE login = p $$;
CREATE OR REPLACE FUNCTION t.a(p text) RETURNS integer LANGUAGE sql AS $$ SELECT id FROM mf.article WHERE code = p $$;

-- ===== A. Catalogue et lieux =====
INSERT INTO article(code,designation,type,unite,seuil_alerte) VALUES ('LIVRET','Livret de collecte','consommable','livret',20),('RAMETTE','Ramette de papier A4','consommable','ramette',5);
INSERT INTO article(code,designation,type,categorie_immobilisation) VALUES ('TEL','Téléphone Android','immobilisable','materiel_informatique');
SELECT t.refuse('A code en minuscules', 'INSERT INTO mf.article(code,designation,type) VALUES (''abc'',''Article'',''consommable'')');
SELECT t.refuse('A immobilisable sans catégorie', 'INSERT INTO mf.article(code,designation,type) VALUES (''X1'',''Article'',''immobilisable'')');
SELECT t.refuse('A consommable avec catégorie', 'INSERT INTO mf.article(code,designation,type,categorie_immobilisation) VALUES (''X2'',''Article'',''consommable'',''terrain'')');
SELECT t.refuse('A type non modifiable', 'UPDATE mf.article SET type = ''immobilisable'' WHERE code = ''LIVRET''');
SELECT t.eq('A lieu siège créé', count(*)::text, '1') FROM lieu_stock WHERE type = 'siege';
SELECT t.eq('A lieu d''agence retrouvé', (lieu_stock_pour('agence', 1::smallint) = lieu_stock_pour('agence', 1::smallint))::text, 'true');
SELECT lieu_stock_pour('agent', 1::smallint, t.u('agt'));
SELECT t.eq('A lieu d''agent', type || '/' || agence_id, 'agent/1') FROM lieu_stock WHERE utilisateur_id = t.u('agt');
SELECT t.refuse('A agent sans agence', 'SELECT mf.lieu_stock_pour(''agent'', 1::smallint, t.u(''compta''))');
SELECT t.refuse('A deuxième siège', 'INSERT INTO mf.lieu_stock(type,libelle) VALUES (''siege'',''Autre'')');

-- ===== B. Entrées, coût moyen pondéré =====
SELECT entrer_stock(t.a('LIVRET'), lieu_stock_pour('siege', NULL), 100, 500, '2026-02-01', 'F-001', (SELECT id FROM tiers LIMIT 1), t.u('compta'));
SELECT entrer_stock(t.a('LIVRET'), lieu_stock_pour('siege', NULL), 100, 700, '2026-02-10', 'F-002', NULL, t.u('compta'));
SELECT t.eq('B solde du siège', solde_stock(t.a('LIVRET'), lieu_stock_pour('siege', NULL))::text, '200.000');
SELECT t.eq('B coût moyen pondéré (500 et 700)', cout_moyen::text, '600.00') FROM article WHERE code = 'LIVRET';
SELECT t.refuse('B entrée sans coût', 'SELECT mf.entrer_stock(t.a(''LIVRET''), mf.lieu_stock_pour(''siege'', NULL), 5, 0, NULL, NULL, NULL, 1)');
SELECT t.refuse('B entrée d''un article immobilisable', 'SELECT mf.entrer_stock(t.a(''TEL''), mf.lieu_stock_pour(''siege'', NULL), 1, 50000, NULL, NULL, NULL, 1)');
SELECT t.refuse('B entrée de quantité négative', 'SELECT mf.entrer_stock(t.a(''LIVRET''), mf.lieu_stock_pour(''siege'', NULL), -5, 100, NULL, NULL, NULL, 1)');

-- ===== C. Transferts =====
SELECT transferer_stock(t.a('LIVRET'), lieu_stock_pour('siege', NULL), lieu_stock_pour('agence', 1::smallint), 60, '2026-02-15', 'Dotation agence Lomé', t.u('compta'));
SELECT transferer_stock(t.a('LIVRET'), lieu_stock_pour('agence', 1::smallint), lieu_stock_pour('agent', 1::smallint, t.u('agt')), 25, '2026-02-16', 'Dotation de l''agent', t.u('chef'));
SELECT t.eq('C solde siège / agence / agent', solde_stock(t.a('LIVRET'), lieu_stock_pour('siege', NULL))::text || '/' || solde_stock(t.a('LIVRET'), lieu_stock_pour('agence', 1::smallint))::text || '/' || solde_stock(t.a('LIVRET'), lieu_stock_pour('agent', 1::smallint, t.u('agt')))::text, '140.000/35.000/25.000');
SELECT t.eq('C total inchangé par les transferts', sum(quantite)::text, '200.000') FROM mouvement_stock WHERE article_id = t.a('LIVRET');
SELECT t.eq('C coût moyen inchangé par un transfert', cout_moyen::text, '600.00') FROM article WHERE code = 'LIVRET';
SELECT t.refuse('C transfert vers le même lieu', 'SELECT mf.transferer_stock(t.a(''LIVRET''), mf.lieu_stock_pour(''siege'', NULL), mf.lieu_stock_pour(''siege'', NULL), 1, NULL, ''Même lieu'', 1)');
SELECT t.refuse('C transfert au-delà du stock', 'SELECT mf.transferer_stock(t.a(''LIVRET''), mf.lieu_stock_pour(''agence'', 1::smallint), mf.lieu_stock_pour(''siege'', NULL), 36, NULL, ''Trop'', 1)');
SELECT t.eq('C le transfert refusé n''a rien laissé', solde_stock(t.a('LIVRET'), lieu_stock_pour('agence', 1::smallint))::text, '35.000');

-- ===== D. Ajout seul =====
SELECT t.refuse('D modification d''un mouvement', 'UPDATE mf.mouvement_stock SET quantite = 1');
SELECT t.refuse('D suppression d''un mouvement', 'DELETE FROM mf.mouvement_stock');
SELECT t.refuse('D vidage', 'TRUNCATE mf.mouvement_stock');

-- ===== E. Sortie / rebut / inventaire : validation par une autre personne =====
SELECT t.refuse('E sortie directe sans demande', format('INSERT INTO mf.mouvement_stock(type,article_id,lieu_id,quantite,motif) VALUES (''sortie'',%s,%s,-1,''Sortie directe'')', t.a('LIVRET'), lieu_stock_pour('agence', 1::smallint)));
INSERT INTO demande_stock(type,article_id,lieu_id,quantite,motif,demande_par) VALUES ('sortie', t.a('LIVRET'), lieu_stock_pour('agence', 1::smallint), 10, 'Livrets remis aux clients', t.u('caiss'));
SELECT t.refuse('E auto-validation', format('SELECT mf.decider_demande_stock(%s, true, %s, NULL)', (SELECT max(id) FROM demande_stock), t.u('caiss')));
SELECT t.refuse('E mouvement sur une demande en attente', format('INSERT INTO mf.mouvement_stock(type,article_id,lieu_id,quantite,motif,demande_id) VALUES (''sortie'',%s,%s,-10,''Sortie directe'',%s)', t.a('LIVRET'), lieu_stock_pour('agence', 1::smallint), (SELECT max(id) FROM demande_stock)));
SELECT t.refuse('E rejet sans motif', format('SELECT mf.decider_demande_stock(%s, false, %s, NULL)', (SELECT max(id) FROM demande_stock), t.u('chef')));
SELECT t.eq('E validation par le chef', decider_demande_stock((SELECT max(id) FROM demande_stock), true, t.u('chef'), 'Accord'), 'validee');
SELECT t.eq('E solde après sortie', solde_stock(t.a('LIVRET'), lieu_stock_pour('agence', 1::smallint))::text, '25.000');
SELECT t.eq('E sortie valorisée au coût moyen', cout_unitaire::text, '600.00') FROM mouvement_stock WHERE type = 'sortie';
SELECT t.refuse('E décision sur une demande déjà décidée', format('SELECT mf.decider_demande_stock(%s, true, %s, NULL)', (SELECT max(id) FROM demande_stock), t.u('compta')));
SELECT t.refuse('E demande décidée non modifiable', 'UPDATE mf.demande_stock SET quantite = 1');
SELECT t.refuse('E demande non supprimable', 'DELETE FROM mf.demande_stock');
SELECT t.refuse('E réutiliser une demande pour un autre article', format('INSERT INTO mf.mouvement_stock(type,article_id,lieu_id,quantite,motif,demande_id) VALUES (''sortie'',%s,%s,-1,''Autre article'',%s)', t.a('RAMETTE'), lieu_stock_pour('agence', 1::smallint), (SELECT max(id) FROM demande_stock)));
-- rejet
INSERT INTO demande_stock(type,article_id,lieu_id,quantite,motif,demande_par) VALUES ('rebut', t.a('LIVRET'), lieu_stock_pour('agence', 1::smallint), 5, 'Livrets mouillés', t.u('caiss'));
SELECT t.eq('E rejet motivé', decider_demande_stock((SELECT max(id) FROM demande_stock), false, t.u('chef'), 'Constat à refaire'), 'rejetee');
SELECT t.eq('E le rejet ne touche pas au stock', solde_stock(t.a('LIVRET'), lieu_stock_pour('agence', 1::smallint))::text, '25.000');
-- rebut validé, puis sortie supérieure au stock refusée
INSERT INTO demande_stock(type,article_id,lieu_id,quantite,motif,demande_par) VALUES ('rebut', t.a('LIVRET'), lieu_stock_pour('agence', 1::smallint), 5, 'Livrets mouillés', t.u('caiss'));
SELECT decider_demande_stock((SELECT max(id) FROM demande_stock), true, t.u('chef'), NULL);
SELECT t.eq('E solde après rebut', solde_stock(t.a('LIVRET'), lieu_stock_pour('agence', 1::smallint))::text, '20.000');
INSERT INTO demande_stock(type,article_id,lieu_id,quantite,motif,demande_par) VALUES ('sortie', t.a('LIVRET'), lieu_stock_pour('agence', 1::smallint), 21, 'Trop gros prélèvement', t.u('caiss'));
SELECT t.refuse('E sortie supérieure au stock', format('SELECT mf.decider_demande_stock(%s, true, %s, NULL)', (SELECT max(id) FROM demande_stock), t.u('chef')));
SELECT t.eq('E la demande refusée par la base reste en attente', statut, 'en_attente') FROM demande_stock WHERE id = (SELECT max(id) FROM demande_stock);
SELECT t.refuse('E demande sur un article immobilisable', format('INSERT INTO mf.demande_stock(type,article_id,lieu_id,quantite,motif,demande_par) VALUES (''sortie'',%s,%s,1,''Téléphone'',%s)', t.a('TEL'), lieu_stock_pour('agence', 1::smallint), t.u('caiss')));
-- inventaire : l'écart est calculé à la validation
INSERT INTO demande_stock(type,article_id,lieu_id,quantite,motif,demande_par) VALUES ('inventaire', t.a('LIVRET'), lieu_stock_pour('agence', 1::smallint), 18, 'Comptage physique de l''agence', t.u('caiss'));
SELECT decider_demande_stock((SELECT max(id) FROM demande_stock), true, t.u('compta'), NULL);
SELECT t.eq('E inventaire : manquant de 2', quantite::text, '-2.000') FROM mouvement_stock WHERE type = 'inventaire';
SELECT t.eq('E solde après inventaire', solde_stock(t.a('LIVRET'), lieu_stock_pour('agence', 1::smallint))::text, '18.000');
INSERT INTO demande_stock(type,article_id,lieu_id,quantite,motif,demande_par) VALUES ('inventaire', t.a('LIVRET'), lieu_stock_pour('agence', 1::smallint), 18, 'Comptage conforme', t.u('caiss'));
SELECT decider_demande_stock((SELECT max(id) FROM demande_stock), true, t.u('compta'), NULL);
SELECT t.eq('E inventaire conforme : aucun mouvement de plus', count(*)::text, '1') FROM mouvement_stock WHERE type = 'inventaire';

-- ===== F. Valorisation et alertes =====
SELECT t.eq('F valeur du lieu agence (18 x 600)', valeur::text, '10800') FROM v_solde_stock WHERE lieu_type = 'agence' AND article_code = 'LIVRET';
SELECT entrer_stock(t.a('RAMETTE'), lieu_stock_pour('agence', 1::smallint), 4, 3000, '2026-03-01', NULL, NULL, t.u('caiss'));
SELECT t.eq('F alerte : ramettes sous le seuil dans l''agence 1', quantite::text, '4.000') FROM v_alerte_stock WHERE article_code = 'RAMETTE' AND agence_id = 1;
SELECT t.eq('F pas d''alerte pour les livrets de l''agence (agence + agent = 43 > 20)', count(*)::text, '0') FROM v_alerte_stock WHERE article_code = 'LIVRET' AND agence_id = 1;
SELECT t.eq('F pas d''alerte du siège pour les livrets (140 > 20)', count(*)::text, '0') FROM v_alerte_stock WHERE article_code = 'LIVRET' AND agence_id IS NULL;

-- ===== G. Comptabilité des consommables =====
UPDATE parametre SET valeur = 'oui' WHERE cle = 'comptabilisation_auto';
SELECT entrer_stock(t.a('RAMETTE'), lieu_stock_pour('agence', 1::smallint), 10, 2500, '2026-03-05', 'F-777', NULL, t.u('caiss'));
SELECT t.eq('G pièce d''entrée : 10 x 2500 au débit du stock', COALESCE((SELECT solde_debiteur::text FROM balance(1::smallint,'2026-01-01','2026-12-31') WHERE compte = '3231'), '0'), '25000');
SELECT t.eq('G pièce liée au mouvement', count(*)::text, '1') FROM v_mouvement_stock WHERE reference_facture = 'F-777' AND piece_id IS NOT NULL;
INSERT INTO demande_stock(type,article_id,lieu_id,quantite,motif,demande_par) VALUES ('sortie', t.a('RAMETTE'), lieu_stock_pour('agence', 1::smallint), 2, 'Consommation du mois', t.u('caiss'));
SELECT decider_demande_stock((SELECT max(id) FROM demande_stock), true, t.u('chef'), NULL);
SELECT t.eq('G sortie : charge de variation de stock (2 x coût moyen)', COALESCE((SELECT solde_debiteur::text FROM balance(1::smallint,'2026-01-01','2026-12-31') WHERE compte = '612'), '0'), (SELECT round(2 * cout_moyen)::text FROM article WHERE code = 'RAMETTE'));
SELECT transferer_stock(t.a('RAMETTE'), lieu_stock_pour('agence', 1::smallint), lieu_stock_pour('agent', 1::smallint, t.u('agt')), 1, NULL, 'Dotation de l''agent', t.u('chef'));
SELECT t.eq('G un transfert ne crée aucune écriture', count(*)::text, '2') FROM piece_comptable WHERE reference_table = 'mouvement_stock';
-- le siège tient sa propre comptabilité : agence marquée siège
INSERT INTO agence(code,libelle,siege) VALUES ('SIE','Siège',true);
SELECT entrer_stock(t.a('RAMETTE'), lieu_stock_pour('siege', NULL), 10, 1000, '2026-03-06', 'F-SIEGE', NULL, t.u('compta'));
SELECT t.eq('G entrée au siège : écriture dans l''agence siège', COALESCE((SELECT solde_debiteur::text FROM balance((SELECT id FROM agence WHERE siege),'2026-01-01','2026-12-31') WHERE compte = '3231'), '0'), '10000');
SELECT t.eq('G pièce du siège liée au mouvement', count(*)::text, '1') FROM v_mouvement_stock WHERE reference_facture = 'F-SIEGE' AND piece_id IS NOT NULL;
UPDATE parametre SET valeur = 'non' WHERE cle = 'comptabilisation_auto';

-- ===== H. Immobilisations : article, affectation à un agent, rebut validé =====
INSERT INTO immobilisation(agence_id,designation,categorie,date_acquisition,date_mise_en_service,valeur_acquisition,article_id) VALUES (1,'Téléphone Android n° 1','materiel_informatique','2026-02-01','2026-02-01',90000, t.a('TEL'));
SELECT t.eq('H article porté par l''immobilisation', article_id::text, t.a('TEL')::text) FROM immobilisation;
SELECT affecter_immobilisation((SELECT id FROM immobilisation), t.u('agt'), '2026-02-05', 'Collecte terrain', t.u('chef'));
SELECT t.eq('H affecté à l''agent', affecte_a, 'Agent') FROM v_immobilisation_stock;
SELECT t.refuse('H double affectation au même agent', format('SELECT mf.affecter_immobilisation(%s, %s, NULL, NULL, 1)', (SELECT id FROM immobilisation), t.u('agt')));
SELECT t.refuse('H agent d''une autre agence', format('SELECT mf.affecter_immobilisation(%s, %s, NULL, NULL, 1)', (SELECT id FROM immobilisation), t.u('agt2')));
SELECT affecter_immobilisation((SELECT id FROM immobilisation), t.u('caiss'), '2026-03-01', 'Réaffectation', t.u('chef'));
SELECT t.eq('H historique : deux affectations, une seule ouverte', count(*)::text || '/' || count(*) FILTER (WHERE date_fin IS NULL), '2/1') FROM affectation_immobilisation;
SELECT t.eq('H l''ancienne affectation est close à la date de la nouvelle', date_fin::text, '2026-03-01') FROM affectation_immobilisation WHERE utilisateur_id = t.u('agt');
SELECT t.refuse('H historique non modifiable', 'UPDATE mf.affectation_immobilisation SET utilisateur_id = 1');
SELECT t.refuse('H historique non supprimable', 'DELETE FROM mf.affectation_immobilisation');
INSERT INTO demande_stock(type,immobilisation_id,motif,demande_par) VALUES ('rebut_immobilisation', (SELECT id FROM immobilisation), 'Écran cassé, irréparable', t.u('caiss'));
SELECT t.refuse('H rebut auto-validé', format('SELECT mf.decider_demande_stock(%s, true, %s, NULL)', (SELECT max(id) FROM demande_stock), t.u('caiss')));
SELECT t.eq('H rien n''est sorti avant la décision', statut, 'en_service') FROM immobilisation;
SELECT decider_demande_stock((SELECT max(id) FROM demande_stock), true, t.u('chef'), NULL);
SELECT t.eq('H immobilisation mise au rebut', statut || '/' || type_sortie, 'sortie/rebut') FROM immobilisation;
SELECT t.eq('H l''affectation est close à la sortie', count(*)::text, '0') FROM affectation_immobilisation WHERE date_fin IS NULL;
SELECT t.refuse('H affectation d''une immobilisation sortie', format('SELECT mf.affecter_immobilisation(%s, %s, NULL, NULL, 1)', (SELECT id FROM immobilisation), t.u('agt')));
