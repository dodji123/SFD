-- =====================================================================
-- 71_rapport_manquants.sql
-- Rapport des manquants non payés, par agent, sur une période libre (du / au).
--   * manquants : débits « manquant_versement » de la période (versement inférieur à la collecte) ;
--   * pertes : débits « perte_retrait » de la période (écart de retrait non couvert par un surplus) ;
--   * autres débits : corrections de la période ;
--   * recouvré : versements, retenues sur commission et corrections créditrices de la période ;
--   * reste dû : ce que l'agent doit encore à la fin de la période (solde cumulé jusqu'à p_au).
-- Ne sont listés que les agents ayant une opération débitrice sur la période ou une dette à la fin de la période.
-- Dépend de : 02 (compte_agent, sens_compte_agent).
-- =====================================================================
SET search_path = mf, public;

CREATE FUNCTION rapport_manquants(p_agence smallint, p_du date, p_au date)
RETURNS TABLE (agent_id integer, matricule text, nom text,
               manquants numeric, pertes numeric, autres_debits numeric, recouvre numeric, reste_du numeric)
LANGUAGE sql STABLE AS $$
  WITH s AS (
    SELECT a.id AS agent_id, a.matricule::text AS matricule, a.nom::text AS nom,
           COALESCE(sum(c.montant) FILTER (WHERE c.type = 'manquant_versement' AND c.date_operation BETWEEN p_du AND p_au), 0) AS manquants,
           COALESCE(sum(c.montant) FILTER (WHERE c.type = 'perte_retrait'      AND c.date_operation BETWEEN p_du AND p_au), 0) AS pertes,
           COALESCE(sum(c.montant) FILTER (WHERE c.type = 'correction_debit'   AND c.date_operation BETWEEN p_du AND p_au), 0) AS autres_debits,
           COALESCE(sum(c.montant) FILTER (WHERE c.type IN ('versement','retenue_commission','correction_credit')
                                             AND c.date_operation BETWEEN p_du AND p_au), 0) AS recouvre,
           GREATEST(-COALESCE(sum(c.montant * mf.sens_compte_agent(c.type)) FILTER (WHERE c.date_operation <= p_au), 0), 0) AS reste_du
      FROM mf.agent a LEFT JOIN mf.compte_agent c ON c.agent_id = a.id
     WHERE a.agence_id = p_agence
     GROUP BY a.id, a.matricule, a.nom
  )
  SELECT * FROM s
   WHERE manquants + pertes + autres_debits > 0 OR reste_du > 0
   ORDER BY nom;
$$;
