SET search_path = mf, public;

-- Module sous test : 76_caisse_flux_tontine.sql (argent des agents encaissé en caisse par la caissière qui ouvre la session)
INSERT INTO agence(code,libelle) VALUES ('LOM','Lomé Centre');
INSERT INTO zone(agence_id,code,libelle) VALUES (1,'Z1','Zone Marché');
INSERT INTO agent(agence_id,matricule,nom) VALUES (1,'A01','Ama'),(1,'A02','Kodjo');
INSERT INTO utilisateur(agence_id,login,nom,role) VALUES (1,'caiss1','Caissière 1','chef_agence'),(1,'caiss2','Caissière 2','chef_agence');
INSERT INTO caisse(agence_id,code,type) VALUES (1,'CP','principale'),(1,'CG','guichet');
-- session de la caissière 1 (utilisateur 1) à la caisse principale
INSERT INTO session_caisse(caisse_id,date_session,solde_ouverture,utilisateur_id) VALUES (1,'2026-10-01',0,1);

-- La caissière 1 a une seule session : son versement y entre
SELECT t.eq('V versement de tournée : id retourné', (versement_tournee_caisse((SELECT id FROM agent WHERE matricule='A01'),'2026-10-01',1000,1) > 0)::text, 'true');
SELECT t.eq('V encaissement en caisse créé', count(*)::text, '1') FROM operation_caisse WHERE motif = 'versement_agent' AND montant = 1000;
SELECT t.eq('V montant encaissé dans la session', solde_theorique::text, '1000') FROM v_session_caisse_solde WHERE session_id = 1;

-- Versement nul : pas d'encaissement
SELECT versement_tournee_caisse((SELECT id FROM agent WHERE matricule='A01'),'2026-10-02',0,1);
SELECT t.eq('V versement nul : aucune opération de caisse', count(*)::text, '1') FROM operation_caisse WHERE motif = 'versement_agent';

-- La caissière 2 n'a aucune session : refus, rien n'est écrit
SELECT t.refuse('V caissière sans session refusée', 'SELECT mf.versement_tournee_caisse((SELECT id FROM agent WHERE matricule=''A02''),''2026-10-03'',500,2)');
SELECT t.eq('V refus : aucun versement écrit', count(*)::text, '0') FROM versement_agent WHERE agent_id = (SELECT id FROM agent WHERE matricule='A02');
SELECT t.eq('V refus : aucune opération de caisse', count(*)::text, '1') FROM operation_caisse WHERE motif = 'versement_agent';

-- La caissière 2 ouvre la caisse guichet : son versement entre dans SA session
INSERT INTO session_caisse(caisse_id,date_session,solde_ouverture,utilisateur_id) VALUES (2,'2026-10-01',0,2);
SELECT versement_tournee_caisse((SELECT id FROM agent WHERE matricule='A02'),'2026-10-03',500,2);
SELECT t.eq('V encaissement sur la session de la caissière 2', count(*)::text, '1')
  FROM operation_caisse o JOIN session_caisse s ON s.id = o.session_id WHERE o.motif = 'versement_agent' AND s.utilisateur_id = 2 AND o.montant = 500;

-- Une caissière ne peut pas encaisser sur la session d'une autre (choix explicite)
SELECT t.refuse('V session d''une autre caissière refusée', 'SELECT mf.versement_tournee_caisse((SELECT id FROM agent WHERE matricule=''A02''),''2026-10-04'',100,1,2)');
-- Session inconnue : refusée
SELECT t.refuse('V session inconnue refusée', 'SELECT mf.versement_tournee_caisse((SELECT id FROM agent WHERE matricule=''A02''),''2026-10-04'',100,2,9999)');
-- Pas de caissière : refusé
SELECT t.refuse('V sans caissière refusé', 'SELECT mf.versement_tournee_caisse((SELECT id FROM agent WHERE matricule=''A02''),''2026-10-04'',100,NULL)');

-- Règlement en numéraire d'une dette : compte agent + caisse de la caissière, plafonné à la dette
INSERT INTO compte_agent(agence_id,agent_id,type,montant,date_operation,libelle)
VALUES (1,(SELECT id FROM agent WHERE matricule='A02'),'manquant_versement',800,'2026-10-05','Manquant test');
SELECT t.refuse('R montant supérieur à la dette refusé', 'SELECT mf.reglement_agent_especes((SELECT id FROM agent WHERE matricule=''A02''),900,''2026-10-06'',NULL,2)');
SELECT t.refuse('R session d''une autre caissière refusée', 'SELECT mf.reglement_agent_especes((SELECT id FROM agent WHERE matricule=''A02''),300,''2026-10-06'',2,1)');
SELECT reglement_agent_especes((SELECT id FROM agent WHERE matricule='A02'),300,'2026-10-06',NULL,2);
SELECT t.eq('R dette réduite par le règlement', (-solde)::text, '500') FROM v_solde_compte_agent WHERE agent_id = (SELECT id FROM agent WHERE matricule='A02');
SELECT t.eq('R encaissement en caisse du règlement', count(*)::text, '1') FROM operation_caisse WHERE motif = 'reglement_manquant' AND montant = 300;
SELECT t.refuse('R sans caissière refusé', 'SELECT mf.reglement_agent_especes((SELECT id FROM agent WHERE matricule=''A02''),100,''2026-10-06'',NULL,NULL)');
SELECT t.eq('R refus : dette inchangée', (-solde)::text, '500') FROM v_solde_compte_agent WHERE agent_id = (SELECT id FROM agent WHERE matricule='A02');
