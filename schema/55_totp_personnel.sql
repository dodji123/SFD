-- =====================================================================
-- 55_totp_personnel.sql
-- Second facteur (TOTP, RFC 6238) du personnel.
--   * un secret par utilisateur, conservé CHIFFRÉ par l'API (jamais en clair en base) ; actif seulement après la preuve
--     de possession (premier code valide)
--   * anti-rejeu : un pas de 30 secondes déjà accepté ne se rejoue pas (dernier_pas ne recule jamais)
--   * codes de secours à usage unique, hachés (SHA-256), jamais réutilisables
--   * sessions_depuis : toute session ouverte avant cette date est refusée (réinitialisation du second facteur)
--   * événements de connexion et alertes dédiés ; nouvelle permission « totp:reinitialiser » (administrateur, directeur)
-- Dépend de : 00, 34, 53.
-- =====================================================================
SET search_path = mf, public;

ALTER TABLE utilisateur ADD COLUMN sessions_depuis timestamptz NOT NULL DEFAULT 'epoch';

CREATE TABLE utilisateur_totp (
  utilisateur_id  integer PRIMARY KEY REFERENCES utilisateur(id),
  secret_chiffre  text NOT NULL CHECK (length(secret_chiffre) >= 20),
  actif           boolean NOT NULL DEFAULT false,
  cree_le         timestamptz NOT NULL DEFAULT now(),
  active_le       timestamptz,
  dernier_pas     bigint NOT NULL DEFAULT 0,
  CHECK (actif = (active_le IS NOT NULL))
);
COMMENT ON TABLE utilisateur_totp IS 'Secret TOTP du personnel (chiffré par l''API). Actif après le premier code valide.';

-- le pas accepté ne recule jamais (anti-rejeu) ; un secret actif ne change pas (on réinitialise puis on réenrôle)
CREATE FUNCTION trg_totp_regles() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF OLD.actif AND NEW.secret_chiffre IS DISTINCT FROM OLD.secret_chiffre THEN
    RAISE EXCEPTION 'Le secret d''un second facteur actif ne change pas : réinitialisez-le puis réenrôlez';
  END IF;
  IF OLD.actif AND NOT NEW.actif THEN
    RAISE EXCEPTION 'Un second facteur actif ne se désactive pas par mise à jour : supprimez-le';
  END IF;
  IF NEW.dernier_pas < OLD.dernier_pas THEN
    RAISE EXCEPTION 'Le dernier pas TOTP accepté ne recule pas (rejeu)';
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER utilisateur_totp_regles BEFORE UPDATE ON utilisateur_totp FOR EACH ROW EXECUTE FUNCTION trg_totp_regles();

CREATE TABLE code_secours_totp (
  id              bigserial PRIMARY KEY,
  utilisateur_id  integer NOT NULL REFERENCES utilisateur(id),
  code_hash       char(64) NOT NULL,
  cree_le         timestamptz NOT NULL DEFAULT now(),
  utilise_le      timestamptz,
  UNIQUE (utilisateur_id, code_hash)
);

-- un code de secours utilisé reste utilisé ; son haché ne change pas
CREATE FUNCTION trg_code_secours_regles() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF NEW.code_hash IS DISTINCT FROM OLD.code_hash OR NEW.utilisateur_id IS DISTINCT FROM OLD.utilisateur_id THEN
    RAISE EXCEPTION 'Un code de secours ne se modifie pas';
  END IF;
  IF OLD.utilise_le IS NOT NULL AND NEW.utilise_le IS DISTINCT FROM OLD.utilise_le THEN
    RAISE EXCEPTION 'Un code de secours utilisé ne se réactive pas';
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER code_secours_regles BEFORE UPDATE ON code_secours_totp FOR EACH ROW EXECUTE FUNCTION trg_code_secours_regles();

-- événements de connexion et alertes
ALTER TABLE journal_connexion DROP CONSTRAINT journal_connexion_evenement_check;
ALTER TABLE journal_connexion ADD CONSTRAINT journal_connexion_evenement_check CHECK (evenement IN
  ('succes','echec','verrouille','mdp_oublie','mdp_reinitialise','mdp_change','mdp_reinit_admin','hors_heures',
   'totp_echec','totp_active','totp_secours','totp_reinit','totp_desactive'));
ALTER TABLE alerte_securite DROP CONSTRAINT alerte_securite_type_check;
ALTER TABLE alerte_securite ADD CONSTRAINT alerte_securite_type_check CHECK (type IN
  ('verrouillage','connexion_hors_heures','mdp_reinit_admin','retraits_fractionnes','operation_inhabituelle','sauvegarde_ancienne','autre',
   'totp_reinit','totp_secours_bas'));

-- permission de réinitialisation du second facteur d'un collègue
INSERT INTO permission(code, categorie) VALUES ('totp:reinitialiser', 'totp');
INSERT INTO droit_role(role_code, perm) VALUES ('admin', 'totp:reinitialiser'), ('directeur', 'totp:reinitialiser');
