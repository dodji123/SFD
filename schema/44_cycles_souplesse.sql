-- =====================================================================
-- 44_cycles_souplesse.sql
-- Tontine : souplesse de gestion des cycles.
--   * le type de cycle n'est plus porté par le produit : il est choisi librement à chaque nouveau cycle (un produit peut encore en imposer un)
--     et reste le même ensuite (les produits existants qui imposent un type continuent de le faire)
--   * délai de grâce après la date de fin (par produit, sinon paramètre) : la clôture automatique et le refus de
--     saisie n'interviennent qu'après fin + grâce
--   * prolongation d'un cycle : demandée avec motif, autorisée par une autre personne, plafonnée
--   * suppression d'une opération : la ligne disparaît des écrans et des calculs, mais une trace « supprimée »
--     (qui, quand, pourquoi, contenu complet) est conservée de façon inaltérable pour l'audit
-- Dépend de : 01, 02, 03, 07, 10, 18, 23.
-- =====================================================================
SET search_path = mf, public;

INSERT INTO parametre(cle, valeur, description) VALUES
  ('cycle_delai_grace_jours', '0', 'Délai de grâce par défaut (jours) après la date de fin d''un cycle, avant clôture automatique et refus de saisie'),
  ('cycle_prolongation_max_jours', '60', 'Prolongation maximale (jours) accordée en une fois pour un cycle'),
  ('cycle_prolongations_max', '2', 'Nombre maximal de prolongations autorisées pour un même cycle');

-- ---------------------------------------------------------------- type de cycle choisi à chaque cycle
ALTER TABLE produit_epargne DROP CONSTRAINT produit_epargne_check;
ALTER TABLE produit_epargne ADD CONSTRAINT produit_type_selon_categorie CHECK (categorie = 'collecte' OR type_cycle IS NULL);
ALTER TABLE produit_epargne ADD COLUMN delai_grace_jours smallint CHECK (delai_grace_jours IS NULL OR delai_grace_jours BETWEEN 0 AND 90);

CREATE OR REPLACE FUNCTION trg_cycle_avant() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE p mf.produit_epargne; c mf.client;
BEGIN
  SELECT * INTO p FROM mf.produit_epargne WHERE id = NEW.produit_id;
  IF p.categorie <> 'collecte' THEN
    RAISE EXCEPTION 'le produit % n''est pas un produit de collecte', p.code;
  END IF;
  IF p.type_cycle IS NOT NULL AND NEW.type_cycle <> p.type_cycle THEN
    RAISE EXCEPTION 'type de cycle % incompatible avec le produit % (type %)', NEW.type_cycle, p.code, p.type_cycle;
  END IF;
  SELECT * INTO c FROM mf.client WHERE id = NEW.client_id;
  IF c.agence_id <> NEW.agence_id THEN
    RAISE EXCEPTION 'le client % n''appartient pas à l''agence %', c.numero, NEW.agence_id;
  END IF;
  IF NEW.nb_lignes_prevues IS NULL THEN NEW.nb_lignes_prevues := 31 * p.nb_pages_livret; END IF;
  IF NEW.mise_courante IS NULL THEN NEW.mise_courante := NEW.mise_initiale; END IF;
  RETURN NEW;
END $$;

-- ---------------------------------------------------------------- délai de grâce
CREATE FUNCTION delai_grace_cycle(p_cycle integer) RETURNS integer
LANGUAGE sql STABLE AS $$
  SELECT COALESCE(p.delai_grace_jours, mf.param_num('cycle_delai_grace_jours', c.agence_id), 0)::int
    FROM mf.cycle c JOIN mf.produit_epargne p ON p.id = c.produit_id WHERE c.id = p_cycle
$$;

-- Date limite de saisie et de clôture automatique = date de fin + délai de grâce
CREATE FUNCTION date_limite_cycle(p_cycle integer) RETURNS date
LANGUAGE sql STABLE AS $$ SELECT c.date_fin + mf.delai_grace_cycle(c.id) FROM mf.cycle c WHERE c.id = p_cycle $$;

CREATE OR REPLACE FUNCTION trg_ligne_avant() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE c mf.cycle; v_pages smallint;
BEGIN
  SELECT * INTO c FROM mf.cycle WHERE id = NEW.cycle_id FOR UPDATE;   -- sérialise les saisies d'un même cycle
  IF c.statut <> 'en_cours' THEN
    RAISE EXCEPTION 'cycle % clos : saisie refusée', c.numero;
  END IF;
  SELECT nb_pages_livret INTO v_pages FROM mf.produit_epargne WHERE id = c.produit_id;
  IF NEW.page > v_pages THEN
    RAISE EXCEPTION 'page % au-delà du livret (% page(s))', NEW.page, v_pages;
  END IF;
  IF NEW.date_collecte < c.date_debut THEN
    RAISE EXCEPTION 'date de collecte % antérieure au début du cycle (%)', NEW.date_collecte, c.date_debut;
  END IF;
  IF NEW.date_collecte > mf.date_limite_cycle(c.id) THEN
    RAISE EXCEPTION 'date de collecte % après la fin du cycle % (fin %, délai de grâce % j) : demander une prolongation',
      NEW.date_collecte, c.numero, c.date_fin, mf.delai_grace_cycle(c.id);
  END IF;
  IF NEW.agent_id IS NOT NULL AND NOT EXISTS
     (SELECT 1 FROM mf.agent WHERE id = NEW.agent_id AND agence_id = c.agence_id) THEN
    RAISE EXCEPTION 'agent % hors de l''agence du cycle', NEW.agent_id;
  END IF;
  IF NEW.mise_appliquee IS NULL THEN
    NEW.mise_appliquee := mf.mise_a_date(NEW.cycle_id, NEW.date_collecte);
  END IF;
  RETURN NEW;
END $$;

CREATE OR REPLACE FUNCTION cloturer_cycles_echus(p_agence smallint, p_date date DEFAULT current_date) RETURNS integer
LANGUAGE plpgsql AS $$
DECLARE r record; n integer := 0;
BEGIN
  FOR r IN
    SELECT c.id
      FROM mf.cycle c
      LEFT JOIN mf.v_cycle_situation s ON s.cycle_id = c.id
     WHERE c.agence_id = p_agence AND c.statut = 'en_cours'
       AND ( mf.date_limite_cycle(c.id) <= p_date
          OR (c.type_cycle = 1 AND (s.montant_collecte >= c.objectif OR s.nb_lignes >= c.nb_lignes_prevues)) )
     ORDER BY c.id
  LOOP
    PERFORM mf.cloturer_cycle(r.id, p_date);
    n := n + 1;
  END LOOP;
  RETURN n;
END $$;

-- ---------------------------------------------------------------- prolongation avec autorisation
CREATE TABLE prolongation_cycle (
  id            serial PRIMARY KEY,
  cycle_id      integer NOT NULL REFERENCES cycle(id),
  ancienne_fin  date NOT NULL,
  nouvelle_fin  date NOT NULL,
  motif         text NOT NULL CHECK (length(btrim(motif)) >= 10),
  statut        varchar(10) NOT NULL DEFAULT 'demandee' CHECK (statut IN ('demandee','autorisee','refusee','annulee')),
  demande_par   integer REFERENCES utilisateur(id),
  demande_le    timestamptz NOT NULL DEFAULT now(),
  decide_par    integer REFERENCES utilisateur(id),
  decide_le     timestamptz,
  commentaire   text,
  CHECK (nouvelle_fin > ancienne_fin)
);
CREATE UNIQUE INDEX prolongation_une_en_attente ON prolongation_cycle(cycle_id) WHERE statut = 'demandee';

CREATE FUNCTION trg_prolongation_regles() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE c mf.cycle; v_max numeric; v_nb integer; v_lim numeric;
BEGIN
  IF TG_OP = 'INSERT' THEN
    SELECT * INTO c FROM mf.cycle WHERE id = NEW.cycle_id FOR UPDATE;
    IF c.statut <> 'en_cours' THEN RAISE EXCEPTION 'Seul un cycle en cours se prolonge (statut %)', c.statut; END IF;
    NEW.ancienne_fin := c.date_fin;
    v_max := COALESCE(mf.param_num('cycle_prolongation_max_jours', c.agence_id), 60);
    IF NEW.nouvelle_fin - c.date_fin > v_max THEN
      RAISE EXCEPTION 'Prolongation limitée à % jours en une fois', v_max;
    END IF;
    v_lim := COALESCE(mf.param_num('cycle_prolongations_max', c.agence_id), 2);
    SELECT count(*) INTO v_nb FROM mf.prolongation_cycle WHERE cycle_id = NEW.cycle_id AND statut = 'autorisee';
    IF v_nb >= v_lim THEN RAISE EXCEPTION 'Ce cycle a déjà été prolongé % fois (maximum %)', v_nb, v_lim; END IF;
  ELSIF NEW.statut IN ('autorisee','refusee') AND OLD.statut = 'demandee' THEN
    IF NEW.decide_par IS NULL THEN RAISE EXCEPTION 'La décision doit être attribuée à son auteur'; END IF;
    IF NEW.decide_par IS NOT DISTINCT FROM NEW.demande_par THEN
      RAISE EXCEPTION 'Séparation des tâches : le demandeur n''autorise pas sa propre prolongation';
    END IF;
    IF NEW.statut = 'refusee' AND length(btrim(COALESCE(NEW.commentaire, ''))) < 5 THEN RAISE EXCEPTION 'Un refus doit être motivé'; END IF;
    NEW.decide_le := now();
    IF NEW.statut = 'autorisee' THEN
      SELECT * INTO c FROM mf.cycle WHERE id = NEW.cycle_id FOR UPDATE;
      IF c.statut <> 'en_cours' THEN RAISE EXCEPTION 'Le cycle n''est plus en cours : prolongation impossible'; END IF;
      IF c.date_fin <> OLD.ancienne_fin THEN RAISE EXCEPTION 'La date de fin du cycle a changé depuis la demande : refaire la demande'; END IF;
      UPDATE mf.cycle SET date_fin = NEW.nouvelle_fin WHERE id = NEW.cycle_id;
    END IF;
  ELSIF TG_OP = 'UPDATE' AND NEW.statut = 'annulee' AND OLD.statut = 'demandee' THEN
    NEW.decide_le := now();
  ELSIF TG_OP = 'UPDATE' THEN
    RAISE EXCEPTION 'Une prolongation décidée ne se modifie pas';
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER prolongation_regles BEFORE INSERT OR UPDATE ON prolongation_cycle FOR EACH ROW EXECUTE FUNCTION trg_prolongation_regles();

-- ---------------------------------------------------------------- suppression : trace inaltérable pour l'audit
CREATE TABLE operation_supprimee (
  id            bigserial PRIMARY KEY,
  nature        text NOT NULL,                  -- table d'origine
  ligne_id      text,
  agence_id     smallint,
  cycle_id      integer,
  donnees       jsonb NOT NULL,                 -- contenu complet de l'opération au moment de la suppression
  supprime_par  text,
  supprime_le   timestamptz NOT NULL DEFAULT now(),
  motif         text NOT NULL
);
CREATE INDEX operation_supprimee_date ON operation_supprimee(supprime_le DESC);
CREATE INDEX operation_supprimee_agence ON operation_supprimee(agence_id, supprime_le DESC);

CREATE FUNCTION trg_archiver_suppression() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE v jsonb := to_jsonb(OLD); v_ag smallint; v_cycle integer;
BEGIN
  v_cycle := NULLIF(v ->> 'cycle_id', '')::integer;
  v_ag := NULLIF(v ->> 'agence_id', '')::smallint;
  IF v_ag IS NULL AND v_cycle IS NOT NULL THEN SELECT agence_id INTO v_ag FROM mf.cycle WHERE id = v_cycle; END IF;
  IF v_ag IS NULL AND (v ->> 'compte_id') IS NOT NULL THEN SELECT agence_id INTO v_ag FROM mf.compte_epargne WHERE id = (v ->> 'compte_id')::integer; END IF;
  INSERT INTO mf.operation_supprimee(nature, ligne_id, agence_id, cycle_id, donnees, supprime_par, motif)
  VALUES (TG_TABLE_NAME, v ->> 'id', v_ag, v_cycle, v,
          COALESCE(NULLIF(current_setting('mf.utilisateur', true), ''), current_user),
          COALESCE(NULLIF(btrim(current_setting('mf.motif_suppression', true)), ''), 'non renseigné'));
  RETURN NULL;
END $$;

CREATE TRIGGER archive_ligne_collecte AFTER DELETE ON ligne_collecte FOR EACH ROW EXECUTE FUNCTION trg_archiver_suppression();
CREATE TRIGGER archive_mouvement_epargne AFTER DELETE ON mouvement_epargne FOR EACH ROW EXECUTE FUNCTION trg_archiver_suppression();
CREATE TRIGGER archive_versement_agent AFTER DELETE ON versement_agent FOR EACH ROW EXECUTE FUNCTION trg_archiver_suppression();
CREATE TRIGGER archive_retrait AFTER DELETE ON retrait FOR EACH ROW EXECUTE FUNCTION trg_archiver_suppression();

CREATE TRIGGER operation_supprimee_ajout_seul BEFORE UPDATE OR DELETE ON operation_supprimee FOR EACH ROW EXECUTE FUNCTION trg_ajout_seul();
CREATE TRIGGER operation_supprimee_pas_de_vidage BEFORE TRUNCATE ON operation_supprimee FOR EACH STATEMENT EXECUTE FUNCTION trg_ajout_seul();
CREATE TRIGGER audit_prolongation_cycle AFTER INSERT OR UPDATE OR DELETE ON prolongation_cycle FOR EACH ROW EXECUTE FUNCTION trg_audit();
