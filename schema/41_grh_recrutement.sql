-- =====================================================================
-- 41_grh_recrutement.sql
-- GRH — recrutement :
--   * besoin de recrutement (poste, nombre, motif) décidé par une autre personne que le demandeur
--   * candidats, candidatures (une par candidat et par besoin), entretiens notés
--   * une candidature n'est « retenue » qu'après un entretien favorable de note suffisante
--   * embauche : crée l'employé et son contrat (salaire dans la fourchette du poste) ; le besoin est pourvu quand
--     le nombre de postes est atteint
-- Dépend de : 04, 39.
-- =====================================================================
SET search_path = mf, public;

INSERT INTO parametre(cle, valeur, description) VALUES
  ('recrutement_note_min', '6', 'Note minimale (sur 10) d''un entretien favorable pour retenir un candidat (provisoire)');

CREATE TABLE besoin_recrutement (
  id               serial PRIMARY KEY,
  agence_id        smallint NOT NULL REFERENCES agence(id),
  poste_id         integer NOT NULL REFERENCES poste(id),
  motif            text NOT NULL CHECK (length(btrim(motif)) >= 5),
  nb_postes        smallint NOT NULL DEFAULT 1 CHECK (nb_postes BETWEEN 1 AND 50),
  date_souhaitee   date,
  statut           varchar(10) NOT NULL DEFAULT 'soumis' CHECK (statut IN ('soumis','approuve','refuse','pourvu','annule')),
  demandeur_id     integer REFERENCES utilisateur(id),
  decide_par       integer REFERENCES utilisateur(id),
  decide_le        timestamptz,
  commentaire      text,
  cree_le          timestamptz NOT NULL DEFAULT now()
);

CREATE FUNCTION trg_besoin_regles() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF TG_OP = 'UPDATE' AND NEW.statut IN ('approuve','refuse') AND OLD.statut = 'soumis' THEN
    IF NEW.decide_par IS NULL THEN RAISE EXCEPTION 'La décision doit être attribuée à son auteur'; END IF;
    IF NEW.decide_par IS NOT DISTINCT FROM NEW.demandeur_id THEN
      RAISE EXCEPTION 'Séparation des tâches : le demandeur ne décide pas de son propre besoin';
    END IF;
    IF NEW.statut = 'refuse' AND length(btrim(COALESCE(NEW.commentaire, ''))) < 5 THEN
      RAISE EXCEPTION 'Un refus doit être motivé';
    END IF;
    NEW.decide_le := now();
  ELSIF TG_OP = 'UPDATE' AND NEW.statut IS DISTINCT FROM OLD.statut
        AND NOT ((OLD.statut = 'soumis' AND NEW.statut = 'annule') OR (OLD.statut = 'approuve' AND NEW.statut IN ('pourvu','annule'))) THEN
    RAISE EXCEPTION 'Transition impossible : % -> %', OLD.statut, NEW.statut;
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER besoin_regles BEFORE UPDATE ON besoin_recrutement FOR EACH ROW EXECUTE FUNCTION trg_besoin_regles();

CREATE TABLE candidat (
  id            serial PRIMARY KEY,
  nom           text NOT NULL,
  telephone     varchar(30),
  email         varchar(200),
  source        varchar(20) NOT NULL DEFAULT 'spontanee' CHECK (source IN ('spontanee','annonce','recommandation','cabinet','autre')),
  cv_reference  text,
  notes         text,
  cree_le       timestamptz NOT NULL DEFAULT now(),
  CHECK (telephone IS NOT NULL OR email IS NOT NULL)
);

CREATE TABLE candidature (
  id           serial PRIMARY KEY,
  besoin_id    integer NOT NULL REFERENCES besoin_recrutement(id),
  candidat_id  integer NOT NULL REFERENCES candidat(id),
  statut       varchar(15) NOT NULL DEFAULT 'recue' CHECK (statut IN ('recue','preselection','entretien','retenue','refusee','embauchee','desistement')),
  motif_refus  text,
  employe_id   integer REFERENCES employe(id),
  cree_le      timestamptz NOT NULL DEFAULT now(),
  UNIQUE (besoin_id, candidat_id),
  CHECK (statut <> 'refusee' OR length(btrim(COALESCE(motif_refus, ''))) >= 5)
);

CREATE TABLE entretien (
  id              serial PRIMARY KEY,
  candidature_id  integer NOT NULL REFERENCES candidature(id),
  date_entretien  date NOT NULL,
  type            varchar(12) NOT NULL DEFAULT 'rh' CHECK (type IN ('telephone','technique','rh','direction')),
  evaluateur_id   integer REFERENCES utilisateur(id),
  note            numeric(3,1) NOT NULL CHECK (note BETWEEN 0 AND 10),
  decision        varchar(12) NOT NULL CHECK (decision IN ('favorable','reserve','defavorable')),
  avis            text
);

CREATE FUNCTION trg_candidature_regles() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE b mf.besoin_recrutement; v_min numeric;
BEGIN
  SELECT * INTO b FROM mf.besoin_recrutement WHERE id = NEW.besoin_id;
  IF TG_OP = 'INSERT' AND b.statut <> 'approuve' THEN
    RAISE EXCEPTION 'On ne reçoit de candidature que pour un besoin approuvé (statut %)', b.statut;
  END IF;
  IF TG_OP = 'UPDATE' AND NEW.statut = 'retenue' AND OLD.statut <> 'retenue' THEN
    v_min := COALESCE(mf.param_num('recrutement_note_min', b.agence_id), 6);
    IF NOT EXISTS (SELECT 1 FROM mf.entretien WHERE candidature_id = NEW.id AND decision = 'favorable' AND note >= v_min) THEN
      RAISE EXCEPTION 'Candidature non retenable : aucun entretien favorable de note au moins %', v_min;
    END IF;
  END IF;
  IF TG_OP = 'UPDATE' AND OLD.statut IN ('embauchee','refusee','desistement') AND NEW.statut <> OLD.statut THEN
    RAISE EXCEPTION 'Candidature close (%)', OLD.statut;
  END IF;
  IF TG_OP = 'UPDATE' AND NEW.statut = 'embauchee' AND OLD.statut <> 'retenue' THEN
    RAISE EXCEPTION 'On n''embauche qu''un candidat retenu';
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER candidature_regles BEFORE INSERT OR UPDATE ON candidature FOR EACH ROW EXECUTE FUNCTION trg_candidature_regles();

-- Un entretien fait passer la candidature à « entretien » si elle n'était qu'à l'étape précédente
CREATE FUNCTION trg_entretien_etape() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  UPDATE mf.candidature SET statut = 'entretien' WHERE id = NEW.candidature_id AND statut IN ('recue','preselection');
  RETURN NULL;
END $$;
CREATE TRIGGER entretien_etape AFTER INSERT ON entretien FOR EACH ROW EXECUTE FUNCTION trg_entretien_etape();

-- Embauche d'un candidat retenu : employé + contrat, dans la fourchette de salaire du poste
CREATE FUNCTION embaucher_candidat(p_candidature integer, p_matricule text, p_date_embauche date, p_salaire numeric,
                                   p_type_contrat text DEFAULT 'cdi', p_date_fin date DEFAULT NULL, p_essai_fin date DEFAULT NULL)
RETURNS integer LANGUAGE plpgsql AS $$
DECLARE c mf.candidature; b mf.besoin_recrutement; p mf.poste; cd mf.candidat; v_emp integer; v_n integer;
BEGIN
  SELECT * INTO c FROM mf.candidature WHERE id = p_candidature FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'candidature % inconnue', p_candidature; END IF;
  IF c.statut <> 'retenue' THEN RAISE EXCEPTION 'On n''embauche qu''un candidat retenu (statut %)', c.statut; END IF;
  SELECT * INTO b FROM mf.besoin_recrutement WHERE id = c.besoin_id FOR UPDATE;
  IF b.statut <> 'approuve' THEN RAISE EXCEPTION 'Le besoin n''est plus ouvert (statut %)', b.statut; END IF;
  SELECT * INTO p FROM mf.poste WHERE id = b.poste_id;
  IF (p.salaire_min IS NOT NULL AND p_salaire < p.salaire_min) OR (p.salaire_max IS NOT NULL AND p_salaire > p.salaire_max) THEN
    RAISE EXCEPTION 'Salaire % hors de la fourchette du poste (% à %)', p_salaire, COALESCE(p.salaire_min::text, '…'), COALESCE(p.salaire_max::text, '…');
  END IF;
  SELECT * INTO cd FROM mf.candidat WHERE id = c.candidat_id;
  INSERT INTO mf.employe(agence_id, matricule, nom, poste, poste_id, service_id, date_embauche, telephone, email)
  VALUES (b.agence_id, p_matricule, cd.nom, p.libelle, p.id, p.service_id, p_date_embauche, cd.telephone, cd.email) RETURNING id INTO v_emp;
  INSERT INTO mf.contrat(employe_id, type, date_debut, date_fin, salaire_base, periode_essai_fin, poste_id, motif_cdd)
  VALUES (v_emp, p_type_contrat, p_date_embauche, p_date_fin, p_salaire, p_essai_fin, p.id,
          CASE WHEN p_type_contrat = 'cdd' THEN 'Recrutement pour le besoin ' || b.id END);
  UPDATE mf.candidature SET statut = 'embauchee', employe_id = v_emp WHERE id = p_candidature;
  SELECT count(*) INTO v_n FROM mf.candidature WHERE besoin_id = b.id AND statut = 'embauchee';
  IF v_n >= b.nb_postes THEN UPDATE mf.besoin_recrutement SET statut = 'pourvu' WHERE id = b.id; END IF;
  RETURN v_emp;
END $$;

-- Entonnoir de recrutement par besoin
CREATE VIEW v_recrutement AS
SELECT b.id AS besoin_id, b.agence_id, p.libelle AS poste, b.nb_postes, b.statut,
       count(c.id) AS candidatures,
       count(c.id) FILTER (WHERE c.statut IN ('entretien','retenue','embauchee')) AS en_entretien_ou_plus,
       count(c.id) FILTER (WHERE c.statut = 'retenue') AS retenues,
       count(c.id) FILTER (WHERE c.statut = 'embauchee') AS embauches
  FROM mf.besoin_recrutement b JOIN mf.poste p ON p.id = b.poste_id LEFT JOIN mf.candidature c ON c.besoin_id = b.id
 GROUP BY b.id, p.libelle;

CREATE TRIGGER audit_besoin_recrutement AFTER INSERT OR UPDATE OR DELETE ON besoin_recrutement FOR EACH ROW EXECUTE FUNCTION trg_audit();
CREATE TRIGGER audit_candidature AFTER INSERT OR UPDATE OR DELETE ON candidature FOR EACH ROW EXECUTE FUNCTION trg_audit();
