SET search_path = mf, public;

-- =====================================================================
-- 61 : retrait partiel avec choix de clôture
--   * cycle en cours, retrait total          : cycle clôturé puis retiré à l'exécution ;
--   * cycle en cours, retrait partiel        : cycle clôturé seulement si demandé (p_cloturer) ;
--   * cycle clôturé, retrait partiel ou total : le cycle reste clôturé ; retiré à l'épuisement du solde.
-- =====================================================================
DROP FUNCTION demander_retrait_cycle(integer, text, date, numeric);

CREATE FUNCTION demander_retrait_cycle(p_cycle integer, p_nature text DEFAULT 'retrait_client',
                                       p_date date DEFAULT current_date, p_montant numeric DEFAULT NULL,
                                       p_cloturer boolean DEFAULT NULL) RETURNS integer
LANGUAGE plpgsql AS $$
DECLARE c mf.cycle; v_solde numeric; v_montant numeric; v_id integer;
BEGIN
  SELECT * INTO c FROM mf.cycle WHERE id = p_cycle FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'cycle % inconnu', p_cycle; END IF;
  IF c.statut = 'retire' THEN RAISE EXCEPTION 'cycle % déjà retiré', c.numero; END IF;
  v_solde := mf.solde_disponible_cycle(p_cycle);
  v_montant := COALESCE(p_montant, v_solde);
  IF v_montant <= 0 THEN RAISE EXCEPTION 'rien à retirer sur le cycle % (solde disponible %)', c.numero, v_solde; END IF;
  IF v_montant > v_solde THEN
    RAISE EXCEPTION 'montant % supérieur au solde disponible % du cycle %', v_montant, v_solde, c.numero;
  END IF;
  IF c.statut = 'en_cours' AND (v_montant = v_solde OR COALESCE(p_cloturer, false)) THEN
    PERFORM mf.cloturer_cycle(p_cycle, p_date);
  END IF;
  INSERT INTO mf.retrait(agence_id, cycle_id, nature, montant, decaissement, date_demande)
  VALUES (c.agence_id, p_cycle, p_nature, v_montant, p_nature = 'retrait_client', p_date)
  RETURNING id INTO v_id;
  RETURN v_id;
END $$;
