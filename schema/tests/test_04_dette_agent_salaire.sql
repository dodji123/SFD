SET search_path = mf, public;

-- Module sous test : 04_rh.sql, generer_bulletin : la dette de l'agent (compte agent débiteur) est retenue sur le salaire,
-- dans la limite du net disponible. Fichiers voisins : tests/test_04_rh.sql (commission, avances).
INSERT INTO agence(code,libelle) VALUES ('LOM','Lomé Centre');
INSERT INTO agent(agence_id,matricule,nom) VALUES (1,'A01','Ama'),(1,'A02','Yao'),(1,'A03','Kossi');
INSERT INTO employe(agence_id,matricule,nom,date_embauche,agent_id) VALUES
  (1,'E01','Ama',  '2026-01-01',(SELECT id FROM agent WHERE matricule = 'A01')),
  (1,'E02','Yao',  '2026-01-01',(SELECT id FROM agent WHERE matricule = 'A02')),
  (1,'E03','Kossi','2026-01-01',(SELECT id FROM agent WHERE matricule = 'A03'));
INSERT INTO contrat(employe_id,type,date_debut,salaire_base)
SELECT id,'cdi','2026-01-01',100000 FROM employe;

-- Dettes : A01 doit 300 (couvert par le salaire) ; A02 doit 500 000 (plus que le net) ; A03 ne doit rien
INSERT INTO compte_agent(agence_id,agent_id,type,montant,date_operation,libelle) VALUES
  (1,(SELECT id FROM agent WHERE matricule = 'A01'),'manquant_versement',300,'2026-09-30','manquant test'),
  (1,(SELECT id FROM agent WHERE matricule = 'A02'),'manquant_versement',500000,'2026-09-30','manquant test');

SELECT generer_bulletin((SELECT id FROM employe WHERE matricule = 'E01'), '2026-10-01');
SELECT generer_bulletin((SELECT id FROM employe WHERE matricule = 'E02'), '2026-10-01');
SELECT generer_bulletin((SELECT id FROM employe WHERE matricule = 'E03'), '2026-10-01');

SELECT t.eq('D E01 : dette retenue sur le salaire (300), net 99 700', retenues::text || '/' || net_a_payer::text, '300/99700')
  FROM bulletin_paie WHERE employe_id = (SELECT id FROM employe WHERE matricule = 'E01');
SELECT t.eq('D E01 : ligne de retenue au bulletin', montant::text, '300') FROM ligne_bulletin l
  JOIN bulletin_paie b ON b.id = l.bulletin_id WHERE b.employe_id = (SELECT id FROM employe WHERE matricule = 'E01') AND l.code = 'DETTE_AGENT';
SELECT t.eq('D A01 : solde remis à zéro', solde::text, '0') FROM v_solde_compte_agent WHERE matricule = 'A01';

SELECT t.eq('D E02 : retenue limitée au net (100 000), net 0', retenues::text || '/' || net_a_payer::text, '100000/0')
  FROM bulletin_paie WHERE employe_id = (SELECT id FROM employe WHERE matricule = 'E02');
SELECT t.eq('D A02 : reste dû après retenue (-400 000)', solde::text, '-400000') FROM v_solde_compte_agent WHERE matricule = 'A02';

SELECT t.eq('D E03 : sans dette, pas de retenue', retenues::text || '/' || net_a_payer::text, '0/100000')
  FROM bulletin_paie WHERE employe_id = (SELECT id FROM employe WHERE matricule = 'E03');
