-- =====================================================================
-- 38_procuration_cheques.sql
-- Contrôles du guide (caisse, liquidités, épargne) :
--   * procurations sur un compte d'épargne : créées puis validées par une autre personne, bornées dans le temps et par
--     un plafond ; un retrait par mandataire doit citer une procuration valide
--   * chèques : signatures requises (directeur + comptable ; + président du conseil au-delà du plafond), le
--     préparateur ne signe pas, chaque personne signe une fois ; émission seulement quand tout est signé
--   * comptes dormants : clôture (solde nul) ou blocage (solde non nul)
-- Dépend de : 01, 13, 36.
-- =====================================================================
SET search_path = mf, public;

INSERT INTO parametre(cle, valeur, description) VALUES
  ('cheque_plafond_trois_signatures', '1000000', 'Montant à partir duquel un chèque exige aussi la signature du président du conseil (provisoire)');

-- ---------------------------------------------------------------- procurations
CREATE TABLE procuration (
  id               serial PRIMARY KEY,
  agence_id        smallint NOT NULL REFERENCES agence(id),
  compte_id        integer NOT NULL REFERENCES compte_epargne(id),
  mandataire_nom   text NOT NULL,
  mandataire_piece text NOT NULL,                  -- type et numéro de la pièce d'identité contrôlée
  mandataire_tel   varchar(30),
  debut            date NOT NULL DEFAULT current_date,
  fin              date,
  plafond          numeric(14,0) CHECK (plafond IS NULL OR plafond > 0),   -- par opération ; NULL = pas de plafond
  statut           varchar(12) NOT NULL DEFAULT 'en_attente' CHECK (statut IN ('en_attente','validee','revoquee')),
  cree_par         integer REFERENCES utilisateur(id),
  validee_par      integer REFERENCES utilisateur(id),
  validee_le       timestamptz,
  cree_le          timestamptz NOT NULL DEFAULT now(),
  CHECK (fin IS NULL OR fin >= debut),
  CHECK (statut <> 'validee' OR (validee_par IS NOT NULL AND validee_par IS DISTINCT FROM cree_par))
);

ALTER TABLE mouvement_epargne ADD COLUMN procuration_id integer REFERENCES procuration(id);

CREATE FUNCTION trg_mouvement_procuration() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE p mf.procuration;
BEGIN
  IF NEW.procuration_id IS NULL THEN RETURN NEW; END IF;
  IF NEW.type <> 'retrait' THEN RAISE EXCEPTION 'Une procuration ne s''applique qu''à un retrait'; END IF;
  SELECT * INTO p FROM mf.procuration WHERE id = NEW.procuration_id;
  IF p.compte_id <> NEW.compte_id THEN RAISE EXCEPTION 'Cette procuration concerne un autre compte'; END IF;
  IF p.statut <> 'validee' THEN RAISE EXCEPTION 'Procuration non validée (statut %)', p.statut; END IF;
  IF NEW.date_operation < p.debut OR (p.fin IS NOT NULL AND NEW.date_operation > p.fin) THEN
    RAISE EXCEPTION 'Procuration hors de sa période de validité';
  END IF;
  IF p.plafond IS NOT NULL AND NEW.montant > p.plafond THEN
    RAISE EXCEPTION 'Le retrait dépasse le plafond de la procuration (%)', p.plafond;
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER mouvement_procuration BEFORE INSERT ON mouvement_epargne FOR EACH ROW EXECUTE FUNCTION trg_mouvement_procuration();

CREATE FUNCTION valider_procuration(p_procuration integer, p_utilisateur integer) RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  UPDATE mf.procuration SET statut = 'validee', validee_par = p_utilisateur, validee_le = now()
   WHERE id = p_procuration AND statut = 'en_attente';
  IF NOT FOUND THEN RAISE EXCEPTION 'Procuration introuvable ou déjà traitée'; END IF;
END $$;

-- ---------------------------------------------------------------- chèques
CREATE TABLE cheque_emission (
  id               serial PRIMARY KEY,
  agence_id        smallint NOT NULL REFERENCES agence(id),
  compte_banque_id integer NOT NULL REFERENCES compte_banque(id),
  numero_cheque    varchar(30) NOT NULL,
  beneficiaire     text NOT NULL,
  objet            text NOT NULL,
  montant          numeric(14,0) NOT NULL CHECK (montant > 0),
  trois_signatures boolean NOT NULL,               -- figé à la préparation selon le plafond
  statut           varchar(10) NOT NULL DEFAULT 'prepare' CHECK (statut IN ('prepare','emis','annule')),
  cree_par         integer REFERENCES utilisateur(id),
  cree_le          timestamptz NOT NULL DEFAULT now(),
  emis_le          timestamptz,
  UNIQUE (compte_banque_id, numero_cheque)
);

CREATE FUNCTION trg_cheque_plafond() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF TG_OP = 'INSERT' THEN
    NEW.trois_signatures := NEW.montant >= COALESCE(mf.param_num('cheque_plafond_trois_signatures', NEW.agence_id), 1000000);
  ELSIF NEW.montant <> OLD.montant OR NEW.trois_signatures <> OLD.trois_signatures THEN
    RAISE EXCEPTION 'Le montant d''un chèque ne se modifie pas : annuler et refaire';
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER cheque_plafond BEFORE INSERT OR UPDATE ON cheque_emission FOR EACH ROW EXECUTE FUNCTION trg_cheque_plafond();

CREATE TABLE cheque_signature (
  cheque_id       integer NOT NULL REFERENCES cheque_emission(id),
  utilisateur_id  integer NOT NULL REFERENCES utilisateur(id),
  fonction        varchar(15) NOT NULL CHECK (fonction IN ('directeur','comptable','president_ca')),
  signe_le        timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (cheque_id, utilisateur_id),
  UNIQUE (cheque_id, fonction)
);

CREATE FUNCTION trg_cheque_signature() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE c mf.cheque_emission; v_role text;
BEGIN
  SELECT * INTO c FROM mf.cheque_emission WHERE id = NEW.cheque_id;
  IF c.statut <> 'prepare' THEN RAISE EXCEPTION 'Le chèque n''est plus à signer (statut %)', c.statut; END IF;
  IF NEW.utilisateur_id IS NOT DISTINCT FROM c.cree_par THEN
    RAISE EXCEPTION 'Séparation des tâches : celui qui prépare le chèque ne le signe pas';
  END IF;
  IF NEW.fonction = 'president_ca' AND NOT c.trois_signatures THEN
    RAISE EXCEPTION 'La signature du président n''est requise qu''au-delà du plafond';
  END IF;
  SELECT role::text INTO v_role FROM mf.utilisateur WHERE id = NEW.utilisateur_id;
  IF (NEW.fonction = 'directeur' AND v_role <> 'directeur') OR (NEW.fonction = 'comptable' AND v_role <> 'comptable')
     OR (NEW.fonction = 'president_ca' AND v_role <> 'admin') THEN
    RAISE EXCEPTION 'Le rôle % ne peut pas signer en qualité de %', v_role, NEW.fonction;
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER cheque_signature_regles BEFORE INSERT ON cheque_signature FOR EACH ROW EXECUTE FUNCTION trg_cheque_signature();

CREATE FUNCTION emettre_cheque(p_cheque integer) RETURNS void LANGUAGE plpgsql AS $$
DECLARE c mf.cheque_emission; v_n integer; v_req integer;
BEGIN
  SELECT * INTO c FROM mf.cheque_emission WHERE id = p_cheque FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'chèque % inconnu', p_cheque; END IF;
  IF c.statut <> 'prepare' THEN RAISE EXCEPTION 'Chèque déjà %', c.statut; END IF;
  SELECT count(*) INTO v_n FROM mf.cheque_signature WHERE cheque_id = p_cheque;
  v_req := CASE WHEN c.trois_signatures THEN 3 ELSE 2 END;
  IF v_n < v_req THEN
    RAISE EXCEPTION 'Signatures insuffisantes : % sur % requises', v_n, v_req;
  END IF;
  UPDATE mf.cheque_emission SET statut = 'emis', emis_le = now() WHERE id = p_cheque;
END $$;

-- ---------------------------------------------------------------- comptes dormants
CREATE FUNCTION traiter_compte_dormant(p_compte integer, p_action text) RETURNS text LANGUAGE plpgsql AS $$
DECLARE d mf.v_compte_dormant;
BEGIN
  SELECT * INTO d FROM mf.v_compte_dormant WHERE compte_id = p_compte;
  IF NOT FOUND THEN RAISE EXCEPTION 'Ce compte n''est pas dormant'; END IF;
  IF p_action = 'clore' THEN
    IF d.solde <> 0 THEN RAISE EXCEPTION 'Clôture impossible : solde non nul (%) ; bloquer le compte et prévenir le client', d.solde; END IF;
    UPDATE mf.compte_epargne SET statut = 'clos' WHERE id = p_compte;
    RETURN 'clos';
  ELSIF p_action = 'bloquer' THEN
    UPDATE mf.compte_epargne SET statut = 'bloque' WHERE id = p_compte;
    RETURN 'bloque';
  END IF;
  RAISE EXCEPTION 'Action inconnue : % (clore ou bloquer)', p_action;
END $$;

CREATE TRIGGER audit_procuration AFTER INSERT OR UPDATE OR DELETE ON procuration FOR EACH ROW EXECUTE FUNCTION trg_audit();
CREATE TRIGGER audit_cheque_emission AFTER INSERT OR UPDATE OR DELETE ON cheque_emission FOR EACH ROW EXECUTE FUNCTION trg_audit();
CREATE TRIGGER audit_cheque_signature AFTER INSERT OR UPDATE OR DELETE ON cheque_signature FOR EACH ROW EXECUTE FUNCTION trg_audit();
