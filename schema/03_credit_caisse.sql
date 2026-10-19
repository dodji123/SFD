-- =====================================================================
-- 03_credit_caisse.sql
-- Crédits, échéances (capital constant ou annuité constante), imputation capital -> intérêts ->
-- pénalités, retard et points de fidélité, remboursement par seuil sur tontine, caisse.
-- Règles : BRIEF_CLAUDE_CODE.md section 3.4 (et 3.6 pour l'échéancier).
-- Dépend de : 00, 01, 02.  Les produits, demandes et garanties sur compte sont en 08.
-- =====================================================================
SET search_path = mf, public;

-- ---------------------------------------------------------------------
-- Caisse : sessions journalières et opérations
-- ---------------------------------------------------------------------
CREATE TABLE caisse (
  id        serial PRIMARY KEY,
  agence_id smallint NOT NULL REFERENCES agence(id),
  code      varchar(10) NOT NULL,
  type      varchar(12) NOT NULL DEFAULT 'principale' CHECK (type IN ('principale','guichet','coffre')),
  actif     boolean NOT NULL DEFAULT true,
  UNIQUE (agence_id, code)
);

CREATE TABLE session_caisse (
  id                  serial PRIMARY KEY,
  caisse_id           integer NOT NULL REFERENCES caisse(id),
  date_session        date NOT NULL,
  solde_ouverture     numeric(14,0) NOT NULL DEFAULT 0,
  billetage_ouverture jsonb,
  statut              varchar(10) NOT NULL DEFAULT 'ouverte' CHECK (statut IN ('ouverte','fermee')),
  solde_compte        numeric(14,0),             -- compté à la fermeture
  ecart_fermeture     numeric(14,0),             -- compté - théorique
  billetage_fermeture jsonb,
  ferme_le            timestamptz,
  utilisateur_id      integer REFERENCES utilisateur(id),
  UNIQUE (caisse_id, date_session)
);

CREATE TABLE operation_caisse (
  id              bigserial PRIMARY KEY,
  session_id      integer NOT NULL REFERENCES session_caisse(id),
  type            varchar(12) NOT NULL CHECK (type IN ('encaissement','decaissement')),
  motif           varchar(30) NOT NULL,
  montant         numeric(14,0) NOT NULL CHECK (montant > 0),
  date_operation  date NOT NULL,
  reference_table text,
  reference_id    bigint,
  libelle         text,
  cree_le         timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX operation_caisse_session ON operation_caisse (session_id);
CREATE INDEX operation_caisse_date ON operation_caisse (date_operation);

CREATE VIEW v_session_caisse_solde AS
SELECT s.id AS session_id, s.caisse_id, s.date_session, s.statut, s.solde_ouverture,
       COALESCE(sum(o.montant) FILTER (WHERE o.type = 'encaissement'), 0)::numeric(14,0) AS encaissements,
       COALESCE(sum(o.montant) FILTER (WHERE o.type = 'decaissement'), 0)::numeric(14,0) AS decaissements,
       (s.solde_ouverture
         + COALESCE(sum(o.montant) FILTER (WHERE o.type = 'encaissement'), 0)
         - COALESCE(sum(o.montant) FILTER (WHERE o.type = 'decaissement'), 0))::numeric(14,0) AS solde_theorique
  FROM session_caisse s LEFT JOIN operation_caisse o ON o.session_id = s.id
 GROUP BY s.id;

-- Enregistre une opération dans une session ouverte. Un décaissement ne peut pas dépasser le solde théorique.
CREATE FUNCTION caisse_operation(p_session integer, p_type text, p_motif text, p_montant numeric,
                                 p_date date DEFAULT current_date, p_ref_table text DEFAULT NULL,
                                 p_ref_id bigint DEFAULT NULL, p_libelle text DEFAULT NULL) RETURNS bigint
LANGUAGE plpgsql AS $$
DECLARE s mf.session_caisse; v_theo numeric; v_id bigint;
BEGIN
  SELECT * INTO s FROM mf.session_caisse WHERE id = p_session FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'session de caisse % inconnue', p_session; END IF;
  IF s.statut <> 'ouverte' THEN RAISE EXCEPTION 'session de caisse % fermée', p_session; END IF;
  IF p_type = 'decaissement' THEN
    SELECT solde_theorique INTO v_theo FROM mf.v_session_caisse_solde WHERE session_id = p_session;
    IF p_montant > v_theo THEN
      RAISE EXCEPTION 'caisse insuffisante : % demandé, solde théorique %', p_montant, v_theo;
    END IF;
  END IF;
  INSERT INTO mf.operation_caisse(session_id, type, motif, montant, date_operation, reference_table, reference_id, libelle)
  VALUES (p_session, p_type, p_motif, p_montant, p_date, p_ref_table, p_ref_id, p_libelle)
  RETURNING id INTO v_id;
  RETURN v_id;
END $$;

-- Fermeture : compare le solde compté (billetage) au solde théorique.
CREATE FUNCTION fermer_session_caisse(p_session integer, p_solde_compte numeric, p_billetage jsonb DEFAULT NULL,
                                      p_utilisateur integer DEFAULT NULL) RETURNS numeric
LANGUAGE plpgsql AS $$
DECLARE s mf.session_caisse; v_theo numeric;
BEGIN
  SELECT * INTO s FROM mf.session_caisse WHERE id = p_session FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'session de caisse % inconnue', p_session; END IF;
  IF s.statut <> 'ouverte' THEN RAISE EXCEPTION 'session de caisse % déjà fermée', p_session; END IF;
  SELECT solde_theorique INTO v_theo FROM mf.v_session_caisse_solde WHERE session_id = p_session;
  UPDATE mf.session_caisse
     SET statut = 'fermee', solde_compte = p_solde_compte, ecart_fermeture = p_solde_compte - v_theo,
         billetage_fermeture = p_billetage, ferme_le = now(), utilisateur_id = COALESCE(p_utilisateur, utilisateur_id)
   WHERE id = p_session;
  RETURN p_solde_compte - v_theo;
END $$;

-- ---------------------------------------------------------------------
-- Crédits et échéances
-- ---------------------------------------------------------------------
CREATE TABLE credit (
  id                 serial PRIMARY KEY,
  agence_id          smallint NOT NULL REFERENCES agence(id),
  numero             varchar(25) NOT NULL,
  client_id          integer NOT NULL REFERENCES client(id),
  type               varchar(15) NOT NULL CHECK (type IN ('sur_epargne','sans_epargne')),
  montant_accorde    numeric(14,0) NOT NULL CHECK (montant_accorde > 0),
  taux               numeric(7,5) NOT NULL CHECK (taux >= 0),     -- annuel, base 360 jours
  frais_dossier      numeric(14,0) NOT NULL DEFAULT 0,
  date_deblocage     date NOT NULL,
  nb_echeances       smallint NOT NULL CHECK (nb_echeances > 0),
  periodicite_jours  smallint NOT NULL DEFAULT 30 CHECK (periodicite_jours > 0),
  methode            varchar(20) NOT NULL DEFAULT 'capital_constant'
                     CHECK (methode IN ('capital_constant','annuite_constante')),
  mode_remboursement varchar(20) NOT NULL CHECK (mode_remboursement IN ('tontine','prelevement_compte','especes')),
  garantie_type      varchar(10) NOT NULL DEFAULT 'aucune' CHECK (garantie_type IN ('aucune','cycle','compte')),
  cycle_garantie_id  integer REFERENCES cycle(id),
  compte_id          integer REFERENCES compte_epargne(id),
  statut             varchar(10) NOT NULL DEFAULT 'en_cours' CHECK (statut IN ('en_cours','en_retard','solde')),
  date_solde         date,
  cree_le            timestamptz NOT NULL DEFAULT now(),
  UNIQUE (agence_id, numero),
  CHECK (mode_remboursement <> 'tontine' OR cycle_garantie_id IS NOT NULL)
);
CREATE INDEX credit_cycle_garantie ON credit (cycle_garantie_id);

CREATE TABLE echeance (
  id             serial PRIMARY KEY,
  credit_id      integer NOT NULL REFERENCES credit(id),
  no_echeance    smallint NOT NULL,
  date_prevue    date NOT NULL,
  capital        numeric(14,0) NOT NULL CHECK (capital >= 0),
  interet        numeric(14,0) NOT NULL DEFAULT 0 CHECK (interet >= 0),
  capital_paye   numeric(14,0) NOT NULL DEFAULT 0,
  interet_paye   numeric(14,0) NOT NULL DEFAULT 0,
  penalite_due   numeric(14,0) NOT NULL DEFAULT 0,
  penalite_payee numeric(14,0) NOT NULL DEFAULT 0,
  statut         varchar(10) NOT NULL DEFAULT 'a_venir' CHECK (statut IN ('a_venir','echue','partielle','payee')),
  date_paiement  date,                           -- date de l'échéance soldée (date d'atteinte du seuil pour la tontine)
  jours_retard   integer NOT NULL DEFAULT 0,
  UNIQUE (credit_id, no_echeance),
  CHECK (capital_paye <= capital AND interet_paye <= interet AND penalite_payee <= penalite_due)
);
CREATE INDEX echeance_date ON echeance (date_prevue) WHERE statut <> 'payee';

-- Un paiement par imputation (base des rapports et de la comptabilité : capital / intérêts / pénalités)
CREATE TABLE paiement_echeance (
  id             bigserial PRIMARY KEY,
  echeance_id    integer NOT NULL REFERENCES echeance(id),
  credit_id      integer NOT NULL REFERENCES credit(id),
  date_operation date NOT NULL,
  capital        numeric(14,0) NOT NULL DEFAULT 0,
  interet        numeric(14,0) NOT NULL DEFAULT 0,
  penalite       numeric(14,0) NOT NULL DEFAULT 0,
  source         varchar(20) NOT NULL CHECK (source IN ('tontine','prelevement','especes','saisie_garantie')),
  retrait_id     integer REFERENCES retrait(id),
  cree_le        timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX paiement_echeance_date ON paiement_echeance (date_operation);

CREATE TABLE points_fidelite (
  id             bigserial PRIMARY KEY,
  client_id      integer NOT NULL REFERENCES client(id),
  credit_id      integer REFERENCES credit(id),
  echeance_id    integer REFERENCES echeance(id),
  motif          varchar(30) NOT NULL,
  points         integer NOT NULL,
  date_operation date NOT NULL,
  cree_le        timestamptz NOT NULL DEFAULT now()
);
CREATE VIEW v_points_client AS
SELECT c.id AS client_id, COALESCE(sum(p.points), 0)::integer AS points
  FROM client c LEFT JOIN points_fidelite p ON p.client_id = c.id GROUP BY c.id;

-- Le retrait de nature « remboursement » référence l'échéance et la date d'atteinte du seuil.
ALTER TABLE retrait
  ADD COLUMN credit_id     integer REFERENCES credit(id),
  ADD COLUMN echeance_id   integer REFERENCES echeance(id),
  ADD COLUMN date_atteinte date;

CREATE VIEW v_credit_situation AS
SELECT c.id AS credit_id, c.agence_id, c.numero, c.client_id, c.type, c.mode_remboursement,
       c.montant_accorde,
       (c.montant_accorde - COALESCE(sum(e.capital_paye), 0))::numeric(14,0) AS capital_restant,
       count(e.id) FILTER (WHERE e.statut <> 'payee') AS nb_echeances_restantes,
       min(e.date_prevue) FILTER (WHERE e.statut <> 'payee') AS prochaine_echeance,
       c.statut
  FROM credit c LEFT JOIN echeance e ON e.credit_id = c.id GROUP BY c.id;

-- Le net d'un cycle déduit désormais les remboursements de crédit prélevés sur la collecte.
CREATE OR REPLACE VIEW v_cycle_situation AS
SELECT c.id AS cycle_id, c.agence_id, c.numero, c.client_id, c.type_cycle, c.statut,
       COALESCE(l.nb, 0)                           AS nb_lignes,
       COALESCE(l.total, 0)::numeric(14,0)         AS montant_collecte,
       CASE WHEN c.type_cycle = 3 THEN NULL
            ELSE COALESCE(l.mises, 0) + GREATEST(c.nb_lignes_prevues - COALESCE(l.nb, 0), 0) * c.mise_courante
       END                                         AS montant_previsionnel,
       CASE WHEN c.type_cycle = 3 THEN NULL
            ELSE COALESCE(l.mises, 0) + GREATEST(c.nb_lignes_prevues - COALESCE(l.nb, 0), 0) * c.mise_courante
                 - COALESCE(l.total, 0)
       END                                         AS reste_a_collecter,
       COALESCE(c.mise_finale, c.mise_courante)    AS mise_cycle,
       COALESCE(l.total, 0) - COALESCE(c.mise_finale, c.mise_courante) - COALESCE(r.rembourse, 0) AS net
  FROM cycle c
  LEFT JOIN (SELECT cycle_id, count(*) nb, sum(montant_collecte) total, sum(mise_appliquee) mises
               FROM ligne_collecte GROUP BY cycle_id) l ON l.cycle_id = c.id
  LEFT JOIN (SELECT cycle_id, sum(montant) rembourse FROM retrait
              WHERE nature = 'remboursement' AND statut <> 'annule' GROUP BY cycle_id) r ON r.cycle_id = c.id;

-- ---------------------------------------------------------------------
-- Pénalité de retard : capital de l'échéance x penalite_taux x jours, plafonnée à
-- penalite_plafond x (capital + intérêts) de l'échéance.
-- ---------------------------------------------------------------------
CREATE FUNCTION calcul_penalite(p_capital numeric, p_total numeric, p_jours integer, p_agence smallint DEFAULT NULL)
RETURNS numeric LANGUAGE sql STABLE AS $$
  SELECT CASE WHEN p_jours <= 0 THEN 0::numeric
              ELSE LEAST(round(p_capital * mf.param_num('penalite_taux', p_agence) * p_jours),
                         round(p_total * mf.param_num('penalite_plafond', p_agence))) END
$$;

-- ---------------------------------------------------------------------
-- Échéancier. intérêt d'une période = capital restant x taux annuel x jours / 360.
-- capital_constant : capital égal (reliquat sur la dernière) ; annuite_constante : annuité arrondie constante.
-- ---------------------------------------------------------------------
CREATE FUNCTION generer_echeancier(p_credit integer, p_periodicite integer DEFAULT NULL,
                                   p_methode text DEFAULT NULL) RETURNS integer
LANGUAGE plpgsql AS $$
DECLARE c mf.credit; v_p integer; v_m text; v_i numeric; v_n integer; v_rest numeric; v_annuite numeric;
        v_int numeric; v_cap numeric; k integer;
BEGIN
  SELECT * INTO c FROM mf.credit WHERE id = p_credit FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'crédit % inconnu', p_credit; END IF;
  IF EXISTS (SELECT 1 FROM mf.echeance WHERE credit_id = p_credit) THEN
    RAISE EXCEPTION 'le crédit % a déjà un échéancier', c.numero;
  END IF;
  v_p := COALESCE(p_periodicite, c.periodicite_jours);
  v_m := COALESCE(p_methode, c.methode);
  v_n := c.nb_echeances;
  v_i := c.taux * v_p / 360;
  v_rest := c.montant_accorde;
  IF v_m = 'annuite_constante' AND v_i > 0 THEN
    v_annuite := round(c.montant_accorde * v_i / (1 - power(1 + v_i, -v_n)));
  END IF;
  FOR k IN 1..v_n LOOP
    v_int := round(v_rest * v_i);
    IF k = v_n THEN
      v_cap := v_rest;
    ELSIF v_m = 'annuite_constante' AND v_annuite IS NOT NULL THEN
      v_cap := LEAST(GREATEST(v_annuite - v_int, 0), v_rest);
    ELSE
      v_cap := round(c.montant_accorde / v_n);
    END IF;
    INSERT INTO mf.echeance(credit_id, no_echeance, date_prevue, capital, interet)
    VALUES (p_credit, k, c.date_deblocage + v_p * k, v_cap, v_int);
    v_rest := v_rest - v_cap;
  END LOOP;
  UPDATE mf.credit SET periodicite_jours = v_p, methode = v_m WHERE id = p_credit;
  RETURN v_n;
END $$;

-- ---------------------------------------------------------------------
-- Imputation d'un paiement sur une échéance : capital, puis intérêts, puis pénalités.
-- Les échéances se règlent dans l'ordre. p_date = date d'effet : date d'atteinte du seuil
-- (tontine), date de prélèvement ou date d'encaissement. Retard, pénalité et points se calculent
-- sur cette date. Retourne le montant imputé.
-- ---------------------------------------------------------------------
CREATE FUNCTION imputer_echeance(p_echeance integer, p_montant numeric, p_date date, p_source text,
                                 p_retrait integer DEFAULT NULL) RETURNS numeric
LANGUAGE plpgsql AS $$
DECLARE e mf.echeance; c mf.credit; v_jours integer; v_pen numeric; v_du numeric;
        v_cap numeric; v_int numeric; v_pn numeric; v_rest numeric; v_solde boolean; v_retard boolean;
        v_tranches integer;
BEGIN
  SELECT * INTO e FROM mf.echeance WHERE id = p_echeance FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'échéance % inconnue', p_echeance; END IF;
  SELECT * INTO c FROM mf.credit WHERE id = e.credit_id FOR UPDATE;
  IF c.statut = 'solde' OR e.statut = 'payee' THEN RAISE EXCEPTION 'échéance % déjà payée', p_echeance; END IF;
  IF p_montant <= 0 THEN RAISE EXCEPTION 'montant invalide'; END IF;
  IF EXISTS (SELECT 1 FROM mf.echeance WHERE credit_id = e.credit_id AND no_echeance < e.no_echeance AND statut <> 'payee') THEN
    RAISE EXCEPTION 'les échéances se règlent dans l''ordre : l''échéance % du crédit % passe avant',
      (SELECT min(no_echeance) FROM mf.echeance WHERE credit_id = e.credit_id AND statut <> 'payee'), c.numero;
  END IF;

  v_jours := GREATEST(p_date - e.date_prevue, 0);
  -- pénalité à la date d'effet (et non la valeur stockée par la tâche quotidienne, qui peut être plus tardive)
  v_pen := GREATEST(mf.calcul_penalite(e.capital, e.capital + e.interet, v_jours, c.agence_id), e.penalite_payee);
  v_du := (e.capital - e.capital_paye) + (e.interet - e.interet_paye) + (v_pen - e.penalite_payee);
  IF p_montant > v_du THEN
    RAISE EXCEPTION 'montant % supérieur au dû % de l''échéance % du crédit %', p_montant, v_du, e.no_echeance, c.numero;
  END IF;

  v_cap  := LEAST(p_montant, e.capital - e.capital_paye);
  v_rest := p_montant - v_cap;
  v_int  := LEAST(v_rest, e.interet - e.interet_paye);
  v_rest := v_rest - v_int;
  v_pn   := v_rest;

  UPDATE mf.echeance
     SET capital_paye = capital_paye + v_cap, interet_paye = interet_paye + v_int,
         penalite_due = v_pen, penalite_payee = penalite_payee + v_pn
   WHERE id = p_echeance;
  v_solde := (e.capital_paye + v_cap = e.capital) AND (e.interet_paye + v_int = e.interet)
             AND (e.penalite_payee + v_pn = v_pen);
  UPDATE mf.echeance
     SET statut = CASE WHEN v_solde THEN 'payee' ELSE 'partielle' END,
         date_paiement = CASE WHEN v_solde THEN p_date ELSE date_paiement END,
         jours_retard = CASE WHEN v_solde THEN v_jours ELSE jours_retard END
   WHERE id = p_echeance;

  INSERT INTO mf.paiement_echeance(echeance_id, credit_id, date_operation, capital, interet, penalite, source, retrait_id)
  VALUES (p_echeance, e.credit_id, p_date, v_cap, v_int, v_pn, p_source, p_retrait);

  IF v_solde THEN
    -- points de fidélité : à temps +X ; en retard -Y par tranche de jours entamée
    IF v_jours = 0 THEN
      INSERT INTO mf.points_fidelite(client_id, credit_id, echeance_id, motif, points, date_operation)
      VALUES (c.client_id, c.id, p_echeance, 'echeance_a_temps', mf.param_num('points_a_temps', c.agence_id)::integer, p_date);
    ELSE
      v_tranches := ceil(v_jours::numeric / GREATEST(mf.param_num('jours_tranche_retard', c.agence_id), 1));
      INSERT INTO mf.points_fidelite(client_id, credit_id, echeance_id, motif, points, date_operation)
      VALUES (c.client_id, c.id, p_echeance, 'echeance_en_retard',
              -(v_tranches * mf.param_num('points_retard_par_tranche', c.agence_id))::integer, p_date);
    END IF;
    -- crédit soldé : dernière échéance payée
    IF NOT EXISTS (SELECT 1 FROM mf.echeance WHERE credit_id = c.id AND statut <> 'payee') THEN
      UPDATE mf.credit SET statut = 'solde', date_solde = p_date WHERE id = c.id;
      SELECT bool_or(jours_retard > 0) INTO v_retard FROM mf.echeance WHERE credit_id = c.id;
      IF NOT COALESCE(v_retard, false) THEN
        INSERT INTO mf.points_fidelite(client_id, credit_id, motif, points, date_operation)
        VALUES (c.client_id, c.id, 'credit_solde_sans_retard', mf.param_num('points_credit_solde', c.agence_id)::integer, p_date);
      END IF;
    END IF;
  END IF;
  RETURN p_montant;
END $$;

-- Dû d'une échéance à une date donnée (capital + intérêts restants + pénalité à cette date).
CREATE FUNCTION du_echeance(p_echeance integer, p_date date) RETURNS numeric
LANGUAGE sql STABLE AS $$
  SELECT (e.capital - e.capital_paye) + (e.interet - e.interet_paye)
         + GREATEST(mf.calcul_penalite(e.capital, e.capital + e.interet, GREATEST(p_date - e.date_prevue, 0), c.agence_id),
                    e.penalite_payee)
         - e.penalite_payee
    FROM mf.echeance e JOIN mf.credit c ON c.id = e.credit_id WHERE e.id = p_echeance
$$;

-- Tâche planifiée : passe les échéances dépassées en « echue » (ou « partielle »), calcule les pénalités
-- à la date donnée et met les crédits en retard. Retourne le nombre d'échéances mises à jour.
CREATE FUNCTION maj_statuts_credit(p_agence smallint, p_date date DEFAULT current_date) RETURNS integer
LANGUAGE plpgsql AS $$
DECLARE n integer;
BEGIN
  UPDATE mf.echeance e
     SET jours_retard = p_date - e.date_prevue,
         statut = CASE WHEN e.capital_paye + e.interet_paye + e.penalite_payee > 0 THEN 'partielle' ELSE 'echue' END,
         penalite_due = GREATEST(e.penalite_due,
                          mf.calcul_penalite(e.capital, e.capital + e.interet, p_date - e.date_prevue, c.agence_id))
    FROM mf.credit c
   WHERE e.credit_id = c.id AND c.agence_id = p_agence AND c.statut <> 'solde'
     AND e.statut <> 'payee' AND e.date_prevue < p_date;
  GET DIAGNOSTICS n = ROW_COUNT;
  UPDATE mf.credit c SET statut = 'en_retard'
   WHERE c.agence_id = p_agence AND c.statut = 'en_cours'
     AND EXISTS (SELECT 1 FROM mf.echeance e WHERE e.credit_id = c.id AND e.statut <> 'payee' AND e.date_prevue < p_date);
  RETURN n;
END $$;

-- ---------------------------------------------------------------------
-- Crédit sur tontine : le remboursement se déclenche quand le collecté du cycle (déduction faite des
-- remboursements déjà réservés) atteint le dû de l'échéance. Il est pris sur la collecte, sans
-- commission supplémentaire, et crée un retrait de nature « remboursement » sans décaissement.
-- La date d'atteinte du seuil (date de la ligne qui franchit le seuil) fixe retard, pénalité et points.
-- Le retrait suit ensuite le circuit des écarts (constater, traiter, exécuter) : pas d'exécution partielle.
-- ---------------------------------------------------------------------
CREATE FUNCTION declencher_remboursements(p_cycle integer) RETURNS integer
LANGUAGE plpgsql AS $$
DECLARE c mf.credit; e mf.echeance; l record; v_cum numeric; v_reserve numeric; v_du numeric;
        v_pen numeric; v_jours integer; v_date date; v_found boolean; v_n integer := 0;
BEGIN
  PERFORM 1 FROM mf.cycle WHERE id = p_cycle FOR UPDATE;
  FOR c IN SELECT * FROM mf.credit
            WHERE cycle_garantie_id = p_cycle AND mode_remboursement = 'tontine' AND statut <> 'solde' ORDER BY id LOOP
    LOOP
      SELECT ec.* INTO e FROM mf.echeance ec
       WHERE ec.credit_id = c.id AND ec.statut <> 'payee'
         AND NOT EXISTS (SELECT 1 FROM mf.retrait r WHERE r.echeance_id = ec.id AND r.nature = 'remboursement' AND r.statut <> 'annule')
       ORDER BY ec.no_echeance LIMIT 1;
      EXIT WHEN NOT FOUND;
      SELECT COALESCE(sum(montant), 0) INTO v_reserve FROM mf.retrait
       WHERE cycle_id = p_cycle AND nature = 'remboursement' AND statut <> 'annule';
      v_cum := 0; v_found := false;
      FOR l IN SELECT date_collecte, montant_collecte FROM mf.ligne_collecte WHERE cycle_id = p_cycle ORDER BY date_collecte, id LOOP
        v_cum := v_cum + l.montant_collecte;
        v_date := GREATEST(l.date_collecte, c.date_deblocage);
        v_jours := GREATEST(v_date - e.date_prevue, 0);
        v_pen := GREATEST(mf.calcul_penalite(e.capital, e.capital + e.interet, v_jours, c.agence_id), e.penalite_payee);
        v_du := (e.capital - e.capital_paye) + (e.interet - e.interet_paye) + (v_pen - e.penalite_payee);
        IF v_cum - v_reserve >= v_du THEN v_found := true; EXIT; END IF;
      END LOOP;
      EXIT WHEN NOT v_found;
      INSERT INTO mf.retrait(agence_id, cycle_id, nature, montant, decaissement, statut, date_demande,
                             credit_id, echeance_id, date_atteinte)
      VALUES (c.agence_id, p_cycle, 'remboursement', v_du, false, 'demande', v_date, c.id, e.id, v_date);
      v_n := v_n + 1;
    END LOOP;
  END LOOP;
  RETURN v_n;
END $$;

CREATE FUNCTION trg_ligne_remboursement() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  IF EXISTS (SELECT 1 FROM mf.credit WHERE cycle_garantie_id = NEW.cycle_id
              AND mode_remboursement = 'tontine' AND statut <> 'solde') THEN
    PERFORM mf.declencher_remboursements(NEW.cycle_id);
  END IF;
  RETURN NULL;
END $$;
CREATE TRIGGER ligne_remboursement AFTER INSERT ON ligne_collecte
  FOR EACH ROW EXECUTE FUNCTION trg_ligne_remboursement();

-- Appelée par executer_retrait (02) pour un retrait de nature « remboursement ».
CREATE FUNCTION exec_remboursement(p_retrait integer) RETURNS void
LANGUAGE plpgsql AS $$
DECLARE r mf.retrait;
BEGIN
  SELECT * INTO r FROM mf.retrait WHERE id = p_retrait;
  PERFORM mf.imputer_echeance(r.echeance_id, r.montant, r.date_atteinte, 'tontine', p_retrait);
END $$;
