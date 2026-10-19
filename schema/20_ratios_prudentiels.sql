-- =====================================================================
-- 20_ratios_prudentiels.sql
-- Ratios prudentiels I à IX du « Guide méthodologique d'audit externe des SFD de la zone UEMOA » (octobre 2010,
-- tableau de l'instruction 6 : pages 48 à 55), calculés sur les postes du module 19.
--   I   limitation des risques (≤ 200 %)           VI   opérations autres que épargne et crédit (≤ 5 %)
--   II  couverture des emplois MLT (≥ 100 %)       VII  réserve générale (dotation ≥ 15 % de l'excédent)
--   III prêts aux dirigeants et au personnel (≤ 10 %)  VIII capitalisation (≥ 15 %)
--   IV  risques sur une seule signature (≤ 5 %)    IX   prises de participation (≤ 25 % des fonds propres)
--   V   liquidité (≥ 100 % / 80 % affilié / 60 % sans dépôts)
-- Seuils paramétrables (table parametre, clés ratio_norme_*). Chaque ratio indique les SAISIES MANQUANTES : certaines
-- données ne sortent pas de la comptabilité (durée résiduelle des dépôts, engagements à court terme, opérations
-- hors épargne et crédit, compléments de provisions exigés) et sont saisies dans donnee_reglementaire ; absentes, elles
-- valent 0 et le ratio est signalé comme incomplet.
-- Interprétations à faire valider : voir le tableau des notes dans la fonction (colonne « note »).
-- Dépend de : 14 (portefeuille_a_date), 19.
-- =====================================================================
SET search_path = mf, public;

ALTER TABLE client ADD COLUMN qualite_interne varchar(15) NOT NULL DEFAULT 'aucune'
  CHECK (qualite_interne IN ('aucune','dirigeant','personnel','personne_liee'));

INSERT INTO parametre(agence_id, cle, valeur, description) VALUES
  (NULL, 'ratio_norme_I',   '200', 'plafond du ratio I (limitation des risques), en %'),
  (NULL, 'ratio_norme_II',  '100', 'plancher du ratio II (couverture des emplois à moyen et long terme), en %'),
  (NULL, 'ratio_norme_III', '10',  'plafond du ratio III (prêts aux dirigeants et au personnel), en % des fonds propres'),
  (NULL, 'ratio_norme_IV',  '5',   'plafond du ratio IV (risques sur une seule signature), en % des fonds propres'),
  (NULL, 'ratio_norme_V_non_affilie', '100', 'plancher du ratio V (liquidité), institution non affiliée, en %'),
  (NULL, 'ratio_norme_V_affilie',     '80',  'plancher du ratio V, institution affiliée, en %'),
  (NULL, 'ratio_norme_V_sans_depots', '60',  'plancher du ratio V, institution qui ne collecte pas de dépôts, en %'),
  (NULL, 'ratio_norme_VI',  '5',   'plafond du ratio VI (opérations autres que épargne et crédit), en %'),
  (NULL, 'ratio_norme_VII', '15',  'dotation minimale à la réserve générale, en % de l''excédent'),
  (NULL, 'ratio_norme_VIII','15',  'plancher du ratio VIII (fonds propres sur total actif), en %'),
  (NULL, 'ratio_norme_IX',  '25',  'plafond du ratio IX (participations), en % des fonds propres'),
  (NULL, 'type_institution_liquidite', 'non_affilie', 'non_affilie | affilie | sans_depots : norme applicable au ratio V')
ON CONFLICT DO NOTHING;

-- ---------------------------------------------------------------------
-- Hypothèses de calcul : points d'interprétation du guide, rendus paramétrables et validables par le comptable.
-- Chaque hypothèse a une valeur retenue (table parametre) ; une validation porte sur une valeur donnée et tombe
-- si la valeur change. Les seuils des ratios (clés ratio_norme_*) se modifient par modifier_norme_ratio.
-- ---------------------------------------------------------------------
INSERT INTO parametre(agence_id, cle, valeur, description) VALUES
  (NULL, 'hyp_ratio_I_depots_garantie', 'non',      'ratio I : oui = les dépôts de garantie reçus (G30) sont déduits des risques portés'),
  (NULL, 'hyp_ratios_A2J',              'II_et_V',  'compte A2J (autres dépôts constitués) : II_et_V | II_seulement | V_seulement'),
  (NULL, 'hyp_ratio_IV_signature',      'client',   'ratio IV : client = un client est une signature ; groupe = les clients liés par un lien groupe ou associé sont regroupés'),
  (NULL, 'hyp_normes_a_jour',           'non_verifiees', 'seuils des ratios : non_verifiees | verifiees (contrôlés contre les instructions BCEAO en vigueur)')
ON CONFLICT DO NOTHING;

CREATE TABLE hypothese_calcul (
  code        varchar(40) PRIMARY KEY,
  cle_param   varchar(60) NOT NULL,
  libelle     text NOT NULL,
  explication text NOT NULL,
  valeurs     text[] NOT NULL
);
INSERT INTO hypothese_calcul(code, cle_param, libelle, explication, valeurs) VALUES
  ('depots_garantie_ratio_I', 'hyp_ratio_I_depots_garantie', 'Dépôts de garantie au ratio I',
   'Le guide parle de montants nets des provisions et des dépôts de garantie. « non » : seules les provisions sont déduites ; « oui » : les dépôts de garantie reçus (poste G30) le sont aussi.', ARRAY['non','oui']),
  ('compte_A2J', 'hyp_ratios_A2J', 'Compte A2J aux ratios II et V',
   'Le guide cite A2J (autres dépôts constitués auprès des institutions financières) dans les emplois à moyen et long terme (II) et dans les valeurs disponibles à court terme (V). Choisir où le compter.', ARRAY['II_et_V','II_seulement','V_seulement']),
  ('signature_ratio_IV', 'hyp_ratio_IV_signature', 'Définition de « une seule signature » au ratio IV',
   '« client » : chaque client est une signature. « groupe » : les clients reliés par un lien de type groupe ou associé forment une seule signature (contrôle conjoint ou influence notable).', ARRAY['client','groupe']),
  ('normes_a_jour', 'hyp_normes_a_jour', 'Seuils des ratios',
   'Le guide date de 2010 : les seuils doivent être contrôlés contre les instructions BCEAO en vigueur. Passer à « verifiees » une fois le contrôle fait.', ARRAY['non_verifiees','verifiees']);

CREATE TABLE hypothese_validation (
  id          serial PRIMARY KEY,
  code        varchar(40) NOT NULL REFERENCES hypothese_calcul(code),
  valeur      text NOT NULL,
  validee_par integer REFERENCES utilisateur(id),
  commentaire text,
  cree_le     timestamptz NOT NULL DEFAULT now()
);
CREATE TRIGGER hypothese_validation_ajout_seul BEFORE UPDATE OR DELETE ON hypothese_validation FOR EACH ROW EXECUTE FUNCTION trg_ajout_seul();
CREATE TRIGGER audit_hypothese_validation AFTER INSERT ON hypothese_validation FOR EACH ROW EXECUTE FUNCTION trg_audit();

CREATE VIEW v_hypotheses AS
SELECT h.code, h.libelle, h.explication, h.valeurs, COALESCE(mf.param(h.cle_param), h.valeurs[1]) AS valeur,
       v.validee_par, u.login AS validee_par_login, v.cree_le AS validee_le, v.commentaire,
       (v.id IS NOT NULL) AS validee
  FROM hypothese_calcul h
  LEFT JOIN LATERAL (SELECT * FROM mf.hypothese_validation x WHERE x.code = h.code AND x.valeur = COALESCE(mf.param(h.cle_param), h.valeurs[1])
                      ORDER BY x.id DESC LIMIT 1) v ON true
  LEFT JOIN utilisateur u ON u.id = v.validee_par;

CREATE FUNCTION modifier_hypothese(p_code text, p_valeur text) RETURNS void
LANGUAGE plpgsql AS $$
DECLARE h mf.hypothese_calcul;
BEGIN
  SELECT * INTO h FROM mf.hypothese_calcul WHERE code = p_code;
  IF NOT FOUND THEN RAISE EXCEPTION 'hypothèse % inconnue', p_code; END IF;
  IF NOT p_valeur = ANY (h.valeurs) THEN RAISE EXCEPTION 'valeur % refusée pour % (valeurs possibles : %)', p_valeur, p_code, array_to_string(h.valeurs, ', '); END IF;
  UPDATE mf.parametre SET valeur = p_valeur WHERE cle = h.cle_param AND agence_id IS NULL;
END $$;

CREATE FUNCTION valider_hypothese(p_code text, p_utilisateur integer DEFAULT NULL, p_commentaire text DEFAULT NULL) RETURNS void
LANGUAGE plpgsql AS $$
DECLARE v text;
BEGIN
  SELECT valeur INTO v FROM mf.v_hypotheses WHERE code = p_code;
  IF NOT FOUND THEN RAISE EXCEPTION 'hypothèse % inconnue', p_code; END IF;
  INSERT INTO mf.hypothese_validation(code, valeur, validee_par, commentaire) VALUES (p_code, v, p_utilisateur, p_commentaire);
END $$;

-- Seuils des ratios : modifiables, valeur contrôlée ; chaque modification est tracée par l'audit du paramètre
CREATE FUNCTION modifier_norme_ratio(p_cle text, p_valeur numeric) RETURNS void
LANGUAGE plpgsql AS $$
BEGIN
  IF p_cle !~ '^ratio_norme_' THEN RAISE EXCEPTION 'paramètre % : ce n''est pas un seuil de ratio', p_cle; END IF;
  IF p_valeur <= 0 OR p_valeur > 1000 THEN RAISE EXCEPTION 'seuil % invalide (entre 0 exclu et 1000)', p_valeur; END IF;
  UPDATE mf.parametre SET valeur = p_valeur::text WHERE cle = p_cle AND agence_id IS NULL;
  IF NOT FOUND THEN RAISE EXCEPTION 'seuil % inconnu', p_cle; END IF;
  UPDATE mf.parametre SET valeur = 'non_verifiees' WHERE cle = 'hyp_normes_a_jour' AND agence_id IS NULL;    -- un seuil modifié est à re-contrôler
END $$;

-- Encours de crédit par signature : un client, ou un groupe de clients reliés (liens groupe et associé)
CREATE FUNCTION encours_par_signature(p_agence smallint, p_date date, p_groupe boolean)
RETURNS TABLE (signature integer, encours numeric)
LANGUAGE sql STABLE AS $$
  WITH RECURSIVE aretes AS (
    SELECT client_id AS a, lie_a_id AS b FROM mf.lien_client WHERE p_groupe AND type IN ('groupe','associe')
    UNION SELECT lie_a_id, client_id FROM mf.lien_client WHERE p_groupe AND type IN ('groupe','associe')
  ), cc(client, rep) AS (
    SELECT c.id, c.id FROM mf.client c
    UNION SELECT a.b, cc.rep FROM cc JOIN aretes a ON a.a = cc.client
  ), comp AS (SELECT client, min(rep) AS rep FROM cc GROUP BY client),
  pf AS (SELECT p.client_id, sum(p.capital_restant) AS cap
           FROM mf.agence ag CROSS JOIN LATERAL mf.portefeuille_a_date(ag.id, p_date) p
          WHERE p_agence IS NULL OR ag.id = p_agence GROUP BY p.client_id)
  SELECT comp.rep, sum(pf.cap) FROM pf JOIN comp ON comp.client = pf.client_id GROUP BY comp.rep
$$;

-- Données réglementaires saisies (par agence, datées, conservées : la plus récente avant la date de calcul fait foi)
CREATE TABLE donnee_reglementaire (
  id          serial PRIMARY KEY,
  agence_id   smallint NOT NULL REFERENCES agence(id),
  code        varchar(40) NOT NULL CHECK (code IN
                ('depots_mlt',                      -- part à plus d'un an des dépôts et dettes (ressources stables, ratio II ; exclue du ratio V)
                 'engagements_ct_donnes',           -- engagements de financement et de garantie à court terme donnés (ratio V, numérateur)
                 'engagements_ct_recus',            -- id. reçus (ratio V, dénominateur)
                 'ops_autres_activites',            -- montant consacré aux opérations autres que épargne et crédit (ratio VI)
                 'complement_provisions_autorites', -- compléments de provisions exigés par les autorités (déduit des fonds propres)
                 'participations_autres_sfd')),     -- participations constituant des fonds propres dans d'autres SFD (déduit)
  date_effet  date NOT NULL,
  valeur      numeric(16,0) NOT NULL CHECK (valeur >= 0),
  commentaire text,
  saisi_par   integer REFERENCES utilisateur(id),
  cree_le     timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX donnee_reglementaire_idx ON donnee_reglementaire (code, agence_id, date_effet DESC, id DESC);
CREATE TRIGGER donnee_reglementaire_ajout_seul BEFORE UPDATE OR DELETE ON donnee_reglementaire FOR EACH ROW EXECUTE FUNCTION trg_ajout_seul();
CREATE TRIGGER audit_donnee_reglementaire AFTER INSERT ON donnee_reglementaire FOR EACH ROW EXECUTE FUNCTION trg_audit();

-- Dernière valeur saisie de chaque agence avant la date, additionnée (une agence : la sienne ; NULL : le réseau)
CREATE FUNCTION donnee_reg(p_code text, p_agence smallint, p_date date) RETURNS numeric
LANGUAGE sql STABLE AS $$
  SELECT COALESCE(sum(x.valeur), 0) FROM (
    SELECT DISTINCT ON (agence_id) valeur FROM mf.donnee_reglementaire
     WHERE code = p_code AND date_effet <= p_date AND (p_agence IS NULL OR agence_id = p_agence)
     ORDER BY agence_id, date_effet DESC, id DESC) x
$$;

CREATE FUNCTION donnee_reg_saisie(p_code text, p_agence smallint, p_date date) RETURNS boolean
LANGUAGE sql STABLE AS $$
  SELECT EXISTS (SELECT 1 FROM mf.donnee_reglementaire WHERE code = p_code AND date_effet <= p_date AND (p_agence IS NULL OR agence_id = p_agence))
$$;

CREATE FUNCTION _pm(m jsonb, c text) RETURNS numeric LANGUAGE sql IMMUTABLE AS $$ SELECT COALESCE((m ->> c)::numeric, 0) $$;

-- Fonds propres retraités (ratios III, IV, VIII, IX) à une date
CREATE FUNCTION fonds_propres_retraites(p_agence smallint, p_date date) RETURNS numeric
LANGUAGE plpgsql STABLE AS $$
DECLARE m jsonb;
BEGIN
  SELECT jsonb_object_agg(code, montant) INTO m FROM mf.valeurs_postes(p_agence, p_date, p_date);
  RETURN mf._pm(m,'L10') + mf._pm(m,'L20') + mf._pm(m,'L30') + mf._pm(m,'L41') + mf._pm(m,'L45') + mf._pm(m,'L50') + mf._pm(m,'L55')
       + mf._pm(m,'L59') + mf._pm(m,'L60') + mf._pm(m,'L65') + mf._pm(m,'L70') + mf._pm(m,'L75') + mf._pm(m,'L80')
       - mf._pm(m,'L62') - mf._pm(m,'E05')
       - (mf._pm(m,'D24') + mf._pm(m,'D31') + mf._pm(m,'D41') + mf._pm(m,'D46'))
       - mf.donnee_reg('complement_provisions_autorites', p_agence, p_date) - mf.donnee_reg('participations_autres_sfd', p_agence, p_date);
END $$;

CREATE FUNCTION ratios_prudentiels(p_agence smallint, p_date date)
RETURNS TABLE (ratio varchar, libelle text, numerateur numeric, denominateur numeric, valeur numeric,
               norme_type text, norme numeric, conforme boolean, saisies_manquantes text[], note text)
LANGUAGE plpgsql STABLE AS $$
DECLARE
  m jsonb; fp numeric; fp_prec numeric; total_actif numeric;
  risques numeric; risques_vi numeric; engagements numeric;
  gros numeric; internes numeric; resultat numeric; base_vii numeric;
  depots_mlt numeric; norme_v numeric; type_inst text;
  a numeric; b numeric; manque text[];
  nm text[] := ARRAY['depots_mlt','engagements_ct_donnes','engagements_ct_recus','ops_autres_activites'];
  agence_param smallint := COALESCE(p_agence, (SELECT min(id) FROM mf.agence));
  hyp_gar text; hyp_a2j text; hyp_sig text; a2j_ii numeric; a2j_v numeric;
BEGIN
  SELECT jsonb_object_agg(code, montant) INTO m FROM mf.valeurs_postes(p_agence, p_date, p_date);
  fp := mf.fonds_propres_retraites(p_agence, p_date);
  fp_prec := mf.fonds_propres_retraites(p_agence, make_date(extract(year FROM p_date)::int - 1, 12, 31));
  total_actif := (SELECT e.montant FROM mf.etat_bilan_reglementaire(p_agence, p_date) e WHERE e.code = 'E90');
  engagements := mf._pm(m,'N1A') + mf._pm(m,'N1J') + mf._pm(m,'N3A') + mf._pm(m,'Q1A');
  depots_mlt := mf.donnee_reg('depots_mlt', p_agence, p_date);
  hyp_gar := COALESCE(mf.param('hyp_ratio_I_depots_garantie', agence_param), 'non');
  hyp_a2j := COALESCE(mf.param('hyp_ratios_A2J', agence_param), 'II_et_V');
  hyp_sig := COALESCE(mf.param('hyp_ratio_IV_signature', agence_param), 'client');
  a2j_ii := CASE WHEN hyp_a2j IN ('II_et_V','II_seulement') THEN mf._pm(m,'A2J') ELSE 0 END;
  a2j_v  := CASE WHEN hyp_a2j IN ('II_et_V','V_seulement') THEN mf._pm(m,'A2J') ELSE 0 END;
  type_inst := COALESCE(mf.param('type_institution_liquidite', agence_param), 'non_affilie');

  SELECT COALESCE(sum(pf.cap) FILTER (WHERE c.qualite_interne <> 'aucune'), 0) INTO internes
    FROM (SELECT p.client_id, sum(p.capital_restant) AS cap
            FROM mf.agence ag CROSS JOIN LATERAL mf.portefeuille_a_date(ag.id, p_date) p
           WHERE p_agence IS NULL OR ag.id = p_agence GROUP BY p.client_id) pf
    JOIN mf.client c ON c.id = pf.client_id;
  SELECT COALESCE(max(encours), 0) INTO gros FROM mf.encours_par_signature(p_agence, p_date, hyp_sig = 'groupe');

  -- I : limitation des risques
  risques := mf._pm(m,'A3A') + mf._pm(m,'A70') + mf._pm(m,'B2D') + mf._pm(m,'B30') + mf._pm(m,'B40') + mf._pm(m,'B70') + mf._pm(m,'C10') + mf._pm(m,'D1L') + engagements;
  a := risques - CASE WHEN hyp_gar = 'oui' THEN mf._pm(m,'G30') ELSE 0 END;
  b := mf._pm(m,'F2A') + mf._pm(m,'F3A') + mf._pm(m,'F50') + mf._pm(m,'G2A') + mf._pm(m,'G10') + mf._pm(m,'G15') + mf._pm(m,'G30') + mf._pm(m,'G35')
     + mf._pm(m,'G60') + mf._pm(m,'G70') + mf._pm(m,'L01');
  ratio := 'I'; libelle := 'Limitation des risques auxquels est exposée l''institution'; numerateur := a; denominateur := b;
  valeur := CASE WHEN b > 0 THEN round(a / b * 100, 2) END; norme_type := 'max'; norme := mf.param_num('ratio_norme_I', agence_param);
  saisies_manquantes := '{}'; note := CASE WHEN hyp_gar = 'oui' THEN 'Risques nets des provisions et des dépôts de garantie reçus (G30).' ELSE 'Risques nets des provisions ; dépôts de garantie non déduits (hypothèse retenue).' END;
  conforme := valeur <= norme; RETURN NEXT;

  -- II : couverture des emplois à moyen et long terme
  a := mf._pm(m,'L01') + mf._pm(m,'F3F') + depots_mlt;
  b := mf._pm(m,'A2H') + mf._pm(m,'A2I') + a2j_ii + mf._pm(m,'A3C') + mf._pm(m,'A70') + mf._pm(m,'B30') + mf._pm(m,'B40') + mf._pm(m,'B70')
     + mf._pm(m,'D1E') + mf._pm(m,'D1L') + mf._pm(m,'D10') + mf._pm(m,'D1S') + mf._pm(m,'D23') + mf._pm(m,'D30') + mf._pm(m,'D40');
  ratio := 'II'; libelle := 'Couverture des emplois à moyen et long terme par des ressources stables'; numerateur := a; denominateur := b;
  valeur := CASE WHEN b > 0 THEN round(a / b * 100, 2) END; norme_type := 'min'; norme := mf.param_num('ratio_norme_II', agence_param);
  saisies_manquantes := CASE WHEN mf.donnee_reg_saisie('depots_mlt', p_agence, p_date) THEN '{}' ELSE ARRAY['depots_mlt'] END;
  note := 'Les durées résiduelles ne sont pas suivies : la part à plus d''un an des dépôts et dettes est saisie (depots_mlt). A2J compté : ' || hyp_a2j || ' (hypothèse retenue).';
  conforme := valeur >= norme OR (b = 0); RETURN NEXT;

  -- III : prêts aux dirigeants, au personnel et aux personnes liées
  ratio := 'III'; libelle := 'Limitation des prêts aux dirigeants, au personnel et aux personnes liées'; numerateur := internes; denominateur := fp;
  valeur := CASE WHEN fp > 0 THEN round(internes / fp * 100, 2) END; norme_type := 'max'; norme := mf.param_num('ratio_norme_III', agence_param);
  saisies_manquantes := '{}'; note := 'Capital restant dû des clients marqués dirigeant, personnel ou personne liée (fiche client) ; engagements par signature non inclus.';
  conforme := CASE WHEN fp > 0 THEN valeur <= norme WHEN internes = 0 THEN true ELSE false END; RETURN NEXT;

  -- IV : risques sur une seule signature
  ratio := 'IV'; libelle := 'Limitation des risques pris sur une seule signature'; numerateur := gros; denominateur := fp;
  valeur := CASE WHEN fp > 0 THEN round(gros / fp * 100, 2) END; norme_type := 'max'; norme := mf.param_num('ratio_norme_IV', agence_param);
  saisies_manquantes := '{}'; note := CASE WHEN hyp_sig = 'groupe' THEN 'Plus gros encours d''un client ou d''un groupe de clients liés (liens groupe et associé).' ELSE 'Plus gros encours d''un même client ; les clients d''un même groupe ne sont pas regroupés (hypothèse retenue).' END;
  conforme := CASE WHEN fp > 0 THEN valeur <= norme WHEN gros = 0 THEN true ELSE false END; RETURN NEXT;

  -- V : liquidité
  norme_v := mf.param_num('ratio_norme_V_' || type_inst, agence_param);
  a := mf._pm(m,'A10') + a2j_v + mf._pm(m,'A3B') + mf._pm(m,'B2D') + mf._pm(m,'C10') + mf._pm(m,'C30') + mf._pm(m,'C40') + mf._pm(m,'C56')
     + mf._pm(m,'A60') + mf._pm(m,'B65') + mf._pm(m,'C55') + mf._pm(m,'D60') + mf.donnee_reg('engagements_ct_donnes', p_agence, p_date);
  b := mf._pm(m,'F1A') + mf._pm(m,'F2A') + mf._pm(m,'F2D') + mf._pm(m,'F3E') + mf._pm(m,'F50') + mf._pm(m,'G10') + mf._pm(m,'G15') + mf._pm(m,'G2A')
     + mf._pm(m,'G30') + mf._pm(m,'G35') + mf._pm(m,'G60') + mf._pm(m,'G70') + mf._pm(m,'H10') + mf._pm(m,'H40')
     + mf.donnee_reg('engagements_ct_recus', p_agence, p_date) - depots_mlt;
  ratio := 'V'; libelle := 'Norme de liquidité (coefficient de liquidité)'; numerateur := a; denominateur := GREATEST(b, 0);
  valeur := CASE WHEN b > 0 THEN round(a / b * 100, 2) END; norme_type := 'min'; norme := norme_v;
  SELECT array_agg(c) INTO manque FROM unnest(ARRAY['depots_mlt','engagements_ct_donnes','engagements_ct_recus']) c WHERE NOT mf.donnee_reg_saisie(c, p_agence, p_date);
  saisies_manquantes := COALESCE(manque, '{}'); note := 'Norme applicable : ' || type_inst || ' (paramètre type_institution_liquidite). Valeurs réalisables et disponibles à court terme / passif exigible à court terme.';
  conforme := CASE WHEN b > 0 THEN valeur >= norme ELSE true END; RETURN NEXT;

  -- VI : opérations autres que l'épargne et le crédit
  a := mf.donnee_reg('ops_autres_activites', p_agence, p_date);
  risques_vi := mf._pm(m,'A3A') + mf._pm(m,'A70') + mf._pm(m,'B2D') + mf._pm(m,'B30') + mf._pm(m,'B40') + mf._pm(m,'B70') + mf._pm(m,'D1E') + mf._pm(m,'D1L') + engagements;
  ratio := 'VI'; libelle := 'Limitation des opérations autres que les activités d''épargne et de crédit'; numerateur := a; denominateur := risques_vi;
  valeur := CASE WHEN risques_vi > 0 THEN round(a / risques_vi * 100, 2) END; norme_type := 'max'; norme := mf.param_num('ratio_norme_VI', agence_param);
  saisies_manquantes := CASE WHEN mf.donnee_reg_saisie('ops_autres_activites', p_agence, p_date) THEN '{}' ELSE ARRAY['ops_autres_activites'] END;
  note := 'Le montant consacré aux autres activités est saisi (ops_autres_activites).';
  conforme := CASE WHEN risques_vi > 0 THEN valeur <= norme ELSE a = 0 END; RETURN NEXT;

  -- VII : réserve générale (dotation de 15 % minimum de l'excédent après imputation du report à nouveau déficitaire)
  resultat := mf._pm(m,'L75') - mf._pm(m,'E05') + mf._pm(m,'L80');
  base_vii := GREATEST(resultat + LEAST(mf._pm(m,'L70'), 0), 0);
  ratio := 'VII'; libelle := 'Constitution de la réserve générale'; numerateur := mf._pm(m,'L56'); denominateur := base_vii;
  valeur := CASE WHEN base_vii > 0 THEN round(mf._pm(m,'L56') / base_vii * 100, 2) END; norme_type := 'min'; norme := mf.param_num('ratio_norme_VII', agence_param);
  saisies_manquantes := '{}'; note := 'Indicatif : compare la réserve générale constituée (L56) à l''excédent de la période ; la dotation annuelle n''est pas isolée.';
  conforme := CASE WHEN base_vii > 0 THEN mf._pm(m,'L56') >= base_vii * norme / 100 ELSE true END; RETURN NEXT;

  -- VIII : capitalisation (fonds propres moyens retraités / total actif)
  a := (fp + fp_prec) / 2;
  ratio := 'VIII'; libelle := 'Norme de capitalisation (fonds propres moyens retraités sur total de l''actif)'; numerateur := a; denominateur := total_actif;
  valeur := CASE WHEN total_actif > 0 THEN round(a / total_actif * 100, 2) END; norme_type := 'min'; norme := mf.param_num('ratio_norme_VIII', agence_param);
  saisies_manquantes := '{}'; note := 'Moyenne des fonds propres retraités au 31/12 de l''exercice précédent et à la date de calcul.';
  conforme := CASE WHEN total_actif > 0 THEN valeur >= norme END; RETURN NEXT;

  -- IX : prises de participation
  ratio := 'IX'; libelle := 'Limitation des prises de participation'; numerateur := mf._pm(m,'D1E'); denominateur := fp;
  valeur := CASE WHEN fp > 0 THEN round(mf._pm(m,'D1E') / fp * 100, 2) END; norme_type := 'max'; norme := mf.param_num('ratio_norme_IX', agence_param);
  saisies_manquantes := '{}'; note := 'Titres de participation (D1E) rapportés aux fonds propres retraités.';
  conforme := CASE WHEN fp > 0 THEN valeur <= norme WHEN mf._pm(m,'D1E') = 0 THEN true ELSE false END; RETURN NEXT;
END $$;

-- Historique : instantané des ratios à une date (pour suivre l'évolution et prouver ce qui a été calculé)
CREATE TABLE ratio_historique (
  id           bigserial PRIMARY KEY,
  agence_id    smallint REFERENCES agence(id),            -- NULL = réseau consolidé
  date_calcul  date NOT NULL,
  ratio        varchar(4) NOT NULL,
  numerateur   numeric,
  denominateur numeric,
  valeur       numeric,
  norme_type   varchar(3),
  norme        numeric,
  conforme     boolean,
  saisies_manquantes text[],
  calcule_par  integer REFERENCES utilisateur(id),
  cree_le      timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX ratio_historique_idx ON ratio_historique (agence_id, ratio, date_calcul DESC, id DESC);
CREATE TRIGGER ratio_historique_ajout_seul BEFORE UPDATE OR DELETE ON ratio_historique FOR EACH ROW EXECUTE FUNCTION trg_ajout_seul();

CREATE FUNCTION enregistrer_ratios(p_agence smallint, p_date date, p_utilisateur integer DEFAULT NULL) RETURNS integer
LANGUAGE plpgsql AS $$
DECLARE v_n integer;
BEGIN
  INSERT INTO mf.ratio_historique(agence_id, date_calcul, ratio, numerateur, denominateur, valeur, norme_type, norme, conforme, saisies_manquantes, calcule_par)
  SELECT p_agence, p_date, r.ratio, r.numerateur, r.denominateur, r.valeur, r.norme_type, r.norme, r.conforme, r.saisies_manquantes, p_utilisateur
    FROM mf.ratios_prudentiels(p_agence, p_date) r;
  GET DIAGNOSTICS v_n = ROW_COUNT;
  RETURN v_n;
END $$;
