-- =====================================================================
-- 51_charges_produits.sql
-- Gestion des charges et des produits (au-dessus des opérations standard du module 50) :
--   * registre des tiers (fournisseurs, bailleurs, prestataires) relié aux opérations
--   * budget mensuel par agence et par opération standard (charge ou produit) ; comparaison prévu / réalisé
--   * opérations récurrentes hors caisse (loyer, abonnement...) générées à échéance, de façon idempotente
--   * alertes : dépassement de budget, opérations en attente de validation depuis trop longtemps, récurrentes en retard
-- Dépend de : 00 (agence, utilisateur, parametre), 50 (operation_standard, operation_generale).
-- =====================================================================
SET search_path = mf, public;

-- ---------------------------------------------------------------- tiers
CREATE TABLE tiers (
  id                 serial PRIMARY KEY,
  agence_id          smallint REFERENCES agence(id),          -- NULL : tiers commun à toutes les agences
  nom                text NOT NULL CHECK (length(btrim(nom)) >= 2),
  type               varchar(14) NOT NULL DEFAULT 'fournisseur' CHECK (type IN ('fournisseur','bailleur','prestataire','administration','autre')),
  telephone          varchar(20),
  adresse            text,
  identifiant_fiscal varchar(40),
  actif              boolean NOT NULL DEFAULT true,
  cree_le            timestamptz NOT NULL DEFAULT now()
);
CREATE UNIQUE INDEX tiers_nom_unique ON tiers (lower(btrim(nom)), COALESCE(agence_id, 0));
CREATE TRIGGER audit_tiers AFTER INSERT OR UPDATE ON tiers FOR EACH ROW EXECUTE FUNCTION trg_audit();

ALTER TABLE operation_generale ADD COLUMN tiers_id integer REFERENCES tiers(id);

-- la saisie accepte désormais un tiers du registre ; la vue l'expose
DROP VIEW v_operation_generale;
DROP FUNCTION saisir_operation_generale(smallint, text, date, numeric, text, text, text, integer, integer, text);
CREATE FUNCTION saisir_operation_generale(p_agence smallint, p_code text, p_date date, p_montant numeric, p_tiers text, p_reference text,
                                          p_libelle text, p_session integer, p_utilisateur integer, p_cle text DEFAULT NULL,
                                          p_tiers_id integer DEFAULT NULL) RETURNS bigint
LANGUAGE plpgsql AS $$
DECLARE s mf.operation_standard; v_id bigint; v_statut text; v_tiers mf.tiers;
BEGIN
  IF p_cle IS NOT NULL THEN
    SELECT id INTO v_id FROM mf.operation_generale WHERE cle = p_cle;
    IF v_id IS NOT NULL THEN RETURN v_id; END IF;
  END IF;
  SELECT * INTO s FROM mf.operation_standard WHERE code = p_code AND actif;
  IF s.code IS NULL THEN RAISE EXCEPTION 'Opération standard % inconnue ou inactive', p_code; END IF;
  IF s.justificatif_obligatoire AND length(btrim(COALESCE(p_reference, ''))) = 0 THEN
    RAISE EXCEPTION 'Un justificatif (référence de la pièce) est obligatoire pour « % »', s.libelle;
  END IF;
  IF p_tiers_id IS NOT NULL THEN
    SELECT * INTO v_tiers FROM mf.tiers WHERE id = p_tiers_id AND actif;
    IF v_tiers.id IS NULL THEN RAISE EXCEPTION 'Tiers inconnu ou inactif'; END IF;
    IF v_tiers.agence_id IS NOT NULL AND v_tiers.agence_id <> p_agence THEN RAISE EXCEPTION 'Ce tiers appartient à une autre agence'; END IF;
    p_tiers := COALESCE(p_tiers, v_tiers.nom);
  END IF;
  IF s.famille = 'caisse' AND p_session IS NULL THEN RAISE EXCEPTION 'Une opération de caisse exige une session de caisse ouverte'; END IF;
  IF s.famille = 'caisse' AND NOT EXISTS (SELECT 1 FROM mf.session_caisse WHERE id = p_session AND statut = 'ouverte') THEN
    RAISE EXCEPTION 'La session de caisse n''est pas ouverte';
  END IF;
  IF s.famille = 'hors_caisse' AND p_session IS NOT NULL THEN RAISE EXCEPTION 'Une opération hors caisse n''utilise pas de session de caisse'; END IF;
  v_statut := CASE WHEN s.seuil_validation IS NOT NULL AND p_montant >= s.seuil_validation THEN 'a_valider' ELSE 'valide' END;
  INSERT INTO mf.operation_generale(agence_id, code_operation, date_operation, montant, tiers, tiers_id, reference_justificatif, libelle, session_id, statut, cle, saisi_par)
    VALUES (p_agence, p_code, p_date, p_montant, p_tiers, p_tiers_id, p_reference, p_libelle, p_session, 'a_valider', p_cle, p_utilisateur) RETURNING id INTO v_id;
  IF v_statut = 'valide' THEN
    PERFORM mf.executer_operation_generale(v_id, p_session);
    UPDATE mf.operation_generale SET statut = 'valide', decide_par = p_utilisateur, commentaire_decision = 'Sous le seuil de validation' WHERE id = v_id;
  END IF;
  RETURN v_id;
END $$;

CREATE VIEW v_operation_generale AS
SELECT o.*, s.libelle AS operation, s.famille, s.categorie, s.sens, s.seuil_validation, us.nom AS saisi_par_nom, ud.nom AS decide_par_nom,
       k.code AS caisse, t.nom AS tiers_nom
FROM mf.operation_generale o
JOIN mf.operation_standard s ON s.code = o.code_operation
LEFT JOIN mf.utilisateur us ON us.id = o.saisi_par
LEFT JOIN mf.utilisateur ud ON ud.id = o.decide_par
LEFT JOIN mf.session_caisse sc ON sc.id = o.session_id
LEFT JOIN mf.caisse k ON k.id = sc.caisse_id
LEFT JOIN mf.tiers t ON t.id = o.tiers_id;

-- ---------------------------------------------------------------- budget mensuel
CREATE TABLE budget_ligne (
  id             serial PRIMARY KEY,
  agence_id      smallint NOT NULL REFERENCES agence(id),
  annee          smallint NOT NULL CHECK (annee BETWEEN 2000 AND 2100),
  mois           smallint NOT NULL CHECK (mois BETWEEN 1 AND 12),
  code_operation varchar(30) NOT NULL REFERENCES operation_standard(code),
  montant_prevu  numeric(14,0) NOT NULL CHECK (montant_prevu >= 0),
  commentaire    text,
  cree_par       integer REFERENCES utilisateur(id),
  maj_le         timestamptz NOT NULL DEFAULT now(),
  UNIQUE (agence_id, annee, mois, code_operation)
);
CREATE FUNCTION trg_budget_ligne_regles() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE v_cat text;
BEGIN
  SELECT categorie INTO v_cat FROM mf.operation_standard WHERE code = NEW.code_operation;
  IF v_cat NOT IN ('charge','produit') THEN RAISE EXCEPTION 'Un budget ne porte que sur des charges ou des produits (opération %, catégorie %)', NEW.code_operation, v_cat; END IF;
  NEW.maj_le := now();
  RETURN NEW;
END $$;
CREATE TRIGGER budget_ligne_regles BEFORE INSERT OR UPDATE ON budget_ligne FOR EACH ROW EXECUTE FUNCTION trg_budget_ligne_regles();
CREATE TRIGGER audit_budget_ligne AFTER INSERT OR UPDATE OR DELETE ON budget_ligne FOR EACH ROW EXECUTE FUNCTION trg_audit();

-- réalisé : opérations validées de catégorie charge ou produit
CREATE VIEW v_realise_mensuel AS
SELECT o.agence_id, extract(year FROM o.date_operation)::smallint AS annee, extract(month FROM o.date_operation)::smallint AS mois,
       s.categorie, o.code_operation, s.libelle, sum(o.montant)::numeric(14,0) AS realise, count(*) AS nb
FROM mf.operation_generale o JOIN mf.operation_standard s ON s.code = o.code_operation
WHERE o.statut = 'valide' AND s.categorie IN ('charge','produit')
GROUP BY o.agence_id, extract(year FROM o.date_operation), extract(month FROM o.date_operation), s.categorie, o.code_operation, s.libelle;

CREATE VIEW v_budget_realise AS
SELECT COALESCE(b.agence_id, r.agence_id) AS agence_id, COALESCE(b.annee, r.annee) AS annee, COALESCE(b.mois, r.mois) AS mois,
       s.categorie, s.code AS code_operation, s.libelle,
       COALESCE(b.montant_prevu, 0)::numeric(14,0) AS prevu, COALESCE(r.realise, 0)::numeric(14,0) AS realise,
       (COALESCE(r.realise, 0) - COALESCE(b.montant_prevu, 0))::numeric(14,0) AS ecart,
       CASE WHEN COALESCE(b.montant_prevu, 0) = 0 THEN NULL ELSE round(100.0 * COALESCE(r.realise, 0) / b.montant_prevu, 1) END AS taux,
       (s.categorie = 'charge' AND COALESCE(b.montant_prevu, 0) > 0 AND COALESCE(r.realise, 0) > b.montant_prevu) AS depassement
FROM mf.budget_ligne b
FULL JOIN mf.v_realise_mensuel r ON r.agence_id = b.agence_id AND r.annee = b.annee AND r.mois = b.mois AND r.code_operation = b.code_operation
JOIN mf.operation_standard s ON s.code = COALESCE(b.code_operation, r.code_operation);

-- ---------------------------------------------------------------- opérations récurrentes hors caisse
CREATE TABLE operation_recurrente (
  id                  serial PRIMARY KEY,
  agence_id           smallint NOT NULL REFERENCES agence(id),
  code_operation      varchar(30) NOT NULL REFERENCES operation_standard(code),
  montant             numeric(14,0) NOT NULL CHECK (montant > 0),
  tiers_id            integer REFERENCES tiers(id),
  libelle             text,
  periodicite         varchar(14) NOT NULL CHECK (periodicite IN ('mensuelle','trimestrielle','annuelle')),
  jour_du_mois        smallint NOT NULL DEFAULT 1 CHECK (jour_du_mois BETWEEN 1 AND 28),
  prochaine_date      date NOT NULL,
  date_fin            date,
  actif               boolean NOT NULL DEFAULT true,
  derniere_generation date,
  cree_par            integer REFERENCES utilisateur(id)
);
CREATE FUNCTION trg_operation_recurrente_regles() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE s mf.operation_standard;
BEGIN
  SELECT * INTO s FROM mf.operation_standard WHERE code = NEW.code_operation;
  IF s.famille <> 'hors_caisse' THEN RAISE EXCEPTION 'Seule une opération hors caisse peut être récurrente : une opération de caisse exige une session ouverte'; END IF;
  IF TG_OP = 'INSERT' AND NEW.date_fin IS NOT NULL AND NEW.date_fin < NEW.prochaine_date THEN RAISE EXCEPTION 'La date de fin précède la première échéance'; END IF;
  IF NEW.tiers_id IS NOT NULL AND NOT EXISTS (SELECT 1 FROM mf.tiers WHERE id = NEW.tiers_id AND actif AND (agence_id IS NULL OR agence_id = NEW.agence_id)) THEN
    RAISE EXCEPTION 'Tiers inconnu, inactif ou rattaché à une autre agence';
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER operation_recurrente_regles BEFORE INSERT OR UPDATE ON operation_recurrente FOR EACH ROW EXECUTE FUNCTION trg_operation_recurrente_regles();
CREATE TRIGGER audit_operation_recurrente AFTER INSERT OR UPDATE ON operation_recurrente FOR EACH ROW EXECUTE FUNCTION trg_audit();

CREATE FUNCTION date_suivante(p_date date, p_periodicite text, p_jour integer) RETURNS date LANGUAGE sql IMMUTABLE AS $$
  SELECT (date_trunc('month', p_date) + (CASE p_periodicite WHEN 'mensuelle' THEN 1 WHEN 'trimestrielle' THEN 3 ELSE 12 END) * interval '1 month'
          + (p_jour - 1) * interval '1 day')::date
$$;

-- génère les opérations dues jusqu'à la date donnée ; rejouable sans effet (clé d'idempotence par échéance)
CREATE FUNCTION generer_operations_recurrentes(p_jusqu date DEFAULT current_date, p_utilisateur integer DEFAULT NULL) RETURNS integer
LANGUAGE plpgsql AS $$
DECLARE r mf.operation_recurrente; v_date date; v_n integer := 0; v_tiers text; v_garde integer;
BEGIN
  IF p_utilisateur IS NULL THEN RAISE EXCEPTION 'La génération des opérations récurrentes doit être attribuée à un utilisateur'; END IF;
  FOR r IN SELECT * FROM mf.operation_recurrente WHERE actif AND prochaine_date <= p_jusqu ORDER BY id FOR UPDATE LOOP
    v_date := r.prochaine_date; v_garde := 0;
    SELECT nom INTO v_tiers FROM mf.tiers WHERE id = r.tiers_id;
    WHILE v_date <= p_jusqu AND (r.date_fin IS NULL OR v_date <= r.date_fin) AND v_garde < 36 LOOP
      PERFORM mf.saisir_operation_generale(r.agence_id, r.code_operation, v_date, r.montant, v_tiers, 'REC-' || r.id || '-' || to_char(v_date, 'YYYYMM'),
                                           COALESCE(r.libelle, 'Opération récurrente'), NULL, p_utilisateur, 'rec-' || r.id || '-' || v_date, r.tiers_id);
      v_n := v_n + 1; v_garde := v_garde + 1;
      v_date := mf.date_suivante(v_date, r.periodicite, r.jour_du_mois);
    END LOOP;
    UPDATE mf.operation_recurrente SET prochaine_date = v_date, derniere_generation = p_jusqu,
           actif = (date_fin IS NULL OR v_date <= date_fin) WHERE id = r.id;
  END LOOP;
  RETURN v_n;
END $$;

-- ---------------------------------------------------------------- alertes
INSERT INTO parametre(cle, valeur, description) VALUES
  ('operation_validation_delai_jours', '2', 'Jours au-delà desquels une opération en attente de validation est signalée'),
  ('recurrente_tolerance_jours', '3', 'Jours de tolérance avant de signaler une opération récurrente non générée')
ON CONFLICT DO NOTHING;

CREATE VIEW v_alerte_charge_produit AS
SELECT agence_id, 'depassement_budget'::text AS type, (code_operation || ' ' || annee || '-' || lpad(mois::text, 2, '0')) AS reference,
       (libelle || ' : réalisé ' || realise || ' F pour ' || prevu || ' F prévus (' || taux || ' %)') AS detail, ecart AS montant
FROM mf.v_budget_realise WHERE depassement
UNION ALL
SELECT agence_id, 'operation_a_valider', 'OP-' || id, (operation || ' en attente depuis le ' || to_char(saisi_le, 'DD/MM/YYYY')), montant
FROM mf.v_operation_generale
WHERE statut = 'a_valider' AND saisi_le < now() - make_interval(days => COALESCE(mf.param_num('operation_validation_delai_jours', agence_id), 2)::int)
UNION ALL
SELECT r.agence_id, 'recurrente_en_retard', 'REC-' || r.id, (s.libelle || ' : échéance du ' || to_char(r.prochaine_date, 'DD/MM/YYYY') || ' non générée'), r.montant
FROM mf.operation_recurrente r JOIN mf.operation_standard s ON s.code = r.code_operation
WHERE r.actif AND r.prochaine_date < current_date - COALESCE(mf.param_num('recurrente_tolerance_jours', r.agence_id), 3)::int;
