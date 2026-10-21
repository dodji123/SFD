-- =====================================================================
-- 47_controle_livrets.sql
-- Contrôle des livrets sur le terrain : un contrôleur compare le livret papier d'un cycle à ce que le système a enregistré.
--   * le constat (état du livret, nombre de lignes et total constatés) est rapproché d'un instantané du système
--   * les écarts ligne à ligne sont listés (absente du système, absente du livret, montant différent)
--   * un responsable valide ou rejette le contrôle ; le contrôleur ne valide pas son propre contrôle
--   * un contrôle décidé ne se modifie plus ; la clé d'opération rend la synchronisation mobile idempotente
-- Dépend de : 01 (utilisateur), 07 (cycle, ligne_collecte, v_cycle_situation), 44.
-- =====================================================================
SET search_path = mf, public;

CREATE TABLE controle_livret (
  id                   serial PRIMARY KEY,
  agence_id            smallint NOT NULL REFERENCES agence(id),
  cycle_id             integer NOT NULL REFERENCES cycle(id),
  controleur_id        integer NOT NULL REFERENCES utilisateur(id),
  date_controle        date NOT NULL DEFAULT current_date,
  cle                  varchar(64) UNIQUE,
  etat_livret          varchar(14) NOT NULL CHECK (etat_livret IN ('conforme','incomplet','abime','perdu','non_presente')),
  nb_lignes_constatees integer CHECK (nb_lignes_constatees >= 0),
  total_constate       numeric(14,0) CHECK (total_constate >= 0),
  nb_lignes_systeme    integer NOT NULL,
  total_systeme        numeric(14,0) NOT NULL,
  ecart_montant        numeric(14,0),
  commentaire          text,
  statut               varchar(10) NOT NULL DEFAULT 'a_valider' CHECK (statut IN ('a_valider','valide','rejete')),
  decide_par           integer REFERENCES utilisateur(id),
  decide_le            timestamptz,
  commentaire_decision text,
  cree_le              timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX controle_livret_cycle_idx ON controle_livret(cycle_id, date_controle DESC);
CREATE INDEX controle_livret_statut_idx ON controle_livret(agence_id, statut);
COMMENT ON TABLE controle_livret IS 'Contrôle terrain d''un livret de tontine : constat du contrôleur rapproché du système, validé par un responsable.';

CREATE TABLE controle_livret_ligne (
  id              serial PRIMARY KEY,
  controle_id     integer NOT NULL REFERENCES controle_livret(id) ON DELETE CASCADE,
  no_ligne        smallint NOT NULL CHECK (no_ligne > 0),
  date_collecte   date,
  montant_livret  numeric(14,0) CHECK (montant_livret >= 0),
  montant_systeme numeric(14,0) CHECK (montant_systeme >= 0),
  nature          varchar(17) NOT NULL CHECK (nature IN ('absente_systeme','absente_livret','montant_different')),
  note            text,
  UNIQUE (controle_id, no_ligne),
  CHECK ((nature = 'absente_systeme'  AND montant_livret IS NOT NULL AND montant_systeme IS NULL)
      OR (nature = 'absente_livret'   AND montant_livret IS NULL     AND montant_systeme IS NOT NULL)
      OR (nature = 'montant_different' AND montant_livret IS NOT NULL AND montant_systeme IS NOT NULL AND montant_livret <> montant_systeme))
);

CREATE FUNCTION trg_controle_livret_regles() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE c mf.cycle; s mf.v_cycle_situation;
BEGIN
  IF TG_OP = 'INSERT' THEN
    SELECT * INTO c FROM mf.cycle WHERE id = NEW.cycle_id;
    SELECT * INTO s FROM mf.v_cycle_situation WHERE cycle_id = NEW.cycle_id;
    NEW.agence_id := c.agence_id;
    NEW.nb_lignes_systeme := s.nb_lignes;
    NEW.total_systeme := s.montant_collecte;
    IF NEW.statut <> 'a_valider' THEN RAISE EXCEPTION 'Un contrôle naît « à valider »'; END IF;
    IF NEW.etat_livret IN ('perdu','non_presente') THEN
      NEW.nb_lignes_constatees := NULL; NEW.total_constate := NULL; NEW.ecart_montant := NULL;
      IF length(btrim(COALESCE(NEW.commentaire, ''))) < 5 THEN RAISE EXCEPTION 'Un livret % doit être commenté', NEW.etat_livret; END IF;
    ELSE
      IF NEW.nb_lignes_constatees IS NULL OR NEW.total_constate IS NULL THEN
        RAISE EXCEPTION 'Le nombre de lignes et le total constatés sont obligatoires';
      END IF;
      NEW.ecart_montant := NEW.total_constate - NEW.total_systeme;
      IF NEW.etat_livret = 'conforme' AND (NEW.ecart_montant <> 0 OR NEW.nb_lignes_constatees <> NEW.nb_lignes_systeme) THEN
        RAISE EXCEPTION 'Un livret conforme ne présente aucun écart avec le système (constaté % lignes / %, système % lignes / %)',
          NEW.nb_lignes_constatees, NEW.total_constate, NEW.nb_lignes_systeme, NEW.total_systeme;
      END IF;
      IF (NEW.etat_livret <> 'conforme' OR NEW.ecart_montant <> 0) AND length(btrim(COALESCE(NEW.commentaire, ''))) < 5 THEN
        RAISE EXCEPTION 'Un écart ou un livret non conforme doit être commenté';
      END IF;
    END IF;
  ELSIF OLD.statut = 'a_valider' AND NEW.statut IN ('valide','rejete') THEN
    IF NEW.decide_par IS NULL THEN RAISE EXCEPTION 'La décision doit être attribuée à son auteur'; END IF;
    IF NEW.decide_par = OLD.controleur_id THEN RAISE EXCEPTION 'Séparation des tâches : le contrôleur ne valide pas son propre contrôle'; END IF;
    IF NEW.statut = 'rejete' AND length(btrim(COALESCE(NEW.commentaire_decision, ''))) < 5 THEN RAISE EXCEPTION 'Un rejet doit être motivé'; END IF;
    IF (NEW.cycle_id, NEW.controleur_id, NEW.etat_livret, NEW.total_constate, NEW.nb_lignes_constatees, NEW.commentaire)
       IS DISTINCT FROM (OLD.cycle_id, OLD.controleur_id, OLD.etat_livret, OLD.total_constate, OLD.nb_lignes_constatees, OLD.commentaire) THEN
      RAISE EXCEPTION 'Le constat ne se modifie pas au moment de la décision';
    END IF;
    NEW.decide_le := now();
  ELSE
    RAISE EXCEPTION 'Un contrôle décidé ne se modifie plus';
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER controle_livret_regles BEFORE INSERT OR UPDATE ON controle_livret FOR EACH ROW EXECUTE FUNCTION trg_controle_livret_regles();

CREATE FUNCTION trg_controle_livret_suppression() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  RAISE EXCEPTION 'Un contrôle de livret ne se supprime pas : il reste dans la piste d''audit';
END $$;
CREATE TRIGGER controle_livret_ni_suppression BEFORE DELETE ON controle_livret FOR EACH ROW EXECUTE FUNCTION trg_controle_livret_suppression();

CREATE FUNCTION trg_controle_livret_ligne_regles() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE v_statut text;
BEGIN
  SELECT statut INTO v_statut FROM mf.controle_livret WHERE id = COALESCE(NEW.controle_id, OLD.controle_id);
  IF v_statut <> 'a_valider' THEN RAISE EXCEPTION 'Les écarts d''un contrôle décidé ne se modifient plus'; END IF;
  RETURN COALESCE(NEW, OLD);
END $$;
CREATE TRIGGER controle_livret_ligne_regles BEFORE INSERT OR UPDATE OR DELETE ON controle_livret_ligne FOR EACH ROW EXECUTE FUNCTION trg_controle_livret_ligne_regles();

CREATE TRIGGER audit_controle_livret AFTER INSERT OR UPDATE OR DELETE ON controle_livret FOR EACH ROW EXECUTE FUNCTION trg_audit();
CREATE TRIGGER audit_controle_livret_ligne AFTER INSERT OR UPDATE OR DELETE ON controle_livret_ligne FOR EACH ROW EXECUTE FUNCTION trg_audit();

CREATE VIEW v_controle_livret AS
SELECT k.*, c.numero AS cycle, cl.id AS client_id, cl.numero AS client_numero, cl.nom AS client, pe.code AS produit,
       uc.nom AS controleur, ud.nom AS decide_par_nom,
       (SELECT count(*) FROM mf.controle_livret_ligne l WHERE l.controle_id = k.id) AS nb_ecarts_lignes
FROM mf.controle_livret k
JOIN mf.cycle c ON c.id = k.cycle_id
JOIN mf.client cl ON cl.id = c.client_id
JOIN mf.produit_epargne pe ON pe.id = c.produit_id
LEFT JOIN mf.utilisateur uc ON uc.id = k.controleur_id
LEFT JOIN mf.utilisateur ud ON ud.id = k.decide_par;
