-- =====================================================================
-- 76_caisse_flux_tontine.sql
-- Flux tontine en espèces : tout argent remis par un agent passe par une session de caisse.
--   * versement de tournée : enregistrer_versement + encaissement en caisse, dans la même opération ;
--   * règlement en numéraire d'un manquant de versement : regler_compte_agent + encaissement, plafonné à la dette.
--   * session : celle qui est choisie, ou l'unique session ouverte de l'agence ; sinon refus.
--   * un refus n'écrit rien (une seule fonction de l'opération, rollback complet).
-- Hors caisse (inchangés) : collecte, retrait, règlement d'un manquant par surplus, règlement par salaire.
-- Dépend de : 02 (enregistrer_versement, compte_agent), 03 (session_caisse, caisse_operation), 13 (sessions).
-- =====================================================================
SET search_path = mf, public;

-- Session qui reçoit des espèces pour une agence.
CREATE FUNCTION session_especes_agence(p_agence smallint, p_session integer DEFAULT NULL) RETURNS integer
LANGUAGE plpgsql AS $$
DECLARE v_ids integer[];
BEGIN
  IF p_session IS NOT NULL THEN
    PERFORM 1 FROM mf.session_caisse s JOIN mf.caisse k ON k.id = s.caisse_id
     WHERE s.id = p_session AND k.agence_id = p_agence AND s.statut = 'ouverte';
    IF NOT FOUND THEN RAISE EXCEPTION 'session de caisse % ouverte introuvable pour cette agence', p_session; END IF;
    RETURN p_session;
  END IF;
  SELECT array_agg(s.id) INTO v_ids
    FROM mf.session_caisse s JOIN mf.caisse k ON k.id = s.caisse_id
   WHERE k.agence_id = p_agence AND s.statut = 'ouverte';
  IF COALESCE(array_length(v_ids, 1), 0) <> 1 THEN
    RAISE EXCEPTION 'choisissez la session de caisse qui reçoit les espèces (aucune ou plusieurs ouvertes)';
  END IF;
  RETURN v_ids[1];
END $$;

-- Fin de tournée : enregistre le versement et, s'il y a de l'argent, son encaissement en caisse.
CREATE FUNCTION versement_tournee_caisse(p_agent integer, p_date date, p_verse numeric, p_utilisateur integer DEFAULT NULL,
                                         p_session integer DEFAULT NULL) RETURNS integer
LANGUAGE plpgsql AS $$
DECLARE a mf.agent; v_session integer; v_id integer;
BEGIN
  SELECT * INTO a FROM mf.agent WHERE id = p_agent;
  IF NOT FOUND THEN RAISE EXCEPTION 'agent % inconnu', p_agent; END IF;
  IF COALESCE(p_verse, 0) > 0 THEN
    v_session := session_especes_agence(a.agence_id, p_session);
  END IF;
  v_id := enregistrer_versement(p_agent, p_date, p_verse, p_utilisateur);
  IF v_session IS NOT NULL THEN
    PERFORM caisse_operation(v_session, 'encaissement', 'versement_agent', p_verse, p_date,
                             'versement_agent', v_id, 'Versement de tournée de ' || a.nom);
  END IF;
  RETURN v_id;
END $$;

-- Règlement en numéraire de la dette d'un agent (manquant de versement ou de collecte imputé) : compte agent + caisse.
CREATE FUNCTION reglement_agent_especes(p_agent integer, p_montant numeric, p_date date DEFAULT current_date,
                                        p_session integer DEFAULT NULL) RETURNS void
LANGUAGE plpgsql AS $$
DECLARE a mf.agent; v_session integer; v_dette numeric;
BEGIN
  SELECT * INTO a FROM mf.agent WHERE id = p_agent;
  IF NOT FOUND THEN RAISE EXCEPTION 'agent % inconnu', p_agent; END IF;
  SELECT GREATEST(-solde, 0) INTO v_dette FROM mf.v_solde_compte_agent WHERE agent_id = p_agent;
  IF COALESCE(p_montant, 0) > COALESCE(v_dette, 0) THEN
    RAISE EXCEPTION 'montant supérieur à la dette de l''agent (%)', COALESCE(v_dette, 0);
  END IF;
  v_session := session_especes_agence(a.agence_id, p_session);
  PERFORM regler_compte_agent(p_agent, p_montant, p_date, 'Règlement en numéraire de la dette d''agent');
  PERFORM caisse_operation(v_session, 'encaissement', 'reglement_manquant', p_montant, p_date,
                           'agent', p_agent, 'Manquant de versement réglé par ' || a.nom);
END $$;
