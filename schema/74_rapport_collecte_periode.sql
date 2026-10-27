-- =====================================================================
-- 74_rapport_collecte_periode.sql
-- Rapport des collectes d'une période, regroupées par produit, par agent ou par zone.
--   * une collecte est rattachée à la zone du CLIENT (et non à la collectrice du jour) : une zone peut changer de
--     collectrice pendant la période, la somme reste celle de la zone ;
--   * pour une zone, la colonne « collectrices » liste toutes les affectations qui chevauchent la période,
--     avec leurs dates (ex. « Ama (2026-10-01 → 2026-10-15), Kofi (2026-10-16 → en cours) ») ;
--   * le filtre produit est facultatif.
-- Dépend de : 00 (affectation_zone, collectrice), 01 (cycle, client, ligne_collecte, produit_epargne, agent, zone).
-- =====================================================================
SET search_path = mf, public;

CREATE FUNCTION rapport_collecte_periode(p_agence smallint, p_du date, p_au date, p_produit integer, p_groupe text)
RETURNS TABLE (cle text, libelle text, nb_lignes bigint, montant_collecte numeric, mises numeric, collectrices text)
LANGUAGE sql STABLE AS $$
  WITH l AS (
    SELECT l.montant_collecte, l.mise_appliquee, a.matricule::text AS matricule, a.nom::text AS agent_nom,
           z.code::text AS zone_code, z.libelle::text AS zone_libelle,
           pe.code::text AS produit_code, pe.libelle::text AS produit_libelle
      FROM mf.ligne_collecte l
      JOIN mf.cycle c ON c.id = l.cycle_id
      JOIN mf.client cl ON cl.id = c.client_id
      JOIN mf.produit_epargne pe ON pe.id = c.produit_id
      LEFT JOIN mf.agent a ON a.id = l.agent_id
      LEFT JOIN mf.zone z ON z.id = cl.zone_id
     WHERE c.agence_id = p_agence AND l.origine = 'collecte'
       AND l.date_collecte BETWEEN p_du AND p_au
       AND (p_produit IS NULL OR pe.id = p_produit)
  ), g AS (
    SELECT CASE p_groupe
             WHEN 'agent' THEN COALESCE(matricule, '—')
             WHEN 'zone'  THEN COALESCE(zone_code, '—')
             ELSE produit_code END AS cle,
           CASE p_groupe
             WHEN 'agent' THEN COALESCE(agent_nom, '—')
             WHEN 'zone'  THEN COALESCE(zone_libelle, '—')
             ELSE produit_libelle END AS libelle,
           count(*) AS nb_lignes,
           sum(montant_collecte) AS montant_collecte,
           sum(mise_appliquee) AS mises
      FROM l
     GROUP BY 1, 2
  )
  SELECT g.cle, g.libelle, g.nb_lignes, g.montant_collecte, g.mises,
         CASE WHEN p_groupe = 'zone' THEN (
           SELECT string_agg(k.nom || ' (' || a.date_debut::text || ' → ' || COALESCE(a.date_fin::text, 'en cours') || ')', ', ' ORDER BY a.date_debut)
             FROM mf.affectation_zone a
             JOIN mf.collectrice k ON k.id = a.collectrice_id
             JOIN mf.zone z2 ON z2.id = a.zone_id
            WHERE z2.code = g.cle AND z2.agence_id = p_agence
              AND a.date_debut <= p_au AND COALESCE(a.date_fin, DATE 'infinity') >= p_du
         ) END AS collectrices
    FROM g
   ORDER BY g.cle;
$$;
