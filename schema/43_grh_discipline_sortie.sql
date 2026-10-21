-- =====================================================================
-- 43_grh_discipline_sortie.sql
-- GRH — discipline, sorties et indicateurs :
--   * sanctions graduées (avertissement verbal / écrit, blâme, mise à pied) : entretien préalable obligatoire dès
--     l'avertissement écrit, prescription des faits, décision par une autre personne que l'intéressé, sanction
--     notifiée non modifiable (annulation motivée seulement)
--   * sortie de l'employé : démission, licenciement, fin de CDD, retraite, décès, rupture conventionnelle ;
--     préavis, indemnité de congés restants, retenue des avances, solde de tout compte ;
--     la finalisation clôt le contrat, désactive le compte utilisateur et l'agent, annule les congés futurs
--   * indicateurs RH par agence : effectifs, ancienneté, masse salariale, turnover, absentéisme
-- Dépend de : 04, 11, 39, 40, 41.
-- =====================================================================
SET search_path = mf, public;

INSERT INTO parametre(cle, valeur, description) VALUES
  ('discipline_prescription_jours', '60', 'Au-delà de ce délai après les faits, plus de sanction possible (provisoire : à valider avec le droit du travail applicable)'),
  ('preavis_jours', '30', 'Préavis minimal (jours) en cas de démission ou de licenciement (provisoire : selon contrat et convention collective)'),
  ('jours_ouvres_par_mois', '22', 'Diviseur du salaire mensuel pour valoriser un jour de congé indemnisé');

-- ---------------------------------------------------------------- sanctions
CREATE TABLE sanction (
  id                      serial PRIMARY KEY,
  employe_id              integer NOT NULL REFERENCES employe(id),
  date_faits              date NOT NULL,
  type                    varchar(20) NOT NULL CHECK (type IN ('avertissement_verbal','avertissement_ecrit','blame','mise_a_pied')),
  motif                   text NOT NULL CHECK (length(btrim(motif)) >= 10),
  date_entretien_prealable date,
  jours_mise_a_pied       smallint CHECK (jours_mise_a_pied IS NULL OR jours_mise_a_pied BETWEEN 1 AND 30),
  explications_employe    text,
  statut                  varchar(10) NOT NULL DEFAULT 'proposee' CHECK (statut IN ('proposee','notifiee','annulee')),
  decide_par              integer REFERENCES utilisateur(id),
  date_notification       date,
  motif_annulation        text,
  cree_le                 timestamptz NOT NULL DEFAULT now(),
  CHECK ((type = 'mise_a_pied') = (jours_mise_a_pied IS NOT NULL)),
  CHECK (date_faits <= current_date),
  CHECK (statut <> 'annulee' OR length(btrim(COALESCE(motif_annulation, ''))) >= 5)
);

CREATE FUNCTION trg_sanction_regles() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE e mf.employe; v_presc numeric;
BEGIN
  SELECT * INTO e FROM mf.employe WHERE id = NEW.employe_id;
  IF TG_OP = 'UPDATE' AND OLD.statut IN ('notifiee','annulee') THEN
    IF NOT (OLD.statut = 'notifiee' AND NEW.statut = 'annulee') THEN
      RAISE EXCEPTION 'Une sanction notifiée ne se modifie pas : seule son annulation motivée est possible';
    END IF;
    IF (NEW.motif, NEW.type, NEW.date_faits, NEW.employe_id) IS DISTINCT FROM (OLD.motif, OLD.type, OLD.date_faits, OLD.employe_id) THEN
      RAISE EXCEPTION 'Une sanction notifiée ne se modifie pas';
    END IF;
    RETURN NEW;
  END IF;
  IF NEW.type <> 'avertissement_verbal' AND NEW.date_entretien_prealable IS NULL AND NEW.statut = 'notifiee' THEN
    RAISE EXCEPTION 'Entretien préalable obligatoire avant cette sanction';
  END IF;
  IF NEW.date_entretien_prealable IS NOT NULL AND NEW.date_entretien_prealable < NEW.date_faits THEN
    RAISE EXCEPTION 'L''entretien préalable ne peut précéder les faits';
  END IF;
  IF NEW.statut = 'notifiee' THEN
    IF NEW.decide_par IS NULL THEN RAISE EXCEPTION 'La sanction doit être attribuée à son auteur'; END IF;
    IF e.utilisateur_id IS NOT NULL AND e.utilisateur_id = NEW.decide_par THEN
      RAISE EXCEPTION 'Séparation des tâches : on ne prononce pas une sanction contre soi-même';
    END IF;
    v_presc := COALESCE(mf.param_num('discipline_prescription_jours', e.agence_id), 60);
    IF current_date - NEW.date_faits > v_presc THEN
      RAISE EXCEPTION 'Faits prescrits : plus de % jours depuis les faits', v_presc;
    END IF;
    IF NEW.date_notification IS NULL THEN NEW.date_notification := current_date; END IF;
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER sanction_regles BEFORE INSERT OR UPDATE ON sanction FOR EACH ROW EXECUTE FUNCTION trg_sanction_regles();

-- ---------------------------------------------------------------- sorties
CREATE TABLE sortie_employe (
  id                 serial PRIMARY KEY,
  employe_id         integer NOT NULL UNIQUE REFERENCES employe(id),
  type               varchar(25) NOT NULL CHECK (type IN ('demission','licenciement','fin_cdd','retraite','deces','rupture_conventionnelle')),
  date_notification  date NOT NULL,
  date_sortie        date NOT NULL,
  motif              text NOT NULL CHECK (length(btrim(motif)) >= 5),
  indemnite_conges   numeric(14,0) NOT NULL DEFAULT 0,
  retenue_avances    numeric(14,0) NOT NULL DEFAULT 0,
  solde_tout_compte  numeric(14,0) NOT NULL DEFAULT 0,        -- négatif : somme due par l'employé
  statut             varchar(10) NOT NULL DEFAULT 'en_cours' CHECK (statut IN ('en_cours','finalisee')),
  decide_par         integer REFERENCES utilisateur(id),
  finalisee_le       timestamptz,
  CHECK (date_sortie >= date_notification)
);

-- Calcule le solde de tout compte : congés restants valorisés - avances non remboursées
CREATE FUNCTION calculer_solde_tout_compte(p_employe integer, p_date_sortie date) RETURNS TABLE(indemnite_conges numeric, retenue_avances numeric, solde numeric)
LANGUAGE plpgsql STABLE AS $$
DECLARE v_base numeric; e mf.employe; v_indem numeric; v_av numeric;
BEGIN
  SELECT * INTO e FROM mf.employe WHERE id = p_employe;
  SELECT salaire_base INTO v_base FROM mf.contrat WHERE employe_id = p_employe AND date_debut <= p_date_sortie
     AND (date_fin IS NULL OR date_fin >= p_date_sortie) ORDER BY date_debut DESC LIMIT 1;
  v_indem := round(GREATEST(0, mf.solde_conge(p_employe, p_date_sortie)) * COALESCE(v_base, 0)
                   / COALESCE(mf.param_num('jours_ouvres_par_mois', e.agence_id), 22));
  SELECT COALESCE(sum(restant), 0) INTO v_av FROM mf.avance_salaire WHERE employe_id = p_employe AND statut = 'en_cours';
  RETURN QUERY SELECT v_indem, v_av, v_indem - v_av;
END $$;

CREATE FUNCTION preparer_sortie(p_employe integer, p_type text, p_date_notification date, p_date_sortie date, p_motif text,
                                p_decide_par integer DEFAULT NULL) RETURNS integer
LANGUAGE plpgsql AS $$
DECLARE e mf.employe; v_preavis numeric; v_id integer; c record;
BEGIN
  SELECT * INTO e FROM mf.employe WHERE id = p_employe FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'employé % inconnu', p_employe; END IF;
  IF e.statut <> 'actif' THEN RAISE EXCEPTION 'L''employé est déjà sorti'; END IF;
  IF e.utilisateur_id IS NOT NULL AND e.utilisateur_id = p_decide_par THEN
    RAISE EXCEPTION 'Séparation des tâches : on ne décide pas de sa propre sortie';
  END IF;
  IF p_type IN ('demission','licenciement') THEN
    v_preavis := COALESCE(mf.param_num('preavis_jours', e.agence_id), 30);
    IF p_date_sortie - p_date_notification < v_preavis THEN
      RAISE EXCEPTION 'Préavis insuffisant : % jours au moins entre la notification et la sortie', v_preavis;
    END IF;
  END IF;
  SELECT * INTO c FROM mf.calculer_solde_tout_compte(p_employe, p_date_sortie);
  INSERT INTO mf.sortie_employe(employe_id, type, date_notification, date_sortie, motif, indemnite_conges, retenue_avances, solde_tout_compte, decide_par)
  VALUES (p_employe, p_type, p_date_notification, p_date_sortie, p_motif, c.indemnite_conges, c.retenue_avances, c.solde, p_decide_par)
  RETURNING id INTO v_id;
  RETURN v_id;
END $$;

CREATE FUNCTION finaliser_sortie(p_sortie integer, p_utilisateur integer DEFAULT NULL) RETURNS void
LANGUAGE plpgsql AS $$
DECLARE s mf.sortie_employe; e mf.employe;
BEGIN
  SELECT * INTO s FROM mf.sortie_employe WHERE id = p_sortie FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'sortie % inconnue', p_sortie; END IF;
  IF s.statut = 'finalisee' THEN RAISE EXCEPTION 'Sortie déjà finalisée'; END IF;
  IF s.date_sortie > current_date THEN RAISE EXCEPTION 'La date de sortie (%) n''est pas atteinte', s.date_sortie; END IF;
  SELECT * INTO e FROM mf.employe WHERE id = s.employe_id FOR UPDATE;
  IF e.utilisateur_id IS NOT NULL AND e.utilisateur_id = p_utilisateur THEN
    RAISE EXCEPTION 'Séparation des tâches : on ne finalise pas sa propre sortie';
  END IF;
  -- recalcul à la date de finalisation : les avances et congés ont pu bouger
  UPDATE mf.sortie_employe SET (indemnite_conges, retenue_avances, solde_tout_compte) =
    (SELECT indemnite_conges, retenue_avances, solde FROM mf.calculer_solde_tout_compte(s.employe_id, s.date_sortie)) WHERE id = p_sortie;
  UPDATE mf.avance_salaire SET restant = 0, statut = 'soldee' WHERE employe_id = s.employe_id AND statut = 'en_cours';
  UPDATE mf.contrat SET date_fin = s.date_sortie WHERE employe_id = s.employe_id AND (date_fin IS NULL OR date_fin > s.date_sortie);
  UPDATE mf.conge SET statut = 'annule' WHERE employe_id = s.employe_id AND statut IN ('demande','approuve') AND date_debut > s.date_sortie;
  UPDATE mf.employe SET statut = 'sorti', date_sortie = s.date_sortie WHERE id = s.employe_id;
  IF e.utilisateur_id IS NOT NULL THEN UPDATE mf.utilisateur SET actif = false WHERE id = e.utilisateur_id; END IF;
  IF e.agent_id IS NOT NULL THEN UPDATE mf.agent SET actif = false WHERE id = e.agent_id; END IF;
  IF e.collectrice_id IS NOT NULL THEN UPDATE mf.collectrice SET actif = false WHERE id = e.collectrice_id; END IF;
  UPDATE mf.sortie_employe SET statut = 'finalisee', finalisee_le = now() WHERE id = p_sortie;
END $$;

-- ---------------------------------------------------------------- indicateurs
CREATE VIEW v_grh_indicateurs AS
SELECT a.id AS agence_id, a.code AS agence,
       (SELECT count(*) FROM mf.employe e WHERE e.agence_id = a.id AND e.statut = 'actif') AS effectif,
       (SELECT count(*) FROM mf.employe e WHERE e.agence_id = a.id AND e.statut = 'actif' AND e.sexe = 'F') AS femmes,
       (SELECT count(*) FROM mf.employe e WHERE e.agence_id = a.id AND e.statut = 'actif' AND e.sexe = 'M') AS hommes,
       (SELECT round(COALESCE(avg(extract(year FROM age(current_date, e.date_embauche)) + extract(month FROM age(current_date, e.date_embauche)) / 12.0), 0), 1)
          FROM mf.employe e WHERE e.agence_id = a.id AND e.statut = 'actif') AS anciennete_moyenne_ans,
       (SELECT COALESCE(sum(c.salaire_base), 0) FROM mf.contrat c JOIN mf.employe e ON e.id = c.employe_id
         WHERE e.agence_id = a.id AND e.statut = 'actif' AND c.date_debut <= current_date AND (c.date_fin IS NULL OR c.date_fin >= current_date)) AS masse_salariale,
       (SELECT count(*) FROM mf.employe e WHERE e.agence_id = a.id AND e.date_embauche >= current_date - 365) AS entrees_12m,
       (SELECT count(*) FROM mf.employe e WHERE e.agence_id = a.id AND e.date_sortie >= current_date - 365) AS sorties_12m,
       (SELECT count(*) FROM mf.conge c JOIN mf.employe e ON e.id = c.employe_id
         WHERE e.agence_id = a.id AND c.statut = 'approuve' AND current_date BETWEEN c.date_debut AND c.date_fin) AS en_conge_aujourdhui,
       (SELECT count(*) FROM mf.presence p JOIN mf.employe e ON e.id = p.employe_id
         WHERE e.agence_id = a.id AND p.statut IN ('absent','absent_justifie') AND p.date_jour >= date_trunc('month', current_date)::date) AS absences_du_mois,
       (SELECT count(*) FROM mf.besoin_recrutement b WHERE b.agence_id = a.id AND b.statut IN ('soumis','approuve')) AS besoins_ouverts
  FROM mf.agence a;

CREATE TRIGGER audit_sanction AFTER INSERT OR UPDATE OR DELETE ON sanction FOR EACH ROW EXECUTE FUNCTION trg_audit();
CREATE TRIGGER audit_sortie_employe AFTER INSERT OR UPDATE OR DELETE ON sortie_employe FOR EACH ROW EXECUTE FUNCTION trg_audit();
