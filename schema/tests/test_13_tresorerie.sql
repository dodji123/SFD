SET search_path = mf, public;

CREATE OR REPLACE FUNCTION t.cs(p_code text, p_jour date) RETURNS integer LANGUAGE sql AS $$
  SELECT s.id FROM mf.session_caisse s JOIN mf.caisse k ON k.id = s.caisse_id WHERE k.code = p_code AND s.date_session = p_jour $$;
CREATE OR REPLACE FUNCTION t.cx(p_code text) RETURNS integer LANGUAGE sql AS $$ SELECT id FROM mf.caisse WHERE code = p_code $$;

-- ===== Données de base =====
INSERT INTO agence(code,libelle) VALUES ('LOM','Lomé Centre'),('KPA','Kpalimé');
INSERT INTO caisse(agence_id,code,type,libelle,plafond) VALUES
  (1,'CF','coffre','Coffre-fort',2000000),(1,'G1','guichet','Guichet 1',300000),(1,'G2','guichet','Guichet 2',NULL),(2,'KG','guichet','Guichet Kpalimé',NULL);

-- ===== A. Ouverture avec continuité =====
SELECT ouvrir_session_caisse(t.cx('CF'), '2026-10-01', 1000000);
SELECT t.refuse('A deuxième session ouverte sur la même caisse', format('SELECT mf.ouvrir_session_caisse(%s, ''2026-10-02'', 1000000)', t.cx('CF')));
SELECT fermer_session_caisse(t.cs('CF','2026-10-01'), 1000000);
SELECT t.refuse('A solde d''ouverture différent de la fermeture de la veille', format('SELECT mf.ouvrir_session_caisse(%s, ''2026-10-02'', 999000)', t.cx('CF')));
SELECT t.refuse('A date non postérieure à la dernière session', format('SELECT mf.ouvrir_session_caisse(%s, ''2026-10-01'', 1000000)', t.cx('CF')));
SELECT ouvrir_session_caisse(t.cx('CF'), '2026-10-02', 1000000);
SELECT t.eq('A ouverture conforme : aucun écart', ecart_ouverture::text, '0') FROM session_caisse WHERE id = t.cs('CF','2026-10-02');
-- écart accepté et tracé (autre caisse : G2, fermée à 5000, rouverte à 4500)
SELECT ouvrir_session_caisse(t.cx('G2'), '2026-10-01', 5000);
SELECT fermer_session_caisse(t.cs('G2','2026-10-01'), 5000);
SELECT ouvrir_session_caisse(t.cx('G2'), '2026-10-02', 4500, NULL, NULL, true);
SELECT t.eq('A écart d''ouverture accepté et tracé', ecart_ouverture::text, '-500') FROM session_caisse WHERE id = t.cs('G2','2026-10-02');
SELECT fermer_session_caisse(t.cs('G2','2026-10-02'), 4500);

-- ===== B. Transferts entre caisses =====
SELECT ouvrir_session_caisse(t.cx('G1'), '2026-10-02', 50000);
SELECT transferer_entre_caisses(t.cs('CF','2026-10-02'), t.cs('G1','2026-10-02'), 200000, '2026-10-02', 'approvisionnement');
SELECT t.eq('B coffre débité', solde_theorique::text, '800000') FROM v_session_caisse_solde WHERE session_id = t.cs('CF','2026-10-02');
SELECT t.eq('B guichet crédité', solde_theorique::text, '250000') FROM v_session_caisse_solde WHERE session_id = t.cs('G1','2026-10-02');
SELECT t.eq('B opérations de caisse liées', string_agg(motif, ',' ORDER BY motif), 'transfert_entrant,transfert_sortant') FROM operation_caisse WHERE reference_table = 'transfert_caisse';
SELECT t.refuse('B même session', format('SELECT mf.transferer_entre_caisses(%s, %s, 10)', t.cs('CF','2026-10-02'), t.cs('CF','2026-10-02')));
SELECT t.refuse('B au-delà du solde de la caisse source', format('SELECT mf.transferer_entre_caisses(%s, %s, 900000)', t.cs('CF','2026-10-02'), t.cs('G1','2026-10-02')));
SELECT t.refuse('B session destinataire fermée', format('SELECT mf.transferer_entre_caisses(%s, %s, 1000)', t.cs('CF','2026-10-02'), t.cs('G2','2026-10-02')));
SELECT ouvrir_session_caisse(t.cx('KG'), '2026-10-02', 1000);
SELECT t.refuse('B entre agences différentes', format('SELECT mf.transferer_entre_caisses(%s, %s, 500)', t.cs('CF','2026-10-02'), t.cs('KG','2026-10-02')));
SELECT t.eq('B échec : rien n''a bougé', solde_theorique::text, '800000') FROM v_session_caisse_solde WHERE session_id = t.cs('CF','2026-10-02');
SELECT t.eq('B un seul transfert enregistré', count(*)::text, '1') FROM transfert_caisse;

-- ===== C. Banque =====
INSERT INTO compte_banque(agence_id,code,libelle,banque) VALUES (1,'BQ1','Compte principal','Banque Atlantique'),(2,'BQK','Compte Kpalimé','Ecobank');
SELECT versement_en_banque(t.cs('G1','2026-10-02'), (SELECT id FROM compte_banque WHERE code='BQ1'), 100000, '2026-10-02');
SELECT t.eq('C caisse débitée du versement', solde_theorique::text, '150000') FROM v_session_caisse_solde WHERE session_id = t.cs('G1','2026-10-02');
SELECT t.eq('C banque créditée', solde::text, '100000') FROM v_solde_compte_banque WHERE code = 'BQ1';
SELECT retrait_en_banque(t.cs('G1','2026-10-02'), (SELECT id FROM compte_banque WHERE code='BQ1'), 30000, '2026-10-02');
SELECT t.eq('C caisse réalimentée', solde_theorique::text, '180000') FROM v_session_caisse_solde WHERE session_id = t.cs('G1','2026-10-02');
SELECT t.eq('C banque après retrait', solde::text, '70000') FROM v_solde_compte_banque WHERE code = 'BQ1';
SELECT t.refuse('C retrait au-delà du solde bancaire', format('SELECT mf.retrait_en_banque(%s, %s, 500000)', t.cs('G1','2026-10-02'), (SELECT id FROM compte_banque WHERE code='BQ1')));
SELECT t.eq('C refus bancaire : la caisse n''a pas été créditée', solde_theorique::text, '180000') FROM v_session_caisse_solde WHERE session_id = t.cs('G1','2026-10-02');
SELECT t.refuse('C versement vers le compte d''une autre agence', format('SELECT mf.versement_en_banque(%s, %s, 1000)', t.cs('G1','2026-10-02'), (SELECT id FROM compte_banque WHERE code='BQK')));
SELECT t.refuse('C versement au-delà de la caisse', format('SELECT mf.versement_en_banque(%s, %s, 5000000)', t.cs('G1','2026-10-02'), (SELECT id FROM compte_banque WHERE code='BQ1')));
INSERT INTO mouvement_banque(compte_banque_id,date_operation,type,montant,libelle) VALUES
  ((SELECT id FROM compte_banque WHERE code='BQ1'),'2026-10-02','depot_externe',40000,'Refinancement'),
  ((SELECT id FROM compte_banque WHERE code='BQ1'),'2026-10-02','frais',5000,'Frais de tenue de compte');
SELECT t.eq('C solde après dépôt externe et frais', solde::text, '105000') FROM v_solde_compte_banque WHERE code = 'BQ1';
SELECT t.refuse('C frais au-delà du solde (pas de découvert)', format('INSERT INTO mf.mouvement_banque(compte_banque_id,date_operation,type,montant) VALUES (%s,''2026-10-02'',''frais'',999999)', (SELECT id FROM compte_banque WHERE code='BQ1')));
SELECT rapprocher_mouvement_banque((SELECT min(id) FROM mouvement_banque), '2026-10-05');
SELECT t.eq('C mouvement rapproché', rapproche::text || '/' || rapproche_le::text, 'true/2026-10-05') FROM mouvement_banque WHERE id = (SELECT min(id) FROM mouvement_banque);

-- ===== D. État des caisses, liquidités, indicateurs, prévision =====
UPDATE caisse SET plafond = 150000 WHERE code = 'G1';
SELECT t.eq('D état du coffre', etat || '/' || solde::text, 'ouverte/800000') FROM etat_caisses(1::smallint,'2026-10-02') WHERE code = 'CF';
SELECT t.eq('D dépassement du plafond du guichet 1 (180000 - 150000)', depassement_plafond::text, '30000') FROM etat_caisses(1::smallint,'2026-10-02') WHERE code = 'G1';
SELECT t.eq('D caisse fermée : solde compté', etat || '/' || solde::text, 'fermee/4500') FROM etat_caisses(1::smallint,'2026-10-02') WHERE code = 'G2';
SELECT t.eq('D caisse non ouverte ce jour : dernier solde connu', etat || '/' || solde::text, 'non_ouverte/800000') FROM etat_caisses(1::smallint,'2026-10-03') WHERE code = 'CF';
SELECT t.eq('D liquidités = 800000 + 180000 + 4500 + 105000', sum(solde)::text, '1089500') FROM tresorerie_liquidites(1::smallint,'2026-10-02');
SELECT t.eq('D banque à une date antérieure aux mouvements', solde::text, '0') FROM tresorerie_liquidites(1::smallint,'2026-10-01') WHERE nature = 'banque';

INSERT INTO produit_epargne(code,libelle,categorie,type_cycle) VALUES ('P1','Tontine','collecte',1);
INSERT INTO produit_epargne(code,libelle,categorie,solde_minimum) VALUES ('CL','Compte','classique',5000);
INSERT INTO agent(agence_id,matricule,nom) VALUES (1,'A1','Ama');
INSERT INTO client(agence_id,numero,nom) VALUES (1,'C1','Client');
INSERT INTO compte_epargne(agence_id,client_id,produit_id,numero) VALUES (1,1,2,'CE1');
INSERT INTO mouvement_epargne(compte_id,type,montant,date_operation) VALUES (1,'depot',40000,'2026-10-01');
INSERT INTO cycle(agence_id,numero,client_id,produit_id,type_cycle,mise_initiale,mise_courante,objectif,date_debut,date_fin) VALUES (1,'CY1',1,1,1,1000,1000,31000,'2026-10-01','2026-10-31');
INSERT INTO ligne_collecte(cycle_id,page,no_ligne,date_collecte,agent_id,montant_collecte) SELECT 1,1,g,'2026-10-01'::date+g-1,1,1000 FROM generate_series(1,10) g;
INSERT INTO credit(agence_id,numero,client_id,type,montant_accorde,taux,date_deblocage,nb_echeances,mode_remboursement)
VALUES (1,'CR1',1,'sans_epargne',30000,0.12,'2026-10-01',3,'especes');
SELECT generer_echeancier(1);
SELECT t.eq('D engagements clients (épargne 40000 + tontine 10000)', valeur::text, '50000') FROM tresorerie_indicateurs(1::smallint,'2026-10-02') WHERE rubrique = 'engagements_clients';
SELECT t.eq('D ratio de liquidité (1089500 / 50000)', valeur::text, '2179.0') FROM tresorerie_indicateurs(1::smallint,'2026-10-02') WHERE rubrique = 'ratio_liquidite_pct';
SELECT t.eq('D à recevoir sous 30 jours (échéance 1 : 10300)', valeur::text, '10300') FROM tresorerie_indicateurs(1::smallint,'2026-10-02') WHERE rubrique = 'a_recevoir_30_jours';
SELECT t.eq('D échéance en retard au 5/11 (échéance 1 impayée)', valeur::text, '10300') FROM tresorerie_indicateurs(1::smallint,'2026-11-05') WHERE rubrique = 'echeances_en_retard';
SELECT t.eq('D prévision sur 60 jours par tranches de 30', string_agg(encaissements::text || '/' || solde_projete::text, ' ' ORDER BY debut), '10300/1099800 10200/1110000') FROM prevision_tresorerie(1::smallint,'2026-10-02',60,30);
SELECT t.refuse('D prévision : paramètres invalides', 'SELECT * FROM mf.prevision_tresorerie(1::smallint, current_date, 0, 7)');

-- ===== E. Comptabilisation automatique des mouvements bancaires =====
INSERT INTO exercice_comptable(code,date_debut,date_fin) VALUES ('2026','2026-01-01','2026-12-31');
INSERT INTO parametre(agence_id,cle,valeur) VALUES (1,'comptabilisation_auto','oui');
SELECT versement_en_banque(t.cs('G1','2026-10-02'), (SELECT id FROM compte_banque WHERE code='BQ1'), 10000, '2026-10-03');
SELECT t.eq('E versement en banque comptabilisé : D 1141 / C 1011', debit::text || '/' || credit::text, '10000/10000')
  FROM (SELECT sum(debit) FILTER (WHERE compte_code = '1141') AS debit, sum(credit) FILTER (WHERE compte_code = '1011') AS credit
          FROM ecriture e JOIN piece_comptable p ON p.id = e.piece_id WHERE p.evenement = 'versement_banque') x;
