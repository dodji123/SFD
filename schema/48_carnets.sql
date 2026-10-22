-- =====================================================================
-- 48_carnets.sql
-- Gestion des carnets (livrets papier) : stock par agence et par produit, remise aux agents, attribution aux membres.
--   * chaque produit de tontine a son propre livret : un carnet n'est attribuable qu'à un cycle du MÊME produit et de la même agence
--   * un lot reçu génère des carnets numérotés (numéro d'ordre continu par agence et produit)
--   * cycle de vie : en_stock -> chez_agent -> attribue -> termine ; perdu / abime / annule (motif obligatoire) ; remplacement tracé
--   * un cycle n'a qu'un carnet attribué à la fois ; chaque changement d'état est journalisé de façon inaltérable
-- Dépend de : 00 (agence, utilisateur), 01 (agent, produit_epargne, cycle).
-- =====================================================================
SET search_path = mf, public;

CREATE TABLE carnet_lot (
  id          serial PRIMARY KEY,
  agence_id   smallint NOT NULL REFERENCES agence(id),
  produit_id  integer NOT NULL REFERENCES produit_epargne(id),
  premier     integer NOT NULL CHECK (premier > 0),
  dernier     integer NOT NULL,
  quantite    integer NOT NULL CHECK (quantite BETWEEN 1 AND 5000),
  reference   text,
  recu_le     date NOT NULL DEFAULT current_date,
  recu_par    text,
  CHECK (dernier = premier + quantite - 1)
);

CREATE TABLE carnet (
  id           serial PRIMARY KEY,
  agence_id    smallint NOT NULL REFERENCES agence(id),
  produit_id   integer NOT NULL REFERENCES produit_epargne(id),
  lot_id       integer NOT NULL REFERENCES carnet_lot(id),
  ordre        integer NOT NULL CHECK (ordre > 0),
  numero       varchar(40) NOT NULL,
  statut       varchar(10) NOT NULL DEFAULT 'en_stock' CHECK (statut IN ('en_stock','chez_agent','attribue','termine','perdu','abime','annule')),
  agent_id     integer REFERENCES agent(id),
  cycle_id     integer REFERENCES cycle(id),
  remplace_id  integer REFERENCES carnet(id),
  motif        text,
  maj_le       timestamptz NOT NULL DEFAULT now(),
  UNIQUE (agence_id, produit_id, ordre),
  UNIQUE (numero),
  CHECK ((statut = 'chez_agent') = (agent_id IS NOT NULL AND cycle_id IS NULL) OR statut IN ('attribue','termine','perdu','abime','annule')),
  CHECK (statut <> 'attribue' OR cycle_id IS NOT NULL),
  CHECK (statut NOT IN ('perdu','abime','annule') OR length(btrim(COALESCE(motif, ''))) >= 5)
);
CREATE UNIQUE INDEX carnet_un_attribue_par_cycle ON carnet(cycle_id) WHERE statut = 'attribue';
CREATE INDEX carnet_stock_idx ON carnet(agence_id, produit_id, statut);
CREATE INDEX carnet_cycle_idx ON carnet(cycle_id);
COMMENT ON TABLE carnet IS 'Carnet (livret papier) d''un produit de tontine : stock, remise à un agent, attribution à un cycle.';

CREATE TABLE carnet_mouvement (
  id          bigserial PRIMARY KEY,
  carnet_id   integer NOT NULL REFERENCES carnet(id),
  de_statut   varchar(10),
  a_statut    varchar(10) NOT NULL,
  agent_id    integer,
  cycle_id    integer,
  motif       text,
  par         text,
  le          timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX carnet_mouvement_idx ON carnet_mouvement(carnet_id, le);

-- numéro lisible et unique : code agence + code produit + numéro d'ordre sur 6 chiffres
CREATE FUNCTION numero_carnet(p_agence smallint, p_produit integer, p_ordre integer) RETURNS text LANGUAGE sql STABLE AS $$
  SELECT a.code || '-' || p.code || '-' || lpad(p_ordre::text, 6, '0') FROM mf.produit_epargne p, mf.agence a WHERE p.id = p_produit AND a.id = p_agence
$$;

-- réception d'un lot : crée les carnets numérotés à la suite des précédents
CREATE FUNCTION recevoir_lot_carnets(p_agence smallint, p_produit integer, p_quantite integer, p_reference text DEFAULT NULL) RETURNS integer
LANGUAGE plpgsql AS $$
DECLARE v_cat text; v_premier integer; v_lot integer;
BEGIN
  SELECT categorie INTO v_cat FROM mf.produit_epargne WHERE id = p_produit;
  IF v_cat IS DISTINCT FROM 'collecte' THEN RAISE EXCEPTION 'Les carnets ne concernent que les produits de collecte'; END IF;
  PERFORM pg_advisory_xact_lock(48, p_agence * 100000 + p_produit);
  SELECT COALESCE(max(ordre), 0) + 1 INTO v_premier FROM mf.carnet WHERE agence_id = p_agence AND produit_id = p_produit;
  INSERT INTO mf.carnet_lot(agence_id, produit_id, premier, dernier, quantite, reference, recu_par)
    VALUES (p_agence, p_produit, v_premier, v_premier + p_quantite - 1, p_quantite, p_reference, current_setting('mf.utilisateur', true))
    RETURNING id INTO v_lot;
  INSERT INTO mf.carnet(agence_id, produit_id, lot_id, ordre, numero)
    SELECT p_agence, p_produit, v_lot, o, mf.numero_carnet(p_agence, p_produit, o) FROM generate_series(v_premier, v_premier + p_quantite - 1) o;
  RETURN v_lot;
END $$;

-- règles de cycle de vie
CREATE FUNCTION trg_carnet_regles() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE c mf.cycle; a mf.agent; r mf.carnet; v_ok boolean;
BEGIN
  IF TG_OP = 'INSERT' THEN
    IF NEW.statut <> 'en_stock' THEN RAISE EXCEPTION 'Un carnet naît en stock'; END IF;
    RETURN NEW;
  END IF;
  IF (NEW.agence_id, NEW.produit_id, NEW.numero, NEW.lot_id, NEW.ordre) IS DISTINCT FROM (OLD.agence_id, OLD.produit_id, OLD.numero, OLD.lot_id, OLD.ordre) THEN
    RAISE EXCEPTION 'Le numéro, le produit et l''agence d''un carnet ne se modifient pas';
  END IF;
  IF NEW.statut = OLD.statut THEN
    IF (NEW.agent_id, NEW.cycle_id) IS DISTINCT FROM (OLD.agent_id, OLD.cycle_id) THEN RAISE EXCEPTION 'Changer l''agent ou le cycle d''un carnet passe par un changement d''état'; END IF;
    RETURN NEW;
  END IF;
  v_ok := (OLD.statut, NEW.statut) IN (('en_stock','chez_agent'), ('en_stock','attribue'), ('en_stock','perdu'), ('en_stock','abime'), ('en_stock','annule'),
                                       ('chez_agent','en_stock'), ('chez_agent','attribue'), ('chez_agent','perdu'), ('chez_agent','abime'),
                                       ('attribue','termine'), ('attribue','perdu'), ('attribue','abime'));
  IF NOT v_ok THEN RAISE EXCEPTION 'Changement d''état impossible : % -> %', OLD.statut, NEW.statut; END IF;
  IF NEW.statut = 'chez_agent' THEN
    SELECT * INTO a FROM mf.agent WHERE id = NEW.agent_id;
    IF a.id IS NULL OR a.agence_id <> NEW.agence_id THEN RAISE EXCEPTION 'L''agent doit appartenir à l''agence du carnet'; END IF;
    NEW.cycle_id := NULL;
  ELSIF NEW.statut = 'en_stock' THEN
    NEW.agent_id := NULL; NEW.cycle_id := NULL;
  ELSIF NEW.statut = 'attribue' THEN
    SELECT * INTO c FROM mf.cycle WHERE id = NEW.cycle_id;
    IF c.id IS NULL THEN RAISE EXCEPTION 'Un carnet attribué désigne un cycle'; END IF;
    IF c.produit_id <> NEW.produit_id THEN RAISE EXCEPTION 'Chaque produit a son livret : ce carnet n''est pas celui du produit du cycle'; END IF;
    IF c.agence_id <> NEW.agence_id THEN RAISE EXCEPTION 'Le carnet et le cycle ne sont pas de la même agence'; END IF;
    IF c.statut <> 'en_cours' THEN RAISE EXCEPTION 'On n''attribue un carnet qu''à un cycle en cours'; END IF;
    IF NEW.remplace_id IS NOT NULL THEN
      SELECT * INTO r FROM mf.carnet WHERE id = NEW.remplace_id;
      IF r.id IS NULL OR r.statut NOT IN ('perdu','abime') OR r.cycle_id IS DISTINCT FROM NEW.cycle_id THEN
        RAISE EXCEPTION 'Un carnet remplace un carnet perdu ou abîmé du même cycle';
      END IF;
    END IF;
  ELSIF NEW.statut = 'termine' THEN
    NULL;
  END IF;
  NEW.maj_le := now();
  RETURN NEW;
END $$;
CREATE TRIGGER carnet_regles BEFORE INSERT OR UPDATE ON carnet FOR EACH ROW EXECUTE FUNCTION trg_carnet_regles();

-- journal inaltérable des mouvements
CREATE FUNCTION trg_carnet_journal() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF TG_OP = 'INSERT' THEN
    INSERT INTO mf.carnet_mouvement(carnet_id, de_statut, a_statut, par) VALUES (NEW.id, NULL, NEW.statut, current_setting('mf.utilisateur', true));
  ELSIF NEW.statut IS DISTINCT FROM OLD.statut THEN
    INSERT INTO mf.carnet_mouvement(carnet_id, de_statut, a_statut, agent_id, cycle_id, motif, par)
      VALUES (NEW.id, OLD.statut, NEW.statut, NEW.agent_id, NEW.cycle_id, NEW.motif, current_setting('mf.utilisateur', true));
  END IF;
  RETURN NULL;
END $$;
CREATE TRIGGER carnet_journal AFTER INSERT OR UPDATE ON carnet FOR EACH ROW EXECUTE FUNCTION trg_carnet_journal();
CREATE TRIGGER carnet_mouvement_ajout_seul BEFORE UPDATE OR DELETE ON carnet_mouvement FOR EACH ROW EXECUTE FUNCTION trg_ajout_seul();
CREATE TRIGGER carnet_ni_suppression BEFORE DELETE ON carnet FOR EACH ROW EXECUTE FUNCTION trg_ajout_seul();
CREATE TRIGGER audit_carnet AFTER INSERT OR UPDATE ON carnet FOR EACH ROW EXECUTE FUNCTION trg_audit();

-- stock par agence et par produit, avec alerte de réapprovisionnement
INSERT INTO parametre(cle, valeur, description) VALUES
  ('carnet_seuil_alerte', '20', 'Nombre de carnets en stock (agence + produit) en dessous duquel une alerte de réapprovisionnement est levée')
ON CONFLICT DO NOTHING;

CREATE VIEW v_stock_carnets AS
SELECT c.agence_id, a.code AS agence, c.produit_id, p.code AS produit, p.libelle AS produit_libelle,
       count(*) FILTER (WHERE c.statut = 'en_stock')   AS en_stock,
       count(*) FILTER (WHERE c.statut = 'chez_agent') AS chez_agents,
       count(*) FILTER (WHERE c.statut = 'attribue')   AS attribues,
       count(*) FILTER (WHERE c.statut = 'termine')    AS termines,
       count(*) FILTER (WHERE c.statut = 'perdu')      AS perdus,
       count(*) FILTER (WHERE c.statut = 'abime')      AS abimes,
       count(*) FILTER (WHERE c.statut = 'annule')     AS annules,
       count(*) AS total,
       count(*) FILTER (WHERE c.statut IN ('en_stock','chez_agent')) < COALESCE(mf.param_num('carnet_seuil_alerte', c.agence_id), 20) AS reapprovisionner
FROM mf.carnet c JOIN mf.agence a ON a.id = c.agence_id JOIN mf.produit_epargne p ON p.id = c.produit_id
GROUP BY c.agence_id, a.code, c.produit_id, p.code, p.libelle;

CREATE VIEW v_carnet AS
SELECT c.*, p.code AS produit, ag.matricule AS agent, ag.nom AS agent_nom, cy.numero AS cycle, cl.id AS client_id, cl.numero AS client_numero, cl.nom AS client
FROM mf.carnet c
JOIN mf.produit_epargne p ON p.id = c.produit_id
LEFT JOIN mf.agent ag ON ag.id = c.agent_id
LEFT JOIN mf.cycle cy ON cy.id = c.cycle_id
LEFT JOIN mf.client cl ON cl.id = cy.client_id;
