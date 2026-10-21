-- =====================================================================
-- 40_grh_conges_absences.sql
-- GRH — congés, absences et présences :
--   * jours fériés (globaux ou par agence) et décompte des jours ouvrés (lundi à vendredi)
--   * droits à congé annuel (jours par mois travaillé) et solde
--   * demande, décision (jamais par l'intéressé), annulation ; pas de chevauchement ; solde suffisant
--   * un congé approuvé pose les présences « conge » ; une présence ne contredit pas un congé
--   * pointage (arrivée, départ, motif) et synthèse mensuelle de l'absentéisme
-- Dépend de : 04, 39.
-- =====================================================================
SET search_path = mf, public;

INSERT INTO parametre(cle, valeur, description) VALUES
  ('conge_jours_par_mois', '2.5', 'Jours de congé annuel acquis par mois travaillé (provisoire : à valider avec le code du travail applicable)');

CREATE TABLE jour_ferie (
  id         serial PRIMARY KEY,
  date_jour  date NOT NULL,
  libelle    text NOT NULL,
  agence_id  smallint REFERENCES agence(id)          -- NULL = toutes les agences
);
CREATE UNIQUE INDEX jour_ferie_unique ON jour_ferie (date_jour, COALESCE(agence_id, 0));

ALTER TABLE conge DROP CONSTRAINT conge_type_check;
ALTER TABLE conge ADD CONSTRAINT conge_type_check CHECK (type IN
  ('annuel','maladie','maternite','paternite','permission','deuil','formation','sans_solde','autre'));
ALTER TABLE conge DROP CONSTRAINT conge_statut_check;
ALTER TABLE conge ADD CONSTRAINT conge_statut_check CHECK (statut IN ('demande','approuve','refuse','annule'));
ALTER TABLE conge
  ADD COLUMN jours_ouvres        numeric(5,1),
  ADD COLUMN motif               text,
  ADD COLUMN remplacant_id       integer REFERENCES employe(id),
  ADD COLUMN decide_par          integer REFERENCES utilisateur(id),
  ADD COLUMN decide_le           timestamptz,
  ADD COLUMN commentaire_decision text,
  ADD COLUMN cree_le             timestamptz NOT NULL DEFAULT now();

ALTER TABLE presence DROP CONSTRAINT presence_statut_check;
ALTER TABLE presence ALTER COLUMN statut TYPE varchar(20);
ALTER TABLE presence ADD CONSTRAINT presence_statut_check CHECK (statut IN ('present','absent','retard','conge','mission','absent_justifie','ferie'));
ALTER TABLE presence
  ADD COLUMN heure_arrivee time,
  ADD COLUMN heure_depart  time,
  ADD COLUMN motif         text,
  ADD CONSTRAINT presence_heures_coherentes CHECK (heure_arrivee IS NULL OR heure_depart IS NULL OR heure_depart > heure_arrivee);

-- Jours ouvrés (lundi à vendredi hors jours fériés) entre deux dates incluses
CREATE FUNCTION jours_ouvres(p_debut date, p_fin date, p_agence smallint DEFAULT NULL) RETURNS numeric
LANGUAGE sql STABLE AS $$
  SELECT count(*)::numeric FROM generate_series(p_debut, p_fin, interval '1 day') g(d)
   WHERE extract(isodow FROM g.d) < 6
     AND NOT EXISTS (SELECT 1 FROM mf.jour_ferie f WHERE f.date_jour = g.d::date AND (f.agence_id IS NULL OR f.agence_id = p_agence))
$$;

-- Congé annuel acquis (mois entiers travaillés x taux) et solde (acquis - congés annuels approuvés)
CREATE FUNCTION conge_acquis(p_employe integer, p_date date DEFAULT current_date) RETURNS numeric
LANGUAGE sql STABLE AS $$
  SELECT (GREATEST(0, (extract(year FROM age(p_date, e.date_embauche)) * 12 + extract(month FROM age(p_date, e.date_embauche)))::int)
          * COALESCE(mf.param_num('conge_jours_par_mois', e.agence_id), 2.5))::numeric
    FROM mf.employe e WHERE e.id = p_employe
$$;

CREATE FUNCTION solde_conge(p_employe integer, p_date date DEFAULT current_date) RETURNS numeric
LANGUAGE sql STABLE AS $$
  SELECT mf.conge_acquis(p_employe, p_date) - COALESCE((SELECT sum(jours_ouvres) FROM mf.conge
          WHERE employe_id = p_employe AND type = 'annuel' AND statut = 'approuve'), 0)
$$;

CREATE FUNCTION trg_conge_regles() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE e mf.employe; v_user_employe integer;
BEGIN
  SELECT * INTO e FROM mf.employe WHERE id = NEW.employe_id;
  NEW.jours_ouvres := mf.jours_ouvres(NEW.date_debut, NEW.date_fin, e.agence_id);
  IF NEW.jours_ouvres = 0 THEN RAISE EXCEPTION 'Cette période ne contient aucun jour ouvré'; END IF;
  IF e.statut <> 'actif' THEN RAISE EXCEPTION 'Employé sorti : aucun congé'; END IF;
  IF NEW.statut IN ('demande','approuve') AND EXISTS (
       SELECT 1 FROM mf.conge c WHERE c.employe_id = NEW.employe_id AND c.id IS DISTINCT FROM NEW.id
          AND c.statut IN ('demande','approuve') AND daterange(c.date_debut, c.date_fin, '[]') && daterange(NEW.date_debut, NEW.date_fin, '[]')) THEN
    RAISE EXCEPTION 'Cette période chevauche un autre congé de l''employé';
  END IF;
  IF NEW.statut = 'approuve' AND (TG_OP = 'INSERT' OR OLD.statut <> 'approuve') THEN
    IF NEW.decide_par IS NULL THEN RAISE EXCEPTION 'La décision doit être prise par un responsable identifié'; END IF;
    IF e.utilisateur_id IS NOT NULL AND e.utilisateur_id = NEW.decide_par THEN
      RAISE EXCEPTION 'Séparation des tâches : on n''approuve pas son propre congé';
    END IF;
    IF NEW.type = 'annuel' AND mf.solde_conge(NEW.employe_id, NEW.date_debut) < NEW.jours_ouvres THEN
      RAISE EXCEPTION 'Solde de congé insuffisant : % jour(s) disponible(s) pour % demandé(s)',
        mf.solde_conge(NEW.employe_id, NEW.date_debut), NEW.jours_ouvres;
    END IF;
    NEW.decide_le := now();
  END IF;
  IF NEW.statut = 'refuse' AND (TG_OP = 'INSERT' OR OLD.statut <> 'refuse') THEN
    IF NEW.decide_par IS NULL OR length(btrim(COALESCE(NEW.commentaire_decision, ''))) < 5 THEN
      RAISE EXCEPTION 'Un refus doit être motivé et attribué à son auteur';
    END IF;
    NEW.decide_le := now();
  END IF;
  IF TG_OP = 'UPDATE' AND OLD.statut IN ('refuse','annule') AND NEW.statut <> OLD.statut THEN
    RAISE EXCEPTION 'Un congé % ne se rouvre pas : refaire une demande', OLD.statut;
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER conge_regles BEFORE INSERT OR UPDATE ON conge FOR EACH ROW EXECUTE FUNCTION trg_conge_regles();

-- Les présences suivent le congé : posées à l'approbation, retirées à l'annulation
CREATE FUNCTION trg_conge_presences() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE v_ag smallint;
BEGIN
  SELECT agence_id INTO v_ag FROM mf.employe WHERE id = NEW.employe_id;
  IF NEW.statut = 'approuve' AND (TG_OP = 'INSERT' OR OLD.statut <> 'approuve') THEN
    INSERT INTO mf.presence(employe_id, date_jour, statut, motif)
    SELECT NEW.employe_id, g.d::date, 'conge', NEW.type
      FROM generate_series(NEW.date_debut, NEW.date_fin, interval '1 day') g(d)
     WHERE extract(isodow FROM g.d) < 6
       AND NOT EXISTS (SELECT 1 FROM mf.jour_ferie f WHERE f.date_jour = g.d::date AND (f.agence_id IS NULL OR f.agence_id = v_ag))
    ON CONFLICT (employe_id, date_jour) DO UPDATE SET statut = 'conge', motif = EXCLUDED.motif, heure_arrivee = NULL, heure_depart = NULL;
  ELSIF TG_OP = 'UPDATE' AND OLD.statut = 'approuve' AND NEW.statut = 'annule' THEN
    DELETE FROM mf.presence WHERE employe_id = NEW.employe_id AND statut = 'conge' AND date_jour BETWEEN NEW.date_debut AND NEW.date_fin;
  END IF;
  RETURN NULL;
END $$;
CREATE TRIGGER conge_presences AFTER INSERT OR UPDATE ON conge FOR EACH ROW EXECUTE FUNCTION trg_conge_presences();

-- Une présence ne contredit pas un congé approuvé ; pas de pointage dans le futur
CREATE FUNCTION trg_presence_regles() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF NEW.date_jour > current_date THEN RAISE EXCEPTION 'On ne pointe pas dans le futur'; END IF;
  IF NEW.statut IN ('present','retard','absent') AND EXISTS (
       SELECT 1 FROM mf.conge c WHERE c.employe_id = NEW.employe_id AND c.statut = 'approuve' AND NEW.date_jour BETWEEN c.date_debut AND c.date_fin) THEN
    RAISE EXCEPTION 'L''employé est en congé approuvé ce jour-là';
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER presence_regles BEFORE INSERT OR UPDATE ON presence FOR EACH ROW
  WHEN (NEW.statut <> 'conge') EXECUTE FUNCTION trg_presence_regles();

-- Pointage d'un employé (création ou correction du jour)
CREATE FUNCTION enregistrer_presence(p_employe integer, p_date date, p_statut text, p_arrivee time DEFAULT NULL,
                                     p_depart time DEFAULT NULL, p_motif text DEFAULT NULL) RETURNS integer
LANGUAGE plpgsql AS $$
DECLARE v_id integer; v_heures numeric;
BEGIN
  v_heures := CASE WHEN p_arrivee IS NOT NULL AND p_depart IS NOT NULL THEN round((extract(epoch FROM (p_depart - p_arrivee)) / 3600)::numeric, 1) END;
  INSERT INTO mf.presence(employe_id, date_jour, statut, heures, heure_arrivee, heure_depart, motif)
  VALUES (p_employe, p_date, p_statut, v_heures, p_arrivee, p_depart, p_motif)
  ON CONFLICT (employe_id, date_jour) DO UPDATE
    SET statut = EXCLUDED.statut, heures = EXCLUDED.heures, heure_arrivee = EXCLUDED.heure_arrivee,
        heure_depart = EXCLUDED.heure_depart, motif = EXCLUDED.motif
  RETURNING id INTO v_id;
  RETURN v_id;
END $$;

-- Synthèse mensuelle : absences, retards, congés, présences
CREATE VIEW v_absenteisme AS
SELECT e.id AS employe_id, e.agence_id, e.matricule, e.nom, date_trunc('month', p.date_jour)::date AS mois,
       count(*) FILTER (WHERE p.statut IN ('present','retard','mission')) AS jours_presents,
       count(*) FILTER (WHERE p.statut = 'absent') AS absences_injustifiees,
       count(*) FILTER (WHERE p.statut = 'absent_justifie') AS absences_justifiees,
       count(*) FILTER (WHERE p.statut = 'retard') AS retards,
       count(*) FILTER (WHERE p.statut = 'conge') AS jours_conge
  FROM mf.employe e JOIN mf.presence p ON p.employe_id = e.id
 GROUP BY e.id, date_trunc('month', p.date_jour);

CREATE TRIGGER audit_conge AFTER INSERT OR UPDATE OR DELETE ON conge FOR EACH ROW EXECUTE FUNCTION trg_audit();
CREATE TRIGGER audit_jour_ferie AFTER INSERT OR UPDATE OR DELETE ON jour_ferie FOR EACH ROW EXECUTE FUNCTION trg_audit();
