-- =====================================================================
-- 31_analyse_capacite.sql
-- Analyse de capacité de remboursement d'une demande de crédit : revenus, charges (activité, ménage, dettes en cours),
-- nouvelle échéance, taux d'endettement, couverture de l'échéance, mise journalière, montant maximal conseillé.
--   Le calcul se fait dans l'API (fonctions testées) ; cette table conserve les saisies et le résultat au moment de l'analyse,
--   pour que la décision s'appuie sur ce qui a été vu. Une analyse par demande, modifiable tant que la demande est « demandée ».
--   L'analyse est indicative : elle n'empêche pas une approbation (règles du brief, section 3, inchangées).
-- Paramètres : endettement_max_pct (part maximale des revenus consacrée aux remboursements), couverture_min (revenu disponible
--   divisé par l'échéance mensuelle).
-- Dépend de : 00, 08, 10 (audit).
-- =====================================================================
SET search_path = mf, public;

INSERT INTO parametre(agence_id, cle, valeur, description) VALUES
  (NULL, 'endettement_max_pct', '33', 'taux d''endettement maximal (% des revenus) : (échéance du nouveau crédit + dettes en cours) / revenus'),
  (NULL, 'couverture_min', '1.5', 'couverture minimale de l''échéance : revenu disponible / échéance mensuelle')
ON CONFLICT DO NOTHING;

CREATE TABLE analyse_capacite (
  id               serial PRIMARY KEY,
  agence_id        smallint NOT NULL REFERENCES agence(id),
  demande_id       integer NOT NULL UNIQUE REFERENCES demande_credit(id),
  client_id        integer NOT NULL REFERENCES client(id),
  secteur          varchar(20),
  anciennete_mois  integer NOT NULL DEFAULT 0 CHECK (anciennete_mois >= 0),
  jours_activite   smallint NOT NULL DEFAULT 26 CHECK (jours_activite BETWEEN 1 AND 31),
  ventes_mensuelles numeric(14,0) NOT NULL DEFAULT 0 CHECK (ventes_mensuelles >= 0),
  achats_mensuels  numeric(14,0) NOT NULL DEFAULT 0 CHECK (achats_mensuels >= 0),
  autres_revenus   numeric(14,0) NOT NULL DEFAULT 0 CHECK (autres_revenus >= 0),
  charges          jsonb NOT NULL DEFAULT '[]'::jsonb,       -- [{libelle, categorie (activite|menage|dette), montant, periode}]
  resultat         jsonb NOT NULL,                            -- calcul figé : revenus, charges, échéance, taux d'endettement, couverture...
  taux_endettement numeric(8,4),                              -- fraction (0.257 = 25,7 %), NULL si revenus nuls
  couverture       numeric(10,3),
  conforme         boolean NOT NULL,                          -- respecte endettement maximal et couverture minimale
  utilisateur_id   integer REFERENCES utilisateur(id),
  cree_le          timestamptz NOT NULL DEFAULT now(),
  modifie_le       timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX analyse_capacite_client ON analyse_capacite (client_id);
CREATE TRIGGER audit_analyse_capacite AFTER INSERT OR UPDATE OR DELETE ON analyse_capacite FOR EACH ROW EXECUTE FUNCTION trg_audit();

-- Une analyse ne se modifie plus une fois la demande décidée
CREATE FUNCTION trg_analyse_capacite_gel() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE v_statut text;
BEGIN
  SELECT statut INTO v_statut FROM mf.demande_credit WHERE id = COALESCE(NEW.demande_id, OLD.demande_id);
  IF v_statut IS DISTINCT FROM 'demandee' THEN
    RAISE EXCEPTION 'la demande est déjà décidée (%) : l''analyse de capacité ne se modifie plus', v_statut;
  END IF;
  RETURN COALESCE(NEW, OLD);
END $$;
CREATE TRIGGER analyse_capacite_gel BEFORE INSERT OR UPDATE OR DELETE ON analyse_capacite FOR EACH ROW EXECUTE FUNCTION trg_analyse_capacite_gel();
