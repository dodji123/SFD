-- =====================================================================
-- 14_rapports_credit_financier.sql
-- Rapports de crédit (portefeuille, portefeuille à risque, retard par tranche, activité d'une période) et rapport
-- financier (compte d'exploitation opérationnel + bilan simplifié issu de la comptabilité).
-- Comme 09_rapports.sql : tout est calculé à partir des DATES MÉTIER, donc reproductible pour une date passée.
-- Lecture seule : aucune table. Dépend de : 03, 04, 05, 08, 09, 13.
-- =====================================================================
SET search_path = mf, public;

-- ---------------------------------------------------------------------
-- Portefeuille à une date : crédits débloqués au plus tard ce jour et non soldés à cette date.
-- jours_retard = ancienneté de l'échéance impayée la plus ancienne (capital + intérêts impayés à cette date).
-- ---------------------------------------------------------------------
CREATE FUNCTION portefeuille_a_date(p_agence smallint, p_date date)
RETURNS TABLE (credit_id integer, numero text, client_id integer, client text, type text, mode_remboursement text,
               produit text, montant_accorde numeric, capital_restant numeric, jours_retard integer,
               nb_echeances_en_retard integer, montant_en_retard numeric, garantie_bloquee numeric)
LANGUAGE sql STABLE AS $$
  SELECT c.id, c.numero::text, c.client_id, cl.nom::text, c.type::text, c.mode_remboursement::text,
         COALESCE(pr.code, '—')::text, c.montant_accorde,
         c.montant_accorde - COALESCE((SELECT sum(p.capital) FROM mf.paiement_echeance p
                                        WHERE p.credit_id = c.id AND p.date_operation <= p_date), 0),
         COALESCE(r.jours, 0), COALESCE(r.nb, 0), COALESCE(r.montant, 0),
         CASE WHEN g.id IS NULL OR (g.libere_le IS NOT NULL AND g.libere_le <= p_date) THEN 0
              ELSE g.montant_bloque - COALESCE((SELECT sum(p.capital + p.interet + p.penalite) FROM mf.paiement_echeance p
                                                  WHERE p.credit_id = c.id AND p.source = 'saisie_garantie'
                                                    AND p.date_operation <= p_date), 0) END
    FROM mf.credit c
    JOIN mf.client cl ON cl.id = c.client_id
    LEFT JOIN mf.demande_credit d ON d.credit_id = c.id
    LEFT JOIN mf.produit_credit_epargne pr ON pr.id = d.produit_id
    LEFT JOIN mf.garantie_compte g ON g.credit_id = c.id
    LEFT JOIN LATERAL (
        SELECT max(p_date - e.date_prevue)::integer AS jours, count(*)::integer AS nb, sum(x.du) AS montant
          FROM mf.echeance e
          CROSS JOIN LATERAL (SELECT mf.du_echeance_a_date(e.id, p_date) AS du) x
         WHERE e.credit_id = c.id AND e.date_prevue < p_date AND x.du > 0) r ON true
   WHERE c.agence_id = p_agence AND c.date_deblocage <= p_date AND (c.date_solde IS NULL OR c.date_solde > p_date)
$$;

-- Indicateurs du portefeuille. PAR n = capital restant des crédits dont l'impayé le plus ancien dépasse n jours.
CREATE FUNCTION rapport_portefeuille(p_agence smallint, p_date date)
RETURNS TABLE (rubrique text, valeur numeric)
LANGUAGE plpgsql STABLE AS $$
DECLARE v_enc numeric; v_nb integer; v_par1 numeric; v_par30 numeric; v_par60 numeric; v_par90 numeric;
BEGIN
  SELECT COALESCE(sum(capital_restant), 0), count(*),
         COALESCE(sum(capital_restant) FILTER (WHERE jours_retard >= 1), 0),
         COALESCE(sum(capital_restant) FILTER (WHERE jours_retard > 30), 0),
         COALESCE(sum(capital_restant) FILTER (WHERE jours_retard > 60), 0),
         COALESCE(sum(capital_restant) FILTER (WHERE jours_retard > 90), 0)
    INTO v_enc, v_nb, v_par1, v_par30, v_par60, v_par90
    FROM mf.portefeuille_a_date(p_agence, p_date);
  RETURN QUERY VALUES
    ('credits_actifs'::text, v_nb::numeric),
    ('encours_capital', v_enc),
    ('credits_en_retard', COALESCE((SELECT count(*) FROM mf.portefeuille_a_date(p_agence, p_date) WHERE jours_retard >= 1), 0)::numeric),
    ('impaye_capital_interets', COALESCE((SELECT sum(montant_en_retard) FROM mf.portefeuille_a_date(p_agence, p_date)), 0)),
    ('par_1_jour', v_par1), ('par_30_jours', v_par30), ('par_60_jours', v_par60), ('par_90_jours', v_par90),
    ('par_1_jour_pct', CASE WHEN v_enc > 0 THEN round(v_par1 * 100 / v_enc, 2) END),
    ('par_30_jours_pct', CASE WHEN v_enc > 0 THEN round(v_par30 * 100 / v_enc, 2) END),
    ('par_60_jours_pct', CASE WHEN v_enc > 0 THEN round(v_par60 * 100 / v_enc, 2) END),
    ('par_90_jours_pct', CASE WHEN v_enc > 0 THEN round(v_par90 * 100 / v_enc, 2) END),
    ('garanties_bloquees', COALESCE((SELECT sum(garantie_bloquee) FROM mf.portefeuille_a_date(p_agence, p_date)), 0)),
    ('credits_soldes_a_ce_jour', COALESCE((SELECT count(*) FROM mf.credit WHERE agence_id = p_agence AND date_solde IS NOT NULL AND date_solde <= p_date), 0)::numeric);
END $$;

-- Retard par tranche d'ancienneté de l'impayé.
CREATE FUNCTION rapport_retard_par_tranche(p_agence smallint, p_date date)
RETURNS TABLE (ordre integer, tranche text, nb_credits bigint, capital_restant numeric, montant_en_retard numeric)
LANGUAGE sql STABLE AS $$
  WITH p AS (SELECT * FROM mf.portefeuille_a_date(p_agence, p_date)),
       t(ordre, tranche, bas, haut) AS (VALUES
         (1, 'À jour', 0, 0), (2, '1 à 30 jours', 1, 30), (3, '31 à 60 jours', 31, 60),
         (4, '61 à 90 jours', 61, 90), (5, '91 à 180 jours', 91, 180), (6, 'Plus de 180 jours', 181, 1000000))
  SELECT t.ordre, t.tranche, count(p.credit_id), COALESCE(sum(p.capital_restant), 0), COALESCE(sum(p.montant_en_retard), 0)
    FROM t LEFT JOIN p ON p.jours_retard BETWEEN t.bas AND t.haut
   GROUP BY t.ordre, t.tranche ORDER BY t.ordre
$$;

-- Répartition de l'encours selon un critère : 'type', 'mode' ou 'produit'.
CREATE FUNCTION portefeuille_repartition(p_agence smallint, p_date date, p_critere text)
RETURNS TABLE (cle text, nb_credits bigint, encours numeric, encours_en_retard numeric)
LANGUAGE plpgsql STABLE AS $$
BEGIN
  IF p_critere NOT IN ('type','mode','produit') THEN RAISE EXCEPTION 'critère inconnu : % (type, mode, produit)', p_critere; END IF;
  RETURN QUERY
  SELECT CASE p_critere WHEN 'type' THEN p.type WHEN 'mode' THEN p.mode_remboursement ELSE p.produit END,
         count(*), COALESCE(sum(p.capital_restant), 0), COALESCE(sum(p.capital_restant) FILTER (WHERE p.jours_retard >= 1), 0)
    FROM mf.portefeuille_a_date(p_agence, p_date) p
   GROUP BY 1 ORDER BY 3 DESC;
END $$;

-- Activité de crédit sur une période : décaissements, recouvrement, soldés.
-- taux_recouvrement_pct = part du capital et des intérêts des échéances tombées dans la période qui est payée à la fin de la période.
CREATE FUNCTION rapport_credits_periode(p_agence smallint, p_du date, p_au date)
RETURNS TABLE (rubrique text, valeur numeric)
LANGUAGE plpgsql STABLE AS $$
DECLARE v_du_attendu numeric; v_recouvre numeric;
BEGIN
  SELECT COALESCE(sum(e.capital + e.interet), 0),
         COALESCE(sum(LEAST(e.capital + e.interet,
                            (SELECT COALESCE(sum(p.capital + p.interet), 0) FROM mf.paiement_echeance p
                              WHERE p.echeance_id = e.id AND p.date_operation <= p_au))), 0)
    INTO v_du_attendu, v_recouvre
    FROM mf.echeance e JOIN mf.credit c ON c.id = e.credit_id
   WHERE c.agence_id = p_agence AND e.date_prevue BETWEEN p_du AND p_au;
  RETURN QUERY VALUES
    ('credits_debloques_nb'::text, COALESCE((SELECT count(*) FROM mf.credit WHERE agence_id = p_agence AND date_deblocage BETWEEN p_du AND p_au), 0)::numeric),
    ('credits_debloques_montant', COALESCE((SELECT sum(montant_accorde) FROM mf.credit WHERE agence_id = p_agence AND date_deblocage BETWEEN p_du AND p_au), 0)),
    ('frais_de_dossier', COALESCE((SELECT sum(frais_dossier) FROM mf.credit WHERE agence_id = p_agence AND date_deblocage BETWEEN p_du AND p_au), 0)),
    ('remboursements_capital', COALESCE((SELECT sum(p.capital) FROM mf.paiement_echeance p JOIN mf.credit c ON c.id = p.credit_id
        WHERE c.agence_id = p_agence AND p.date_operation BETWEEN p_du AND p_au), 0)),
    ('remboursements_interets', COALESCE((SELECT sum(p.interet) FROM mf.paiement_echeance p JOIN mf.credit c ON c.id = p.credit_id
        WHERE c.agence_id = p_agence AND p.date_operation BETWEEN p_du AND p_au), 0)),
    ('remboursements_penalites', COALESCE((SELECT sum(p.penalite) FROM mf.paiement_echeance p JOIN mf.credit c ON c.id = p.credit_id
        WHERE c.agence_id = p_agence AND p.date_operation BETWEEN p_du AND p_au), 0)),
    ('remboursements_par_tontine', COALESCE((SELECT sum(p.capital + p.interet + p.penalite) FROM mf.paiement_echeance p JOIN mf.credit c ON c.id = p.credit_id
        WHERE c.agence_id = p_agence AND p.date_operation BETWEEN p_du AND p_au AND p.source = 'tontine'), 0)),
    ('remboursements_par_prelevement', COALESCE((SELECT sum(p.capital + p.interet + p.penalite) FROM mf.paiement_echeance p JOIN mf.credit c ON c.id = p.credit_id
        WHERE c.agence_id = p_agence AND p.date_operation BETWEEN p_du AND p_au AND p.source = 'prelevement'), 0)),
    ('remboursements_en_especes', COALESCE((SELECT sum(p.capital + p.interet + p.penalite) FROM mf.paiement_echeance p JOIN mf.credit c ON c.id = p.credit_id
        WHERE c.agence_id = p_agence AND p.date_operation BETWEEN p_du AND p_au AND p.source = 'especes'), 0)),
    ('garanties_saisies', COALESCE((SELECT sum(p.capital + p.interet + p.penalite) FROM mf.paiement_echeance p JOIN mf.credit c ON c.id = p.credit_id
        WHERE c.agence_id = p_agence AND p.date_operation BETWEEN p_du AND p_au AND p.source = 'saisie_garantie'), 0)),
    ('credits_soldes', COALESCE((SELECT count(*) FROM mf.credit WHERE agence_id = p_agence AND date_solde BETWEEN p_du AND p_au), 0)::numeric),
    ('echeances_attendues', v_du_attendu),
    ('echeances_recouvrees', v_recouvre),
    ('taux_recouvrement_pct', CASE WHEN v_du_attendu > 0 THEN round(v_recouvre * 100 / v_du_attendu, 1) END);
END $$;

-- ---------------------------------------------------------------------
-- Rapport financier : compte d'exploitation OPÉRATIONNEL d'une période, calculé à partir des opérations
-- (donc disponible même sans comptabilisation automatique). Ce n'est pas un état réglementaire.
--   produits : intérêts, pénalités, frais de dossier, mises de tontine retenues à l'exécution des retraits,
--              excédents de caisse, intérêts bancaires ;
--   charges  : commissions brutes des collectrices, salaires et charges patronales des bulletins validés,
--              manquants de caisse, frais bancaires.
-- Non modélisés : intérêts servis sur l'épargne, provisions, amortissements. Les créances sur les agents
-- (manquants, pertes) ne sont pas des charges tant qu'elles ne sont pas passées en perte : elles figurent en information.
-- ---------------------------------------------------------------------
CREATE FUNCTION rapport_financier(p_agence smallint, p_du date, p_au date)
RETURNS TABLE (section text, rubrique text, libelle text, valeur numeric)
LANGUAGE sql STABLE AS $$
  WITH base(ordre, section, rubrique, libelle, valeur) AS (VALUES
    (1, 'produit', 'interets_credits', 'Intérêts sur crédits',
       COALESCE((SELECT sum(p.interet) FROM mf.paiement_echeance p JOIN mf.credit c ON c.id = p.credit_id
                  WHERE c.agence_id = p_agence AND p.date_operation BETWEEN p_du AND p_au), 0)::numeric),
    (2, 'produit', 'penalites', 'Pénalités de retard',
       COALESCE((SELECT sum(p.penalite) FROM mf.paiement_echeance p JOIN mf.credit c ON c.id = p.credit_id
                  WHERE c.agence_id = p_agence AND p.date_operation BETWEEN p_du AND p_au), 0)::numeric),
    (3, 'produit', 'frais_dossier', 'Frais de dossier',
       COALESCE((SELECT sum(frais_dossier) FROM mf.credit WHERE agence_id = p_agence AND date_deblocage BETWEEN p_du AND p_au), 0)::numeric),
    (4, 'produit', 'mises_tontine', 'Mises de tontine retenues (commission de collecte)',
       COALESCE((SELECT sum(COALESCE(cy.mise_finale, cy.mise_courante)) FROM mf.retrait r JOIN mf.cycle cy ON cy.id = r.cycle_id
                  WHERE r.agence_id = p_agence AND r.statut = 'execute' AND r.nature IN ('retrait_client','virement_vers_epargne')
                    AND r.date_operation BETWEEN p_du AND p_au), 0)::numeric),
    (5, 'produit', 'excedents_caisse', 'Excédents de caisse',
       COALESCE((SELECT sum(s.ecart_fermeture) FROM mf.session_caisse s JOIN mf.caisse k ON k.id = s.caisse_id
                  WHERE k.agence_id = p_agence AND s.date_session BETWEEN p_du AND p_au AND s.ecart_fermeture > 0), 0)::numeric),
    (6, 'produit', 'interets_bancaires', 'Intérêts bancaires',
       COALESCE((SELECT sum(m.montant) FROM mf.mouvement_banque m JOIN mf.compte_banque b ON b.id = m.compte_banque_id
                  WHERE b.agence_id = p_agence AND m.type = 'interets' AND m.date_operation BETWEEN p_du AND p_au), 0)::numeric),
    (7, 'charge', 'commissions_collectrices', 'Commissions des collectrices (brutes)',
       COALESCE((SELECT sum(commission_brute) FROM mf.commission_collectrice
                  WHERE agence_id = p_agence AND periode_fin BETWEEN p_du AND p_au), 0)::numeric),
    (8, 'charge', 'salaires', 'Salaires bruts (bulletins validés)',
       COALESCE((SELECT sum(brut) FROM mf.bulletin_paie WHERE agence_id = p_agence AND statut IN ('valide','paye')
                  AND periode BETWEEN date_trunc('month', p_du)::date AND p_au), 0)::numeric),
    (9, 'charge', 'charges_patronales', 'Charges patronales',
       COALESCE((SELECT sum(charges_patronales) FROM mf.bulletin_paie WHERE agence_id = p_agence AND statut IN ('valide','paye')
                  AND periode BETWEEN date_trunc('month', p_du)::date AND p_au), 0)::numeric),
    (10, 'charge', 'manquants_caisse', 'Manquants de caisse',
       COALESCE((SELECT -sum(s.ecart_fermeture) FROM mf.session_caisse s JOIN mf.caisse k ON k.id = s.caisse_id
                  WHERE k.agence_id = p_agence AND s.date_session BETWEEN p_du AND p_au AND s.ecart_fermeture < 0), 0)::numeric),
    (11, 'charge', 'frais_bancaires', 'Frais bancaires',
       COALESCE((SELECT sum(m.montant) FROM mf.mouvement_banque m JOIN mf.compte_banque b ON b.id = m.compte_banque_id
                  WHERE b.agence_id = p_agence AND m.type = 'frais' AND m.date_operation BETWEEN p_du AND p_au), 0)::numeric)
  ), tot AS (
    SELECT COALESCE(sum(valeur) FILTER (WHERE section = 'produit'), 0) AS prod,
           COALESCE(sum(valeur) FILTER (WHERE section = 'charge'), 0) AS charges FROM base
  )
  SELECT x.section, x.rubrique, x.libelle, x.valeur FROM (
    SELECT ordre, section, rubrique, libelle, valeur FROM base
    UNION ALL SELECT 20, 'resultat', 'total_produits', 'Total des produits', prod FROM tot
    UNION ALL SELECT 21, 'resultat', 'total_charges', 'Total des charges', charges FROM tot
    UNION ALL SELECT 22, 'resultat', 'resultat', 'Résultat de la période', prod - charges FROM tot
    UNION ALL SELECT 30, 'info', 'encours_credits', 'Encours de crédits en fin de période',
         COALESCE((SELECT sum(capital_restant) FROM mf.portefeuille_a_date(p_agence, p_au)), 0)::numeric
    UNION ALL SELECT 31, 'info', 'creances_agents', 'Créances sur les agents (manquants et pertes non recouvrés)',
         COALESCE((SELECT sum(-solde) FROM mf.v_solde_compte_agent WHERE agence_id = p_agence AND solde < 0), 0)::numeric
    UNION ALL SELECT 32, 'info', 'ratio_charges_produits_pct', 'Charges / produits (%)',
         CASE WHEN prod > 0 THEN round(charges * 100 / prod, 1) END FROM tot
  ) x ORDER BY x.ordre
$$;

-- ---------------------------------------------------------------------
-- Bilan simplifié issu de la comptabilité (écritures jusqu'à p_au), par compte de niveau 2 :
-- le solde de chaque compte imputable va à l'actif s'il est débiteur, au passif s'il est créditeur ;
-- les classes 6 et 7 sont résumées en « résultat » ; la classe 9 (hors bilan) est ignorée.
-- Document de travail : ce n'est pas l'état de synthèse réglementaire.
-- ---------------------------------------------------------------------
CREATE FUNCTION bilan_simplifie(p_agence smallint, p_au date)
RETURNS TABLE (cote text, classe char, code varchar, libelle text, montant numeric)
LANGUAGE sql STABLE AS $$
  WITH soldes AS (
    SELECT c.code, c.classe, sum(e.debit - e.credit) AS solde
      FROM mf.ecriture e
      JOIN mf.piece_comptable p ON p.id = e.piece_id
      JOIN mf.compte_comptable c ON c.code = e.compte_code
     WHERE (p_agence IS NULL OR p.agence_id = p_agence) AND p.date_piece <= p_au AND c.classe NOT IN ('6','7','9')
     GROUP BY c.code, c.classe
  ), n2 AS (
    SELECT CASE WHEN solde > 0 THEN 'actif' ELSE 'passif' END AS cote, s.classe, left(s.code, 2) AS code, abs(sum(solde)) AS montant
      FROM soldes s WHERE solde <> 0 GROUP BY 1, 2, 3
  ), res AS (
    SELECT COALESCE(sum(e.credit - e.debit), 0) AS r
      FROM mf.ecriture e JOIN mf.piece_comptable p ON p.id = e.piece_id JOIN mf.compte_comptable c ON c.code = e.compte_code
     WHERE c.classe IN ('6','7') AND (p_agence IS NULL OR p.agence_id = p_agence) AND p.date_piece <= p_au
  )
  SELECT n2.cote, n2.classe, n2.code::varchar, COALESCE(pc.libelle, n2.code), n2.montant
    FROM n2 LEFT JOIN mf.compte_comptable pc ON pc.code = n2.code
  UNION ALL
  SELECT CASE WHEN r >= 0 THEN 'passif' ELSE 'actif' END, '7'::char, 'RES'::varchar, 'Résultat de l''exercice', abs(r) FROM res WHERE r <> 0
  ORDER BY 1, 3
$$;
