-- =====================================================================
-- 72_controle_carnet.sql
-- Contrôle d'un cycle de tontine au carnet du client : le contrôleur saisit, ligne par ligne du tableau de collecte,
-- le montant porté sur le carnet. Un contrôle enregistre :
--   * un en-tête par cycle : date de contrôle, total collecté (système), total du carnet, écart total ;
--   * une ligne par collecte contrôlée : montant système, montant carnet, écart (carnet - système).
-- Écart de collecte : carnet > système = manquant de collecte (le carnet est payé, donc l'écart
-- est imputé à l'agent, sauf surplus de versement à la même date : règlement à venir).
-- Carnet < système = excédent constaté, mis en réserve.
-- Un contrôle se saisit d'un seul coup pour tout le cycle, et ne se modifie ni ne se supprime.
-- Dépend de : 01 (cycle, ligne_collecte, agent), 10 (trg_audit), 11 (utilisateur).
-- =====================================================================
SET search_path = mf, public;

CREATE TABLE controle_carnet (
  id             serial PRIMARY KEY,
  agence_id      smallint NOT NULL REFERENCES agence(id),
  cycle_id       integer NOT NULL REFERENCES cycle(id),
  controleur_id  integer NOT NULL REFERENCES utilisateur(id),
  date_controle  date NOT NULL DEFAULT current_date,
  total_collecte numeric(14,0) NOT NULL CHECK (total_collecte >= 0),
  total_carnet   numeric(14,0) NOT NULL CHECK (total_carnet >= 0),
  ecart_collecte numeric(14,0) NOT NULL,          -- total carnet - total collecté
  commentaire    text,
  cree_le        timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX controle_carnet_cycle_idx ON controle_carnet (cycle_id, date_controle DESC);

CREATE TABLE controle_carnet_ligne (
  id                integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  controle_id       integer NOT NULL REFERENCES controle_carnet(id),
  ligne_collecte_id integer NOT NULL REFERENCES ligne_collecte(id),
  date_collecte     date NOT NULL,
  agent_id          integer REFERENCES agent(id),
  montant_collecte  numeric(14,0) NOT NULL,
  montant_carnet    numeric(14,0) NOT NULL CHECK (montant_carnet >= 0),
  ecart             numeric(14,0) NOT NULL,       -- carnet - collecté
  UNIQUE (controle_id, ligne_collecte_id)
);

CREATE FUNCTION trg_controle_carnet_fige() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  RAISE EXCEPTION 'Un contrôle au carnet ne se modifie ni ne se supprime : il reste dans la piste d''audit';
END $$;
CREATE TRIGGER controle_carnet_fige BEFORE UPDATE OR DELETE ON controle_carnet
  FOR EACH ROW EXECUTE FUNCTION trg_controle_carnet_fige();
CREATE TRIGGER controle_carnet_ligne_fige BEFORE UPDATE OR DELETE ON controle_carnet_ligne
  FOR EACH ROW EXECUTE FUNCTION trg_controle_carnet_fige();
CREATE TRIGGER audit_controle_carnet AFTER INSERT ON controle_carnet FOR EACH ROW EXECUTE FUNCTION trg_audit();
CREATE TRIGGER audit_controle_carnet_ligne AFTER INSERT ON controle_carnet_ligne FOR EACH ROW EXECUTE FUNCTION trg_audit();

-- p_lignes : [{"ligne_id": 12, "montant_carnet": 2000}, ...] : une entrée par ligne de collecte du cycle, sans omission.
CREATE FUNCTION enregistrer_controle_carnet(p_cycle integer, p_controleur integer, p_date date,
                                            p_lignes jsonb, p_commentaire text DEFAULT NULL) RETURNS integer
LANGUAGE plpgsql AS $$
DECLARE c mf.cycle; v_nb_cycle integer; v_nb integer; v_tc numeric; v_tk numeric; v_id integer; v_hors integer;
BEGIN
  SELECT * INTO c FROM mf.cycle WHERE id = p_cycle;
  IF NOT FOUND THEN RAISE EXCEPTION 'cycle % inconnu', p_cycle; END IF;
  IF p_lignes IS NULL OR jsonb_typeof(p_lignes) <> 'array' OR jsonb_array_length(p_lignes) = 0 THEN
    RAISE EXCEPTION 'le contrôle doit porter sur les lignes de collecte du cycle';
  END IF;
  IF EXISTS (SELECT 1 FROM jsonb_to_recordset(p_lignes) AS x(ligne_id integer, montant_carnet numeric)
              WHERE x.montant_carnet IS NULL OR x.montant_carnet < 0) THEN
    RAISE EXCEPTION 'montant carnet invalide';
  END IF;

  -- cycle à mise fixe : le montant porté sur le carnet est un multiple de la mise ; le type 3 (libre) n'a pas cette règle
  IF COALESCE(c.type_cycle, 0) <> 3 THEN
    SELECT count(*) INTO v_hors FROM jsonb_to_recordset(p_lignes) AS x(ligne_id integer, montant_carnet numeric)
     WHERE x.montant_carnet % c.mise_courante <> 0;
    IF v_hors > 0 THEN
      RAISE EXCEPTION 'montant carnet doit être un multiple de la mise (% F) : % ligne(s) hors multiple', c.mise_courante, v_hors;
    END IF;
  END IF;

  SELECT count(*) INTO v_nb_cycle FROM mf.ligne_collecte WHERE cycle_id = p_cycle;
  SELECT count(*), COALESCE(sum(l.montant_collecte), 0), COALESCE(sum(x.montant_carnet), 0)
    INTO v_nb, v_tc, v_tk
    FROM jsonb_to_recordset(p_lignes) AS x(ligne_id integer, montant_carnet numeric)
    JOIN mf.ligne_collecte l ON l.id = x.ligne_id AND l.cycle_id = p_cycle;
  IF jsonb_array_length(p_lignes) <> v_nb_cycle OR v_nb <> v_nb_cycle THEN
    RAISE EXCEPTION 'chaque ligne de collecte du cycle doit être contrôlée (% saisies, % attendues)', jsonb_array_length(p_lignes), v_nb_cycle;
  END IF;

  INSERT INTO mf.controle_carnet(agence_id, cycle_id, controleur_id, date_controle, total_collecte, total_carnet, ecart_collecte, commentaire)
  VALUES (c.agence_id, p_cycle, p_controleur, COALESCE(p_date, current_date), v_tc, v_tk, v_tk - v_tc, p_commentaire)
  RETURNING id INTO v_id;

  INSERT INTO mf.controle_carnet_ligne(controle_id, ligne_collecte_id, date_collecte, agent_id, montant_collecte, montant_carnet, ecart)
  SELECT v_id, l.id, l.date_collecte, l.agent_id, l.montant_collecte, x.montant_carnet, x.montant_carnet - l.montant_collecte
    FROM jsonb_to_recordset(p_lignes) AS x(ligne_id integer, montant_carnet numeric)
    JOIN mf.ligne_collecte l ON l.id = x.ligne_id AND l.cycle_id = p_cycle;
  RETURN v_id;
END $$;
