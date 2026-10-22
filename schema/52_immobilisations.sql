-- =====================================================================
-- 52_immobilisations.sql
-- Immobilisations, maintenance, réparation et alertes.
--   * catégories d'immobilisations (comptes d'immobilisation, d'amortissement et de dotation, durée)
--   * registre des immobilisations numérotées par agence, amortissement linéaire mensuel généré par rattrapage et sans doublon,
--     sortie (cession, rebut, perte) avec valeur nette comptable
--   * plans de maintenance préventive et interventions (préventives et réparations) avec coûts ; la clôture d'une intervention
--     coûteuse crée la charge « entretien et réparation à payer » (module 50) avec le tiers prestataire
--   * alertes : maintenance en retard ou à prévoir, réparation trop longue, panne urgente non traitée, garantie proche de la fin,
--     immobilisation totalement amortie
--   * écritures par catégorie (acquisition, dotation, sortie) via regle_comptable, si la comptabilisation automatique est active
-- Dépend de : 00 (agence, utilisateur, parametre), 05 (comptabilité), 50 (opérations), 51 (tiers).
-- =====================================================================
SET search_path = mf, public;

-- ---------------------------------------------------------------- catégories
CREATE TABLE categorie_immobilisation (
  code                varchar(30) PRIMARY KEY CHECK (code ~ '^[a-z0-9_]+$'),
  libelle             text NOT NULL,
  compte_immobilisation varchar(7) NOT NULL REFERENCES compte_comptable(code),
  compte_amortissement  varchar(7) REFERENCES compte_comptable(code),
  compte_dotation       varchar(7) REFERENCES compte_comptable(code),
  duree_annees        smallint CHECK (duree_annees IS NULL OR duree_annees BETWEEN 1 AND 50),
  comptes_valides     boolean NOT NULL DEFAULT false,
  actif               boolean NOT NULL DEFAULT true,
  CHECK ((duree_annees IS NULL) = (compte_amortissement IS NULL AND compte_dotation IS NULL))
);
COMMENT ON TABLE categorie_immobilisation IS 'Catégorie d''immobilisation : comptes et durée d''amortissement linéaire (durée vide : non amortissable, ex. terrain).';

INSERT INTO categorie_immobilisation(code, libelle, compte_immobilisation, compte_amortissement, compte_dotation, duree_annees) VALUES
  ('mobilier_bureau',        'Matériel et mobilier de bureau', '442134', '442834', '66112', 5),
  ('materiel_informatique',  'Matériel informatique',          '442138', '442838', '66112', 3),
  ('materiel_transport',     'Matériel de transport',          '442135', '442835', '66112', 5),
  ('amenagement_bureau',     'Aménagements de bureaux',        '442125', '442825', '66112', 10),
  ('installation_technique', 'Installations techniques',       '442124', '442824', '66112', 10),
  ('batiment',               'Bâtiments administratifs',       '442121', '442821', '66112', 20),
  ('terrain',                'Terrains',                       '442112', NULL,     NULL,    NULL);

-- règles comptables par catégorie : acquisition, dotation, sortie
CREATE FUNCTION trg_categorie_immobilisation_sync() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  INSERT INTO mf.regle_comptable(evenement, ligne, compte_debit, compte_credit, cle_montant, journal_code, libelle, actif)
    VALUES ('immo_acq_' || NEW.code, 1, NEW.compte_immobilisation, '33212', 'montant', 'OD', 'Acquisition : ' || NEW.libelle, NEW.actif)
    ON CONFLICT (evenement, ligne, (COALESCE(agence_id, 0))) DO UPDATE SET compte_debit = EXCLUDED.compte_debit, libelle = EXCLUDED.libelle, actif = EXCLUDED.actif;
  IF NEW.compte_dotation IS NOT NULL THEN
    INSERT INTO mf.regle_comptable(evenement, ligne, compte_debit, compte_credit, cle_montant, journal_code, libelle, actif)
      VALUES ('immo_amort_' || NEW.code, 1, NEW.compte_dotation, NEW.compte_amortissement, 'montant', 'OD', 'Dotation aux amortissements : ' || NEW.libelle, NEW.actif)
      ON CONFLICT (evenement, ligne, (COALESCE(agence_id, 0))) DO UPDATE SET compte_debit = EXCLUDED.compte_debit, compte_credit = EXCLUDED.compte_credit, libelle = EXCLUDED.libelle, actif = EXCLUDED.actif;
    INSERT INTO mf.regle_comptable(evenement, ligne, compte_debit, compte_credit, cle_montant, journal_code, libelle, actif)
      VALUES ('immo_sortie_' || NEW.code, 1, NEW.compte_amortissement, NEW.compte_immobilisation, 'cumul', 'OD', 'Sortie : amortissements cumulés', NEW.actif)
      ON CONFLICT (evenement, ligne, (COALESCE(agence_id, 0))) DO UPDATE SET compte_debit = EXCLUDED.compte_debit, compte_credit = EXCLUDED.compte_credit, actif = EXCLUDED.actif;
  END IF;
  INSERT INTO mf.regle_comptable(evenement, ligne, compte_debit, compte_credit, cle_montant, journal_code, libelle, actif)
    VALUES ('immo_sortie_' || NEW.code, 2, '62392', NEW.compte_immobilisation, 'vnc', 'OD', 'Sortie : valeur nette comptable', NEW.actif)
    ON CONFLICT (evenement, ligne, (COALESCE(agence_id, 0))) DO UPDATE SET compte_credit = EXCLUDED.compte_credit, actif = EXCLUDED.actif;
  RETURN NULL;
END $$;
CREATE TRIGGER categorie_immobilisation_sync AFTER INSERT OR UPDATE ON categorie_immobilisation FOR EACH ROW EXECUTE FUNCTION trg_categorie_immobilisation_sync();
CREATE TRIGGER audit_categorie_immobilisation AFTER INSERT OR UPDATE ON categorie_immobilisation FOR EACH ROW EXECUTE FUNCTION trg_audit();
-- les catégories ci-dessus ont été insérées avant la création du déclencheur : on génère leurs règles
UPDATE categorie_immobilisation SET actif = actif;

-- ---------------------------------------------------------------- registre des immobilisations
CREATE TABLE immobilisation (
  id                   serial PRIMARY KEY,
  agence_id            smallint NOT NULL REFERENCES agence(id),
  ordre                integer NOT NULL,
  numero               varchar(30) NOT NULL UNIQUE,
  designation          text NOT NULL CHECK (length(btrim(designation)) >= 3),
  categorie            varchar(30) NOT NULL REFERENCES categorie_immobilisation(code),
  date_acquisition     date NOT NULL,
  date_mise_en_service date NOT NULL,
  valeur_acquisition   numeric(14,0) NOT NULL CHECK (valeur_acquisition > 0),
  valeur_residuelle    numeric(14,0) NOT NULL DEFAULT 0 CHECK (valeur_residuelle >= 0),
  duree_annees         smallint CHECK (duree_annees IS NULL OR duree_annees BETWEEN 1 AND 50),
  tiers_id             integer REFERENCES tiers(id),
  reference_facture    text,
  numero_serie         text,
  localisation         text,
  date_fin_garantie    date,
  statut               varchar(14) NOT NULL DEFAULT 'en_service' CHECK (statut IN ('en_service','en_maintenance','hors_service','sortie')),
  date_sortie          date,
  type_sortie          varchar(8) CHECK (type_sortie IN ('cession','rebut','perte')),
  valeur_cession       numeric(14,0) CHECK (valeur_cession IS NULL OR valeur_cession >= 0),
  motif_sortie         text,
  cree_par             integer REFERENCES utilisateur(id),
  cree_le              timestamptz NOT NULL DEFAULT now(),
  UNIQUE (agence_id, ordre),
  CHECK (valeur_residuelle <= valeur_acquisition),
  CHECK (date_mise_en_service >= date_acquisition),
  CHECK ((statut = 'sortie') = (date_sortie IS NOT NULL))
);
CREATE INDEX immobilisation_statut_idx ON immobilisation(agence_id, statut);

CREATE TABLE amortissement_immobilisation (
  id                serial PRIMARY KEY,
  immobilisation_id integer NOT NULL REFERENCES immobilisation(id),
  annee             smallint NOT NULL,
  mois              smallint NOT NULL CHECK (mois BETWEEN 1 AND 12),
  montant           numeric(14,0) NOT NULL CHECK (montant > 0),
  cumul_apres       numeric(14,0) NOT NULL,
  cree_le           timestamptz NOT NULL DEFAULT now(),
  UNIQUE (immobilisation_id, annee, mois)
);
CREATE TRIGGER amortissement_immobilisation_ajout_seul BEFORE UPDATE OR DELETE ON amortissement_immobilisation FOR EACH ROW EXECUTE FUNCTION trg_ajout_seul();
CREATE TRIGGER audit_amortissement_immobilisation AFTER INSERT ON amortissement_immobilisation FOR EACH ROW EXECUTE FUNCTION trg_audit();

CREATE FUNCTION trg_immobilisation_regles() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE c mf.categorie_immobilisation; k mf.agence;
BEGIN
  IF TG_OP = 'INSERT' THEN
    SELECT * INTO c FROM mf.categorie_immobilisation WHERE code = NEW.categorie AND actif;
    IF c.code IS NULL THEN RAISE EXCEPTION 'Catégorie d''immobilisation inconnue ou inactive'; END IF;
    IF c.duree_annees IS NULL THEN
      NEW.duree_annees := NULL;
    ELSE
      NEW.duree_annees := COALESCE(NEW.duree_annees, c.duree_annees);
    END IF;
    IF NEW.tiers_id IS NOT NULL AND NOT EXISTS (SELECT 1 FROM mf.tiers WHERE id = NEW.tiers_id AND actif AND (agence_id IS NULL OR agence_id = NEW.agence_id)) THEN
      RAISE EXCEPTION 'Tiers inconnu, inactif ou rattaché à une autre agence';
    END IF;
    PERFORM pg_advisory_xact_lock(52, NEW.agence_id);
    SELECT COALESCE(max(ordre), 0) + 1 INTO NEW.ordre FROM mf.immobilisation WHERE agence_id = NEW.agence_id;
    SELECT * INTO k FROM mf.agence WHERE id = NEW.agence_id;
    NEW.numero := 'IMM-' || k.code || '-' || lpad(NEW.ordre::text, 6, '0');
    NEW.statut := 'en_service'; NEW.date_sortie := NULL;
  ELSE
    IF OLD.statut = 'sortie' THEN RAISE EXCEPTION 'Une immobilisation sortie ne se modifie plus'; END IF;
    IF (NEW.agence_id, NEW.numero, NEW.categorie, NEW.valeur_acquisition, NEW.date_mise_en_service, NEW.duree_annees, NEW.valeur_residuelle)
       IS DISTINCT FROM (OLD.agence_id, OLD.numero, OLD.categorie, OLD.valeur_acquisition, OLD.date_mise_en_service, OLD.duree_annees, OLD.valeur_residuelle) THEN
      RAISE EXCEPTION 'Les éléments qui fondent l''amortissement (valeur, catégorie, mise en service, durée) ne se modifient pas';
    END IF;
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER immobilisation_regles BEFORE INSERT OR UPDATE ON immobilisation FOR EACH ROW EXECUTE FUNCTION trg_immobilisation_regles();
CREATE TRIGGER audit_immobilisation AFTER INSERT OR UPDATE ON immobilisation FOR EACH ROW EXECUTE FUNCTION trg_audit();

-- écriture d'acquisition
CREATE FUNCTION trg_immobilisation_compta() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF mf.comptabilisation_active(NEW.agence_id) THEN
    PERFORM mf.comptabiliser('immo_acq_' || NEW.categorie, NEW.agence_id, NEW.date_acquisition, jsonb_build_object('montant', NEW.valeur_acquisition),
                             'immobilisation', NEW.id, 'Acquisition ' || NEW.numero || ' ' || NEW.designation);
  END IF;
  RETURN NULL;
END $$;
CREATE TRIGGER immobilisation_compta AFTER INSERT ON immobilisation FOR EACH ROW EXECUTE FUNCTION trg_immobilisation_compta();

-- amortissement linéaire mensuel : rattrape tous les mois dus jusqu'au mois de la date donnée ; rejouable sans effet
CREATE FUNCTION calculer_amortissements(p_agence smallint, p_jusqu date DEFAULT current_date, p_utilisateur integer DEFAULT NULL) RETURNS integer
LANGUAGE plpgsql AS $$
DECLARE i mf.immobilisation; v_mois date; v_fin date; v_base numeric; v_mensualite numeric; v_cumul numeric; v_montant numeric; v_n integer := 0; v_dernier date; v_aid integer;
BEGIN
  v_fin := date_trunc('month', p_jusqu)::date;
  FOR i IN SELECT * FROM mf.immobilisation WHERE duree_annees IS NOT NULL AND (p_agence IS NULL OR agence_id = p_agence) ORDER BY id FOR UPDATE LOOP
    v_base := i.valeur_acquisition - i.valeur_residuelle;
    v_mensualite := GREATEST(round(v_base / (i.duree_annees * 12)), 1);
    SELECT COALESCE(sum(montant), 0), max(make_date(annee, mois, 1)) INTO v_cumul, v_dernier FROM mf.amortissement_immobilisation WHERE immobilisation_id = i.id;
    v_mois := COALESCE((v_dernier + interval '1 month')::date, date_trunc('month', i.date_mise_en_service)::date);
    WHILE v_mois <= v_fin AND v_cumul < v_base AND (i.date_sortie IS NULL OR i.date_sortie >= (v_mois + interval '1 month')::date) LOOP
      v_montant := LEAST(v_mensualite, v_base - v_cumul);
      IF v_cumul + v_montant + v_mensualite > v_base THEN v_montant := v_base - v_cumul; END IF;     -- le dernier mois solde l'écart d'arrondi
      v_cumul := v_cumul + v_montant;
      INSERT INTO mf.amortissement_immobilisation(immobilisation_id, annee, mois, montant, cumul_apres)
        VALUES (i.id, extract(year FROM v_mois), extract(month FROM v_mois), v_montant, v_cumul)
        RETURNING id INTO v_aid;
      IF mf.comptabilisation_active(i.agence_id) THEN
        PERFORM mf.comptabiliser('immo_amort_' || i.categorie, i.agence_id, (v_mois + interval '1 month - 1 day')::date, jsonb_build_object('montant', v_montant),
                                 'amortissement_immobilisation', v_aid, 'Dotation ' || to_char(v_mois, 'MM/YYYY') || ' ' || i.numero);
      END IF;
      v_n := v_n + 1;
      v_mois := (v_mois + interval '1 month')::date;
    END LOOP;
  END LOOP;
  RETURN v_n;
END $$;

-- sortie de l'inventaire
CREATE FUNCTION sortir_immobilisation(p_id integer, p_date date, p_type text, p_valeur_cession numeric, p_motif text, p_utilisateur integer) RETURNS numeric
LANGUAGE plpgsql AS $$
DECLARE i mf.immobilisation; v_cumul numeric; v_vnc numeric;
BEGIN
  SELECT * INTO i FROM mf.immobilisation WHERE id = p_id FOR UPDATE;
  IF i.id IS NULL THEN RAISE EXCEPTION 'Immobilisation % introuvable', p_id; END IF;
  IF i.statut = 'sortie' THEN RAISE EXCEPTION 'Cette immobilisation est déjà sortie'; END IF;
  IF p_type NOT IN ('cession','rebut','perte') THEN RAISE EXCEPTION 'Type de sortie inconnu'; END IF;
  IF p_date < i.date_mise_en_service THEN RAISE EXCEPTION 'La sortie ne peut précéder la mise en service'; END IF;
  IF length(btrim(COALESCE(p_motif, ''))) < 5 THEN RAISE EXCEPTION 'Le motif de sortie est obligatoire'; END IF;
  IF p_type = 'cession' AND p_valeur_cession IS NULL THEN RAISE EXCEPTION 'Le prix de cession est obligatoire'; END IF;
  IF EXISTS (SELECT 1 FROM mf.intervention WHERE immobilisation_id = p_id AND statut IN ('signalee','planifiee','en_cours')) THEN
    RAISE EXCEPTION 'Des interventions sont encore ouvertes sur cette immobilisation';
  END IF;
  PERFORM mf.calculer_amortissements(i.agence_id, p_date - 1, p_utilisateur);      -- dotations jusqu'au mois précédant la sortie
  SELECT COALESCE(sum(montant), 0) INTO v_cumul FROM mf.amortissement_immobilisation WHERE immobilisation_id = p_id;
  v_vnc := i.valeur_acquisition - v_cumul;
  UPDATE mf.immobilisation SET statut = 'sortie', date_sortie = p_date, type_sortie = p_type, valeur_cession = p_valeur_cession, motif_sortie = p_motif WHERE id = p_id;
  UPDATE mf.plan_maintenance SET actif = false WHERE immobilisation_id = p_id;
  IF mf.comptabilisation_active(i.agence_id) THEN
    PERFORM mf.comptabiliser('immo_sortie_' || i.categorie, i.agence_id, p_date, jsonb_build_object('cumul', v_cumul, 'vnc', v_vnc), 'immobilisation', i.id, 'Sortie ' || i.numero || ' (' || p_type || ')');
  END IF;
  RETURN v_vnc;
END $$;

-- ---------------------------------------------------------------- maintenance
CREATE TABLE plan_maintenance (
  id                   serial PRIMARY KEY,
  immobilisation_id    integer NOT NULL REFERENCES immobilisation(id),
  libelle              text NOT NULL CHECK (length(btrim(libelle)) >= 3),
  periodicite_mois     smallint NOT NULL CHECK (periodicite_mois BETWEEN 1 AND 120),
  prochaine_echeance   date NOT NULL,
  derniere_realisation date,
  tiers_id             integer REFERENCES tiers(id),
  cout_prevu           numeric(14,0) CHECK (cout_prevu IS NULL OR cout_prevu >= 0),
  actif                boolean NOT NULL DEFAULT true
);
CREATE TRIGGER audit_plan_maintenance AFTER INSERT OR UPDATE ON plan_maintenance FOR EACH ROW EXECUTE FUNCTION trg_audit();

CREATE TABLE intervention (
  id                serial PRIMARY KEY,
  agence_id         smallint NOT NULL REFERENCES agence(id),
  immobilisation_id integer NOT NULL REFERENCES immobilisation(id),
  type              varchar(10) NOT NULL CHECK (type IN ('preventive','corrective')),
  plan_id           integer REFERENCES plan_maintenance(id),
  statut            varchar(10) NOT NULL DEFAULT 'signalee' CHECK (statut IN ('signalee','planifiee','en_cours','terminee','annulee')),
  priorite          varchar(8) NOT NULL DEFAULT 'normale' CHECK (priorite IN ('basse','normale','haute','urgente')),
  description       text NOT NULL CHECK (length(btrim(description)) >= 5),
  date_signalement  date NOT NULL DEFAULT current_date,
  signale_par       integer REFERENCES utilisateur(id),
  date_planifiee    date,
  date_debut        date,
  date_fin          date,
  tiers_id          integer REFERENCES tiers(id),
  cout_main_oeuvre  numeric(14,0) NOT NULL DEFAULT 0 CHECK (cout_main_oeuvre >= 0),
  cout_pieces       numeric(14,0) NOT NULL DEFAULT 0 CHECK (cout_pieces >= 0),
  cout_total        numeric(14,0) GENERATED ALWAYS AS (cout_main_oeuvre + cout_pieces) STORED,
  reference_facture text,
  operation_id      bigint REFERENCES operation_generale(id),
  resultat          text,
  cree_le           timestamptz NOT NULL DEFAULT now(),
  CHECK (date_fin IS NULL OR date_debut IS NULL OR date_fin >= date_debut)
);
CREATE INDEX intervention_immo_idx ON intervention(immobilisation_id, statut);

CREATE FUNCTION trg_intervention_regles() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE i mf.immobilisation;
BEGIN
  IF TG_OP = 'INSERT' THEN
    SELECT * INTO i FROM mf.immobilisation WHERE id = NEW.immobilisation_id;
    IF i.id IS NULL OR i.statut = 'sortie' THEN RAISE EXCEPTION 'Immobilisation inconnue ou sortie de l''inventaire'; END IF;
    NEW.agence_id := i.agence_id;
    IF NEW.tiers_id IS NOT NULL AND NOT EXISTS (SELECT 1 FROM mf.tiers WHERE id = NEW.tiers_id AND actif AND (agence_id IS NULL OR agence_id = NEW.agence_id)) THEN
      RAISE EXCEPTION 'Tiers inconnu, inactif ou rattaché à une autre agence';
    END IF;
    RETURN NEW;
  END IF;
  IF OLD.statut IN ('terminee','annulee') THEN
    -- seule exception : la liaison, juste après la clôture, de l'opération de dépense créée automatiquement
    IF NOT (OLD.operation_id IS NULL AND NEW.operation_id IS NOT NULL AND (to_jsonb(NEW) - 'operation_id' - 'cout_total') = (to_jsonb(OLD) - 'operation_id' - 'cout_total')) THEN
      RAISE EXCEPTION 'Une intervention terminée ou annulée ne se modifie plus';
    END IF;
    RETURN NEW;
  END IF;
  IF (NEW.immobilisation_id, NEW.agence_id, NEW.type) IS DISTINCT FROM (OLD.immobilisation_id, OLD.agence_id, OLD.type) THEN
    RAISE EXCEPTION 'L''immobilisation et le type d''une intervention ne se modifient pas';
  END IF;
  IF NEW.statut <> OLD.statut THEN
    IF NOT ((OLD.statut, NEW.statut) IN (('signalee','planifiee'),('signalee','en_cours'),('planifiee','en_cours'),('en_cours','terminee'),
                                          ('signalee','annulee'),('planifiee','annulee'),('en_cours','annulee'))) THEN
      RAISE EXCEPTION 'Changement d''état impossible : % -> %', OLD.statut, NEW.statut;
    END IF;
    IF NEW.statut = 'planifiee' AND NEW.date_planifiee IS NULL THEN RAISE EXCEPTION 'Une date de planification est obligatoire'; END IF;
    IF NEW.statut = 'en_cours' THEN NEW.date_debut := COALESCE(NEW.date_debut, current_date); END IF;
    IF NEW.statut = 'terminee' THEN
      IF NEW.date_fin IS NULL THEN RAISE EXCEPTION 'La date de fin est obligatoire'; END IF;
      IF length(btrim(COALESCE(NEW.resultat, ''))) < 5 THEN RAISE EXCEPTION 'Le résultat de l''intervention doit être renseigné'; END IF;
      IF NEW.cout_main_oeuvre + NEW.cout_pieces > 0 AND length(btrim(COALESCE(NEW.reference_facture, ''))) = 0 THEN RAISE EXCEPTION 'La référence de la facture est obligatoire quand l''intervention a un coût'; END IF;
    END IF;
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER intervention_regles BEFORE INSERT OR UPDATE ON intervention FOR EACH ROW EXECUTE FUNCTION trg_intervention_regles();
CREATE TRIGGER intervention_ni_suppression BEFORE DELETE ON intervention FOR EACH ROW EXECUTE FUNCTION trg_ajout_seul();
CREATE TRIGGER audit_intervention AFTER INSERT OR UPDATE ON intervention FOR EACH ROW EXECUTE FUNCTION trg_audit();

-- effets d'une intervention sur l'immobilisation, le plan et la dépense
CREATE FUNCTION trg_intervention_effets() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE i mf.immobilisation; v_tiers text; v_op bigint;
BEGIN
  SELECT * INTO i FROM mf.immobilisation WHERE id = NEW.immobilisation_id;
  IF TG_OP = 'INSERT' OR NEW.statut IS DISTINCT FROM OLD.statut THEN
    IF NEW.statut = 'en_cours' AND i.statut = 'en_service' THEN
      UPDATE mf.immobilisation SET statut = 'en_maintenance' WHERE id = i.id;
    ELSIF NEW.statut IN ('terminee','annulee') AND i.statut IN ('en_maintenance','hors_service')
          AND NOT EXISTS (SELECT 1 FROM mf.intervention WHERE immobilisation_id = i.id AND id <> NEW.id AND statut = 'en_cours') THEN
      UPDATE mf.immobilisation SET statut = 'en_service' WHERE id = i.id;
    END IF;
    IF NEW.statut = 'terminee' THEN
      IF NEW.plan_id IS NOT NULL THEN
        UPDATE mf.plan_maintenance SET derniere_realisation = NEW.date_fin,
               prochaine_echeance = (NEW.date_fin + (periodicite_mois || ' months')::interval)::date WHERE id = NEW.plan_id;
      END IF;
      IF NEW.cout_total > 0 AND NEW.operation_id IS NULL THEN
        SELECT nom INTO v_tiers FROM mf.tiers WHERE id = NEW.tiers_id;
        v_op := mf.saisir_operation_generale(NEW.agence_id, 'facture_entretien_a_payer', NEW.date_fin, NEW.cout_total, v_tiers, NEW.reference_facture,
                                             'Intervention n° ' || NEW.id || ' sur ' || i.numero, NULL, COALESCE(NEW.signale_par, i.cree_par), 'int-' || NEW.id, NEW.tiers_id);
        UPDATE mf.intervention SET operation_id = v_op WHERE id = NEW.id;
      END IF;
    END IF;
  END IF;
  RETURN NULL;
END $$;
CREATE TRIGGER intervention_effets AFTER INSERT OR UPDATE ON intervention FOR EACH ROW EXECUTE FUNCTION trg_intervention_effets();

CREATE VIEW v_immobilisation AS
SELECT i.*, c.libelle AS categorie_libelle, t.nom AS tiers_nom,
       COALESCE(a.cumul, 0)::numeric(14,0) AS cumul_amortissement,
       (i.valeur_acquisition - COALESCE(a.cumul, 0))::numeric(14,0) AS valeur_nette,
       (i.duree_annees IS NOT NULL AND COALESCE(a.cumul, 0) >= i.valeur_acquisition - i.valeur_residuelle) AS totalement_amortie,
       (SELECT count(*) FROM mf.intervention x WHERE x.immobilisation_id = i.id) AS nb_interventions
FROM mf.immobilisation i
JOIN mf.categorie_immobilisation c ON c.code = i.categorie
LEFT JOIN mf.tiers t ON t.id = i.tiers_id
LEFT JOIN LATERAL (SELECT sum(montant) AS cumul FROM mf.amortissement_immobilisation WHERE immobilisation_id = i.id) a ON true;

-- signalement d'une panne (réparation corrective)
CREATE FUNCTION signaler_panne(p_immobilisation integer, p_description text, p_priorite text, p_hors_service boolean, p_utilisateur integer) RETURNS integer
LANGUAGE plpgsql AS $$
DECLARE v_id integer;
BEGIN
  INSERT INTO mf.intervention(immobilisation_id, type, priorite, description, signale_par)
    VALUES (p_immobilisation, 'corrective', COALESCE(p_priorite, 'normale'), p_description, p_utilisateur) RETURNING id INTO v_id;
  IF p_hors_service THEN
    UPDATE mf.immobilisation SET statut = 'hors_service' WHERE id = p_immobilisation AND statut IN ('en_service','en_maintenance');
  END IF;
  RETURN v_id;
END $$;

-- interventions préventives à venir (rejouable sans effet : pas de doublon tant qu'une intervention du plan est ouverte)
INSERT INTO parametre(cle, valeur, description) VALUES
  ('maintenance_preavis_jours', '15', 'Jours avant l''échéance d''un plan de maintenance où l''intervention préventive est planifiée et signalée'),
  ('reparation_delai_jours', '15', 'Jours au-delà desquels une réparation non terminée est signalée'),
  ('garantie_preavis_jours', '30', 'Jours avant la fin de garantie d''une immobilisation pour la signaler')
ON CONFLICT DO NOTHING;

CREATE FUNCTION generer_interventions_preventives(p_date date DEFAULT current_date, p_utilisateur integer DEFAULT NULL) RETURNS integer
LANGUAGE plpgsql AS $$
DECLARE p record; v_n integer := 0;
BEGIN
  FOR p IN SELECT pl.*, i.agence_id FROM mf.plan_maintenance pl JOIN mf.immobilisation i ON i.id = pl.immobilisation_id
            WHERE pl.actif AND i.statut <> 'sortie'
              AND pl.prochaine_echeance <= p_date + COALESCE(mf.param_num('maintenance_preavis_jours', i.agence_id), 15)::int
              AND NOT EXISTS (SELECT 1 FROM mf.intervention x WHERE x.plan_id = pl.id AND x.statut IN ('signalee','planifiee','en_cours'))
            ORDER BY pl.id LOOP
    INSERT INTO mf.intervention(immobilisation_id, type, plan_id, statut, priorite, description, date_planifiee, tiers_id, signale_par)
      VALUES (p.immobilisation_id, 'preventive', p.id, 'planifiee', 'normale', p.libelle, p.prochaine_echeance, p.tiers_id, p_utilisateur);
    v_n := v_n + 1;
  END LOOP;
  RETURN v_n;
END $$;

CREATE VIEW v_intervention AS
SELECT x.*, i.numero AS immobilisation_numero, i.designation AS immobilisation, t.nom AS tiers_nom, u.nom AS signale_par_nom,
       (x.statut IN ('signalee','planifiee','en_cours')) AS ouverte,
       (current_date - x.date_signalement) AS age_jours
FROM mf.intervention x
JOIN mf.immobilisation i ON i.id = x.immobilisation_id
LEFT JOIN mf.tiers t ON t.id = x.tiers_id
LEFT JOIN mf.utilisateur u ON u.id = x.signale_par;

CREATE VIEW v_cout_maintenance AS
SELECT i.id AS immobilisation_id, i.agence_id, i.numero, i.designation, i.valeur_acquisition,
       count(x.id) FILTER (WHERE x.statut = 'terminee') AS nb_interventions,
       COALESCE(sum(x.cout_total) FILTER (WHERE x.statut = 'terminee'), 0)::numeric(14,0) AS cout_total,
       COALESCE(sum(x.cout_total) FILTER (WHERE x.statut = 'terminee' AND x.type = 'corrective'), 0)::numeric(14,0) AS cout_reparations,
       max(x.date_fin) AS derniere_intervention
FROM mf.immobilisation i LEFT JOIN mf.intervention x ON x.immobilisation_id = i.id
GROUP BY i.id;

-- ---------------------------------------------------------------- alertes
CREATE VIEW v_alerte_immobilisation AS
SELECT i.agence_id, 'maintenance_en_retard'::text AS type, i.numero AS reference,
       (pl.libelle || ' : échéance du ' || to_char(pl.prochaine_echeance, 'DD/MM/YYYY') || ' dépassée') AS detail, pl.prochaine_echeance AS echeance
FROM mf.plan_maintenance pl JOIN mf.immobilisation i ON i.id = pl.immobilisation_id
WHERE pl.actif AND i.statut <> 'sortie' AND pl.prochaine_echeance < current_date
  AND NOT EXISTS (SELECT 1 FROM mf.intervention x WHERE x.plan_id = pl.id AND x.statut = 'en_cours')
UNION ALL
SELECT i.agence_id, 'maintenance_a_prevoir', i.numero, (pl.libelle || ' : échéance le ' || to_char(pl.prochaine_echeance, 'DD/MM/YYYY')), pl.prochaine_echeance
FROM mf.plan_maintenance pl JOIN mf.immobilisation i ON i.id = pl.immobilisation_id
WHERE pl.actif AND i.statut <> 'sortie' AND pl.prochaine_echeance BETWEEN current_date AND current_date + COALESCE(mf.param_num('maintenance_preavis_jours', i.agence_id), 15)::int
UNION ALL
SELECT x.agence_id, 'reparation_longue', i.numero, ('Réparation ouverte depuis ' || (current_date - x.date_signalement) || ' jours : ' || x.description), x.date_signalement
FROM mf.intervention x JOIN mf.immobilisation i ON i.id = x.immobilisation_id
WHERE x.type = 'corrective' AND x.statut IN ('signalee','planifiee','en_cours')
  AND x.date_signalement < current_date - COALESCE(mf.param_num('reparation_delai_jours', x.agence_id), 15)::int
UNION ALL
SELECT x.agence_id, 'panne_urgente', i.numero, ('Panne urgente non prise en charge : ' || x.description), x.date_signalement
FROM mf.intervention x JOIN mf.immobilisation i ON i.id = x.immobilisation_id
WHERE x.type = 'corrective' AND x.priorite = 'urgente' AND x.statut = 'signalee'
UNION ALL
SELECT i.agence_id, 'garantie_proche_fin', i.numero, (i.designation || ' : garantie jusqu''au ' || to_char(i.date_fin_garantie, 'DD/MM/YYYY')), i.date_fin_garantie
FROM mf.immobilisation i
WHERE i.statut <> 'sortie' AND i.date_fin_garantie BETWEEN current_date AND current_date + COALESCE(mf.param_num('garantie_preavis_jours', i.agence_id), 30)::int
UNION ALL
SELECT v.agence_id, 'totalement_amortie', v.numero, (v.designation || ' est totalement amortie et toujours en service : renouvellement à prévoir'), NULL::date
FROM mf.v_immobilisation v WHERE v.statut IN ('en_service','en_maintenance') AND v.totalement_amortie;
