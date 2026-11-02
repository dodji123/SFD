-- =====================================================================
-- 23_validation_collecte.sql
-- Saisie de collecte au guichet : agent responsable d'une zone, correction des lignes et validation globale de la journée.
--   1. zone.agent_id : l'agent commercial qui collecte dans la zone (choisir l'un propose l'autre à la saisie).
--   2. modifier_ligne_collecte / supprimer_ligne_collecte : correction d'une ligne tant que la journée n'est pas validée.
--      Refusée si la journée est validée, si l'agent a déjà versé sa tournée, si le cycle n'est plus en cours,
--      ou si un remboursement de crédit a déjà été déclenché sur ce cycle (garantie tontine).
--   3. validation_collecte : validation globale d'une journée par agence ; elle verrouille les lignes de collecte du jour
--      (saisie, modification, suppression). rouvrir_journee_collecte la lève (traçable).
-- Les lignes de virement (origine 'virement') ne sont pas concernées.
-- Dépend de : 00, 01, 02, 03.
-- =====================================================================
SET search_path = mf, public;

ALTER TABLE zone ADD COLUMN agent_id integer REFERENCES agent(id);

CREATE TABLE validation_collecte (
  agence_id     smallint NOT NULL REFERENCES agence(id),
  date_collecte date NOT NULL,
  valide_par    integer REFERENCES utilisateur(id),
  valide_le     timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (agence_id, date_collecte)
);

CREATE TABLE validation_collecte_journal (
  id            bigserial PRIMARY KEY,
  agence_id     smallint NOT NULL REFERENCES agence(id),
  date_collecte date NOT NULL,
  action        varchar(10) NOT NULL CHECK (action IN ('validee','rouverte')),
  utilisateur_id integer REFERENCES utilisateur(id),
  motif         text,
  cree_le       timestamptz NOT NULL DEFAULT now()
);

-- Verrou : aucune ligne de collecte ne bouge sur une journée validée
CREATE FUNCTION trg_ligne_jour_valide() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE l mf.ligne_collecte; v_agence smallint;
BEGIN
  l := CASE WHEN TG_OP = 'INSERT' THEN NEW ELSE OLD END;
  IF l.origine <> 'collecte' THEN RETURN l; END IF;
  SELECT agence_id INTO v_agence FROM mf.cycle WHERE id = l.cycle_id;
  IF EXISTS (SELECT 1 FROM mf.validation_collecte WHERE agence_id = v_agence AND date_collecte = l.date_collecte) THEN
    RAISE EXCEPTION 'la journée de collecte du % est validée : modification refusée', l.date_collecte;
  END IF;
  IF TG_OP = 'UPDATE' AND NEW.date_collecte <> OLD.date_collecte AND EXISTS
     (SELECT 1 FROM mf.validation_collecte WHERE agence_id = v_agence AND date_collecte = NEW.date_collecte) THEN
    RAISE EXCEPTION 'la journée de collecte du % est validée : modification refusée', NEW.date_collecte;
  END IF;
  RETURN CASE WHEN TG_OP = 'DELETE' THEN OLD ELSE NEW END;
END $$;
CREATE TRIGGER ligne_jour_valide BEFORE INSERT OR UPDATE OR DELETE ON ligne_collecte
  FOR EACH ROW EXECUTE FUNCTION trg_ligne_jour_valide();

-- Contrôles communs à la modification et à la suppression d'une ligne de collecte
CREATE FUNCTION verifier_ligne_modifiable(p_ligne bigint) RETURNS mf.ligne_collecte
LANGUAGE plpgsql AS $$
DECLARE l mf.ligne_collecte; c mf.cycle;
BEGIN
  SELECT * INTO l FROM mf.ligne_collecte WHERE id = p_ligne FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'ligne de collecte % inconnue', p_ligne; END IF;
  IF l.origine <> 'collecte' THEN RAISE EXCEPTION 'une ligne issue d''un virement ne se corrige pas ici'; END IF;
  SELECT * INTO c FROM mf.cycle WHERE id = l.cycle_id FOR UPDATE;
  IF c.statut <> 'en_cours' THEN RAISE EXCEPTION 'cycle % clos : correction refusée', c.numero; END IF;
  IF EXISTS (SELECT 1 FROM mf.validation_collecte WHERE agence_id = c.agence_id AND date_collecte = l.date_collecte) THEN
    RAISE EXCEPTION 'la journée de collecte du % est validée : correction refusée', l.date_collecte;
  END IF;
  IF EXISTS (SELECT 1 FROM mf.versement_agent WHERE agent_id = l.agent_id AND date_tournee = l.date_collecte) THEN
    RAISE EXCEPTION 'la tournée du % est déjà versée par cet agent : correction refusée', l.date_collecte;
  END IF;
  IF EXISTS (SELECT 1 FROM mf.retrait WHERE cycle_id = l.cycle_id AND nature = 'remboursement' AND statut <> 'annule') THEN
    RAISE EXCEPTION 'un remboursement de crédit a déjà été déclenché sur le cycle % : correction refusée', c.numero;
  END IF;
  RETURN l;
END $$;

CREATE FUNCTION modifier_ligne_collecte(p_ligne bigint, p_montant numeric) RETURNS void
LANGUAGE plpgsql AS $$
BEGIN
  IF p_montant IS NULL OR p_montant <= 0 THEN RAISE EXCEPTION 'le montant doit être positif'; END IF;
  PERFORM mf.verifier_ligne_modifiable(p_ligne);
  UPDATE mf.ligne_collecte SET montant_collecte = p_montant WHERE id = p_ligne;
END $$;

CREATE FUNCTION supprimer_ligne_collecte(p_ligne bigint) RETURNS void
LANGUAGE plpgsql AS $$
BEGIN
  PERFORM mf.verifier_ligne_modifiable(p_ligne);
  DELETE FROM mf.ligne_collecte WHERE id = p_ligne;
END $$;

CREATE FUNCTION valider_journee_collecte(p_agence smallint, p_date date, p_utilisateur integer DEFAULT NULL) RETURNS void
LANGUAGE plpgsql AS $$
BEGIN
  IF p_date > current_date THEN RAISE EXCEPTION 'impossible de valider une journée à venir'; END IF;
  IF EXISTS (SELECT 1 FROM mf.validation_collecte WHERE agence_id = p_agence AND date_collecte = p_date) THEN
    RAISE EXCEPTION 'la journée du % est déjà validée', p_date;
  END IF;
  INSERT INTO mf.validation_collecte(agence_id, date_collecte, valide_par) VALUES (p_agence, p_date, p_utilisateur);
  INSERT INTO mf.validation_collecte_journal(agence_id, date_collecte, action, utilisateur_id) VALUES (p_agence, p_date, 'validee', p_utilisateur);
END $$;

CREATE FUNCTION rouvrir_journee_collecte(p_agence smallint, p_date date, p_motif text, p_utilisateur integer DEFAULT NULL) RETURNS void
LANGUAGE plpgsql AS $$
BEGIN
  IF p_motif IS NULL OR btrim(p_motif) = '' THEN RAISE EXCEPTION 'un motif est obligatoire pour rouvrir une journée'; END IF;
  DELETE FROM mf.validation_collecte WHERE agence_id = p_agence AND date_collecte = p_date;
  IF NOT FOUND THEN RAISE EXCEPTION 'la journée du % n''est pas validée', p_date; END IF;
  INSERT INTO mf.validation_collecte_journal(agence_id, date_collecte, action, utilisateur_id, motif)
  VALUES (p_agence, p_date, 'rouverte', p_utilisateur, p_motif);
END $$;
