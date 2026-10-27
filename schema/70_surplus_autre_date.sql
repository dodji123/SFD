-- =====================================================================
-- 70_surplus_autre_date.sql
-- Règlement d'un écart de retrait par un surplus d'une AUTRE date, sur validation du chef d'agence.
--   * par défaut, un écart ne se règle que par le surplus de sa date exacte (module 02) ;
--   * le chef d'agence peut autoriser, détail d'écart par détail d'écart, l'usage d'un surplus d'une autre date
--     du même agent ; la validation est motivée, tracée (piste d'audit) et ne se supprime pas ;
--   * traiter_ecart_retrait consomme d'abord le surplus de la date exacte, puis les validations ;
--     le reste est une perte de l'agent (compte agent).
-- Remplace traiter_ecart_retrait du module 02 (même signature), en y ajoutant l'étape des validations.
-- Dépend de : 02 (surplus, ecart_retrait, ecart_retrait_date), 10 (trg_audit), 11 (utilisateur).
-- =====================================================================
SET search_path = mf, public;

CREATE TABLE validation_surplus_autre_date (
  id            serial PRIMARY KEY,
  agence_id     smallint NOT NULL REFERENCES agence(id),
  ecart_date_id integer NOT NULL REFERENCES ecart_retrait_date(id),
  surplus_id    integer NOT NULL REFERENCES surplus(id),
  montant       numeric(14,0) NOT NULL CHECK (montant > 0),
  consomme      numeric(14,0) NOT NULL DEFAULT 0 CHECK (consomme BETWEEN 0 AND montant),
  motif         text NOT NULL CHECK (length(btrim(motif)) >= 5),
  valide_par    integer NOT NULL REFERENCES utilisateur(id),
  valide_le     timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX validation_surplus_detail_idx ON validation_surplus_autre_date (ecart_date_id);
CREATE INDEX validation_surplus_surplus_idx ON validation_surplus_autre_date (surplus_id);
COMMENT ON TABLE validation_surplus_autre_date IS 'Autorisation du chef d''agence : régler un détail d''écart de retrait par le surplus d''une autre date du même agent.';

CREATE FUNCTION trg_validation_surplus_suppression() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  RAISE EXCEPTION 'Une validation de surplus ne se supprime pas : elle reste dans la piste d''audit';
END $$;
CREATE TRIGGER validation_surplus_ni_suppression BEFORE DELETE ON validation_surplus_autre_date
  FOR EACH ROW EXECUTE FUNCTION trg_validation_surplus_suppression();
CREATE TRIGGER audit_validation_surplus_autre_date AFTER INSERT OR UPDATE OR DELETE ON validation_surplus_autre_date
  FOR EACH ROW EXECUTE FUNCTION trg_audit();

-- Validation par le chef d'agence. Retourne l'identifiant de la validation.
CREATE FUNCTION valider_surplus_autre_date(p_ecart_date integer, p_surplus integer, p_montant numeric,
                                           p_chef integer, p_motif text) RETURNS integer
LANGUAGE plpgsql AS $$
DECLARE d record; s mf.surplus; u mf.utilisateur; v_libre numeric; v_besoin numeric; v_id integer;
BEGIN
  SELECT dt.*, e.agence_id, e.statut AS statut_ecart INTO d
    FROM mf.ecart_retrait_date dt JOIN mf.ecart_retrait e ON e.id = dt.ecart_id
   WHERE dt.id = p_ecart_date;
  IF NOT FOUND THEN RAISE EXCEPTION 'détail d''écart % inconnu', p_ecart_date; END IF;
  IF d.statut_ecart = 'traite' THEN RAISE EXCEPTION 'écart déjà traité : plus de validation possible'; END IF;

  SELECT * INTO u FROM mf.utilisateur WHERE id = p_chef;
  IF NOT FOUND OR u.role <> 'chef_agence' OR u.agence_id IS DISTINCT FROM d.agence_id THEN
    RAISE EXCEPTION 'seul le chef d''agence de l''agence peut valider un surplus d''une autre date';
  END IF;
  IF length(btrim(COALESCE(p_motif, ''))) < 5 THEN RAISE EXCEPTION 'la validation doit être motivée'; END IF;
  IF p_montant IS NULL OR p_montant <= 0 THEN RAISE EXCEPTION 'montant de validation invalide'; END IF;

  SELECT * INTO s FROM mf.surplus WHERE id = p_surplus FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'surplus % inconnu', p_surplus; END IF;
  IF s.agent_id <> d.agent_id THEN RAISE EXCEPTION 'le surplus appartient à un autre agent'; END IF;
  IF s.date_surplus = d.date_ecart THEN
    RAISE EXCEPTION 'surplus de la même date : il s''utilise directement, sans validation';
  END IF;
  IF s.statut <> 'a_traiter' THEN RAISE EXCEPTION 'surplus déjà soldé'; END IF;

  v_libre := s.montant - s.montant_utilise
           - COALESCE((SELECT sum(v.montant - v.consomme) FROM mf.validation_surplus_autre_date v WHERE v.surplus_id = s.id), 0);
  IF p_montant > v_libre THEN RAISE EXCEPTION 'surplus disponible insuffisant (%)', v_libre; END IF;

  v_besoin := d.montant
            - COALESCE((SELECT sum(v.montant - v.consomme) FROM mf.validation_surplus_autre_date v WHERE v.ecart_date_id = d.id), 0);
  IF p_montant > v_besoin THEN RAISE EXCEPTION 'montant supérieur au reste à régler de ce détail (%)', v_besoin; END IF;

  INSERT INTO mf.validation_surplus_autre_date(agence_id, ecart_date_id, surplus_id, montant, motif, valide_par)
  VALUES (d.agence_id, d.id, s.id, p_montant, p_motif, p_chef)
  RETURNING id INTO v_id;
  RETURN v_id;
END $$;

-- Traitement d'un écart livret > machine, date par date : surplus de la date exacte, puis surplus d'autres dates validés,
-- le reste est une perte imputée à l'agent. Retourne la perte totale imputée aux agents.
CREATE OR REPLACE FUNCTION traiter_ecart_retrait(p_ecart integer, p_date date DEFAULT NULL) RETURNS numeric
LANGUAGE plpgsql AS $$
DECLARE e mf.ecart_retrait; r mf.retrait; d record; s record; v record; v_date date;
        v_reste numeric; v_util numeric; v_use numeric; v_perte numeric := 0;
BEGIN
  SELECT * INTO e FROM mf.ecart_retrait WHERE id = p_ecart FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'écart % inconnu', p_ecart; END IF;
  IF e.statut = 'traite' THEN RAISE EXCEPTION 'écart % déjà traité', p_ecart; END IF;
  SELECT * INTO r FROM mf.retrait WHERE id = e.retrait_id FOR UPDATE;
  v_date := COALESCE(p_date, r.date_demande);

  FOR d IN SELECT * FROM mf.ecart_retrait_date WHERE ecart_id = p_ecart ORDER BY date_ecart, id LOOP
    v_reste := d.montant; v_util := 0;

    -- 1. surplus de la date exacte
    FOR s IN SELECT * FROM mf.surplus
              WHERE agent_id = d.agent_id AND date_surplus = d.date_ecart AND statut = 'a_traiter'
              ORDER BY id FOR UPDATE LOOP
      EXIT WHEN v_reste <= 0;
      v_use := LEAST(v_reste, s.montant - s.montant_utilise);
      UPDATE mf.surplus
         SET montant_utilise = montant_utilise + v_use,
             statut = CASE WHEN montant_utilise + v_use = montant THEN 'solde' ELSE statut END
       WHERE id = s.id;
      v_reste := v_reste - v_use; v_util := v_util + v_use;
    END LOOP;

    -- 2. surplus d'autres dates, autorisés par le chef d'agence
    FOR v IN SELECT * FROM mf.validation_surplus_autre_date
              WHERE ecart_date_id = d.id AND consomme < montant
              ORDER BY id FOR UPDATE LOOP
      EXIT WHEN v_reste <= 0;
      SELECT * INTO s FROM mf.surplus WHERE id = v.surplus_id FOR UPDATE;
      v_use := LEAST(v_reste, v.montant - v.consomme, s.montant - s.montant_utilise);
      CONTINUE WHEN v_use <= 0;
      UPDATE mf.surplus
         SET montant_utilise = montant_utilise + v_use,
             statut = CASE WHEN montant_utilise + v_use = montant THEN 'solde' ELSE statut END
       WHERE id = s.id;
      UPDATE mf.validation_surplus_autre_date SET consomme = consomme + v_use WHERE id = v.id;
      v_reste := v_reste - v_use; v_util := v_util + v_use;
    END LOOP;

    -- 3. le reste est une perte de l'agent
    IF v_reste > 0 THEN
      INSERT INTO mf.compte_agent(agence_id, agent_id, type, montant, date_operation, libelle, reference)
      VALUES (e.agence_id, d.agent_id, 'perte_retrait', v_reste, v_date,
              'Perte sur retrait, collecte du ' || d.date_ecart, 'ecart_retrait:' || p_ecart);
    END IF;
    UPDATE mf.ecart_retrait_date SET surplus_utilise = v_util, perte = v_reste WHERE id = d.id;
    v_perte := v_perte + v_reste;
  END LOOP;

  UPDATE mf.ecart_retrait SET statut = 'traite', traite_le = v_date WHERE id = p_ecart;
  UPDATE mf.retrait SET statut = 'fonds_disponibles' WHERE id = e.retrait_id;
  RETURN v_perte;
END $$;
