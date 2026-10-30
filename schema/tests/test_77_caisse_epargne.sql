SET search_path = mf, public;

-- Module sous test : 77_caisse_epargne.sql (dépôts et retraits d'épargne au guichet passent par la caisse)
INSERT INTO agence(code,libelle) VALUES ('LOM','Lomé Centre');
INSERT INTO zone(agence_id,code,libelle) VALUES (1,'Z1','Zone Marché');
INSERT INTO client(agence_id,zone_id,numero,nom) VALUES (1,1,'C001','Un');
INSERT INTO produit_epargne(code,libelle,categorie) VALUES ('CL','Classique','classique');
INSERT INTO compte_epargne(agence_id,client_id,produit_id) VALUES (1,1,1);
INSERT INTO utilisateur(agence_id,login,nom,role) VALUES (1,'caiss1','Caissière 1','chef_agence'),(1,'caiss2','Caissière 2','chef_agence');
INSERT INTO caisse(agence_id,code,type) VALUES (1,'CP','principale');
INSERT INTO session_caisse(caisse_id,date_session,solde_ouverture,utilisateur_id) VALUES (1,'2026-10-01',0,1);

-- Dépôt : encaissement sur la session de la caissière 1
SELECT mouvement_epargne_especes(1,'depot',20000,'2026-10-01',NULL,NULL,1,1);
SELECT t.eq('E dépôt : encaissement en caisse', count(*)::text, '1') FROM operation_caisse WHERE motif = 'epargne_depot' AND montant = 20000;
SELECT t.eq('E dépôt : solde théorique de la caisse', solde_theorique::text, '20000') FROM v_session_caisse_solde WHERE session_id = 1;

-- Retrait : décaissement de la caisse
SELECT mouvement_epargne_especes(1,'retrait',5000,'2026-10-01',NULL,NULL,1,1);
SELECT t.eq('E retrait : décaissement en caisse', count(*)::text, '1') FROM operation_caisse WHERE motif = 'epargne_retrait' AND montant = 5000;
SELECT t.eq('E retrait : solde de la caisse', solde_theorique::text, '15000') FROM v_session_caisse_solde WHERE session_id = 1;

-- Retrait supérieur à la caisse : refusé, rien n'est écrit
SELECT t.refuse('E retrait supérieur à la caisse refusé', 'SELECT mf.mouvement_epargne_especes(1,''retrait'',99999,''2026-10-01'',NULL,NULL,1,1)');
SELECT t.eq('E refus : aucun mouvement écrit', count(*)::text, '2') FROM mouvement_epargne WHERE compte_id = 1;

-- La caissière 2 n'a pas de session : refusée
SELECT t.refuse('E caissière sans session refusée', 'SELECT mf.mouvement_epargne_especes(1,''depot'',100,''2026-10-01'',NULL,NULL,2,1)');
SELECT t.eq('E refus caissière 2 : aucun mouvement', count(*)::text, '2') FROM mouvement_epargne WHERE compte_id = 1;

-- Type non géré en espèces : refusé
SELECT t.refuse('E type virement refusé en espèces', 'SELECT mf.mouvement_epargne_especes(1,''virement_entrant'',100,''2026-10-01'',NULL,NULL,1,1)');

-- Sans session choisie : refusé, même si la caissière n'a qu'une session
SELECT t.refuse('E sans session choisie refusée', 'SELECT mf.mouvement_epargne_especes(1,''depot'',100,''2026-10-01'',NULL,NULL,1)');
SELECT t.eq('E refus sans session : aucun mouvement', count(*)::text, '2') FROM mouvement_epargne WHERE compte_id = 1;
