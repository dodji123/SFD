SET search_path = mf, public;

-- =====================================================================
-- 63 : bilan au format du modèle, avec brut, amortissements / provisions et net.
-- Règle : pour un poste d'actif, le brut est la somme des comptes rattachés avec le signe « + » ;
-- les amortissements et provisions sont les comptes de contrepartie (signe « - ») en valeur positive.
-- Net = brut - amortissements/provisions, et égal à valeurs_postes (même calcul).
-- Pour un poste de passif, ou un poste spécial (E05, L75), brut = net et amortissements = 0.
-- =====================================================================
CREATE FUNCTION valeurs_postes_detail(p_agence smallint, p_au date)
RETURNS TABLE (code varchar, cote text, libelle text, brut numeric, amort numeric, net numeric)
LANGUAGE sql STABLE AS $$
  WITH s AS (
    SELECT e.compte_code,
           COALESCE(sum(e.debit), 0)  AS d_cum,
           COALESCE(sum(e.credit), 0) AS c_cum
      FROM mf.ecriture e JOIN mf.piece_comptable p ON p.id = e.piece_id
     WHERE p.date_piece <= p_au AND (p_agence IS NULL OR p.agence_id = p_agence)
     GROUP BY e.compte_code
  ), lien AS (
    SELECT pc.poste_code, s.compte_code,
           bool_and(pc.ex)        AS seulement_ex,
           bool_or(pc.signe = -1) AS contrepartie,
           max(s.d_cum)           AS d_cum,
           max(s.c_cum)           AS c_cum
      FROM mf.poste_compte pc
      JOIN s ON s.compte_code LIKE pc.prefixe || '%'
     GROUP BY pc.poste_code, s.compte_code
  ), val AS (
    SELECT l.poste_code, l.contrepartie,
           CASE WHEN l.seulement_ex THEN GREATEST(l.d_cum - l.c_cum, 0) ELSE l.d_cum - l.c_cum END AS m
      FROM lien l JOIN mf.poste_etat pe ON pe.code = l.poste_code AND pe.cote = 'actif'
  )
  SELECT pe.code::varchar, pe.cote::text, pe.libelle,
         CASE WHEN pe.cote = 'actif' AND pe.code NOT IN ('E05', 'L75')
              THEN COALESCE((SELECT sum(v.m) FILTER (WHERE NOT v.contrepartie) FROM val v WHERE v.poste_code = pe.code), 0)
              ELSE vp.montant END                                                    AS brut,
         CASE WHEN pe.cote = 'actif' AND pe.code NOT IN ('E05', 'L75')
              THEN -COALESCE((SELECT sum(v.m) FILTER (WHERE v.contrepartie) FROM val v WHERE v.poste_code = pe.code), 0)
              ELSE 0 END                                                             AS amort,
         vp.montant                                                                  AS net
    FROM mf.poste_etat pe
    JOIN mf.valeurs_postes(p_agence, p_au, p_au) vp ON vp.code = pe.code
   ORDER BY pe.code
$$;
