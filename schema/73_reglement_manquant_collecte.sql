-- =====================================================================
-- 73_reglement_manquant_collecte.sql
-- Règlement des manquants de collecte relevés au contrôle au carnet (module 72).
--   * on parcourt les surplus de versement de l'agent (d'abord ceux de la date de la collecte, puis les plus anciens) ;
--   * le manquant est déduit du surplus, sans jamais dépasser le solde disponible ; le surplus est mis à jour ;
--   * le reste, s'il y en a, est imputé à l'agent : débit « manquant_versement » de son compte agent,
--     qui sera déduit automatiquement au virement de salaire (solde négatif du compte agent) ;
--   * un manquant ne se règle qu'une fois.
-- Dépend de : 02 (surplus, compte_agent), 72 (controle_carnet_ligne).
-- =====================================================================
SET search_path = mf, public;

CREATE TABLE reglement_manquant_collecte (
  id                 serial PRIMARY KEY,
  agence_id          smallint NOT NULL REFERENCES agence(id),
  controle_ligne_id  integer NOT NULL UNIQUE REFERENCES controle_carnet_ligne(id),
  agent_id           integer NOT NULL REFERENCES agent(id),
  montant_manquant   numeric(14,0) NOT NULL CHECK (montant_manquant > 0),
  surplus_utilise    numeric(14,0) NOT NULL DEFAULT 0 CHECK (surplus_utilise >= 0),
  impute_agent       numeric(14,0) NOT NULL DEFAULT 0 CHECK (impute_agent >= 0),
  date_reglement     date NOT NULL,
  cree_le            timestamptz NOT NULL DEFAULT now(),
  CHECK (surplus_utilise + impute_agent = montant_manquant)
);

CREATE TRIGGER audit_reglement_manquant_collecte AFTER INSERT ON reglement_manquant_collecte
  FOR EACH ROW EXECUTE FUNCTION trg_audit();
CREATE TRIGGER reglement_manquant_collecte_fige BEFORE UPDATE OR DELETE ON reglement_manquant_collecte
  FOR EACH ROW EXECUTE FUNCTION trg_controle_carnet_fige();

-- Règle le manquant d'une ligne de contrôle. Retourne le montant imputé à l'agent.
CREATE FUNCTION regler_manquant_collecte(p_controle_ligne integer, p_date date DEFAULT current_date) RETURNS numeric
LANGUAGE plpgsql AS $$
DECLARE l mf.controle_carnet_ligne; k mf.controle_carnet; s record; v_reste numeric; v_use numeric; v_utilise numeric := 0; v_impute numeric;
BEGIN
  SELECT * INTO l FROM mf.controle_carnet_ligne WHERE id = p_controle_ligne;
  IF NOT FOUND THEN RAISE EXCEPTION 'ligne de contrôle % inconnue', p_controle_ligne; END IF;
  IF l.ecart <= 0 THEN RAISE EXCEPTION 'la ligne % n''est pas un manquant (écart %)', p_controle_ligne, l.ecart; END IF;
  IF l.agent_id IS NULL THEN RAISE EXCEPTION 'la collecte n''a pas d''agent : manquant non imputable'; END IF;
  IF EXISTS (SELECT 1 FROM mf.reglement_manquant_collecte WHERE controle_ligne_id = p_controle_ligne) THEN
    RAISE EXCEPTION 'manquant de la ligne % déjà réglé', p_controle_ligne;
  END IF;
  SELECT * INTO k FROM mf.controle_carnet WHERE id = l.controle_id;

  v_reste := l.ecart;
  -- le surplus de la date de la collecte d'abord, puis les plus anciens ; jamais au-delà du solde disponible
  FOR s IN SELECT * FROM mf.surplus
            WHERE agent_id = l.agent_id AND statut = 'a_traiter' AND montant > montant_utilise
            ORDER BY (date_surplus = l.date_collecte) DESC, date_surplus, id
            FOR UPDATE LOOP
    EXIT WHEN v_reste <= 0;
    v_use := LEAST(v_reste, s.montant - s.montant_utilise);
    UPDATE mf.surplus
       SET montant_utilise = montant_utilise + v_use,
           statut = CASE WHEN montant_utilise + v_use = montant THEN 'solde' ELSE statut END
     WHERE id = s.id;
    v_reste := v_reste - v_use;
    v_utilise := v_utilise + v_use;
  END LOOP;

  v_impute := v_reste;
  IF v_impute > 0 THEN
    INSERT INTO mf.compte_agent(agence_id, agent_id, type, montant, date_operation, libelle, reference)
    VALUES (k.agence_id, l.agent_id, 'manquant_versement', v_impute, p_date,
            'Manquant de collecte du ' || l.date_collecte, 'manquant_collecte:' || p_controle_ligne);
  END IF;

  INSERT INTO mf.reglement_manquant_collecte(agence_id, controle_ligne_id, agent_id, montant_manquant, surplus_utilise, impute_agent, date_reglement)
  VALUES (k.agence_id, p_controle_ligne, l.agent_id, l.ecart, v_utilise, v_impute, p_date);
  RETURN v_impute;
END $$;

-- Règle tous les manquants d'un contrôle au carnet, ligne par ligne. Retourne le total imputé à l'agent.
CREATE FUNCTION regler_manquants_controle(p_controle integer, p_date date DEFAULT current_date) RETURNS numeric
LANGUAGE plpgsql AS $$
DECLARE l record; v_total numeric := 0;
BEGIN
  FOR l IN SELECT id FROM mf.controle_carnet_ligne
            WHERE controle_id = p_controle AND ecart > 0
              AND id NOT IN (SELECT controle_ligne_id FROM mf.reglement_manquant_collecte)
            ORDER BY id LOOP
    v_total := v_total + regler_manquant_collecte(l.id, p_date);
  END LOOP;
  RETURN v_total;
END $$;
