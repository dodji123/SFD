-- =====================================================================
-- 18_espace_client.sql
-- Espace client sécurisé : consentements, accès (PIN + code à usage unique), journal des accès non modifiable,
-- file des SMS, et journal d'audit en « ajout seul ».
--  * l'accès n'est ouvert qu'à un client actif, au KYC complet, sans alerte de sanction, et ayant consenti
--    (finalité « portail ») ; retirer le consentement coupe l'accès aussitôt ;
--  * le PIN et le code à usage unique sont stockés hachés ; verrouillage après échecs (géré par l'API) ;
--  * journal des accès et journal d'audit : UPDATE, DELETE et TRUNCATE interdits (preuve conservable) ;
--  * file des SMS (sms_outbox) : journal des envois sans doublon ; le message ne contient jamais le solde.
-- Dépend de : 00 à 17.
-- =====================================================================
SET search_path = mf, public;

-- ---------------------------------------------------------------------
-- Tables en ajout seul : aucune modification ni suppression
-- ---------------------------------------------------------------------
CREATE FUNCTION trg_ajout_seul() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  RAISE EXCEPTION 'la table % est en ajout seul : modification et suppression interdites', TG_TABLE_NAME;
END $$;

CREATE TRIGGER audit_log_ajout_seul BEFORE UPDATE OR DELETE ON audit_log FOR EACH ROW EXECUTE FUNCTION trg_ajout_seul();
CREATE TRIGGER audit_log_pas_de_vidage BEFORE TRUNCATE ON audit_log FOR EACH STATEMENT EXECUTE FUNCTION trg_ajout_seul();

-- ---------------------------------------------------------------------
-- Consentements (historique ; le dernier état par finalité fait foi)
-- ---------------------------------------------------------------------
CREATE TABLE consentement_client (
  id           serial PRIMARY KEY,
  client_id    integer NOT NULL REFERENCES client(id),
  finalite     varchar(20) NOT NULL CHECK (finalite IN ('portail','sms_rappel','traitement_donnees')),
  accorde      boolean NOT NULL,
  canal        varchar(10) NOT NULL DEFAULT 'agence' CHECK (canal IN ('papier','agence','portail')),
  recueilli_par integer REFERENCES utilisateur(id),
  cree_le      timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX consentement_client_idx ON consentement_client (client_id, finalite, id DESC);

CREATE FUNCTION consentement_actif(p_client integer, p_finalite text) RETURNS boolean
LANGUAGE sql STABLE AS $$
  SELECT COALESCE((SELECT c.accorde FROM mf.consentement_client c WHERE c.client_id = p_client AND c.finalite = p_finalite
                    ORDER BY c.id DESC LIMIT 1), false)
$$;

CREATE TRIGGER consentement_ajout_seul BEFORE UPDATE OR DELETE ON consentement_client FOR EACH ROW EXECUTE FUNCTION trg_ajout_seul();

-- ---------------------------------------------------------------------
-- Accès à l'espace client
-- ---------------------------------------------------------------------
CREATE TABLE client_acces (
  client_id         integer PRIMARY KEY REFERENCES client(id),
  pin_hash          text NOT NULL,
  pin_provisoire    boolean NOT NULL DEFAULT true,         -- à changer à la première connexion
  actif             boolean NOT NULL DEFAULT true,
  echecs            integer NOT NULL DEFAULT 0,
  verrouille_jusqua timestamptz,
  derniere_connexion timestamptz,
  active_par        integer REFERENCES utilisateur(id),
  cree_le           timestamptz NOT NULL DEFAULT now(),
  maj_le            timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE client_otp (
  id          bigserial PRIMARY KEY,
  client_id   integer NOT NULL REFERENCES client(id),
  code_hash   text NOT NULL,
  expire_le   timestamptz NOT NULL,
  tentatives  smallint NOT NULL DEFAULT 0,
  utilise     boolean NOT NULL DEFAULT false,
  cree_le     timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX client_otp_client ON client_otp (client_id, cree_le DESC);

-- Journal des accès : qui, quoi, d'où ; non modifiable
CREATE TABLE acces_client_log (
  id          bigserial PRIMARY KEY,
  client_id   integer REFERENCES client(id),               -- NULL si l'identifiant est inconnu
  numero_saisi varchar(40),
  evenement   varchar(30) NOT NULL,
  ip          varchar(64),
  appareil    text,
  detail      text,
  cree_le     timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX acces_client_log_client ON acces_client_log (client_id, id DESC);
CREATE TRIGGER acces_client_log_ajout_seul BEFORE UPDATE OR DELETE ON acces_client_log FOR EACH ROW EXECUTE FUNCTION trg_ajout_seul();
CREATE TRIGGER acces_client_log_pas_de_vidage BEFORE TRUNCATE ON acces_client_log FOR EACH STATEMENT EXECUTE FUNCTION trg_ajout_seul();

-- Ouverture de l'accès par un agent habilité (le PIN provisoire est haché par l'API et remis une seule fois)
CREATE FUNCTION activer_acces_client(p_client integer, p_pin_hash text, p_utilisateur integer DEFAULT NULL) RETURNS void
LANGUAGE plpgsql AS $$
DECLARE c mf.client;
BEGIN
  SELECT * INTO c FROM mf.client WHERE id = p_client;
  IF NOT FOUND THEN RAISE EXCEPTION 'client % inconnu', p_client; END IF;
  IF NOT c.actif THEN RAISE EXCEPTION 'accès refusé : le client % est inactif', c.numero; END IF;
  IF c.statut_kyc <> 'complet' THEN RAISE EXCEPTION 'accès refusé : le KYC du client % n''est pas complet', c.numero; END IF;
  IF c.telephone IS NULL OR btrim(c.telephone) = '' THEN RAISE EXCEPTION 'accès refusé : le client % n''a pas de téléphone (code de connexion par SMS)', c.numero; END IF;
  IF EXISTS (SELECT 1 FROM mf.alerte_lbc WHERE client_id = p_client AND type = 'sanction' AND statut IN ('a_examiner','confirmee')) THEN
    RAISE EXCEPTION 'accès refusé : alerte de sanction sur le client %', c.numero;
  END IF;
  IF NOT mf.consentement_actif(p_client, 'portail') THEN RAISE EXCEPTION 'accès refusé : consentement « portail » du client % absent', c.numero; END IF;
  INSERT INTO mf.client_acces(client_id, pin_hash, pin_provisoire, actif, echecs, verrouille_jusqua, active_par)
  VALUES (p_client, p_pin_hash, true, true, 0, NULL, p_utilisateur)
  ON CONFLICT (client_id) DO UPDATE
    SET pin_hash = EXCLUDED.pin_hash, pin_provisoire = true, actif = true, echecs = 0, verrouille_jusqua = NULL,
        active_par = EXCLUDED.active_par, maj_le = now();
  INSERT INTO mf.acces_client_log(client_id, numero_saisi, evenement, detail)
  VALUES (p_client, c.numero, 'acces_active', 'par utilisateur ' || COALESCE(p_utilisateur::text, '?'));
END $$;

CREATE FUNCTION bloquer_acces_client(p_client integer, p_utilisateur integer DEFAULT NULL, p_motif text DEFAULT NULL) RETURNS void
LANGUAGE plpgsql AS $$
BEGIN
  UPDATE mf.client_acces SET actif = false, maj_le = now() WHERE client_id = p_client;
  IF NOT FOUND THEN RAISE EXCEPTION 'le client % n''a pas d''accès à l''espace client', p_client; END IF;
  INSERT INTO mf.acces_client_log(client_id, evenement, detail)
  VALUES (p_client, 'acces_bloque', 'par utilisateur ' || COALESCE(p_utilisateur::text, '?') || COALESCE(' : ' || p_motif, ''));
END $$;

-- Retirer le consentement « portail », désactiver le client ou ouvrir une alerte de sanction coupe l'accès.
CREATE FUNCTION trg_consentement_coupe_acces() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  IF NEW.finalite = 'portail' AND NOT NEW.accorde THEN
    UPDATE mf.client_acces SET actif = false, maj_le = now() WHERE client_id = NEW.client_id AND actif;
    IF FOUND THEN
      INSERT INTO mf.acces_client_log(client_id, evenement, detail) VALUES (NEW.client_id, 'acces_bloque', 'consentement retiré');
    END IF;
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER consentement_coupe_acces AFTER INSERT ON consentement_client FOR EACH ROW EXECUTE FUNCTION trg_consentement_coupe_acces();

CREATE FUNCTION trg_client_inactif_coupe_acces() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  UPDATE mf.client_acces SET actif = false, maj_le = now() WHERE client_id = NEW.id AND actif;
  RETURN NEW;
END $$;
CREATE TRIGGER client_inactif_coupe_acces AFTER UPDATE OF actif ON client FOR EACH ROW WHEN (NOT NEW.actif AND OLD.actif) EXECUTE FUNCTION trg_client_inactif_coupe_acces();

CREATE FUNCTION trg_alerte_coupe_acces() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  IF NEW.type = 'sanction' AND NEW.statut IN ('a_examiner','confirmee') THEN
    UPDATE mf.client_acces SET actif = false, maj_le = now() WHERE client_id = NEW.client_id AND actif;
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER alerte_coupe_acces AFTER INSERT OR UPDATE OF statut ON alerte_lbc FOR EACH ROW EXECUTE FUNCTION trg_alerte_coupe_acces();

-- Nettoyage quotidien : codes à usage unique expirés (le journal des accès, lui, se conserve)
CREATE FUNCTION purger_otp() RETURNS integer
LANGUAGE plpgsql AS $$
DECLARE v_n integer;
BEGIN
  DELETE FROM mf.client_otp WHERE expire_le < now() - interval '1 day';
  GET DIAGNOSTICS v_n = ROW_COUNT;
  RETURN v_n;
END $$;

-- ---------------------------------------------------------------------
-- File et journal des SMS (codes de connexion, rappels d'échéance, relances)
-- Un message de rappel ne part qu'une fois par (client, type, référence) : pas de doublon.
-- ---------------------------------------------------------------------
CREATE TABLE sms_outbox (
  id           bigserial PRIMARY KEY,
  client_id    integer REFERENCES client(id),
  telephone    varchar(30) NOT NULL,
  type         varchar(15) NOT NULL CHECK (type IN ('otp','rappel','relance','alerte','information')),
  reference    varchar(60),                               -- ex. 'echeance:123:J-3' : clé anti-doublon
  message      text NOT NULL,
  statut       varchar(10) NOT NULL DEFAULT 'en_attente' CHECK (statut IN ('en_attente','envoye','echec','ignore')),
  erreur       text,
  cree_le      timestamptz NOT NULL DEFAULT now(),
  envoye_le    timestamptz
);
CREATE UNIQUE INDEX sms_outbox_pas_de_doublon ON sms_outbox (client_id, type, reference) WHERE reference IS NOT NULL;
CREATE INDEX sms_outbox_statut ON sms_outbox (statut, cree_le);

-- Piste d'audit sans secret : le haché du PIN n'est jamais recopié dans audit_log
CREATE FUNCTION trg_audit_sans_secret() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE v_user text := COALESCE(NULLIF(current_setting('mf.utilisateur', true), ''), current_user); v_row jsonb;
BEGIN
  v_row := CASE WHEN TG_OP = 'DELETE' THEN to_jsonb(OLD) ELSE to_jsonb(NEW) END;
  INSERT INTO mf.audit_log(utilisateur, table_name, operation, ligne_id, avant, apres)
  VALUES (v_user, TG_TABLE_NAME, TG_OP, COALESCE(v_row ->> 'id', v_row ->> 'client_id'),
          CASE WHEN TG_OP IN ('UPDATE','DELETE') THEN to_jsonb(OLD) - 'pin_hash' - 'code_hash' END,
          CASE WHEN TG_OP IN ('INSERT','UPDATE') THEN to_jsonb(NEW) - 'pin_hash' - 'code_hash' END);
  RETURN NULL;
END $$;
CREATE TRIGGER audit_client_acces AFTER INSERT OR UPDATE OR DELETE ON client_acces FOR EACH ROW EXECUTE FUNCTION trg_audit_sans_secret();
