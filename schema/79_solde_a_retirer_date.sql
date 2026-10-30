-- =====================================================================
-- 79_solde_a_retirer_date.sql
-- Soldes que les clients pouvaient retirer à une date donnée (rapport par produit, client et cycle).
--   * solde à la date D = collecte jusqu'à D (lignes de collecte datées ≤ D) - mise du cycle - retraits clients
--     et virements vers l'épargne datés ≤ D et non annulés ;
--   * ne retiennent que les cycles ouverts à D (date_debut ≤ D) et dont le solde à D est positif ;
--   * approximation : la mise prise est la mise du cycle (pas l'historique des changements de mise).
-- Dépend de : 01 (cycle, ligne_collecte), 03 (retrait), 75 (rapport courant, même forme de sortie).
-- =====================================================================
SET search_path = mf, public;

CREATE FUNCTION rapport_solde_a_retirer_date(p_agence smallint, p_date date, p_produit integer DEFAULT NULL)
RETURNS TABLE (produit_code text, produit_libelle text, client_numero text, client text, zone text,
               cycle text, statut text, date_fin date, solde numeric)
LANGUAGE sql STABLE AS $$
  SELECT pe.code::text, pe.libelle::text, cl.numero::text, cl.nom::text, z.libelle::text,
         c.numero::text, c.statut::text, c.date_fin, x.solde
    FROM (
      SELECT c.id,
             COALESCE((SELECT sum(l.montant_collecte) FROM mf.ligne_collecte l
                        WHERE l.cycle_id = c.id AND l.date_collecte <= p_date), 0)
             - COALESCE(c.mise_finale, c.mise_courante)
             - COALESCE((SELECT sum(r.montant) FROM mf.retrait r
                          WHERE r.cycle_id = c.id AND r.statut <> 'annule'
                            AND r.nature IN ('retrait_client','virement_vers_epargne')
                            AND r.date_demande <= p_date), 0) AS solde
        FROM mf.cycle c
       WHERE c.agence_id = p_agence
         AND c.date_debut <= p_date
    ) x
    JOIN mf.cycle c ON c.id = x.id
    JOIN mf.client cl ON cl.id = c.client_id
    JOIN mf.produit_epargne pe ON pe.id = c.produit_id
    LEFT JOIN mf.zone z ON z.id = cl.zone_id
   WHERE x.solde > 0
     AND (p_produit IS NULL OR pe.id = p_produit)
   ORDER BY pe.code, cl.nom, c.numero;
$$;
