SET search_path = mf, public;

-- =====================================================================
-- 59 : retraits partiels de tontine
--   * retrait d'urgence pendant la collecte : le cycle reste en cours, il n'est pas clôturé ;
--   * retrait partiel après clôture : le reste du solde reste sur le cycle ;
--   * le cycle n'est « retiré » que lorsque le solde disponible est nul.
-- Solde disponible = net du cycle (collecté - mise) - retraits de solde non annulés.
-- =====================================================================

-- Un seul retrait de solde actif par cycle n'a plus de sens : plusieurs retraits partiels sont possibles.
DROP INDEX IF EXISTS mf.retrait_un_actif_par_cycle;

CREATE FUNCTION solde_disponible_cycle(p_cycle integer) RETURNS numeric
LANGUAGE sql STABLE AS $$
  SELECT COALESCE(s.net, 0) - COALESCE((
           SELECT sum(r.montant) FROM mf.retrait r
            WHERE r.cycle_id = p_cycle AND r.statut <> 'annule'
              AND r.nature IN ('retrait_client','virement_vers_epargne')), 0)
    FROM mf.v_cycle_situation s WHERE s.cycle_id = p_cycle
$$;

-- Remplace la version à trois paramètres : le montant est optionnel (null = solde disponible entier).
-- Un retrait qui vide le solde clôt le cycle s'il est encore en cours ; un retrait partiel ne le clôt pas.
DROP FUNCTION demander_retrait_cycle(integer, text, date);

CREATE FUNCTION demander_retrait_cycle(p_cycle integer, p_nature text DEFAULT 'retrait_client',
                                       p_date date DEFAULT current_date, p_montant numeric DEFAULT NULL) RETURNS integer
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
  IF c.statut = 'en_cours' AND v_montant = v_solde THEN PERFORM mf.cloturer_cycle(p_cycle, p_date); END IF;
  INSERT INTO mf.retrait(agence_id, cycle_id, nature, montant, decaissement, date_demande)
  VALUES (c.agence_id, p_cycle, p_nature, v_montant, p_nature = 'retrait_client', p_date)
  RETURNING id INTO v_id;
  RETURN v_id;
END $$;

-- L'exécution ne retire le cycle que si son solde disponible est épuisé.
CREATE OR REPLACE FUNCTION executer_retrait(p_retrait integer, p_date date DEFAULT NULL, p_session integer DEFAULT NULL)
RETURNS void LANGUAGE plpgsql AS $$
DECLARE r mf.retrait; v_date date; v_paye numeric;
BEGIN
  SELECT * INTO r FROM mf.retrait WHERE id = p_retrait FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'retrait % inconnu', p_retrait; END IF;
  IF r.statut <> 'fonds_disponibles' THEN
    RAISE EXCEPTION 'retrait % non exécutable (statut %) : constater ou traiter les écarts d''abord', p_retrait, r.statut;
  END IF;
  v_date := COALESCE(p_date, r.date_demande);
  v_paye := CASE WHEN r.nature = 'remboursement' THEN r.montant ELSE r.montant + r.ecart END;
  IF v_paye < 0 THEN RAISE EXCEPTION 'montant à payer négatif (%)', v_paye; END IF;

  UPDATE mf.retrait SET montant_paye = v_paye, statut = 'execute', date_operation = v_date, execute_le = now()
   WHERE id = p_retrait;
  IF r.nature IN ('retrait_client','virement_vers_epargne') AND mf.solde_disponible_cycle(r.cycle_id) <= 0 THEN
    UPDATE mf.cycle SET statut = 'retire' WHERE id = r.cycle_id;
  END IF;

  IF r.nature = 'virement_vers_epargne' THEN
    PERFORM mf.exec_virement_vers_epargne(p_retrait);
  ELSIF r.nature = 'remboursement' THEN
    PERFORM mf.exec_remboursement(p_retrait);
  ELSIF r.nature = 'retrait_client' AND r.decaissement AND p_session IS NOT NULL AND v_paye > 0 THEN
    PERFORM mf.caisse_operation(p_session, 'decaissement', 'retrait_client', v_paye, v_date, 'retrait', p_retrait);
  END IF;
END $$;
