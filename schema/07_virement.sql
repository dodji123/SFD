-- =====================================================================
-- 07_virement.sql
-- Virements entre épargne tontine (cycle) et épargne classique (compte).
-- Règles : BRIEF_CLAUDE_CODE.md section 3.5.
--   Tontine -> épargne : retrait de cycle sans décaissement, même circuit d'écarts ; le compte est crédité
--     selon le livret (montant +/- écart) ; le cycle passe à « retiré ».
--   Épargne -> tontine : lignes de livret d'origine « virement », sans agent. Types 1 et 2 : montant multiple
--     de la mise, une ligne par mise. Type 3 : une ligne. Même client obligatoire.
-- Dépend de : 00 à 03 (retrait, exécution, mouvements d'épargne).
-- =====================================================================
SET search_path = mf, public;

CREATE TABLE virement (
  id              serial PRIMARY KEY,
  agence_id       smallint NOT NULL REFERENCES agence(id),
  sens            varchar(20) NOT NULL CHECK (sens IN ('cycle_vers_epargne','epargne_vers_cycle')),
  cycle_id        integer NOT NULL REFERENCES cycle(id),
  compte_id       integer NOT NULL REFERENCES compte_epargne(id),
  montant         numeric(14,0) NOT NULL CHECK (montant > 0),   -- net machine (cycle -> épargne) ou montant viré
  montant_credite numeric(14,0),                                -- crédité sur le compte (selon le livret)
  statut          varchar(10) NOT NULL DEFAULT 'demande' CHECK (statut IN ('demande','execute','annule')),
  retrait_id      integer REFERENCES retrait(id),
  date_operation  date,
  utilisateur_id  integer REFERENCES utilisateur(id),
  cree_le         timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX virement_cycle ON virement (cycle_id);
CREATE UNIQUE INDEX virement_retrait ON virement (retrait_id) WHERE retrait_id IS NOT NULL;

-- Épargne classique -> tontine. Retourne l'id du virement.
CREATE FUNCTION virement_epargne_vers_tontine(p_compte integer, p_cycle integer, p_montant numeric,
                                              p_date date DEFAULT current_date,
                                              p_utilisateur integer DEFAULT NULL) RETURNS integer
LANGUAGE plpgsql AS $$
DECLARE c mf.cycle; ce mf.compte_epargne; v_mise numeric; v_n integer; v_nb integer; v_idx integer;
        v_id integer; v_k integer; v_montant_ligne numeric;
BEGIN
  SELECT * INTO c FROM mf.cycle WHERE id = p_cycle FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'cycle % inconnu', p_cycle; END IF;
  SELECT * INTO ce FROM mf.compte_epargne WHERE id = p_compte;
  IF NOT FOUND THEN RAISE EXCEPTION 'compte % inconnu', p_compte; END IF;
  IF ce.client_id <> c.client_id THEN RAISE EXCEPTION 'le compte % n''appartient pas au client du cycle %', ce.numero, c.numero; END IF;
  IF c.statut <> 'en_cours' THEN RAISE EXCEPTION 'cycle % non en cours', c.numero; END IF;
  IF p_montant <= 0 THEN RAISE EXCEPTION 'montant invalide'; END IF;

  IF c.type_cycle = 3 THEN
    v_n := 1; v_montant_ligne := p_montant;
  ELSE
    v_mise := mf.mise_a_date(p_cycle, p_date);
    IF mod(p_montant, v_mise) <> 0 THEN
      RAISE EXCEPTION 'le montant % n''est pas un multiple de la mise (%)', p_montant, v_mise;
    END IF;
    v_n := (p_montant / v_mise)::integer; v_montant_ligne := v_mise;
  END IF;
  SELECT count(*) INTO v_nb FROM mf.ligne_collecte WHERE cycle_id = p_cycle;
  IF v_nb + v_n > c.nb_lignes_prevues THEN
    RAISE EXCEPTION 'le livret n''a plus assez de lignes libres (% prévues, % utilisées, % demandées)', c.nb_lignes_prevues, v_nb, v_n;
  END IF;

  INSERT INTO mf.virement(agence_id, sens, cycle_id, compte_id, montant, montant_credite, statut, date_operation, utilisateur_id)
  VALUES (c.agence_id, 'epargne_vers_cycle', p_cycle, p_compte, p_montant, p_montant, 'execute', p_date, p_utilisateur)
  RETURNING id INTO v_id;

  -- sortie du compte d'abord : le contrôle du disponible refuse si les fonds manquent
  INSERT INTO mf.mouvement_epargne(compte_id, type, montant, date_operation, libelle, reference)
  VALUES (p_compte, 'virement_sortant', p_montant, p_date, 'Virement vers cycle ' || c.numero, 'virement:' || v_id);

  SELECT COALESCE(max((page - 1) * 31 + no_ligne), 0) INTO v_idx FROM mf.ligne_collecte WHERE cycle_id = p_cycle;
  FOR v_k IN 1..v_n LOOP
    v_idx := v_idx + 1;
    INSERT INTO mf.ligne_collecte(cycle_id, page, no_ligne, date_collecte, agent_id, origine, montant_collecte)
    VALUES (p_cycle, (v_idx - 1) / 31 + 1, (v_idx - 1) % 31 + 1, p_date, NULL, 'virement', v_montant_ligne);
  END LOOP;
  RETURN v_id;
END $$;

-- Tontine -> épargne classique : crée la demande de retrait (sans décaissement) et le virement associé.
-- Le circuit se poursuit comme tout retrait : constater_sans_ecart ou enregistrer_ecart_retrait / traiter,
-- puis executer_retrait.
CREATE FUNCTION demander_virement_cycle_vers_epargne(p_cycle integer, p_compte integer,
                                                     p_utilisateur integer DEFAULT NULL,
                                                     p_date date DEFAULT current_date) RETURNS integer
LANGUAGE plpgsql AS $$
DECLARE c mf.cycle; ce mf.compte_epargne; v_retrait integer; v_montant numeric; v_id integer;
BEGIN
  SELECT * INTO c FROM mf.cycle WHERE id = p_cycle FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'cycle % inconnu', p_cycle; END IF;
  SELECT * INTO ce FROM mf.compte_epargne WHERE id = p_compte;
  IF NOT FOUND THEN RAISE EXCEPTION 'compte % inconnu', p_compte; END IF;
  IF ce.client_id <> c.client_id THEN RAISE EXCEPTION 'le compte % n''appartient pas au client du cycle %', ce.numero, c.numero; END IF;
  IF ce.statut <> 'actif' THEN RAISE EXCEPTION 'compte % non actif', ce.numero; END IF;
  v_retrait := mf.demander_retrait_cycle(p_cycle, 'virement_vers_epargne', p_date);
  SELECT montant INTO v_montant FROM mf.retrait WHERE id = v_retrait;
  IF v_montant <= 0 THEN RAISE EXCEPTION 'rien à virer : net du cycle nul'; END IF;
  INSERT INTO mf.virement(agence_id, sens, cycle_id, compte_id, montant, statut, retrait_id, utilisateur_id)
  VALUES (c.agence_id, 'cycle_vers_epargne', p_cycle, p_compte, v_montant, 'demande', v_retrait, p_utilisateur)
  RETURNING id INTO v_id;
  RETURN v_id;
END $$;

-- Appelée par executer_retrait (02) : crédite le compte selon le livret.
CREATE FUNCTION exec_virement_vers_epargne(p_retrait integer) RETURNS void
LANGUAGE plpgsql AS $$
DECLARE r mf.retrait; v mf.virement;
BEGIN
  SELECT * INTO r FROM mf.retrait WHERE id = p_retrait;
  SELECT * INTO v FROM mf.virement WHERE retrait_id = p_retrait FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'aucun virement lié au retrait %', p_retrait; END IF;
  IF r.montant_paye > 0 THEN
    INSERT INTO mf.mouvement_epargne(compte_id, type, montant, date_operation, libelle, reference)
    VALUES (v.compte_id, 'virement_entrant', r.montant_paye, r.date_operation,
            'Virement du cycle ' || (SELECT numero FROM mf.cycle WHERE id = r.cycle_id), 'virement:' || v.id);
  END IF;
  UPDATE mf.virement SET montant_credite = r.montant_paye, statut = 'execute', date_operation = r.date_operation WHERE id = v.id;
END $$;
