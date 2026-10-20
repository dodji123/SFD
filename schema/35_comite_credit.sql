-- =====================================================================
-- 35_comite_credit.sql
-- Procédure du comité de gestion du crédit (guide du contrôle interne, fiches crédit et 6.16) :
--   * comités par niveau (agence / réseau / siège), compétence par montant, quorum
--   * membres et fonctions (président, secrétaire, membre), voix délibérative ou consultative
--   * délégations individuelles de décision (plafond par crédit et par période)
--   * séances : convocation (délai minimal), ordre du jour, présences, ouverture, clôture, PV signé
--   * dossiers examinés : rapporteur, analyse individuelle, visite et contre-visite selon le montant
--   * votes motivés (acceptation / ajournement / rejet / abstention), récusation, voix prépondérante
--   * décision : quorum + majorité des membres présents ; applique la décision à la demande de crédit
--   * paramètre comite_credit_obligatoire : quand il vaut 1, une demande ne se décide plus qu'en comité
--     ou par délégation (approuver_demande est durcie)
-- Dépend de : 00, 08, 11, 31, 33, 34.
-- =====================================================================
SET search_path = mf, public;

INSERT INTO parametre(cle, valeur, description) VALUES
  ('comite_credit_obligatoire', '0', '1 = toute décision de crédit passe par le comité de crédit ou une délégation (0 = ancien fonctionnement)'),
  ('comite_delai_convocation_h', '24', 'Délai minimal (heures) entre la convocation et la séance du comité de crédit (provisoire)'),
  ('credit_visite_seuil', '500000', 'Montant à partir duquel une visite préalable du client est obligatoire (provisoire)'),
  ('credit_contre_visite_seuil', '2000000', 'Montant à partir duquel une contre-visite par une autre personne est obligatoire (provisoire)');

-- ---------------------------------------------------------------------
-- Comités
-- ---------------------------------------------------------------------
CREATE TABLE comite_credit (
  id           smallserial PRIMARY KEY,
  code         varchar(10) NOT NULL UNIQUE,
  libelle      text NOT NULL,
  agence_id    smallint REFERENCES agence(id),     -- comité d'agence
  reseau_id    smallint REFERENCES reseau(id),     -- comité de réseau ; ni l'un ni l'autre : comité central
  montant_min  numeric(14,0) NOT NULL DEFAULT 0 CHECK (montant_min >= 0),
  montant_max  numeric(14,0),                      -- NULL = sans plafond
  quorum       smallint NOT NULL DEFAULT 3 CHECK (quorum >= 1),
  actif        boolean NOT NULL DEFAULT true,
  cree_le      timestamptz NOT NULL DEFAULT now(),
  CHECK (agence_id IS NULL OR reseau_id IS NULL),
  CHECK (montant_max IS NULL OR montant_max >= montant_min)
);

CREATE TABLE comite_membre (
  id              serial PRIMARY KEY,
  comite_id       smallint NOT NULL REFERENCES comite_credit(id),
  utilisateur_id  integer NOT NULL REFERENCES utilisateur(id),
  fonction        varchar(10) NOT NULL DEFAULT 'membre' CHECK (fonction IN ('president','secretaire','membre')),
  avec_voix       boolean NOT NULL DEFAULT true,   -- false : voix consultative
  depuis          date NOT NULL DEFAULT current_date,
  jusqua          date,
  UNIQUE (comite_id, utilisateur_id),
  CHECK (jusqua IS NULL OR jusqua >= depuis)
);
CREATE UNIQUE INDEX comite_un_president ON comite_membre(comite_id) WHERE fonction = 'president' AND jusqua IS NULL;
CREATE UNIQUE INDEX comite_un_secretaire ON comite_membre(comite_id) WHERE fonction = 'secretaire' AND jusqua IS NULL;

-- ---------------------------------------------------------------------
-- Délégations individuelles
-- ---------------------------------------------------------------------
CREATE TABLE delegation_credit (
  id                   serial PRIMARY KEY,
  utilisateur_id       integer NOT NULL REFERENCES utilisateur(id),
  montant_max_credit   numeric(14,0) NOT NULL CHECK (montant_max_credit > 0),
  montant_max_periode  numeric(14,0) CHECK (montant_max_periode IS NULL OR montant_max_periode >= montant_max_credit),
  periode              varchar(10) NOT NULL DEFAULT 'mois' CHECK (periode IN ('mois','trimestre','annee')),
  debut                date NOT NULL DEFAULT current_date,
  fin                  date,
  motif                text NOT NULL CHECK (length(btrim(motif)) >= 5),
  accordee_par         integer NOT NULL REFERENCES utilisateur(id),
  cree_le              timestamptz NOT NULL DEFAULT now(),
  CHECK (fin IS NULL OR fin >= debut),
  CHECK (accordee_par <> utilisateur_id)           -- on ne s'auto-délègue pas
);

-- Début de la période en cours pour une délégation
CREATE FUNCTION debut_periode(p_periode text, p_date date) RETURNS date LANGUAGE sql IMMUTABLE AS $$
  SELECT CASE p_periode WHEN 'mois' THEN date_trunc('month', p_date)::date
                        WHEN 'trimestre' THEN date_trunc('quarter', p_date)::date
                        ELSE date_trunc('year', p_date)::date END
$$;

-- La délégation d'un utilisateur couvre-t-elle ce montant dans cette agence ?
CREATE FUNCTION delegation_couvre(p_user integer, p_agence smallint, p_montant numeric, p_date date DEFAULT current_date)
RETURNS boolean LANGUAGE plpgsql STABLE AS $$
DECLARE d mf.delegation_credit; v_cumul numeric; v_ag integer[];
BEGIN
  IF p_user IS NULL THEN RETURN false; END IF;
  v_ag := mf.agences_utilisateur(p_user);
  IF v_ag IS NOT NULL AND NOT (p_agence = ANY (v_ag)) THEN RETURN false; END IF;
  FOR d IN SELECT * FROM mf.delegation_credit
            WHERE utilisateur_id = p_user AND debut <= p_date AND (fin IS NULL OR fin >= p_date)
              AND montant_max_credit >= p_montant LOOP
    IF d.montant_max_periode IS NULL THEN RETURN true; END IF;
    -- le cumul ne compte que les décisions prises seul (celles d'un comité n'engagent pas la délégation personnelle)
    SELECT COALESCE(sum(montant), 0) INTO v_cumul FROM mf.demande_credit dc
     WHERE dc.validateur_id = p_user AND dc.statut IN ('approuvee','debloquee')
       AND dc.date_decision >= mf.debut_periode(d.periode, p_date)
       AND NOT EXISTS (SELECT 1 FROM mf.seance_dossier sd WHERE sd.demande_id = dc.id AND sd.decision = 'acceptation');
    IF v_cumul + p_montant <= d.montant_max_periode THEN RETURN true; END IF;
  END LOOP;
  RETURN false;
END $$;

-- ---------------------------------------------------------------------
-- Séances
-- ---------------------------------------------------------------------
CREATE TABLE seance_comite (
  id                  serial PRIMARY KEY,
  numero              varchar(30) NOT NULL UNIQUE,         -- posé par le déclencheur à partir de l'id
  comite_id           smallint NOT NULL REFERENCES comite_credit(id),
  date_seance         timestamptz NOT NULL,
  lieu                text,
  ordre_du_jour       text,
  statut              varchar(10) NOT NULL DEFAULT 'preparee' CHECK (statut IN ('preparee','convoquee','ouverte','close','annulee')),
  convoquee_le        timestamptz,
  convoquee_par       integer REFERENCES utilisateur(id),
  ouverte_le          timestamptz,
  close_le            timestamptz,
  pv_signe_president  timestamptz,
  pv_signe_secretaire timestamptz,
  cree_par            integer REFERENCES utilisateur(id),
  cree_le             timestamptz NOT NULL DEFAULT now()
);

CREATE FUNCTION trg_seance_numero() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF NEW.numero IS NULL OR NEW.numero = '' THEN
    NEW.numero := 'CC-' || (SELECT code FROM mf.comite_credit WHERE id = NEW.comite_id) || '-'
                  || to_char(NEW.date_seance, 'YYYY') || '-' || lpad(NEW.id::text, 5, '0');
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER seance_numero BEFORE INSERT ON seance_comite FOR EACH ROW EXECUTE FUNCTION trg_seance_numero();

CREATE TABLE seance_presence (
  seance_id       integer NOT NULL REFERENCES seance_comite(id),
  utilisateur_id  integer NOT NULL REFERENCES utilisateur(id),
  present         boolean,                          -- NULL = pas encore pointé
  motif_absence   text,
  PRIMARY KEY (seance_id, utilisateur_id)
);

-- ---------------------------------------------------------------------
-- Dossiers examinés, votes, récusations
-- ---------------------------------------------------------------------
CREATE TABLE seance_dossier (
  id                   serial PRIMARY KEY,
  seance_id            integer NOT NULL REFERENCES seance_comite(id),
  demande_id           integer NOT NULL REFERENCES demande_credit(id),
  rapporteur_id        integer REFERENCES utilisateur(id),
  montant_demande      numeric(14,0),                -- montant demandé à l'inscription (la demande peut être réduite par la décision)
  analyse_individuelle text,                         -- synthèse de l'instruction présentée au comité
  visite_le            date,
  visite_par           integer REFERENCES utilisateur(id),
  contre_visite_le     date,
  contre_visite_par    integer REFERENCES utilisateur(id),
  decision             varchar(12) CHECK (decision IN ('acceptation','ajournement','rejet')),
  motif                text,
  montant_accorde      numeric(14,0) CHECK (montant_accorde IS NULL OR montant_accorde > 0),
  conditions           text,                         -- conditions suspensives
  decide_le            timestamptz,
  UNIQUE (seance_id, demande_id),
  CHECK ((visite_le IS NULL) = (visite_par IS NULL)),
  CHECK ((contre_visite_le IS NULL) = (contre_visite_par IS NULL)),
  CHECK (contre_visite_par IS NULL OR contre_visite_par IS DISTINCT FROM visite_par),
  CHECK ((decision IS NULL) = (decide_le IS NULL))
);
-- un dossier n'est inscrit qu'à une seule séance non décidée à la fois
CREATE UNIQUE INDEX seance_dossier_en_cours ON seance_dossier(demande_id) WHERE decision IS NULL;

CREATE TABLE seance_vote (
  dossier_id      integer NOT NULL REFERENCES seance_dossier(id),
  utilisateur_id  integer NOT NULL REFERENCES utilisateur(id),
  vote            varchar(12) NOT NULL CHECK (vote IN ('acceptation','ajournement','rejet','abstention')),
  motif           text,
  vote_le         timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (dossier_id, utilisateur_id),
  CHECK (vote = 'abstention' OR length(btrim(COALESCE(motif, ''))) >= 5)
);

CREATE TABLE seance_recusation (
  dossier_id      integer NOT NULL REFERENCES seance_dossier(id),
  utilisateur_id  integer NOT NULL REFERENCES utilisateur(id),
  motif           text NOT NULL CHECK (length(btrim(motif)) >= 5),   -- conflit d'intérêts déclaré
  PRIMARY KEY (dossier_id, utilisateur_id)
);

-- ---------------------------------------------------------------------
-- Garde-fous
-- ---------------------------------------------------------------------
CREATE FUNCTION comite_membre_actif(p_comite integer, p_user integer, p_date date DEFAULT current_date)
RETURNS mf.comite_membre LANGUAGE sql STABLE AS $$
  SELECT m FROM mf.comite_membre m
   WHERE m.comite_id = p_comite AND m.utilisateur_id = p_user AND m.depuis <= p_date AND (m.jusqua IS NULL OR m.jusqua >= p_date)
$$;

-- Une séance close est figée ; une séance annulée aussi.
CREATE FUNCTION seance_modifiable(p_seance integer) RETURNS boolean LANGUAGE sql STABLE AS $$
  SELECT statut IN ('preparee','convoquee','ouverte') FROM mf.seance_comite WHERE id = p_seance
$$;

CREATE FUNCTION trg_seance_figee() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE v_seance integer;
BEGIN
  IF TG_TABLE_NAME IN ('seance_presence', 'seance_dossier') THEN
    v_seance := CASE WHEN TG_OP = 'DELETE' THEN OLD.seance_id ELSE NEW.seance_id END;
  ELSE
    SELECT seance_id INTO v_seance FROM mf.seance_dossier
     WHERE id = CASE WHEN TG_OP = 'DELETE' THEN OLD.dossier_id ELSE NEW.dossier_id END;
  END IF;
  IF NOT mf.seance_modifiable(v_seance) THEN
    RAISE EXCEPTION 'La séance est close ou annulée : le procès-verbal ne peut plus être modifié';
  END IF;
  RETURN COALESCE(NEW, OLD);
END $$;
CREATE TRIGGER seance_presence_figee BEFORE INSERT OR UPDATE OR DELETE ON seance_presence FOR EACH ROW EXECUTE FUNCTION trg_seance_figee();
CREATE TRIGGER seance_dossier_figee BEFORE INSERT OR UPDATE OR DELETE ON seance_dossier FOR EACH ROW EXECUTE FUNCTION trg_seance_figee();
CREATE TRIGGER seance_vote_figee BEFORE INSERT OR UPDATE OR DELETE ON seance_vote FOR EACH ROW EXECUTE FUNCTION trg_seance_figee();
CREATE TRIGGER seance_recusation_figee BEFORE INSERT OR UPDATE OR DELETE ON seance_recusation FOR EACH ROW EXECUTE FUNCTION trg_seance_figee();

CREATE FUNCTION trg_seance_figee_seance() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF OLD.statut IN ('close','annulee') THEN
    RAISE EXCEPTION 'La séance % est figée (statut %) : elle ne peut plus être modifiée', OLD.numero, OLD.statut;
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER seance_figee BEFORE UPDATE OR DELETE ON seance_comite FOR EACH ROW EXECUTE FUNCTION trg_seance_figee_seance();

-- Inscription d'un dossier : la demande doit être en attente et relever de la compétence du comité.
CREATE FUNCTION trg_seance_dossier_inscription() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE d mf.demande_credit; c mf.comite_credit; v_reseau smallint;
BEGIN
  IF TG_OP = 'UPDATE' AND NEW.demande_id = OLD.demande_id AND NEW.seance_id = OLD.seance_id THEN RETURN NEW; END IF;
  SELECT * INTO d FROM mf.demande_credit WHERE id = NEW.demande_id;
  SELECT c2.* INTO c FROM mf.comite_credit c2 JOIN mf.seance_comite s ON s.comite_id = c2.id WHERE s.id = NEW.seance_id;
  IF d.statut <> 'demandee' THEN
    RAISE EXCEPTION 'La demande % n''est plus en attente de décision (statut %)', d.numero, d.statut;
  END IF;
  NEW.montant_demande := d.montant;
  IF d.montant < c.montant_min OR (c.montant_max IS NOT NULL AND d.montant > c.montant_max) THEN
    RAISE EXCEPTION 'La demande % (% ) ne relève pas de la compétence du comité % (de % à %)',
      d.numero, d.montant, c.code, c.montant_min, COALESCE(c.montant_max::text, 'sans plafond');
  END IF;
  IF c.agence_id IS NOT NULL AND c.agence_id <> d.agence_id THEN
    RAISE EXCEPTION 'La demande % est d''une autre agence que celle du comité %', d.numero, c.code;
  END IF;
  IF c.reseau_id IS NOT NULL THEN
    SELECT reseau_id INTO v_reseau FROM mf.agence WHERE id = d.agence_id;
    IF v_reseau IS DISTINCT FROM c.reseau_id THEN
      RAISE EXCEPTION 'La demande % est d''un autre réseau que celui du comité %', d.numero, c.code;
    END IF;
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER seance_dossier_inscription BEFORE INSERT OR UPDATE ON seance_dossier FOR EACH ROW EXECUTE FUNCTION trg_seance_dossier_inscription();

-- Les décisions ne s'écrivent que par decider_dossier() ; une visite exige une personne distincte pour la contre-visite.
CREATE FUNCTION trg_seance_dossier_decision() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF (NEW.decision IS DISTINCT FROM OLD.decision) AND COALESCE(current_setting('mf.comite_decision', true), '') <> NEW.id::text THEN
    RAISE EXCEPTION 'La décision d''un dossier ne s''enregistre que par la procédure de décision du comité';
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER seance_dossier_decision BEFORE UPDATE ON seance_dossier FOR EACH ROW EXECUTE FUNCTION trg_seance_dossier_decision();

-- Vote : séance ouverte, votant membre actif avec voix, présent, non récusé, dossier non décidé.
CREATE FUNCTION trg_seance_vote_regles() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE s mf.seance_comite; dos mf.seance_dossier; m mf.comite_membre;
BEGIN
  SELECT * INTO dos FROM mf.seance_dossier WHERE id = NEW.dossier_id;
  SELECT * INTO s FROM mf.seance_comite WHERE id = dos.seance_id;
  IF s.statut <> 'ouverte' THEN RAISE EXCEPTION 'On ne vote que pendant une séance ouverte'; END IF;
  IF dos.decision IS NOT NULL THEN RAISE EXCEPTION 'Le dossier est déjà décidé'; END IF;
  m := mf.comite_membre_actif(s.comite_id, NEW.utilisateur_id, s.date_seance::date);
  IF m.id IS NULL THEN RAISE EXCEPTION 'Seuls les membres du comité votent'; END IF;
  IF NOT m.avec_voix THEN RAISE EXCEPTION 'Ce membre n''a que voix consultative'; END IF;
  IF NOT COALESCE((SELECT present FROM mf.seance_presence WHERE seance_id = s.id AND utilisateur_id = NEW.utilisateur_id), false) THEN
    RAISE EXCEPTION 'Un membre absent ne vote pas';
  END IF;
  IF EXISTS (SELECT 1 FROM mf.seance_recusation WHERE dossier_id = NEW.dossier_id AND utilisateur_id = NEW.utilisateur_id) THEN
    RAISE EXCEPTION 'Membre récusé pour ce dossier (conflit d''intérêts)';
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER seance_vote_regles BEFORE INSERT OR UPDATE ON seance_vote FOR EACH ROW EXECUTE FUNCTION trg_seance_vote_regles();

-- Un membre qui a déjà voté ne peut plus être récusé (la récusation précède le vote).
CREATE FUNCTION trg_seance_recusation_regles() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF EXISTS (SELECT 1 FROM mf.seance_vote WHERE dossier_id = NEW.dossier_id AND utilisateur_id = NEW.utilisateur_id) THEN
    RAISE EXCEPTION 'Ce membre a déjà voté : la récusation doit précéder le vote';
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER seance_recusation_regles BEFORE INSERT ON seance_recusation FOR EACH ROW EXECUTE FUNCTION trg_seance_recusation_regles();

-- ---------------------------------------------------------------------
-- Procédure : convoquer, pointer, ouvrir, décider, signer, clore
-- ---------------------------------------------------------------------
-- Convocation : ordre du jour, au moins un dossier, délai minimal, effectif suffisant. Crée la liste de présence.
CREATE FUNCTION convoquer_seance(p_seance integer, p_utilisateur integer DEFAULT NULL) RETURNS void
LANGUAGE plpgsql AS $$
DECLARE s mf.seance_comite; c mf.comite_credit; v_delai numeric; v_ag smallint; v_membres integer;
BEGIN
  SELECT * INTO s FROM mf.seance_comite WHERE id = p_seance FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'séance % inconnue', p_seance; END IF;
  IF s.statut <> 'preparee' THEN RAISE EXCEPTION 'La séance % n''est plus à convoquer (statut %)', s.numero, s.statut; END IF;
  SELECT * INTO c FROM mf.comite_credit WHERE id = s.comite_id;
  IF NOT c.actif THEN RAISE EXCEPTION 'Le comité % est inactif', c.code; END IF;
  IF btrim(COALESCE(s.ordre_du_jour, '')) = '' THEN RAISE EXCEPTION 'L''ordre du jour est obligatoire pour convoquer'; END IF;
  IF NOT EXISTS (SELECT 1 FROM mf.seance_dossier WHERE seance_id = p_seance) THEN
    RAISE EXCEPTION 'Aucun dossier inscrit à l''ordre du jour';
  END IF;
  v_ag := c.agence_id;
  v_delai := COALESCE(mf.param_num('comite_delai_convocation_h', v_ag), 24);
  IF s.date_seance < now() + make_interval(secs => (v_delai * 3600)::int) THEN
    RAISE EXCEPTION 'Délai de convocation insuffisant : % heure(s) au minimum avant la séance', v_delai;
  END IF;
  SELECT count(*) INTO v_membres FROM mf.comite_membre m
   WHERE m.comite_id = s.comite_id AND m.avec_voix AND m.depuis <= s.date_seance::date AND (m.jusqua IS NULL OR m.jusqua >= s.date_seance::date);
  IF v_membres < c.quorum THEN
    RAISE EXCEPTION 'Le comité n''a que % membre(s) avec voix pour un quorum de %', v_membres, c.quorum;
  END IF;
  INSERT INTO mf.seance_presence(seance_id, utilisateur_id)
    SELECT p_seance, m.utilisateur_id FROM mf.comite_membre m
     WHERE m.comite_id = s.comite_id AND m.depuis <= s.date_seance::date AND (m.jusqua IS NULL OR m.jusqua >= s.date_seance::date)
    ON CONFLICT DO NOTHING;
  UPDATE mf.seance_comite SET statut = 'convoquee', convoquee_le = now(), convoquee_par = p_utilisateur WHERE id = p_seance;
END $$;

CREATE FUNCTION pointer_presence(p_seance integer, p_utilisateur integer, p_present boolean, p_motif text DEFAULT NULL) RETURNS void
LANGUAGE plpgsql AS $$
BEGIN
  UPDATE mf.seance_presence SET present = p_present, motif_absence = CASE WHEN p_present THEN NULL ELSE p_motif END
   WHERE seance_id = p_seance AND utilisateur_id = p_utilisateur;
  IF NOT FOUND THEN RAISE EXCEPTION 'Cet utilisateur n''est pas convoqué à la séance'; END IF;
END $$;

-- Quorum d'une séance : présents avec voix >= quorum du comité ET majorité des membres avec voix.
CREATE FUNCTION seance_quorum(p_seance integer) RETURNS boolean LANGUAGE sql STABLE AS $$
  SELECT COALESCE((
    SELECT count(*) FILTER (WHERE p.present AND m.avec_voix) >= c.quorum
       AND count(*) FILTER (WHERE p.present AND m.avec_voix) * 2 > count(*) FILTER (WHERE m.avec_voix)
    FROM mf.seance_comite s
    JOIN mf.comite_credit c ON c.id = s.comite_id
    JOIN mf.seance_presence p ON p.seance_id = s.id
    JOIN mf.comite_membre m ON m.comite_id = s.comite_id AND m.utilisateur_id = p.utilisateur_id
    WHERE s.id = p_seance
    GROUP BY c.quorum
  ), false)
$$;

CREATE FUNCTION ouvrir_seance(p_seance integer) RETURNS void LANGUAGE plpgsql AS $$
DECLARE s mf.seance_comite;
BEGIN
  SELECT * INTO s FROM mf.seance_comite WHERE id = p_seance FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'séance % inconnue', p_seance; END IF;
  IF s.statut <> 'convoquee' THEN RAISE EXCEPTION 'La séance % doit être convoquée avant son ouverture', s.numero; END IF;
  IF EXISTS (SELECT 1 FROM mf.seance_presence WHERE seance_id = p_seance AND present IS NULL) THEN
    RAISE EXCEPTION 'La liste de présence n''est pas complète';
  END IF;
  IF NOT mf.seance_quorum(p_seance) THEN
    RAISE EXCEPTION 'Quorum non atteint : la séance ne peut pas s''ouvrir';
  END IF;
  UPDATE mf.seance_comite SET statut = 'ouverte', ouverte_le = now() WHERE id = p_seance;
END $$;

-- Décision d'un dossier. Voix de chacun requise ; acceptation / rejet à la majorité absolue des suffrages
-- exprimés (hors abstentions) ; égalité : voix prépondérante du président si elle va dans ce sens ; sinon ajournement.
CREATE FUNCTION decider_dossier(p_dossier integer, p_motif text, p_montant_accorde numeric DEFAULT NULL,
                                p_conditions text DEFAULT NULL, p_utilisateur integer DEFAULT NULL) RETURNS text
LANGUAGE plpgsql AS $$
DECLARE dos mf.seance_dossier; s mf.seance_comite; d mf.demande_credit; c mf.comite_credit;
        v_pour int; v_contre int; v_ajourne int; v_abst int; v_attendus int; v_vote_pres text; v_decision text;
        v_seuil_v numeric; v_seuil_cv numeric; v_pres integer; v_montant numeric; v_resp integer; v_votants integer[];
BEGIN
  SELECT * INTO dos FROM mf.seance_dossier WHERE id = p_dossier FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'dossier % inconnu', p_dossier; END IF;
  SELECT * INTO s FROM mf.seance_comite WHERE id = dos.seance_id;
  SELECT * INTO c FROM mf.comite_credit WHERE id = s.comite_id;
  SELECT * INTO d FROM mf.demande_credit WHERE id = dos.demande_id FOR UPDATE;
  IF s.statut <> 'ouverte' THEN RAISE EXCEPTION 'La séance n''est pas ouverte'; END IF;
  IF dos.decision IS NOT NULL THEN RAISE EXCEPTION 'Dossier déjà décidé'; END IF;
  IF btrim(COALESCE(p_motif, '')) = '' OR length(btrim(p_motif)) < 10 THEN
    RAISE EXCEPTION 'La décision doit être motivée (10 caractères au moins)';
  END IF;
  IF NOT mf.seance_quorum(s.id) THEN RAISE EXCEPTION 'Quorum perdu : décision impossible'; END IF;
  IF btrim(COALESCE(dos.analyse_individuelle, '')) = '' THEN
    RAISE EXCEPTION 'L''analyse individuelle du dossier doit être présentée avant la décision';
  END IF;

  -- visite et contre-visite selon le montant (seuils par agence)
  v_seuil_v  := COALESCE(mf.param_num('credit_visite_seuil', d.agence_id), 500000);
  v_seuil_cv := COALESCE(mf.param_num('credit_contre_visite_seuil', d.agence_id), 2000000);
  IF d.montant >= v_seuil_v AND dos.visite_le IS NULL THEN
    RAISE EXCEPTION 'Visite préalable obligatoire à partir de % (montant demandé %)', v_seuil_v, d.montant;
  END IF;
  IF d.montant >= v_seuil_cv AND dos.contre_visite_le IS NULL THEN
    RAISE EXCEPTION 'Contre-visite obligatoire à partir de % (montant demandé %)', v_seuil_cv, d.montant;
  END IF;

  -- votants attendus : présents avec voix, non récusés
  SELECT array_agg(p.utilisateur_id) INTO v_votants FROM mf.seance_presence p
      JOIN mf.comite_membre m ON m.comite_id = s.comite_id AND m.utilisateur_id = p.utilisateur_id
     WHERE p.seance_id = s.id AND p.present AND m.avec_voix
       AND NOT EXISTS (SELECT 1 FROM mf.seance_recusation r WHERE r.dossier_id = p_dossier AND r.utilisateur_id = p.utilisateur_id);
  v_attendus := COALESCE(array_length(v_votants, 1), 0);
  IF v_attendus = 0 THEN RAISE EXCEPTION 'Aucun votant éligible pour ce dossier'; END IF;
  IF EXISTS (SELECT 1 FROM unnest(v_votants) AS v(uid) WHERE NOT EXISTS
               (SELECT 1 FROM mf.seance_vote x WHERE x.dossier_id = p_dossier AND x.utilisateur_id = v.uid)) THEN
    RAISE EXCEPTION 'Tous les membres éligibles n''ont pas encore voté';
  END IF;

  SELECT count(*) FILTER (WHERE vote = 'acceptation'), count(*) FILTER (WHERE vote = 'rejet'),
         count(*) FILTER (WHERE vote = 'ajournement'), count(*) FILTER (WHERE vote = 'abstention')
    INTO v_pour, v_contre, v_ajourne, v_abst
    FROM mf.seance_vote WHERE dossier_id = p_dossier;
  SELECT m.utilisateur_id INTO v_pres FROM mf.comite_membre m WHERE m.comite_id = s.comite_id AND m.fonction = 'president' AND m.jusqua IS NULL;
  SELECT vote INTO v_vote_pres FROM mf.seance_vote WHERE dossier_id = p_dossier AND utilisateur_id = v_pres;

  IF v_pour > v_contre + v_ajourne THEN v_decision := 'acceptation';
  ELSIF v_contre > v_pour + v_ajourne THEN v_decision := 'rejet';
  ELSIF v_pour = v_contre + v_ajourne AND v_pour > 0 AND v_vote_pres = 'acceptation' THEN v_decision := 'acceptation';
  ELSIF v_contre = v_pour + v_ajourne AND v_contre > 0 AND v_vote_pres = 'rejet' THEN v_decision := 'rejet';
  ELSE v_decision := 'ajournement';
  END IF;

  v_montant := COALESCE(p_montant_accorde, d.montant);
  IF v_decision = 'acceptation' AND (v_montant <= 0 OR v_montant > d.montant) THEN
    RAISE EXCEPTION 'Le montant accordé (%) ne peut dépasser le montant demandé (%)', v_montant, d.montant;
  END IF;

  PERFORM set_config('mf.comite_decision', p_dossier::text, true);
  UPDATE mf.seance_dossier
     SET decision = v_decision, motif = p_motif, decide_le = now(), conditions = p_conditions,
         montant_accorde = CASE WHEN v_decision = 'acceptation' THEN v_montant END
   WHERE id = p_dossier;

  -- application à la demande de crédit (le président de séance est le validateur)
  v_resp := COALESCE(v_pres, p_utilisateur);
  IF v_decision = 'acceptation' THEN
    IF v_montant < d.montant THEN
      UPDATE mf.demande_credit SET montant = v_montant WHERE id = d.id;
    END IF;
    PERFORM mf.approuver_demande(d.id, v_resp, true,
      'Comité ' || c.code || ' — séance ' || s.numero || ' : ' || p_motif);
  ELSIF v_decision = 'rejet' THEN
    PERFORM mf.approuver_demande(d.id, v_resp, false,
      'Comité ' || c.code || ' — séance ' || s.numero || ' : ' || p_motif);
  ELSE
    UPDATE mf.demande_credit SET commentaire = 'Ajourné par le comité ' || c.code || ' (' || s.numero || ') : ' || p_motif WHERE id = d.id;
  END IF;
  PERFORM set_config('mf.comite_decision', '', true);
  RETURN v_decision;
END $$;

-- Signature du procès-verbal par le président et par le secrétaire de séance
CREATE FUNCTION signer_pv(p_seance integer, p_utilisateur integer) RETURNS text LANGUAGE plpgsql AS $$
DECLARE s mf.seance_comite; m mf.comite_membre;
BEGIN
  SELECT * INTO s FROM mf.seance_comite WHERE id = p_seance FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'séance % inconnue', p_seance; END IF;
  IF s.statut <> 'ouverte' THEN RAISE EXCEPTION 'Le procès-verbal se signe pendant la séance ouverte, avant la clôture'; END IF;
  IF EXISTS (SELECT 1 FROM mf.seance_dossier WHERE seance_id = p_seance AND decision IS NULL) THEN
    RAISE EXCEPTION 'Des dossiers inscrits n''ont pas été décidés';
  END IF;
  m := mf.comite_membre_actif(s.comite_id, p_utilisateur, s.date_seance::date);
  IF m.id IS NULL OR m.fonction NOT IN ('president','secretaire') THEN
    RAISE EXCEPTION 'Seuls le président et le secrétaire signent le procès-verbal';
  END IF;
  IF NOT COALESCE((SELECT present FROM mf.seance_presence WHERE seance_id = p_seance AND utilisateur_id = p_utilisateur), false) THEN
    RAISE EXCEPTION 'Le signataire doit avoir été présent';
  END IF;
  IF m.fonction = 'president' THEN
    UPDATE mf.seance_comite SET pv_signe_president = now() WHERE id = p_seance;
  ELSE
    UPDATE mf.seance_comite SET pv_signe_secretaire = now() WHERE id = p_seance;
  END IF;
  RETURN m.fonction;
END $$;

CREATE FUNCTION cloturer_seance(p_seance integer) RETURNS void LANGUAGE plpgsql AS $$
DECLARE s mf.seance_comite;
BEGIN
  SELECT * INTO s FROM mf.seance_comite WHERE id = p_seance FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'séance % inconnue', p_seance; END IF;
  IF s.statut <> 'ouverte' THEN RAISE EXCEPTION 'La séance % n''est pas ouverte', s.numero; END IF;
  IF EXISTS (SELECT 1 FROM mf.seance_dossier WHERE seance_id = p_seance AND decision IS NULL) THEN
    RAISE EXCEPTION 'Des dossiers inscrits n''ont pas été décidés';
  END IF;
  IF s.pv_signe_president IS NULL OR s.pv_signe_secretaire IS NULL THEN
    RAISE EXCEPTION 'Le procès-verbal doit être signé par le président et par le secrétaire';
  END IF;
  UPDATE mf.seance_comite SET statut = 'close', close_le = now() WHERE id = p_seance;
END $$;

CREATE FUNCTION annuler_seance(p_seance integer, p_motif text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  IF length(btrim(COALESCE(p_motif, ''))) < 5 THEN RAISE EXCEPTION 'Le motif d''annulation est obligatoire'; END IF;
  UPDATE mf.seance_comite SET statut = 'annulee', ordre_du_jour = COALESCE(ordre_du_jour, '') || E'\nANNULÉE : ' || p_motif
   WHERE id = p_seance AND statut IN ('preparee','convoquee','ouverte');
  IF NOT FOUND THEN RAISE EXCEPTION 'Séance introuvable ou déjà close'; END IF;
END $$;

-- ---------------------------------------------------------------------
-- Durcissement de la décision directe : en mode « comité obligatoire », seule la décision de comité
-- ou une délégation couvrant le montant permet d'approuver ou de refuser une demande.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION approuver_demande(p_demande integer, p_validateur integer DEFAULT NULL,
                                             p_approuve boolean DEFAULT true, p_commentaire text DEFAULT NULL,
                                             p_date date DEFAULT current_date) RETURNS void
LANGUAGE plpgsql AS $$
DECLARE d mf.demande_credit;
BEGIN
  SELECT * INTO d FROM mf.demande_credit WHERE id = p_demande FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'demande % inconnue', p_demande; END IF;
  IF d.statut <> 'demandee' THEN RAISE EXCEPTION 'demande % déjà traitée (statut %)', d.numero, d.statut; END IF;
  IF p_approuve AND p_validateur IS NULL AND d.montant > mf.param_num('seuil_validation_credit', d.agence_id) THEN
    RAISE EXCEPTION 'la demande % dépasse le seuil de validation : un validateur est obligatoire', d.numero;
  END IF;
  IF COALESCE(mf.param('comite_credit_obligatoire', d.agence_id), '0') = '1'
     AND COALESCE(current_setting('mf.comite_decision', true), '') = ''
     AND NOT mf.delegation_couvre(p_validateur, d.agence_id, d.montant, p_date) THEN
    RAISE EXCEPTION 'La demande % doit être décidée par le comité de crédit (ou par une délégation couvrant % )', d.numero, d.montant;
  END IF;
  UPDATE mf.demande_credit
     SET statut = CASE WHEN p_approuve THEN 'approuvee' ELSE 'refusee' END,
         validateur_id = p_validateur, commentaire = p_commentaire, date_decision = p_date
   WHERE id = p_demande;
END $$;

-- ---------------------------------------------------------------------
-- Analyse globale d'une séance (montants, répartition des décisions, portefeuille des agences concernées)
-- ---------------------------------------------------------------------
CREATE VIEW v_seance_analyse_globale AS
SELECT s.id AS seance_id, s.numero,
       count(sd.id)                                                        AS nb_dossiers,
       COALESCE(sum(COALESCE(sd.montant_demande, d.montant)), 0)           AS total_demande,
       COALESCE(sum(sd.montant_accorde) FILTER (WHERE sd.decision = 'acceptation'), 0) AS total_accorde,
       count(sd.id) FILTER (WHERE sd.decision = 'acceptation')             AS nb_acceptes,
       count(sd.id) FILTER (WHERE sd.decision = 'ajournement')             AS nb_ajournes,
       count(sd.id) FILTER (WHERE sd.decision = 'rejet')                   AS nb_rejetes,
       count(sd.id) FILTER (WHERE sd.decision IS NULL)                     AS nb_en_attente,
       COALESCE((SELECT sum(v.capital_restant) FROM mf.v_credit_situation v JOIN mf.credit c ON c.id = v.credit_id
                  WHERE c.agence_id IN (SELECT DISTINCT d2.agence_id FROM mf.seance_dossier sd2 JOIN mf.demande_credit d2 ON d2.id = sd2.demande_id WHERE sd2.seance_id = s.id)), 0)
         AS encours_agences_concernees
FROM mf.seance_comite s
LEFT JOIN mf.seance_dossier sd ON sd.seance_id = s.id
LEFT JOIN mf.demande_credit d ON d.id = sd.demande_id
GROUP BY s.id, s.numero;

-- Piste d'audit
CREATE TRIGGER audit_comite_credit AFTER INSERT OR UPDATE OR DELETE ON comite_credit FOR EACH ROW EXECUTE FUNCTION trg_audit();
CREATE TRIGGER audit_comite_membre AFTER INSERT OR UPDATE OR DELETE ON comite_membre FOR EACH ROW EXECUTE FUNCTION trg_audit();
CREATE TRIGGER audit_delegation_credit AFTER INSERT OR UPDATE OR DELETE ON delegation_credit FOR EACH ROW EXECUTE FUNCTION trg_audit();
CREATE TRIGGER audit_seance_comite AFTER INSERT OR UPDATE OR DELETE ON seance_comite FOR EACH ROW EXECUTE FUNCTION trg_audit();
CREATE TRIGGER audit_seance_dossier AFTER INSERT OR UPDATE OR DELETE ON seance_dossier FOR EACH ROW EXECUTE FUNCTION trg_audit();
CREATE TRIGGER audit_seance_vote AFTER INSERT OR UPDATE OR DELETE ON seance_vote FOR EACH ROW EXECUTE FUNCTION trg_audit();
