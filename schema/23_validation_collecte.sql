-- =====================================================================
-- 23_validation_collecte.sql
-- Saisie de collecte au guichet : agent responsable d'une zone, correction des lignes de collecte.
--   1. zone.agent_id : l'agent commercial qui collecte dans la zone (choisir l'un propose l'autre à la saisie).
--   2. modifier_ligne_collecte / supprimer_ligne_collecte : correction d'une ligne tant qu'elle est sur la date
--      d'opération ouverte (module 81). Refusée si l'agent a déjà versé sa tournée, si le cycle n'est plus en cours,
--      ou si un remboursement de crédit a déjà été déclenché sur ce cycle (garantie tontine).
-- Les validations journalières par agence sont retirées : la clôture de la date d'opération vaut pour tout le monde.
-- Les lignes de virement (origine 'virement') ne sont pas concernées.
-- Dépend de : 00, 01, 02, 03 ; 81 (date_operation_courante) pour les contrôles de date.
-- =====================================================================
SET search_path = mf, public;

ALTER TABLE zone ADD COLUMN agent_id integer REFERENCES agent(id);

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
  IF l.date_collecte IS DISTINCT FROM mf.date_operation_courante() THEN
    RAISE EXCEPTION 'la collecte du % ne se corrige que sur la date d''opération ouverte (%)', l.date_collecte, mf.date_operation_courante();
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
