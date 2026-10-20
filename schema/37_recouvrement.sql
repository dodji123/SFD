-- =====================================================================
-- 37_recouvrement.sql
-- Recouvrement (guide du contrôle interne, fiche 6.15) : d'abord à l'amiable (relances, visites), puis mise en demeure,
-- avals et réalisation des garanties ; passage en perte seulement après toutes les étapes, une visite du client et un
-- retard minimal, par une personne autre que l'agent de recouvrement. Rééchelonnement = nouveau dossier de crédit.
-- Dépend de : 03, 08, 11, 35.
-- =====================================================================
SET search_path = mf, public;

INSERT INTO parametre(cle, valeur, description) VALUES
  ('perte_min_retard_jours', '365', 'Retard minimal (jours) avant passage en perte d''un crédit (provisoire)');

CREATE TABLE dossier_recouvrement (
  id                   serial PRIMARY KEY,
  agence_id            smallint NOT NULL REFERENCES agence(id),
  credit_id            integer NOT NULL REFERENCES credit(id),
  ouvert_le            date NOT NULL DEFAULT current_date,
  ouvert_par           integer REFERENCES utilisateur(id),
  agent_id             integer REFERENCES utilisateur(id),            -- agent de recouvrement
  statut               varchar(20) NOT NULL DEFAULT 'amiable'
                       CHECK (statut IN ('amiable','mise_en_demeure','garanties','regle','perte')),
  montant_du_ouverture numeric(14,0) NOT NULL CHECK (montant_du_ouverture >= 0),
  note                 text,
  cloture_le           date,
  cloture_motif        text,
  CHECK ((statut IN ('regle','perte')) = (cloture_le IS NOT NULL))
);
CREATE UNIQUE INDEX dossier_recouvrement_un_ouvert ON dossier_recouvrement(credit_id) WHERE statut NOT IN ('regle','perte');

CREATE TABLE action_recouvrement (
  id              serial PRIMARY KEY,
  dossier_id      integer NOT NULL REFERENCES dossier_recouvrement(id),
  date_action     date NOT NULL DEFAULT current_date,
  type            varchar(25) NOT NULL CHECK (type IN
                    ('relance','appel','visite','accord_amiable','mise_en_demeure','mise_en_demeure_aval','saisie_salaire','vente_garantie')),
  resultat        text,
  montant_promis  numeric(14,0) CHECK (montant_promis IS NULL OR montant_promis > 0),
  date_promesse   date,
  valeur_estimee  numeric(14,0) CHECK (valeur_estimee IS NULL OR valeur_estimee > 0),   -- évaluation avant vente d'une garantie
  utilisateur_id  integer REFERENCES utilisateur(id),
  cree_le         timestamptz NOT NULL DEFAULT now(),
  CHECK (type <> 'vente_garantie' OR valeur_estimee IS NOT NULL),
  CHECK (type <> 'accord_amiable' OR (montant_promis IS NOT NULL AND date_promesse IS NOT NULL))
);

-- Radiation enregistrée (le crédit reste inchangé : le passage en charges comptable n'est pas automatisé)
CREATE TABLE radiation_credit (
  id              serial PRIMARY KEY,
  credit_id       integer NOT NULL UNIQUE REFERENCES credit(id),
  dossier_id      integer NOT NULL REFERENCES dossier_recouvrement(id),
  date_radiation  date NOT NULL DEFAULT current_date,
  capital_restant numeric(14,0) NOT NULL,
  motif           text NOT NULL,
  approuvee_par   integer REFERENCES utilisateur(id)
);

-- Jours de retard d'un crédit : plus ancienne échéance impayée
CREATE FUNCTION jours_retard_credit(p_credit integer, p_date date DEFAULT current_date) RETURNS integer
LANGUAGE sql STABLE AS $$
  SELECT COALESCE(max(p_date - e.date_prevue), 0)::integer FROM mf.echeance e
   WHERE e.credit_id = p_credit AND e.statut <> 'payee' AND e.date_prevue < p_date
$$;

CREATE FUNCTION ouvrir_dossier_recouvrement(p_credit integer, p_utilisateur integer DEFAULT NULL, p_agent integer DEFAULT NULL,
                                            p_note text DEFAULT NULL) RETURNS integer
LANGUAGE plpgsql AS $$
DECLARE c mf.credit; v_du numeric; v_id integer;
BEGIN
  SELECT * INTO c FROM mf.credit WHERE id = p_credit FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'crédit % inconnu', p_credit; END IF;
  IF c.statut <> 'en_retard' THEN RAISE EXCEPTION 'Le crédit % n''est pas en retard (statut %)', c.numero, c.statut; END IF;
  SELECT capital_restant INTO v_du FROM mf.v_credit_situation WHERE credit_id = p_credit;
  IF p_agent IS NOT NULL AND NOT EXISTS (
       SELECT 1 FROM mf.utilisateur u WHERE u.id = p_agent AND u.actif
          AND (mf.agences_utilisateur(u.id) IS NULL OR c.agence_id::int = ANY (mf.agences_utilisateur(u.id)))) THEN
    RAISE EXCEPTION 'L''agent de recouvrement doit être un utilisateur actif de l''agence du crédit';
  END IF;
  INSERT INTO mf.dossier_recouvrement(agence_id, credit_id, ouvert_par, agent_id, montant_du_ouverture, note)
  VALUES (c.agence_id, p_credit, p_utilisateur, COALESCE(p_agent, p_utilisateur), v_du, p_note) RETURNING id INTO v_id;
  RETURN v_id;
END $$;

-- Règles de l'enchaînement des actions
CREATE FUNCTION trg_action_recouvrement() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE d mf.dossier_recouvrement; v_amiable boolean; v_med boolean;
BEGIN
  SELECT * INTO d FROM mf.dossier_recouvrement WHERE id = NEW.dossier_id FOR UPDATE;
  IF d.statut IN ('regle','perte') THEN RAISE EXCEPTION 'Le dossier de recouvrement est clos (%)', d.statut; END IF;
  SELECT EXISTS (SELECT 1 FROM mf.action_recouvrement WHERE dossier_id = d.id AND type IN ('relance','appel','visite')) INTO v_amiable;
  SELECT EXISTS (SELECT 1 FROM mf.action_recouvrement WHERE dossier_id = d.id AND type = 'mise_en_demeure') INTO v_med;
  IF NEW.type = 'mise_en_demeure' AND NOT v_amiable THEN
    RAISE EXCEPTION 'Avant la mise en demeure : relances, appels ou visites à l''amiable obligatoires';
  END IF;
  IF NEW.type IN ('mise_en_demeure_aval','saisie_salaire','vente_garantie') AND NOT v_med THEN
    RAISE EXCEPTION 'Mise en demeure du débiteur obligatoire avant cette étape';
  END IF;
  IF NEW.type = 'mise_en_demeure' THEN
    UPDATE mf.dossier_recouvrement SET statut = 'mise_en_demeure' WHERE id = d.id AND statut = 'amiable';
  ELSIF NEW.type IN ('saisie_salaire','vente_garantie') THEN
    UPDATE mf.dossier_recouvrement SET statut = 'garanties' WHERE id = d.id;
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER action_recouvrement_regles BEFORE INSERT ON action_recouvrement FOR EACH ROW EXECUTE FUNCTION trg_action_recouvrement();

CREATE FUNCTION trg_action_immuable() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN RAISE EXCEPTION 'une action de recouvrement est conservée telle quelle (%)', TG_OP; END $$;
CREATE TRIGGER action_recouvrement_immuable BEFORE UPDATE OR DELETE ON action_recouvrement FOR EACH ROW EXECUTE FUNCTION trg_action_immuable();

-- Passage en perte : toutes les étapes faites, visite du client, retard minimal, approbateur distinct de l'agent
CREATE FUNCTION passer_en_perte(p_dossier integer, p_utilisateur integer, p_motif text) RETURNS integer
LANGUAGE plpgsql AS $$
DECLARE d mf.dossier_recouvrement; v_min numeric; v_retard integer; v_cap numeric; v_id integer;
BEGIN
  SELECT * INTO d FROM mf.dossier_recouvrement WHERE id = p_dossier FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'dossier % inconnu', p_dossier; END IF;
  IF d.statut NOT IN ('mise_en_demeure','garanties') THEN
    RAISE EXCEPTION 'Passage en perte impossible : le dossier est au stade « % » (mise en demeure obligatoire)', d.statut;
  END IF;
  IF length(btrim(COALESCE(p_motif, ''))) < 10 THEN RAISE EXCEPTION 'Le motif du passage en perte est obligatoire (10 caractères)'; END IF;
  IF p_utilisateur IS NOT DISTINCT FROM d.agent_id OR p_utilisateur IS NOT DISTINCT FROM d.ouvert_par
     OR EXISTS (SELECT 1 FROM mf.action_recouvrement WHERE dossier_id = d.id AND utilisateur_id = p_utilisateur) THEN
    RAISE EXCEPTION 'Séparation des tâches : celui qui a ouvert le dossier, l''agent de recouvrement ou un intervenant ne peut pas approuver le passage en perte';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM mf.action_recouvrement WHERE dossier_id = d.id AND type = 'visite') THEN
    RAISE EXCEPTION 'Une visite du client est obligatoire avant le passage en perte';
  END IF;
  v_min := COALESCE(mf.param_num('perte_min_retard_jours', d.agence_id), 365);
  v_retard := mf.jours_retard_credit(d.credit_id);
  IF v_retard < v_min THEN RAISE EXCEPTION 'Retard insuffisant : % jours (minimum %)', v_retard, v_min; END IF;
  SELECT capital_restant INTO v_cap FROM mf.v_credit_situation WHERE credit_id = d.credit_id;
  INSERT INTO mf.radiation_credit(credit_id, dossier_id, capital_restant, motif, approuvee_par)
  VALUES (d.credit_id, d.id, v_cap, p_motif, p_utilisateur) RETURNING id INTO v_id;
  UPDATE mf.dossier_recouvrement SET statut = 'perte', cloture_le = current_date, cloture_motif = p_motif WHERE id = d.id;
  RETURN v_id;
END $$;

CREATE FUNCTION cloturer_dossier_regle(p_dossier integer) RETURNS void LANGUAGE plpgsql AS $$
DECLARE d mf.dossier_recouvrement; v_statut text;
BEGIN
  SELECT * INTO d FROM mf.dossier_recouvrement WHERE id = p_dossier FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'dossier % inconnu', p_dossier; END IF;
  SELECT statut INTO v_statut FROM mf.credit WHERE id = d.credit_id;
  IF v_statut <> 'solde' THEN RAISE EXCEPTION 'Le crédit n''est pas soldé : le dossier reste ouvert'; END IF;
  UPDATE mf.dossier_recouvrement SET statut = 'regle', cloture_le = current_date, cloture_motif = 'Crédit soldé' WHERE id = p_dossier;
END $$;

-- Rééchelonnement = nouveau dossier : demande de crédit pour le capital restant, liée à l'ancien crédit
ALTER TABLE demande_credit ADD COLUMN reechelonne_de integer REFERENCES credit(id);

CREATE FUNCTION reechelonner_credit(p_credit integer, p_nb_echeances integer, p_note text DEFAULT NULL) RETURNS integer
LANGUAGE plpgsql AS $$
DECLARE c mf.credit; v_cap numeric; v_id integer; v_produit integer;
BEGIN
  SELECT * INTO c FROM mf.credit WHERE id = p_credit FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'crédit % inconnu', p_credit; END IF;
  IF c.statut <> 'en_retard' THEN RAISE EXCEPTION 'Seul un crédit en retard se rééchelonne'; END IF;
  IF EXISTS (SELECT 1 FROM mf.demande_credit WHERE reechelonne_de = p_credit AND statut IN ('demandee','approuvee')) THEN
    RAISE EXCEPTION 'Un rééchelonnement est déjà en cours pour ce crédit';
  END IF;
  SELECT capital_restant INTO v_cap FROM mf.v_credit_situation WHERE credit_id = p_credit;
  SELECT d.produit_id INTO v_produit FROM mf.demande_credit d WHERE d.credit_id = p_credit;
  IF v_produit IS NULL THEN RAISE EXCEPTION 'Produit d''origine introuvable pour ce crédit'; END IF;
  INSERT INTO mf.demande_credit(agence_id, client_id, produit_id, montant, nb_echeances, taux, mode_remboursement, note, reechelonne_de)
  VALUES (c.agence_id, c.client_id, v_produit, v_cap, p_nb_echeances, c.taux, c.mode_remboursement,
          COALESCE(p_note, 'Rééchelonnement du crédit ' || c.numero), p_credit) RETURNING id INTO v_id;
  RETURN v_id;
END $$;

CREATE TRIGGER audit_dossier_recouvrement AFTER INSERT OR UPDATE OR DELETE ON dossier_recouvrement FOR EACH ROW EXECUTE FUNCTION trg_audit();
CREATE TRIGGER audit_radiation_credit AFTER INSERT OR UPDATE OR DELETE ON radiation_credit FOR EACH ROW EXECUTE FUNCTION trg_audit();
