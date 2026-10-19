-- =====================================================================
-- 19_etats_reglementaires.sql  (données des postes : 19_postes_data.sql)
-- États financiers selon la nomenclature des postes du référentiel comptable des SFD de l'UMOA
-- (annexe 1.1 : codes postes et concordance avec le plan de comptes ; annexes 2 et 3 : bilan, compte de résultat).
--  * poste_etat / poste_compte : nomenclature et concordance, chargées par 19_postes_data.sql ;
--  * valeurs_postes(agence, du, au) : valeur de chaque poste calculée à partir des écritures ;
--  * etat_bilan_reglementaire / etat_resultat_reglementaire / etat_hors_bilan.
-- Règles de calcul (à valider par le comptable) :
--  1. un compte est rattaché à un poste par PRÉFIXE de code ; un compte n'est compté qu'une fois par poste ;
--  2. les signes « + » et « - » de la concordance désignent des comptes de contrepartie (provisions, amortissements) :
--     la valeur d'un poste d'actif ou de charge est la somme des soldes débiteurs (débit - crédit) de ses comptes, celle
--     d'un poste de passif ou de produit la somme des soldes créditeurs (crédit - débit) ; une provision (solde créditeur)
--     vient donc bien en déduction d'un poste d'actif ;
--  3. un compte marqué « ex » peut être débiteur ou créditeur : il figure à l'actif s'il est débiteur, au passif s'il est créditeur ;
--  4. bilan : soldes cumulés jusqu'à la date ; compte de résultat : mouvements de la période ;
--  5. E05 (excédent des charges sur les produits) et L75 (excédent des produits sur les charges) sont les parties positives du
--     résultat cumulé des classes 6 et 7 (aucune clôture d'exercice n'est passée) ;
--  6. hors-bilan : valeur absolue du solde ; seules les valeurs nettes sont produites (pas de colonnes brut / amortissements).
-- Dépend de : 05 (écritures).
-- =====================================================================
SET search_path = mf, public;

CREATE TABLE poste_etat (
  code    varchar(3) PRIMARY KEY,
  cote    varchar(10) NOT NULL CHECK (cote IN ('actif','passif','hors_bilan','charge','produit','autre')),
  libelle text NOT NULL
);

CREATE TABLE poste_compte (
  poste_code varchar(3) NOT NULL REFERENCES poste_etat(code),
  prefixe    varchar(7) NOT NULL,
  signe      smallint NOT NULL CHECK (signe IN (1, -1)),
  ex         boolean NOT NULL DEFAULT false,
  PRIMARY KEY (poste_code, prefixe, ex)
);
CREATE INDEX poste_compte_prefixe ON poste_compte (prefixe text_pattern_ops);

-- Valeur de chaque poste pour une agence (NULL = toutes les agences) ; bilan cumulé jusqu'à p_au, résultat sur [p_du, p_au].
CREATE FUNCTION valeurs_postes(p_agence smallint, p_du date, p_au date)
RETURNS TABLE (code varchar, cote text, libelle text, montant numeric)
LANGUAGE sql STABLE AS $$
  WITH s AS (                                  -- mouvements par compte : cumul jusqu'à la date et période
    SELECT e.compte_code,
           COALESCE(sum(e.debit)  FILTER (WHERE p.date_piece <= p_au), 0) AS d_cum,
           COALESCE(sum(e.credit) FILTER (WHERE p.date_piece <= p_au), 0) AS c_cum,
           COALESCE(sum(e.debit)  FILTER (WHERE p.date_piece BETWEEN p_du AND p_au), 0) AS d_per,
           COALESCE(sum(e.credit) FILTER (WHERE p.date_piece BETWEEN p_du AND p_au), 0) AS c_per
      FROM mf.ecriture e JOIN mf.piece_comptable p ON p.id = e.piece_id
     WHERE p.date_piece <= p_au AND (p_agence IS NULL OR p.agence_id = p_agence)
     GROUP BY e.compte_code
  ), lien AS (                                 -- un compte compte une fois par poste ; « ex » seulement si aucun rattachement ordinaire
    SELECT pc.poste_code, s.compte_code, e.cote, bool_and(pc.ex) AS seulement_ex,
           max(s.d_cum) AS d_cum, max(s.c_cum) AS c_cum, max(s.d_per) AS d_per, max(s.c_per) AS c_per
      FROM mf.poste_compte pc
      JOIN mf.poste_etat e ON e.code = pc.poste_code
      JOIN s ON s.compte_code LIKE pc.prefixe || '%'
     GROUP BY pc.poste_code, s.compte_code, e.cote
  ), val AS (
    SELECT l.poste_code, l.cote,
           CASE l.cote
             WHEN 'actif'      THEN CASE WHEN l.seulement_ex THEN GREATEST(l.d_cum - l.c_cum, 0) ELSE l.d_cum - l.c_cum END
             WHEN 'passif'     THEN CASE WHEN l.seulement_ex THEN GREATEST(l.c_cum - l.d_cum, 0) ELSE l.c_cum - l.d_cum END
             WHEN 'hors_bilan' THEN abs(l.d_cum - l.c_cum)
             WHEN 'charge'     THEN l.d_per - l.c_per
             WHEN 'produit'    THEN l.c_per - l.d_per
             ELSE 0
           END AS m
      FROM lien l
  )
  SELECT pe.code::varchar, pe.cote::text, pe.libelle,
         CASE pe.code
           WHEN 'E05' THEN GREATEST((SELECT COALESCE(sum(d_cum - c_cum), 0) FROM s WHERE compte_code ~ '^[67]'), 0)
           WHEN 'L75' THEN GREATEST((SELECT COALESCE(sum(c_cum - d_cum), 0) FROM s WHERE compte_code ~ '^[67]'), 0)
           ELSE COALESCE((SELECT sum(v.m) FROM val v WHERE v.poste_code = pe.code), 0)
         END
    FROM mf.poste_etat pe
   ORDER BY pe.code
$$;

-- Bilan réglementaire : tous les postes non nuls, avec les totaux E90 (actif) et L90 (passif)
CREATE FUNCTION etat_bilan_reglementaire(p_agence smallint, p_au date)
RETURNS TABLE (cote text, code varchar, libelle text, montant numeric)
LANGUAGE sql STABLE AS $$
  WITH v AS (SELECT * FROM mf.valeurs_postes(p_agence, p_au, p_au) WHERE cote IN ('actif','passif'))
  SELECT v.cote, v.code, v.libelle, v.montant FROM v WHERE v.montant <> 0
  UNION ALL
  SELECT 'actif', 'E90'::varchar, 'TOTAL ACTIF', COALESCE(sum(montant), 0) FROM v WHERE cote = 'actif' AND (code ~ '^[A-D]01$' OR code = 'E01' OR code = 'E05')
  UNION ALL
  SELECT 'passif', 'L90'::varchar, 'TOTAL PASSIF', COALESCE(sum(montant), 0) FROM v WHERE cote = 'passif' AND (code ~ '^[FGHKL]01$' OR code = 'L75')
  ORDER BY 1, 2
$$;

CREATE FUNCTION etat_resultat_reglementaire(p_agence smallint, p_du date, p_au date)
RETURNS TABLE (cote text, code varchar, libelle text, montant numeric)
LANGUAGE sql STABLE AS $$
  SELECT v.cote, v.code, v.libelle, v.montant
    FROM mf.valeurs_postes(p_agence, p_du, p_au) v WHERE v.cote IN ('charge','produit') AND v.montant <> 0
   ORDER BY 1 DESC, 2
$$;

CREATE FUNCTION etat_hors_bilan(p_agence smallint, p_au date)
RETURNS TABLE (code varchar, libelle text, montant numeric)
LANGUAGE sql STABLE AS $$
  SELECT v.code, v.libelle, v.montant FROM mf.valeurs_postes(p_agence, p_au, p_au) v WHERE v.cote = 'hors_bilan' AND v.montant <> 0 ORDER BY v.code
$$;
