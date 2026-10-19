-- =====================================================================
-- 28_depots_garantie_terme.sql
-- Dépôts bloqués d'un compte d'épargne classique : dépôt de garantie et dépôt à terme.
--   Dépôt de garantie : un dépôt en espèces bloqué dès son encaissement (il réduit le solde disponible du compte), éventuellement
--     rattaché à un crédit. Il se libère par déblocage ; si un crédit y est rattaché, celui-ci doit être soldé.
--   Dépôt à terme : un montant prélevé sur le compte et placé pour une durée en mois à un taux annuel (paramètre dat_taux_annuel,
--     modifiable à la souscription). Intérêts simples : montant x taux x durée / 12.
--     À l'échéance : déblocage = capital + intérêts versés sur le compte.
--     Avant l'échéance : rupture anticipée = capital seul + intérêts courus au prorata, diminués de la pénalité
--     (paramètre dat_penalite_rupture_pct : part des intérêts courus perdue, 100 = tout).
-- Paramètres : dat_taux_annuel, dat_duree_min_mois, dat_montant_min, dat_penalite_rupture_pct.
-- Hors périmètre : renouvellement automatique, retenue fiscale, écritures comptables spécifiques des dépôts à terme.
-- Remplace solde_disponible (garanties de dépôt déduites) et radier_adhesion_compte (sortie refusée avec un dépôt bloqué).
-- Dépend de : 01, 08, 27.
-- =====================================================================
SET search_path = mf, public;

INSERT INTO parametre(agence_id, cle, valeur, description) VALUES
  (NULL, 'dat_taux_annuel', '0.04', 'taux annuel des dépôts à terme (fraction : 0.04 = 4 %)'),
  (NULL, 'dat_duree_min_mois', '3', 'durée minimale d''un dépôt à terme (mois)'),
  (NULL, 'dat_montant_min', '50000', 'montant minimal d''un dépôt à terme (F)'),
  (NULL, 'dat_penalite_rupture_pct', '100', 'rupture anticipée : part des intérêts courus perdue (%)')
ON CONFLICT DO NOTHING;

CREATE TABLE depot_garantie (
  id               serial PRIMARY KEY,
  agence_id        smallint NOT NULL REFERENCES agence(id),
  client_id        integer NOT NULL REFERENCES client(id),
  compte_id        integer NOT NULL REFERENCES compte_epargne(id),
  numero           varchar(25) NOT NULL,
  montant          numeric(14,0) NOT NULL CHECK (montant > 0),
  motif            text,
  credit_id        integer REFERENCES credit(id),
  date_depot       date NOT NULL,
  statut           varchar(10) NOT NULL DEFAULT 'bloque' CHECK (statut IN ('bloque','libere')),
  date_liberation  date,
  utilisateur_id   integer REFERENCES utilisateur(id),
  cree_le          timestamptz NOT NULL DEFAULT now(),
  UNIQUE (agence_id, numero),
  CHECK ((statut = 'libere') = (date_liberation IS NOT NULL))
);
CREATE INDEX depot_garantie_compte ON depot_garantie (compte_id) WHERE statut = 'bloque';
CREATE TRIGGER depot_garantie_numero BEFORE INSERT ON depot_garantie FOR EACH ROW EXECUTE FUNCTION trg_numerotation('DG');

CREATE TABLE depot_terme (
  id               serial PRIMARY KEY,
  agence_id        smallint NOT NULL REFERENCES agence(id),
  client_id        integer NOT NULL REFERENCES client(id),
  compte_id        integer NOT NULL REFERENCES compte_epargne(id),
  numero           varchar(25) NOT NULL,
  montant          numeric(14,0) NOT NULL CHECK (montant > 0),
  duree_mois       smallint NOT NULL CHECK (duree_mois > 0),
  taux_annuel      numeric(7,5) NOT NULL CHECK (taux_annuel >= 0),
  date_depot       date NOT NULL,
  date_echeance    date NOT NULL,
  interets_prevus  numeric(14,0) NOT NULL,
  statut           varchar(10) NOT NULL DEFAULT 'en_cours' CHECK (statut IN ('en_cours','verse','rompu')),
  date_deblocage   date,
  interets_verses  numeric(14,0),
  utilisateur_id   integer REFERENCES utilisateur(id),
  cree_le          timestamptz NOT NULL DEFAULT now(),
  UNIQUE (agence_id, numero),
  CHECK (date_echeance > date_depot),
  CHECK ((statut = 'en_cours') = (date_deblocage IS NULL))
);
CREATE INDEX depot_terme_compte ON depot_terme (compte_id, statut);
CREATE TRIGGER depot_terme_numero BEFORE INSERT ON depot_terme FOR EACH ROW EXECUTE FUNCTION trg_numerotation('DT');

-- Solde disponible = solde - solde minimum - garanties de crédit bloquées - dépôts de garantie bloqués
CREATE OR REPLACE FUNCTION solde_disponible(p_compte integer) RETURNS numeric
LANGUAGE sql STABLE AS $$
  SELECT GREATEST(v.solde - p.solde_minimum
                  - COALESCE((SELECT sum(g.montant_restant) FROM mf.garantie_compte g
                               WHERE g.compte_id = p_compte AND g.statut = 'bloquee'), 0)
                  - COALESCE((SELECT sum(d.montant) FROM mf.depot_garantie d
                               WHERE d.compte_id = p_compte AND d.statut = 'bloque'), 0), 0)
    FROM mf.v_solde_compte_epargne v
    JOIN mf.compte_epargne c ON c.id = v.compte_id
    JOIN mf.produit_epargne p ON p.id = c.produit_id
   WHERE v.compte_id = p_compte
$$;

CREATE FUNCTION deposer_garantie(p_compte integer, p_montant numeric, p_date date DEFAULT current_date, p_motif text DEFAULT NULL,
                                 p_credit integer DEFAULT NULL, p_utilisateur integer DEFAULT NULL) RETURNS integer
LANGUAGE plpgsql AS $$
DECLARE ce mf.compte_epargne; cr mf.credit; v_id integer;
BEGIN
  SELECT * INTO ce FROM mf.compte_epargne WHERE id = p_compte FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'compte % inconnu', p_compte; END IF;
  IF ce.statut <> 'actif' THEN RAISE EXCEPTION 'compte % non actif', ce.numero; END IF;
  IF p_montant IS NULL OR p_montant <= 0 THEN RAISE EXCEPTION 'le montant doit être positif'; END IF;
  IF p_date > current_date THEN RAISE EXCEPTION 'la date du dépôt ne peut pas être dans le futur'; END IF;
  IF p_credit IS NOT NULL THEN
    SELECT * INTO cr FROM mf.credit WHERE id = p_credit;
    IF NOT FOUND THEN RAISE EXCEPTION 'crédit % inconnu', p_credit; END IF;
    IF cr.client_id <> ce.client_id THEN RAISE EXCEPTION 'le crédit % n''appartient pas au client du compte', cr.numero; END IF;
    IF cr.statut = 'solde' THEN RAISE EXCEPTION 'le crédit % est déjà soldé', cr.numero; END IF;
  END IF;
  INSERT INTO mf.depot_garantie(agence_id, client_id, compte_id, montant, motif, credit_id, date_depot, utilisateur_id)
  VALUES (ce.agence_id, ce.client_id, p_compte, p_montant, p_motif, p_credit, p_date, p_utilisateur) RETURNING id INTO v_id;
  INSERT INTO mf.mouvement_epargne(compte_id, type, montant, date_operation, libelle, reference)
  VALUES (p_compte, 'depot', p_montant, p_date, 'Dépôt de garantie' || COALESCE(' : ' || p_motif, ''), 'depot_garantie:' || v_id);
  RETURN v_id;
END $$;

CREATE FUNCTION liberer_depot_garantie(p_id integer, p_date date DEFAULT current_date, p_utilisateur integer DEFAULT NULL) RETURNS void
LANGUAGE plpgsql AS $$
DECLARE d mf.depot_garantie; cr mf.credit;
BEGIN
  SELECT * INTO d FROM mf.depot_garantie WHERE id = p_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'dépôt de garantie % inconnu', p_id; END IF;
  IF d.statut <> 'bloque' THEN RAISE EXCEPTION 'dépôt de garantie % déjà libéré', d.numero; END IF;
  IF p_date > current_date THEN RAISE EXCEPTION 'la date de déblocage ne peut pas être dans le futur'; END IF;
  IF p_date < d.date_depot THEN RAISE EXCEPTION 'la date de déblocage précède le dépôt'; END IF;
  IF d.credit_id IS NOT NULL THEN
    SELECT * INTO cr FROM mf.credit WHERE id = d.credit_id;
    IF cr.statut <> 'solde' THEN RAISE EXCEPTION 'déblocage refusé : le crédit % rattaché n''est pas soldé', cr.numero; END IF;
  END IF;
  UPDATE mf.depot_garantie SET statut = 'libere', date_liberation = p_date WHERE id = p_id;
END $$;

CREATE FUNCTION placer_depot_terme(p_compte integer, p_montant numeric, p_duree_mois integer, p_date date DEFAULT current_date,
                                   p_taux numeric DEFAULT NULL, p_utilisateur integer DEFAULT NULL) RETURNS integer
LANGUAGE plpgsql AS $$
DECLARE ce mf.compte_epargne; v_taux numeric; v_id integer; v_min numeric; v_dmin integer;
BEGIN
  SELECT * INTO ce FROM mf.compte_epargne WHERE id = p_compte FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'compte % inconnu', p_compte; END IF;
  IF ce.statut <> 'actif' THEN RAISE EXCEPTION 'compte % non actif', ce.numero; END IF;
  IF p_date > current_date THEN RAISE EXCEPTION 'la date du placement ne peut pas être dans le futur'; END IF;
  v_min := COALESCE(mf.param_num('dat_montant_min', ce.agence_id), 0);
  v_dmin := COALESCE(mf.param_num('dat_duree_min_mois', ce.agence_id), 1);
  IF p_montant IS NULL OR p_montant < GREATEST(v_min, 1) THEN RAISE EXCEPTION 'montant minimal d''un dépôt à terme : % F', GREATEST(v_min, 1); END IF;
  IF p_duree_mois IS NULL OR p_duree_mois < v_dmin THEN RAISE EXCEPTION 'durée minimale d''un dépôt à terme : % mois', v_dmin; END IF;
  v_taux := COALESCE(p_taux, mf.param_num('dat_taux_annuel', ce.agence_id), 0);
  IF v_taux < 0 THEN RAISE EXCEPTION 'le taux ne peut pas être négatif'; END IF;
  INSERT INTO mf.depot_terme(agence_id, client_id, compte_id, montant, duree_mois, taux_annuel, date_depot, date_echeance, interets_prevus, utilisateur_id)
  VALUES (ce.agence_id, ce.client_id, p_compte, p_montant, p_duree_mois, v_taux, p_date, (p_date + make_interval(months => p_duree_mois))::date,
          round(p_montant * v_taux * p_duree_mois / 12), p_utilisateur) RETURNING id INTO v_id;
  -- sortie du compte : refusée si le disponible ne couvre pas le placement
  INSERT INTO mf.mouvement_epargne(compte_id, type, montant, date_operation, libelle, reference)
  VALUES (p_compte, 'virement_sortant', p_montant, p_date, 'Placement à terme n° ' || v_id, 'depot_terme:' || v_id);
  RETURN v_id;
END $$;

-- Versement du capital et des intérêts sur le compte ; p_rupture : retrait anticipé (intérêts courus au prorata, pénalité déduite)
CREATE FUNCTION solder_depot_terme(p_id integer, p_date date, p_rupture boolean, p_utilisateur integer) RETURNS numeric
LANGUAGE plpgsql AS $$
DECLARE d mf.depot_terme; ce mf.compte_epargne; v_interets numeric; v_pen numeric;
BEGIN
  SELECT * INTO d FROM mf.depot_terme WHERE id = p_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'dépôt à terme % inconnu', p_id; END IF;
  IF d.statut <> 'en_cours' THEN RAISE EXCEPTION 'dépôt à terme % déjà soldé', d.numero; END IF;
  IF p_date > current_date THEN RAISE EXCEPTION 'la date ne peut pas être dans le futur'; END IF;
  IF p_date < d.date_depot THEN RAISE EXCEPTION 'la date précède le placement'; END IF;
  SELECT * INTO ce FROM mf.compte_epargne WHERE id = d.compte_id;
  IF ce.statut <> 'actif' THEN RAISE EXCEPTION 'compte % non actif', ce.numero; END IF;
  IF p_rupture THEN
    IF p_date >= d.date_echeance THEN RAISE EXCEPTION 'le dépôt % est échu : utiliser le déblocage à l''échéance', d.numero; END IF;
    v_pen := LEAST(GREATEST(COALESCE(mf.param_num('dat_penalite_rupture_pct', d.agence_id), 100), 0), 100);
    v_interets := round(d.interets_prevus * (p_date - d.date_depot)::numeric / (d.date_echeance - d.date_depot) * (100 - v_pen) / 100);
  ELSE
    IF p_date < d.date_echeance THEN RAISE EXCEPTION 'échéance du dépôt % non atteinte (%) : rupture anticipée seulement', d.numero, d.date_echeance; END IF;
    v_interets := d.interets_prevus;
  END IF;
  INSERT INTO mf.mouvement_epargne(compte_id, type, montant, date_operation, libelle, reference)
  VALUES (d.compte_id, 'virement_entrant', d.montant, p_date,
          CASE WHEN p_rupture THEN 'Rupture anticipée du dépôt à terme ' ELSE 'Échéance du dépôt à terme ' END || d.numero, 'depot_terme:' || d.id);
  IF v_interets > 0 THEN
    INSERT INTO mf.mouvement_epargne(compte_id, type, montant, date_operation, libelle, reference)
    VALUES (d.compte_id, 'interet', v_interets, p_date, 'Intérêts du dépôt à terme ' || d.numero, 'depot_terme:' || d.id);
  END IF;
  UPDATE mf.depot_terme SET statut = CASE WHEN p_rupture THEN 'rompu' ELSE 'verse' END, date_deblocage = p_date, interets_verses = v_interets,
                            utilisateur_id = COALESCE(p_utilisateur, utilisateur_id)
   WHERE id = p_id;
  RETURN v_interets;
END $$;

CREATE FUNCTION debloquer_depot_terme(p_id integer, p_date date DEFAULT current_date, p_utilisateur integer DEFAULT NULL) RETURNS numeric
LANGUAGE sql AS $$ SELECT mf.solder_depot_terme(p_id, p_date, false, p_utilisateur) $$;

CREATE FUNCTION rompre_depot_terme(p_id integer, p_date date DEFAULT current_date, p_utilisateur integer DEFAULT NULL) RETURNS numeric
LANGUAGE sql AS $$ SELECT mf.solder_depot_terme(p_id, p_date, true, p_utilisateur) $$;

-- La sortie d'un compte (module 27) est aussi refusée tant qu'un dépôt de garantie ou un dépôt à terme y est en cours
CREATE OR REPLACE FUNCTION radier_adhesion_compte(p_compte integer, p_date date DEFAULT current_date, p_utilisateur integer DEFAULT NULL) RETURNS numeric
LANGUAGE plpgsql AS $$
DECLARE a mf.adhesion; ce mf.compte_epargne; v_parts integer; v_montant numeric;
BEGIN
  SELECT * INTO ce FROM mf.compte_epargne WHERE id = p_compte FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'compte % inconnu', p_compte; END IF;
  SELECT * INTO a FROM mf.adhesion WHERE compte_id = p_compte FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'le compte % n''a pas d''adhésion', ce.numero; END IF;
  IF a.statut <> 'active' THEN RAISE EXCEPTION 'adhésion % déjà radiée', a.numero; END IF;
  IF p_date > current_date THEN RAISE EXCEPTION 'la date de sortie ne peut pas être dans le futur'; END IF;
  IF EXISTS (SELECT 1 FROM mf.v_solde_compte_epargne v WHERE v.compte_id = p_compte AND v.solde > 0) THEN
    RAISE EXCEPTION 'sortie refusée : le compte % a encore un solde', ce.numero;
  END IF;
  IF EXISTS (SELECT 1 FROM mf.depot_garantie WHERE compte_id = p_compte AND statut = 'bloque')
     OR EXISTS (SELECT 1 FROM mf.depot_terme WHERE compte_id = p_compte AND statut = 'en_cours') THEN
    RAISE EXCEPTION 'sortie refusée : un dépôt de garantie ou un dépôt à terme est encore en cours sur le compte %', ce.numero;
  END IF;
  IF EXISTS (SELECT 1 FROM mf.liaison_tontine_epargne l JOIN mf.cycle cy ON cy.id = l.cycle_id WHERE l.compte_id = p_compte AND cy.statut = 'en_cours') THEN
    RAISE EXCEPTION 'sortie refusée : une souscription de tontine en cours est reliée au compte %', ce.numero;
  END IF;
  IF EXISTS (SELECT 1 FROM mf.credit WHERE client_id = ce.client_id AND statut <> 'solde' AND mode_remboursement = 'prelevement_compte') THEN
    RAISE EXCEPTION 'sortie refusée : un crédit non soldé est remboursé par prélèvement sur le compte';
  END IF;
  SELECT COALESCE(sum(nb_parts), 0), COALESCE(sum(montant), 0) INTO v_parts, v_montant FROM mf.souscription_part WHERE adhesion_id = a.id;
  INSERT INTO mf.remboursement_part(adhesion_id, nb_parts, montant, date_operation, utilisateur_id) VALUES (a.id, v_parts, v_montant, p_date, p_utilisateur);
  UPDATE mf.adhesion SET statut = 'radiee' WHERE id = a.id;
  UPDATE mf.compte_epargne SET statut = 'clos' WHERE id = p_compte;
  RETURN v_montant;
END $$;
