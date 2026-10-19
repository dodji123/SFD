-- =====================================================================
-- 09_rapports.sql
-- Rapport journalier (global, par agent, par zone) et écrans de crédit (échus, à venir, situation).
-- Règle (brief 3.7) : une date passée doit être reproductible. Tout est donc calculé à partir des
-- DATES MÉTIER des opérations (date de collecte, d'exécution, de paiement, de prélèvement...) et jamais
-- à partir des horodatages système (cree_le) ni des statuts courants.
-- Les trois sorties (écran, PDF, Excel) partent de ces mêmes fonctions : la mise en forme PDF / Excel
-- (un onglet par section) est à faire dans la couche applicative.
-- Dépend de : 00 à 03, 07, 08.
-- =====================================================================
SET search_path = mf, public;

-- Dû restant d'une échéance à une date : capital + intérêts moins les paiements datés au plus tard ce jour.
CREATE FUNCTION du_echeance_a_date(p_echeance integer, p_date date) RETURNS numeric
LANGUAGE sql STABLE AS $$
  SELECT e.capital + e.interet - COALESCE((SELECT sum(p.capital + p.interet) FROM mf.paiement_echeance p
                                            WHERE p.echeance_id = e.id AND p.date_operation <= p_date), 0)
    FROM mf.echeance e WHERE e.id = p_echeance
$$;

-- ---------------------------------------------------------------------
-- Rapport global d'une agence pour un jour : rubrique / valeur.
-- ---------------------------------------------------------------------
CREATE FUNCTION rapport_journalier_global(p_agence smallint, p_date date)
RETURNS TABLE (rubrique text, valeur numeric)
LANGUAGE plpgsql STABLE AS $$
BEGIN
  RETURN QUERY
  SELECT v.r, v.m FROM (VALUES
    -- collecte
    ('collecte_montant'::text, COALESCE((SELECT sum(l.montant_collecte) FROM mf.ligne_collecte l JOIN mf.cycle c ON c.id = l.cycle_id
        WHERE c.agence_id = p_agence AND l.date_collecte = p_date AND l.origine = 'collecte'), 0)::numeric),
    ('collecte_nb_lignes', COALESCE((SELECT count(*) FROM mf.ligne_collecte l JOIN mf.cycle c ON c.id = l.cycle_id
        WHERE c.agence_id = p_agence AND l.date_collecte = p_date AND l.origine = 'collecte'), 0)::numeric),
    ('mises_collectees', COALESCE((SELECT sum(l.mise_appliquee) FROM mf.ligne_collecte l JOIN mf.cycle c ON c.id = l.cycle_id
        WHERE c.agence_id = p_agence AND l.date_collecte = p_date AND l.origine = 'collecte'), 0)::numeric),
    ('virements_epargne_vers_tontine', COALESCE((SELECT sum(l.montant_collecte) FROM mf.ligne_collecte l JOIN mf.cycle c ON c.id = l.cycle_id
        WHERE c.agence_id = p_agence AND l.date_collecte = p_date AND l.origine = 'virement'), 0)::numeric),
    -- versements et écarts de tournée
    ('versements_agents', COALESCE((SELECT sum(montant_verse) FROM mf.versement_agent
        WHERE agence_id = p_agence AND date_tournee = p_date), 0)::numeric),
    ('versements_manquants', COALESCE((SELECT sum(ecart) FROM mf.versement_agent
        WHERE agence_id = p_agence AND date_tournee = p_date AND ecart > 0), 0)::numeric),
    ('versements_surplus', COALESCE((SELECT -sum(ecart) FROM mf.versement_agent
        WHERE agence_id = p_agence AND date_tournee = p_date AND ecart < 0), 0)::numeric),
    -- retraits et virements de cycle exécutés ce jour
    ('retraits_clients', COALESCE((SELECT sum(montant_paye) FROM mf.retrait
        WHERE agence_id = p_agence AND nature = 'retrait_client' AND statut = 'execute' AND date_operation = p_date), 0)::numeric),
    ('virements_tontine_vers_epargne', COALESCE((SELECT sum(montant_paye) FROM mf.retrait
        WHERE agence_id = p_agence AND nature = 'virement_vers_epargne' AND statut = 'execute' AND date_operation = p_date), 0)::numeric),
    ('ecarts_pertes_agents', COALESCE((SELECT sum(montant) FROM mf.compte_agent
        WHERE agence_id = p_agence AND type = 'perte_retrait' AND date_operation = p_date), 0)::numeric),
    ('ecarts_manquants_agents', COALESCE((SELECT sum(montant) FROM mf.compte_agent
        WHERE agence_id = p_agence AND type = 'manquant_versement' AND date_operation = p_date), 0)::numeric),
    ('retenues_sur_commission', COALESCE((SELECT sum(montant) FROM mf.compte_agent
        WHERE agence_id = p_agence AND type = 'retenue_commission' AND date_operation = p_date), 0)::numeric),
    -- épargne classique
    ('epargne_depots', COALESCE((SELECT sum(m.montant) FROM mf.mouvement_epargne m JOIN mf.compte_epargne c ON c.id = m.compte_id
        WHERE c.agence_id = p_agence AND m.type = 'depot' AND m.date_operation = p_date), 0)::numeric),
    ('epargne_retraits', COALESCE((SELECT sum(m.montant) FROM mf.mouvement_epargne m JOIN mf.compte_epargne c ON c.id = m.compte_id
        WHERE c.agence_id = p_agence AND m.type = 'retrait' AND m.date_operation = p_date), 0)::numeric),
    -- crédits
    ('credits_decaisses_nb', COALESCE((SELECT count(*) FROM mf.credit
        WHERE agence_id = p_agence AND date_deblocage = p_date), 0)::numeric),
    ('credits_decaisses_montant', COALESCE((SELECT sum(montant_accorde) FROM mf.credit
        WHERE agence_id = p_agence AND date_deblocage = p_date), 0)::numeric),
    ('remboursements_capital', COALESCE((SELECT sum(p.capital) FROM mf.paiement_echeance p JOIN mf.credit c ON c.id = p.credit_id
        WHERE c.agence_id = p_agence AND p.date_operation = p_date), 0)::numeric),
    ('remboursements_interets', COALESCE((SELECT sum(p.interet) FROM mf.paiement_echeance p JOIN mf.credit c ON c.id = p.credit_id
        WHERE c.agence_id = p_agence AND p.date_operation = p_date), 0)::numeric),
    ('remboursements_penalites', COALESCE((SELECT sum(p.penalite) FROM mf.paiement_echeance p JOIN mf.credit c ON c.id = p.credit_id
        WHERE c.agence_id = p_agence AND p.date_operation = p_date), 0)::numeric),
    ('remboursements_tontine', COALESCE((SELECT sum(p.capital + p.interet + p.penalite) FROM mf.paiement_echeance p JOIN mf.credit c ON c.id = p.credit_id
        WHERE c.agence_id = p_agence AND p.date_operation = p_date AND p.source = 'tontine'), 0)::numeric),
    ('remboursements_prelevement', COALESCE((SELECT sum(p.capital + p.interet + p.penalite) FROM mf.paiement_echeance p JOIN mf.credit c ON c.id = p.credit_id
        WHERE c.agence_id = p_agence AND p.date_operation = p_date AND p.source = 'prelevement'), 0)::numeric),
    ('remboursements_especes', COALESCE((SELECT sum(p.capital + p.interet + p.penalite) FROM mf.paiement_echeance p JOIN mf.credit c ON c.id = p.credit_id
        WHERE c.agence_id = p_agence AND p.date_operation = p_date AND p.source = 'especes'), 0)::numeric),
    ('saisies_garantie', COALESCE((SELECT sum(p.capital + p.interet + p.penalite) FROM mf.paiement_echeance p JOIN mf.credit c ON c.id = p.credit_id
        WHERE c.agence_id = p_agence AND p.date_operation = p_date AND p.source = 'saisie_garantie'), 0)::numeric),
    -- échéances échues (avant ce jour, impayées à cette date) et à venir (7 jours)
    ('echeances_echues_nb', COALESCE((SELECT count(*) FROM mf.echeance e JOIN mf.credit c ON c.id = e.credit_id
        WHERE c.agence_id = p_agence AND e.date_prevue < p_date AND mf.du_echeance_a_date(e.id, p_date) > 0), 0)::numeric),
    ('echeances_echues_montant', COALESCE((SELECT sum(mf.du_echeance_a_date(e.id, p_date)) FROM mf.echeance e JOIN mf.credit c ON c.id = e.credit_id
        WHERE c.agence_id = p_agence AND e.date_prevue < p_date AND mf.du_echeance_a_date(e.id, p_date) > 0), 0)::numeric),
    ('echeances_a_venir_nb', COALESCE((SELECT count(*) FROM mf.echeance e JOIN mf.credit c ON c.id = e.credit_id
        WHERE c.agence_id = p_agence AND e.date_prevue BETWEEN p_date AND p_date + 7 AND mf.du_echeance_a_date(e.id, p_date) > 0), 0)::numeric),
    ('echeances_a_venir_montant', COALESCE((SELECT sum(mf.du_echeance_a_date(e.id, p_date)) FROM mf.echeance e JOIN mf.credit c ON c.id = e.credit_id
        WHERE c.agence_id = p_agence AND e.date_prevue BETWEEN p_date AND p_date + 7 AND mf.du_echeance_a_date(e.id, p_date) > 0), 0)::numeric),
    -- fidélité
    ('points_fidelite', COALESCE((SELECT sum(p.points) FROM mf.points_fidelite p JOIN mf.client cl ON cl.id = p.client_id
        WHERE cl.agence_id = p_agence AND p.date_operation = p_date), 0)::numeric),
    -- caisse
    ('caisse_encaissements', COALESCE((SELECT sum(o.montant) FROM mf.operation_caisse o
        JOIN mf.session_caisse s ON s.id = o.session_id JOIN mf.caisse k ON k.id = s.caisse_id
        WHERE k.agence_id = p_agence AND o.type = 'encaissement' AND o.date_operation = p_date), 0)::numeric),
    ('caisse_decaissements', COALESCE((SELECT sum(o.montant) FROM mf.operation_caisse o
        JOIN mf.session_caisse s ON s.id = o.session_id JOIN mf.caisse k ON k.id = s.caisse_id
        WHERE k.agence_id = p_agence AND o.type = 'decaissement' AND o.date_operation = p_date), 0)::numeric),
    -- cycles
    ('cycles_clotures', COALESCE((SELECT count(*) FROM mf.cycle WHERE agence_id = p_agence AND date_cloture = p_date), 0)::numeric)
  ) AS v(r, m);
END $$;

-- ---------------------------------------------------------------------
-- Rapport par agent
-- ---------------------------------------------------------------------
CREATE FUNCTION rapport_journalier_agent(p_agence smallint, p_date date)
RETURNS TABLE (agent text, montant_collecte numeric, mises numeric, nb_lignes bigint,
               montant_verse numeric, ecart_versement numeric, pertes_retrait numeric)
LANGUAGE sql STABLE AS $$
  SELECT a.nom::text,
         COALESCE((SELECT sum(l.montant_collecte) FROM mf.ligne_collecte l
                    WHERE l.agent_id = a.id AND l.date_collecte = p_date AND l.origine = 'collecte'), 0)::numeric,
         COALESCE((SELECT sum(l.mise_appliquee) FROM mf.ligne_collecte l
                    WHERE l.agent_id = a.id AND l.date_collecte = p_date AND l.origine = 'collecte'), 0)::numeric,
         (SELECT count(*) FROM mf.ligne_collecte l
           WHERE l.agent_id = a.id AND l.date_collecte = p_date AND l.origine = 'collecte'),
         COALESCE((SELECT v.montant_verse FROM mf.versement_agent v WHERE v.agent_id = a.id AND v.date_tournee = p_date), 0)::numeric,
         COALESCE((SELECT v.ecart FROM mf.versement_agent v WHERE v.agent_id = a.id AND v.date_tournee = p_date), 0)::numeric,
         COALESCE((SELECT sum(c.montant) FROM mf.compte_agent c
                    WHERE c.agent_id = a.id AND c.type = 'perte_retrait' AND c.date_operation = p_date), 0)::numeric
    FROM mf.agent a WHERE a.agence_id = p_agence
   ORDER BY a.matricule
$$;

-- ---------------------------------------------------------------------
-- Rapport par zone : collecte, retraits, remboursements et écarts de retrait
-- ---------------------------------------------------------------------
CREATE FUNCTION rapport_journalier_zone(p_agence smallint, p_date date)
RETURNS TABLE (zone text, collectrice text, montant_collecte numeric, mises numeric, nb_lignes bigint,
               retraits numeric, remboursements numeric, ecarts_retrait numeric)
LANGUAGE sql STABLE AS $$
  SELECT z.code::text,
         (SELECT k.nom FROM mf.affectation_zone a JOIN mf.collectrice k ON k.id = a.collectrice_id
           WHERE a.zone_id = z.id AND p_date >= a.date_debut AND (a.date_fin IS NULL OR p_date <= a.date_fin) LIMIT 1)::text,
         COALESCE((SELECT sum(l.montant_collecte) FROM mf.ligne_collecte l JOIN mf.cycle c ON c.id = l.cycle_id
                    JOIN mf.client cl ON cl.id = c.client_id
                    WHERE cl.zone_id = z.id AND l.date_collecte = p_date AND l.origine = 'collecte'), 0)::numeric,
         COALESCE((SELECT sum(l.mise_appliquee) FROM mf.ligne_collecte l JOIN mf.cycle c ON c.id = l.cycle_id
                    JOIN mf.client cl ON cl.id = c.client_id
                    WHERE cl.zone_id = z.id AND l.date_collecte = p_date AND l.origine = 'collecte'), 0)::numeric,
         (SELECT count(*) FROM mf.ligne_collecte l JOIN mf.cycle c ON c.id = l.cycle_id
            JOIN mf.client cl ON cl.id = c.client_id
           WHERE cl.zone_id = z.id AND l.date_collecte = p_date AND l.origine = 'collecte'),
         COALESCE((SELECT sum(r.montant_paye) FROM mf.retrait r JOIN mf.cycle c ON c.id = r.cycle_id
                    JOIN mf.client cl ON cl.id = c.client_id
                    WHERE cl.zone_id = z.id AND r.statut = 'execute' AND r.date_operation = p_date
                      AND r.nature IN ('retrait_client','virement_vers_epargne')), 0)::numeric,
         COALESCE((SELECT sum(p.capital + p.interet + p.penalite) FROM mf.paiement_echeance p JOIN mf.credit cr ON cr.id = p.credit_id
                    JOIN mf.client cl ON cl.id = cr.client_id
                    WHERE cl.zone_id = z.id AND p.date_operation = p_date), 0)::numeric,
         COALESCE((SELECT sum(d.perte) FROM mf.ecart_retrait_date d JOIN mf.ecart_retrait e ON e.id = d.ecart_id
                    JOIN mf.cycle c ON c.id = e.cycle_id JOIN mf.client cl ON cl.id = c.client_id
                    WHERE cl.zone_id = z.id AND e.traite_le = p_date), 0)::numeric
    FROM mf.zone z WHERE z.agence_id = p_agence
   ORDER BY z.code
$$;

-- ---------------------------------------------------------------------
-- Écrans de crédit
-- ---------------------------------------------------------------------
-- Remboursements échus : échéance dépassée et impayée à cette date.
CREATE FUNCTION remboursements_echus(p_agence smallint, p_date date)
RETURNS TABLE (credit text, client text, no_echeance smallint, date_prevue date, jours_retard integer,
               du numeric, penalite numeric)
LANGUAGE sql STABLE AS $$
  SELECT c.numero::text, cl.nom::text, e.no_echeance, e.date_prevue, (p_date - e.date_prevue)::integer,
         mf.du_echeance_a_date(e.id, p_date),
         mf.calcul_penalite(e.capital, e.capital + e.interet, p_date - e.date_prevue, c.agence_id)
    FROM mf.echeance e JOIN mf.credit c ON c.id = e.credit_id JOIN mf.client cl ON cl.id = c.client_id
   WHERE c.agence_id = p_agence AND e.date_prevue < p_date AND mf.du_echeance_a_date(e.id, p_date) > 0
   ORDER BY e.date_prevue, c.numero, e.no_echeance
$$;

-- Remboursements à venir dans les p_jours jours (jour même inclus).
CREATE FUNCTION remboursements_a_venir(p_agence smallint, p_date date, p_jours integer DEFAULT 7)
RETURNS TABLE (credit text, client text, no_echeance smallint, date_prevue date, du numeric, mode_remboursement text)
LANGUAGE sql STABLE AS $$
  SELECT c.numero::text, cl.nom::text, e.no_echeance, e.date_prevue, mf.du_echeance_a_date(e.id, p_date), c.mode_remboursement::text
    FROM mf.echeance e JOIN mf.credit c ON c.id = e.credit_id JOIN mf.client cl ON cl.id = c.client_id
   WHERE c.agence_id = p_agence AND e.date_prevue BETWEEN p_date AND p_date + p_jours
     AND mf.du_echeance_a_date(e.id, p_date) > 0
   ORDER BY e.date_prevue, c.numero, e.no_echeance
$$;

-- Situation des crédits à une date : capital restant, prochaine échéance, garantie encore bloquée, statut à la date.
CREATE FUNCTION situation_credits(p_agence smallint, p_date date)
RETURNS TABLE (credit text, client text, type text, mode_remboursement text, montant_accorde numeric,
               capital_restant numeric, echeances_restantes bigint, prochaine_echeance date,
               garantie_bloquee numeric, statut_a_date text)
LANGUAGE sql STABLE AS $$
  SELECT c.numero::text, cl.nom::text, c.type::text, c.mode_remboursement::text, c.montant_accorde,
         c.montant_accorde - COALESCE((SELECT sum(p.capital) FROM mf.paiement_echeance p
                                        WHERE p.credit_id = c.id AND p.date_operation <= p_date), 0),
         (SELECT count(*) FROM mf.echeance e WHERE e.credit_id = c.id AND mf.du_echeance_a_date(e.id, p_date) > 0),
         (SELECT min(e.date_prevue) FROM mf.echeance e WHERE e.credit_id = c.id AND mf.du_echeance_a_date(e.id, p_date) > 0),
         CASE WHEN g.id IS NULL OR (g.libere_le IS NOT NULL AND g.libere_le <= p_date) THEN 0
              ELSE g.montant_bloque - COALESCE((SELECT sum(p.capital + p.interet + p.penalite) FROM mf.paiement_echeance p
                                                 WHERE p.credit_id = c.id AND p.source = 'saisie_garantie'
                                                   AND p.date_operation <= p_date), 0) END,
         CASE WHEN c.date_solde IS NOT NULL AND c.date_solde <= p_date THEN 'solde'
              WHEN EXISTS (SELECT 1 FROM mf.echeance e WHERE e.credit_id = c.id AND e.date_prevue < p_date
                              AND mf.du_echeance_a_date(e.id, p_date) > 0) THEN 'en_retard'
              ELSE 'en_cours' END
    FROM mf.credit c JOIN mf.client cl ON cl.id = c.client_id
    LEFT JOIN mf.garantie_compte g ON g.credit_id = c.id
   WHERE c.agence_id = p_agence AND c.date_deblocage <= p_date
   ORDER BY c.numero
$$;
