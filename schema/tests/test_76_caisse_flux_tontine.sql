SET search_path = mf, public;

-- Module sous test : 76_caisse_flux_tontine.sql (argent des agents encaissé en caisse)
INSERT INTO agence(code,libelle) VALUES ('LOM','Lomé Centre');
INSERT INTO zone(agence_id,code,libelle) VALUES (1,'Z1','Zone Marché');
INSERT INTO agent(agence_id,matricule,nom) VALUES (1,'A01','Ama'),(1,'A02','Kodjo');
INSERT INTO caisse(agence_id,code,type) VALUES (1,'CP','principale'),(1,'CG','guichet');
INSERT INTO session_caisse(caisse_id,date_session,solde_ouverture) VALUES (1,'2026-10-01',0);

-- Une seule session ouverte à l'agence : le versement y entre
SELECT t.eq('V versement de tournée : id retourné', (versement_tournee_caisse((SELECT id FROM agent WHERE matricule='A01'),'2026-10-01',1000,NULL) > 0)::text, 'true');
SELECT t.eq('V encaissement en caisse créé', count(*)::text, '1') FROM operation_caisse WHERE motif = 'versement_agent' AND montant = 1000;
SELECT t.eq('V montant encaissé dans la session', solde_theorique::text, '1000') FROM v_session_caisse_solde WHERE session_id = 1;

-- Versement nul : pas d'encaissement
SELECT versement_tournee_caisse((SELECT id FROM agent WHERE matricule='A01'),'2026-10-02',0,NULL);
SELECT t.eq('V versement nul : aucune opération de caisse', count(*)::text, '1') FROM operation_caisse WHERE motif = 'versement_agent';

-- Deux sessions ouvertes et aucune choisie : refus, rien n'est écrit
INSERT INTO session_caisse(caisse_id,date_session,solde_ouverture) VALUES (2,'2026-10-01',0);
SELECT t.refuse('V sans session choisie avec deux sessions ouvertes', 'SELECT mf.versement_tournee_caisse((SELECT id FROM agent WHERE matricule=''A02''),''2026-10-03'',500,NULL)');
SELECT t.eq('V refus : aucun versement écrit', count(*)::text, '0') FROM versement_agent WHERE agent_id = (SELECT id FROM agent WHERE matricule='A02');
SELECT t.eq('V refus : aucune opération de caisse', count(*)::text, '1') FROM operation_caisse WHERE motif = 'versement_agent';

-- Session choisie explicitement (caisse guichet) : l'encaissement suit le choix
SELECT versement_tournee_caisse((SELECT id FROM agent WHERE matricule='A02'),'2026-10-03',500,NULL,
       (SELECT id FROM session_caisse WHERE caisse_id = 2));
SELECT t.eq('V choix de session : encaissement sur la caisse guichet', count(*)::text, '1')
  FROM operation_caisse o JOIN session_caisse s ON s.id = o.session_id WHERE o.motif = 'versement_agent' AND s.caisse_id = 2 AND o.montant = 500;

-- Session inconnue : refusée
SELECT t.refuse('V session inconnue refusée', 'SELECT mf.versement_tournee_caisse((SELECT id FROM agent WHERE matricule=''A02''),''2026-10-04'',100,NULL,9999)');

-- Règlement en numéraire d'une dette : compte agent + caisse, plafonné à la dette
INSERT INTO compte_agent(agence_id,agent_id,type,montant,date_operation,libelle)
VALUES (1,(SELECT id FROM agent WHERE matricule='A02'),'manquant_versement',800,'2026-10-05','Manquant test');
SELECT t.refuse('R montant supérieur à la dette refusé', 'SELECT mf.reglement_agent_especes((SELECT id FROM agent WHERE matricule=''A02''),900,''2026-10-06'',1)');
SELECT reglement_agent_especes((SELECT id FROM agent WHERE matricule='A02'),300,'2026-10-06',1);
SELECT t.eq('R dette réduite par le règlement', (-solde)::text, '500') FROM v_solde_compte_agent WHERE agent_id = (SELECT id FROM agent WHERE matricule='A02');
SELECT t.eq('R encaissement en caisse du règlement', count(*)::text, '1') FROM operation_caisse WHERE motif = 'reglement_manquant' AND montant = 300;
SELECT t.refuse('R règlement sans session unique refusé', 'SELECT mf.reglement_agent_especes((SELECT id FROM agent WHERE matricule=''A02''),100,''2026-10-06'')');
SELECT t.eq('R refus : dette inchangée', (-solde)::text, '500') FROM v_solde_compte_agent WHERE agent_id = (SELECT id FROM agent WHERE matricule='A02');
