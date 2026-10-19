SET search_path = mf, public;

-- Module sous test : 20_ratios_prudentiels.sql (ratios prudentiels I à IX du guide d'audit externe, saisies complémentaires, historique)
INSERT INTO agence(code,libelle) VALUES ('LOM','Lomé Centre'),('KPA','Kpalimé');
INSERT INTO utilisateur(agence_id,login,nom,role) VALUES (1,'chef','Chef','chef_agence');
INSERT INTO exercice_comptable(code,date_debut,date_fin) VALUES ('2026','2026-01-01','2026-12-31');
INSERT INTO client(agence_id,numero,nom) VALUES (1,'C1','Dirigeant Un'),(1,'C2','Client Deux'),(1,'C3','Client Trois');
CREATE FUNCTION pg_temp.ac(p text) RETURNS text LANGUAGE sql AS $$ SELECT min(code) FROM mf.compte_comptable WHERE code LIKE p || '%' AND imputable $$;
CREATE FUNCTION pg_temp.acp(p_poste text) RETURNS text LANGUAGE sql AS $$
  SELECT min(c.code) FROM mf.compte_comptable c JOIN mf.poste_compte pc ON c.code LIKE pc.prefixe || '%' WHERE pc.poste_code = p_poste AND c.imputable $$;
CREATE FUNCTION pg_temp.piece(p_agence smallint, p_date date, p_debit text, p_credit text, p_montant numeric) RETURNS void LANGUAGE plpgsql AS $$
DECLARE v bigint;
BEGIN
  INSERT INTO mf.piece_comptable(agence_id,journal_id,exercice_id,date_piece,numero,libelle,origine)
  VALUES (p_agence,(SELECT id FROM mf.journal WHERE code='OD'),(SELECT id FROM mf.exercice_comptable LIMIT 1),p_date,
          mf.prochain_numero('piece',p_agence,p_date,'PC'),'test','manuelle') RETURNING id INTO v;
  INSERT INTO mf.ecriture(piece_id,ligne,compte_code,debit,credit) VALUES (v,1,p_debit,p_montant,0),(v,2,p_credit,0,p_montant);
END $$;
CREATE FUNCTION pg_temp.r(p_ratio text, p_agence smallint DEFAULT 1) RETURNS TABLE (valeur numeric, conforme boolean, manquantes text, norme_type text, norme numeric) LANGUAGE sql AS $$
  SELECT r.valeur, r.conforme, array_to_string(r.saisies_manquantes, ','), r.norme_type, r.norme FROM mf.ratios_prudentiels(p_agence, DATE '2026-10-31') r WHERE r.ratio = p_ratio $$;

-- ===== Écritures : capital 100000, dépôts 50000, crédit CT 30000, intérêts 3000, participation 5000 =====
SELECT pg_temp.piece(1::smallint,'2026-10-05', pg_temp.ac('1011'),  pg_temp.ac('5711'),  100000);
SELECT pg_temp.piece(1::smallint,'2026-10-05', pg_temp.ac('1011'),  pg_temp.ac('25111'),  50000);
SELECT pg_temp.piece(1::smallint,'2026-10-05', pg_temp.ac('20221'), pg_temp.ac('1011'),   30000);
SELECT pg_temp.piece(1::smallint,'2026-10-05', pg_temp.ac('1011'),  pg_temp.ac('70212'),    3000);
SELECT pg_temp.piece(1::smallint,'2026-10-05', pg_temp.acp('D1E'),  pg_temp.ac('1011'),     5000);
-- Portefeuille : un dirigeant (20000) et un client ordinaire (40000), sans remboursement
UPDATE client SET qualite_interne = 'dirigeant' WHERE id = 1;
INSERT INTO credit(agence_id,numero,client_id,type,montant_accorde,taux,date_deblocage,nb_echeances,mode_remboursement) VALUES
  (1,'CR-1',1,'sans_epargne',20000,0.12,'2026-10-01',4,'especes'),(1,'CR-2',2,'sans_epargne',40000,0.12,'2026-10-01',4,'especes');

-- ===== A. Fonds propres retraités =====
SELECT t.eq('A fonds propres = capital + excédent (L60 + L75)', fonds_propres_retraites(1::smallint,'2026-10-31')::text, '103000');
SELECT t.eq('A fonds propres consolidés (réseau)', fonds_propres_retraites(NULL,'2026-10-31')::text, '103000');

-- ===== B. Les neuf ratios =====
SELECT t.eq('B I limitation des risques : 30000 / 150000', valeur::text || ' ' || conforme || ' ' || norme_type || norme, '20.00 true max200') FROM pg_temp.r('I');
SELECT t.eq('B II couverture MLT : 100000 / 5000, depots_mlt à saisir', valeur::text || ' ' || conforme || ' ' || manquantes, '2000.00 true depots_mlt') FROM pg_temp.r('II');
SELECT t.eq('B III prêts aux dirigeants : 20000 / 103000, non conforme', valeur::text || ' ' || conforme || ' ' || norme_type || norme, '19.42 false max10') FROM pg_temp.r('III');
SELECT t.eq('B IV plus gros risque : 40000 / 103000, non conforme', valeur::text || ' ' || conforme, '38.83 false') FROM pg_temp.r('IV');
SELECT t.eq('B V liquidité : 148000 / 50000, trois saisies à faire', valeur::text || ' ' || conforme || ' ' || manquantes, '296.00 true depots_mlt,engagements_ct_donnes,engagements_ct_recus') FROM pg_temp.r('V');
SELECT t.eq('B VI autres opérations : 0 / 35000, saisie manquante', valeur::text || ' ' || conforme || ' ' || manquantes, '0.00 true ops_autres_activites') FROM pg_temp.r('VI');
SELECT t.eq('B VII réserve générale : aucune réserve pour un excédent de 3000', valeur::text || ' ' || conforme, '0.00 false') FROM pg_temp.r('VII');
SELECT t.eq('B VIII capitalisation : fonds propres moyens 51500 / actif 153000', valeur::text || ' ' || conforme || ' ' || norme_type || norme, '33.66 true min15') FROM pg_temp.r('VIII');
SELECT t.eq('B IX participations : 5000 / 103000', valeur::text || ' ' || conforme || ' ' || norme_type || norme, '4.85 true max25') FROM pg_temp.r('IX');
SELECT t.eq('B neuf ratios restitués', count(*)::text, '9') FROM ratios_prudentiels(1::smallint,'2026-10-31');
SELECT t.eq('B réseau : même résultat qu''une agence seule (l''autre est vide)', valeur::text, '20.00') FROM pg_temp.r('I', NULL);

-- ===== C. Saisies complémentaires =====
INSERT INTO donnee_reglementaire(agence_id,code,date_effet,valeur,commentaire,saisi_par) VALUES
  (1,'depots_mlt','2026-10-01',40000,'DAT à 18 mois',1),(1,'engagements_ct_donnes','2026-10-01',10000,NULL,1),(1,'engagements_ct_recus','2026-10-01',0,NULL,1),(1,'ops_autres_activites','2026-10-01',700,NULL,1);
SELECT t.eq('C II avec 40000 de dépôts à plus d''un an : 140000 / 5000, plus de saisie manquante', valeur::text || ' ' || manquantes, '2800.00 ') FROM pg_temp.r('II');
SELECT t.eq('C V : numérateur 148000 + 10000, dénominateur 50000 - 40000', valeur::text || ' ' || manquantes, '1580.00 ') FROM pg_temp.r('V');
SELECT t.eq('C VI : 700 / 35000', valeur::text || ' ' || conforme, '2.00 true') FROM pg_temp.r('VI');
INSERT INTO donnee_reglementaire(agence_id,code,date_effet,valeur) VALUES (1,'ops_autres_activites','2026-12-01',9999);
SELECT t.eq('C une saisie datée après la date de calcul est ignorée', valeur::text, '2.00') FROM pg_temp.r('VI');
INSERT INTO donnee_reglementaire(agence_id,code,date_effet,valeur) VALUES (1,'ops_autres_activites','2026-10-20',3500);
SELECT t.eq('C la saisie la plus récente avant la date fait foi', valeur::text || ' ' || conforme, '10.00 false') FROM pg_temp.r('VI');
INSERT INTO donnee_reglementaire(agence_id,code,date_effet,valeur) VALUES (1,'complement_provisions_autorites','2026-10-01',3000);
SELECT t.eq('C compléments de provisions déduits des fonds propres', fonds_propres_retraites(1::smallint,'2026-10-31')::text, '100000');
SELECT t.refuse('C modifier une saisie', 'UPDATE mf.donnee_reglementaire SET valeur = 1');
SELECT t.refuse('C supprimer une saisie', 'DELETE FROM mf.donnee_reglementaire');
SELECT t.refuse('C valeur négative', 'INSERT INTO mf.donnee_reglementaire(agence_id,code,date_effet,valeur) VALUES (1,''depots_mlt'',''2026-10-01'',-5)');
SELECT t.refuse('C code inconnu', 'INSERT INTO mf.donnee_reglementaire(agence_id,code,date_effet,valeur) VALUES (1,''fantaisie'',''2026-10-01'',5)');

-- ===== D. Réserve générale =====
SELECT pg_temp.piece(1::smallint,'2026-10-10', pg_temp.ac('1011'), pg_temp.ac('5521'), 600);
SELECT t.eq('D VII : réserve de 600 pour un excédent de 3000 (15 % = 450)', valeur::text || ' ' || conforme, '20.00 true') FROM pg_temp.r('VII');

-- ===== E. Seuils paramétrables et norme de liquidité =====
UPDATE parametre SET valeur = '10' WHERE cle = 'ratio_norme_I' AND agence_id IS NULL;
SELECT t.eq('E seuil du ratio I modifié : la norme suit', conforme::text || ' ' || norme, 'false 10') FROM pg_temp.r('I');
UPDATE parametre SET valeur = '200' WHERE cle = 'ratio_norme_I' AND agence_id IS NULL;
UPDATE parametre SET valeur = 'affilie' WHERE cle = 'type_institution_liquidite' AND agence_id IS NULL;
SELECT t.eq('E institution affiliée : plancher de liquidité à 80', norme::text, '80') FROM pg_temp.r('V');
UPDATE parametre SET valeur = 'sans_depots' WHERE cle = 'type_institution_liquidite' AND agence_id IS NULL;
SELECT t.eq('E institution sans dépôts : plancher à 60', norme::text, '60') FROM pg_temp.r('V');
UPDATE parametre SET valeur = 'non_affilie' WHERE cle = 'type_institution_liquidite' AND agence_id IS NULL;
SELECT t.refuse('E qualité interne inconnue', 'UPDATE mf.client SET qualite_interne = ''roi'' WHERE id = 1');

-- ===== F. Historique =====
SELECT t.eq('F instantané enregistré : 9 lignes', enregistrer_ratios(1::smallint,'2026-10-31',1)::text, '9');
SELECT t.eq('F instantané relu', string_agg(ratio || '=' || valeur, ' ' ORDER BY ratio) FILTER (WHERE ratio IN ('I','IV','IX')), 'I=19.92 IV=39.76 IX=4.97') FROM ratio_historique WHERE agence_id = 1;
SELECT t.refuse('F historique non modifiable', 'UPDATE mf.ratio_historique SET valeur = 0');
SELECT t.refuse('F historique non supprimable', 'DELETE FROM mf.ratio_historique');

-- ===== G. Hypothèses de calcul paramétrables et validables =====
SELECT t.eq('G quatre hypothèses, aucune validée au départ', count(*)::text || '/' || count(*) FILTER (WHERE validee), '4/0') FROM v_hypotheses;
SELECT t.eq('G valeurs par défaut', string_agg(code || '=' || valeur, ' ' ORDER BY code), 'compte_A2J=II_et_V depots_garantie_ratio_I=non normes_a_jour=non_verifiees signature_ratio_IV=client') FROM v_hypotheses;
SELECT pg_temp.piece(1::smallint,'2026-10-12', pg_temp.ac('1011'), pg_temp.ac('2545'), 10000);    -- dépôt de garantie reçu (G30)
SELECT pg_temp.piece(1::smallint,'2026-10-12', pg_temp.ac('1281'), pg_temp.ac('1011'),  7000);    -- autre dépôt constitué (A2J)
SELECT t.eq('G ratio I sans déduction des dépôts de garantie : 30000 / 160600', valeur::text, '18.68') FROM pg_temp.r('I');
SELECT modifier_hypothese('depots_garantie_ratio_I', 'oui');
SELECT t.eq('G ratio I avec déduction du dépôt de garantie : 20000 / 160600', valeur::text, '12.45') FROM pg_temp.r('I');
SELECT modifier_hypothese('depots_garantie_ratio_I', 'non');
SELECT t.refuse('G valeur d''hypothèse hors liste', 'SELECT mf.modifier_hypothese(''depots_garantie_ratio_I'', ''peut-etre'')');
SELECT t.refuse('G hypothèse inconnue', 'SELECT mf.modifier_hypothese(''fantaisie'', ''oui'')');
-- A2J : numérateur du ratio V (II_et_V puis II_seulement) et dénominateur du ratio II
SELECT t.eq('G A2J compté aux deux ratios : V = 168600, II = 5000 + 7000', (SELECT numerateur FROM ratios_prudentiels(1::smallint,'2026-10-31') WHERE ratio = 'V')::text || '/' ||
            (SELECT denominateur FROM ratios_prudentiels(1::smallint,'2026-10-31') WHERE ratio = 'II')::text, '168600/12000');
SELECT modifier_hypothese('compte_A2J', 'II_seulement');
SELECT t.eq('G A2J compté au ratio II seulement : V = 161600, II = 12000', (SELECT numerateur FROM ratios_prudentiels(1::smallint,'2026-10-31') WHERE ratio = 'V')::text || '/' ||
            (SELECT denominateur FROM ratios_prudentiels(1::smallint,'2026-10-31') WHERE ratio = 'II')::text, '161600/12000');
SELECT modifier_hypothese('compte_A2J', 'V_seulement');
SELECT t.eq('G A2J compté au ratio V seulement : V = 168600, II = 5000', (SELECT numerateur FROM ratios_prudentiels(1::smallint,'2026-10-31') WHERE ratio = 'V')::text || '/' ||
            (SELECT denominateur FROM ratios_prudentiels(1::smallint,'2026-10-31') WHERE ratio = 'II')::text, '168600/5000');
SELECT modifier_hypothese('compte_A2J', 'II_et_V');
-- « une seule signature » : un client puis un groupe
SELECT t.eq('G signature = client : 40000 / 100600', valeur::text, '39.76') FROM pg_temp.r('IV');
INSERT INTO lien_client(client_id,lie_a_id,type) VALUES (1,2,'groupe'), (2,3,'famille');
SELECT modifier_hypothese('signature_ratio_IV', 'groupe');
SELECT t.eq('G signature = groupe (clients 1 et 2 liés, le lien de famille ne compte pas) : 60000 / 100600', valeur::text, '59.64') FROM pg_temp.r('IV');
SELECT t.eq('G encours par signature regroupé : les clients 1 et 2 forment 1 signature', count(*)::text || '/' || max(encours), '1/60000') FROM encours_par_signature(1::smallint,'2026-10-31', true);
SELECT t.eq('G encours par signature sans regroupement : 2 clients', count(*)::text || '/' || max(encours), '2/40000') FROM encours_par_signature(1::smallint,'2026-10-31', false);
SELECT modifier_hypothese('signature_ratio_IV', 'client');
-- validation : porte sur une valeur, tombe si la valeur change
SELECT valider_hypothese('depots_garantie_ratio_I', 1, 'validé avec le comptable');
SELECT t.eq('G hypothèse validée', validee::text || ' ' || validee_par_login, 'true chef') FROM v_hypotheses WHERE code = 'depots_garantie_ratio_I';
SELECT modifier_hypothese('depots_garantie_ratio_I', 'oui');
SELECT t.eq('G la valeur change : la validation ne couvre plus la nouvelle valeur', validee::text, 'false') FROM v_hypotheses WHERE code = 'depots_garantie_ratio_I';
SELECT t.refuse('G validation non modifiable', 'UPDATE mf.hypothese_validation SET valeur = ''x''');
SELECT t.refuse('G validation d''une hypothèse inconnue', 'SELECT mf.valider_hypothese(''fantaisie'', 1)');
-- seuils modifiables
SELECT modifier_hypothese('normes_a_jour', 'verifiees');
SELECT t.eq('G seuils déclarés vérifiés', valeur, 'verifiees') FROM v_hypotheses WHERE code = 'normes_a_jour';
SELECT modifier_norme_ratio('ratio_norme_IX', 20);
SELECT t.eq('G seuil IX modifié, la norme suit', norme::text, '20') FROM pg_temp.r('IX');
SELECT t.eq('G un seuil modifié remet « seuils vérifiés » à non vérifiés', valeur, 'non_verifiees') FROM v_hypotheses WHERE code = 'normes_a_jour';
SELECT t.refuse('G ce n''est pas un seuil de ratio', 'SELECT mf.modifier_norme_ratio(''taux_commission'', 5)');
SELECT t.refuse('G seuil nul', 'SELECT mf.modifier_norme_ratio(''ratio_norme_IX'', 0)');
SELECT t.refuse('G seuil excessif', 'SELECT mf.modifier_norme_ratio(''ratio_norme_IX'', 5000)');
SELECT t.refuse('G seuil inconnu', 'SELECT mf.modifier_norme_ratio(''ratio_norme_X'', 5)');
