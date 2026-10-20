-- =====================================================================
-- 34_securite_comptes.sql
-- Sécurité des comptes du personnel (guide du contrôle interne : DICP, mot de passe temporaire,
-- journal des accès, alertes d'opérations inhabituelles, sauvegardes testées).
--   * contact (email, téléphone) pour la récupération du mot de passe
--   * mot de passe temporaire : doit_changer_mdp ; ancienneté : mdp_change_le
--   * historique des hachés (interdiction de réutiliser les derniers mots de passe)
--   * jetons de récupération à usage unique (seul le haché SHA-256 est conservé)
--   * journal des connexions, alertes de sécurité, messages sortants du personnel
--   * registre des sauvegardes et de leurs tests de restauration
--   * rôle « coordinateur » : périmètre réseau obligatoire
-- Dépend de : 00, 11, 33.
-- =====================================================================
SET search_path = mf, public;

ALTER TABLE utilisateur
  ADD COLUMN email             varchar(200),
  ADD COLUMN telephone         varchar(30),
  ADD COLUMN doit_changer_mdp  boolean NOT NULL DEFAULT false,
  ADD COLUMN mdp_change_le     timestamptz NOT NULL DEFAULT now();

-- un coordinateur dirige un réseau : périmètre réseau obligatoire (rôle ajouté au module 33)
ALTER TABLE utilisateur ADD CONSTRAINT utilisateur_coordinateur_reseau
  CHECK (role <> 'coordinateur' OR (reseau_id IS NOT NULL AND agence_id IS NULL));

-- Historique des mots de passe : alimenté automatiquement, quel que soit le chemin de modification.
CREATE TABLE historique_mdp (
  id              bigserial PRIMARY KEY,
  utilisateur_id  integer NOT NULL REFERENCES utilisateur(id),
  hash            text NOT NULL,
  cree_le         timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX historique_mdp_user ON historique_mdp(utilisateur_id, cree_le DESC);

CREATE FUNCTION trg_utilisateur_mdp() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF NEW.mot_de_passe_hash IS NOT NULL
     AND (TG_OP = 'INSERT' OR NEW.mot_de_passe_hash IS DISTINCT FROM OLD.mot_de_passe_hash) THEN
    NEW.mdp_change_le := now();
    -- l'historique est écrit après coup (la ligne doit exister pour la clé étrangère)
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER utilisateur_mdp_avant BEFORE INSERT OR UPDATE OF mot_de_passe_hash ON utilisateur
  FOR EACH ROW EXECUTE FUNCTION trg_utilisateur_mdp();

CREATE FUNCTION trg_utilisateur_mdp_histo() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF NEW.mot_de_passe_hash IS NOT NULL
     AND (TG_OP = 'INSERT' OR NEW.mot_de_passe_hash IS DISTINCT FROM OLD.mot_de_passe_hash) THEN
    INSERT INTO historique_mdp(utilisateur_id, hash) VALUES (NEW.id, NEW.mot_de_passe_hash);
  END IF;
  RETURN NULL;
END $$;
CREATE TRIGGER utilisateur_mdp_apres AFTER INSERT OR UPDATE OF mot_de_passe_hash ON utilisateur
  FOR EACH ROW EXECUTE FUNCTION trg_utilisateur_mdp_histo();

-- Jetons de récupération : à usage unique, durée limitée, haché seulement.
CREATE TABLE jeton_reinit_mdp (
  id              bigserial PRIMARY KEY,
  utilisateur_id  integer NOT NULL REFERENCES utilisateur(id),
  jeton_hash      char(64) NOT NULL UNIQUE,
  expire_le       timestamptz NOT NULL,
  utilise_le      timestamptz,
  ip              varchar(60),
  cree_le         timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX jeton_reinit_user ON jeton_reinit_mdp(utilisateur_id, cree_le DESC);

-- Journal des connexions (succès, échecs, verrouillages, récupérations, déconnexions)
CREATE TABLE journal_connexion (
  id              bigserial PRIMARY KEY,
  horodatage      timestamptz NOT NULL DEFAULT now(),
  login           varchar(60) NOT NULL,
  utilisateur_id  integer REFERENCES utilisateur(id),
  evenement       varchar(20) NOT NULL CHECK (evenement IN
                    ('succes','echec','verrouille','mdp_oublie','mdp_reinitialise','mdp_change','mdp_reinit_admin','hors_heures')),
  ip              varchar(60),
  detail          text
);
CREATE INDEX journal_connexion_date ON journal_connexion(horodatage DESC);
CREATE INDEX journal_connexion_user ON journal_connexion(utilisateur_id, horodatage DESC);

-- Alertes de sécurité (opérations inhabituelles) à traiter par la direction / le contrôle interne
CREATE TABLE alerte_securite (
  id              bigserial PRIMARY KEY,
  horodatage      timestamptz NOT NULL DEFAULT now(),
  type            varchar(30) NOT NULL CHECK (type IN
                    ('verrouillage','connexion_hors_heures','mdp_reinit_admin','retraits_fractionnes','operation_inhabituelle','sauvegarde_ancienne','autre')),
  gravite         varchar(10) NOT NULL DEFAULT 'moyenne' CHECK (gravite IN ('faible','moyenne','elevee')),
  utilisateur_id  integer REFERENCES utilisateur(id),
  agence_id       smallint REFERENCES agence(id),
  detail          text NOT NULL,
  traitee_le      timestamptz,
  traitee_par     integer REFERENCES utilisateur(id),
  commentaire     text,
  CHECK ((traitee_le IS NULL) = (traitee_par IS NULL))
);
CREATE INDEX alerte_securite_ouvertes ON alerte_securite(horodatage DESC) WHERE traitee_le IS NULL;

-- Messages sortants du personnel (lien de récupération, avis de sécurité) : en développement, simple journal.
CREATE TABLE message_personnel (
  id              bigserial PRIMARY KEY,
  utilisateur_id  integer REFERENCES utilisateur(id),
  canal           varchar(10) NOT NULL DEFAULT 'email' CHECK (canal IN ('email','sms')),
  destinataire    varchar(200),
  objet           text NOT NULL,
  corps           text NOT NULL,
  statut          varchar(10) NOT NULL DEFAULT 'en_attente' CHECK (statut IN ('en_attente','envoye','echec','ignore')),
  cree_le         timestamptz NOT NULL DEFAULT now(),
  envoye_le       timestamptz
);

-- Registre des sauvegardes : une sauvegarde n'est fiable qu'une fois sa restauration testée.
CREATE TABLE sauvegarde (
  id               serial PRIMARY KEY,
  effectuee_le     timestamptz NOT NULL,
  type             varchar(15) NOT NULL CHECK (type IN ('complete','incrementale','journal')),
  support          text NOT NULL,                       -- ex. « disque externe coffre », « serveur distant »
  emplacement      text,
  taille_mo        numeric(12,2) CHECK (taille_mo IS NULL OR taille_mo >= 0),
  empreinte        varchar(128),                        -- somme de contrôle du fichier
  effectuee_par    integer REFERENCES utilisateur(id),
  test_restaure_le timestamptz,
  test_par         integer REFERENCES utilisateur(id),
  test_resultat    varchar(10) CHECK (test_resultat IN ('reussi','echec')),
  test_commentaire text,
  CHECK ((test_restaure_le IS NULL) = (test_resultat IS NULL)),
  CHECK (test_restaure_le IS NULL OR test_restaure_le >= effectuee_le)
);

-- Un test de restauration est fait par une autre personne que celle qui a sauvegardé (séparation des tâches).
CREATE FUNCTION trg_sauvegarde_test() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF NEW.test_par IS NOT NULL AND NEW.test_par = NEW.effectuee_par THEN
    RAISE EXCEPTION 'Le test de restauration doit être fait par une autre personne que l''auteur de la sauvegarde';
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER sauvegarde_test BEFORE INSERT OR UPDATE ON sauvegarde
  FOR EACH ROW EXECUTE FUNCTION trg_sauvegarde_test();

-- Dernière sauvegarde dont la restauration a été testée avec succès
CREATE VIEW v_sauvegarde_fiable AS
  SELECT max(effectuee_le) AS derniere_fiable
  FROM sauvegarde WHERE test_resultat = 'reussi';

-- Piste d'audit des alertes et sauvegardes (les tables à secrets — hachés, jetons — ne sont pas auditées)
CREATE TRIGGER audit_alerte_securite AFTER INSERT OR UPDATE OR DELETE ON alerte_securite
  FOR EACH ROW EXECUTE FUNCTION trg_audit();
CREATE TRIGGER audit_sauvegarde AFTER INSERT OR UPDATE OR DELETE ON sauvegarde
  FOR EACH ROW EXECUTE FUNCTION trg_audit();
