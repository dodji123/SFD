-- =====================================================================
-- 21_provisions.sql
-- Classification des créances et provisionnement, selon le référentiel comptable des SFD de l'UMOA
-- (comptes 29 « crédits en souffrance et immobilisés » et 299 « provisions »).
--  * l'ANCIENNETÉ de l'impayé est celle de la plus ancienne échéance impayée du crédit ; le déclassement porte sur la
--    totalité de l'encours du crédit (échu ou non) ;
--  * classes : 0 à 3 mois (compte 2921, déclassement et provision facultatifs), 3 à 6 mois (2922), 6 à 12 mois (293),
--    12 à 24 mois (294), plus de 24 mois (irrécouvrable : à passer en charges, provisionné à 100 % en attendant) ;
--  * provision = taux × solde restant dû, où solde restant dû = encours - dépôts constitués en garantie ;
--    taux réglementaires : 40 % jusqu'à 6 mois, 80 % de 6 à 12 mois, 100 % de 12 à 24 mois ;
--  * une règle interne plus stricte peut être paramétrée (prov_interne_*) : la provision retenue est la plus élevée,
--    les deux sont affichées ;
--  * generer_provisions passe la pièce de dotation ou de reprise (écart entre la provision requise et les comptes 299).
-- Un mois vaut 30 jours (paramètres prov_jours_*). La comptabilisation du déclassement lui-même (transfert de l'encours
-- vers 2921 à 294) et le passage en perte (compte 6691) ne sont pas automatisés : la classification les liste.
-- Dépend de : 14 (portefeuille_a_date), 05 (pièces), 08 (garanties).
-- =====================================================================
SET search_path = mf, public;

INSERT INTO parametre(agence_id, cle, valeur, description) VALUES
  (NULL, 'prov_jours_3m',  '90',  'ancienneté de l''impayé (jours) : fin de la tranche 0 à 3 mois'),
  (NULL, 'prov_jours_6m',  '180', 'fin de la tranche 3 à 6 mois'),
  (NULL, 'prov_jours_12m', '360', 'fin de la tranche 6 à 12 mois'),
  (NULL, 'prov_jours_24m', '720', 'fin de la tranche 12 à 24 mois : au-delà, créance irrécouvrable'),
  (NULL, 'prov_taux_6m',   '40',  'taux de provision réglementaire des crédits en souffrance de 3 à 6 mois, en %'),
  (NULL, 'prov_taux_12m',  '80',  'taux réglementaire de 6 à 12 mois, en %'),
  (NULL, 'prov_taux_24m',  '100', 'taux réglementaire de 12 à 24 mois et au-delà, en %'),
  (NULL, 'prov_declasser_0_3m', 'non', 'oui : les crédits impayés depuis 0 à 3 mois sont déclassés (facultatif dans le référentiel)'),
  (NULL, 'prov_provisionner_0_3m', 'non', 'oui : les crédits déclassés de 0 à 3 mois sont provisionnés (facultatif dans le référentiel)'),
  (NULL, 'prov_taux_0_3m', '40',  'taux appliqué de 0 à 3 mois si prov_provisionner_0_3m = oui, en %')
ON CONFLICT DO NOTHING;
-- Règle interne plus stricte (facultative) : créer les paramètres prov_interne_0_3m, prov_interne_3_6m, prov_interne_6_12m,
-- prov_interne_12_24m (taux en %) ; absents, la provision retenue est la provision réglementaire.

-- Classification de chaque crédit à une date
CREATE FUNCTION classification_creances(p_agence smallint, p_date date)
RETURNS TABLE (credit_id integer, numero text, client_id integer, client text, capital_restant numeric, garantie_bloquee numeric,
               jours_retard integer, classe text, declasse boolean, compte_encours text, solde_restant_du numeric,
               taux_reglementaire numeric, provision_reglementaire numeric, taux_interne numeric, provision_interne numeric,
               provision_retenue numeric, compte_provision text, a_passer_en_perte boolean)
LANGUAGE sql STABLE AS $$
  WITH pf AS (
    SELECT ag.id::smallint AS agence_id, p.* FROM mf.agence ag CROSS JOIN LATERAL mf.portefeuille_a_date(ag.id, p_date) p
     WHERE p_agence IS NULL OR ag.id = p_agence
  ), cl AS (
    SELECT pf.*,
           CASE WHEN pf.jours_retard <= 0 THEN 'sain'
                WHEN pf.jours_retard <= mf.param_num('prov_jours_3m', pf.agence_id)  THEN '0_3'
                WHEN pf.jours_retard <= mf.param_num('prov_jours_6m', pf.agence_id)  THEN '3_6'
                WHEN pf.jours_retard <= mf.param_num('prov_jours_12m', pf.agence_id) THEN '6_12'
                WHEN pf.jours_retard <= mf.param_num('prov_jours_24m', pf.agence_id) THEN '12_24'
                ELSE 'irrecouvrable' END AS classe
      FROM pf
  ), v AS (
    SELECT cl.*,
           (cl.classe <> 'sain' AND (cl.classe <> '0_3' OR mf.param('prov_declasser_0_3m', cl.agence_id) = 'oui')) AS declasse,
           GREATEST(cl.capital_restant - cl.garantie_bloquee, 0) AS srd
      FROM cl
  ), t AS (
    SELECT v.*,
           CASE v.classe WHEN '0_3' THEN CASE WHEN v.declasse AND mf.param('prov_provisionner_0_3m', v.agence_id) = 'oui'
                                              THEN mf.param_num('prov_taux_0_3m', v.agence_id) ELSE 0 END
                         WHEN '3_6' THEN mf.param_num('prov_taux_6m', v.agence_id)
                         WHEN '6_12' THEN mf.param_num('prov_taux_12m', v.agence_id)
                         WHEN '12_24' THEN mf.param_num('prov_taux_24m', v.agence_id)
                         WHEN 'irrecouvrable' THEN mf.param_num('prov_taux_24m', v.agence_id)
                         ELSE 0 END AS taux_reg,
           CASE v.classe WHEN '0_3' THEN mf.param_num('prov_interne_0_3m', v.agence_id)
                         WHEN '3_6' THEN mf.param_num('prov_interne_3_6m', v.agence_id)
                         WHEN '6_12' THEN mf.param_num('prov_interne_6_12m', v.agence_id)
                         WHEN '12_24' THEN mf.param_num('prov_interne_12_24m', v.agence_id)
                         WHEN 'irrecouvrable' THEN mf.param_num('prov_interne_12_24m', v.agence_id)
                         ELSE NULL END AS taux_int
      FROM v
  ), m AS (
    SELECT t.*, round(t.srd * t.taux_reg / 100) AS p_reg, round(t.srd * t.taux_int / 100) AS p_int FROM t
  )
  SELECT m.credit_id, m.numero, m.client_id, m.client, m.capital_restant, m.garantie_bloquee, m.jours_retard, m.classe, m.declasse,
         CASE WHEN NOT m.declasse THEN NULL WHEN m.classe = '0_3' THEN '2921' WHEN m.classe = '3_6' THEN '2922'
              WHEN m.classe = '6_12' THEN '293' ELSE '294' END,
         m.srd, m.taux_reg, m.p_reg, m.taux_int, m.p_int,
         GREATEST(m.p_reg, COALESCE(m.p_int, 0)),
         CASE WHEN GREATEST(m.p_reg, COALESCE(m.p_int, 0)) = 0 THEN NULL
              WHEN m.classe = '0_3' THEN '29911' WHEN m.classe = '3_6' THEN '29912' WHEN m.classe = '6_12' THEN '2992' ELSE '2993' END,
         (m.classe = 'irrecouvrable')
    FROM m ORDER BY m.jours_retard DESC, m.numero
$$;

-- Provisions constituées dans les comptes 299 (solde créditeur) à une date
CREATE FUNCTION provisions_constituees(p_agence smallint, p_date date)
RETURNS TABLE (compte text, montant numeric)
LANGUAGE sql STABLE AS $$
  SELECT c.code::text, COALESCE((SELECT sum(e.credit - e.debit) FROM mf.ecriture e JOIN mf.piece_comptable p ON p.id = e.piece_id
                                  WHERE e.compte_code = c.code AND p.date_piece <= p_date AND (p_agence IS NULL OR p.agence_id = p_agence)), 0)
    FROM mf.compte_comptable c WHERE c.code IN ('29911','29912','2992','2993') ORDER BY c.code
$$;

-- Rapport par classe : encours, solde restant dû, provision réglementaire / interne / retenue
CREATE FUNCTION rapport_provisions(p_agence smallint, p_date date)
RETURNS TABLE (classe text, libelle text, nb_credits bigint, encours numeric, solde_restant_du numeric,
               provision_reglementaire numeric, provision_interne numeric, provision_retenue numeric)
LANGUAGE sql STABLE AS $$
  WITH c AS (SELECT * FROM mf.classification_creances(p_agence, p_date)),
  ref(classe, libelle, ordre) AS (VALUES ('sain','Crédits sains',1), ('0_3','Impayés de 0 à 3 mois',2), ('3_6','Impayés de 3 à 6 mois',3),
        ('6_12','Impayés de 6 à 12 mois',4), ('12_24','Impayés de 12 à 24 mois',5), ('irrecouvrable','Plus de 24 mois : irrécouvrables',6))
  SELECT r.classe, r.libelle, count(c.credit_id), COALESCE(sum(c.capital_restant), 0), COALESCE(sum(c.solde_restant_du), 0),
         COALESCE(sum(c.provision_reglementaire), 0), COALESCE(sum(c.provision_interne), 0), COALESCE(sum(c.provision_retenue), 0)
    FROM ref r LEFT JOIN c ON c.classe = r.classe GROUP BY r.classe, r.libelle, r.ordre ORDER BY r.ordre
$$;

-- Écart par compte entre la provision requise et la provision constituée (dotation si positif, reprise si négatif)
CREATE FUNCTION ecarts_provisions(p_agence smallint, p_date date)
RETURNS TABLE (compte text, dotation text, reprise text, requis numeric, constitue numeric, delta numeric)
LANGUAGE sql STABLE AS $$
  SELECT k.compte, k.dotation, k.reprise, COALESCE(req.montant, 0), COALESCE(cst.montant, 0), COALESCE(req.montant, 0) - COALESCE(cst.montant, 0)
    FROM (VALUES ('29911','66411','76411'), ('29912','66412','76412'), ('2992','6642','7642'), ('2993','6643','7643')) AS k(compte, dotation, reprise)
    LEFT JOIN (SELECT compte_provision, sum(provision_retenue) AS montant FROM mf.classification_creances(p_agence, p_date)
                WHERE compte_provision IS NOT NULL GROUP BY compte_provision) req ON req.compte_provision = k.compte
    LEFT JOIN mf.provisions_constituees(p_agence, p_date) cst ON cst.compte = k.compte
   ORDER BY k.compte
$$;

-- Pièce de dotation ou de reprise : amène chaque compte 299 au niveau de la provision retenue (une pièce par agence et par jour)
CREATE FUNCTION generer_provisions(p_agence smallint, p_date date, p_utilisateur integer DEFAULT NULL) RETURNS bigint
LANGUAGE plpgsql AS $$
DECLARE v_piece bigint; v_ex integer; v_j integer; v_ligne integer := 0; r record;
BEGIN
  IF p_agence IS NULL THEN RAISE EXCEPTION 'agence obligatoire : les provisions se passent agence par agence'; END IF;
  IF EXISTS (SELECT 1 FROM mf.piece_comptable WHERE agence_id = p_agence AND date_piece = p_date AND evenement = 'provision_creances') THEN
    RAISE EXCEPTION 'provisions déjà passées pour l''agence % au % : contrepasser la pièce pour la refaire', p_agence, p_date;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM mf.ecarts_provisions(p_agence, p_date) WHERE delta <> 0) THEN RETURN NULL; END IF;
  SELECT id INTO v_ex FROM mf.exercice_comptable WHERE p_date BETWEEN date_debut AND date_fin AND statut = 'ouvert';
  IF v_ex IS NULL THEN RAISE EXCEPTION 'aucun exercice comptable ouvert pour le %', p_date; END IF;
  SELECT id INTO v_j FROM mf.journal WHERE code = 'OD';
  INSERT INTO mf.piece_comptable(agence_id, journal_id, exercice_id, date_piece, numero, libelle, evenement, origine, utilisateur_id)
  VALUES (p_agence, v_j, v_ex, p_date, mf.prochain_numero('piece', p_agence, p_date, 'PC'), 'Provisions sur crédits en souffrance au ' || p_date,
          'provision_creances', 'manuelle', p_utilisateur)
  RETURNING id INTO v_piece;
  FOR r IN SELECT * FROM mf.ecarts_provisions(p_agence, p_date) WHERE delta <> 0 LOOP
    IF r.delta > 0 THEN
      v_ligne := v_ligne + 1; INSERT INTO mf.ecriture(piece_id, ligne, compte_code, debit, credit) VALUES (v_piece, v_ligne, r.dotation, r.delta, 0);
      v_ligne := v_ligne + 1; INSERT INTO mf.ecriture(piece_id, ligne, compte_code, debit, credit) VALUES (v_piece, v_ligne, r.compte, 0, r.delta);
    ELSE
      v_ligne := v_ligne + 1; INSERT INTO mf.ecriture(piece_id, ligne, compte_code, debit, credit) VALUES (v_piece, v_ligne, r.compte, -r.delta, 0);
      v_ligne := v_ligne + 1; INSERT INTO mf.ecriture(piece_id, ligne, compte_code, debit, credit) VALUES (v_piece, v_ligne, r.reprise, 0, -r.delta);
    END IF;
  END LOOP;
  RETURN v_piece;
END $$;

-- ---------------------------------------------------------------------
-- Mode de passage des écritures : « manuel » (bouton de l'écran) ou « automatique » (tâche quotidienne du planificateur,
-- python -m app.cli planifier). Dans les deux cas la même fonction generer_provisions passe la pièce, une fois par jour.
-- ---------------------------------------------------------------------
INSERT INTO parametre(agence_id, cle, valeur, description) VALUES
  (NULL, 'prov_mode', 'manuel', 'passage des écritures de provisions : manuel (bouton) | automatique (tâche quotidienne du planificateur)')
ON CONFLICT DO NOTHING;

-- Tâche du planificateur : ne fait rien en mode manuel ; en mode automatique passe la pièce du jour si un écart existe.
-- Retourne 1 si une pièce a été passée, 0 sinon. Une erreur (ex. aucun exercice ouvert) remonte et est journalisée.
CREATE FUNCTION generer_provisions_auto(p_agence smallint, p_date date) RETURNS integer
LANGUAGE plpgsql AS $$
BEGIN
  IF COALESCE(mf.param('prov_mode', p_agence), 'manuel') <> 'automatique' THEN RETURN 0; END IF;
  IF EXISTS (SELECT 1 FROM mf.piece_comptable WHERE agence_id = p_agence AND date_piece = p_date AND evenement = 'provision_creances') THEN RETURN 0; END IF;
  RETURN CASE WHEN mf.generer_provisions(p_agence, p_date, NULL) IS NULL THEN 0 ELSE 1 END;
END $$;

ALTER TABLE execution_tache DROP CONSTRAINT execution_tache_tache_check;
ALTER TABLE execution_tache ADD CONSTRAINT execution_tache_tache_check CHECK (tache IN
  ('cloturer_cycles_echus','prelever_echeances_compte','maj_statuts_credit','saisir_garantie_echeances','purger_dates','generer_provisions_auto'));
