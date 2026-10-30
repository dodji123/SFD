-- =====================================================================
-- 77_caisse_epargne.sql
-- Dépôts et retraits d'épargne au guichet : espèces, donc en caisse.
--   * dépôt : mouvement_epargne (depot) + encaissement en caisse ;
--   * retrait : mouvement_epargne (retrait) + décaissement en caisse (refusé si la caisse ne suffit pas) ;
--   * session : celle de la caissière (module 76), dans la même opération ; sinon refus, rien n'est écrit.
-- Dépend de : 01 (compte_epargne, mouvement_epargne), 03 (caisse_operation), 76 (session_especes_agence).
-- =====================================================================
SET search_path = mf, public;

CREATE FUNCTION mouvement_epargne_especes(p_compte integer, p_type text, p_montant numeric, p_date date DEFAULT current_date,
                                          p_libelle text DEFAULT NULL, p_procuration integer DEFAULT NULL,
                                          p_utilisateur integer DEFAULT NULL, p_session integer DEFAULT NULL) RETURNS bigint
LANGUAGE plpgsql AS $$
DECLARE ce mf.compte_epargne; v_session integer; v_id bigint; v_sens text;
BEGIN
  IF p_type NOT IN ('depot', 'retrait') THEN
    RAISE EXCEPTION 'type de mouvement en espèces inconnu : %', p_type;
  END IF;
  SELECT * INTO ce FROM mf.compte_epargne WHERE id = p_compte;
  IF NOT FOUND THEN RAISE EXCEPTION 'compte d''épargne % inconnu', p_compte; END IF;
  -- session choisie explicitement par la caissière (pas de sélection automatique pour l'épargne)
  IF p_session IS NULL THEN RAISE EXCEPTION 'choisissez la session de caisse pour ce dépôt ou retrait en espèces'; END IF;
  v_session := session_especes_agence(ce.agence_id, p_utilisateur, p_session);

  INSERT INTO mf.mouvement_epargne(compte_id, type, montant, date_operation, libelle, procuration_id)
  VALUES (p_compte, p_type, p_montant, p_date, p_libelle, p_procuration)
  RETURNING id INTO v_id;

  v_sens := CASE WHEN p_type = 'depot' THEN 'encaissement' ELSE 'decaissement' END;
  PERFORM caisse_operation(v_session, v_sens, 'epargne_' || p_type, p_montant, p_date,
                           'mouvement_epargne', v_id, COALESCE(p_libelle, 'Épargne : ' || p_type));
  RETURN v_id;
END $$;
