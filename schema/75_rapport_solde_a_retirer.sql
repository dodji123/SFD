-- =====================================================================
-- 75_rapport_solde_a_retirer.sql
-- Rapport des soldes que les clients peuvent encore retirer, par produit.
--   * un cycle non retiré dont le solde disponible est positif (solde_disponible_cycle : collecté - mise - retraits déjà faits) ;
--   * regroupé par produit, avec le détail par client et par cycle ; filtre produit facultatif.
-- Dépend de : 59 (solde_disponible_cycle), 01 (cycle, client, produit_epargne, zone).
-- =====================================================================
SET search_path = mf, public;

CREATE FUNCTION rapport_solde_a_retirer(p_agence smallint, p_produit integer)
RETURNS TABLE (produit_code text, produit_libelle text, client_numero text, client text, zone text,
               cycle text, statut text, date_fin date, solde numeric)
LANGUAGE sql STABLE AS $$
  SELECT pe.code::text, pe.libelle::text, cl.numero::text, cl.nom::text, z.libelle::text,
         c.numero::text, c.statut::text, c.date_fin, solde_disponible_cycle(c.id)
    FROM mf.cycle c
    JOIN mf.client cl ON cl.id = c.client_id
    JOIN mf.produit_epargne pe ON pe.id = c.produit_id
    LEFT JOIN mf.zone z ON z.id = cl.zone_id
   WHERE c.agence_id = p_agence
     AND c.statut <> 'retire'
     AND (p_produit IS NULL OR pe.id = p_produit)
     AND solde_disponible_cycle(c.id) > 0
   ORDER BY pe.code, cl.nom, c.numero;
$$;
