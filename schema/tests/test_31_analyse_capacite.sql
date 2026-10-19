SET search_path = mf, public;

-- Module sous test : 31_analyse_capacite.sql (analyse de capacité de remboursement d'une demande de crédit)
INSERT INTO agence(code,libelle) VALUES ('LOM','Lomé Centre');
INSERT INTO client(agence_id,nom) VALUES (1,'Client un');
INSERT INTO produit_credit_epargne(code,libelle,type,taux_annuel) VALUES ('PC','Produit','sans_epargne',0.18);
INSERT INTO demande_credit(agence_id,client_id,produit_id,montant,nb_echeances,taux,mode_remboursement) VALUES (1,1,1,600000,12,0.18,'especes');

SELECT t.eq('A seuils par défaut', mf.param_num('endettement_max_pct', 1::smallint)::text || '/' || mf.param_num('couverture_min', 1::smallint)::text, '33/1.5');

INSERT INTO analyse_capacite(agence_id,demande_id,client_id,ventes_mensuelles,achats_mensuels,resultat,taux_endettement,couverture,conforme)
VALUES (1,1,1,900000,600000,'{"revenus":214000}'::jsonb,0.2570,1.891,true);
SELECT t.eq('A analyse enregistrée', taux_endettement::text || '/' || couverture::text || '/' || conforme::text, '0.2570/1.891/true') FROM analyse_capacite;
SELECT t.refuse('A une seule analyse par demande', 'INSERT INTO mf.analyse_capacite(agence_id,demande_id,client_id,resultat,conforme) VALUES (1,1,1,''{}''::jsonb,true)');
SELECT t.refuse('A jours d''activité hors bornes', 'UPDATE mf.analyse_capacite SET jours_activite = 40');
SELECT t.refuse('A ventes négatives', 'UPDATE mf.analyse_capacite SET ventes_mensuelles = -1');
UPDATE analyse_capacite SET autres_revenus = 50000, taux_endettement = 0.21, modifie_le = now() WHERE demande_id = 1;
SELECT t.eq('A modifiable tant que la demande est demandée', autres_revenus::text, '50000') FROM analyse_capacite;

-- ===== B. Gel après la décision =====
UPDATE demande_credit SET statut = 'approuvee', date_decision = current_date WHERE id = 1;
SELECT t.refuse('B modification refusée après décision', 'UPDATE mf.analyse_capacite SET autres_revenus = 1');
SELECT t.refuse('B suppression refusée après décision', 'DELETE FROM mf.analyse_capacite');
INSERT INTO demande_credit(agence_id,client_id,produit_id,montant,nb_echeances,taux,mode_remboursement) VALUES (1,1,1,100000,6,0.18,'especes');
INSERT INTO analyse_capacite(agence_id,demande_id,client_id,resultat,conforme) VALUES (1,(SELECT max(id) FROM demande_credit),1,'{}'::jsonb,false);
SELECT t.eq('B analyse de la seconde demande', count(*)::text, '2') FROM analyse_capacite;
