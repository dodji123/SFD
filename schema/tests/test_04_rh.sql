SET search_path = mf, public;

CREATE OR REPLACE FUNCTION t.cy(p_numero text) RETURNS integer LANGUAGE sql AS $$ SELECT id FROM mf.cycle WHERE numero = p_numero $$;
CREATE OR REPLACE FUNCTION t.em(p_matricule text) RETURNS integer LANGUAGE sql AS $$ SELECT id FROM mf.employe WHERE matricule = p_matricule $$;

-- ===== Données de base =====
INSERT INTO agence(code,libelle) VALUES ('LOM','Lomé Centre');
INSERT INTO zone(agence_id,code,libelle) VALUES (1,'Z1','Zone Marché');
INSERT INTO agent(agence_id,matricule,nom) VALUES (1,'A01','Ama');
INSERT INTO collectrice(agence_id,matricule,nom,agent_id) VALUES (1,'K1','Kofi',1);
INSERT INTO affectation_zone(zone_id,collectrice_id,date_debut) VALUES (1,1,'2026-01-01');
INSERT INTO client(agence_id,zone_id,numero,nom) VALUES (1,1,'C001','Un');
INSERT INTO produit_epargne(code,libelle,categorie,type_cycle,nb_pages_livret) VALUES ('P1','Tontine','collecte',1,1);

-- ===== C. Commission : production x taux, nette de la retenue sur le compte agent =====
INSERT INTO cycle(agence_id,numero,client_id,produit_id,type_cycle,mise_initiale,mise_courante,objectif,date_debut,date_fin)
VALUES (1,'CY1',1,1,1,1000,1000,31000,'2026-10-01','2026-10-31');
INSERT INTO ligne_collecte(cycle_id,page,no_ligne,date_collecte,agent_id,montant_collecte)
SELECT t.cy('CY1'),1,g,'2026-10-01'::date+g-1,1,1000 FROM generate_series(1,3) g;
SELECT enregistrer_versement(1,'2026-10-01',0);              -- manquant 1000 : l'agent doit 1000
SELECT cloturer_cycle(t.cy('CY1'),'2026-10-31');
SELECT calculer_commission(1,'2026-10-01','2026-10-31');
SELECT t.eq('C production x taux 2 % - retenue plafonnée à 50 %',
  production::text || '/' || commission_brute::text || '/' || retenue_agent::text || '/' || commission_nette::text, '3000/60/30/30')
  FROM commission_collectrice;
SELECT t.eq('C compte agent après retenue', solde::text, '-970') FROM v_solde_compte_agent WHERE agent_id = 1;
SELECT t.refuse('C commission déjà calculée', 'SELECT mf.calculer_commission(1,''2026-10-01'',''2026-10-31'')');

-- ===== P. Paie =====
INSERT INTO employe(agence_id,matricule,nom,poste,date_embauche,collectrice_id,agent_id) VALUES
  (1,'E1','Kofi','Collectrice','2026-01-01',1,1),
  (1,'E2','Sans contrat','Caissier','2026-01-01',NULL,NULL);
INSERT INTO contrat(employe_id,type,date_debut,salaire_base) VALUES (t.em('E1'),'cdi','2026-01-01',100000);
SELECT t.refuse('P contrats qui se chevauchent', format('INSERT INTO mf.contrat(employe_id,type,date_debut,salaire_base) VALUES (%s,''cdd'',''2026-06-01'',90000)', t.em('E1')));
-- rubriques de TEST (les vrais taux ne sont pas fournis)
INSERT INTO rubrique_paie(code,libelle,type,mode,valeur,base,ordre) VALUES
  ('PRIME','Prime de transport','gain','fixe',5000,'salaire_base',10),
  ('COTSOC','Cotisation sociale','retenue_salariale','pourcentage',0.04,'brut',20),
  ('PATSOC','Charges patronales','charge_patronale','pourcentage',0.15,'brut',30);
INSERT INTO avance_salaire(employe_id,date_avance,montant,restant) VALUES (t.em('E1'),'2026-09-15',20000,20000);

SELECT t.refuse('P employé sans contrat', format('SELECT mf.generer_bulletin(%s,''2026-10-01'')', t.em('E2')));
SELECT generer_bulletin(t.em('E1'),'2026-10-15');            -- n'importe quel jour du mois
SELECT t.eq('P brut = base 100000 + prime 5000 + commission 30', brut::text, '105030') FROM bulletin_paie;
SELECT t.eq('P cotisation salariale 4 % du brut', retenues::text, '4201') FROM bulletin_paie;
SELECT t.eq('P charges patronales 15 % du brut', charges_patronales::text, '15755') FROM bulletin_paie;
SELECT t.eq('P avance retenue en totalité', retenue_avance::text, '20000') FROM bulletin_paie;
SELECT t.eq('P net à payer', net_a_payer::text, '80829') FROM bulletin_paie;
SELECT t.eq('P lignes du bulletin', string_agg(code, ',' ORDER BY id), 'BASE,COMMISSION,PRIME,COTSOC,PATSOC,AVANCE') FROM ligne_bulletin;
SELECT t.eq('P période normalisée au 1er du mois', periode::text, '2026-10-01') FROM bulletin_paie;
SELECT t.refuse('P bulletin déjà généré', format('SELECT mf.generer_bulletin(%s,''2026-10-01'')', t.em('E1')));
SELECT valider_bulletin((SELECT id FROM bulletin_paie));
SELECT t.eq('P avance soldée à la validation', statut || '/' || restant::text, 'soldee/0') FROM avance_salaire;
SELECT t.eq('P commission marquée payée', statut, 'payee') FROM commission_collectrice;
SELECT t.refuse('P double validation', format('SELECT mf.valider_bulletin(%s)', (SELECT id FROM bulletin_paie)));
SELECT t.eq('P bulletins du mois suivant : E1 seul (E2 sans contrat)', generer_bulletins(1::smallint,'2026-11-01')::text, '1');
SELECT t.eq('P novembre : sans commission ni avance', brut::text || '/' || net_a_payer::text, '105000/100800') FROM bulletin_paie WHERE periode = '2026-11-01';

-- avance supérieure au net : la retenue est limitée
INSERT INTO avance_salaire(employe_id,date_avance,montant,restant) VALUES (t.em('E1'),'2026-11-20',500000,500000);
SELECT generer_bulletin(t.em('E1'),'2026-12-01');
SELECT t.eq('P retenue d''avance limitée au net disponible', retenue_avance::text || '/' || net_a_payer::text, '100800/0') FROM bulletin_paie WHERE periode = '2026-12-01';
