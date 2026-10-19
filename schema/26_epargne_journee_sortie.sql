-- =====================================================================
-- 26_epargne_journee_sortie.sql
-- Compléments de l'épargne classique et de l'adhésion.
--   1. Annulation d'un dépôt ou d'un retrait du jour par contre-passation (jamais de suppression : la comptabilisation
--      automatique et la piste d'audit restent cohérentes). Un dépôt ne s'annule que si le solde disponible le permet.
--   2. Validation globale de la journée d'épargne par agence : plus de dépôt, retrait ni annulation ce jour-là.
--      rouvrir_journee_epargne la lève (motif obligatoire, tracée).
--   3. Sortie d'un membre : radier_adhesion rembourse les parts (capital libéré) et radie l'adhésion, à condition qu'aucun
--      compte d'épargne ne soit actif avec un solde, qu'aucun cycle de tontine ne soit en cours et qu'aucun crédit ne soit non soldé.
-- Dépend de : 01, 02 (mouvements), 03 (crédit), 24 (adhésion).
-- =====================================================================
SET search_path = mf, public;

CREATE TABLE annulation_mouvement (
  mouvement_id   bigint PRIMARY KEY REFERENCES mouvement_epargne(id),
  contre_id      bigint NOT NULL UNIQUE REFERENCES mouvement_epargne(id),
  utilisateur_id integer REFERENCES utilisateur(id),
  cree_le        timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE validation_epargne (
  agence_id      smallint NOT NULL REFERENCES agence(id),
  date_operation date NOT NULL,
  valide_par     integer REFERENCES utilisateur(id),
  valide_le      timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (agence_id, date_operation)
);

CREATE TABLE validation_epargne_journal (
  id             bigserial PRIMARY KEY,
  agence_id      smallint NOT NULL REFERENCES agence(id),
  date_operation date NOT NULL,
  action         varchar(10) NOT NULL CHECK (action IN ('validee','rouverte')),
  utilisateur_id integer REFERENCES utilisateur(id),
  motif          text,
  cree_le        timestamptz NOT NULL DEFAULT now()
);

-- Verrou : pas de dépôt ni de retrait sur une journée validée
CREATE FUNCTION trg_epargne_jour_valide() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE v_agence smallint;
BEGIN
  IF NEW.type NOT IN ('depot', 'retrait') THEN RETURN NEW; END IF;
  SELECT agence_id INTO v_agence FROM mf.compte_epargne WHERE id = NEW.compte_id;
  IF EXISTS (SELECT 1 FROM mf.validation_epargne WHERE agence_id = v_agence AND date_operation = NEW.date_operation) THEN
    RAISE EXCEPTION 'la journée d''épargne du % est validée : opération refusée', NEW.date_operation;
  END IF;
  RETURN NEW;
END $$;
-- nom précédant « mouvement_controle » dans l'ordre alphabétique des déclencheurs : le verrou passe en premier
CREATE TRIGGER mouvement_a_jour_valide BEFORE INSERT ON mouvement_epargne
  FOR EACH ROW EXECUTE FUNCTION trg_epargne_jour_valide();

CREATE FUNCTION valider_journee_epargne(p_agence smallint, p_date date, p_utilisateur integer DEFAULT NULL) RETURNS void
LANGUAGE plpgsql AS $$
BEGIN
  IF p_date > current_date THEN RAISE EXCEPTION 'impossible de valider une journée à venir'; END IF;
  IF EXISTS (SELECT 1 FROM mf.validation_epargne WHERE agence_id = p_agence AND date_operation = p_date) THEN
    RAISE EXCEPTION 'la journée d''épargne du % est déjà validée', p_date;
  END IF;
  INSERT INTO mf.validation_epargne(agence_id, date_operation, valide_par) VALUES (p_agence, p_date, p_utilisateur);
  INSERT INTO mf.validation_epargne_journal(agence_id, date_operation, action, utilisateur_id) VALUES (p_agence, p_date, 'validee', p_utilisateur);
END $$;

CREATE FUNCTION rouvrir_journee_epargne(p_agence smallint, p_date date, p_motif text, p_utilisateur integer DEFAULT NULL) RETURNS void
LANGUAGE plpgsql AS $$
BEGIN
  IF p_motif IS NULL OR btrim(p_motif) = '' THEN RAISE EXCEPTION 'un motif est obligatoire pour rouvrir une journée'; END IF;
  DELETE FROM mf.validation_epargne WHERE agence_id = p_agence AND date_operation = p_date;
  IF NOT FOUND THEN RAISE EXCEPTION 'la journée d''épargne du % n''est pas validée', p_date; END IF;
  INSERT INTO mf.validation_epargne_journal(agence_id, date_operation, action, utilisateur_id, motif) VALUES (p_agence, p_date, 'rouverte', p_utilisateur, p_motif);
END $$;

-- Contre-passation d'un dépôt ou d'un retrait (même date que l'opération). Retourne l'id du mouvement inverse.
CREATE FUNCTION annuler_mouvement_epargne(p_mouvement bigint, p_utilisateur integer DEFAULT NULL) RETURNS bigint
LANGUAGE plpgsql AS $$
DECLARE m mf.mouvement_epargne; v_contre bigint;
BEGIN
  SELECT * INTO m FROM mf.mouvement_epargne WHERE id = p_mouvement;
  IF NOT FOUND THEN RAISE EXCEPTION 'mouvement % inconnu', p_mouvement; END IF;
  IF m.type NOT IN ('depot', 'retrait') THEN RAISE EXCEPTION 'seuls un dépôt ou un retrait s''annulent ici'; END IF;
  IF m.reference LIKE 'annulation:%' THEN RAISE EXCEPTION 'une annulation ne s''annule pas'; END IF;
  IF EXISTS (SELECT 1 FROM mf.annulation_mouvement WHERE mouvement_id = p_mouvement) THEN
    RAISE EXCEPTION 'le mouvement % est déjà annulé', p_mouvement;
  END IF;
  INSERT INTO mf.mouvement_epargne(compte_id, type, montant, date_operation, libelle, reference)
  VALUES (m.compte_id, CASE m.type WHEN 'depot' THEN 'retrait' ELSE 'depot' END, m.montant, m.date_operation,
          'Annulation du ' || m.type || ' n° ' || m.id, 'annulation:' || m.id)
  RETURNING id INTO v_contre;
  INSERT INTO mf.annulation_mouvement(mouvement_id, contre_id, utilisateur_id) VALUES (p_mouvement, v_contre, p_utilisateur);
  RETURN v_contre;
END $$;

-- Sortie d'un membre : remboursement des parts et radiation
CREATE TABLE remboursement_part (
  id              serial PRIMARY KEY,
  adhesion_id     integer NOT NULL UNIQUE REFERENCES adhesion(id),
  nb_parts        integer NOT NULL CHECK (nb_parts >= 0),
  montant         numeric(14,0) NOT NULL CHECK (montant >= 0),
  date_operation  date NOT NULL,
  utilisateur_id  integer REFERENCES utilisateur(id),
  cree_le         timestamptz NOT NULL DEFAULT now()
);

CREATE FUNCTION radier_adhesion(p_client integer, p_date date DEFAULT current_date, p_utilisateur integer DEFAULT NULL) RETURNS numeric
LANGUAGE plpgsql AS $$
DECLARE a mf.adhesion; v_parts integer; v_montant numeric;
BEGIN
  SELECT * INTO a FROM mf.adhesion WHERE client_id = p_client FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'le client % n''a pas d''adhésion', p_client; END IF;
  IF a.statut <> 'active' THEN RAISE EXCEPTION 'adhésion % déjà radiée', a.numero; END IF;
  IF p_date > current_date THEN RAISE EXCEPTION 'la date de sortie ne peut pas être dans le futur'; END IF;
  IF EXISTS (SELECT 1 FROM mf.compte_epargne ce JOIN mf.v_solde_compte_epargne v ON v.compte_id = ce.id
              WHERE ce.client_id = p_client AND ce.statut <> 'clos' AND v.solde > 0) THEN
    RAISE EXCEPTION 'sortie refusée : un compte d''épargne du client a encore un solde';
  END IF;
  IF EXISTS (SELECT 1 FROM mf.cycle WHERE client_id = p_client AND statut = 'en_cours') THEN
    RAISE EXCEPTION 'sortie refusée : une souscription de tontine est en cours';
  END IF;
  IF EXISTS (SELECT 1 FROM mf.credit WHERE client_id = p_client AND statut <> 'solde') THEN
    RAISE EXCEPTION 'sortie refusée : un crédit n''est pas soldé';
  END IF;
  SELECT COALESCE(sum(nb_parts), 0), COALESCE(sum(montant), 0) INTO v_parts, v_montant FROM mf.souscription_part WHERE adhesion_id = a.id;
  INSERT INTO mf.remboursement_part(adhesion_id, nb_parts, montant, date_operation, utilisateur_id) VALUES (a.id, v_parts, v_montant, p_date, p_utilisateur);
  UPDATE mf.adhesion SET statut = 'radiee' WHERE id = a.id;
  RETURN v_montant;
END $$;
