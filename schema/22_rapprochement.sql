-- =====================================================================
-- 22_rapprochement.sql
-- Rapprochement entre l'inventaire des fiches (crédits, épargne) et la comptabilité, à une date d'arrêté.
--   1. encours des crédits sains            fiches : capital restant des crédits non déclassés   / comptes 20221, 20231, 2031, 2041
--   2. encours des crédits en souffrance    fiches : capital restant des crédits déclassés        / comptes 291 à 294
--   3. provisions sur crédits en souffrance fiches : provision retenue (module 21)                / comptes 299
--   4. épargne classique                    fiches : mouvements d'épargne jusqu'à la date         / comptes 2511, 2521, 2531
-- Hors périmètre (signalé) : intérêts courus non échus (créances rattachées), tontine, comptes d'attente.
-- Chaque écart supérieur à la tolérance (paramètre rapprochement_tolerance, 0 par défaut) est signalé. Le comptable valide
-- le rapprochement : « conforme » si aucun écart, « écart justifié » avec une justification obligatoire sinon.
-- La régularisation comptable d'un écart (pièce, compte d'attente) reste une saisie du comptable.
-- Dépend de : 05 (pièces), 14, 21 (classification).
-- =====================================================================
SET search_path = mf, public;

INSERT INTO parametre(agence_id, cle, valeur, description) VALUES
  (NULL, 'rapprochement_tolerance', '0', 'écart toléré (en F) entre fiches et comptabilité avant d''être signalé')
ON CONFLICT DO NOTHING;

-- Solde débiteur (débit - crédit) cumulé jusqu'à la date des comptes dont le code commence par l'un des préfixes
CREATE FUNCTION solde_comptes(p_agence smallint, p_date date, p_prefixes text[]) RETURNS numeric
LANGUAGE sql STABLE AS $$
  SELECT COALESCE(sum(e.debit - e.credit), 0)
    FROM mf.ecriture e JOIN mf.piece_comptable p ON p.id = e.piece_id
   WHERE p.date_piece <= p_date AND (p_agence IS NULL OR p.agence_id = p_agence)
     AND EXISTS (SELECT 1 FROM unnest(p_prefixes) x WHERE e.compte_code LIKE x || '%')
$$;

CREATE FUNCTION rapprochement(p_agence smallint, p_date date)
RETURNS TABLE (code text, libelle text, inventaire numeric, comptabilite numeric, ecart numeric, conforme boolean, note text)
LANGUAGE plpgsql STABLE AS $$
DECLARE
  v_tol numeric := COALESCE(mf.param_num('rapprochement_tolerance', p_agence), 0);
  v_sain numeric; v_souf numeric; v_prov numeric; v_epargne numeric;
BEGIN
  SELECT COALESCE(sum(c.capital_restant) FILTER (WHERE NOT c.declasse), 0), COALESCE(sum(c.capital_restant) FILTER (WHERE c.declasse), 0),
         COALESCE(sum(c.provision_retenue), 0)
    INTO v_sain, v_souf, v_prov FROM mf.classification_creances(p_agence, p_date) c;
  SELECT COALESCE(sum(m.montant * mf.sens_mouvement(m.type)), 0) INTO v_epargne
    FROM mf.mouvement_epargne m JOIN mf.compte_epargne ce ON ce.id = m.compte_id
   WHERE m.date_operation <= p_date AND (p_agence IS NULL OR ce.agence_id = p_agence);

  code := 'credits_sains'; libelle := 'Encours des crédits sains'; inventaire := v_sain;
  comptabilite := mf.solde_comptes(p_agence, p_date, ARRAY['20221','20231','2031','2041']);
  ecart := inventaire - comptabilite; conforme := abs(ecart) <= v_tol; note := 'Crédits non déclassés (capital restant) contre les comptes de crédits sains.'; RETURN NEXT;

  code := 'credits_souffrance'; libelle := 'Encours des crédits en souffrance'; inventaire := v_souf;
  comptabilite := mf.solde_comptes(p_agence, p_date, ARRAY['291','292','293','294']);
  ecart := inventaire - comptabilite; conforme := abs(ecart) <= v_tol; note := 'Crédits déclassés contre les comptes 291 à 294 (le déclassement comptable n''est pas automatisé).'; RETURN NEXT;

  code := 'provisions'; libelle := 'Provisions sur crédits en souffrance'; inventaire := v_prov;
  comptabilite := -mf.solde_comptes(p_agence, p_date, ARRAY['299']);
  ecart := inventaire - comptabilite; conforme := abs(ecart) <= v_tol; note := 'Provision retenue (module Provisions) contre les comptes 299.'; RETURN NEXT;

  code := 'epargne'; libelle := 'Épargne classique'; inventaire := v_epargne;
  comptabilite := -mf.solde_comptes(p_agence, p_date, ARRAY['2511','2521','2531']);
  ecart := inventaire - comptabilite; conforme := abs(ecart) <= v_tol; note := 'Soldes des comptes d''épargne contre les comptes 2511, 2521 et 2531. La tontine n''est pas rapprochée.'; RETURN NEXT;
END $$;

-- Validation du rapprochement par le comptable (conservée, non modifiable)
CREATE TABLE rapprochement_validation (
  id            serial PRIMARY KEY,
  agence_id     smallint NOT NULL REFERENCES agence(id),
  date_arrete   date NOT NULL,
  statut        varchar(15) NOT NULL CHECK (statut IN ('conforme','ecart_justifie')),
  ecart_total   numeric NOT NULL,                      -- somme des écarts en valeur absolue au moment de la validation
  justification text,
  valide_par    integer REFERENCES utilisateur(id),
  cree_le       timestamptz NOT NULL DEFAULT now(),
  CHECK (statut = 'conforme' OR (justification IS NOT NULL AND btrim(justification) <> ''))
);
CREATE INDEX rapprochement_validation_idx ON rapprochement_validation (agence_id, date_arrete DESC, id DESC);
CREATE TRIGGER rapprochement_validation_ajout_seul BEFORE UPDATE OR DELETE ON rapprochement_validation FOR EACH ROW EXECUTE FUNCTION trg_ajout_seul();
CREATE TRIGGER audit_rapprochement_validation AFTER INSERT ON rapprochement_validation FOR EACH ROW EXECUTE FUNCTION trg_audit();

CREATE FUNCTION valider_rapprochement(p_agence smallint, p_date date, p_utilisateur integer DEFAULT NULL, p_justification text DEFAULT NULL) RETURNS integer
LANGUAGE plpgsql AS $$
DECLARE v_ecart numeric; v_statut text; v_id integer;
BEGIN
  IF p_agence IS NULL THEN RAISE EXCEPTION 'agence obligatoire : le rapprochement se valide agence par agence'; END IF;
  IF p_date > current_date THEN RAISE EXCEPTION 'date d''arrêté dans le futur'; END IF;
  SELECT COALESCE(sum(abs(r.ecart)), 0), CASE WHEN bool_and(r.conforme) THEN 'conforme' ELSE 'ecart_justifie' END
    INTO v_ecart, v_statut FROM mf.rapprochement(p_agence, p_date) r;
  IF v_statut = 'ecart_justifie' AND (p_justification IS NULL OR btrim(p_justification) = '') THEN
    RAISE EXCEPTION 'écart de % entre fiches et comptabilité : une justification est obligatoire pour valider', v_ecart;
  END IF;
  INSERT INTO mf.rapprochement_validation(agence_id, date_arrete, statut, ecart_total, justification, valide_par)
  VALUES (p_agence, p_date, v_statut, v_ecart, NULLIF(btrim(p_justification), ''), p_utilisateur) RETURNING id INTO v_id;
  RETURN v_id;
END $$;

-- Agences dont le rapprochement n'est pas validé à la date (avant consolidation) : dernière validation du jour, avec son statut
CREATE FUNCTION etat_rapprochement_agences(p_date date)
RETURNS TABLE (agence_id smallint, agence text, validee boolean, statut text, ecart_total numeric, valide_le timestamptz)
LANGUAGE sql STABLE AS $$
  SELECT a.id, a.code::text, (v.id IS NOT NULL), v.statut::text, v.ecart_total, v.cree_le
    FROM mf.agence a
    LEFT JOIN LATERAL (SELECT * FROM mf.rapprochement_validation x WHERE x.agence_id = a.id AND x.date_arrete = p_date ORDER BY x.id DESC LIMIT 1) v ON true
   WHERE a.actif ORDER BY a.code
$$;
