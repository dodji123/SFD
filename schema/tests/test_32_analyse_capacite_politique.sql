SET search_path = mf, public;

-- Module sous test : 32_analyse_capacite_politique.sql (politique de crédit paramétrable, colonnes de l'analyse)
INSERT INTO agence(code,libelle) VALUES ('LOM','Lomé Centre');
INSERT INTO client(agence_id,nom) VALUES (1,'Client un');
INSERT INTO produit_credit_epargne(code,libelle,type,taux_annuel) VALUES ('PC','Produit','sans_epargne',0.18);
INSERT INTO demande_credit(agence_id,client_id,produit_id,montant,nb_echeances,taux,mode_remboursement) VALUES (1,1,1,600000,12,0.18,'especes');

SELECT t.eq('A poids du score par défaut',
  mf.param_num('score_poids_capacite', 1::smallint)::text || '/' || mf.param_num('score_poids_endettement', 1::smallint)::text || '/' || mf.param_num('score_poids_garanties', 1::smallint)::text
  || '/' || mf.param_num('score_poids_anciennete', 1::smallint)::text || '/' || mf.param_num('score_poids_historique', 1::smallint)::text, '35/20/15/15/15');
SELECT t.eq('A seuils de l''avis', mf.param_num('score_seuil_favorable', 1::smallint)::text || '/' || mf.param_num('score_seuil_conditions', 1::smallint)::text || '/' || mf.param_num('score_seuil_risque', 1::smallint)::text, '75/55/35');
SELECT t.eq('A plafonds par cycle', (SELECT string_agg(valeur, ',' ORDER BY cle) FROM parametre WHERE cle LIKE 'plafond_cycle_%'), '300000,500000,800000,1200000,2000000');
SELECT t.eq('A garanties exigées', mf.param_num('garantie_min_pct', 1::smallint)::text, '100');
-- une agence peut surcharger la politique
INSERT INTO parametre(agence_id,cle,valeur) VALUES (1,'plafond_cycle_1','150000');
SELECT t.eq('A surcharge par agence', mf.param_num('plafond_cycle_1', 1::smallint)::text, '150000');

INSERT INTO analyse_capacite(agence_id,demande_id,client_id,resultat,conforme) VALUES (1,1,1,'{}'::jsonb,true);
SELECT t.eq('B valeurs par défaut du dossier', cycle || '/' || caution || '/' || historique || '/' || jsonb_array_length(garanties) || '/' || jsonb_array_length(scenarios) || '/' || jsonb_array_length(groupe), '1/perso/bon/0/0/0') FROM analyse_capacite;
SELECT t.refuse('B cycle hors bornes', 'UPDATE mf.analyse_capacite SET cycle = 6');
SELECT t.refuse('B caution inconnue', 'UPDATE mf.analyse_capacite SET caution = ''voisin''');
SELECT t.refuse('B historique inconnu', 'UPDATE mf.analyse_capacite SET historique = ''excellent''');
SELECT t.refuse('B ventes mensuelles : exactement 12 mois', 'UPDATE mf.analyse_capacite SET ventes_par_mois = ''[1,2,3]''::jsonb');
UPDATE analyse_capacite SET ventes_par_mois = to_jsonb(array_fill(900000, ARRAY[12])), score = 96.6, avis = 'Favorable', cycle = 3, caution = 'groupe', historique = 'mineur',
  garanties = '[{"type":"materiel","valeur":300000,"decote":50}]'::jsonb;
SELECT t.eq('B dossier complet enregistré', cycle || '/' || caution || '/' || historique || '/' || jsonb_array_length(ventes_par_mois) || '/' || score || '/' || avis, '3/groupe/mineur/12/96.6/Favorable') FROM analyse_capacite;
