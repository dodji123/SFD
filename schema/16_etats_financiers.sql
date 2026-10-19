-- =====================================================================
-- 16_etats_financiers.sql
-- États financiers issus des écritures comptables : par agence et consolidés (réseau).
--  * compte de résultat : produits (classe 7) et charges (classe 6) par compte de niveau 2, sur une période ;
--  * bilan : soldes cumulés jusqu'à une date, par compte de niveau 2 (hors classes 6, 7 et 9),
--    plus le résultat cumulé (ligne RES) ;
--  * synthèse par agence avec contrôle d'équilibre.
-- Les fonctions renvoient une ligne par agence ; la consolidation (somme des agences) est faite
-- par l'appelant. Dépend de : 05 (écritures), 14.
-- Consolidation = agrégation : aucune écriture inter-agences n'existe (voir 15), donc rien à éliminer.
-- Documents de travail : ce ne sont pas les états réglementaires de la BCEAO.
-- =====================================================================
SET search_path = mf, public;

-- Compte de résultat par agence (p_agence NULL : toutes les agences)
CREATE FUNCTION etat_resultat_par_agence(p_agence smallint, p_du date, p_au date)
RETURNS TABLE (agence_id smallint, agence text, cote text, code varchar, libelle text, montant numeric)
LANGUAGE sql STABLE AS $$
  SELECT x.agence_id, x.agence, x.cote, x.code, COALESCE(pc.libelle, x.code)::text, x.montant
    FROM (
      SELECT p.agence_id, a.code::text AS agence,
             CASE WHEN c.classe = '7' THEN 'produit' ELSE 'charge' END AS cote,
             left(c.code, 2)::varchar AS code,
             sum(CASE WHEN c.classe = '7' THEN e.credit - e.debit ELSE e.debit - e.credit END) AS montant
        FROM mf.ecriture e
        JOIN mf.piece_comptable p ON p.id = e.piece_id
        JOIN mf.agence a ON a.id = p.agence_id
        JOIN mf.compte_comptable c ON c.code = e.compte_code
       WHERE c.classe IN ('6', '7') AND p.date_piece BETWEEN p_du AND p_au
         AND (p_agence IS NULL OR p.agence_id = p_agence)
       GROUP BY p.agence_id, a.code, CASE WHEN c.classe = '7' THEN 'produit' ELSE 'charge' END, left(c.code, 2)
    ) x
    LEFT JOIN mf.compte_comptable pc ON pc.code = x.code
   WHERE x.montant <> 0
   ORDER BY x.cote DESC, x.code, x.agence_id
$$;

-- Bilan par agence : solde signé (débit - crédit) par compte de niveau 2 ; positif = actif, négatif = passif.
-- La ligne RES porte le résultat cumulé (bénéfice = solde négatif, au passif).
CREATE FUNCTION bilan_par_agence(p_agence smallint, p_au date)
RETURNS TABLE (agence_id smallint, agence text, code varchar, libelle text, solde numeric)
LANGUAGE sql STABLE AS $$
  SELECT y.agence_id, y.agence, y.code, COALESCE(pc.libelle, y.code)::text, y.solde
    FROM (
      SELECT p.agence_id, a.code::text AS agence, left(c.code, 2)::varchar AS code, sum(e.debit - e.credit) AS solde
        FROM mf.ecriture e
        JOIN mf.piece_comptable p ON p.id = e.piece_id
        JOIN mf.agence a ON a.id = p.agence_id
        JOIN mf.compte_comptable c ON c.code = e.compte_code
       WHERE c.classe NOT IN ('6', '7', '9') AND p.date_piece <= p_au AND (p_agence IS NULL OR p.agence_id = p_agence)
       GROUP BY p.agence_id, a.code, left(c.code, 2)
    ) y
    LEFT JOIN mf.compte_comptable pc ON pc.code = y.code
   WHERE y.solde <> 0
  UNION ALL
  SELECT p.agence_id, a.code::text, 'RES'::varchar, 'Résultat de l''exercice'::text, sum(e.debit - e.credit)
    FROM mf.ecriture e
    JOIN mf.piece_comptable p ON p.id = e.piece_id
    JOIN mf.agence a ON a.id = p.agence_id
    JOIN mf.compte_comptable c ON c.code = e.compte_code
   WHERE c.classe IN ('6', '7') AND p.date_piece <= p_au AND (p_agence IS NULL OR p.agence_id = p_agence)
   GROUP BY p.agence_id, a.code
  HAVING sum(e.debit - e.credit) <> 0
  ORDER BY 3, 1
$$;

-- Synthèse : une ligne par agence (toutes, même sans écriture) avec produits, charges, résultat de la période,
-- total actif / passif à la date de fin et écart de contrôle (doit être 0).
CREATE FUNCTION synthese_agences(p_du date, p_au date)
RETURNS TABLE (agence_id smallint, agence text, produits numeric, charges numeric, resultat numeric,
               total_actif numeric, total_passif numeric, ecart numeric)
LANGUAGE sql STABLE AS $$
  SELECT a.id, a.code::text,
         COALESCE((SELECT sum(r.montant) FROM mf.etat_resultat_par_agence(a.id, p_du, p_au) r WHERE r.cote = 'produit'), 0),
         COALESCE((SELECT sum(r.montant) FROM mf.etat_resultat_par_agence(a.id, p_du, p_au) r WHERE r.cote = 'charge'), 0),
         COALESCE((SELECT sum(r.montant) FILTER (WHERE r.cote = 'produit') FROM mf.etat_resultat_par_agence(a.id, p_du, p_au) r), 0)
         - COALESCE((SELECT sum(r.montant) FILTER (WHERE r.cote = 'charge') FROM mf.etat_resultat_par_agence(a.id, p_du, p_au) r), 0),
         COALESCE((SELECT sum(b.solde) FROM mf.bilan_par_agence(a.id, p_au) b WHERE b.solde > 0), 0),
         COALESCE((SELECT -sum(b.solde) FROM mf.bilan_par_agence(a.id, p_au) b WHERE b.solde < 0), 0),
         COALESCE((SELECT sum(b.solde) FROM mf.bilan_par_agence(a.id, p_au) b), 0)
    FROM mf.agence a
   ORDER BY a.code
$$;
