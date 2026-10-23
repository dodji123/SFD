-- =====================================================================
-- 56_appareils_mobiles.sql
-- Appareils mobiles agréés (application de collecte /m).
--   * un téléphone par agent / collectrice : un seul appareil « en attente » ou « agréé » à la fois ; changer de téléphone
--     suppose de révoquer l'ancien
--   * l'appareil se reconnaît à un secret généré sur le téléphone ; la base ne garde que son empreinte SHA-256
--   * agrément par un AUTRE responsable que l'intéressé ; refus et révocation motivés ; états terminaux (refusé, révoqué)
--   * effacement à distance : demandé à la révocation, confirmé par le téléphone à sa prochaine connexion au serveur
--   * rien ne se supprime ; événements de connexion et alertes dédiés ; permissions « appareil:read » et « appareil:gerer »
-- Dépend de : 00, 34, 53, 55.
-- =====================================================================
SET search_path = mf, public;

CREATE TABLE appareil_mobile (
  id                  serial PRIMARY KEY,
  utilisateur_id      integer NOT NULL REFERENCES utilisateur(id),
  nom                 varchar(80) NOT NULL CHECK (length(btrim(nom)) >= 2),
  empreinte           char(64) NOT NULL UNIQUE,
  statut              varchar(12) NOT NULL DEFAULT 'en_attente' CHECK (statut IN ('en_attente','agree','refuse','revoque')),
  cree_le             timestamptz NOT NULL DEFAULT now(),
  agree_par           integer REFERENCES utilisateur(id),
  agree_le            timestamptz,
  decide_par          integer REFERENCES utilisateur(id),      -- refus ou révocation
  decide_le           timestamptz,
  motif_decision      text,
  efface_demande      boolean NOT NULL DEFAULT false,
  efface_confirme_le  timestamptz,
  derniere_activite   timestamptz,
  derniere_ip         varchar(60),
  -- un appareil révoqué garde la trace de son agrément passé ; les autres états n'en ont pas
  CHECK (statut = 'revoque' OR ((statut = 'agree') = (agree_par IS NOT NULL AND agree_le IS NOT NULL))),
  CHECK (statut NOT IN ('refuse','revoque') OR (decide_par IS NOT NULL AND decide_le IS NOT NULL AND length(btrim(coalesce(motif_decision, ''))) >= 5)),
  CHECK (NOT efface_demande OR statut = 'revoque'),
  CHECK (efface_confirme_le IS NULL OR efface_demande)
);
COMMENT ON TABLE appareil_mobile IS 'Téléphones agréés pour la collecte. Seule l''empreinte du secret de l''appareil est conservée.';
CREATE UNIQUE INDEX appareil_un_actif ON appareil_mobile(utilisateur_id) WHERE statut IN ('en_attente','agree');

CREATE FUNCTION trg_appareil_regles() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF TG_OP = 'DELETE' THEN RAISE EXCEPTION 'Un appareil ne se supprime pas : révoquez-le'; END IF;
  IF TG_OP = 'INSERT' THEN
    IF NEW.statut <> 'en_attente' THEN RAISE EXCEPTION 'Un appareil naît « en attente » d''agrément'; END IF;
    RETURN NEW;
  END IF;
  IF NEW.utilisateur_id <> OLD.utilisateur_id OR NEW.empreinte <> OLD.empreinte OR NEW.cree_le <> OLD.cree_le THEN
    RAISE EXCEPTION 'L''appareil, son propriétaire et son empreinte ne changent pas';
  END IF;
  IF OLD.statut IN ('refuse','revoque') AND NEW.statut <> OLD.statut THEN
    RAISE EXCEPTION 'Un appareil refusé ou révoqué ne se réactive pas : enregistrez-en un nouveau';
  END IF;
  IF NEW.statut <> OLD.statut THEN
    IF NOT ((OLD.statut = 'en_attente' AND NEW.statut IN ('agree','refuse','revoque')) OR (OLD.statut = 'agree' AND NEW.statut = 'revoque')) THEN
      RAISE EXCEPTION 'Transition interdite : % -> %', OLD.statut, NEW.statut;
    END IF;
    IF NEW.statut = 'agree' AND NEW.agree_par = NEW.utilisateur_id THEN
      RAISE EXCEPTION 'On n''agrée pas son propre appareil : un responsable doit le faire';
    END IF;
    IF NEW.statut IN ('refuse','revoque') AND NEW.decide_par = NEW.utilisateur_id THEN
      RAISE EXCEPTION 'On ne décide pas du sort de son propre appareil';
    END IF;
  END IF;
  IF OLD.statut = 'agree' AND NEW.statut = 'agree' AND (NEW.agree_par IS DISTINCT FROM OLD.agree_par OR NEW.agree_le IS DISTINCT FROM OLD.agree_le) THEN
    RAISE EXCEPTION 'L''agrément ne se réécrit pas';
  END IF;
  IF OLD.efface_confirme_le IS NOT NULL AND NEW.efface_confirme_le IS DISTINCT FROM OLD.efface_confirme_le THEN
    RAISE EXCEPTION 'La confirmation d''effacement ne se réécrit pas';
  END IF;
  IF OLD.efface_demande AND NOT NEW.efface_demande THEN
    RAISE EXCEPTION 'Une demande d''effacement ne s''annule pas';
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER appareil_regles BEFORE INSERT OR UPDATE OR DELETE ON appareil_mobile FOR EACH ROW EXECUTE FUNCTION trg_appareil_regles();
CREATE TRIGGER audit_appareil_mobile AFTER INSERT OR UPDATE ON appareil_mobile FOR EACH ROW EXECUTE FUNCTION trg_audit();

-- événements de connexion et alertes
ALTER TABLE journal_connexion DROP CONSTRAINT journal_connexion_evenement_check;
ALTER TABLE journal_connexion ADD CONSTRAINT journal_connexion_evenement_check CHECK (evenement IN
  ('succes','echec','verrouille','mdp_oublie','mdp_reinitialise','mdp_change','mdp_reinit_admin','hors_heures',
   'totp_echec','totp_active','totp_secours','totp_reinit','totp_desactive',
   'appareil_enregistre','appareil_agree','appareil_refuse','appareil_revoque','appareil_efface'));
ALTER TABLE alerte_securite DROP CONSTRAINT alerte_securite_type_check;
ALTER TABLE alerte_securite ADD CONSTRAINT alerte_securite_type_check CHECK (type IN
  ('verrouillage','connexion_hors_heures','mdp_reinit_admin','retraits_fractionnes','operation_inhabituelle','sauvegarde_ancienne','autre',
   'totp_reinit','totp_secours_bas','appareil_nouveau','appareil_revoque_usage'));

-- permissions
INSERT INTO permission(code, categorie) VALUES ('appareil:read', 'appareil'), ('appareil:gerer', 'appareil');
INSERT INTO droit_role(role_code, perm) VALUES
  ('admin', 'appareil:read'), ('directeur', 'appareil:read'), ('chef_agence', 'appareil:read'), ('coordinateur', 'appareil:read'), ('auditeur', 'appareil:read'),
  ('admin', 'appareil:gerer'), ('directeur', 'appareil:gerer'), ('chef_agence', 'appareil:gerer'), ('coordinateur', 'appareil:gerer');
