-- =====================================================================
-- 42_grh_formation_evaluation.sql
-- GRH — formation et évaluation de la performance :
--   * catalogue de formations, sessions (capacité, coût), inscriptions, présence, validation avec certificat ;
--     pas d'inscription d'un employé sorti ou en congé approuvé pendant la session
--   * campagnes d'évaluation, évaluation par le supérieur direct sur des objectifs pondérés (total 100),
--     note globale pondérée, décision (maintien, augmentation, promotion, formation, alerte), validation
--     par une autre personne ; une évaluation validée est figée
-- Dépend de : 39, 40.
-- =====================================================================
SET search_path = mf, public;

-- ---------------------------------------------------------------- formation
CREATE TABLE formation (
  id             serial PRIMARY KEY,
  code           varchar(15) NOT NULL UNIQUE,
  titre          text NOT NULL,
  organisme      text,
  duree_heures   numeric(6,1) NOT NULL CHECK (duree_heures > 0),
  cout_unitaire  numeric(14,0) NOT NULL DEFAULT 0 CHECK (cout_unitaire >= 0),
  objectifs      text,
  actif          boolean NOT NULL DEFAULT true
);

CREATE TABLE session_formation (
  id            serial PRIMARY KEY,
  formation_id  integer NOT NULL REFERENCES formation(id),
  date_debut    date NOT NULL,
  date_fin      date NOT NULL,
  lieu          text,
  formateur     text,
  capacite      smallint NOT NULL DEFAULT 20 CHECK (capacite > 0),
  cout_total    numeric(14,0) CHECK (cout_total IS NULL OR cout_total >= 0),
  statut        varchar(10) NOT NULL DEFAULT 'planifiee' CHECK (statut IN ('planifiee','realisee','annulee')),
  CHECK (date_fin >= date_debut)
);

CREATE TABLE participation_formation (
  session_id       integer NOT NULL REFERENCES session_formation(id),
  employe_id       integer NOT NULL REFERENCES employe(id),
  statut           varchar(10) NOT NULL DEFAULT 'inscrit' CHECK (statut IN ('inscrit','present','absent','valide')),
  note             numeric(4,1) CHECK (note IS NULL OR note BETWEEN 0 AND 20),
  certificat_ref   text,
  inscrit_le       timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (session_id, employe_id)
);

CREATE FUNCTION trg_participation_regles() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE s mf.session_formation; e mf.employe; v_n integer;
BEGIN
  SELECT * INTO s FROM mf.session_formation WHERE id = NEW.session_id FOR UPDATE;
  IF TG_OP = 'INSERT' THEN
    IF s.statut <> 'planifiee' THEN RAISE EXCEPTION 'La session n''accepte plus d''inscription (statut %)', s.statut; END IF;
    SELECT * INTO e FROM mf.employe WHERE id = NEW.employe_id;
    IF e.statut <> 'actif' THEN RAISE EXCEPTION 'Employé sorti : pas d''inscription'; END IF;
    SELECT count(*) INTO v_n FROM mf.participation_formation WHERE session_id = NEW.session_id;
    IF v_n >= s.capacite THEN RAISE EXCEPTION 'Session complète (% places)', s.capacite; END IF;
    IF EXISTS (SELECT 1 FROM mf.conge c WHERE c.employe_id = NEW.employe_id AND c.statut = 'approuve'
                  AND daterange(c.date_debut, c.date_fin, '[]') && daterange(s.date_debut, s.date_fin, '[]')) THEN
      RAISE EXCEPTION 'L''employé est en congé approuvé pendant la session';
    END IF;
  ELSE
    IF NEW.statut IN ('present','absent','valide') AND s.date_debut > current_date THEN
      RAISE EXCEPTION 'La session n''a pas encore commencé';
    END IF;
    IF NEW.statut = 'valide' AND OLD.statut <> 'present' THEN
      RAISE EXCEPTION 'On ne valide qu''un participant présent';
    END IF;
    IF NEW.statut = 'valide' AND NEW.certificat_ref IS NULL THEN
      RAISE EXCEPTION 'Référence du certificat obligatoire pour valider la formation';
    END IF;
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER participation_regles BEFORE INSERT OR UPDATE ON participation_formation FOR EACH ROW EXECUTE FUNCTION trg_participation_regles();

CREATE VIEW v_formation_employe AS
SELECT e.id AS employe_id, e.agence_id, e.matricule, e.nom, extract(year FROM s.date_debut)::int AS annee,
       count(*) FILTER (WHERE p.statut = 'valide') AS formations_validees,
       COALESCE(sum(f.duree_heures) FILTER (WHERE p.statut IN ('present','valide')), 0) AS heures_suivies
  FROM mf.employe e JOIN mf.participation_formation p ON p.employe_id = e.id
  JOIN mf.session_formation s ON s.id = p.session_id JOIN mf.formation f ON f.id = s.formation_id
 GROUP BY e.id, extract(year FROM s.date_debut);

-- ---------------------------------------------------------------- évaluation
CREATE TABLE campagne_evaluation (
  id             serial PRIMARY KEY,
  libelle        text NOT NULL,
  periode_debut  date NOT NULL,
  periode_fin    date NOT NULL,
  statut         varchar(8) NOT NULL DEFAULT 'ouverte' CHECK (statut IN ('ouverte','close')),
  CHECK (periode_fin >= periode_debut)
);

CREATE TABLE evaluation (
  id                   serial PRIMARY KEY,
  campagne_id          integer NOT NULL REFERENCES campagne_evaluation(id),
  employe_id           integer NOT NULL REFERENCES employe(id),
  evaluateur_id        integer NOT NULL REFERENCES employe(id),
  statut               varchar(16) NOT NULL DEFAULT 'a_faire' CHECK (statut IN ('a_faire','auto_evaluation','evalue','validee')),
  note_globale         numeric(4,2) CHECK (note_globale IS NULL OR note_globale BETWEEN 0 AND 10),
  points_forts         text,
  axes_progres         text,
  decision             varchar(12) CHECK (decision IN ('maintien','augmentation','promotion','formation','alerte')),
  commentaire_employe  text,
  validee_par          integer REFERENCES utilisateur(id),
  validee_le           timestamptz,
  UNIQUE (campagne_id, employe_id),
  CHECK (evaluateur_id <> employe_id)
);

CREATE TABLE objectif_evaluation (
  id             serial PRIMARY KEY,
  evaluation_id  integer NOT NULL REFERENCES evaluation(id),
  libelle        text NOT NULL,
  poids          numeric(5,2) NOT NULL CHECK (poids > 0 AND poids <= 100),
  resultat       text,
  note           numeric(4,2) CHECK (note IS NULL OR note BETWEEN 0 AND 10)
);

-- Note globale = moyenne pondérée des notes d'objectifs
CREATE FUNCTION note_evaluation(p_evaluation integer) RETURNS numeric LANGUAGE sql STABLE AS $$
  SELECT round(sum(note * poids) / NULLIF(sum(poids), 0), 2) FROM mf.objectif_evaluation WHERE evaluation_id = p_evaluation AND note IS NOT NULL
$$;

CREATE FUNCTION trg_evaluation_regles() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE c mf.campagne_evaluation; v_poids numeric; v_sans_note integer; v_evaluateur_user integer;
BEGIN
  SELECT * INTO c FROM mf.campagne_evaluation WHERE id = NEW.campagne_id;
  IF TG_OP = 'INSERT' THEN
    IF c.statut <> 'ouverte' THEN RAISE EXCEPTION 'Campagne close : plus d''évaluation'; END IF;
    RETURN NEW;
  END IF;
  IF OLD.statut = 'validee' THEN RAISE EXCEPTION 'Une évaluation validée est figée'; END IF;
  IF NEW.statut IN ('evalue','validee') AND OLD.statut NOT IN ('evalue') THEN
    SELECT COALESCE(sum(poids), 0), count(*) FILTER (WHERE note IS NULL) INTO v_poids, v_sans_note
      FROM mf.objectif_evaluation WHERE evaluation_id = NEW.id;
    IF v_poids <> 100 THEN RAISE EXCEPTION 'Les poids des objectifs doivent totaliser 100 (actuellement %)', v_poids; END IF;
    IF v_sans_note > 0 THEN RAISE EXCEPTION 'Tous les objectifs doivent être notés'; END IF;
    NEW.note_globale := mf.note_evaluation(NEW.id);
  END IF;
  IF NEW.statut = 'validee' THEN
    IF NEW.decision IS NULL THEN RAISE EXCEPTION 'La décision est obligatoire pour valider'; END IF;
    IF NEW.validee_par IS NULL THEN RAISE EXCEPTION 'La validation doit être attribuée à son auteur'; END IF;
    SELECT utilisateur_id INTO v_evaluateur_user FROM mf.employe WHERE id = NEW.evaluateur_id;
    IF v_evaluateur_user IS NOT NULL AND v_evaluateur_user = NEW.validee_par THEN
      RAISE EXCEPTION 'Séparation des tâches : l''évaluateur ne valide pas sa propre évaluation';
    END IF;
    IF (SELECT utilisateur_id FROM mf.employe WHERE id = NEW.employe_id) = NEW.validee_par THEN
      RAISE EXCEPTION 'On ne valide pas sa propre évaluation';
    END IF;
    NEW.validee_le := now();
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER evaluation_regles BEFORE INSERT OR UPDATE ON evaluation FOR EACH ROW EXECUTE FUNCTION trg_evaluation_regles();

CREATE FUNCTION trg_objectif_fige() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE v_statut text;
BEGIN
  SELECT statut INTO v_statut FROM mf.evaluation WHERE id = COALESCE(NEW.evaluation_id, OLD.evaluation_id);
  IF v_statut = 'validee' THEN RAISE EXCEPTION 'Une évaluation validée est figée'; END IF;
  RETURN COALESCE(NEW, OLD);
END $$;
CREATE TRIGGER objectif_fige BEFORE INSERT OR UPDATE OR DELETE ON objectif_evaluation FOR EACH ROW EXECUTE FUNCTION trg_objectif_fige();

-- Ouvre les évaluations d'une campagne : tout employé actif ayant un supérieur direct est évalué par lui.
-- Retourne le nombre d'évaluations créées (les employés sans supérieur sont à traiter à la main).
CREATE FUNCTION ouvrir_evaluations(p_campagne integer, p_agence smallint DEFAULT NULL) RETURNS integer
LANGUAGE plpgsql AS $$
DECLARE v_n integer;
BEGIN
  INSERT INTO mf.evaluation(campagne_id, employe_id, evaluateur_id)
  SELECT p_campagne, e.id, e.superieur_id FROM mf.employe e
   WHERE e.statut = 'actif' AND e.superieur_id IS NOT NULL AND (p_agence IS NULL OR e.agence_id = p_agence)
     AND e.date_embauche <= (SELECT periode_fin FROM mf.campagne_evaluation WHERE id = p_campagne)
  ON CONFLICT (campagne_id, employe_id) DO NOTHING;
  GET DIAGNOSTICS v_n = ROW_COUNT;
  RETURN v_n;
END $$;

CREATE TRIGGER audit_evaluation AFTER INSERT OR UPDATE OR DELETE ON evaluation FOR EACH ROW EXECUTE FUNCTION trg_audit();
CREATE TRIGGER audit_participation_formation AFTER INSERT OR UPDATE OR DELETE ON participation_formation FOR EACH ROW EXECUTE FUNCTION trg_audit();
