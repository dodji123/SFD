-- =====================================================================
-- 49_mobile_money.sql
-- Espace client : collecte par mobile money, demande de retrait par le client, suivi de sa collecte.
--   * un paiement mobile money est initié par le client sur l'un de ses cycles en cours ; il n'est inscrit au livret
--     (ligne d'origine « mobile », sans agent) que lorsque l'opérateur le confirme
--   * la confirmation est idempotente (un rejeu de l'opérateur ne crée rien) ; si le livret ne peut plus recevoir le
--     versement (cycle clos entre-temps), le paiement passe « à rembourser » avec le motif
--   * limites paramétrables (montant minimal, maximal, plafond journalier par client) ; un seul paiement en attente par cycle
--   * le client ne clôture jamais lui-même son cycle : sa demande de retrait est examinée et acceptée par le personnel
-- Dépend de : 00 (agence, utilisateur, parametre), 01 (client, cycle, ligne_collecte, retrait), 44.
-- =====================================================================
SET search_path = mf, public;

-- origine « mobile » (mobile money) sur le livret
ALTER TABLE ligne_collecte DROP CONSTRAINT ligne_collecte_origine_check;
ALTER TABLE ligne_collecte ADD CONSTRAINT ligne_collecte_origine_check CHECK (origine IN ('collecte','virement','mobile'));

CREATE TABLE operateur_mobile (
  code     varchar(12) PRIMARY KEY,
  libelle  text NOT NULL,
  actif    boolean NOT NULL DEFAULT true
);
INSERT INTO operateur_mobile(code, libelle) VALUES ('TMONEY', 'T-Money (Togocel)'), ('FLOOZ', 'Flooz (Moov Africa)'), ('WAVE', 'Wave');

CREATE TABLE paiement_mobile (
  id             serial PRIMARY KEY,
  reference      varchar(20) UNIQUE,
  cle            varchar(64) UNIQUE,
  agence_id      smallint NOT NULL REFERENCES agence(id),
  client_id      integer NOT NULL REFERENCES client(id),
  cycle_id       integer NOT NULL REFERENCES cycle(id),
  operateur      varchar(12) NOT NULL REFERENCES operateur_mobile(code),
  telephone      varchar(20) NOT NULL CHECK (telephone ~ '^\+?[0-9]{8,15}$'),
  montant        numeric(12,0) NOT NULL CHECK (montant > 0),
  statut         varchar(12) NOT NULL DEFAULT 'initie' CHECK (statut IN ('initie','reussi','echoue','expire','a_rembourser','rembourse')),
  ref_operateur  text,
  motif          text,
  ligne_id       bigint REFERENCES ligne_collecte(id) ON DELETE SET NULL,
  cree_le        timestamptz NOT NULL DEFAULT now(),
  expire_le      timestamptz NOT NULL DEFAULT now() + interval '15 minutes',
  maj_le         timestamptz NOT NULL DEFAULT now()
);
CREATE UNIQUE INDEX paiement_mobile_un_en_attente ON paiement_mobile(cycle_id) WHERE statut = 'initie';
CREATE INDEX paiement_mobile_client_idx ON paiement_mobile(client_id, cree_le DESC);
COMMENT ON TABLE paiement_mobile IS 'Versement par mobile money d''un client sur un cycle : inscrit au livret seulement quand l''opérateur confirme.';

INSERT INTO parametre(cle, valeur, description) VALUES
  ('mm_montant_min', '100', 'Montant minimal d''un paiement mobile money (F)'),
  ('mm_montant_max', '500000', 'Montant maximal d''un paiement mobile money (F)'),
  ('mm_plafond_jour', '1000000', 'Total maximal de paiements mobile money par client et par jour (F)')
ON CONFLICT DO NOTHING;

CREATE FUNCTION trg_paiement_mobile_regles() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE c mf.cycle; s mf.v_cycle_situation; v_min numeric; v_max numeric; v_jour numeric; v_deja numeric; v_actif boolean;
BEGIN
  IF TG_OP = 'INSERT' THEN
    SELECT * INTO c FROM mf.cycle WHERE id = NEW.cycle_id;
    IF c.client_id <> NEW.client_id THEN RAISE EXCEPTION 'Ce cycle n''appartient pas à ce client'; END IF;
    IF c.statut <> 'en_cours' THEN RAISE EXCEPTION 'On ne verse que sur un cycle en cours (cycle %)', c.numero; END IF;
    SELECT actif INTO v_actif FROM mf.operateur_mobile WHERE code = NEW.operateur;
    IF NOT COALESCE(v_actif, false) THEN RAISE EXCEPTION 'Opérateur % indisponible', NEW.operateur; END IF;
    NEW.agence_id := c.agence_id;
    NEW.statut := 'initie';
    NEW.ligne_id := NULL;
    v_min := COALESCE(mf.param_num('mm_montant_min', c.agence_id), 100);
    v_max := COALESCE(mf.param_num('mm_montant_max', c.agence_id), 500000);
    v_jour := COALESCE(mf.param_num('mm_plafond_jour', c.agence_id), 1000000);
    IF NEW.montant < v_min OR NEW.montant > v_max THEN RAISE EXCEPTION 'Montant hors limites (% à % F)', v_min, v_max; END IF;
    SELECT COALESCE(sum(montant), 0) INTO v_deja FROM mf.paiement_mobile
      WHERE client_id = NEW.client_id AND statut IN ('initie','reussi') AND cree_le::date = current_date;
    IF v_deja + NEW.montant > v_jour THEN RAISE EXCEPTION 'Plafond journalier de % F dépassé', v_jour; END IF;
    IF c.type_cycle <> 3 THEN
      IF NEW.montant % c.mise_courante <> 0 THEN RAISE EXCEPTION 'Le montant doit être un multiple de la mise (% F)', c.mise_courante; END IF;
      SELECT * INTO s FROM mf.v_cycle_situation WHERE cycle_id = c.id;
      IF s.reste_a_collecter IS NOT NULL AND NEW.montant > s.reste_a_collecter THEN
        RAISE EXCEPTION 'Le montant dépasse le reste à collecter (% F)', s.reste_a_collecter;
      END IF;
    END IF;
    NEW.reference := 'MM-' || lpad(NEW.id::text, 8, '0');
  ELSE
    IF (NEW.client_id, NEW.cycle_id, NEW.operateur, NEW.telephone, NEW.montant, NEW.reference, NEW.cle)
       IS DISTINCT FROM (OLD.client_id, OLD.cycle_id, OLD.operateur, OLD.telephone, OLD.montant, OLD.reference, OLD.cle) THEN
      RAISE EXCEPTION 'Un paiement mobile money ne se modifie pas : seul son état évolue';
    END IF;
    IF NEW.statut <> OLD.statut AND NOT ((OLD.statut, NEW.statut) IN (('initie','reussi'),('initie','echoue'),('initie','expire'),('initie','a_rembourser'),('a_rembourser','rembourse'))) THEN
      RAISE EXCEPTION 'Changement d''état impossible : % -> %', OLD.statut, NEW.statut;
    END IF;
    IF OLD.statut NOT IN ('initie','a_rembourser') AND NEW.statut = OLD.statut AND (NEW.ref_operateur, NEW.motif, NEW.ligne_id) IS DISTINCT FROM (OLD.ref_operateur, OLD.motif, OLD.ligne_id) THEN
      RAISE EXCEPTION 'Un paiement terminé ne se modifie plus';
    END IF;
    NEW.maj_le := now();
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER paiement_mobile_regles BEFORE INSERT OR UPDATE ON paiement_mobile FOR EACH ROW EXECUTE FUNCTION trg_paiement_mobile_regles();
CREATE TRIGGER paiement_mobile_ni_suppression BEFORE DELETE ON paiement_mobile FOR EACH ROW EXECUTE FUNCTION trg_ajout_seul();
CREATE TRIGGER audit_paiement_mobile AFTER INSERT OR UPDATE ON paiement_mobile FOR EACH ROW EXECUTE FUNCTION trg_audit();

-- Confirmation par l'opérateur : inscrit le versement au livret. Rejouable sans effet.
CREATE FUNCTION confirmer_paiement_mobile(p_id integer, p_ref_operateur text DEFAULT NULL) RETURNS text
LANGUAGE plpgsql AS $$
DECLARE p mf.paiement_mobile; v_idx integer; v_ligne bigint;
BEGIN
  SELECT * INTO p FROM mf.paiement_mobile WHERE id = p_id FOR UPDATE;
  IF p.id IS NULL THEN RAISE EXCEPTION 'Paiement % introuvable', p_id; END IF;
  IF p.statut <> 'initie' THEN RETURN p.statut; END IF;
  BEGIN
    SELECT COALESCE(max((page - 1) * 31 + no_ligne), 0) + 1 INTO v_idx FROM mf.ligne_collecte WHERE cycle_id = p.cycle_id;
    INSERT INTO mf.ligne_collecte(cycle_id, page, no_ligne, date_collecte, agent_id, origine, montant_collecte)
      VALUES (p.cycle_id, (v_idx - 1) / 31 + 1, (v_idx - 1) % 31 + 1, current_date, NULL, 'mobile', p.montant)
      RETURNING id INTO v_ligne;
    UPDATE mf.paiement_mobile SET statut = 'reussi', ref_operateur = p_ref_operateur, ligne_id = v_ligne WHERE id = p_id;
    RETURN 'reussi';
  EXCEPTION WHEN OTHERS THEN
    UPDATE mf.paiement_mobile SET statut = 'a_rembourser', ref_operateur = p_ref_operateur,
      motif = 'Versement reçu mais non inscrit au livret : ' || SQLERRM WHERE id = p_id;
    RETURN 'a_rembourser';
  END;
END $$;

CREATE FUNCTION echouer_paiement_mobile(p_id integer, p_motif text) RETURNS text
LANGUAGE plpgsql AS $$
DECLARE v_statut text;
BEGIN
  UPDATE mf.paiement_mobile SET statut = 'echoue', motif = p_motif WHERE id = p_id AND statut = 'initie';
  SELECT statut INTO v_statut FROM mf.paiement_mobile WHERE id = p_id;
  RETURN v_statut;
END $$;

CREATE FUNCTION expirer_paiements_mobile() RETURNS integer LANGUAGE plpgsql AS $$
DECLARE n integer;
BEGIN
  UPDATE mf.paiement_mobile SET statut = 'expire', motif = 'Aucune confirmation de l''opérateur dans le délai' WHERE statut = 'initie' AND expire_le < now();
  GET DIAGNOSTICS n = ROW_COUNT;
  RETURN n;
END $$;

CREATE VIEW v_paiement_mobile AS
SELECT p.*, c.numero AS cycle, cl.numero AS client_numero, cl.nom AS client, o.libelle AS operateur_libelle, pe.code AS produit
FROM mf.paiement_mobile p
JOIN mf.cycle c ON c.id = p.cycle_id
JOIN mf.client cl ON cl.id = p.client_id
JOIN mf.operateur_mobile o ON o.code = p.operateur
JOIN mf.produit_epargne pe ON pe.id = c.produit_id;

-- ---------------------------------------------------------------- demande de retrait faite par le client
CREATE TABLE demande_retrait_client (
  id           serial PRIMARY KEY,
  agence_id    smallint NOT NULL REFERENCES agence(id),
  client_id    integer NOT NULL REFERENCES client(id),
  cycle_id     integer NOT NULL REFERENCES cycle(id),
  canal        varchar(12) NOT NULL DEFAULT 'agence' CHECK (canal IN ('agence','mobile_money')),
  operateur    varchar(12) REFERENCES operateur_mobile(code),
  telephone    varchar(20) CHECK (telephone IS NULL OR telephone ~ '^\+?[0-9]{8,15}$'),
  motif        text,
  statut       varchar(10) NOT NULL DEFAULT 'en_attente' CHECK (statut IN ('en_attente','acceptee','refusee','annulee')),
  cree_le      timestamptz NOT NULL DEFAULT now(),
  decide_par   integer REFERENCES utilisateur(id),
  decide_le    timestamptz,
  commentaire  text,
  retrait_id   integer REFERENCES retrait(id),
  CHECK (canal <> 'mobile_money' OR (operateur IS NOT NULL AND telephone IS NOT NULL))
);
CREATE UNIQUE INDEX demande_retrait_client_une_en_attente ON demande_retrait_client(cycle_id) WHERE statut = 'en_attente';
CREATE INDEX demande_retrait_client_idx ON demande_retrait_client(client_id, cree_le DESC);

CREATE FUNCTION trg_demande_retrait_client_regles() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE c mf.cycle;
BEGIN
  IF TG_OP = 'INSERT' THEN
    SELECT * INTO c FROM mf.cycle WHERE id = NEW.cycle_id;
    IF c.client_id <> NEW.client_id THEN RAISE EXCEPTION 'Ce cycle n''appartient pas à ce client'; END IF;
    IF c.statut = 'retire' THEN RAISE EXCEPTION 'Ce cycle a déjà été retiré'; END IF;
    IF EXISTS (SELECT 1 FROM mf.retrait WHERE cycle_id = NEW.cycle_id AND statut <> 'annule' AND nature IN ('retrait_client','virement_vers_epargne')) THEN
      RAISE EXCEPTION 'Un retrait est déjà en cours pour ce cycle';
    END IF;
    NEW.agence_id := c.agence_id;
    NEW.statut := 'en_attente'; NEW.decide_par := NULL; NEW.decide_le := NULL; NEW.retrait_id := NULL;
  ELSIF OLD.statut = 'en_attente' AND NEW.statut IN ('acceptee','refusee') THEN
    IF NEW.decide_par IS NULL THEN RAISE EXCEPTION 'La décision doit être attribuée à son auteur'; END IF;
    IF NEW.statut = 'refusee' AND length(btrim(COALESCE(NEW.commentaire, ''))) < 5 THEN RAISE EXCEPTION 'Un refus doit être motivé'; END IF;
    IF NEW.statut = 'acceptee' AND NEW.retrait_id IS NULL THEN RAISE EXCEPTION 'L''acceptation crée le retrait du cycle'; END IF;
    NEW.decide_le := now();
  ELSIF OLD.statut = 'en_attente' AND NEW.statut = 'annulee' THEN
    NEW.decide_le := now();
  ELSE
    RAISE EXCEPTION 'Une demande de retrait décidée ne se modifie plus';
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER demande_retrait_client_regles BEFORE INSERT OR UPDATE ON demande_retrait_client FOR EACH ROW EXECUTE FUNCTION trg_demande_retrait_client_regles();
CREATE TRIGGER demande_retrait_client_ni_suppression BEFORE DELETE ON demande_retrait_client FOR EACH ROW EXECUTE FUNCTION trg_ajout_seul();
CREATE TRIGGER audit_demande_retrait_client AFTER INSERT OR UPDATE ON demande_retrait_client FOR EACH ROW EXECUTE FUNCTION trg_audit();

CREATE VIEW v_demande_retrait_client AS
SELECT d.*, c.numero AS cycle, cl.numero AS client_numero, cl.nom AS client, ud.nom AS decide_par_nom, pe.code AS produit
FROM mf.demande_retrait_client d
JOIN mf.cycle c ON c.id = d.cycle_id
JOIN mf.client cl ON cl.id = d.client_id
JOIN mf.produit_epargne pe ON pe.id = c.produit_id
LEFT JOIN mf.utilisateur ud ON ud.id = d.decide_par;
