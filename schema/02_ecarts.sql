-- =====================================================================
-- 02_ecarts.sql
-- Compte agent, versements de fin de tournée, surplus, écarts de retrait
-- (livret > machine, machine > livret), excédents à régulariser, purge de date,
-- constat / traitement / exécution des retraits.
-- Règles : BRIEF_CLAUDE_CODE.md section 3.3 (et 3.5 pour le circuit de retrait).
-- Dépend de : 00, 01.  L'exécution d'un retrait appelle, au besoin, des fonctions
-- définies plus loin (liaison tardive plpgsql) : exec_remboursement (03),
-- exec_virement_vers_epargne (07), caisse_operation (03).
-- =====================================================================
SET search_path = mf, public;

-- Le retrait porte le montant selon le livret et le montant réellement payé.
ALTER TABLE retrait
  ADD COLUMN montant_livret numeric(14,0),                   -- net selon le livret = montant + ecart
  ADD COLUMN montant_paye   numeric(14,0),                   -- net réellement payé / crédité
  ADD COLUMN ecart          numeric(14,0) NOT NULL DEFAULT 0; -- livret - machine (signé)

-- ---------------------------------------------------------------------
-- Compte de l'agent : manquants et pertes (débit), versements et retenues (crédit)
-- ---------------------------------------------------------------------
CREATE TABLE compte_agent (
  id             bigserial PRIMARY KEY,
  agence_id      smallint NOT NULL REFERENCES agence(id),
  agent_id       integer NOT NULL REFERENCES agent(id),
  type           varchar(30) NOT NULL CHECK (type IN
                   ('manquant_versement','perte_retrait','correction_debit',
                    'versement','retenue_commission','correction_credit')),
  montant        numeric(14,0) NOT NULL CHECK (montant > 0),
  date_operation date NOT NULL,
  libelle        text,
  reference      text,
  cree_le        timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX compte_agent_agent ON compte_agent (agent_id, date_operation);

-- +1 crédit (réduit la dette), -1 débit (la creuse)
CREATE FUNCTION sens_compte_agent(p_type text) RETURNS smallint
LANGUAGE sql IMMUTABLE AS $$
  SELECT CASE WHEN p_type IN ('manquant_versement','perte_retrait','correction_debit') THEN -1 ELSE 1 END::smallint
$$;

-- solde < 0 : l'agent doit de l'argent à l'institution
CREATE VIEW v_solde_compte_agent AS
SELECT a.id AS agent_id, a.agence_id, a.matricule, a.nom,
       COALESCE(sum(c.montant * mf.sens_compte_agent(c.type)), 0)::numeric(14,0) AS solde
  FROM agent a LEFT JOIN compte_agent c ON c.agent_id = a.id
 GROUP BY a.id;

-- ---------------------------------------------------------------------
-- Versements de fin de tournée et surplus
-- ---------------------------------------------------------------------
CREATE TABLE versement_agent (
  id               serial PRIMARY KEY,
  agence_id        smallint NOT NULL REFERENCES agence(id),
  agent_id         integer NOT NULL REFERENCES agent(id),
  date_tournee     date NOT NULL,
  montant_collecte numeric(14,0) NOT NULL,       -- saisie du jour
  montant_verse    numeric(14,0) NOT NULL CHECK (montant_verse >= 0),
  ecart            numeric(14,0) NOT NULL,       -- collecté - versé (> 0 : manquant)
  utilisateur_id   integer REFERENCES utilisateur(id),
  cree_le          timestamptz NOT NULL DEFAULT now(),
  UNIQUE (agent_id, date_tournee)
);

CREATE TABLE surplus (
  id              serial PRIMARY KEY,
  agence_id       smallint NOT NULL REFERENCES agence(id),
  agent_id        integer NOT NULL REFERENCES agent(id),
  date_surplus    date NOT NULL,
  montant         numeric(14,0) NOT NULL CHECK (montant > 0),
  montant_utilise numeric(14,0) NOT NULL DEFAULT 0,
  origine         varchar(15) NOT NULL CHECK (origine IN ('versement','regularisation')),
  statut          varchar(10) NOT NULL DEFAULT 'a_traiter' CHECK (statut IN ('a_traiter','solde')),
  reference       text,
  cree_le         timestamptz NOT NULL DEFAULT now(),
  CHECK (montant_utilise BETWEEN 0 AND montant)
);
CREATE INDEX surplus_agent_date ON surplus (agent_id, date_surplus);

-- Un surplus reste bloqué tant qu'un cycle lié à sa date n'est pas retiré.
CREATE VIEW v_surplus AS
SELECT s.*, s.montant - s.montant_utilise AS restant,
       EXISTS (SELECT 1 FROM mf.ligne_collecte l JOIN mf.cycle c ON c.id = l.cycle_id
                WHERE c.agence_id = s.agence_id AND l.date_collecte = s.date_surplus
                  AND l.origine = 'collecte' AND c.statut <> 'retire') AS bloque
  FROM surplus s;

-- Écart de versement = collecté (lignes saisies pour l'agent ce jour-là) - versé.
-- Manquant : débit du compte de l'agent. Surplus : table surplus, statut « à traiter ».
CREATE FUNCTION enregistrer_versement(p_agent integer, p_date date, p_verse numeric,
                                      p_utilisateur integer DEFAULT NULL) RETURNS integer
LANGUAGE plpgsql AS $$
DECLARE a mf.agent; v_coll numeric; v_ecart numeric; v_id integer;
BEGIN
  SELECT * INTO a FROM mf.agent WHERE id = p_agent FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'agent % inconnu', p_agent; END IF;
  SELECT COALESCE(sum(montant_collecte), 0) INTO v_coll
    FROM mf.ligne_collecte WHERE agent_id = p_agent AND date_collecte = p_date AND origine = 'collecte';
  v_ecart := v_coll - p_verse;
  INSERT INTO mf.versement_agent(agence_id, agent_id, date_tournee, montant_collecte, montant_verse, ecart, utilisateur_id)
  VALUES (a.agence_id, p_agent, p_date, v_coll, p_verse, v_ecart, p_utilisateur) RETURNING id INTO v_id;
  IF v_ecart > 0 THEN
    INSERT INTO mf.compte_agent(agence_id, agent_id, type, montant, date_operation, libelle, reference)
    VALUES (a.agence_id, p_agent, 'manquant_versement', v_ecart, p_date, 'Manquant à la tournée du ' || p_date, 'versement_agent:' || v_id);
  ELSIF v_ecart < 0 THEN
    INSERT INTO mf.surplus(agence_id, agent_id, date_surplus, montant, origine, reference)
    VALUES (a.agence_id, p_agent, p_date, -v_ecart, 'versement', 'versement_agent:' || v_id);
  END IF;
  RETURN v_id;
END $$;

-- Solder le compte de l'agent par versement.
CREATE FUNCTION regler_compte_agent(p_agent integer, p_montant numeric, p_date date DEFAULT current_date,
                                    p_libelle text DEFAULT 'Règlement par versement') RETURNS void
LANGUAGE plpgsql AS $$
DECLARE a mf.agent;
BEGIN
  SELECT * INTO a FROM mf.agent WHERE id = p_agent FOR UPDATE;
  IF p_montant <= 0 THEN RAISE EXCEPTION 'montant invalide'; END IF;
  INSERT INTO mf.compte_agent(agence_id, agent_id, type, montant, date_operation, libelle)
  VALUES (a.agence_id, p_agent, 'versement', p_montant, p_date, p_libelle);
END $$;

-- Retenue sur commission, plafonnée à plafond_retenue x commission. Retourne le montant retenu.
CREATE FUNCTION retenue_sur_commission(p_agent integer, p_commission numeric, p_date date DEFAULT current_date)
RETURNS numeric LANGUAGE plpgsql AS $$
DECLARE a mf.agent; v_dette numeric; v_plafond numeric; v_ret numeric;
BEGIN
  SELECT * INTO a FROM mf.agent WHERE id = p_agent FOR UPDATE;
  SELECT GREATEST(-solde, 0) INTO v_dette FROM mf.v_solde_compte_agent WHERE agent_id = p_agent;
  v_plafond := floor(p_commission * mf.param_num('plafond_retenue', a.agence_id));
  v_ret := GREATEST(LEAST(v_dette, v_plafond), 0);
  IF v_ret > 0 THEN
    INSERT INTO mf.compte_agent(agence_id, agent_id, type, montant, date_operation, libelle)
    VALUES (a.agence_id, p_agent, 'retenue_commission', v_ret, p_date, 'Retenue sur commission');
  END IF;
  RETURN v_ret;
END $$;

-- ---------------------------------------------------------------------
-- Écarts de retrait
-- livret > machine : le client est payé selon le livret ; l'écart est rattaché à des dates ;
--                    surplus de la date exacte d'abord, le reste est une perte de l'agent.
-- machine > livret : pas un surplus réel : excédent « à régulariser » + retrait de
--                    régularisation sans décaissement ; devient surplus à la purge de la date.
-- ---------------------------------------------------------------------
CREATE TABLE ecart_retrait (
  id              serial PRIMARY KEY,
  agence_id       smallint NOT NULL REFERENCES agence(id),
  retrait_id      integer NOT NULL REFERENCES retrait(id),
  cycle_id        integer NOT NULL REFERENCES cycle(id),
  sens            varchar(12) NOT NULL CHECK (sens IN ('livret_sup','machine_sup')),
  montant_livret  numeric(14,0) NOT NULL,
  montant_machine numeric(14,0) NOT NULL,
  montant         numeric(14,0) NOT NULL CHECK (montant > 0),
  statut          varchar(10) NOT NULL DEFAULT 'a_traiter' CHECK (statut IN ('a_traiter','traite')),
  traite_le       date,
  cree_le         timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX ecart_retrait_cycle ON ecart_retrait (cycle_id);

CREATE TABLE ecart_retrait_date (
  id              serial PRIMARY KEY,
  ecart_id        integer NOT NULL REFERENCES ecart_retrait(id),
  date_ecart      date NOT NULL,
  agent_id        integer NOT NULL REFERENCES agent(id),
  montant         numeric(14,0) NOT NULL CHECK (montant > 0),
  surplus_utilise numeric(14,0) NOT NULL DEFAULT 0,
  perte           numeric(14,0) NOT NULL DEFAULT 0
);

CREATE TABLE excedent_regularisation (
  id          serial PRIMARY KEY,
  agence_id   smallint NOT NULL REFERENCES agence(id),
  cycle_id    integer NOT NULL REFERENCES cycle(id),
  retrait_id  integer NOT NULL REFERENCES retrait(id),   -- le retrait de régularisation
  date_ligne  date NOT NULL,
  agent_id    integer NOT NULL REFERENCES agent(id),
  montant     numeric(14,0) NOT NULL CHECK (montant > 0),
  statut      varchar(15) NOT NULL DEFAULT 'a_regulariser' CHECK (statut IN ('a_regulariser','regularise')),
  surplus_id  integer REFERENCES surplus(id),
  cree_le     timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE date_purgee (
  agence_id  smallint NOT NULL REFERENCES agence(id),
  date_purge date NOT NULL,
  purge_le   timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (agence_id, date_purge)
);

-- Retrait sans écart : livret = machine.
CREATE FUNCTION constater_sans_ecart(p_retrait integer) RETURNS void
LANGUAGE plpgsql AS $$
DECLARE r mf.retrait;
BEGIN
  SELECT * INTO r FROM mf.retrait WHERE id = p_retrait FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'retrait % inconnu', p_retrait; END IF;
  IF r.statut <> 'demande' THEN RAISE EXCEPTION 'retrait % déjà constaté (statut %)', p_retrait, r.statut; END IF;
  UPDATE mf.retrait SET montant_livret = montant, ecart = 0, statut = 'fonds_disponibles' WHERE id = p_retrait;
END $$;

-- p_details : [{"date":"2026-10-03","montant":500,"agent_id":1}, ...] ; la somme = |livret - machine|.
-- agent_id facultatif : par défaut, l'agent qui a collecté ce jour-là sur le cycle.
CREATE FUNCTION enregistrer_ecart_retrait(p_retrait integer, p_livret numeric, p_machine numeric,
                                          p_details jsonb) RETURNS integer
LANGUAGE plpgsql AS $$
DECLARE r mf.retrait; v_coll numeric; v_ecart numeric; v_sum numeric := 0; v_id integer;
        d jsonb; v_date date; v_mt numeric; v_agent integer; v_regul integer;
BEGIN
  SELECT * INTO r FROM mf.retrait WHERE id = p_retrait FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'retrait % inconnu', p_retrait; END IF;
  IF r.statut <> 'demande' THEN RAISE EXCEPTION 'retrait % déjà constaté (statut %)', p_retrait, r.statut; END IF;
  IF r.nature = 'regularisation' THEN RAISE EXCEPTION 'un retrait de régularisation n''a pas d''écart'; END IF;
  SELECT montant_collecte INTO v_coll FROM mf.v_cycle_situation WHERE cycle_id = r.cycle_id;
  IF p_machine <> v_coll THEN
    RAISE EXCEPTION 'montant machine % différent du collecté du cycle (%)', p_machine, v_coll;
  END IF;
  v_ecart := p_livret - p_machine;
  IF v_ecart = 0 THEN RAISE EXCEPTION 'aucun écart : utiliser constater_sans_ecart'; END IF;
  IF p_details IS NULL OR jsonb_typeof(p_details) <> 'array' OR jsonb_array_length(p_details) = 0 THEN
    RAISE EXCEPTION 'l''écart doit être rattaché à au moins une date';
  END IF;

  INSERT INTO mf.ecart_retrait(agence_id, retrait_id, cycle_id, sens, montant_livret, montant_machine, montant, statut)
  VALUES (r.agence_id, p_retrait, r.cycle_id,
          CASE WHEN v_ecart > 0 THEN 'livret_sup' ELSE 'machine_sup' END,
          p_livret, p_machine, abs(v_ecart), CASE WHEN v_ecart > 0 THEN 'a_traiter' ELSE 'traite' END)
  RETURNING id INTO v_id;

  IF v_ecart < 0 THEN
    -- retrait de régularisation : sans décaissement, déjà exécuté
    INSERT INTO mf.retrait(agence_id, cycle_id, nature, montant, decaissement, statut, date_demande,
                           date_operation, execute_le, montant_paye)
    VALUES (r.agence_id, r.cycle_id, 'regularisation', abs(v_ecart), false, 'execute', r.date_demande,
            r.date_demande, now(), 0)
    RETURNING id INTO v_regul;
  END IF;

  FOR d IN SELECT * FROM jsonb_array_elements(p_details) LOOP
    v_date := (d->>'date')::date;
    v_mt   := (d->>'montant')::numeric;
    IF v_date IS NULL OR v_mt IS NULL OR v_mt <= 0 THEN RAISE EXCEPTION 'détail d''écart invalide : %', d; END IF;
    v_agent := COALESCE((d->>'agent_id')::integer,
                        (SELECT agent_id FROM mf.ligne_collecte
                          WHERE cycle_id = r.cycle_id AND date_collecte = v_date AND origine = 'collecte'
                          ORDER BY id LIMIT 1));
    IF v_agent IS NULL OR NOT EXISTS (SELECT 1 FROM mf.ligne_collecte
                                       WHERE cycle_id = r.cycle_id AND date_collecte = v_date
                                         AND origine = 'collecte' AND agent_id = v_agent) THEN
      RAISE EXCEPTION 'aucune collecte de l''agent % sur le cycle à la date %', v_agent, v_date;
    END IF;
    INSERT INTO mf.ecart_retrait_date(ecart_id, date_ecart, agent_id, montant) VALUES (v_id, v_date, v_agent, v_mt);
    IF v_ecart < 0 THEN
      INSERT INTO mf.excedent_regularisation(agence_id, cycle_id, retrait_id, date_ligne, agent_id, montant)
      VALUES (r.agence_id, r.cycle_id, v_regul, v_date, v_agent, v_mt);
    END IF;
    v_sum := v_sum + v_mt;
  END LOOP;
  IF v_sum <> abs(v_ecart) THEN
    RAISE EXCEPTION 'la somme des dates (%) ne correspond pas à l''écart (%)', v_sum, abs(v_ecart);
  END IF;

  UPDATE mf.retrait
     SET montant_livret = montant + v_ecart, ecart = v_ecart,
         statut = CASE WHEN v_ecart > 0 THEN 'ecart_en_traitement' ELSE 'fonds_disponibles' END
   WHERE id = p_retrait;
  RETURN v_id;
END $$;

-- Traitement d'un écart livret > machine, date par date. Retourne la perte totale imputée aux agents.
CREATE FUNCTION traiter_ecart_retrait(p_ecart integer, p_date date DEFAULT NULL) RETURNS numeric
LANGUAGE plpgsql AS $$
DECLARE e mf.ecart_retrait; r mf.retrait; d record; s record; v_date date;
        v_reste numeric; v_util numeric; v_use numeric; v_perte numeric := 0;
BEGIN
  SELECT * INTO e FROM mf.ecart_retrait WHERE id = p_ecart FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'écart % inconnu', p_ecart; END IF;
  IF e.statut = 'traite' THEN RAISE EXCEPTION 'écart % déjà traité', p_ecart; END IF;
  SELECT * INTO r FROM mf.retrait WHERE id = e.retrait_id FOR UPDATE;
  v_date := COALESCE(p_date, r.date_demande);

  FOR d IN SELECT * FROM mf.ecart_retrait_date WHERE ecart_id = p_ecart ORDER BY date_ecart, id LOOP
    v_reste := d.montant; v_util := 0;
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

-- Exécution : exige un retrait « fonds_disponibles » (donc constaté, écarts traités).
-- Le client est payé selon le livret. Un remboursement de crédit est imputé sur la date d'atteinte du seuil.
CREATE FUNCTION executer_retrait(p_retrait integer, p_date date DEFAULT NULL, p_session integer DEFAULT NULL)
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
  IF r.nature IN ('retrait_client','virement_vers_epargne') THEN
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

-- ---------------------------------------------------------------------
-- Purge d'une date : tous les retraits des cycles ayant une ligne à cette date sont faits
-- et aucun écart n'est ouvert sur cette date. Les excédents à régulariser deviennent alors
-- surplus réel de l'agent.
-- ---------------------------------------------------------------------
CREATE FUNCTION purger_date(p_agence smallint, p_date date) RETURNS boolean
LANGUAGE plpgsql AS $$
DECLARE x record; v_sid integer;
BEGIN
  IF EXISTS (SELECT 1 FROM mf.date_purgee WHERE agence_id = p_agence AND date_purge = p_date) THEN RETURN false; END IF;
  IF EXISTS (SELECT 1 FROM mf.ligne_collecte l JOIN mf.cycle c ON c.id = l.cycle_id
              WHERE c.agence_id = p_agence AND l.date_collecte = p_date AND l.origine = 'collecte'
                AND c.statut <> 'retire') THEN RETURN false; END IF;
  IF EXISTS (SELECT 1 FROM mf.ecart_retrait_date d JOIN mf.ecart_retrait e ON e.id = d.ecart_id
              WHERE e.agence_id = p_agence AND d.date_ecart = p_date AND e.statut = 'a_traiter') THEN RETURN false; END IF;

  FOR x IN SELECT * FROM mf.excedent_regularisation
            WHERE agence_id = p_agence AND date_ligne = p_date AND statut = 'a_regulariser' ORDER BY id LOOP
    INSERT INTO mf.surplus(agence_id, agent_id, date_surplus, montant, origine, reference)
    VALUES (p_agence, x.agent_id, p_date, x.montant, 'regularisation', 'excedent_regularisation:' || x.id)
    RETURNING id INTO v_sid;
    UPDATE mf.excedent_regularisation SET statut = 'regularise', surplus_id = v_sid WHERE id = x.id;
  END LOOP;
  INSERT INTO mf.date_purgee(agence_id, date_purge) VALUES (p_agence, p_date);
  RETURN true;
END $$;

-- Tâche planifiée : purge toutes les dates purgeables jusqu'à p_jusqu_au. Retourne le nombre de dates purgées.
CREATE FUNCTION purger_dates(p_agence smallint, p_jusqu_au date DEFAULT current_date) RETURNS integer
LANGUAGE plpgsql AS $$
DECLARE x record; n integer := 0;
BEGIN
  FOR x IN SELECT DISTINCT l.date_collecte AS d
             FROM mf.ligne_collecte l JOIN mf.cycle c ON c.id = l.cycle_id
            WHERE c.agence_id = p_agence AND l.date_collecte <= p_jusqu_au AND l.origine = 'collecte'
              AND NOT EXISTS (SELECT 1 FROM mf.date_purgee p WHERE p.agence_id = p_agence AND p.date_purge = l.date_collecte)
            ORDER BY 1 LOOP
    IF mf.purger_date(p_agence, x.d) THEN n := n + 1; END IF;
  END LOOP;
  RETURN n;
END $$;
