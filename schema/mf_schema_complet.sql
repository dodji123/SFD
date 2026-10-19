-- Schéma complet mf : généré par tools/build_schema_complet.sh (ne pas éditer : modifier les modules).
-- Chargement : psql -v ON_ERROR_STOP=1 -f mf_schema_complet.sql   (PostgreSQL 14+, extension btree_gist)

-- =====================================================================
-- MODULE 00_noyau.sql
-- =====================================================================
-- =====================================================================
-- 00_noyau.sql : types, agences, utilisateurs, zones, agents, collectrices,
-- affectations sans chevauchement, paramètres (surcharge par agence), audit.
-- Reconstruit depuis BRIEF_CLAUDE_CODE.md (sections 2 et 3.2).
-- =====================================================================
CREATE EXTENSION IF NOT EXISTS btree_gist;
CREATE SCHEMA IF NOT EXISTS mf;
SET search_path = mf, public;

CREATE TYPE role_utilisateur AS ENUM
  ('admin','directeur','chef_agence','caissier','comptable','agent','collectrice','rh','auditeur');

CREATE TABLE agence (
  id        smallserial PRIMARY KEY,
  code      varchar(10) NOT NULL UNIQUE,
  libelle   text NOT NULL,
  siege     boolean NOT NULL DEFAULT false,
  actif     boolean NOT NULL DEFAULT true,
  cree_le   timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE utilisateur (
  id           serial PRIMARY KEY,
  agence_id    smallint REFERENCES agence(id),      -- NULL = siège (voit tout)
  login        varchar(60) NOT NULL UNIQUE,
  nom          text NOT NULL,
  role         role_utilisateur NOT NULL,
  actif        boolean NOT NULL DEFAULT true,
  cree_le      timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE collectrice (
  id         serial PRIMARY KEY,
  agence_id  smallint NOT NULL REFERENCES agence(id),
  matricule  varchar(20) NOT NULL,
  nom        text NOT NULL,
  actif      boolean NOT NULL DEFAULT true,
  UNIQUE (agence_id, matricule)
);

CREATE TABLE zone (
  id         serial PRIMARY KEY,
  agence_id  smallint NOT NULL REFERENCES agence(id),
  code       varchar(10) NOT NULL,
  libelle    text NOT NULL,
  UNIQUE (agence_id, code)
);

-- Agent commercial (celui qui collecte sur le terrain)
CREATE TABLE agent (
  id         serial PRIMARY KEY,
  agence_id  smallint NOT NULL REFERENCES agence(id),
  matricule  varchar(20) NOT NULL,
  nom        text NOT NULL,
  actif      boolean NOT NULL DEFAULT true,
  UNIQUE (agence_id, matricule)
);

-- Une zone a au plus une collectrice à une date donnée (pas de chevauchement).
CREATE TABLE affectation_zone (
  id             serial PRIMARY KEY,
  zone_id        integer NOT NULL REFERENCES zone(id),
  collectrice_id integer NOT NULL REFERENCES collectrice(id),
  date_debut     date NOT NULL,
  date_fin       date,                                   -- NULL = en cours
  CHECK (date_fin IS NULL OR date_fin >= date_debut),
  EXCLUDE USING gist (
    zone_id WITH =,
    daterange(date_debut, date_fin, '[]') WITH &&
  )
);

-- Paramètres : valeur globale (agence_id NULL) surchargeable par agence.
CREATE TABLE parametre (
  id         serial PRIMARY KEY,
  agence_id  smallint REFERENCES agence(id),
  cle        varchar(60) NOT NULL,
  valeur     text NOT NULL,
  description text
);
CREATE UNIQUE INDEX parametre_unique ON parametre (cle, COALESCE(agence_id, 0));

-- param(cle, agence) : valeur de l'agence si elle existe, sinon globale.
CREATE FUNCTION param(p_cle text, p_agence smallint DEFAULT NULL)
RETURNS text LANGUAGE sql STABLE AS $$
  SELECT valeur FROM mf.parametre
   WHERE cle = p_cle AND (agence_id = p_agence OR agence_id IS NULL)
   ORDER BY agence_id NULLS LAST
   LIMIT 1
$$;

CREATE FUNCTION param_num(p_cle text, p_agence smallint DEFAULT NULL)
RETURNS numeric LANGUAGE sql STABLE AS $$ SELECT mf.param(p_cle, p_agence)::numeric $$;

-- Valeurs par défaut (provisoires : à valider avec le client, voir brief P0.3)
INSERT INTO parametre(cle,valeur,description) VALUES
  ('arrondi_mode','plus_proche','Arrondi mise type 3 : plus_proche | superieur | inferieur'),
  ('arrondi_multiple','25','Multiple d''arrondi de la mise'),
  ('diviseur_type3','31','Diviseur de la mise finale type 3'),
  ('mode_cloture','calendaire_mensuel','calendaire_mensuel | date_fin_client'),
  ('taux_commission','0.02','PROVISOIRE : à fixer par le client'),
  ('plafond_retenue','0.5','Part max de la commission retenable pour solder le compte agent'),
  ('jours_saisie_garantie','30','Jours de retard avant saisie de la garantie'),
  ('points_a_temps','10','Points fidélité : échéance à temps (X)'),
  ('points_retard_par_tranche','2','Points perdus par tranche de retard (Y)'),
  ('jours_tranche_retard','5','Taille d''une tranche de retard en jours'),
  ('points_credit_solde','20','Points : crédit soldé sans retard (Z)'),
  ('penalite_taux','0.001','Pénalité de retard : part du capital de l''échéance par jour de retard (provisoire)'),
  ('penalite_plafond','0.10','Plafond de pénalité en part de l''échéance (provisoire)');

-- Journal d'audit (table seule ; les triggers sont à brancher, brief P2.4)
CREATE TABLE audit_log (
  id          bigserial PRIMARY KEY,
  horodatage  timestamptz NOT NULL DEFAULT now(),
  utilisateur text DEFAULT current_user,
  table_name  text NOT NULL,
  operation   text NOT NULL,
  ligne_id    text,
  avant       jsonb,
  apres       jsonb
);

-- =====================================================================
-- MODULE 01_epargne_collecte.sql
-- =====================================================================
-- =====================================================================
-- 01_epargne_collecte.sql
-- Clients, produits, comptes classiques et mouvements, cycles (types 1, 2, 3),
-- historique des mises, lignes de collecte (livret de 31 lignes par page),
-- arrondi, clôture, demande de retrait par cycle, production de collectrice.
-- Règles : BRIEF_CLAUDE_CODE.md sections 3.1 et 3.2.
-- Dépend de : 00_noyau.sql
-- Hors périmètre ici : exécution des retraits et écarts (02), crédit (03, 08),
-- virements (07). solde_disponible() est redéfinie en 08 pour déduire les garanties.
-- =====================================================================
SET search_path = mf, public;

-- ---------------------------------------------------------------------
-- Clients et produits
-- ---------------------------------------------------------------------
CREATE TABLE client (
  id         serial PRIMARY KEY,
  agence_id  smallint NOT NULL REFERENCES agence(id),
  zone_id    integer REFERENCES zone(id),
  numero     varchar(20) NOT NULL,
  nom        text NOT NULL,
  telephone  varchar(30),
  actif      boolean NOT NULL DEFAULT true,
  cree_le    timestamptz NOT NULL DEFAULT now(),
  UNIQUE (agence_id, numero)
);

-- categorie 'collecte' = tontine (cycles) ; 'classique' = épargne à vue / à terme
CREATE TABLE produit_epargne (
  id              serial PRIMARY KEY,
  code            varchar(10) NOT NULL UNIQUE,
  libelle         text NOT NULL,
  categorie       varchar(10) NOT NULL CHECK (categorie IN ('collecte','classique')),
  type_cycle      smallint CHECK (type_cycle IN (1,2,3)),
  nb_pages_livret smallint NOT NULL DEFAULT 1 CHECK (nb_pages_livret >= 1),
  taux_interet    numeric(7,5) NOT NULL DEFAULT 0,   -- annuel ; calcul des intérêts : brief P1.6
  solde_minimum   numeric(14,0) NOT NULL DEFAULT 0,
  actif           boolean NOT NULL DEFAULT true,
  CHECK ((categorie = 'collecte') = (type_cycle IS NOT NULL))
);

-- ---------------------------------------------------------------------
-- Épargne classique : comptes et mouvements
-- ---------------------------------------------------------------------
CREATE TABLE compte_epargne (
  id         serial PRIMARY KEY,
  agence_id  smallint NOT NULL REFERENCES agence(id),
  client_id  integer NOT NULL REFERENCES client(id),
  produit_id integer NOT NULL REFERENCES produit_epargne(id),
  numero     varchar(25) NOT NULL,
  ouvert_le  date NOT NULL DEFAULT current_date,
  statut     varchar(10) NOT NULL DEFAULT 'actif' CHECK (statut IN ('actif','bloque','clos')),
  UNIQUE (agence_id, numero)
);

-- Types élargis (varchar(25)). Si un type s'ajoute : mettre à jour ce CHECK,
-- les fonctions mf.sens_mouvement() et la vue v_solde_compte_epargne.
CREATE TABLE mouvement_epargne (
  id             bigserial PRIMARY KEY,
  compte_id      integer NOT NULL REFERENCES compte_epargne(id),
  type           varchar(25) NOT NULL CHECK (type IN
                   ('depot','virement_entrant','interet','deblocage_credit',
                    'retrait','virement_sortant','frais_dossier','prelevement_echeance','saisie_garantie')),
  montant        numeric(14,0) NOT NULL CHECK (montant > 0),
  date_operation date NOT NULL DEFAULT current_date,   -- date métier (et non cree_le)
  libelle        text,
  reference      text,
  cree_le        timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX mouvement_epargne_compte ON mouvement_epargne (compte_id, date_operation);

-- +1 entrée, -1 sortie
CREATE FUNCTION sens_mouvement(p_type text) RETURNS smallint
LANGUAGE sql IMMUTABLE AS $$
  SELECT CASE WHEN p_type IN ('depot','virement_entrant','interet','deblocage_credit') THEN 1 ELSE -1 END::smallint
$$;

CREATE VIEW v_solde_compte_epargne AS
SELECT c.id AS compte_id, c.agence_id, c.client_id, c.numero,
       COALESCE(sum(m.montant * mf.sens_mouvement(m.type)), 0)::numeric(14,0) AS solde
  FROM compte_epargne c
  LEFT JOIN mouvement_epargne m ON m.compte_id = c.id
 GROUP BY c.id;

-- Solde disponible = solde - solde minimum du produit (les garanties bloquées sont déduites en 08).
CREATE FUNCTION solde_disponible(p_compte integer) RETURNS numeric
LANGUAGE sql STABLE AS $$
  SELECT GREATEST(v.solde - p.solde_minimum, 0)
    FROM mf.v_solde_compte_epargne v
    JOIN mf.compte_epargne c ON c.id = v.compte_id
    JOIN mf.produit_epargne p ON p.id = c.produit_id
   WHERE v.compte_id = p_compte
$$;

-- Refuse toute sortie au-delà du disponible. Le verrou sur le compte sérialise
-- deux retraits simultanés.
CREATE FUNCTION trg_mouvement_controle() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE v_statut text; v_dispo numeric;
BEGIN
  SELECT statut INTO v_statut FROM mf.compte_epargne WHERE id = NEW.compte_id FOR UPDATE;
  IF v_statut IS DISTINCT FROM 'actif' THEN
    RAISE EXCEPTION 'compte % non actif (statut %)', NEW.compte_id, v_statut;
  END IF;
  IF mf.sens_mouvement(NEW.type) < 0 THEN
    v_dispo := mf.solde_disponible(NEW.compte_id);
    IF NEW.montant > v_dispo THEN
      RAISE EXCEPTION 'sortie de % refusée : solde disponible % (compte %)', NEW.montant, v_dispo, NEW.compte_id;
    END IF;
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER mouvement_controle BEFORE INSERT ON mouvement_epargne
  FOR EACH ROW EXECUTE FUNCTION trg_mouvement_controle();

-- ---------------------------------------------------------------------
-- Cycles de collecte
-- ---------------------------------------------------------------------
CREATE TABLE cycle (
  id                serial PRIMARY KEY,
  agence_id         smallint NOT NULL REFERENCES agence(id),
  numero            varchar(25) NOT NULL,
  client_id         integer NOT NULL REFERENCES client(id),
  produit_id        integer NOT NULL REFERENCES produit_epargne(id),
  type_cycle        smallint NOT NULL CHECK (type_cycle IN (1,2,3)),
  mise_initiale     numeric(12,0) NOT NULL CHECK (mise_initiale > 0),
  mise_courante     numeric(12,0) NOT NULL CHECK (mise_courante > 0),
  mise_finale       numeric(12,0),                       -- fixée à la clôture
  objectif          numeric(14,0),                       -- types 1 et 2
  nb_lignes_prevues smallint,                            -- défaut : 31 x pages du produit
  date_debut        date NOT NULL,
  date_fin          date NOT NULL,
  statut            varchar(10) NOT NULL DEFAULT 'en_cours' CHECK (statut IN ('en_cours','clos','retire')),
  date_cloture      date,
  cree_le           timestamptz NOT NULL DEFAULT now(),
  CHECK (date_fin >= date_debut),
  UNIQUE (agence_id, numero)
);
CREATE INDEX cycle_client ON cycle (client_id);
CREATE INDEX cycle_statut_fin ON cycle (agence_id, statut, date_fin);

-- Historique des mises : une ligne par changement (la première = mise initiale).
CREATE TABLE cycle_mise_historique (
  cycle_id   integer NOT NULL REFERENCES cycle(id),
  date_effet date NOT NULL,
  mise       numeric(12,0) NOT NULL CHECK (mise > 0),
  motif      text,
  cree_le    timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (cycle_id, date_effet)
);

CREATE FUNCTION trg_cycle_avant() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE p mf.produit_epargne; c mf.client;
BEGIN
  SELECT * INTO p FROM mf.produit_epargne WHERE id = NEW.produit_id;
  IF p.categorie <> 'collecte' THEN
    RAISE EXCEPTION 'le produit % n''est pas un produit de collecte', p.code;
  END IF;
  IF NEW.type_cycle <> p.type_cycle THEN
    RAISE EXCEPTION 'type de cycle % incompatible avec le produit % (type %)', NEW.type_cycle, p.code, p.type_cycle;
  END IF;
  SELECT * INTO c FROM mf.client WHERE id = NEW.client_id;
  IF c.agence_id <> NEW.agence_id THEN
    RAISE EXCEPTION 'le client % n''appartient pas à l''agence %', c.numero, NEW.agence_id;
  END IF;
  IF NEW.nb_lignes_prevues IS NULL THEN NEW.nb_lignes_prevues := 31 * p.nb_pages_livret; END IF;
  IF NEW.mise_courante IS NULL THEN NEW.mise_courante := NEW.mise_initiale; END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER cycle_avant BEFORE INSERT ON cycle FOR EACH ROW EXECUTE FUNCTION trg_cycle_avant();

CREATE FUNCTION trg_cycle_apres() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  INSERT INTO mf.cycle_mise_historique(cycle_id, date_effet, mise, motif)
  VALUES (NEW.id, NEW.date_debut, NEW.mise_initiale, 'mise initiale');
  RETURN NEW;
END $$;
CREATE TRIGGER cycle_apres AFTER INSERT ON cycle FOR EACH ROW EXECUTE FUNCTION trg_cycle_apres();

-- Mise en vigueur à une date donnée (dernier changement <= date).
CREATE FUNCTION mise_a_date(p_cycle integer, p_date date) RETURNS numeric
LANGUAGE sql STABLE AS $$
  SELECT mise FROM mf.cycle_mise_historique
   WHERE cycle_id = p_cycle AND date_effet <= p_date
   ORDER BY date_effet DESC LIMIT 1
$$;

-- Hausse ou baisse de mise : n'affecte que les lignes à venir (types 1 et 2).
CREATE FUNCTION changer_mise(p_cycle integer, p_mise numeric, p_date date DEFAULT current_date, p_motif text DEFAULT NULL)
RETURNS void LANGUAGE plpgsql AS $$
DECLARE c mf.cycle;
BEGIN
  SELECT * INTO c FROM mf.cycle WHERE id = p_cycle FOR UPDATE;
  IF c.statut <> 'en_cours' THEN RAISE EXCEPTION 'cycle % non en cours', c.numero; END IF;
  IF c.type_cycle = 3 THEN RAISE EXCEPTION 'pas de changement de mise sur un cycle de type 3'; END IF;
  IF p_mise <= 0 THEN RAISE EXCEPTION 'mise invalide'; END IF;
  IF EXISTS (SELECT 1 FROM mf.ligne_collecte WHERE cycle_id = p_cycle AND date_collecte >= p_date) THEN
    RAISE EXCEPTION 'des lignes existent déjà à partir du % : le changement fausserait le passé', p_date;
  END IF;
  INSERT INTO mf.cycle_mise_historique(cycle_id, date_effet, mise, motif)
  VALUES (p_cycle, p_date, p_mise, p_motif)
  ON CONFLICT (cycle_id, date_effet) DO UPDATE SET mise = EXCLUDED.mise, motif = EXCLUDED.motif;
  UPDATE mf.cycle SET mise_courante = p_mise WHERE id = p_cycle;
END $$;

-- ---------------------------------------------------------------------
-- Lignes de collecte (livret : 31 lignes par page)
-- ---------------------------------------------------------------------
CREATE TABLE ligne_collecte (
  id               bigserial PRIMARY KEY,
  cycle_id         integer NOT NULL REFERENCES cycle(id),
  page             smallint NOT NULL CHECK (page >= 1),
  no_ligne         smallint NOT NULL CHECK (no_ligne BETWEEN 1 AND 31),
  date_collecte    date NOT NULL,
  agent_id         integer REFERENCES agent(id),         -- celui qui a collecté (pertes et surplus lui sont imputés)
  origine          varchar(10) NOT NULL DEFAULT 'collecte' CHECK (origine IN ('collecte','virement')),
  montant_collecte numeric(12,0) NOT NULL CHECK (montant_collecte > 0),
  mise_appliquee   numeric(12,0),                        -- mise en vigueur à la date de la ligne
  cree_le          timestamptz NOT NULL DEFAULT now(),
  UNIQUE (cycle_id, page, no_ligne),
  CHECK (origine <> 'collecte' OR agent_id IS NOT NULL)
);
CREATE INDEX ligne_collecte_date ON ligne_collecte (date_collecte);
CREATE INDEX ligne_collecte_agent ON ligne_collecte (agent_id, date_collecte);

CREATE FUNCTION trg_ligne_avant() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE c mf.cycle; v_pages smallint;
BEGIN
  SELECT * INTO c FROM mf.cycle WHERE id = NEW.cycle_id FOR UPDATE;   -- sérialise les saisies d'un même cycle
  IF c.statut <> 'en_cours' THEN
    RAISE EXCEPTION 'cycle % clos : saisie refusée', c.numero;
  END IF;
  SELECT nb_pages_livret INTO v_pages FROM mf.produit_epargne WHERE id = c.produit_id;
  IF NEW.page > v_pages THEN
    RAISE EXCEPTION 'page % au-delà du livret (% page(s))', NEW.page, v_pages;
  END IF;
  IF NEW.date_collecte < c.date_debut THEN
    RAISE EXCEPTION 'date de collecte % antérieure au début du cycle (%)', NEW.date_collecte, c.date_debut;
  END IF;
  IF NEW.agent_id IS NOT NULL AND NOT EXISTS
     (SELECT 1 FROM mf.agent WHERE id = NEW.agent_id AND agence_id = c.agence_id) THEN
    RAISE EXCEPTION 'agent % hors de l''agence du cycle', NEW.agent_id;
  END IF;
  IF NEW.mise_appliquee IS NULL THEN
    NEW.mise_appliquee := mf.mise_a_date(NEW.cycle_id, NEW.date_collecte);
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER ligne_avant BEFORE INSERT ON ligne_collecte FOR EACH ROW EXECUTE FUNCTION trg_ligne_avant();

-- Situation d'un cycle. Prévisionnel = mises déjà appliquées + lignes restantes x mise courante.
-- net = collecté - mise du cycle. Types 3 : pas de prévisionnel (collecte aléatoire).
CREATE VIEW v_cycle_situation AS
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
       COALESCE(l.total, 0) - COALESCE(c.mise_finale, c.mise_courante) AS net
  FROM cycle c
  LEFT JOIN (SELECT cycle_id, count(*) nb, sum(montant_collecte) total, sum(mise_appliquee) mises
               FROM ligne_collecte GROUP BY cycle_id) l ON l.cycle_id = c.id;

-- ---------------------------------------------------------------------
-- Arrondi paramétrable (arrondi_mode, arrondi_multiple ; défaut plus proche, 25)
-- ---------------------------------------------------------------------
CREATE FUNCTION arrondir(p_montant numeric, p_agence smallint DEFAULT NULL) RETURNS numeric
LANGUAGE plpgsql STABLE AS $$
DECLARE v_mode text := mf.param('arrondi_mode', p_agence);
        v_mult numeric := mf.param_num('arrondi_multiple', p_agence);
BEGIN
  IF v_mult IS NULL OR v_mult <= 0 THEN RETURN round(p_montant); END IF;
  RETURN CASE v_mode
    WHEN 'superieur' THEN ceil(p_montant / v_mult) * v_mult
    WHEN 'inferieur' THEN floor(p_montant / v_mult) * v_mult
    ELSE round(p_montant / v_mult) * v_mult
  END;
END $$;

-- ---------------------------------------------------------------------
-- Clôture
-- Type 1 : objectif atteint ou date de fin. Types 2 et 3 : date de fin.
-- Type 3 : mise_finale = max(arrondi(total / diviseur_type3), mise_initiale).
-- ---------------------------------------------------------------------
CREATE FUNCTION cloturer_cycle(p_cycle integer, p_date date DEFAULT current_date) RETURNS numeric
LANGUAGE plpgsql AS $$
DECLARE c mf.cycle; v_total numeric; v_mise numeric;
BEGIN
  SELECT * INTO c FROM mf.cycle WHERE id = p_cycle FOR UPDATE;
  IF c.statut <> 'en_cours' THEN RAISE EXCEPTION 'cycle % déjà clos', c.numero; END IF;
  SELECT COALESCE(sum(montant_collecte), 0) INTO v_total FROM mf.ligne_collecte WHERE cycle_id = p_cycle;
  IF c.type_cycle = 3 THEN
    v_mise := GREATEST(mf.arrondir(v_total / mf.param_num('diviseur_type3', c.agence_id), c.agence_id), c.mise_initiale);
  ELSE
    v_mise := c.mise_courante;
  END IF;
  UPDATE mf.cycle SET statut = 'clos', date_cloture = p_date, mise_finale = v_mise WHERE id = p_cycle;
  RETURN v_mise;
END $$;

-- Tâche planifiée : à lancer par agence et par jour (fin de mois en mode calendaire).
CREATE FUNCTION cloturer_cycles_echus(p_agence smallint, p_date date DEFAULT current_date) RETURNS integer
LANGUAGE plpgsql AS $$
DECLARE r record; n integer := 0;
BEGIN
  FOR r IN
    SELECT c.id
      FROM mf.cycle c
      LEFT JOIN mf.v_cycle_situation s ON s.cycle_id = c.id
     WHERE c.agence_id = p_agence AND c.statut = 'en_cours'
       AND ( c.date_fin <= p_date
          OR (c.type_cycle = 1 AND (s.montant_collecte >= c.objectif OR s.nb_lignes >= c.nb_lignes_prevues)) )
     ORDER BY c.id
  LOOP
    PERFORM mf.cloturer_cycle(r.id, p_date);
    n := n + 1;
  END LOOP;
  RETURN n;
END $$;

-- ---------------------------------------------------------------------
-- Retrait par cycle (structure). L'exécution et les écarts sont en 02.
-- natures : retrait_client | virement_vers_epargne | remboursement
-- statuts : demande -> ecart_en_traitement -> fonds_disponibles -> execute
-- ---------------------------------------------------------------------
CREATE TABLE retrait (
  id             serial PRIMARY KEY,
  agence_id      smallint NOT NULL REFERENCES agence(id),
  cycle_id       integer NOT NULL REFERENCES cycle(id),
  nature         varchar(25) NOT NULL DEFAULT 'retrait_client'
                 CHECK (nature IN ('retrait_client','virement_vers_epargne','remboursement','regularisation')),
  montant        numeric(14,0) NOT NULL CHECK (montant >= 0),   -- net selon la machine : collecté - mise
  decaissement   boolean NOT NULL,                              -- faux : pas de sortie de caisse
  statut         varchar(25) NOT NULL DEFAULT 'demande'
                 CHECK (statut IN ('demande','ecart_en_traitement','fonds_disponibles','execute','annule')),
  date_demande   date NOT NULL DEFAULT current_date,
  date_operation date,                                          -- date métier d'exécution
  execute_le     timestamptz,
  cree_le        timestamptz NOT NULL DEFAULT now()
);
-- un seul retrait de solde (client ou virement) actif par cycle ; les remboursements de crédit
-- (plusieurs par cycle) et la régularisation d'excédent ne sont pas concernés.
CREATE UNIQUE INDEX retrait_un_actif_par_cycle ON retrait (cycle_id)
  WHERE statut <> 'annule' AND nature IN ('retrait_client','virement_vers_epargne');

-- Crée la demande de retrait d'un cycle. Si le cycle est encore en cours, il est clôturé
-- à cette date (retrait anticipé). Montant = collecté - mise du cycle (net machine).
CREATE FUNCTION demander_retrait_cycle(p_cycle integer, p_nature text DEFAULT 'retrait_client',
                                        p_date date DEFAULT current_date) RETURNS integer
LANGUAGE plpgsql AS $$
DECLARE c mf.cycle; v_net numeric; v_id integer;
BEGIN
  SELECT * INTO c FROM mf.cycle WHERE id = p_cycle FOR UPDATE;
  IF c.statut = 'retire' THEN RAISE EXCEPTION 'cycle % déjà retiré', c.numero; END IF;
  IF c.statut = 'en_cours' THEN PERFORM mf.cloturer_cycle(p_cycle, p_date); END IF;
  SELECT net INTO v_net FROM mf.v_cycle_situation WHERE cycle_id = p_cycle;
  INSERT INTO mf.retrait(agence_id, cycle_id, nature, montant, decaissement, date_demande)
  VALUES (c.agence_id, p_cycle, p_nature, GREATEST(v_net, 0), p_nature = 'retrait_client', p_date)
  RETURNING id INTO v_id;
  RETURN v_id;
END $$;

-- ---------------------------------------------------------------------
-- Production d'une collectrice sur [du, au] (base de la commission, calculée en 04).
-- Production d'une ligne = sa mise appliquée (types 1 et 2) ou le montant collecté (type 3,
-- pas de mise cible). Seules les lignes de collecte comptent : les lignes de virement n'ont pas d'agent.
-- calendaire_mensuel : cycles clôturés dans la période, attribués à la collectrice de la zone
--                      à la date de clôture.
-- date_fin_client    : lignes collectées dans la période, attribuées à la collectrice de la zone
--                      à la date de la ligne.
-- ---------------------------------------------------------------------
CREATE FUNCTION production_collectrice(p_collectrice integer, p_du date, p_au date) RETURNS numeric
LANGUAGE plpgsql STABLE AS $$
DECLARE v_agence smallint; v_mode text; v_prod numeric;
BEGIN
  SELECT agence_id INTO v_agence FROM mf.collectrice WHERE id = p_collectrice;
  v_mode := mf.param('mode_cloture', v_agence);
  IF v_mode = 'date_fin_client' THEN
    SELECT COALESCE(sum(CASE WHEN c.type_cycle = 3 THEN l.montant_collecte ELSE l.mise_appliquee END), 0)
      INTO v_prod
      FROM mf.ligne_collecte l
      JOIN mf.cycle c   ON c.id = l.cycle_id
      JOIN mf.client cl ON cl.id = c.client_id
      JOIN mf.affectation_zone a ON a.zone_id = cl.zone_id AND a.collectrice_id = p_collectrice
           AND l.date_collecte >= a.date_debut AND (a.date_fin IS NULL OR l.date_collecte <= a.date_fin)
     WHERE l.origine = 'collecte' AND l.date_collecte BETWEEN p_du AND p_au;
  ELSE
    SELECT COALESCE(sum(CASE WHEN c.type_cycle = 3 THEN l.montant_collecte ELSE l.mise_appliquee END), 0)
      INTO v_prod
      FROM mf.cycle c
      JOIN mf.ligne_collecte l ON l.cycle_id = c.id AND l.origine = 'collecte'
      JOIN mf.client cl ON cl.id = c.client_id
      JOIN mf.affectation_zone a ON a.zone_id = cl.zone_id AND a.collectrice_id = p_collectrice
           AND c.date_cloture >= a.date_debut AND (a.date_fin IS NULL OR c.date_cloture <= a.date_fin)
     WHERE c.statut IN ('clos','retire') AND c.date_cloture BETWEEN p_du AND p_au;
  END IF;
  RETURN v_prod;
END $$;

-- =====================================================================
-- MODULE 02_ecarts.sql
-- =====================================================================
-- =====================================================================
-- 02_ecarts.sql
-- Compte agent, versements de fin de tournée, surplus, écarts de retrait
-- (livret > machine, machine > livret), excédents à régulariser, purge de date,
-- constat / traitement / exécution des retraits.
-- Règles : BRIEF_CLAUDE_CODE.md section 3.3 (et 3.5 pour le circuit de retrait).
-- Dépend de : 00, 01.  L'exécution d'un retrait appelle, au besoin, des fonctions
-- définies plus loin (liaison tardive plpgsql) : exec_remboursement (03),
-- exec_virement_vers_epargne (07), caisse_operation (03).
-- =====================================================================
SET search_path = mf, public;

-- Le retrait porte le montant selon le livret et le montant réellement payé.
ALTER TABLE retrait
  ADD COLUMN montant_livret numeric(14,0),                   -- net selon le livret = montant + ecart
  ADD COLUMN montant_paye   numeric(14,0),                   -- net réellement payé / crédité
  ADD COLUMN ecart          numeric(14,0) NOT NULL DEFAULT 0; -- livret - machine (signé)

-- ---------------------------------------------------------------------
-- Compte de l'agent : manquants et pertes (débit), versements et retenues (crédit)
-- ---------------------------------------------------------------------
CREATE TABLE compte_agent (
  id             bigserial PRIMARY KEY,
  agence_id      smallint NOT NULL REFERENCES agence(id),
  agent_id       integer NOT NULL REFERENCES agent(id),
  type           varchar(30) NOT NULL CHECK (type IN
                   ('manquant_versement','perte_retrait','correction_debit',
                    'versement','retenue_commission','correction_credit')),
  montant        numeric(14,0) NOT NULL CHECK (montant > 0),
  date_operation date NOT NULL,
  libelle        text,
  reference      text,
  cree_le        timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX compte_agent_agent ON compte_agent (agent_id, date_operation);

-- +1 crédit (réduit la dette), -1 débit (la creuse)
CREATE FUNCTION sens_compte_agent(p_type text) RETURNS smallint
LANGUAGE sql IMMUTABLE AS $$
  SELECT CASE WHEN p_type IN ('manquant_versement','perte_retrait','correction_debit') THEN -1 ELSE 1 END::smallint
$$;

-- solde < 0 : l'agent doit de l'argent à l'institution
CREATE VIEW v_solde_compte_agent AS
SELECT a.id AS agent_id, a.agence_id, a.matricule, a.nom,
       COALESCE(sum(c.montant * mf.sens_compte_agent(c.type)), 0)::numeric(14,0) AS solde
  FROM agent a LEFT JOIN compte_agent c ON c.agent_id = a.id
 GROUP BY a.id;

-- ---------------------------------------------------------------------
-- Versements de fin de tournée et surplus
-- ---------------------------------------------------------------------
CREATE TABLE versement_agent (
  id               serial PRIMARY KEY,
  agence_id        smallint NOT NULL REFERENCES agence(id),
  agent_id         integer NOT NULL REFERENCES agent(id),
  date_tournee     date NOT NULL,
  montant_collecte numeric(14,0) NOT NULL,       -- saisie du jour
  montant_verse    numeric(14,0) NOT NULL CHECK (montant_verse >= 0),
  ecart            numeric(14,0) NOT NULL,       -- collecté - versé (> 0 : manquant)
  utilisateur_id   integer REFERENCES utilisateur(id),
  cree_le          timestamptz NOT NULL DEFAULT now(),
  UNIQUE (agent_id, date_tournee)
);

CREATE TABLE surplus (
  id              serial PRIMARY KEY,
  agence_id       smallint NOT NULL REFERENCES agence(id),
  agent_id        integer NOT NULL REFERENCES agent(id),
  date_surplus    date NOT NULL,
  montant         numeric(14,0) NOT NULL CHECK (montant > 0),
  montant_utilise numeric(14,0) NOT NULL DEFAULT 0,
  origine         varchar(15) NOT NULL CHECK (origine IN ('versement','regularisation')),
  statut          varchar(10) NOT NULL DEFAULT 'a_traiter' CHECK (statut IN ('a_traiter','solde')),
  reference       text,
  cree_le         timestamptz NOT NULL DEFAULT now(),
  CHECK (montant_utilise BETWEEN 0 AND montant)
);
CREATE INDEX surplus_agent_date ON surplus (agent_id, date_surplus);

-- Un surplus reste bloqué tant qu'un cycle lié à sa date n'est pas retiré.
CREATE VIEW v_surplus AS
SELECT s.*, s.montant - s.montant_utilise AS restant,
       EXISTS (SELECT 1 FROM mf.ligne_collecte l JOIN mf.cycle c ON c.id = l.cycle_id
                WHERE c.agence_id = s.agence_id AND l.date_collecte = s.date_surplus
                  AND l.origine = 'collecte' AND c.statut <> 'retire') AS bloque
  FROM surplus s;

-- Écart de versement = collecté (lignes saisies pour l'agent ce jour-là) - versé.
-- Manquant : débit du compte de l'agent. Surplus : table surplus, statut « à traiter ».
CREATE FUNCTION enregistrer_versement(p_agent integer, p_date date, p_verse numeric,
                                      p_utilisateur integer DEFAULT NULL) RETURNS integer
LANGUAGE plpgsql AS $$
DECLARE a mf.agent; v_coll numeric; v_ecart numeric; v_id integer;
BEGIN
  SELECT * INTO a FROM mf.agent WHERE id = p_agent FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'agent % inconnu', p_agent; END IF;
  SELECT COALESCE(sum(montant_collecte), 0) INTO v_coll
    FROM mf.ligne_collecte WHERE agent_id = p_agent AND date_collecte = p_date AND origine = 'collecte';
  v_ecart := v_coll - p_verse;
  INSERT INTO mf.versement_agent(agence_id, agent_id, date_tournee, montant_collecte, montant_verse, ecart, utilisateur_id)
  VALUES (a.agence_id, p_agent, p_date, v_coll, p_verse, v_ecart, p_utilisateur) RETURNING id INTO v_id;
  IF v_ecart > 0 THEN
    INSERT INTO mf.compte_agent(agence_id, agent_id, type, montant, date_operation, libelle, reference)
    VALUES (a.agence_id, p_agent, 'manquant_versement', v_ecart, p_date, 'Manquant à la tournée du ' || p_date, 'versement_agent:' || v_id);
  ELSIF v_ecart < 0 THEN
    INSERT INTO mf.surplus(agence_id, agent_id, date_surplus, montant, origine, reference)
    VALUES (a.agence_id, p_agent, p_date, -v_ecart, 'versement', 'versement_agent:' || v_id);
  END IF;
  RETURN v_id;
END $$;

-- Solder le compte de l'agent par versement.
CREATE FUNCTION regler_compte_agent(p_agent integer, p_montant numeric, p_date date DEFAULT current_date,
                                    p_libelle text DEFAULT 'Règlement par versement') RETURNS void
LANGUAGE plpgsql AS $$
DECLARE a mf.agent;
BEGIN
  SELECT * INTO a FROM mf.agent WHERE id = p_agent FOR UPDATE;
  IF p_montant <= 0 THEN RAISE EXCEPTION 'montant invalide'; END IF;
  INSERT INTO mf.compte_agent(agence_id, agent_id, type, montant, date_operation, libelle)
  VALUES (a.agence_id, p_agent, 'versement', p_montant, p_date, p_libelle);
END $$;

-- Retenue sur commission, plafonnée à plafond_retenue x commission. Retourne le montant retenu.
CREATE FUNCTION retenue_sur_commission(p_agent integer, p_commission numeric, p_date date DEFAULT current_date)
RETURNS numeric LANGUAGE plpgsql AS $$
DECLARE a mf.agent; v_dette numeric; v_plafond numeric; v_ret numeric;
BEGIN
  SELECT * INTO a FROM mf.agent WHERE id = p_agent FOR UPDATE;
  SELECT GREATEST(-solde, 0) INTO v_dette FROM mf.v_solde_compte_agent WHERE agent_id = p_agent;
  v_plafond := floor(p_commission * mf.param_num('plafond_retenue', a.agence_id));
  v_ret := GREATEST(LEAST(v_dette, v_plafond), 0);
  IF v_ret > 0 THEN
    INSERT INTO mf.compte_agent(agence_id, agent_id, type, montant, date_operation, libelle)
    VALUES (a.agence_id, p_agent, 'retenue_commission', v_ret, p_date, 'Retenue sur commission');
  END IF;
  RETURN v_ret;
END $$;

-- ---------------------------------------------------------------------
-- Écarts de retrait
-- livret > machine : le client est payé selon le livret ; l'écart est rattaché à des dates ;
--                    surplus de la date exacte d'abord, le reste est une perte de l'agent.
-- machine > livret : pas un surplus réel : excédent « à régulariser » + retrait de
--                    régularisation sans décaissement ; devient surplus à la purge de la date.
-- ---------------------------------------------------------------------
CREATE TABLE ecart_retrait (
  id              serial PRIMARY KEY,
  agence_id       smallint NOT NULL REFERENCES agence(id),
  retrait_id      integer NOT NULL REFERENCES retrait(id),
  cycle_id        integer NOT NULL REFERENCES cycle(id),
  sens            varchar(12) NOT NULL CHECK (sens IN ('livret_sup','machine_sup')),
  montant_livret  numeric(14,0) NOT NULL,
  montant_machine numeric(14,0) NOT NULL,
  montant         numeric(14,0) NOT NULL CHECK (montant > 0),
  statut          varchar(10) NOT NULL DEFAULT 'a_traiter' CHECK (statut IN ('a_traiter','traite')),
  traite_le       date,
  cree_le         timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX ecart_retrait_cycle ON ecart_retrait (cycle_id);

CREATE TABLE ecart_retrait_date (
  id              serial PRIMARY KEY,
  ecart_id        integer NOT NULL REFERENCES ecart_retrait(id),
  date_ecart      date NOT NULL,
  agent_id        integer NOT NULL REFERENCES agent(id),
  montant         numeric(14,0) NOT NULL CHECK (montant > 0),
  surplus_utilise numeric(14,0) NOT NULL DEFAULT 0,
  perte           numeric(14,0) NOT NULL DEFAULT 0
);

CREATE TABLE excedent_regularisation (
  id          serial PRIMARY KEY,
  agence_id   smallint NOT NULL REFERENCES agence(id),
  cycle_id    integer NOT NULL REFERENCES cycle(id),
  retrait_id  integer NOT NULL REFERENCES retrait(id),   -- le retrait de régularisation
  date_ligne  date NOT NULL,
  agent_id    integer NOT NULL REFERENCES agent(id),
  montant     numeric(14,0) NOT NULL CHECK (montant > 0),
  statut      varchar(15) NOT NULL DEFAULT 'a_regulariser' CHECK (statut IN ('a_regulariser','regularise')),
  surplus_id  integer REFERENCES surplus(id),
  cree_le     timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE date_purgee (
  agence_id  smallint NOT NULL REFERENCES agence(id),
  date_purge date NOT NULL,
  purge_le   timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (agence_id, date_purge)
);

-- Retrait sans écart : livret = machine.
CREATE FUNCTION constater_sans_ecart(p_retrait integer) RETURNS void
LANGUAGE plpgsql AS $$
DECLARE r mf.retrait;
BEGIN
  SELECT * INTO r FROM mf.retrait WHERE id = p_retrait FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'retrait % inconnu', p_retrait; END IF;
  IF r.statut <> 'demande' THEN RAISE EXCEPTION 'retrait % déjà constaté (statut %)', p_retrait, r.statut; END IF;
  UPDATE mf.retrait SET montant_livret = montant, ecart = 0, statut = 'fonds_disponibles' WHERE id = p_retrait;
END $$;

-- p_details : [{"date":"2026-10-03","montant":500,"agent_id":1}, ...] ; la somme = |livret - machine|.
-- agent_id facultatif : par défaut, l'agent qui a collecté ce jour-là sur le cycle.
CREATE FUNCTION enregistrer_ecart_retrait(p_retrait integer, p_livret numeric, p_machine numeric,
                                          p_details jsonb) RETURNS integer
LANGUAGE plpgsql AS $$
DECLARE r mf.retrait; v_coll numeric; v_ecart numeric; v_sum numeric := 0; v_id integer;
        d jsonb; v_date date; v_mt numeric; v_agent integer; v_regul integer;
BEGIN
  SELECT * INTO r FROM mf.retrait WHERE id = p_retrait FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'retrait % inconnu', p_retrait; END IF;
  IF r.statut <> 'demande' THEN RAISE EXCEPTION 'retrait % déjà constaté (statut %)', p_retrait, r.statut; END IF;
  IF r.nature = 'regularisation' THEN RAISE EXCEPTION 'un retrait de régularisation n''a pas d''écart'; END IF;
  SELECT montant_collecte INTO v_coll FROM mf.v_cycle_situation WHERE cycle_id = r.cycle_id;
  IF p_machine <> v_coll THEN
    RAISE EXCEPTION 'montant machine % différent du collecté du cycle (%)', p_machine, v_coll;
  END IF;
  v_ecart := p_livret - p_machine;
  IF v_ecart = 0 THEN RAISE EXCEPTION 'aucun écart : utiliser constater_sans_ecart'; END IF;
  IF p_details IS NULL OR jsonb_typeof(p_details) <> 'array' OR jsonb_array_length(p_details) = 0 THEN
    RAISE EXCEPTION 'l''écart doit être rattaché à au moins une date';
  END IF;

  INSERT INTO mf.ecart_retrait(agence_id, retrait_id, cycle_id, sens, montant_livret, montant_machine, montant, statut)
  VALUES (r.agence_id, p_retrait, r.cycle_id,
          CASE WHEN v_ecart > 0 THEN 'livret_sup' ELSE 'machine_sup' END,
          p_livret, p_machine, abs(v_ecart), CASE WHEN v_ecart > 0 THEN 'a_traiter' ELSE 'traite' END)
  RETURNING id INTO v_id;

  IF v_ecart < 0 THEN
    -- retrait de régularisation : sans décaissement, déjà exécuté
    INSERT INTO mf.retrait(agence_id, cycle_id, nature, montant, decaissement, statut, date_demande,
                           date_operation, execute_le, montant_paye)
    VALUES (r.agence_id, r.cycle_id, 'regularisation', abs(v_ecart), false, 'execute', r.date_demande,
            r.date_demande, now(), 0)
    RETURNING id INTO v_regul;
  END IF;

  FOR d IN SELECT * FROM jsonb_array_elements(p_details) LOOP
    v_date := (d->>'date')::date;
    v_mt   := (d->>'montant')::numeric;
    IF v_date IS NULL OR v_mt IS NULL OR v_mt <= 0 THEN RAISE EXCEPTION 'détail d''écart invalide : %', d; END IF;
    v_agent := COALESCE((d->>'agent_id')::integer,
                        (SELECT agent_id FROM mf.ligne_collecte
                          WHERE cycle_id = r.cycle_id AND date_collecte = v_date AND origine = 'collecte'
                          ORDER BY id LIMIT 1));
    IF v_agent IS NULL OR NOT EXISTS (SELECT 1 FROM mf.ligne_collecte
                                       WHERE cycle_id = r.cycle_id AND date_collecte = v_date
                                         AND origine = 'collecte' AND agent_id = v_agent) THEN
      RAISE EXCEPTION 'aucune collecte de l''agent % sur le cycle à la date %', v_agent, v_date;
    END IF;
    INSERT INTO mf.ecart_retrait_date(ecart_id, date_ecart, agent_id, montant) VALUES (v_id, v_date, v_agent, v_mt);
    IF v_ecart < 0 THEN
      INSERT INTO mf.excedent_regularisation(agence_id, cycle_id, retrait_id, date_ligne, agent_id, montant)
      VALUES (r.agence_id, r.cycle_id, v_regul, v_date, v_agent, v_mt);
    END IF;
    v_sum := v_sum + v_mt;
  END LOOP;
  IF v_sum <> abs(v_ecart) THEN
    RAISE EXCEPTION 'la somme des dates (%) ne correspond pas à l''écart (%)', v_sum, abs(v_ecart);
  END IF;

  UPDATE mf.retrait
     SET montant_livret = montant + v_ecart, ecart = v_ecart,
         statut = CASE WHEN v_ecart > 0 THEN 'ecart_en_traitement' ELSE 'fonds_disponibles' END
   WHERE id = p_retrait;
  RETURN v_id;
END $$;

-- Traitement d'un écart livret > machine, date par date. Retourne la perte totale imputée aux agents.
CREATE FUNCTION traiter_ecart_retrait(p_ecart integer, p_date date DEFAULT NULL) RETURNS numeric
LANGUAGE plpgsql AS $$
DECLARE e mf.ecart_retrait; r mf.retrait; d record; s record; v_date date;
        v_reste numeric; v_util numeric; v_use numeric; v_perte numeric := 0;
BEGIN
  SELECT * INTO e FROM mf.ecart_retrait WHERE id = p_ecart FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'écart % inconnu', p_ecart; END IF;
  IF e.statut = 'traite' THEN RAISE EXCEPTION 'écart % déjà traité', p_ecart; END IF;
  SELECT * INTO r FROM mf.retrait WHERE id = e.retrait_id FOR UPDATE;
  v_date := COALESCE(p_date, r.date_demande);

  FOR d IN SELECT * FROM mf.ecart_retrait_date WHERE ecart_id = p_ecart ORDER BY date_ecart, id LOOP
    v_reste := d.montant; v_util := 0;
    FOR s IN SELECT * FROM mf.surplus
              WHERE agent_id = d.agent_id AND date_surplus = d.date_ecart AND statut = 'a_traiter'
              ORDER BY id FOR UPDATE LOOP
      EXIT WHEN v_reste <= 0;
      v_use := LEAST(v_reste, s.montant - s.montant_utilise);
      UPDATE mf.surplus
         SET montant_utilise = montant_utilise + v_use,
             statut = CASE WHEN montant_utilise + v_use = montant THEN 'solde' ELSE statut END
       WHERE id = s.id;
      v_reste := v_reste - v_use; v_util := v_util + v_use;
    END LOOP;
    IF v_reste > 0 THEN
      INSERT INTO mf.compte_agent(agence_id, agent_id, type, montant, date_operation, libelle, reference)
      VALUES (e.agence_id, d.agent_id, 'perte_retrait', v_reste, v_date,
              'Perte sur retrait, collecte du ' || d.date_ecart, 'ecart_retrait:' || p_ecart);
    END IF;
    UPDATE mf.ecart_retrait_date SET surplus_utilise = v_util, perte = v_reste WHERE id = d.id;
    v_perte := v_perte + v_reste;
  END LOOP;

  UPDATE mf.ecart_retrait SET statut = 'traite', traite_le = v_date WHERE id = p_ecart;
  UPDATE mf.retrait SET statut = 'fonds_disponibles' WHERE id = e.retrait_id;
  RETURN v_perte;
END $$;

-- Exécution : exige un retrait « fonds_disponibles » (donc constaté, écarts traités).
-- Le client est payé selon le livret. Un remboursement de crédit est imputé sur la date d'atteinte du seuil.
CREATE FUNCTION executer_retrait(p_retrait integer, p_date date DEFAULT NULL, p_session integer DEFAULT NULL)
RETURNS void LANGUAGE plpgsql AS $$
DECLARE r mf.retrait; v_date date; v_paye numeric;
BEGIN
  SELECT * INTO r FROM mf.retrait WHERE id = p_retrait FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'retrait % inconnu', p_retrait; END IF;
  IF r.statut <> 'fonds_disponibles' THEN
    RAISE EXCEPTION 'retrait % non exécutable (statut %) : constater ou traiter les écarts d''abord', p_retrait, r.statut;
  END IF;
  v_date := COALESCE(p_date, r.date_demande);
  v_paye := CASE WHEN r.nature = 'remboursement' THEN r.montant ELSE r.montant + r.ecart END;
  IF v_paye < 0 THEN RAISE EXCEPTION 'montant à payer négatif (%)', v_paye; END IF;

  UPDATE mf.retrait SET montant_paye = v_paye, statut = 'execute', date_operation = v_date, execute_le = now()
   WHERE id = p_retrait;
  IF r.nature IN ('retrait_client','virement_vers_epargne') THEN
    UPDATE mf.cycle SET statut = 'retire' WHERE id = r.cycle_id;
  END IF;

  IF r.nature = 'virement_vers_epargne' THEN
    PERFORM mf.exec_virement_vers_epargne(p_retrait);
  ELSIF r.nature = 'remboursement' THEN
    PERFORM mf.exec_remboursement(p_retrait);
  ELSIF r.nature = 'retrait_client' AND r.decaissement AND p_session IS NOT NULL AND v_paye > 0 THEN
    PERFORM mf.caisse_operation(p_session, 'decaissement', 'retrait_client', v_paye, v_date, 'retrait', p_retrait);
  END IF;
END $$;

-- ---------------------------------------------------------------------
-- Purge d'une date : tous les retraits des cycles ayant une ligne à cette date sont faits
-- et aucun écart n'est ouvert sur cette date. Les excédents à régulariser deviennent alors
-- surplus réel de l'agent.
-- ---------------------------------------------------------------------
CREATE FUNCTION purger_date(p_agence smallint, p_date date) RETURNS boolean
LANGUAGE plpgsql AS $$
DECLARE x record; v_sid integer;
BEGIN
  IF EXISTS (SELECT 1 FROM mf.date_purgee WHERE agence_id = p_agence AND date_purge = p_date) THEN RETURN false; END IF;
  IF EXISTS (SELECT 1 FROM mf.ligne_collecte l JOIN mf.cycle c ON c.id = l.cycle_id
              WHERE c.agence_id = p_agence AND l.date_collecte = p_date AND l.origine = 'collecte'
                AND c.statut <> 'retire') THEN RETURN false; END IF;
  IF EXISTS (SELECT 1 FROM mf.ecart_retrait_date d JOIN mf.ecart_retrait e ON e.id = d.ecart_id
              WHERE e.agence_id = p_agence AND d.date_ecart = p_date AND e.statut = 'a_traiter') THEN RETURN false; END IF;

  FOR x IN SELECT * FROM mf.excedent_regularisation
            WHERE agence_id = p_agence AND date_ligne = p_date AND statut = 'a_regulariser' ORDER BY id LOOP
    INSERT INTO mf.surplus(agence_id, agent_id, date_surplus, montant, origine, reference)
    VALUES (p_agence, x.agent_id, p_date, x.montant, 'regularisation', 'excedent_regularisation:' || x.id)
    RETURNING id INTO v_sid;
    UPDATE mf.excedent_regularisation SET statut = 'regularise', surplus_id = v_sid WHERE id = x.id;
  END LOOP;
  INSERT INTO mf.date_purgee(agence_id, date_purge) VALUES (p_agence, p_date);
  RETURN true;
END $$;

-- Tâche planifiée : purge toutes les dates purgeables jusqu'à p_jusqu_au. Retourne le nombre de dates purgées.
CREATE FUNCTION purger_dates(p_agence smallint, p_jusqu_au date DEFAULT current_date) RETURNS integer
LANGUAGE plpgsql AS $$
DECLARE x record; n integer := 0;
BEGIN
  FOR x IN SELECT DISTINCT l.date_collecte AS d
             FROM mf.ligne_collecte l JOIN mf.cycle c ON c.id = l.cycle_id
            WHERE c.agence_id = p_agence AND l.date_collecte <= p_jusqu_au AND l.origine = 'collecte'
              AND NOT EXISTS (SELECT 1 FROM mf.date_purgee p WHERE p.agence_id = p_agence AND p.date_purge = l.date_collecte)
            ORDER BY 1 LOOP
    IF mf.purger_date(p_agence, x.d) THEN n := n + 1; END IF;
  END LOOP;
  RETURN n;
END $$;

-- =====================================================================
-- MODULE 03_credit_caisse.sql
-- =====================================================================
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

-- =====================================================================
-- MODULE 04_rh.sql
-- =====================================================================
-- =====================================================================
-- 04_rh.sql
-- Employés, contrats, congés, présences, rubriques et bulletins de paie, avances sur salaire,
-- commission de collectrice (production x taux, nette de la retenue sur le compte agent).
-- Règles : BRIEF_CLAUDE_CODE.md sections 3.2 et P1.8.
-- Dépend de : 00, 01, 02.
-- Les taux de cotisations sociales et d'impôt sur salaire ne sont PAS fournis (brief P0.5) :
-- aucune rubrique n'est préchargée, elles se saisissent dans rubrique_paie.
-- =====================================================================
SET search_path = mf, public;

-- Une collectrice peut être aussi un agent : sa dette (compte agent) est retenue sur sa commission.
ALTER TABLE collectrice ADD COLUMN agent_id integer REFERENCES agent(id);

CREATE TABLE employe (
  id             serial PRIMARY KEY,
  agence_id      smallint NOT NULL REFERENCES agence(id),
  matricule      varchar(20) NOT NULL,
  nom            text NOT NULL,
  poste          text,
  date_embauche  date NOT NULL,
  date_sortie    date,
  statut         varchar(10) NOT NULL DEFAULT 'actif' CHECK (statut IN ('actif','sorti')),
  collectrice_id integer REFERENCES collectrice(id),   -- sa commission entre dans son bulletin
  agent_id       integer REFERENCES agent(id),
  utilisateur_id integer REFERENCES utilisateur(id),
  UNIQUE (agence_id, matricule)
);

CREATE TABLE contrat (
  id            serial PRIMARY KEY,
  employe_id    integer NOT NULL REFERENCES employe(id),
  type          varchar(10) NOT NULL CHECK (type IN ('cdi','cdd','stage','journalier')),
  date_debut    date NOT NULL,
  date_fin      date,
  salaire_base  numeric(14,0) NOT NULL CHECK (salaire_base >= 0),
  CHECK (date_fin IS NULL OR date_fin >= date_debut),
  EXCLUDE USING gist (employe_id WITH =, daterange(date_debut, date_fin, '[]') WITH &&)
);

CREATE TABLE conge (
  id         serial PRIMARY KEY,
  employe_id integer NOT NULL REFERENCES employe(id),
  type       varchar(15) NOT NULL CHECK (type IN ('annuel','maladie','maternite','sans_solde','autre')),
  date_debut date NOT NULL,
  date_fin   date NOT NULL,
  statut     varchar(10) NOT NULL DEFAULT 'demande' CHECK (statut IN ('demande','approuve','refuse')),
  CHECK (date_fin >= date_debut)
);

CREATE TABLE presence (
  id         serial PRIMARY KEY,
  employe_id integer NOT NULL REFERENCES employe(id),
  date_jour  date NOT NULL,
  statut     varchar(10) NOT NULL CHECK (statut IN ('present','absent','retard','conge')),
  heures     numeric(4,1),
  UNIQUE (employe_id, date_jour)
);

-- Rubriques de paie paramétrables. base : 'brut' ou 'salaire_base'.
CREATE TABLE rubrique_paie (
  id       serial PRIMARY KEY,
  agence_id smallint REFERENCES agence(id),            -- NULL = toutes les agences
  code     varchar(20) NOT NULL,
  libelle  text NOT NULL,
  type     varchar(20) NOT NULL CHECK (type IN ('gain','retenue_salariale','charge_patronale')),
  mode     varchar(12) NOT NULL CHECK (mode IN ('fixe','pourcentage')),
  valeur   numeric(12,5) NOT NULL CHECK (valeur >= 0),
  base     varchar(12) NOT NULL DEFAULT 'brut' CHECK (base IN ('brut','salaire_base')),
  actif    boolean NOT NULL DEFAULT true,
  ordre    smallint NOT NULL DEFAULT 100
);
CREATE UNIQUE INDEX rubrique_paie_code ON rubrique_paie (code, COALESCE(agence_id, 0));

CREATE TABLE avance_salaire (
  id          serial PRIMARY KEY,
  employe_id  integer NOT NULL REFERENCES employe(id),
  date_avance date NOT NULL,
  montant     numeric(14,0) NOT NULL CHECK (montant > 0),
  restant     numeric(14,0) NOT NULL,
  statut      varchar(10) NOT NULL DEFAULT 'en_cours' CHECK (statut IN ('en_cours','soldee')),
  CHECK (restant BETWEEN 0 AND montant)
);

-- ---------------------------------------------------------------------
-- Commission de collectrice : production x taux_commission, nette de la retenue sur le compte agent
-- (plafonnée par plafond_retenue). La production dépend de mode_cloture (voir production_collectrice).
-- ---------------------------------------------------------------------
CREATE TABLE commission_collectrice (
  id               serial PRIMARY KEY,
  agence_id        smallint NOT NULL REFERENCES agence(id),
  collectrice_id   integer NOT NULL REFERENCES collectrice(id),
  periode_debut    date NOT NULL,
  periode_fin      date NOT NULL,
  production       numeric(14,0) NOT NULL,
  taux             numeric(7,5) NOT NULL,
  commission_brute numeric(14,0) NOT NULL,
  retenue_agent    numeric(14,0) NOT NULL DEFAULT 0,
  commission_nette numeric(14,0) NOT NULL,
  statut           varchar(10) NOT NULL DEFAULT 'calculee' CHECK (statut IN ('calculee','payee')),
  calcule_le       timestamptz NOT NULL DEFAULT now(),
  CHECK (periode_fin >= periode_debut),
  UNIQUE (collectrice_id, periode_debut, periode_fin)
);

CREATE FUNCTION calculer_commission(p_collectrice integer, p_du date, p_au date) RETURNS integer
LANGUAGE plpgsql AS $$
DECLARE c mf.collectrice; v_prod numeric; v_taux numeric; v_brute numeric; v_ret numeric := 0; v_id integer;
BEGIN
  SELECT * INTO c FROM mf.collectrice WHERE id = p_collectrice FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'collectrice % inconnue', p_collectrice; END IF;
  IF EXISTS (SELECT 1 FROM mf.commission_collectrice WHERE collectrice_id = p_collectrice
              AND periode_debut = p_du AND periode_fin = p_au) THEN
    RAISE EXCEPTION 'commission déjà calculée pour la collectrice % sur % - %', c.matricule, p_du, p_au;
  END IF;
  v_prod  := mf.production_collectrice(p_collectrice, p_du, p_au);
  v_taux  := mf.param_num('taux_commission', c.agence_id);
  v_brute := round(v_prod * v_taux);
  IF c.agent_id IS NOT NULL THEN
    v_ret := mf.retenue_sur_commission(c.agent_id, v_brute, p_au);
  END IF;
  INSERT INTO mf.commission_collectrice(agence_id, collectrice_id, periode_debut, periode_fin, production,
                                        taux, commission_brute, retenue_agent, commission_nette)
  VALUES (c.agence_id, p_collectrice, p_du, p_au, v_prod, v_taux, v_brute, v_ret, v_brute - v_ret)
  RETURNING id INTO v_id;
  RETURN v_id;
END $$;

-- ---------------------------------------------------------------------
-- Bulletins de paie
-- ---------------------------------------------------------------------
CREATE TABLE bulletin_paie (
  id               serial PRIMARY KEY,
  agence_id        smallint NOT NULL REFERENCES agence(id),
  employe_id       integer NOT NULL REFERENCES employe(id),
  periode          date NOT NULL,                   -- 1er jour du mois
  salaire_base     numeric(14,0) NOT NULL,
  commission_nette numeric(14,0) NOT NULL DEFAULT 0,
  brut             numeric(14,0) NOT NULL,
  retenues         numeric(14,0) NOT NULL,          -- retenues salariales (hors avance)
  retenue_avance   numeric(14,0) NOT NULL DEFAULT 0,
  charges_patronales numeric(14,0) NOT NULL DEFAULT 0,
  net_a_payer      numeric(14,0) NOT NULL,
  statut           varchar(10) NOT NULL DEFAULT 'brouillon' CHECK (statut IN ('brouillon','valide','paye')),
  commission_id    integer REFERENCES commission_collectrice(id),
  cree_le          timestamptz NOT NULL DEFAULT now(),
  UNIQUE (employe_id, periode)
);

CREATE TABLE ligne_bulletin (
  id          serial PRIMARY KEY,
  bulletin_id integer NOT NULL REFERENCES bulletin_paie(id) ON DELETE CASCADE,
  code        varchar(20) NOT NULL,
  libelle     text NOT NULL,
  type        varchar(20) NOT NULL,
  base        numeric(14,0),
  taux        numeric(12,5),
  montant     numeric(14,0) NOT NULL
);

-- Génère le bulletin d'un employé pour un mois : salaire de base du contrat en vigueur, commission nette
-- de la période (si la collectrice a une commission calculée sur le mois), rubriques actives, retenue d'avance
-- (dans la limite du net restant). Pas de retenue pour absence : non spécifiée dans le brief.
CREATE FUNCTION generer_bulletin(p_employe integer, p_periode date) RETURNS integer
LANGUAGE plpgsql AS $$
DECLARE e mf.employe; v_mois date := date_trunc('month', p_periode)::date; v_fin date;
        v_base numeric; v_comm numeric := 0; v_comm_id integer; v_brut numeric; v_gains numeric := 0;
        v_ret numeric := 0; v_pat numeric := 0; v_net numeric; v_avance numeric := 0; v_id integer;
        r record; v_m numeric; v_b numeric;
BEGIN
  v_fin := (v_mois + interval '1 month - 1 day')::date;
  SELECT * INTO e FROM mf.employe WHERE id = p_employe FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'employé % inconnu', p_employe; END IF;
  SELECT salaire_base INTO v_base FROM mf.contrat
   WHERE employe_id = p_employe AND date_debut <= v_fin AND (date_fin IS NULL OR date_fin >= v_mois)
   ORDER BY date_debut DESC LIMIT 1;
  IF v_base IS NULL THEN RAISE EXCEPTION 'aucun contrat pour % sur %', e.matricule, v_mois; END IF;
  IF EXISTS (SELECT 1 FROM mf.bulletin_paie WHERE employe_id = p_employe AND periode = v_mois) THEN
    RAISE EXCEPTION 'bulletin déjà généré pour % sur %', e.matricule, v_mois;
  END IF;

  IF e.collectrice_id IS NOT NULL THEN
    SELECT id, commission_nette INTO v_comm_id, v_comm FROM mf.commission_collectrice
     WHERE collectrice_id = e.collectrice_id AND statut = 'calculee'
       AND periode_debut >= v_mois AND periode_fin <= v_fin
     ORDER BY periode_fin DESC LIMIT 1;
    v_comm := COALESCE(v_comm, 0);
  END IF;

  INSERT INTO mf.bulletin_paie(agence_id, employe_id, periode, salaire_base, commission_nette, brut, retenues,
                               net_a_payer, commission_id)
  VALUES (e.agence_id, p_employe, v_mois, v_base, v_comm, v_base + v_comm, 0, 0, v_comm_id)
  RETURNING id INTO v_id;
  INSERT INTO mf.ligne_bulletin(bulletin_id, code, libelle, type, montant) VALUES (v_id, 'BASE', 'Salaire de base', 'gain', v_base);
  IF v_comm > 0 THEN
    INSERT INTO mf.ligne_bulletin(bulletin_id, code, libelle, type, montant) VALUES (v_id, 'COMMISSION', 'Commission nette', 'gain', v_comm);
  END IF;

  -- gains paramétrés (sur le salaire de base), puis brut
  FOR r IN SELECT * FROM mf.rubrique_paie WHERE actif AND type = 'gain' AND (agence_id IS NULL OR agence_id = e.agence_id) ORDER BY ordre, id LOOP
    v_m := CASE WHEN r.mode = 'fixe' THEN r.valeur ELSE round(v_base * r.valeur) END;
    v_gains := v_gains + v_m;
    INSERT INTO mf.ligne_bulletin(bulletin_id, code, libelle, type, base, taux, montant)
    VALUES (v_id, r.code, r.libelle, 'gain', CASE WHEN r.mode = 'pourcentage' THEN v_base END,
            CASE WHEN r.mode = 'pourcentage' THEN r.valeur END, v_m);
  END LOOP;
  v_brut := v_base + v_comm + v_gains;

  FOR r IN SELECT * FROM mf.rubrique_paie WHERE actif AND type IN ('retenue_salariale','charge_patronale')
              AND (agence_id IS NULL OR agence_id = e.agence_id) ORDER BY ordre, id LOOP
    v_b := CASE WHEN r.base = 'brut' THEN v_brut ELSE v_base END;
    v_m := CASE WHEN r.mode = 'fixe' THEN r.valeur ELSE round(v_b * r.valeur) END;
    IF r.type = 'retenue_salariale' THEN v_ret := v_ret + v_m; ELSE v_pat := v_pat + v_m; END IF;
    INSERT INTO mf.ligne_bulletin(bulletin_id, code, libelle, type, base, taux, montant)
    VALUES (v_id, r.code, r.libelle, r.type, CASE WHEN r.mode = 'pourcentage' THEN v_b END,
            CASE WHEN r.mode = 'pourcentage' THEN r.valeur END, v_m);
  END LOOP;

  -- retenue d'avances : tout le restant dû, dans la limite du net disponible
  SELECT COALESCE(sum(restant), 0) INTO v_avance FROM mf.avance_salaire WHERE employe_id = p_employe AND statut = 'en_cours';
  v_avance := LEAST(v_avance, GREATEST(v_brut - v_ret, 0));
  IF v_avance > 0 THEN
    INSERT INTO mf.ligne_bulletin(bulletin_id, code, libelle, type, montant) VALUES (v_id, 'AVANCE', 'Retenue d''avance', 'retenue_salariale', v_avance);
  END IF;
  v_net := v_brut - v_ret - v_avance;
  UPDATE mf.bulletin_paie
     SET brut = v_brut, retenues = v_ret, retenue_avance = v_avance, charges_patronales = v_pat, net_a_payer = v_net
   WHERE id = v_id;
  RETURN v_id;
END $$;

CREATE FUNCTION generer_bulletins(p_agence smallint, p_periode date) RETURNS integer
LANGUAGE plpgsql AS $$
DECLARE x record; n integer := 0; v_mois date := date_trunc('month', p_periode)::date;
BEGIN
  FOR x IN SELECT e.id FROM mf.employe e
            WHERE e.agence_id = p_agence AND e.statut = 'actif'
              AND NOT EXISTS (SELECT 1 FROM mf.bulletin_paie b WHERE b.employe_id = e.id AND b.periode = v_mois)
              AND EXISTS (SELECT 1 FROM mf.contrat c WHERE c.employe_id = e.id AND c.date_debut <= (v_mois + interval '1 month - 1 day')::date
                           AND (c.date_fin IS NULL OR c.date_fin >= v_mois))
            ORDER BY e.id LOOP
    PERFORM mf.generer_bulletin(x.id, v_mois);
    n := n + 1;
  END LOOP;
  RETURN n;
END $$;

-- Validation : impute la retenue d'avance et marque la commission comme payée.
CREATE FUNCTION valider_bulletin(p_bulletin integer) RETURNS void
LANGUAGE plpgsql AS $$
DECLARE b mf.bulletin_paie; v_reste numeric; a record; v_use numeric;
BEGIN
  SELECT * INTO b FROM mf.bulletin_paie WHERE id = p_bulletin FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'bulletin % inconnu', p_bulletin; END IF;
  IF b.statut <> 'brouillon' THEN RAISE EXCEPTION 'bulletin % déjà validé', p_bulletin; END IF;
  v_reste := b.retenue_avance;
  FOR a IN SELECT * FROM mf.avance_salaire WHERE employe_id = b.employe_id AND statut = 'en_cours' ORDER BY date_avance, id FOR UPDATE LOOP
    EXIT WHEN v_reste <= 0;
    v_use := LEAST(v_reste, a.restant);
    UPDATE mf.avance_salaire SET restant = restant - v_use, statut = CASE WHEN restant - v_use = 0 THEN 'soldee' ELSE statut END WHERE id = a.id;
    v_reste := v_reste - v_use;
  END LOOP;
  IF b.commission_id IS NOT NULL THEN
    UPDATE mf.commission_collectrice SET statut = 'payee' WHERE id = b.commission_id;
  END IF;
  UPDATE mf.bulletin_paie SET statut = 'valide' WHERE id = p_bulletin;
END $$;

-- =====================================================================
-- MODULE 05_comptabilite.sql
-- =====================================================================
-- =====================================================================
-- 05_comptabilite.sql
-- Comptabilité en partie double selon le référentiel comptable spécifique des SFD de l'UMOA :
-- exercices, plan de comptes (chargé par 05_plan_comptable_data.sql), journaux, pièces, écritures
-- équilibrées par trigger, règles comptables, comptabilisation d'événements, balance, grand livre,
-- numérotation automatique.
-- Dépend de : 00. Les règles par événement et leur branchement sur les opérations sont en 10.
-- =====================================================================
SET search_path = mf, public;

CREATE TABLE exercice_comptable (
  id         serial PRIMARY KEY,
  code       varchar(10) NOT NULL UNIQUE,
  date_debut date NOT NULL,
  date_fin   date NOT NULL,
  statut     varchar(10) NOT NULL DEFAULT 'ouvert' CHECK (statut IN ('ouvert','cloture')),
  CHECK (date_fin > date_debut),
  EXCLUDE USING gist (daterange(date_debut, date_fin, '[]') WITH &&)
);

CREATE TABLE compte_comptable (
  code      varchar(7) PRIMARY KEY,
  libelle   text NOT NULL,
  classe    char(1) NOT NULL,
  parent    varchar(7) REFERENCES compte_comptable(code),
  imputable boolean NOT NULL,          -- seuls les comptes sans sous-compte reçoivent des écritures
  actif     boolean NOT NULL DEFAULT true
);
CREATE INDEX compte_comptable_classe ON compte_comptable (classe);

CREATE TABLE journal (
  id      serial PRIMARY KEY,
  code    varchar(6) NOT NULL UNIQUE,
  libelle text NOT NULL,
  type    varchar(20) NOT NULL
);
INSERT INTO journal(code, libelle, type) VALUES
  ('CAI','Journal de caisse','caisse'),
  ('EPA','Journal de l''épargne','epargne'),
  ('CRE','Journal des crédits','credit'),
  ('AGT','Journal des opérations agents','agents'),
  ('PAI','Journal de paie','paie'),
  ('OD','Opérations diverses','divers');

-- ---------------------------------------------------------------------
-- Numérotation automatique (clients, comptes, cycles, crédits, pièces ...)
-- ---------------------------------------------------------------------
CREATE TABLE numerotation (
  cle       varchar(30) NOT NULL,
  agence_id smallint NOT NULL,
  annee     smallint NOT NULL,
  dernier   integer NOT NULL DEFAULT 0,
  PRIMARY KEY (cle, agence_id, annee)
);

-- ex. CL-LOM-2026-000001. Le verrou de ligne de l'upsert sérialise les appels concurrents.
CREATE FUNCTION prochain_numero(p_cle text, p_agence smallint, p_date date, p_prefixe text) RETURNS text
LANGUAGE plpgsql AS $$
DECLARE v_n integer; v_code text; v_annee smallint := extract(year FROM p_date);
BEGIN
  SELECT code INTO v_code FROM mf.agence WHERE id = p_agence;
  INSERT INTO mf.numerotation(cle, agence_id, annee, dernier) VALUES (p_cle, p_agence, v_annee, 1)
  ON CONFLICT (cle, agence_id, annee) DO UPDATE SET dernier = mf.numerotation.dernier + 1
  RETURNING dernier INTO v_n;
  RETURN p_prefixe || '-' || COALESCE(v_code, p_agence::text) || '-' || v_annee || '-' || lpad(v_n::text, 6, '0');
END $$;

-- BEFORE INSERT : renseigne numero s'il est absent (argument : préfixe).
CREATE FUNCTION trg_numerotation() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  IF NEW.numero IS NULL THEN
    NEW.numero := mf.prochain_numero(TG_TABLE_NAME, NEW.agence_id, current_date, TG_ARGV[0]);
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER client_numero BEFORE INSERT ON client FOR EACH ROW EXECUTE FUNCTION trg_numerotation('CL');
CREATE TRIGGER compte_epargne_numero BEFORE INSERT ON compte_epargne FOR EACH ROW EXECUTE FUNCTION trg_numerotation('CE');
CREATE TRIGGER cycle_numero BEFORE INSERT ON cycle FOR EACH ROW EXECUTE FUNCTION trg_numerotation('CY');
CREATE TRIGGER credit_numero BEFORE INSERT ON credit FOR EACH ROW EXECUTE FUNCTION trg_numerotation('CR');

-- ---------------------------------------------------------------------
-- Pièces et écritures
-- ---------------------------------------------------------------------
CREATE TABLE piece_comptable (
  id              bigserial PRIMARY KEY,
  agence_id       smallint NOT NULL REFERENCES agence(id),
  journal_id      integer NOT NULL REFERENCES journal(id),
  exercice_id     integer NOT NULL REFERENCES exercice_comptable(id),
  date_piece      date NOT NULL,
  numero          varchar(40) NOT NULL,
  libelle         text,
  evenement       varchar(40),
  reference_table text,
  reference_id    bigint,
  origine         varchar(15) NOT NULL DEFAULT 'manuelle' CHECK (origine IN ('manuelle','auto','contrepassation')),
  piece_origine_id bigint REFERENCES piece_comptable(id),
  utilisateur_id  integer REFERENCES utilisateur(id),
  cree_le         timestamptz NOT NULL DEFAULT now(),
  UNIQUE (agence_id, numero)
);
-- une opération ne se comptabilise qu'une fois par événement
CREATE UNIQUE INDEX piece_auto_unique ON piece_comptable (evenement, reference_table, reference_id)
  WHERE origine = 'auto' AND reference_id IS NOT NULL;
CREATE INDEX piece_date ON piece_comptable (agence_id, date_piece);

CREATE TABLE ecriture (
  id          bigserial PRIMARY KEY,
  piece_id    bigint NOT NULL REFERENCES piece_comptable(id),
  ligne       smallint NOT NULL,
  compte_code varchar(7) NOT NULL REFERENCES compte_comptable(code),
  debit       numeric(14,0) NOT NULL DEFAULT 0,
  credit      numeric(14,0) NOT NULL DEFAULT 0,
  libelle     text,
  CHECK (debit >= 0 AND credit >= 0 AND (debit = 0) <> (credit = 0)),
  UNIQUE (piece_id, ligne)
);
CREATE INDEX ecriture_compte ON ecriture (compte_code);

-- Compte imputable et actif, exercice ouvert, date dans l'exercice.
CREATE FUNCTION trg_ecriture_controle() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE c mf.compte_comptable; p mf.piece_comptable; x mf.exercice_comptable;
BEGIN
  SELECT * INTO c FROM mf.compte_comptable WHERE code = NEW.compte_code;
  IF NOT c.imputable OR NOT c.actif THEN
    RAISE EXCEPTION 'compte % (%) non imputable ou inactif', c.code, c.libelle;
  END IF;
  SELECT * INTO p FROM mf.piece_comptable WHERE id = NEW.piece_id;
  SELECT * INTO x FROM mf.exercice_comptable WHERE id = p.exercice_id;
  IF x.statut <> 'ouvert' THEN RAISE EXCEPTION 'exercice % clôturé', x.code; END IF;
  IF p.date_piece NOT BETWEEN x.date_debut AND x.date_fin THEN
    RAISE EXCEPTION 'date de pièce % hors de l''exercice %', p.date_piece, x.code;
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER ecriture_controle BEFORE INSERT ON ecriture FOR EACH ROW EXECUTE FUNCTION trg_ecriture_controle();

-- Journal inviolable : pas de modification ni de suppression, on contrepasse.
CREATE FUNCTION trg_ecriture_inviolable() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  RAISE EXCEPTION 'une écriture comptable ne se modifie ni ne se supprime : contrepasser la pièce';
END $$;
CREATE TRIGGER ecriture_inviolable BEFORE UPDATE OR DELETE ON ecriture FOR EACH ROW EXECUTE FUNCTION trg_ecriture_inviolable();
CREATE TRIGGER piece_inviolable BEFORE DELETE ON piece_comptable FOR EACH ROW EXECUTE FUNCTION trg_ecriture_inviolable();

-- Équilibre débit = crédit par pièce, contrôlé en fin de transaction (contrainte différée).
CREATE FUNCTION trg_piece_equilibre() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE v_d numeric; v_c numeric; v_n integer;
BEGIN
  SELECT sum(debit), sum(credit), count(*) INTO v_d, v_c, v_n FROM mf.ecriture WHERE piece_id = NEW.piece_id;
  IF v_d IS DISTINCT FROM v_c THEN
    RAISE EXCEPTION 'pièce % déséquilibrée : débit %, crédit %', NEW.piece_id, v_d, v_c;
  END IF;
  RETURN NULL;
END $$;
CREATE CONSTRAINT TRIGGER ecriture_equilibre AFTER INSERT ON ecriture
  DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION trg_piece_equilibre();

-- ---------------------------------------------------------------------
-- Règles comptables : par événement, une ou plusieurs lignes (compte débité, compte crédité,
-- clé du montant dans le JSON de l'événement). Une règle d'agence remplace la règle globale de même ligne.
-- ---------------------------------------------------------------------
CREATE TABLE regle_comptable (
  id            serial PRIMARY KEY,
  evenement     varchar(40) NOT NULL,
  ligne         smallint NOT NULL,
  agence_id     smallint REFERENCES agence(id),
  compte_debit  varchar(7) NOT NULL REFERENCES compte_comptable(code),
  compte_credit varchar(7) NOT NULL REFERENCES compte_comptable(code),
  cle_montant   varchar(30) NOT NULL,
  journal_code  varchar(6) NOT NULL DEFAULT 'OD' REFERENCES journal(code),
  libelle       text,
  actif         boolean NOT NULL DEFAULT true
);
CREATE UNIQUE INDEX regle_comptable_unique ON regle_comptable (evenement, ligne, COALESCE(agence_id, 0));

-- Comptabilise un événement : une pièce, une paire d'écritures par ligne de règle dont le montant est > 0.
-- Retourne l'id de la pièce, ou NULL si tous les montants sont nuls.
CREATE FUNCTION comptabiliser(p_evenement text, p_agence smallint, p_date date, p_montants jsonb,
                              p_ref_table text DEFAULT NULL, p_ref_id bigint DEFAULT NULL,
                              p_libelle text DEFAULT NULL, p_utilisateur integer DEFAULT NULL) RETURNS bigint
LANGUAGE plpgsql AS $$
DECLARE r record; v_m numeric; v_x integer; v_j integer; v_piece bigint; v_ligne smallint := 0; v_regles integer := 0;
        v_jcode text;
BEGIN
  SELECT count(*) INTO v_regles FROM mf.regle_comptable WHERE evenement = p_evenement AND actif;
  IF v_regles = 0 THEN RAISE EXCEPTION 'aucune règle comptable pour l''événement %', p_evenement; END IF;
  SELECT id INTO v_x FROM mf.exercice_comptable WHERE p_date BETWEEN date_debut AND date_fin;
  IF v_x IS NULL THEN RAISE EXCEPTION 'aucun exercice comptable pour la date %', p_date; END IF;

  FOR r IN SELECT DISTINCT ON (ligne) * FROM mf.regle_comptable
            WHERE evenement = p_evenement AND actif AND (agence_id = p_agence OR agence_id IS NULL)
            ORDER BY ligne, agence_id NULLS LAST LOOP
    v_m := COALESCE((p_montants ->> r.cle_montant)::numeric, 0);
    IF v_m < 0 THEN RAISE EXCEPTION 'montant négatif pour la clé % de l''événement %', r.cle_montant, p_evenement; END IF;
    CONTINUE WHEN v_m = 0;
    IF v_piece IS NULL THEN
      v_jcode := r.journal_code;
      SELECT id INTO v_j FROM mf.journal WHERE code = v_jcode;
      INSERT INTO mf.piece_comptable(agence_id, journal_id, exercice_id, date_piece, numero, libelle, evenement,
                                     reference_table, reference_id, origine, utilisateur_id)
      VALUES (p_agence, v_j, v_x, p_date, mf.prochain_numero('piece', p_agence, p_date, 'PC'),
              COALESCE(p_libelle, r.libelle, p_evenement), p_evenement, p_ref_table, p_ref_id, 'auto', p_utilisateur)
      RETURNING id INTO v_piece;
    END IF;
    v_ligne := v_ligne + 1;
    INSERT INTO mf.ecriture(piece_id, ligne, compte_code, debit, credit, libelle)
    VALUES (v_piece, v_ligne, r.compte_debit, v_m, 0, COALESCE(r.libelle, p_libelle));
    v_ligne := v_ligne + 1;
    INSERT INTO mf.ecriture(piece_id, ligne, compte_code, debit, credit, libelle)
    VALUES (v_piece, v_ligne, r.compte_credit, 0, v_m, COALESCE(r.libelle, p_libelle));
  END LOOP;
  RETURN v_piece;
END $$;

-- Contrepasse une pièce (écritures inverses) : seul moyen de corriger.
CREATE FUNCTION contrepasser_piece(p_piece bigint, p_date date DEFAULT current_date, p_motif text DEFAULT NULL) RETURNS bigint
LANGUAGE plpgsql AS $$
DECLARE p mf.piece_comptable; v_x integer; v_new bigint;
BEGIN
  SELECT * INTO p FROM mf.piece_comptable WHERE id = p_piece;
  IF NOT FOUND THEN RAISE EXCEPTION 'pièce % inconnue', p_piece; END IF;
  IF p.origine = 'contrepassation' THEN RAISE EXCEPTION 'une contrepassation ne se contrepasse pas'; END IF;
  IF EXISTS (SELECT 1 FROM mf.piece_comptable WHERE piece_origine_id = p_piece) THEN
    RAISE EXCEPTION 'pièce % déjà contrepassée', p_piece;
  END IF;
  SELECT id INTO v_x FROM mf.exercice_comptable WHERE p_date BETWEEN date_debut AND date_fin;
  IF v_x IS NULL THEN RAISE EXCEPTION 'aucun exercice comptable pour la date %', p_date; END IF;
  INSERT INTO mf.piece_comptable(agence_id, journal_id, exercice_id, date_piece, numero, libelle, origine, piece_origine_id)
  VALUES (p.agence_id, p.journal_id, v_x, p_date, mf.prochain_numero('piece', p.agence_id, p_date, 'PC'),
          'Contrepassation de ' || p.numero || COALESCE(' : ' || p_motif, ''), 'contrepassation', p_piece)
  RETURNING id INTO v_new;
  INSERT INTO mf.ecriture(piece_id, ligne, compte_code, debit, credit, libelle)
  SELECT v_new, ligne, compte_code, credit, debit, 'Contrepassation ' || COALESCE(libelle, '')
    FROM mf.ecriture WHERE piece_id = p_piece;
  RETURN v_new;
END $$;

CREATE FUNCTION cloturer_exercice(p_exercice integer) RETURNS void
LANGUAGE plpgsql AS $$
BEGIN
  UPDATE mf.exercice_comptable SET statut = 'cloture' WHERE id = p_exercice AND statut = 'ouvert';
  IF NOT FOUND THEN RAISE EXCEPTION 'exercice % inconnu ou déjà clôturé', p_exercice; END IF;
END $$;

-- ---------------------------------------------------------------------
-- États : balance, grand livre, résultat. p_agence NULL = toutes les agences (siège).
-- Les états de synthèse réglementaires (bilan, hors bilan, soldes intermédiaires) restent à bâtir
-- sur ces fonctions.
-- ---------------------------------------------------------------------
CREATE FUNCTION balance(p_agence smallint, p_du date, p_au date)
RETURNS TABLE (compte varchar, libelle text, debit numeric, credit numeric, solde_debiteur numeric, solde_crediteur numeric)
LANGUAGE sql STABLE AS $$
  SELECT e.compte_code, c.libelle, sum(e.debit), sum(e.credit),
         GREATEST(sum(e.debit) - sum(e.credit), 0), GREATEST(sum(e.credit) - sum(e.debit), 0)
    FROM mf.ecriture e
    JOIN mf.piece_comptable p ON p.id = e.piece_id
    JOIN mf.compte_comptable c ON c.code = e.compte_code
   WHERE (p_agence IS NULL OR p.agence_id = p_agence) AND p.date_piece BETWEEN p_du AND p_au
   GROUP BY e.compte_code, c.libelle
   ORDER BY e.compte_code
$$;

CREATE FUNCTION grand_livre(p_compte text, p_agence smallint, p_du date, p_au date)
RETURNS TABLE (date_piece date, numero varchar, libelle text, debit numeric, credit numeric, solde_cumule numeric)
LANGUAGE sql STABLE AS $$
  SELECT p.date_piece, p.numero, COALESCE(e.libelle, p.libelle), e.debit, e.credit,
         sum(e.debit - e.credit) OVER (ORDER BY p.date_piece, p.id, e.ligne)
    FROM mf.ecriture e JOIN mf.piece_comptable p ON p.id = e.piece_id
   WHERE e.compte_code = p_compte AND (p_agence IS NULL OR p.agence_id = p_agence)
     AND p.date_piece BETWEEN p_du AND p_au
   ORDER BY p.date_piece, p.id, e.ligne
$$;

-- Résultat = produits (classe 7) - charges (classe 6)
CREATE FUNCTION resultat(p_agence smallint, p_du date, p_au date) RETURNS numeric
LANGUAGE sql STABLE AS $$
  SELECT COALESCE(sum(CASE c.classe WHEN '7' THEN e.credit - e.debit WHEN '6' THEN e.credit - e.debit END), 0)
    FROM mf.ecriture e
    JOIN mf.piece_comptable p ON p.id = e.piece_id
    JOIN mf.compte_comptable c ON c.code = e.compte_code
   WHERE c.classe IN ('6','7') AND (p_agence IS NULL OR p.agence_id = p_agence) AND p.date_piece BETWEEN p_du AND p_au
$$;

-- =====================================================================
-- MODULE 05_plan_comptable_data.sql
-- =====================================================================
-- Généré par tools/extraire_plan_comptable.py à partir de data/plan_comptable_sfd_umoa.csv
-- Référentiel comptable spécifique des SFD de l'UMOA (1re édition) : 1440 comptes.
-- À faire relire par le comptable : libellés extraits d'un PDF.
SET search_path = mf, public;
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('10','VALEURS EN CAISSE','1',NULL,false);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('11','COMPTES ORDINAIRES CHEZ LES INSTITUTIONS FINANCIERES','1',NULL,false);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('12','AUTRES COMPTES DE DEPOTS CHEZ LES INSTITUTIONS FINANCIERES','1',NULL,false);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('13','COMPTES DE PRETS AUX INSTITUTIONS FINANCIERES','1',NULL,false);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('15','COMPTES ORDINAIRES DES INSTITUTIONS FINANCIERES','1',NULL,false);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('16','AUTRES COMPTES DE DEPOTS DES INSTITUTIONS FINANCIERES','1',NULL,false);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('17','COMPTES D''EMPRUNTS ET AUTRES SOMMES DUES AUX INSTITUTIONS FINANCIERES','1',NULL,false);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('18','RESSOURCES AFFECTEES','1',NULL,false);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('19','COMPTES DE PRETS EN SOUFFRANCE ET IMMOBILISES','1',NULL,false);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('20','CREDITS AUX MEMBRES, BENEFICIAIRES OU CLIENTS','2',NULL,false);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('25','COMPTES DES MEMBRES, BENEFICIAIRES OU CLIENTS','2',NULL,false);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('27','EMPRUNTS ET AUTRES SOMMES DUES AUX MEMBRES, CLIENTS OU BENEFICIAIRES','2',NULL,false);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('29','COMPTES DE CREDITS EN SOUFFRANCE','2',NULL,false);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('30','TITRES DE PLACEMENT','3',NULL,false);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('32','COMPTES DE STOCKS ET EMPLOIS DIVERS','3',NULL,false);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('33','DEBITEURS ET CREDITEURS DIVERS','3',NULL,false);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('37','COMPTES TRANSITOIRES ET D''ATTENTE','3',NULL,false);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('38','COMPTES DE REGULARISATION','3',NULL,false);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('39','COMPTES DE LIAISON','3',NULL,true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('41','IMMOBILISATIONS FINANCIERES','4',NULL,false);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('42','DEPOTS ET CAUTIONNEMENTS','4',NULL,false);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('43','IMMOBILISATIONS EN COURS','4',NULL,false);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('44','IMMOBILISATIONS D''EXPLOITATION','4',NULL,false);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('45','IMMOBILISATIONS HORS EXPLOITATION','4',NULL,false);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('46','OPERATIONS DE CREDIT-BAIL ET DE LOCATION AVEC OPTION D''ACHAT','4',NULL,false);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('47','OPERATIONS DE LOCATION-VENTE','4',NULL,false);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('49','COMPTES DE CREANCES EN SOUFFRANCE','4',NULL,false);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('50','SUBVENTIONS ET AUTRES FONDS RECUS','5',NULL,false);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('51','PROVISIONS POUR RISQUES ET CHARGES','5',NULL,false);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('52','PROVISIONS REGLEMENTEES','5',NULL,false);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('53','EMPRUNTS ET TITRES EMIS SUBORDONNES','5',NULL,false);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('54','FONDS POUR RISQUES FINANCIERS GENERAUX','5',NULL,true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('55','PRIMES LIEES AU CAPITAL ET RESERVES','5',NULL,false);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('56','FONDS DE DOTATION','5',NULL,true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('57','CAPITAL SOCIAL','5',NULL,false);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('58','REPORT A NOUVEAU','5',NULL,true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('59','RESULTAT','5',NULL,false);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('60','CHARGES D''EXPLOITATION FINANCIERE','6',NULL,false);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('61','ACHATS ET VARIATIONS DE STOCKS','6',NULL,false);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('62','AUTRES CHARGES EXTERNES ET CHARGES DIVERSES D''EXPLOITATION','6',NULL,false);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('63','IMPOTS, TAXES ET VERSEMENTS ASSIMILES','6',NULL,false);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('64','CHARGES DE PERSONNEL','6',NULL,false);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('65','DOTATION AU FONDS POUR RISQUES FINANCIERS GENERAUX','6',NULL,true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('66','DOTATIONS AUX AMORTISSEMENTS, AUX PROVISIONS ET PERTES SUR CREANCES IRRECOUVRABLES','6',NULL,false);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('67','CHARGES EXCEPTIONNELLES ET PERTES SUR EXERCICES ANTERIEURS','6',NULL,false);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('69','IMPOTS SUR LES EXCEDENTS','6',NULL,false);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('70','PRODUITS D''EXPLOITATION FINANCIERE','7',NULL,false);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('71','VENTES','7',NULL,false);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('72','PRODUITS DIVERS D''EXPLOITATION','7',NULL,false);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('73','PRODUCTION IMMOBILISEE','7',NULL,false);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('74','SUBVENTIONS D''EXPLOITATION','7',NULL,true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('75','REPRISES DU FONDS POUR RISQUES FINANCIERS GENERAUX','7',NULL,true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('76','REPRISES D''AMORTISSEMENTS, DE PROVISIONS ET RECUPERATIONS SUR CREANCES IRRECOUVRABLES','7',NULL,false);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('77','PRODUITS EXCEPTIONNELS ET PROFITS SUR EXERCICES ANTERIEURS','7',NULL,false);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('90','ENGAGEMENTS DE FINANCEMENT','9',NULL,false);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('91','ENGAGEMENTS DE GARANTIE','9',NULL,false);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('92','ENGAGEMENTS SUR TITRES','9',NULL,false);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('93','ENGAGEMENTS SUR OPERATIONS EN DEVISES','9',NULL,false);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('95','AUTRES ENGAGEMENTS','9',NULL,false);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('96','OPERATIONS EFFECTUEES POUR LE COMPTE DE TIERS','9',NULL,false);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('99','ENGAGEMENTS DOUTEUX','9',NULL,true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('101','Billets et monnaies','1','10',false);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('110','Banque Centrale','1','11',false);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('111','Organe Financier/Caisse Centrale','1','11',false);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('112','Trésor Public','1','11',false);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('113','Centre des Chèques Postaux','1','11',false);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('114','Banques et correspondants','1','11',false);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('115','Etablissements Financiers','1','11',false);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('116','Systèmes Financiers Décentralisés','1','11',false);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('117','Autres institutions financières','1','11',false);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('126','Dépôts à terme constitués','1','12',false);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('127','Dépôts de garantie constitués','1','12',false);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('128','Autres dépôts constitués','1','12',false);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('131','Prêts à moins d’1 an','1','13',false);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('133','Prêts à terme','1','13',false);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('151','Organe financier','1','15',false);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('152','Trésor Public','1','15',false);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('153','Centre des Chèques Postaux','1','15',false);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('154','Banques et correspondants','1','15',false);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('155','Etablissements financiers','1','15',false);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('156','Systèmes Financiers Décentralisés','1','15',false);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('157','Autres institutions financières','1','15',false);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('161','Dépôts à terme reçus','1','16',false);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('162','Dépôts de garantie reçus','1','16',false);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('165','Autres dépôts reçus','1','16',false);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('175','Emprunts à moins d’un an','1','17',false);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('178','Emprunts à terme','1','17',false);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('179','Autres sommes dues aux institutions financières','1','17',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('181','Ressources affectées à court terme','1','18',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('182','Ressources affectées à moyen terme','1','18',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('183','Ressources affectées à long terme','1','18',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('184','Intérêts capitalisés','1','18',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('191','Prêts immobilisés','1','19',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('192','Prêts en souffrance de 6 mois au plus','1','19',false);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('193','Prêts en souffrance de plus de 6 mois à 12 mois au plus','1','19',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('194','Prêts en souffrance de plus de 12 mois à 24 mois au plus','1','19',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('199','Provisions sur prêts en souffrance','1','19',false);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('202','Crédits à court terme','2','20',false);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('203','Crédits à moyen terme','2','20',false);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('204','Crédits à long terme','2','20',false);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('251','Comptes ordinaires','2','25',false);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('252','Dépôts à terme reçus','2','25',false);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('253','Comptes d''épargne à régime spécial','2','25',false);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('254','Dépôts de garantie reçus','2','25',false);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('255','Autres dépôts reçus','2','25',false);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('271','Emprunts aux membres, clients ou bénéficiaires','2','27',false);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('272','Autres sommes dues aux membres, clients ou bénéficiaires','2','27',false);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('291','Crédits immobilisés','2','29',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('292','Crédits en souffrance de 6 mois au plus','2','29',false);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('293','Crédits en souffrance de plus de 6 mois à 12 mois au plus','2','29',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('294','Crédits en souffrance de plus de 12 mois à 24 mois au plus','2','29',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('299','Provisions sur crédits en souffrance','2','29',false);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('301','Obligations','3','30',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('302','Autres titres à revenu fixe','3','30',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('303','Actions','3','30',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('304','Autres titres à revenu variable','3','30',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('305','Versements restant à effectuer','3','30',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('307','Créances rattachées','3','30',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('309','Provisions pour dépréciation','3','30',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('321','Stocks de biens meubles','3','32',false);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('322','Stocks de marchandises','3','32',false);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('323','Stocks de fournitures','3','32',false);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('324','Autres stocks et assimilés','3','32',false);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('331','Débiteurs divers','3','33',false);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('332','Créditeurs divers','3','33',false);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('371','Comptes d''encaissement','3','37',false);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('372','Comptes de recouvrement','3','37',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('373','Comptes de contrepartie des comptes de recouvrement','3','37',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('374','Comptes de différences de conversion','3','37',false);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('375','Comptes de réévaluation des opérations de change','3','37',false);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('376','Comptes d''opérations sur crédits consortiaux','3','37',false);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('378','Autres comptes transitoires','3','37',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('379','Comptes d''attente','3','37',false);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('381','Comptes de régularisation - actif','3','38',false);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('382','Comptes de régularisation - passif','3','38',false);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('410','Prêts et titres subordonnés','4','41',false);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('412','Titres de participation','4','41',false);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('414','Titres d''investissement','4','41',false);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('421','Cautions sur loyers','4','42',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('422','Dépôts pour l’électricité','4','42',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('423','Dépôts pour l’eau','4','42',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('424','Dépôts pour le gaz','4','42',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('425','Dépôts pour le téléphone, le télex, la télécopie','4','42',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('426','Cautionnements sur marchés publics','4','42',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('427','Créances rattachées','4','42',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('428','Autres dépôts et cautionnements sur autres opérations','4','42',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('429','Provisions pour dépréciation des dépôts et cautionnements','4','42',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('431','Immobilisations incorporelles en cours','4','43',false);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('432','Immobilisations corporelles en cours','4','43',false);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('441','Immobilisations incorporelles','4','44',false);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('442','Immobilisations corporelles','4','44',false);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('451','Immobilisations incorporelles','4','45',false);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('452','Immobilisations corporelles','4','45',false);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('453','Immobilisations incorporelles acquises par réalisation de garantie','4','45',false);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('454','Immobilisations corporelles acquises par réalisation de garantie','4','45',false);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('461','Crédit-bail','4','46',false);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('462','Location avec option d''achat','4','46',false);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('463','Immobilisations en location simple','4','46',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('464','Immobilisations non louées','4','46',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('467','Créances rattachées','4','46',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('468','Amortissements des immobilisations en crédit-bail et en location avec option d’achat','4','46',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('469','Provisions pour dépréciation des immobilisations en crédit-bail et en location avec option d’achat','4','46',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('471','Immobilisations en cours','4','47',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('472','Location-vente','4','47',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('473','Immobilisations en location simple','4','47',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('474','Immobilisations non louées','4','47',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('477','Créances rattachées','4','47',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('478','Amortissements des immobilisations en location-vente','4','47',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('479','Provisions pour dépréciation des immobilisations en location-vente','4','47',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('491','Créances en souffrance de 6 mois au plus','4','49',false);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('492','Créances en souffrance de plus de 6 mois à 12 mois au plus','4','49',false);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('493','Créances en souffrance de plus de 12 mois à 24 mois au plus','4','49',false);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('499','Provisions sur créances en souffrance','4','49',false);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('501','Subventions d''investissement','5','50',false);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('502','Fonds affectés','5','50',false);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('503','Fonds de crédit','5','50',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('511','Provisions pour charges de retraite','5','51',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('512','Provisions pour risque d’exécution d’engagement par signature','5','51',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('519','Autres provisions pour risques et charges','5','51',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('521','Provisions pour risques afférents aux opérations de crédits à moyen et long termes','5','52',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('522','Provision spéciale de réévaluation','5','52',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('532','Emprunts et titres émis subordonnés','5','53',false);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('536','Dettes rattachées','5','53',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('551','Primes liées au capital','5','55',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('552','Réserves','5','55',false);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('553','Ecart de réévaluation des immobilisations','5','55',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('571','Capital','5','57',false);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('573','Actionnaires, associés ou membres','5','57',false);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('591','Excédent ou déficit en instance d''approbation','5','59',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('592','Excédent ou déficit de l''exercice','5','59',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('593','Marge','5','59',false);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('594','Produit financier net ou charge financière nette','5','59',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('595','Excédent ou déficit d’exploitation','5','59',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('596','Excédent ou déficit exceptionnel','5','59',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('601','Charges sur opérations avec les institutions financières','6','60',false);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('602','Charges sur opérations avec les membres, bénéficiaires ou clients','6','60',false);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('603','Charges sur opérations sur titres et sur opérations diverses','6','60',false);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('604','Charges sur valeurs immobilisées','6','60',false);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('605','Charges sur fonds propres et assimilés','6','60',false);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('606','Charges sur opérations de change','6','60',false);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('607','Charges sur opérations de hors bilan','6','60',false);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('608','Charges sur prestations de services financiers','6','60',false);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('609','Autres charges d''exploitation financière','6','60',false);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('611','Achats','6','61',false);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('612','Variations de stocks','6','61',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('621','Services extérieurs','6','62',false);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('622','Autres services extérieurs','6','62',false);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('623','Charges diverses d''exploitation','6','62',false);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('631','Impôts, taxes et versements assimilés sur rémunérations','6','63',false);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('632','Autres impôts, taxes et prélèvements assimilés versés à l''Administration des impôts','6','63',false);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('633','Autres impôts, taxes et prélèvements assimilés versés aux autres organismes','6','63',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('641','Salaires et traitements','6','64',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('642','Charges sociales','6','64',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('643','Rémunérations versées aux stagiaires','6','64',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('661','Dotations aux amortissements des immobilisations','6','66',false);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('662','Dotations aux amortissements des charges à répartir','6','66',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('663','Dotations aux provisions pour dépréciation des immobilisations','6','66',false);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('664','Dotations aux provisions sur créances en souffrance','6','66',false);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('666','Dotations aux provisions pour dépréciation des autres éléments d''actif','6','66',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('667','Dotations aux provisions pour risques et charges','6','66',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('668','Dotations aux provisions réglementées','6','66',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('669','Pertes sur créances irrécouvrables','6','66',false);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('671','Charges exceptionnelles','6','67',false);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('672','Pertes sur exercices antérieurs','6','67',false);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('691','Impôts sur les excédents liés à l’activité d’épargne et de crédit','6','69',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('692','Impôts sur les excédents liés aux activités autres que l’épargne et le crédit','6','69',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('701','Produits sur opérations avec les institutions financières','7','70',false);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('702','Produits sur opérations avec les membres, bénéficiaires ou clients','7','70',false);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('703','Produits sur opérations sur titres et sur opérations diverses','7','70',false);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('704','Produits sur valeurs immobilisées','7','70',false);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('706','Produits sur opérations de change','7','70',false);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('707','Produits sur opérations de hors bilan','7','70',false);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('708','Produits sur prestations de services financiers','7','70',false);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('709','Autres produits d''exploitation financière','7','70',false);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('711','Ventes','7','71',false);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('721','Redevances sur concessions, brevets, licences, procédés, droits et valeurs similaires','7','72',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('722','Indemnités de fonction et rémunérations d''administrateurs, gérants reçues','7','72',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('725','Plus-values de cession','7','72',false);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('727','Revenus des immeubles hors exploitation','7','72',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('728','Transferts de charges d''exploitation non financière','7','72',false);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('729','Autres produits divers d''exploitation','7','72',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('731','Immobilisations incorporelles','7','73',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('732','Immobilisations corporelles','7','73',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('761','Reprises d''amortissements des immobilisations','7','76',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('763','Reprises de provisions sur immobilisations','7','76',false);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('764','Reprises de provisions sur créances en souffrance','7','76',false);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('766','Reprises de provisions pour dépréciation des autres éléments d''actif','7','76',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('767','Reprises de provisions pour risques et charges','7','76',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('768','Reprises de provisions réglementées','7','76',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('769','Récupération sur créances amorties','7','76',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('771','Produits exceptionnels','7','77',false);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('772','Profits sur exercices antérieurs','7','77',false);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('901','Engagements de financement donnés en faveur des institutions financières','9','90',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('902','Engagements de financement reçus des institutions financières','9','90',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('903','Engagements de financement donnés en faveur des membres, bénéficiaires ou clients','9','90',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('904','Engagements de financement reçus des membres, bénéficiaires ou clients','9','90',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('911','Cautions, avals et autres garanties d''ordre des institutions financières','9','91',false);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('912','Cautions, avals et autres garanties reçus des institutions financières','9','91',false);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('913','Garanties d''ordre des membres, bénéficiaires ou clients','9','91',false);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('914','Garanties reçues des membres, bénéficiaires ou clients','9','91',false);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('921','Titres à livrer','9','92',false);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('922','Titres à recevoir','9','92',false);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('931','Opérations de change au comptant','9','93',false);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('932','Opérations de change à terme','9','93',false);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('933','Opérations de prêts ou d''emprunts en devises','9','93',false);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('934','Report/déport non couru','9','93',false);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('935','Intérêts non courus en devises couverts','9','93',false);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('936','Comptes d''ajustement de devises hors bilan','9','93',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('937','Comptes de position de change hors bilan','9','93',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('938','Comptes de contre-valeur de position de change hors bilan','9','93',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('951','Autres engagements donnés','9','95',false);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('952','Autres engagements reçus','9','95',false);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('961','Opérations d''encaissement','9','96',false);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('962','Comptes de suivi des engagements consortiaux de financement donnés','9','96',false);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('963','Comptes de suivi des engagements consortiaux de garantie donnés','9','96',false);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('965','Comptes de suivi des crédits consortiaux distribués','9','96',false);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('966','Comptes de suivi des crédits distribués pour le compte de tiers','9','96',false);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('1011','Billets et monnaies émis par la BCEAO','1','101',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('1012','Billets et monnaies étrangers','1','101',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('1101','Banque Centrale','1','110',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('1111','Organe Financier/Caisse Centrale','1','111',false);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('1121','Trésor Public','1','112',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('1131','Centre des Chèques Postaux','1','113',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('1136','Dettes rattachées','1','113',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('1137','Créances rattachées','1','113',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('1141','Banques et correspondants','1','114',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('1146','Dettes rattachées','1','114',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('1147','Créances rattachées','1','114',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('1151','Etablissements Financiers','1','115',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('1156','Dettes rattachées','1','115',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('1157','Créances rattachées','1','115',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('1161','Systèmes Financiers Décentralisés','1','116',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('1166','Dettes rattachées','1','116',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('1167','Créances rattachées','1','116',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('1171','Autres institutions financières','1','117',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('1176','Dettes rattachées','1','117',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('1177','Créances rattachées','1','117',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('1261','Dépôts à terme constitués','1','126',false);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('1267','Créances rattachées','1','126',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('1271','Dépôts de garantie constitués','1','127',false);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('1277','Créances rattachées','1','127',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('1281','Autres dépôts constitués','1','128',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('1287','Créances rattachées','1','128',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('1311','Prêts à moins d’1 an','1','131',false);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('1317','Créances rattachées','1','131',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('1331','Prêts à terme','1','133',false);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('1337','Créances rattachées','1','133',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('1511','Organe Financier','1','151',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('1516','Dettes rattachées','1','151',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('1517','Créances rattachées','1','151',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('1521','Trésor Public','1','152',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('1526','Dettes rattachées','1','152',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('1527','Créances rattachées','1','152',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('1531','Centre des Chèques Postaux','1','153',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('1536','Dettes rattachées','1','153',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('1537','Créances rattachées','1','153',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('1541','Banques et correspondants','1','154',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('1546','Dettes rattachées','1','154',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('1547','Créances rattachées','1','154',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('1551','Etablissements financiers','1','155',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('1556','Dettes rattachées','1','155',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('1557','Créances rattachées','1','155',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('1561','Systèmes Financiers Décentralisés','1','156',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('1566','Dettes rattachées','1','156',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('1567','Créances rattachées','1','156',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('1571','Autres institutions financières','1','157',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('1576','Dettes rattachées','1','157',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('1577','Créances rattachées','1','157',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('1611','Dépôts à terme reçus','1','161',false);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('1616','Dettes rattachées','1','161',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('1621','Dépôts de garantie reçus','1','162',false);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('1626','Dettes rattachées','1','162',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('1651','Autres dépôts reçus','1','165',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('1656','Dettes rattachées','1','165',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('1751','E m prunts à m oins d’un an','1','175',false);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('1756','Dettes rattachées','1','175',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('1781','Emprunts à terme','1','178',false);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('1786','Dettes rattachées','1','178',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('1921','Prêts en souffrance de 0 à 3 mois au plus','1','192',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('1922','Prêts en souffrance de plus de 3 mois à 6 mois au plus','1','192',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('1991','Provisions sur prêts en souffrance de 6 mois au plus','1','199',false);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('1992','Provisions sur prêts en souffrance de plus de 6 mois à 12 mois au plus','1','199',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('1993','Provisions sur prêts en souffrance de plus de 12 mois à 24 mois au plus','1','199',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('2022','Crédits ordinaires','2','202',false);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('2023','D écouverts','2','202',false);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('2031','Crédits à m oyen terme','2','203',false);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('2037','Créances rattachées','2','203',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('2041','Crédits à long terme','2','204',false);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('2047','Créances rattachées','2','204',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('2511','Comptes ordinaires','2','251',false);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('2512','Comptes ordinaires sur livret','2','251',false);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('2521','Dépôts à terme reçus','2','252',false);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('2526','Dettes rattachées','2','252',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('2531','Livrets d''épargne','2','253',false);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('2532','Comptes d''épargne-logement','2','253',false);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('2533','Plans d''épargne-logement','2','253',false);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('2539','Autres comptes d''épargne à régime spécial','2','253',false);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('2545','Dépôts de garantie reçus','2','254',false);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('2546','Dettes rattachées','2','254',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('2551','Autres dépôts reçus','2','255',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('2556','Dettes rattachées','2','255',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('2711','Emprunts','2','271',false);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('2716','Dettes rattachées','2','271',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('2721','Dispositions à payer','2','272',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('2722','Provisions pour chèques certifiés','2','272',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('2725','Divers','2','272',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('2726','Dettes rattachées','2','272',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('2921','Crédits en souffrance de 0 à 3 mois au plus','2','292',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('2922','Crédits en souffrance de plus de 3 mois à 6 mois au plus','2','292',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('2991','Provisions sur crédits en souffrance de 6 mois au plus','2','299',false);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('2992','Provisions sur crédits en souffrance de plus de 6 mois à 12 mois au plus','2','299',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('2993','Provisions sur crédits en souffrance de plus de 12 mois à 24 mois au plus','2','299',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('3211','Stocks de biens meubles','3','321',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('3219','Provisions pour dépréciation','3','321',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('3221','Stocks de marchandises','3','322',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('3229','Provisions pour dépréciation','3','322',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('3231','Stocks de fournitures','3','323',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('3239','Provisions pour dépréciation','3','323',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('3241','Autres stocks et assimilés','3','324',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('3249','Provisions pour dépréciation','3','324',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('3311','Fournisseurs débiteurs','3','331',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('3312','Personnel, avances et acomptes','3','331',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('3313','Organismes sociaux, créances diverses','3','331',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('3314','Etat, créances diverses','3','331',false);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('3315','Organismes internationaux, créances diverses','3','331',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('3316','Autres débiteurs divers','3','331',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('3319','Autres créances en souffrance','3','331',false);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('3321','Fournisseurs','3','332',false);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('3322','Personnel','3','332',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('3323','Organismes sociaux','3','332',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('3324','Etat et collectivités publiques','3','332',false);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('3325','Organismes internationaux','3','332',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('3326','Dividendes à payer','3','332',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('3327','Autres créditeurs divers','3','332',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('3711','Valeurs à l''encaissement avec crédit immédiat','3','371',false);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('3712','Comptes de valeurs à imputer','3','371',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('3713','Valeurs à rejeter','3','371',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('3741','Comptes d''ajustement','3','374',false);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('3742','Comptes d''écarts-actif','3','374',false);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('3743','Comptes d''écarts-passif','3','374',false);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('3757','Comptes de position de change','3','375',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('3758','Comptes de contre-valeur de position de change','3','375',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('3761','Comptes d''appels de fonds sur crédits consortiaux','3','376',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('3762','Comptes de contrepartie de comptes d''appels de fonds sur crédits consortiaux','3','376',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('3791','Comptes d''attente - actif','3','379',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('3792','Comptes d''attente - passif','3','379',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('3811','Charges à répartir sur plusieurs exercices','3','381',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('3812','Charges constatées d''avance','3','381',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('3814','Comptes d''abonnement de produits','3','381',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('3815','Produits à recevoir','3','381',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('3822','Produits constatés d''avance','3','382',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('3824','Comptes d''abonnement de charges','3','382',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('3825','Charges à payer','3','382',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('4101','Prêts et titres subordonnés à terme','4','410',false);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('4102','Prêts et titres subordonnés à durée indéterminée','4','410',false);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('4107','Créances rattachées','4','410',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('4121','Titres de participation des banques et correspondants et des établissements financiers','4','412',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('4122','Titres de participation de SFD','4','412',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('4123','Titres de participation d''autres entreprises à caractère financier','4','412',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('4124','Titres de participation de sociétés immobilières','4','412',false);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('4125','Titres de participation d''autres entreprises à caractère non financier','4','412',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('4126','Versements restant à effectuer','4','412',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('4127','Créances rattachées','4','412',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('4129','Provisions pour dépréciation','4','412',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('4141','Obligations','4','414',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('4142','Autres titres à revenu fixe','4','414',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('4147','Créances rattachées','4','414',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('4149','Provisions pour dépréciation','4','414',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('4311','Immobilisations incorporelles en cours','4','431',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('4319','Provisions pour dépréciation','4','431',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('4321','Immobilisations corporelles en cours','4','432',false);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('4329','Provisions pour dépréciation','4','432',false);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('4411','Fonds commercial','4','441',false);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('4412','Frais d''établissement','4','441',false);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('4413','Autres immobilisations incorporelles','4','441',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('4418','Amortissements','4','441',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('4419','Provisions pour dépréciation','4','441',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('4421','Immobilisations corporelles','4','442',false);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('4428','Am ortissem ents','4','442',false);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('4429','Provisions pour dépréciation','4','442',false);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('4511','Fonds commercial','4','451',false);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('4513','Autres immobilisations incorporelles','4','451',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('4518','Amortissements','4','451',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('4519','Provisions pour dépréciation','4','451',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('4521','Immobilisations corporelles','4','452',false);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('4528','Am ortissem ents','4','452',false);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('4529','Provisions pour dépréciation','4','452',false);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('4531','Immobilisations incorporelles acquises par réalisation de garantie','4','453',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('4538','Amortissements','4','453',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('4539','Provisions pour dépréciation','4','453',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('4541','Immobilisations corporelles acquises par réalisation de garantie','4','454',false);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('4548','Am ortissem ents','4','454',false);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('4549','Provisions pour dépréciation','4','454',false);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('4611','Immobilisations en cours','4','461',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('4612','Crédit-bail mobilier','4','461',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('4613','Crédit-bail immobilier','4','461',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('4614','Crédit-bail sur actifs incorporels','4','461',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('4621','Immobilisations en cours','4','462',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('4622','Location avec option d''achat mobilier','4','462',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('4916','Créances en souffrance de 6 mois au plus sur opérations de crédit-bail et de location avec option d''achat','4','491',false);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('4917','Créances en souffrance de 6 mois au plus sur opérations de location-vente','4','491',false);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('4926','Créances en souffrance de plus de 6 mois à 12 mois au plus sur opérations de crédit-bail et de location avec option d''achat','4','492',false);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('4927','Créances en souffrance de plus de 6 mois à 12 mois au plus sur opérations de location-vente','4','492',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('4936','Créances en souffrance de plus de 12 mois à 24 mois au plus sur opérations de crédit-bail et de location avec option d''achat','4','493',false);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('4937','Créances en souffrance de plus de 12 mois à 24 mois au plus sur opérations de location-vente','4','493',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('4996','Provisions sur créances en souffrance sur opérations de crédit-bail et de location avec option d''achat','4','499',false);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('4997','Provisions sur créances en souffrance sur opérations de location-vente','4','499',false);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('5011','Subventions d''investissement','5','501',false);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('5012','Subventions d''investissement virées au compte de résultat','5','501',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('5021','Fonds de garantie','5','502',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('5022','Fonds d''assurance','5','502',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('5023','Fonds de bonification','5','502',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('5024','Fonds de sécurité','5','502',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('5029','Autres fonds affectés','5','502',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('5321','Emprunts et titres émis subordonnés à terme','5','532',false);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('5322','Emprunts et titres émis subordonnés à durée indéterminée','5','532',false);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('5521','Réserve générale','5','552',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('5522','Réserves facultatives','5','552',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('5523','Autres réserves','5','552',false);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('5711','Capital souscrit appelé','5','571',false);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('5712','Capital souscrit non appelé','5','571',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('5731','Actionnaires, associés ou membres, capital souscrit non appelé','5','573',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('5732','Actionnaires, associés ou membres, capital souscrit appelé non versé','5','573',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('5931','Marge d’intérêts','5','593',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('5932','Marge commerciale','5','593',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('6011','Intérêts sur comptes ordinaires chez les institutions financières','6','601',false);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('6015','Intérêts sur comptes ordinaires des institutions financières','6','601',false);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('6016','Intérêts sur autres comptes de dépôts des institutions financières','6','601',false);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('6017','Intérêts sur comptes d''em prunts','6','601',false);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('6018','Autres intérêts','6','601',false);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('6019','Commissions','6','601',false);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('6025','Intérêts sur comptes des m em bres, bénéficiaires ou clients','6','602',false);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('6027','Intérêts sur em prunts et autres sommes dues aux m em bres, bénéficiaires ou clients','6','602',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('6028','Autres intérêts','6','602',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('6029','Commissions','6','602',false);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('6031','Charges et pertes sur titres de placement','6','603',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('6038','Charges sur opérations diverses','6','603',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('6039','Commissions','6','603',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('6041','Charges sur immobilisations financières','6','604',false);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('6046','Charges sur opérations de crédit-bail et de location avec option d''achat','6','604',false);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('6047','Charges sur opérations de location-vente','6','604',false);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('6053','Charges sur emprunts et titres émis subordonnés','6','605',false);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('6061','Pertes sur opérations de change','6','606',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('6069','Commissions','6','606',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('6071','Charges sur engagements de financement reçus','6','607',false);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('6072','Charges sur engagements de garantie reçus','6','607',false);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('6073','Charges sur engagements sur titres','6','607',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('6075','Charges sur autres engagements reçus','6','607',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('6081','Charges sur les moyens de paiement','6','608',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('6089','Autres charges sur prestations de services financiers','6','608',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('6091','Moins-values sur cession d''éléments d''actif','6','609',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('6098','Transferts de produits d''exploitation financière','6','609',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('6099','Diverses charges d''exploitation financière','6','609',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('6112','Stocks vendus','6','611',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('6116','Achats non stockés de matières et fournitures','6','611',false);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('6117','Achats de marchandises','6','611',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('6118','Frais accessoires d''achat','6','611',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('6119','Rabais, remises et ristournes obtenus sur achats de marchandises','6','611',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('6211','Redevances de crédit-bail','6','621',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('6212','Loyers','6','621',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('6213','Charges locatives et de co-propriété','6','621',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('6214','Entretien et réparations','6','621',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('6215','Primes d''assurance','6','621',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('6216','Etudes et recherches','6','621',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('6217','Frais de formation','6','621',false);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('6218','Divers','6','621',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('6219','Rabais, remises et ristournes obtenus sur services extérieurs','6','621',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('6221','Personnel extérieur à l''institution','6','622',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('6222','Rémunérations d''intermédiaires et honoraires','6','622',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('6223','Publicité, publications et relations publiques','6','622',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('6224','Transports de biens','6','622',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('6225','Transports collectifs du personnel','6','622',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('6226','Déplacements, missions et réceptions','6','622',false);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('6227','Frais postaux et frais de communication','6','622',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('6228','Divers','6','622',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('6229','Rabais, remises et ristournes obtenus sur autres services extérieurs','6','622',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('6231','Redevances pour concessions, brevets, licences, procédés, droits et valeurs similaires','6','623',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('6232','Indemnités de fonction versées','6','623',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('6233','Frais de tenue des réunions des organes et des assemblées','6','623',false);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('6235','Moins-values de cession sur immobilisations','6','623',false);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('6238','Transferts de produits d''exploitation non financière','6','623',false);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('6239','Autres charges diverses d''exploitation non financière','6','623',false);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('6311','Impôts et taxes versés à l''Administration des impôts','6','631',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('6312','Impôts et taxes versés aux autres organismes','6','631',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('6321','Impôts directs','6','632',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('6323','Impôts indirects','6','632',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('6324','Droits d''enregistrement et de timbre','6','632',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('6329','Impôts et taxes divers','6','632',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('6611','Dotations aux amortissements des immobilisations d''exploitation','6','661',false);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('6612','Dotations aux amortissements des immobilisations hors exploitation','6','661',false);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('6631','Dotations aux provisions pour dépréciation des immobilisations en cours','6','663',false);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('6632','Dotations aux provisions pour dépréciation des immobilisations d''exploitation','6','663',false);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('6633','Dotations aux provisions pour dépréciation des immobilisations hors exploitation','6','663',false);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('6641','Dotations aux provisions sur créances en souffrance de 6 mois au plus','6','664',false);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('6642','Dotations aux provisions sur créances en souffrance de plus de 6 mois à 12 mois au plus','6','664',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('6643','Dotations aux provisions sur créances en souffrance de plus 12 mois à 24 mois au plus','6','664',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('6691','Pertes sur créances irrécouvrables couvertes par des provisions','6','669',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('6692','Pertes sur créances irrécouvrables non couvertes par des provisions','6','669',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('6711','Pertes causées par un cataclysme','6','671',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('6712','Charges de restructuration','6','671',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('6713','Pénalités et amendes fiscales et pénales','6','671',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('6714','Rappels d''impôts autres que l''impôt sur les excédents','6','671',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('6715','Pertes résultant d''un changement de méthode','6','671',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('6716','Pertes résultant des écarts sur caisse','6','671',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('6717','Pertes résultant des écarts sur dépôts','6','671',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('6718','Pertes résultant des écarts sur crédits','6','671',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('6719','Autres charges exceptionnelles','6','671',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('6721','Pertes d''exploitation financière','6','672',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('6722','Pertes d''exploitation non financière','6','672',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('6723','Pertes exceptionnelles','6','672',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('7011','Intérêts sur comptes ordinaires chez les institutions financières','7','701',false);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('7012','Intérêts sur autres comptes de dépôts chez les institutions financières','7','701',false);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('7013','Intérêts sur comptes de prêts aux institutions financières','7','701',false);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('7015','Intérêts sur comptes ordinaires des institutions financières','7','701',false);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('7018','Autres intérêts','7','701',false);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('7019','Commissions','7','701',false);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('7021','Intérêts sur crédits aux membres, bénéficiaires ou clients','7','702',false);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('7025','Intérêts sur comptes des membres, bénéficiaires ou clients','7','702',false);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('7028','Autres intérêts','7','702',false);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('7029','Commissions','7','702',false);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('7031','Produits et profits sur titres de placement','7','703',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('7038','Produits sur opérations diverses','7','703',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('7039','Commissions','7','703',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('7041','Produits sur les immobilisations financières','7','704',false);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('7046','Produits sur opérations de crédit-bail et de location avec option d''achat','7','704',false);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('7047','Produits sur opérations de location-vente','7','704',false);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('7061','Gains sur opérations de change','7','706',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('7069','Commissions','7','706',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('7071','Produits sur engagements de financement donnés','7','707',false);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('7072','Produits sur engagements de garantie donnés','7','707',false);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('7073','Produits sur engagements sur titres','7','707',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('7075','Produits sur autres engagements donnés','7','707',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('7076','Produits sur opérations effectuées pour le compte de tiers','7','707',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('7081','Produits sur les moyens de paiement','7','708',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('7089','Autres produits sur prestations de services financiers','7','708',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('7091','Plus - values sur cession d''éléments d''actif','7','709',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('7098','Transferts de charges d''exploitation','7','709',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('7099','Divers produits d''exploitation','7','709',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('7111','Ventes de marchandises','7','711',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('7118','Produits accessoires d''achat','7','711',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('7119','Rabais, remises et ristournes accordés sur ventes de marchandises','7','711',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('7251','sur immobilisations incorporelles et corporelles','7','725',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('7252','sur immobilisations financières','7','725',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('7281','Charges refacturées','7','728',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('7282','Charges à répartir sur plusieurs exercices','7','728',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('7289','Autres transferts de charges','7','728',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('7631','Reprises de provisions sur immobilisations en cours','7','763',false);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('7632','Reprises de provisions sur immobilisations d''exploitation','7','763',false);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('7633','Reprises de provisions sur immobilisations hors exploitation','7','763',false);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('7641','Reprises de provisions sur créances en souffrance de 6 mois au plus','7','764',false);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('7642','Reprises de provisions sur créances en souffrance de plus de 6 mois à 12 mois au plus','7','764',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('7643','Reprises de provisions sur créances en souffrance de plus de 12 mois à 24 mois au plus','7','764',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('7711','Dédits, pénalités et libéralités perçus','7','771',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('7712','Subventions d''équilibre','7','771',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('7713','Dégrèvement d''impôts autres que l’impôt sur les excédents','7','771',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('7714','Quote-part des subventions d''investissement virée au résultat de l''exercice','7','771',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('7715','Produits résultant d''un changement de méthode d''évaluation','7','771',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('7716','Produits résultant des écarts sur caisse','7','771',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('7717','Produits résultant des écarts sur dépôts','7','771',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('7718','Produits résultant des écarts sur crédits','7','771',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('7719','Autres produits exceptionnels','7','771',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('7721','Profits d''exploitation financière','7','772',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('7722','Profits d''exploitation non financière','7','772',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('7723','Profits exceptionnels','7','772',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('9112','Confirmations d''ouverture de crédits documentaires','9','911',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('9113','Acceptations à payer','9','911',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('9119','Autres garanties données','9','911',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('9121','Cautions et avals reçus','9','912',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('9122','Contre-garanties reçues sur les crédits distribués','9','912',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('9123','Contre-garanties reçues des engagements par signature donnés','9','912',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('9124','Autres garanties irrévocables et inconditionnelles reçues','9','912',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('9132','Obligations cautionnées','9','913',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('9133','Cautions, avals et autres garanties donnés','9','913',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('9134','Garanties de remboursement de crédits','9','913',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('9139','Autres garanties données','9','913',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('9141','Garanties reçues de l''Etat et des organismes assimilés','9','914',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('9142','Garanties reçues des entreprises d''assurance et de capitalisation','9','914',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('9149','Autres garanties reçues','9','914',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('9211','Interventions à l''émission','9','921',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('9212','Marché gris','9','921',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('9219','Autres titres à livrer','9','921',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('9221','Interventions à l''émission','9','922',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('9222','Marché gris','9','922',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('9229','Autres titres à recevoir','9','922',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('9311','Francs CFA achetés non encore reçus','9','931',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('9312','Devises achetées non encore reçues','9','931',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('9313','Francs CFA vendus non encore livrés','9','931',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('9314','Devises vendues non encore livrées','9','931',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('9321','Francs CFA à recevoir contre devises à livrer','9','932',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('9322','Devises à recevoir contre francs CFA à livrer','9','932',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('9323','Devises à recevoir contre devises à livrer','9','932',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('9324','Devises à livrer contre devises à recevoir','9','932',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('9331','Devises prêtées non encore livrées','9','933',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('9332','Devises empruntées non encore reçues','9','933',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('9341','Report/déport à recevoir','9','934',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('9342','Report/déport à payer','9','934',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('9351','Intérêts non courus en devises couverts à recevoir','9','935',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('9352','Intérêts non courus en devises couverts à payer','9','935',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('9513','Loyers à payer','9','951',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('9519','Engagements divers donnés','9','951',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('9522','Valeurs reçues en garantie','9','952',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('9523','Loyers à percevoir','9','952',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('9529','Engagements divers reçus','9','952',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('9611','Valeurs à l''encaissement reçues des membres, bénéficiaires ou clients et non disponibles','9','961',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('9612','Comptes des membres, bénéficiaires ou clients exigibles après encaissement','9','961',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('9613','Valeurs à l''encaissement reçues des correspondants et non disponibles','9','961',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('9614','Comptes des correspondants exigibles après encaissement','9','961',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('9621','Engagements de financement','9','962',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('9622','Part de chef de file','9','962',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('9623','Parts des co-participants','9','962',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('9631','Engagements de garantie donnés','9','963',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('9632','Part de chef de file','9','963',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('9633','Parts des co-participants','9','963',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('9651','Crédits consortiaux','9','965',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('9652','Part de chef de file','9','965',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('9653','Parts des co-participants','9','965',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('9659','Echéances impayées','9','965',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('9661','Crédits distribués pour le compte de tiers','9','966',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('9662','Ressources affectées aux crédits distribués pour le compte de tiers','9','966',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('11111','Organe Financier','1','1111',false);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('11112','Caisse Centrale','1','1111',false);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('12611','Dépôts à terme constitués de 0 à 6 mois au plus','1','1261',false);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('12612','Dépôts à terme constitués de plus de 6 mois à 12 mois au plus','1','1261',false);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('12613','Dépôts à terme constitués de plus d’1 an à 2 ans au plus','1','1261',false);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('12614','Dépôts à terme constitués de plus de 2 ans à 3 ans au plus','1','1261',false);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('12615','Dépôts à terme constitués de plus de 3 ans à 10 ans au plus','1','1261',false);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('12616','Dépôts à terme constitués de plus de 10 ans','1','1261',false);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('12711','Dépôts de garantie constitués de 0 à 6 mois au plus','1','1271',false);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('12712','Dépôts de garantie constitués de plus de 6 mois à 12 mois au plus','1','1271',false);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('12713','Dépôts de garantie constitués de plus d’1 an à 2 ans au plus','1','1271',false);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('12714','Dépôts de garantie constitués de plus de 2 ans à 3 ans au plus','1','1271',false);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('12715','Dépôts de garantie constitués de plus de 3 ans à 10 ans au plus','1','1271',false);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('12716','Dépôts de garantie constitués de plus de 10 ans','1','1271',false);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('13111','Prêts à moins d’1 an à l’Organe Financier/Caisse Centrale','1','1311',false);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('13112','Prêts à moins d’1 an aux banques et correspondants','1','1311',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('13113','Prêts à moins d’1 an aux SFD','1','1311',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('13114','Prêts à moins d’1 an à d’autres institutions financières','1','1311',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('13311','Prêts à terme à l’Organe Financier/Caisse Centrale','1','1331',false);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('13312','Prêts à terme aux banques et correspondants','1','1331',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('13313','Prêts à terme aux SFD','1','1331',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('13314','Prêts à terme à d’autres institutions financières','1','1331',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('16111','Dépôts à terme reçus de 0 à 6 mois au plus','1','1611',false);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('16112','Dépôts à terme reçus de plus de 6 mois à 12 mois au plus','1','1611',false);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('16113','Dépôts à terme reçus de plus d’1 an à 2 ans au plus','1','1611',false);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('16114','Dépôts à terme reçus de plus de 2 ans à 3 ans au plus','1','1611',false);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('16115','Dépôts à terme reçus de plus de 3 ans à 10 ans au plus','1','1611',false);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('16116','Dépôts à terme reçus de plus de 10 ans','1','1611',false);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('16211','Dépôts de garantie reçus de 0 à 6 mois au plus','1','1621',false);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('16212','Dépôts de garantie reçus de plus de 6 mois à 12 mois au plus','1','1621',false);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('16213','Dépôts de garantie reçus de plus d’1 an à 2 ans au plus','1','1621',false);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('16214','Dépôts de garantie reçus de plus de 2 ans à 3 ans au plus','1','1621',false);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('16215','Dépôts de garantie reçus de plus de 3 ans à 10 ans au plus','1','1621',false);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('16216','Dépôts de garantie reçus de plus de 10 ans','1','1621',false);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('17511','Emprunts à moins d’un an auprès de l’Organe Financier/Caisse Centrale','1','1751',false);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('17512','Emprunts à moins d’un an auprès des banques et correspondants','1','1751',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('17513','Emprunts à moins d’un an auprès des SFD','1','1751',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('17514','Emprunts à moins d’un an auprès d’autres institutions financières','1','1751',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('17811','Emprunts à terme auprès de l’Organe Financier/Caisse Centrale','1','1781',false);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('17812','Emprunts à terme auprès des banques et correspondants','1','1781',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('17813','Emprunts à terme auprès des SFD','1','1781',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('17814','Emprunts à terme auprès d’autres institutions financières','1','1781',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('19911','Provisions sur prêts en souffrance de 0 à 3 mois au plus','1','1991',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('19912','Provisions sur prêts en souffrance de plus 3 mois à 6 mois au plus','1','1991',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('20221','Crédits ordinaires','2','2022',false);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('20227','Créances rattachées','2','2022',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('20231','Découverts','2','2023',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('20237','Créances rattachées','2','2023',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('20311','Crédits à moyen terme de plus d’1 an à 2 ans au plus','2','2031',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('20312','Crédits à moyen terme de plus de 2 ans à 3 ans au plus','2','2031',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('20411','Crédits à long terme de plus de 3 ans à 10 ans au plus','2','2041',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('20412','Crédits à long terme de plus de 10 ans','2','2041',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('25111','Comptes ordinaires','2','2511',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('25116','Dettes rattachées','2','2511',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('25117','Créances rattachées','2','2511',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('25121','Comptes ordinaires','2','2512',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('25126','Dettes rattachées','2','2512',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('25211','Dépôts à terme reçus de 0 à 6 mois au plus','2','2521',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('25212','Dépôts à terme reçus de plus de 6 mois à 12 mois au plus','2','2521',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('25213','Dépôts à terme reçus de plus d’1 an à 2 ans au plus','2','2521',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('25214','Dépôts à terme reçus de plus de 2 ans à 3 ans au plus','2','2521',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('25215','Dépôts à terme reçus de plus de 3 ans à 10 ans au plus','2','2521',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('25216','Dépôts à terme reçus de plus de 10 ans','2','2521',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('25311','Livrets d''épargne','2','2531',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('25316','Dettes rattachées','2','2531',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('25321','Comptes d''épargne-logement','2','2532',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('25326','Dettes rattachées','2','2532',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('25331','Plans d''épargne-logement','2','2533',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('25336','Dettes rattachées','2','2533',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('25391','Autres comptes d''épargne à régime spécial','2','2539',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('25396','Dettes rattachées','2','2539',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('25451','Dépôts de garantie reçus de 0 à 6 mois au plus','2','2545',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('25452','Dépôts de garantie reçus de plus de 6 mois à 12 mois au plus','2','2545',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('25453','Dépôts de garantie reçus de plus d’1 an à 2 ans au plus','2','2545',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('25454','Dépôts de garantie reçus de plus de 2 ans à 3 ans au plus','2','2545',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('25455','Dépôts de garantie reçus de plus de 3 ans à 10 ans au plus','2','2545',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('25456','Dépôts de garantie reçus de plus de 10 ans','2','2545',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('27111','Emprunts à moins d’un an','2','2711',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('27112','Emprunts à terme','2','2711',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('29911','Provisions sur crédits en souffrance de 0 à 3 mois au plus','2','2991',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('29912','Provisions sur crédits en souffrance de plus de 3 mois à 6 mois au plus','2','2991',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('33141','Avances et acomptes versés sur impôts et taxes directs','3','3314',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('33142','Avances et acomptes versés sur impôts et taxes indirects','3','3314',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('33143','Autres créances diverses','3','3314',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('33191','Autres créances en souffrance','3','3319',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('33199','Provisions pour dépréciation','3','3319',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('33211','Fournisseurs d’exploitation','3','3321',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('33212','Fournisseurs d’investissement','3','3321',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('33213','Fournisseurs - factures non parvenues','3','3321',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('33214','Fournisseurs - Avances et acomptes versés','3','3321',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('33241','Impôts et taxes directs','3','3324',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('33242','Impôts et taxes indirects','3','3324',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('33243','Autres impôts et taxes','3','3324',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('37111','reçues des membres, bénéficiaires ou clients','3','3711',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('37112','reçues des correspondants','3','3711',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('37411','Comptes d''ajustement devises','3','3741',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('37421','Comptes d''écarts sur devises garantis','3','3742',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('37429','Autres comptes d''écarts sur devises','3','3742',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('37431','Comptes d''écarts sur devises garantis','3','3743',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('37439','Autres comptes d''écarts sur devises','3','3743',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('41012','Prêts subordonnés à terme','4','4101',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('41014','Titres subordonnés à terme','4','4101',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('41022','Prêts subordonnés à durée indéterminée','4','4102',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('41024','Titres subordonnés à durée indéterminée','4','4102',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('41241','Titres de participation de sociétés immobilières d''exploitation','4','4124',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('41242','Titres de participation de sociétés immobilières hors exploitation','4','4124',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('43211','Aménagements de terrain en cours','4','4321',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('43212','Bâtiments et installations en cours','4','4321',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('43213','Matériels en cours','4','4321',false);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('43291','Provisions pour dépréciation des immobilisations corporelles en cours','4','4329',false);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('44111','Droit au bail','4','4411',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('44112','Autres éléments du fonds commercial','4','4411',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('44121','Frais de constitution','4','4412',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('44122','Frais de modification du capital','4','4412',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('44123','Frais de fonctionnement antérieurs au démarrage','4','4412',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('44124','Frais divers d’établissement','4','4412',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('44211','Terrains','4','4421',false);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('44212','Bâtiments, installations techniques et agencements','4','4421',false);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('44213','Matériel','4','4421',false);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('44281','Amortissements des terrains','4','4428',false);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('44282','Amortissements des bâtiments, installations techniques et agencements','4','4428',false);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('44283','Amortissements des matériels','4','4428',false);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('44291','Provisions des terrains','4','4429',false);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('44292','Provisions des bâtiments, installations techniques et agencements','4','4429',false);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('44293','Provisions des matériels','4','4429',false);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('45111','Droit au bail','4','4511',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('45112','Autres éléments du fonds commercial','4','4511',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('45211','Terrains','4','4521',false);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('45212','Bâtiments, installations techniques et agencements','4','4521',false);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('45213','Matériel','4','4521',false);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('45281','Amortissements des terrains','4','4528',false);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('45282','Amortissements des bâtiments, installations techniques et agencements','4','4528',false);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('45283','Amortissements des matériels','4','4528',false);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('45291','Provisions des terrains','4','4529',false);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('45292','Provisions des bâtiments, installations techniques et agencements','4','4529',false);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('45293','Provisions des matériels','4','4529',false);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('45411','Terrains','4','4541',false);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('45412','Bâtiments, installations techniques et agencements','4','4541',false);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('45413','Matériel','4','4541',false);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('45481','Amortissements des terrains','4','4548',false);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('45482','Amortissements des bâtiments, installations techniques et agencements','4','4548',false);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('45483','Amortissements des matériels','4','4548',false);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('45491','Provisions des terrains','4','4549',false);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('45492','Provisions des bâtiments, installations techniques et agencements','4','4549',false);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('45493','Provisions des matériels','4','4549',false);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('49161','Créances en souffrance de 6 mois au plus sur opérations de crédit-bail','4','4916',false);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('49162','Créances en souffrance de 6 mois au plus sur opérations de location avec option d''achat','4','4916',false);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('49261','Créances en souffrance de plus de 6 mois à 12 mois au plus sur opérations de crédit-bail','4','4926',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('49262','Créances en souffrance de plus de 6 mois à 12 mois au plus sur opérations de location avec option d''achat','4','4926',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('49361','Créances en souffrance de plus de 12 mois à 24 mois au plus sur opérations de crédit-bail','4','4936',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('49362','Créances en souffrance de plus de 12 mois à 24 mois au plus sur opérations de location avec option d''achat','4','4936',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('49961','Provisions sur créances en souffrance de 6 mois au plus','4','4996',false);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('49962','Provisions sur créances en souffrance de plus de 6 mois à 12 mois au plus','4','4996',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('49963','Provisions sur créances en souffrance de plus de 12 mois à 24 mois au plus','4','4996',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('49971','Provisions sur créances en souffrance de 6 mois au plus','4','4997',false);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('49972','Provisions sur créances en souffrance de plus de 6 mois à 12 mois au plus','4','4997',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('49973','Provisions sur créances en souffrance de plus de 12 mois à 24 mois au plus','4','4997',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('50111','Subventions d''investissement reçues de l’Etat','5','5011',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('50112','Subventions d''investissement reçues d’Organismes internationaux','5','5011',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('50113','Autres subventions d''investissement','5','5011',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('53212','Emprunts émis subordonnés à terme','5','5321',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('53214','Titres émis subordonnés à terme','5','5321',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('53222','Emprunts émis subordonnés à durée indéterminée','5','5322',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('53224','Titres émis subordonnés à durée indéterminée','5','5322',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('55231','Réserves statutaires','5','5523',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('55232','Autres réserves','5','5523',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('57111','capital souscrit appelé versé','5','5711',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('57112','capital appelé souscrit non versé','5','5711',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('60111','Intérêts sur comptes ordinaires chez l’organe financier','6','6011',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('60112','Intérêts sur comptes ordinaires chez la Caisse Centrale','6','6011',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('60113','Intérêts sur comptes ordinaires chez les CCP','6','6011',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('60114','Intérêts sur comptes ordinaires chez les banques et correspondants','6','6011',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('60115','Intérêts sur comptes ordinaires chez les établissements financiers','6','6011',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('60116','Intérêts sur comptes ordinaires chez les SFD','6','6011',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('60117','Intérêts sur comptes ordinaires chez les autres institutions financières','6','6011',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('60151','Intérêts sur comptes ordinaires de l’organe financier','6','6015',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('60152','Intérêts sur comptes ordinaires du Trésor Public','6','6015',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('60153','Intérêts sur comptes ordinaires des CCP','6','6015',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('60154','Intérêts sur comptes ordinaires des banques et correspondants','6','6015',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('60155','Intérêts sur comptes ordinaires des établissements financiers','6','6015',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('60156','Intérêts sur comptes ordinaires des SFD','6','6015',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('60157','Intérêts sur comptes ordinaires d’autres institutions financières','6','6015',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('60161','Intérêts sur dépôts à terme reçus','6','6016',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('60162','Intérêts sur dépôts de garantie reçus','6','6016',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('60165','Intérêts sur autres dépôts reçus','6','6016',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('60175','Intérêts sur emprunts à moins d’un an','6','6017',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('60178','Intérêts sur emprunts à terme','6','6017',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('60189','Divers intérêts','6','6018',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('60191','Cotisations','6','6019',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('60193','Autres commissions','6','6019',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('60251','Intérêts sur comptes ordinaires créditeurs','6','6025',false);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('60252','Intérêts sur dépôts à terme reçus','6','6025',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('60253','Intérêts sur comptes d’épargne à régime spécial','6','6025',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('60254','Intérêts sur dépôts de garantie reçus','6','6025',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('60255','Intérêts sur autres dépôts reçus','6','6025',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('60291','Cotisations','6','6029',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('60293','Autres commissions','6','6029',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('60411','Frais d''acquisition','6','6041',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('60412','Etalement de la prime','6','6041',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('60461','Charges sur crédit-bail','6','6046',false);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('60462','Charges sur location avec option d''achat','6','6046',false);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('60463','Charges sur opérations de location simple','6','6046',false);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('60464','Charges sur immobilisations non louées','6','6046',false);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('60471','Charges sur immobilisations en cours','6','6047',false);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('60472','Charges sur location-vente','6','6047',false);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('60473','Charges sur opérations de location simple','6','6047',false);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('60474','Charges sur immobilisations non louées','6','6047',false);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('60532','Charges sur emprunts et titres émis subordonnés','6','6053',false);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('60712','Charges sur engagements de financement reçus des institutions financières','6','6071',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('60714','Charges sur engagements de financement reçus des membres, clients ou bénéficiaires','6','6071',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('60722','Charges sur engagements de garantie reçus des institutions financières','6','6072',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('60724','Charges sur engagements de garantie reçus des membres, bénéficiaires ou clients','6','6072',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('61161','Carburant et lubrifiants','6','6116',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('61162','Autres matières et fournitures','6','6116',false);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('62171','Frais de formation du personnel','6','6217',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('62172','Frais de formation des membres','6','6217',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('62173','Frais de formation des élus','6','6217',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('62261','Déplacements','6','6226',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('62262','Missions','6','6226',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('62263','Réceptions','6','6226',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('62331','Perdiem','6','6233',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('62332','Transport','6','6233',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('62333','Hébergement','6','6233',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('62334','Téléphone','6','6233',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('62335','Carburant','6','6233',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('62339','Autres','6','6233',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('62351','sur immobilisations corporelles et incorporelles','6','6235',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('62352','sur immobilisations financières','6','6235',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('62381','Produits rétrocédés','6','6238',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('62389','Autres transferts de produits','6','6238',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('62391','Dons','6','6239',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('62392','Autres charges diverses d’exploitation','6','6239',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('66111','Dotations aux amortissements des immobilisations incorporelles d''exploitation','6','6611',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('66112','Dotations aux amortissements des immobilisations corporelles d''exploitation','6','6611',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('66121','Dotations aux amortissements des immobilisations incorporelles hors exploitation','6','6612',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('66122','Dotations aux amortissements des immobilisations corporelles hors exploitation','6','6612',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('66311','Dotations aux provisions pour dépréciation des immobilisations incorporelles en cours','6','6631',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('66312','Dotations aux provisions pour dépréciation des immobilisations corporelles en cours','6','6631',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('66321','Dotations aux provisions pour dépréciation des immobilisations incorporelles d''exploitation','6','6632',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('66322','Dotations aux provisions pour dépréciation des immobilisations corporelles d''exploitation','6','6632',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('66331','Dotations aux provisions pour dépréciation des immobilisations incorporelles hors exploitation','6','6633',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('66332','Dotations aux provisions pour dépréciation des immobilisations corporelles hors exploitation','6','6633',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('66411','Dotations aux provisions sur créances en souffrance de 0 à 3 mois au plus','6','6641',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('66412','Dotations aux provisions sur créances en souffrance de plus de 3 mois à 6 mois au plus','6','6641',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('70111','Intérêts sur comptes ordinaires chez l’organe financier','7','7011',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('70112','Intérêts sur comptes ordinaires chez la caisse centrale','7','7011',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('70113','Intérêts sur comptes ordinaires chez les CCP','7','7011',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('70114','Intérêts sur comptes ordinaires chez les banques et correspondants','7','7011',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('70115','Intérêts sur comptes ordinaires chez les établissements financiers','7','7011',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('70116','Intérêts sur comptes ordinaires chez les SFD','7','7011',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('70117','Intérêts sur comptes ordinaires chez les autres institutions financières','7','7011',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('70126','Intérêts sur dépôts à terme constitués','7','7012',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('70127','Intérêts sur dépôts de garantie constitués','7','7012',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('70128','Intérêts sur autres dépôts constitués','7','7012',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('70131','Intérêts sur prêts à moins d’un an','7','7013',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('70133','Intérêts sur prêts à terme','7','7013',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('70151','Intérêts sur comptes ordinaires de l’organe financier','7','7015',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('70152','Intérêts sur comptes ordinaires du Trésor public','7','7015',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('70153','Intérêts sur comptes ordinaires du Centre des Chèques Postaux','7','7015',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('70154','Intérêts sur comptes ordinaires des banques et correspondants','7','7015',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('70155','Intérêts sur comptes ordinaires des établissements financiers','7','7015',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('70156','Intérêts sur comptes ordinaires des SFD','7','7015',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('70157','Intérêts sur comptes ordinaires d’autres institutions financières','7','7015',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('70189','Divers intérêts','7','7018',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('70191','Cotisations et droits d’adhésion','7','7019',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('70192','Commissions sur transfert d’argent','7','7019',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('70193','Autres commissions','7','7019',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('70212','intérêts sur crédits à court terme','7','7021',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('70213','Intérêts sur crédits à moyen terme','7','7021',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('70214','Intérêts sur crédits à long terme','7','7021',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('70251','Intérêts sur comptes ordinaires','7','7025',false);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('70289','Divers intérêts','7','7028',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('70291','Cotisations et droits d’adhésion','7','7029',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('70292','Commissions sur transfert d’argent','7','7029',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('70293','Autres commissions','7','7029',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('70410','Produits et profits sur prêts et titres subordonnés','7','7041',false);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('70412','Dividendes et produits assimilés sur titres de participation','7','7041',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('70414','Produits et profits sur titres d''investissement','7','7041',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('70461','Produits sur crédit-bail','7','7046',false);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('70462','Produits sur location avec option d''achat','7','7046',false);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('70463','Produits sur location simple','7','7046',false);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('70464','Produits sur immobilisations non louées','7','7046',false);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('70472','Produits sur location-vente','7','7047',false);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('70473','Produits sur location simple','7','7047',false);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('70474','Produits sur immobilisations non louées','7','7047',false);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('70711','Produits sur engagements de financement donnés aux institutions financières','7','7071',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('70713','Produits sur engagements de financement donnés aux membres, bénéficiaires ou clients','7','7071',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('70721','Produits sur engagements de garantie donnés aux institutions financières','7','7072',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('70723','Produits sur engagements de garantie donnés aux membres, bénéficiaires ou clients','7','7072',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('76311','Reprises de provisions sur immobilisations incorporelles en cours','7','7631',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('76312','Reprises de provisions sur immobilisations corporelles en cours','7','7631',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('76321','Reprises de provisions sur immobilisations incorporelles d''exploitation','7','7632',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('76322','Reprises de provisions sur immobilisations corporelles d''exploitation','7','7632',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('76331','Reprises de provisions sur immobilisations incorporelles hors exploitation','7','7633',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('76332','Reprises de provisions sur immobilisations corporelles hors exploitation','7','7633',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('76411','Reprises de provisions sur créances en souffrance de 0 à 3 mois au plus','7','7641',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('76412','Reprises de provisions sur créances en souffrance de plus de 3 mois à 6 mois au plus','7','7641',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('111111','Organe Financier','1','11111',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('111116','Dettes rattachées','1','11111',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('111117','Créances rattachées','1','11111',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('111121','Caisse Centrale','1','11112',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('111126','Dettes rattachées','1','11112',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('111127','Créances rattachées','1','11112',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('126111','Dépôts à terme constitués de 0 à 6 mois au plus chez l’organe financier','1','12611',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('126112','Dépôts à terme constitués de 0 à 6 mois au plus au Trésor public','1','12611',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('126113','Dépôts à terme constitués de 0 à 6 mois au plus chez les CCP','1','12611',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('126114','Dépôts à terme constitués de 0 à 6 mois au plus chez les banques et correspondants','1','12611',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('126115','Dépôts à terme constitués de 0 à 6 mois au plus chez les établissements financiers','1','12611',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('126116','Dépôts à terme constitués de 0 à 6 mois au plus chez les SFD','1','12611',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('126117','Dépôts à terme constitués de 0 à 6 mois au plus chez les autres institutions financières','1','12611',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('126121','Dépôts à terme constitués de plus de 6 mois à 12 mois au plus chez l’organe financier','1','12612',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('126122','Dépôts à terme constitués de plus de 6 mois à 12 mois au plus au Trésor Public','1','12612',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('126123','Dépôts à terme constitués de plus de 6 mois à 12 mois au plus chez les CCP','1','12612',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('126124','Dépôts à terme constitués de plus de 6 mois à 12 mois au plus chez les banques et correspondants','1','12612',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('126125','Dépôts à terme constitués de plus de 6 mois à 12 mois au plus chez les établissements financiers','1','12612',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('126126','Dépôts à terme constitués de plus de 6 mois à 12 mois au plus chez les SFD','1','12612',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('126127','Dépôts à terme constitués de plus de 6 mois à 12 mois au plus chez les autres institutions financières','1','12612',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('126131','Dépôts à terme constitués de plus d’1 an à 2 ans au plus chez l’organe Financier','1','12613',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('126132','Dépôts à terme constitués de plus d’1 an à 2 ans au plus au Trésor Public','1','12613',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('126133','Dépôts à terme constitués de plus d’1 an à 2 ans au plus chez les CCP','1','12613',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('126134','Dépôts à terme constitués de plus d’1 an à 2 ans au plus chez les banques et correspondants','1','12613',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('126135','Dépôts à terme constitués de plus d’1 an à 2 ans au plus chez les établissements financiers','1','12613',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('126136','Dépôts à terme constitués de plus d’1 an à 2 ans au plus chez les SFD','1','12613',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('126137','Dépôts à terme constitués de plus d’1 an à 2 ans au plus chez les autres institutions financières','1','12613',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('126141','Dépôts à terme constitués de plus de 2 ans à 3 ans au plus chez l’organe financier','1','12614',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('126142','Dépôts à terme constitués de plus de 2 ans à 3 ans au plus au Trésor Public','1','12614',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('126143','Dépôts à terme constitués de plus de 2 ans à 3 ans au plus chez les CCP','1','12614',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('126144','Dépôts à terme constitués de plus de 2 ans à 3 ans au plus chez les banques et correspondants','1','12614',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('126145','Dépôts à terme constitués de plus de 2 ans à 3 ans au plus chez les établissements financiers','1','12614',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('126146','Dépôts à terme constitués de plus de 2 ans à 3 ans au plus chez les SFD','1','12614',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('126147','Dépôts à terme constitués de plus de 2 ans à 3 ans au plus chez les autres institutions financières','1','12614',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('126151','Dépôts à terme constitués de plus de 3 ans à 10 ans au plus chez l’organe financier','1','12615',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('126152','Dépôts à terme constitués de plus de 3 ans à 10 ans au plus au Trésor Public','1','12615',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('126153','Dépôts à terme constitués de plus de 3 ans à 10 ans au plus chez les CCP','1','12615',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('126154','Dépôts à terme constitués de plus de 3 ans à 10 ans au plus chez les banques et correspondants','1','12615',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('126155','Dépôts à terme constitués de plus de 3 ans à 10 ans au plus chez les établissements financiers','1','12615',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('126156','Dépôts à terme constitués de plus de 3 ans à 10 ans au plus chez les SFD','1','12615',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('126157','Dépôts à terme constitués de plus de 3 ans à 10 ans au plus chez les autres institutions financières','1','12615',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('126161','Dépôts à terme constitués de plus de 10 ans chez l’organe financier','1','12616',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('126162','Dépôts à terme constitués de plus de 10 ans au Trésor Public','1','12616',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('126163','Dépôts à terme constitués de plus de 10 ans chez les CCP','1','12616',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('126164','Dépôts à terme constitués de plus de 10 ans chez les banques et correspondants','1','12616',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('126165','Dépôts à terme constitués de plus de 10 ans chez les établissements financiers','1','12616',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('126166','Dépôts à terme constitués de plus de 10 ans chez les SFD','1','12616',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('126167','Dépôts à terme constitués de plus de 10 ans chez les autres institutions financières','1','12616',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('127111','Dépôts de garantie constitués de 0 à 6 mois au plus chez l’organe financier','1','12711',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('127112','Dépôts de garantie constitués de 0 à 6 mois au plus au Trésor Public','1','12711',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('127113','Dépôts de garantie constitués de 0 à 6 mois au plus chez les CCP','1','12711',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('127114','Dépôts de garantie constitués de 0 à 6 mois au plus chez les banques et correspondants','1','12711',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('127115','Dépôts de garantie constitués de 0 à 6 mois au plus chez les établissements financiers','1','12711',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('127116','Dépôts de garantie constitués de 0 à 6 mois au plus chez les SFD','1','12711',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('127117','Dépôts de garantie constitués de 0 à 6 mois au plus chez les autres institutions financières','1','12711',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('127121','Dépôts de garantie constitués de plus de 6 mois à 12 mois au plus chez l’organe financier','1','12712',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('127122','Dépôts de garantie constitués de plus de 6 mois à 12 mois au plus au Trésor Public','1','12712',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('127123','Dépôts de garantie constitués de plus de 6 mois à 12 mois au plus chez les CCP','1','12712',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('127124','Dépôts de garantie constitués de plus de 6 mois à 12 mois au plus chez les banques et correspondants','1','12712',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('127125','Dépôts de garantie constitués de plus de 6 mois à 12 mois au plus chez les établissements financiers','1','12712',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('127126','Dépôts de garantie constitués de plus de 6 mois à 12 mois au plus chez les SFD','1','12712',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('127127','Dépôts de garantie constitués de plus de 6 mois à 12 mois au plus chez les autres institutions financières','1','12712',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('127131','Dépôts de garantie constitués de plus d’1 an à 2 ans au plus chez l’organe financier','1','12713',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('127132','Dépôts de garantie constitués de plus d’1 an à 2 ans au plus au Trésor Public','1','12713',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('127133','Dépôts de garantie constitués de plus d’1 an à 2 ans au plus chez les CCP','1','12713',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('127134','Dépôts de garantie constitués de plus d’1 an à 2 ans au plus chez les banques et correspondants','1','12713',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('127135','Dépôts de garantie constitués de plus d’1 an à 2 ans au plus chez les établissements financiers','1','12713',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('127136','Dépôts de garantie constitués de plus d’1 an à 2 ans au plus chez les SFD','1','12713',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('127137','Dépôts de garantie constitués de plus d’1 an à 2 ans au plus chez les autres institutions financières','1','12713',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('127141','Dépôts de garantie constitués de plus de 2 ans à 3 ans au plus chez l’organe financier','1','12714',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('127142','Dépôts de garantie constitués de plus de 2 ans à 3 ans au plus au Trésor Public','1','12714',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('127143','Dépôts de garantie constitués de plus de 2 ans à 3 ans au plus chez les CCP','1','12714',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('127144','Dépôts de garantie constitués de plus de 2 ans à 3 ans au plus chez les banques et correspondants','1','12714',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('127145','Dépôts de garantie constitués de plus de 2 ans à 3 ans au plus chez les établissements financiers','1','12714',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('127146','Dépôts de garantie constitués de plus de 2 ans à 3 ans au plus chez les SFD','1','12714',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('127147','Dépôts de garantie constitués de plus de 2 ans à 3 ans au plus chez les autres institutions financières','1','12714',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('127151','Dépôts de garantie constitués de plus de 3 ans à 10 ans au plus chez l’organe financier','1','12715',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('127152','Dépôts de garantie constitués de plus de 3 ans à 10 ans au plus au Trésor Public','1','12715',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('127153','Dépôts de garantie constitués de plus de 3 ans à 10 ans au plus chez les CCP','1','12715',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('127154','Dépôts de garantie constitués de plus de 3 ans à 10 ans au plus chez les banques et correspondants','1','12715',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('127155','Dépôts de garantie constitués de plus de 3 ans à 10 ans au plus chez les établissements financiers','1','12715',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('127156','Dépôts de garantie constitués de plus de 3 ans à 10 ans au plus chez les SFD','1','12715',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('127157','Dépôts de garantie constitués de plus de 3 ans à 10 ans au plus chez les autres institutions financières','1','12715',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('127161','Dépôts de garantie constitués de plus de 10 ans chez l’organe financier','1','12716',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('127162','Dépôts de garantie constitués de plus de 10 ans au Trésor Public','1','12716',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('127163','Dépôts de garantie constitués de plus de 10 ans chez les CCP','1','12716',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('127164','Dépôts de garantie constitués de plus de 10 ans chez les banques et correspondants','1','12716',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('127165','Dépôts de garantie constitués de plus de 10 ans chez les établissements financiers','1','12716',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('127166','Dépôts de garantie constitués de plus de 10 ans chez les SFD','1','12716',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('127167','Dépôts de garantie constitués de plus de 10 ans chez les autres institutions financières','1','12716',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('131111','Prêts à moins d’1 an à l’Organe Financier','1','13111',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('131112','Prêts à moins d’1 an à la Caisse Centrale','1','13111',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('133111','Prêts à terme à l’Organe Financier','1','13311',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('133112','Prêts à terme à la Caisse Centrale','1','13311',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('161111','Dépôts à terme reçus de 0 à 6 mois au plus de l’organe financier','1','16111',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('161112','Dépôts à terme reçus de 0 à 6 mois au plus du Trésor Public','1','16111',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('161113','Dépôts à terme reçus de 0 à 6 mois au plus des CCP','1','16111',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('161114','Dépôts à terme reçus de 0 à 6 mois au plus des banques et correspondants','1','16111',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('161115','Dépôts à terme reçus de 0 à 6 mois au plus des établissements financiers','1','16111',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('161116','Dépôts à terme reçus de 0 à 6 mois au plus des SFD','1','16111',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('161117','Dépôts à terme reçus de 0 à 6 mois au plus des autres institutions financières','1','16111',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('161121','Dépôts à terme reçus de plus de 6 mois à 12 mois au plus de l’organe financier','1','16112',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('161122','Dépôts à terme reçus de plus de 6 mois à 12 mois au plus du Trésor Public','1','16112',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('161123','Dépôts à terme reçus de plus de 6 mois à 12 mois au plus des CCP','1','16112',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('161124','Dépôts à terme reçus de plus de 6 mois à 12 mois au plus des banques et correspondants','1','16112',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('161125','Dépôts à terme reçus de plus de 6 mois à 12 mois au plus des établissements financiers','1','16112',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('161126','Dépôts à terme reçus de plus de 6 mois à 12 mois au plus des SFD','1','16112',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('161127','Dépôts à terme reçus de plus de 6 mois à 12 mois au plus des autres institutions financières','1','16112',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('161131','Dépôts à terme reçus de plus d’1 an à 2 ans au plus de l’organe financier','1','16113',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('161132','Dépôts à terme reçus de plus d’1 an à 2 ans au plus du Trésor Public','1','16113',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('161133','Dépôts à terme reçus de plus d’1 an à 2 ans au plus des CCP','1','16113',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('161134','Dépôts à terme reçus de plus d’1 an à 2 ans au plus des banques et correspondants','1','16113',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('161135','Dépôts à terme reçus de plus d’1 an à 2 ans au plus des établissements financiers','1','16113',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('161136','Dépôts à terme reçus de plus d’1 an à 2 ans au plus des SFD','1','16113',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('161137','Dépôts à terme reçus de plus d’1 an à 2 ans au plus des autres institutions financières','1','16113',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('161141','Dépôts à terme reçus de plus de 2 ans à 3 ans au plus de l’organe financier','1','16114',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('161142','Dépôts à terme reçus de plus de 2 ans à 3 ans au plus du Trésor Public','1','16114',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('161143','Dépôts à terme reçus de plus de 2 ans à 3 ans au plus des CCP','1','16114',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('161144','Dépôts à terme reçus de plus de 2 ans à 3 ans au plus des banques et correspondants','1','16114',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('161145','Dépôts à terme reçus de plus de 2 ans à 3 ans au plus des établissements financiers','1','16114',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('161146','Dépôts à terme reçus de plus de 2 ans à 3 ans au plus des SFD','1','16114',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('161147','Dépôts à terme reçus de plus de 2 ans à 3 ans au plus des autres institutions financières','1','16114',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('161151','Dépôts à terme reçus de plus de 3 ans à 10 ans au plus de l’organe financier','1','16115',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('161152','Dépôts à terme reçus de plus de 3 ans à 10 ans au plus du Trésor Public','1','16115',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('161153','Dépôts à terme reçus de plus de 3 ans à 10 ans au plus des CCP','1','16115',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('161154','Dépôts à terme reçus de plus de 3 ans à 10 ans au plus des banques et correspondants','1','16115',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('161155','Dépôts à terme reçus de plus de 3 ans à 10 ans au plus des établissements financiers','1','16115',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('161156','Dépôts à terme reçus de plus de 3 ans à 10 ans au plus des SFD','1','16115',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('161157','Dépôts à terme reçus de plus de 3 ans à 10 ans au plus des autres institutions financières','1','16115',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('161161','Dépôts à terme reçus de plus de 10 ans de l’organe financier','1','16116',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('161162','Dépôts à terme reçus de plus de 10 ans du Trésor Public','1','16116',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('161163','Dépôts à terme reçus de plus de 10 ans des CCP','1','16116',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('161164','Dépôts à terme reçus de plus de 10 ans des banques et correspondants','1','16116',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('161165','Dépôts à terme reçus de plus de 10 ans des établissements financiers','1','16116',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('161166','Dépôts à terme reçus de plus de 10 ans des SFD','1','16116',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('161167','Dépôts à terme reçus de plus de 10 ans des autres institutions financières','1','16116',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('162111','Dépôts de garantie reçus de 0 à 6 mois au plus de l’organe financier','1','16211',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('162112','Dépôts de garantie reçus de 0 à 6 mois au plus du Trésor Public','1','16211',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('162113','Dépôts de garantie reçus de 0 à 6 mois au plus des CCP','1','16211',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('162114','Dépôts de garantie reçus de 0 à 6 mois au plus des banques et correspondants','1','16211',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('162115','Dépôts de garantie reçus de 0 à 6 mois au plus des établissements financiers','1','16211',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('162116','Dépôts de garantie reçus de 0 à 6 mois au plus des SFD','1','16211',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('162117','Dépôts de garantie reçus de 0 à 6 mois au plus des autres institutions financières','1','16211',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('162121','Dépôts de garantie reçus de plus de 6 mois à 12 mois au plus de l’organe financier','1','16212',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('162122','Dépôts de garantie reçus de plus de 6 mois à 12 mois au plus du Trésor Public','1','16212',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('162123','Dépôts de garantie reçus de plus de 6 mois à 12 mois au plus des CCP','1','16212',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('162124','Dépôts de garantie reçus de plus de 6 mois à 12 mois au plus des banques et correspondants','1','16212',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('162125','Dépôts de garantie reçus de plus de 6 mois à 12 mois au plus des établissements financiers','1','16212',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('162126','Dépôts de garantie reçus de plus de 6 mois à 12 mois au plus des SFD','1','16212',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('162127','Dépôts de garantie reçus de plus de 6 mois à 12 mois au plus des autres institutions financières','1','16212',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('162131','Dépôts de garantie reçus de plus d’1 an à 2 ans au plus de l’organe financier','1','16213',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('162132','Dépôts de garantie reçus de plus d’1 an à 2 ans au plus du Trésor Public','1','16213',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('162133','Dépôts de garantie reçus de plus d’1 an à 2 ans au plus des CCP','1','16213',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('162134','Dépôts de garantie reçus de plus d’1 an à 2 ans au plus des banques et correspondants','1','16213',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('162135','Dépôts de garantie reçus de plus d’1 an à 2 ans au plus des établissements financiers','1','16213',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('162136','Dépôts de garantie reçus de plus d’1 an à 2 ans au plus des SFD','1','16213',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('162137','Dépôts de garantie reçus de plus d’1 an à 2 ans au plus des autres institutions financières','1','16213',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('162141','Dépôts de garantie reçus de plus de 2 ans à 3 ans au plus de l’organe financier','1','16214',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('162142','Dépôts de garantie reçus de plus de 2 ans à 3 ans au plus du Trésor Public','1','16214',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('162143','Dépôts de garantie reçus de plus de 2 ans à 3 ans au plus des CCP','1','16214',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('162144','Dépôts de garantie reçus de plus de 2 ans à 3 ans au plus des banques et correspondants','1','16214',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('162145','Dépôts de garantie reçus de plus de 2 ans à 3 ans au plus des établissements financiers','1','16214',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('162146','Dépôts de garantie reçus de plus de 2 ans à 3 ans au plus des SFD','1','16214',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('162147','Dépôts de garantie reçus de plus de 2 ans à 3 ans au plus des autres institutions financières','1','16214',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('162151','Dépôts de garantie reçus de plus de 3 ans à 10 ans au plus de l’organe financier','1','16215',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('162152','Dépôts de garantie reçus de plus de 3 ans à 10 ans au plus du Trésor Public','1','16215',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('162153','Dépôts de garantie reçus de plus de 3 ans à 10 ans au plus des CCP','1','16215',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('162154','Dépôts de garantie reçus de plus de 3 ans à 10 ans au plus des banques et correspondants','1','16215',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('162155','Dépôts de garantie reçus de plus de 3 ans à 10 ans au plus des établissements financiers','1','16215',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('162156','Dépôts de garantie reçus de plus de 3 ans à 10 ans au plus des SFD','1','16215',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('162157','Dépôts de garantie reçus de plus de 3 ans à 10 ans au plus des autres institutions financières','1','16215',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('162161','Dépôts de garantie reçus de plus de 10 ans de l’organe financier','1','16216',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('162162','Dépôts de garantie reçus de plus de 10 ans du Trésor Public','1','16216',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('162163','Dépôts de garantie reçus de plus de 10 ans des CCP','1','16216',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('162164','Dépôts de garantie reçus de plus de 10 ans des banques et correspondants','1','16216',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('162165','Dépôts de garantie reçus de plus de 10 ans des établissements financiers','1','16216',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('162166','Dépôts de garantie reçus de plus de 10 ans des SFD','1','16216',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('162167','Dépôts de garantie reçus de plus de 10 ans des autres institutions financières','1','16216',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('175111','Emprunts à moins d’un an auprès de l’Organe Financier','1','17511',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('175112','Emprunts à moins d’un an auprès de la Caisse Centrale','1','17511',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('178111','Emprunts à terme auprès de l’Organe Financier','1','17811',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('178112','Emprunts à terme auprès de la Caisse Centrale','1','17811',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('202211','Crédits à court terme de 0 à 6 mois au plus','2','20221',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('202212','Crédits à court terme de plus de 6 mois à 12 mois au plus','2','20221',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('432131','Matériel et outillage industriel et commercial en cours','4','43213',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('432132','Matériel et outillage agricole en cours','4','43213',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('432133','Matériel d’emballage récupérable et identifiable en cours','4','43213',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('432134','Matériel et mobilier de bureau en cours','4','43213',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('432135','Matériel de transport en cours','4','43213',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('432136','Immobilisations animales et agricoles en cours','4','43213',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('432137','Agencements et aménagements du matériel en cours','4','43213',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('432138','Autres matériels en cours','4','43213',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('432911','Provisions pour dépréciation des aménagements de terrains en cours','4','43291',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('432912','Provisions pour dépréciation des bâtiments et installations en cours','4','43291',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('432913','Provisions pour dépréciation de matériels en cours','4','43291',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('442111','Terrains agricoles et forestiers','4','44211',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('442112','Terrains nus','4','44211',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('442113','Terrains bâtis','4','44211',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('442114','Travaux de mise en valeur des terrains','4','44211',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('442115','Terrains de gisement','4','44211',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('442116','Terrains aménagés','4','44211',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('442117','Terrains mis en concession','4','44211',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('442118','Autres terrains','4','44211',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('442121','Bâtiments industriels, agricoles, administratifs et commerciaux sur sol propre','4','44212',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('442122','Bâtiments industriels, agricoles, administratifs et commerciaux sur sol d’autrui','4','44212',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('442123','Ouvrages d’infrastructure','4','44212',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('442124','Installations techniques','4','44212',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('442125','Aménagements de bureaux','4','44212',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('442126','Bâtiments industriels, agricoles et commerciaux mis en concession','4','44212',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('442127','Autres installations et agencements','4','44212',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('442131','Matériel et outillage industriel et commercial','4','44213',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('442132','Matériel et outillage agricole','4','44213',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('442133','Matériel d’emballage récupérable et identifiable','4','44213',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('442134','Matériel et mobilier de bureau','4','44213',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('442135','Matériel de transport','4','44213',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('442136','Immobilisations animales et agricoles','4','44213',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('442137','Agencements et aménagements du matériel','4','44213',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('442138','Autres matériels','4','44213',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('442811','Amortissements des terrains agricoles et forestiers','4','44281',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('442814','Amortissements des travaux de mise en valeur des terrains','4','44281',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('442815','Amortissements des terrains de gisement','4','44281',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('442821','Amortissements des bâtiments industriels, agricoles, administratifs et commerciaux sur sol propre','4','44282',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('442822','Amortissements des bâtiments industriels, agricoles, administratifs et commerciaux sur sol d’autrui','4','44282',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('442823','Amortissements des ouvrages d’infrastructure','4','44282',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('442824','Amortissements des installations techniques','4','44282',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('442825','Amortissements des aménagements de bureaux','4','44282',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('442826','Amortissements des bâtiments industriels, agricoles et commerciaux mis en concession','4','44282',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('442827','Amortissements des autres installations et agencements','4','44282',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('442831','Amortissements du matériel et outillage industriel et commercial','4','44283',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('442832','Amortissements du matériel et outillage agricole','4','44283',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('442833','Amortissements du matériel d’emballage récupérable et identifiable','4','44283',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('442834','Amortissements du matériel et mobilier de bureau','4','44283',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('442835','Amortissements du matériel de transport','4','44283',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('442836','Amortissements des immobilisations animales et agricoles','4','44283',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('442837','Amortissements des agencements et aménagements du matériel','4','44283',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('442838','Amortissements des autres matériels','4','44283',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('442911','Provisions des terrains agricoles et forestiers','4','44291',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('442912','Provisions des terrains nus','4','44291',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('442913','Provisions des terrains bâtis','4','44291',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('442914','Provisions des travaux de mise en valeur des terrains','4','44291',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('442915','Provisions des terrains de gisement','4','44291',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('442916','Provisions des terrains aménagés','4','44291',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('442917','Provisions des terrains mis en concession','4','44291',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('442918','Provisions des autres terrains','4','44291',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('442921','Provisions des bâtiments industriels, agricoles, administratifs et commerciaux sur sol propre','4','44292',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('442922','Provisions des bâtiments industriels, agricoles, administratifs et commerciaux sur sol d’autrui','4','44292',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('442923','Provisions des ouvrages d’infrastructure','4','44292',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('442924','Provisions des installations techniques','4','44292',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('442925','Provisions des aménagements de bureaux','4','44292',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('442926','Provisions des bâtiments industriels, agricoles et commerciaux mis en concession','4','44292',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('442927','Provisions des autres installations et agencements','4','44292',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('442931','Provisions du matériel et outillage industriel et commercial','4','44293',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('442932','Provisions du matériel et outillage agricole','4','44293',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('442933','Provisions du matériel d’emballage récupérable et identifiable','4','44293',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('442934','Provisions du matériel et mobilier de bureau','4','44293',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('442935','Provisions du matériel de transport','4','44293',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('442936','Provisions des immobilisations animales et agricoles','4','44293',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('442937','Provisions des agencements et aménagements du matériel','4','44293',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('442938','Provisions des autres matériels','4','44293',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('452111','Terrains agricoles et forestiers','4','45211',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('452112','Terrains nus','4','45211',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('452113','Terrains bâtis','4','45211',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('452114','Travaux de mise en valeur des terrains','4','45211',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('452115','Terrains de gisement','4','45211',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('452116','Terrains aménagés','4','45211',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('452117','Terrains mis en concession','4','45211',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('452118','Autres terrains','4','45211',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('452121','Bâtiments industriels, agricoles, administratifs et commerciaux sur sol propre','4','45212',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('452122','Bâtiments industriels, agricoles, administratifs et commerciaux sur sol d’autrui','4','45212',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('452123','Ouvrages d’infrastructure','4','45212',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('452124','Installations techniques','4','45212',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('452125','Aménagements de bureaux','4','45212',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('452126','Bâtiments industriels, agricoles et commerciaux mis en concession','4','45212',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('452127','Autres installations et agencements','4','45212',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('452131','Matériel et outillage industriel et commercial','4','45213',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('452132','Matériel et outillage agricole','4','45213',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('452133','Matériel d’emballage récupérable et identifiable','4','45213',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('452134','Matériel et mobilier de bureau','4','45213',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('452135','Matériel de transport','4','45213',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('452136','Immobilisations animales et agricoles','4','45213',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('452137','Agencements et aménagements du matériel','4','45213',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('452138','Autres matériels','4','45213',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('452811','Amortissements des terrains agricoles et forestiers','4','45281',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('452814','Amortissements des travaux de mise en valeur des terrains','4','45281',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('452815','Amortissements des terrains de gisement','4','45281',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('452821','Amortissements des bâtiments industriels, agricoles, administratifs et commerciaux sur sol propre','4','45282',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('452822','Amortissements des bâtiments industriels, agricoles, administratifs et commerciaux sur sol d’autrui','4','45282',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('452823','Amortissements des ouvrages d’infrastructure','4','45282',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('452824','Amortissements des installations techniques','4','45282',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('452825','Amortissements des aménagements de bureaux','4','45282',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('452826','Amortissements des bâtiments industriels, agricoles et commerciaux mis en concession','4','45282',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('452827','Amortissements des autres installations et agencements','4','45282',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('452831','Amortissements du matériel et outillage industriel et commercial','4','45283',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('452832','Amortissements du matériel et outillage agricole','4','45283',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('452833','Amortissements du matériel d’emballage récupérable et identifiable','4','45283',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('452834','Amortissements du matériel et mobilier de bureau','4','45283',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('452835','Amortissements du matériel de transport','4','45283',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('452836','Amortissements des immobilisations animales et agricoles','4','45283',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('452837','Amortissements des agencements et aménagements du matériel','4','45283',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('452838','Amortissements des autres matériels','4','45283',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('452911','Provisions des terrains agricoles et forestiers','4','45291',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('452912','Provisions des terrains nus','4','45291',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('452913','Provisions des terrains bâtis','4','45291',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('452914','Provisions des travaux de mise en valeur des terrains','4','45291',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('452915','Provisions des terrains de gisement','4','45291',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('452916','Provisions des terrains aménagés','4','45291',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('452917','Provisions des terrains mis en concession','4','45291',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('452918','Provisions des autres terrains','4','45291',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('452921','Provisions des bâtiments industriels, agricoles, administratifs et commerciaux sur sol propre','4','45292',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('452922','Provisions des bâtiments industriels, agricoles, administratifs et commerciaux sur sol d’autrui','4','45292',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('452923','Provisions des ouvrages d’infrastructure','4','45292',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('452924','Provisions des installations techniques','4','45292',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('452925','Provisions des aménagements de bureaux','4','45292',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('452926','Provisions des bâtiments industriels, agricoles et commerciaux mis en concession','4','45292',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('452927','Provisions des autres installations et agencements','4','45292',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('452931','Provisions du matériel et outillage industriel et commercial','4','45293',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('452932','Provisions du matériel et outillage agricole','4','45293',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('452933','Provisions du matériel d’emballage récupérable et identifiable','4','45293',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('452934','Provisions du matériel et mobilier de bureau','4','45293',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('452935','Provisions du matériel de transport','4','45293',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('452936','Provisions des immobilisations animales et agricoles','4','45293',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('452937','Provisions des agencements et aménagements du matériel','4','45293',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('452938','Provisions des autres matériels','4','45293',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('454111','Terrains agricoles et forestiers','4','45411',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('454112','Terrains nus','4','45411',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('454113','Terrains bâtis','4','45411',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('454114','Travaux de mise en valeur des terrains','4','45411',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('454115','Terrains de gisement','4','45411',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('454116','Terrains aménagés','4','45411',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('454117','Terrains mis en concession','4','45411',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('454118','Autres terrains','4','45411',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('454121','Bâtiments industriels, agricoles, administratifs et commerciaux sur sol propre','4','45412',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('454122','Bâtiments industriels, agricoles, administratifs et commerciaux sur sol d’autrui','4','45412',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('454123','Ouvrages d’infrastructure','4','45412',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('454124','Installations techniques','4','45412',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('454125','Aménagements de bureaux','4','45412',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('454126','Bâtiments industriels, agricoles et commerciaux mis en concession','4','45412',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('454127','Autres installations et agencements','4','45412',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('454131','Matériel et outillage industriel et commercial','4','45413',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('454132','Matériel et outillage agricole','4','45413',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('454133','Matériel d’emballage récupérable et identifiable','4','45413',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('454134','Matériel et mobilier de bureau','4','45413',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('454135','Matériel de transport','4','45413',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('454136','Immobilisations animales et agricoles','4','45413',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('454137','Agencements et aménagements du matériel','4','45413',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('454138','Autres matériels','4','45413',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('454811','Amortissements des terrains agricoles et forestiers','4','45481',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('454814','Amortissements des travaux de mise en valeur des terrains','4','45481',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('454815','Amortissements des terrains de gisement','4','45481',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('454821','Amortissements des bâtiments industriels, agricoles, administratifs et commerciaux sur sol propre','4','45482',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('454822','Amortissements des bâtiments industriels, agricoles, administratifs et commerciaux sur sol d’autrui','4','45482',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('454823','Amortissements des ouvrages d’infrastructure','4','45482',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('454824','Amortissements des installations techniques','4','45482',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('454825','Amortissements des aménagements de bureaux','4','45482',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('454826','Amortissements des bâtiments industriels, agricoles et commerciaux mis en concession','4','45482',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('454827','Amortissements des autres installations et agencements','4','45482',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('454831','Amortissements du matériel et outillage industriel et commercial','4','45483',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('454832','Amortissements du matériel et outillage agricole','4','45483',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('454833','Amortissements du matériel d’emballage récupérable et identifiable','4','45483',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('454834','Amortissements du matériel et mobilier de bureau','4','45483',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('454835','Amortissements du matériel de transport','4','45483',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('454836','Amortissements des immobilisations animales et agricoles','4','45483',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('454837','Amortissements des agencements et aménagements du matériel','4','45483',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('454838','Amortissements des autres matériels','4','45483',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('454911','Provisions des terrains agricoles et forestiers','4','45491',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('454912','Provisions des terrains nus','4','45491',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('454913','Provisions des terrains bâtis','4','45491',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('454914','Provisions des travaux de mise en valeur des terrains','4','45491',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('454915','Provisions des terrains de gisement','4','45491',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('454916','Provisions des terrains aménagés','4','45491',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('454917','Provisions des terrains mis en concession','4','45491',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('454918','Provisions des autres terrains','4','45491',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('454921','Provisions des bâtiments industriels, agricoles, administratifs et commerciaux sur sol propre','4','45492',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('454922','Provisions des bâtiments industriels, agricoles, administratifs et commerciaux sur sol d’autrui','4','45492',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('454923','Provisions des ouvrages d’infrastructure','4','45492',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('454924','Provisions des installations techniques','4','45492',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('454925','Provisions des aménagements de bureaux','4','45492',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('454926','Provisions des bâtiments industriels, agricoles et commerciaux mis en concession','4','45492',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('454927','Provisions des autres installations et agencements','4','45492',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('454931','Provisions du matériel et outillage industriel et commercial','4','45493',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('454932','Provisions du matériel et outillage agricole','4','45493',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('454933','Provisions du matériel d’emballage récupérable et identifiable','4','45493',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('454934','Provisions du matériel et mobilier de bureau','4','45493',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('454935','Provisions du matériel de transport','4','45493',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('454936','Provisions des immobilisations animales et agricoles','4','45493',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('454937','Provisions des agencements et aménagements du matériel','4','45493',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('454938','Provisions des autres matériels','4','45493',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('491611','Créances en souffrance de 0 à 3 mois au plus sur opérations de crédit-bail','4','49161',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('491612','Créances en souffrance de plus de 3 mois à 6 mois au plus sur opérations de crédit-bail','4','49161',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('491621','Créances en souffrance de 0 à 3 mois au plus sur opérations de location avec option d''achat','4','49162',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('491622','Créances en souffrance de plus de 3 mois à 6 mois au plus sur opérations de location avec option d''achat','4','49162',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('491711','Créances en souffrance de 0 à 3 mois au plus sur opérations de location-vente','4','4917',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('491712','Créances en souffrance de plus de 3 mois à 6 mois au plus sur opérations de location-vente','4','4917',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('499611','Provisions sur créances en souffrance de 0 à 3 mois au plus','4','49961',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('499612','Provisions sur créances en souffrance de plus de 3 mois à 6 mois au plus','4','49961',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('499711','Provisions sur créances en souffrance de 0 à 3 mois au plus','4','49971',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('499712','Provisions sur créances en souffrance de plus de 3 mois à 6 mois au plus','4','49971',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('602511','Intérêts sur comptes ordinaires créditeurs','6','60251',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('602512','Intérêts sur comptes ordinaires sur livrets créditeurs','6','60251',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('604611','Dotations aux amortissements','6','60461',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('604612','Dotations aux provisions','6','60461',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('604613','Moins-values de cession','6','60461',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('604619','Autres charges','6','60461',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('604621','Dotations aux amortissements','6','60462',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('604622','Dotations aux provisions','6','60462',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('604623','Moins-values de cession','6','60462',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('604629','Autres charges','6','60462',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('604631','Dotations aux amortissements','6','60463',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('604632','Dotations aux provisions','6','60463',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('604633','Moins-values de cession','6','60463',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('604639','Autres charges','6','60463',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('604641','Dotations aux amortissements','6','60464',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('604642','Dotations aux provisions','6','60464',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('604643','Moins-values de cession','6','60464',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('604649','Autres charges','6','60464',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('604712','Dotations aux provisions','6','60471',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('604713','Moins-values de cession','6','60471',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('604719','Autres charges','6','60471',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('604721','Dotations aux amortissements','6','60472',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('604722','Dotations aux provisions','6','60472',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('604723','Moins-values de cession','6','60472',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('604729','Autres charges','6','60472',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('604731','Dotations aux amortissements','6','60473',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('604732','Dotations aux provisions','6','60473',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('604733','Moins-values de cession','6','60473',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('604739','Autres charges','6','60473',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('604741','Dotations aux amortissements','6','60474',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('604742','Dotations aux provisions','6','60474',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('604743','Moins-values de cession','6','60474',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('604749','Autres charges','6','60474',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('605321','Charges sur emprunts et titres émis subordonnés à terme','6','60532',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('605322','Charges sur emprunts et titres émis subordonnés à durée indéterminée','6','60532',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('611621','Fournitures non stockables - Eau','6','61162',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('611622','Fournitures non stockables - Electricité','6','61162',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('611623','Fournitures non stockables - Autres énergies','6','61162',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('702511','Intérêts sur comptes ordinaires','7','70251',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('704101','Produits et profits sur prêts et titres subordonnés à terme','7','70410',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('704102','Produits et profits sur prêts et titres subordonnés à durée indéterminée','7','70410',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('704611','Loyers','7','70461',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('704612','Reprises de provisions','7','70461',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('704613','Plus-values de cession','7','70461',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('704619','Autres produits','7','70461',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('704621','Loyers','7','70462',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('704622','Reprises de provisions','7','70462',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('704623','Plus-values de cession','7','70462',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('704629','Autres produits','7','70462',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('704631','Loyers','7','70463',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('704632','Reprises de provisions','7','70463',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('704633','Plus-values de cession','7','70463',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('704639','Autres produits','7','70463',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('704642','Reprises de provisions','7','70464',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('704643','Plus-values de cession','7','70464',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('704649','Autres produits','7','70464',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('704721','Loyers','7','70472',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('704722','Reprises de provisions','7','70472',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('704723','Plus-values de cession','7','70472',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('704729','Autres produits','7','70472',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('704731','Loyers','7','70473',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('704732','Reprises de provisions','7','70473',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('704733','Plus-values de cession','7','70473',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('704739','Autres produits','7','70473',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('704742','Reprises de provisions','7','70474',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('704743','Plus-values de cession','7','70474',true);
INSERT INTO compte_comptable(code,libelle,classe,parent,imputable) VALUES ('704749','Autres produits','7','70474',true);

-- =====================================================================
-- MODULE 07_virement.sql
-- =====================================================================
-- =====================================================================
-- 07_virement.sql
-- Virements entre épargne tontine (cycle) et épargne classique (compte).
-- Règles : BRIEF_CLAUDE_CODE.md section 3.5.
--   Tontine -> épargne : retrait de cycle sans décaissement, même circuit d'écarts ; le compte est crédité
--     selon le livret (montant +/- écart) ; le cycle passe à « retiré ».
--   Épargne -> tontine : lignes de livret d'origine « virement », sans agent. Types 1 et 2 : montant multiple
--     de la mise, une ligne par mise. Type 3 : une ligne. Même client obligatoire.
-- Dépend de : 00 à 03 (retrait, exécution, mouvements d'épargne).
-- =====================================================================
SET search_path = mf, public;

CREATE TABLE virement (
  id              serial PRIMARY KEY,
  agence_id       smallint NOT NULL REFERENCES agence(id),
  sens            varchar(20) NOT NULL CHECK (sens IN ('cycle_vers_epargne','epargne_vers_cycle')),
  cycle_id        integer NOT NULL REFERENCES cycle(id),
  compte_id       integer NOT NULL REFERENCES compte_epargne(id),
  montant         numeric(14,0) NOT NULL CHECK (montant > 0),   -- net machine (cycle -> épargne) ou montant viré
  montant_credite numeric(14,0),                                -- crédité sur le compte (selon le livret)
  statut          varchar(10) NOT NULL DEFAULT 'demande' CHECK (statut IN ('demande','execute','annule')),
  retrait_id      integer REFERENCES retrait(id),
  date_operation  date,
  utilisateur_id  integer REFERENCES utilisateur(id),
  cree_le         timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX virement_cycle ON virement (cycle_id);
CREATE UNIQUE INDEX virement_retrait ON virement (retrait_id) WHERE retrait_id IS NOT NULL;

-- Épargne classique -> tontine. Retourne l'id du virement.
CREATE FUNCTION virement_epargne_vers_tontine(p_compte integer, p_cycle integer, p_montant numeric,
                                              p_date date DEFAULT current_date,
                                              p_utilisateur integer DEFAULT NULL) RETURNS integer
LANGUAGE plpgsql AS $$
DECLARE c mf.cycle; ce mf.compte_epargne; v_mise numeric; v_n integer; v_nb integer; v_idx integer;
        v_id integer; v_k integer; v_montant_ligne numeric;
BEGIN
  SELECT * INTO c FROM mf.cycle WHERE id = p_cycle FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'cycle % inconnu', p_cycle; END IF;
  SELECT * INTO ce FROM mf.compte_epargne WHERE id = p_compte;
  IF NOT FOUND THEN RAISE EXCEPTION 'compte % inconnu', p_compte; END IF;
  IF ce.client_id <> c.client_id THEN RAISE EXCEPTION 'le compte % n''appartient pas au client du cycle %', ce.numero, c.numero; END IF;
  IF c.statut <> 'en_cours' THEN RAISE EXCEPTION 'cycle % non en cours', c.numero; END IF;
  IF p_montant <= 0 THEN RAISE EXCEPTION 'montant invalide'; END IF;

  IF c.type_cycle = 3 THEN
    v_n := 1; v_montant_ligne := p_montant;
  ELSE
    v_mise := mf.mise_a_date(p_cycle, p_date);
    IF mod(p_montant, v_mise) <> 0 THEN
      RAISE EXCEPTION 'le montant % n''est pas un multiple de la mise (%)', p_montant, v_mise;
    END IF;
    v_n := (p_montant / v_mise)::integer; v_montant_ligne := v_mise;
  END IF;
  SELECT count(*) INTO v_nb FROM mf.ligne_collecte WHERE cycle_id = p_cycle;
  IF v_nb + v_n > c.nb_lignes_prevues THEN
    RAISE EXCEPTION 'le livret n''a plus assez de lignes libres (% prévues, % utilisées, % demandées)', c.nb_lignes_prevues, v_nb, v_n;
  END IF;

  INSERT INTO mf.virement(agence_id, sens, cycle_id, compte_id, montant, montant_credite, statut, date_operation, utilisateur_id)
  VALUES (c.agence_id, 'epargne_vers_cycle', p_cycle, p_compte, p_montant, p_montant, 'execute', p_date, p_utilisateur)
  RETURNING id INTO v_id;

  -- sortie du compte d'abord : le contrôle du disponible refuse si les fonds manquent
  INSERT INTO mf.mouvement_epargne(compte_id, type, montant, date_operation, libelle, reference)
  VALUES (p_compte, 'virement_sortant', p_montant, p_date, 'Virement vers cycle ' || c.numero, 'virement:' || v_id);

  SELECT COALESCE(max((page - 1) * 31 + no_ligne), 0) INTO v_idx FROM mf.ligne_collecte WHERE cycle_id = p_cycle;
  FOR v_k IN 1..v_n LOOP
    v_idx := v_idx + 1;
    INSERT INTO mf.ligne_collecte(cycle_id, page, no_ligne, date_collecte, agent_id, origine, montant_collecte)
    VALUES (p_cycle, (v_idx - 1) / 31 + 1, (v_idx - 1) % 31 + 1, p_date, NULL, 'virement', v_montant_ligne);
  END LOOP;
  RETURN v_id;
END $$;

-- Tontine -> épargne classique : crée la demande de retrait (sans décaissement) et le virement associé.
-- Le circuit se poursuit comme tout retrait : constater_sans_ecart ou enregistrer_ecart_retrait / traiter,
-- puis executer_retrait.
CREATE FUNCTION demander_virement_cycle_vers_epargne(p_cycle integer, p_compte integer,
                                                     p_utilisateur integer DEFAULT NULL,
                                                     p_date date DEFAULT current_date) RETURNS integer
LANGUAGE plpgsql AS $$
DECLARE c mf.cycle; ce mf.compte_epargne; v_retrait integer; v_montant numeric; v_id integer;
BEGIN
  SELECT * INTO c FROM mf.cycle WHERE id = p_cycle FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'cycle % inconnu', p_cycle; END IF;
  SELECT * INTO ce FROM mf.compte_epargne WHERE id = p_compte;
  IF NOT FOUND THEN RAISE EXCEPTION 'compte % inconnu', p_compte; END IF;
  IF ce.client_id <> c.client_id THEN RAISE EXCEPTION 'le compte % n''appartient pas au client du cycle %', ce.numero, c.numero; END IF;
  IF ce.statut <> 'actif' THEN RAISE EXCEPTION 'compte % non actif', ce.numero; END IF;
  v_retrait := mf.demander_retrait_cycle(p_cycle, 'virement_vers_epargne', p_date);
  SELECT montant INTO v_montant FROM mf.retrait WHERE id = v_retrait;
  IF v_montant <= 0 THEN RAISE EXCEPTION 'rien à virer : net du cycle nul'; END IF;
  INSERT INTO mf.virement(agence_id, sens, cycle_id, compte_id, montant, statut, retrait_id, utilisateur_id)
  VALUES (c.agence_id, 'cycle_vers_epargne', p_cycle, p_compte, v_montant, 'demande', v_retrait, p_utilisateur)
  RETURNING id INTO v_id;
  RETURN v_id;
END $$;

-- Appelée par executer_retrait (02) : crédite le compte selon le livret.
CREATE FUNCTION exec_virement_vers_epargne(p_retrait integer) RETURNS void
LANGUAGE plpgsql AS $$
DECLARE r mf.retrait; v mf.virement;
BEGIN
  SELECT * INTO r FROM mf.retrait WHERE id = p_retrait;
  SELECT * INTO v FROM mf.virement WHERE retrait_id = p_retrait FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'aucun virement lié au retrait %', p_retrait; END IF;
  IF r.montant_paye > 0 THEN
    INSERT INTO mf.mouvement_epargne(compte_id, type, montant, date_operation, libelle, reference)
    VALUES (v.compte_id, 'virement_entrant', r.montant_paye, r.date_operation,
            'Virement du cycle ' || (SELECT numero FROM mf.cycle WHERE id = r.cycle_id), 'virement:' || v.id);
  END IF;
  UPDATE mf.virement SET montant_credite = r.montant_paye, statut = 'execute', date_operation = r.date_operation WHERE id = v.id;
END $$;

-- =====================================================================
-- MODULE 08_credit_epargne.sql
-- =====================================================================
-- =====================================================================
-- 08_credit_epargne.sql
-- Crédit sur épargne classique : produits, demandes, garantie bloquée sur le compte, déblocage
-- (sur compte ou en espèces), prélèvement automatique, saisie de la garantie, remboursement en espèces.
-- Règles : BRIEF_CLAUDE_CODE.md sections 3.4 et 3.6.
--   solde disponible = solde - solde minimum du produit - garanties bloquées (un trigger refuse toute sortie
--   au-delà, voir 01) ; prélèvement : dû complet seulement ; espèces : paiement partiel accepté ;
--   saisie après jours_saisie_garantie de retard ; libération quand le crédit est soldé.
-- Dépend de : 00 à 03, 05 (numérotation).
-- =====================================================================
SET search_path = mf, public;

INSERT INTO parametre(cle, valeur, description) VALUES
  ('seuil_validation_credit', '1000000000',
   'Montant au-delà duquel un validateur est obligatoire pour approuver une demande (PROVISOIRE : pratiquement désactivé)');

CREATE TABLE produit_credit_epargne (
  id                 serial PRIMARY KEY,
  code               varchar(10) NOT NULL UNIQUE,
  libelle            text NOT NULL,
  type               varchar(15) NOT NULL CHECK (type IN ('sur_epargne','sans_epargne')),
  taux_annuel        numeric(7,5) NOT NULL CHECK (taux_annuel >= 0),
  frais_dossier_taux numeric(7,5) NOT NULL DEFAULT 0 CHECK (frais_dossier_taux >= 0),
  periodicite_jours  smallint NOT NULL DEFAULT 30 CHECK (periodicite_jours > 0),
  methode            varchar(20) NOT NULL DEFAULT 'capital_constant' CHECK (methode IN ('capital_constant','annuite_constante')),
  actif              boolean NOT NULL DEFAULT true
);

CREATE TABLE demande_credit (
  id               serial PRIMARY KEY,
  agence_id        smallint NOT NULL REFERENCES agence(id),
  numero           varchar(25) NOT NULL,
  client_id        integer NOT NULL REFERENCES client(id),
  produit_id       integer NOT NULL REFERENCES produit_credit_epargne(id),
  compte_id        integer REFERENCES compte_epargne(id),
  cycle_id         integer REFERENCES cycle(id),
  montant          numeric(14,0) NOT NULL CHECK (montant > 0),
  nb_echeances     smallint NOT NULL CHECK (nb_echeances > 0),
  taux             numeric(7,5) NOT NULL CHECK (taux >= 0),
  garantie_montant numeric(14,0) NOT NULL DEFAULT 0 CHECK (garantie_montant >= 0),  -- négociée, sans plafond
  mode_remboursement varchar(20) NOT NULL CHECK (mode_remboursement IN ('tontine','prelevement_compte','especes')),
  note             text,
  statut           varchar(10) NOT NULL DEFAULT 'demandee' CHECK (statut IN ('demandee','approuvee','refusee','debloquee')),
  date_demande     date NOT NULL DEFAULT current_date,
  date_decision    date,
  validateur_id    integer REFERENCES utilisateur(id),
  commentaire      text,
  credit_id        integer REFERENCES credit(id),
  cree_le          timestamptz NOT NULL DEFAULT now(),
  UNIQUE (agence_id, numero)
);
CREATE TRIGGER demande_credit_numero BEFORE INSERT ON demande_credit FOR EACH ROW EXECUTE FUNCTION trg_numerotation('DC');

-- Garantie bloquée sur un compte d'épargne classique.
CREATE TABLE garantie_compte (
  id              serial PRIMARY KEY,
  credit_id       integer NOT NULL UNIQUE REFERENCES credit(id),
  compte_id       integer NOT NULL REFERENCES compte_epargne(id),
  montant_bloque  numeric(14,0) NOT NULL CHECK (montant_bloque > 0),
  montant_saisi   numeric(14,0) NOT NULL DEFAULT 0,
  montant_restant numeric(14,0) NOT NULL,            -- encore bloqué
  statut          varchar(10) NOT NULL DEFAULT 'bloquee' CHECK (statut IN ('bloquee','liberee')),
  libere_le       date,
  cree_le         timestamptz NOT NULL DEFAULT now(),
  CHECK (montant_saisi >= 0 AND montant_restant >= 0 AND montant_saisi + montant_restant <= montant_bloque)
);
CREATE INDEX garantie_compte_compte ON garantie_compte (compte_id) WHERE statut = 'bloquee';

-- Solde disponible = solde - solde minimum du produit - garanties bloquées.
CREATE OR REPLACE FUNCTION solde_disponible(p_compte integer) RETURNS numeric
LANGUAGE sql STABLE AS $$
  SELECT GREATEST(v.solde - p.solde_minimum
                  - COALESCE((SELECT sum(g.montant_restant) FROM mf.garantie_compte g
                               WHERE g.compte_id = p_compte AND g.statut = 'bloquee'), 0), 0)
    FROM mf.v_solde_compte_epargne v
    JOIN mf.compte_epargne c ON c.id = v.compte_id
    JOIN mf.produit_epargne p ON p.id = c.produit_id
   WHERE v.compte_id = p_compte
$$;

-- ---------------------------------------------------------------------
-- Demande, décision, déblocage
-- ---------------------------------------------------------------------
-- Montant, taux, frais et garantie sont négociés (pas de plafond en pourcentage). Un crédit sur épargne exige
-- une garantie (compte classique, ou cycle de tontine) ; mode « tontine » : cycle obligatoire ;
-- « prélèvement » : compte obligatoire.
CREATE FUNCTION nouvelle_demande_credit(p_client integer, p_compte integer, p_produit integer, p_montant numeric,
                                        p_nb_echeances integer, p_taux numeric DEFAULT NULL,
                                        p_garantie numeric DEFAULT 0, p_mode text DEFAULT 'prelevement_compte',
                                        p_note text DEFAULT NULL, p_cycle integer DEFAULT NULL) RETURNS integer
LANGUAGE plpgsql AS $$
DECLARE cl mf.client; pr mf.produit_credit_epargne; ce mf.compte_epargne; cy mf.cycle; v_id integer;
BEGIN
  SELECT * INTO cl FROM mf.client WHERE id = p_client;
  IF NOT FOUND THEN RAISE EXCEPTION 'client % inconnu', p_client; END IF;
  SELECT * INTO pr FROM mf.produit_credit_epargne WHERE id = p_produit AND actif;
  IF NOT FOUND THEN RAISE EXCEPTION 'produit de crédit % inconnu ou inactif', p_produit; END IF;
  IF p_montant <= 0 OR p_nb_echeances <= 0 THEN RAISE EXCEPTION 'montant ou nombre d''échéances invalide'; END IF;
  IF p_mode NOT IN ('tontine','prelevement_compte','especes') THEN RAISE EXCEPTION 'mode de remboursement inconnu : %', p_mode; END IF;

  IF p_compte IS NOT NULL THEN
    SELECT * INTO ce FROM mf.compte_epargne WHERE id = p_compte;
    IF NOT FOUND OR ce.client_id <> p_client THEN RAISE EXCEPTION 'le compte % n''appartient pas au client %', p_compte, cl.numero; END IF;
    IF ce.statut <> 'actif' THEN RAISE EXCEPTION 'compte % non actif', ce.numero; END IF;
  END IF;
  IF p_cycle IS NOT NULL THEN
    SELECT * INTO cy FROM mf.cycle WHERE id = p_cycle;
    IF NOT FOUND OR cy.client_id <> p_client THEN RAISE EXCEPTION 'le cycle % n''appartient pas au client %', p_cycle, cl.numero; END IF;
    IF cy.statut <> 'en_cours' THEN RAISE EXCEPTION 'cycle % non en cours', cy.numero; END IF;
  END IF;
  IF pr.type = 'sur_epargne' THEN
    IF COALESCE(p_garantie, 0) <= 0 THEN RAISE EXCEPTION 'un crédit sur épargne exige une garantie'; END IF;
    IF p_compte IS NULL AND p_cycle IS NULL THEN RAISE EXCEPTION 'un crédit sur épargne exige un compte ou un cycle en garantie'; END IF;
  END IF;
  IF p_mode = 'tontine' AND p_cycle IS NULL THEN RAISE EXCEPTION 'le remboursement sur tontine exige un cycle'; END IF;
  IF p_mode = 'prelevement_compte' AND p_compte IS NULL THEN RAISE EXCEPTION 'le prélèvement exige un compte'; END IF;

  INSERT INTO mf.demande_credit(agence_id, numero, client_id, produit_id, compte_id, cycle_id, montant, nb_echeances,
                                taux, garantie_montant, mode_remboursement, note)
  VALUES (cl.agence_id, NULL, p_client, p_produit, p_compte, p_cycle, p_montant, p_nb_echeances,
          COALESCE(p_taux, pr.taux_annuel), COALESCE(p_garantie, 0), p_mode, p_note)
  RETURNING id INTO v_id;
  RETURN v_id;
END $$;

CREATE FUNCTION approuver_demande(p_demande integer, p_validateur integer DEFAULT NULL,
                                  p_approuve boolean DEFAULT true, p_commentaire text DEFAULT NULL,
                                  p_date date DEFAULT current_date) RETURNS void
LANGUAGE plpgsql AS $$
DECLARE d mf.demande_credit;
BEGIN
  SELECT * INTO d FROM mf.demande_credit WHERE id = p_demande FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'demande % inconnue', p_demande; END IF;
  IF d.statut <> 'demandee' THEN RAISE EXCEPTION 'demande % déjà traitée (statut %)', d.numero, d.statut; END IF;
  IF p_approuve AND p_validateur IS NULL AND d.montant > mf.param_num('seuil_validation_credit', d.agence_id) THEN
    RAISE EXCEPTION 'la demande % dépasse le seuil de validation : un validateur est obligatoire', d.numero;
  END IF;
  UPDATE mf.demande_credit
     SET statut = CASE WHEN p_approuve THEN 'approuvee' ELSE 'refusee' END,
         validateur_id = p_validateur, commentaire = p_commentaire, date_decision = p_date
   WHERE id = p_demande;
END $$;

-- Déblocage : crée le crédit et son échéancier, bloque la garantie sur compte, décaisse sur le compte
-- (mode 'compte') ou en espèces (mode 'especes', session de caisse obligatoire). Frais de dossier :
-- débités du compte, ou encaissés en caisse. Retourne l'id du crédit.
CREATE FUNCTION debloquer_credit(p_demande integer, p_date date DEFAULT current_date, p_mode text DEFAULT 'compte',
                                 p_session integer DEFAULT NULL, p_utilisateur integer DEFAULT NULL) RETURNS integer
LANGUAGE plpgsql AS $$
DECLARE d mf.demande_credit; pr mf.produit_credit_epargne; v_frais numeric; v_credit integer;
        v_gtype text; v_cycle integer; v_compte integer;
BEGIN
  SELECT * INTO d FROM mf.demande_credit WHERE id = p_demande FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'demande % inconnue', p_demande; END IF;
  IF d.statut <> 'approuvee' THEN RAISE EXCEPTION 'demande % non approuvée (statut %)', d.numero, d.statut; END IF;
  IF p_mode NOT IN ('compte','especes') THEN RAISE EXCEPTION 'mode de décaissement inconnu : %', p_mode; END IF;
  IF p_mode = 'compte' AND d.compte_id IS NULL THEN RAISE EXCEPTION 'décaissement sur compte : aucun compte sur la demande'; END IF;
  IF p_mode = 'especes' AND p_session IS NULL THEN RAISE EXCEPTION 'décaissement en espèces : session de caisse obligatoire'; END IF;
  SELECT * INTO pr FROM mf.produit_credit_epargne WHERE id = d.produit_id;
  v_frais := round(d.montant * pr.frais_dossier_taux);

  v_gtype := CASE WHEN pr.type <> 'sur_epargne' THEN 'aucune' WHEN d.cycle_id IS NOT NULL THEN 'cycle' ELSE 'compte' END;
  -- une garantie sur compte doit être couverte par le disponible
  IF v_gtype = 'compte' AND d.garantie_montant > mf.solde_disponible(d.compte_id) THEN
    RAISE EXCEPTION 'garantie % supérieure au solde disponible % du compte', d.garantie_montant, mf.solde_disponible(d.compte_id);
  END IF;

  INSERT INTO mf.credit(agence_id, numero, client_id, type, montant_accorde, taux, frais_dossier, date_deblocage,
                        nb_echeances, periodicite_jours, methode, mode_remboursement, garantie_type,
                        cycle_garantie_id, compte_id)
  VALUES (d.agence_id, NULL, d.client_id, pr.type, d.montant, d.taux, v_frais, p_date, d.nb_echeances,
          pr.periodicite_jours, pr.methode, d.mode_remboursement, v_gtype,
          CASE WHEN v_gtype = 'cycle' THEN d.cycle_id END, d.compte_id)
  RETURNING id INTO v_credit;
  PERFORM mf.generer_echeancier(v_credit);

  IF v_gtype = 'compte' THEN
    INSERT INTO mf.garantie_compte(credit_id, compte_id, montant_bloque, montant_restant)
    VALUES (v_credit, d.compte_id, d.garantie_montant, d.garantie_montant);
  END IF;

  IF p_mode = 'compte' THEN
    INSERT INTO mf.mouvement_epargne(compte_id, type, montant, date_operation, libelle, reference)
    VALUES (d.compte_id, 'deblocage_credit', d.montant, p_date, 'Déblocage du crédit ' || d.numero, 'credit:' || v_credit);
    IF v_frais > 0 THEN
      INSERT INTO mf.mouvement_epargne(compte_id, type, montant, date_operation, libelle, reference)
      VALUES (d.compte_id, 'frais_dossier', v_frais, p_date, 'Frais de dossier ' || d.numero, 'credit:' || v_credit);
    END IF;
  ELSE
    PERFORM mf.caisse_operation(p_session, 'decaissement', 'deblocage_credit', d.montant, p_date, 'credit', v_credit);
    IF v_frais > 0 THEN
      PERFORM mf.caisse_operation(p_session, 'encaissement', 'frais_dossier', v_frais, p_date, 'credit', v_credit);
    END IF;
  END IF;

  UPDATE mf.demande_credit SET statut = 'debloquee', credit_id = v_credit WHERE id = p_demande;
  RETURN v_credit;
END $$;

-- ---------------------------------------------------------------------
-- Prélèvement automatique : dû complet seulement, sur le solde disponible (garantie exclue).
-- La date d'effet (retard, pénalité, points) est la date du prélèvement, soit le premier jour où le disponible
-- suffit : lancer la tâche chaque jour. Retourne le nombre d'échéances prélevées.
-- ---------------------------------------------------------------------
CREATE FUNCTION prelever_echeances_compte(p_agence smallint, p_date date DEFAULT current_date) RETURNS integer
LANGUAGE plpgsql AS $$
DECLARE c record; e mf.echeance; v_du numeric; n integer := 0;
BEGIN
  FOR c IN SELECT * FROM mf.credit
            WHERE agence_id = p_agence AND mode_remboursement = 'prelevement_compte' AND statut <> 'solde' AND compte_id IS NOT NULL
            ORDER BY id LOOP
    LOOP
      SELECT * INTO e FROM mf.echeance WHERE credit_id = c.id AND statut <> 'payee' ORDER BY no_echeance LIMIT 1;
      EXIT WHEN NOT FOUND OR e.date_prevue > p_date;
      v_du := mf.du_echeance(e.id, p_date);
      EXIT WHEN v_du <= 0 OR v_du > mf.solde_disponible(c.compte_id);
      INSERT INTO mf.mouvement_epargne(compte_id, type, montant, date_operation, libelle, reference)
      VALUES (c.compte_id, 'prelevement_echeance', v_du, p_date,
              'Prélèvement échéance ' || e.no_echeance || ' du crédit ' || c.numero, 'echeance:' || e.id);
      PERFORM mf.imputer_echeance(e.id, v_du, p_date, 'prelevement');
      n := n + 1;
    END LOOP;
  END LOOP;
  RETURN n;
END $$;

-- ---------------------------------------------------------------------
-- Saisie de la garantie : sur l'échéance la plus ancienne impayée dont le retard dépasse jours_saisie_garantie,
-- dans la limite de la garantie encore bloquée. Retourne le nombre de saisies (échéances imputées).
-- ---------------------------------------------------------------------
CREATE FUNCTION saisir_garantie_echeances(p_agence smallint, p_date date DEFAULT current_date) RETURNS integer
LANGUAGE plpgsql AS $$
DECLARE gr record; e mf.echeance; v_du numeric; v_s numeric; v_delai integer; n integer := 0;
BEGIN
  FOR gr IN SELECT gc.*, c.numero AS credit_numero, c.agence_id
             FROM mf.garantie_compte gc JOIN mf.credit c ON c.id = gc.credit_id
            WHERE c.agence_id = p_agence AND gc.statut = 'bloquee' AND gc.montant_restant > 0 AND c.statut <> 'solde'
            ORDER BY gc.id LOOP
    v_delai := mf.param_num('jours_saisie_garantie', gr.agence_id)::integer;
    LOOP
      SELECT * INTO e FROM mf.echeance WHERE credit_id = gr.credit_id AND statut <> 'payee' ORDER BY no_echeance LIMIT 1;
      EXIT WHEN NOT FOUND OR (p_date - e.date_prevue) <= v_delai;
      SELECT montant_restant INTO v_s FROM mf.garantie_compte WHERE id = gr.id;
      EXIT WHEN v_s <= 0;
      v_du := mf.du_echeance(e.id, p_date);
      v_s := LEAST(v_s, v_du);
      EXIT WHEN v_s <= 0;
      -- on réduit d'abord le bloqué, ce qui libère le disponible nécessaire à la sortie
      UPDATE mf.garantie_compte SET montant_saisi = montant_saisi + v_s, montant_restant = montant_restant - v_s WHERE id = gr.id;
      INSERT INTO mf.mouvement_epargne(compte_id, type, montant, date_operation, libelle, reference)
      VALUES (gr.compte_id, 'saisie_garantie', v_s, p_date,
              'Saisie de garantie, échéance ' || e.no_echeance || ' du crédit ' || gr.credit_numero, 'echeance:' || e.id);
      PERFORM mf.imputer_echeance(e.id, v_s, p_date, 'saisie_garantie');
      n := n + 1;
    END LOOP;
  END LOOP;
  RETURN n;
END $$;

-- Libération du solde de la garantie quand le crédit est soldé.
CREATE FUNCTION trg_credit_solde_garantie() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  IF NEW.statut = 'solde' AND OLD.statut <> 'solde' THEN
    UPDATE mf.garantie_compte SET montant_restant = 0, statut = 'liberee', libere_le = NEW.date_solde
     WHERE credit_id = NEW.id AND statut = 'bloquee';
  END IF;
  RETURN NULL;
END $$;
CREATE TRIGGER credit_solde_garantie AFTER UPDATE OF statut ON credit
  FOR EACH ROW EXECUTE FUNCTION trg_credit_solde_garantie();

-- Remboursement en espèces à la caisse : paiement partiel accepté, échéances dans l'ordre.
CREATE FUNCTION rembourser_echeance_especes(p_echeance integer, p_montant numeric, p_session integer,
                                            p_date date DEFAULT current_date) RETURNS void
LANGUAGE plpgsql AS $$
DECLARE cr mf.credit;
BEGIN
  SELECT k.* INTO cr FROM mf.credit k JOIN mf.echeance e ON e.credit_id = k.id WHERE e.id = p_echeance;
  IF NOT FOUND THEN RAISE EXCEPTION 'échéance % inconnue', p_echeance; END IF;
  IF cr.mode_remboursement <> 'especes' THEN
    RAISE EXCEPTION 'le crédit % se rembourse par %, pas en espèces', cr.numero, cr.mode_remboursement;
  END IF;
  PERFORM mf.imputer_echeance(p_echeance, p_montant, p_date, 'especes');
  PERFORM mf.caisse_operation(p_session, 'encaissement', 'remboursement_credit', p_montant, p_date, 'echeance', p_echeance);
END $$;

CREATE VIEW v_credit_epargne_situation AS
SELECT s.credit_id, s.agence_id, s.numero, s.client_id, s.type, s.mode_remboursement, s.capital_restant,
       COALESCE(g.montant_restant, 0)::numeric(14,0) AS garantie_bloquee, s.statut
  FROM v_credit_situation s LEFT JOIN garantie_compte g ON g.credit_id = s.credit_id;

-- =====================================================================
-- MODULE 09_rapports.sql
-- =====================================================================
-- =====================================================================
-- 09_rapports.sql
-- Rapport journalier (global, par agent, par zone) et écrans de crédit (échus, à venir, situation).
-- Règle (brief 3.7) : une date passée doit être reproductible. Tout est donc calculé à partir des
-- DATES MÉTIER des opérations (date de collecte, d'exécution, de paiement, de prélèvement...) et jamais
-- à partir des horodatages système (cree_le) ni des statuts courants.
-- Les trois sorties (écran, PDF, Excel) partent de ces mêmes fonctions : la mise en forme PDF / Excel
-- (un onglet par section) est à faire dans la couche applicative.
-- Dépend de : 00 à 03, 07, 08.
-- =====================================================================
SET search_path = mf, public;

-- Dû restant d'une échéance à une date : capital + intérêts moins les paiements datés au plus tard ce jour.
CREATE FUNCTION du_echeance_a_date(p_echeance integer, p_date date) RETURNS numeric
LANGUAGE sql STABLE AS $$
  SELECT e.capital + e.interet - COALESCE((SELECT sum(p.capital + p.interet) FROM mf.paiement_echeance p
                                            WHERE p.echeance_id = e.id AND p.date_operation <= p_date), 0)
    FROM mf.echeance e WHERE e.id = p_echeance
$$;

-- ---------------------------------------------------------------------
-- Rapport global d'une agence pour un jour : rubrique / valeur.
-- ---------------------------------------------------------------------
CREATE FUNCTION rapport_journalier_global(p_agence smallint, p_date date)
RETURNS TABLE (rubrique text, valeur numeric)
LANGUAGE plpgsql STABLE AS $$
BEGIN
  RETURN QUERY
  SELECT v.r, v.m FROM (VALUES
    -- collecte
    ('collecte_montant'::text, COALESCE((SELECT sum(l.montant_collecte) FROM mf.ligne_collecte l JOIN mf.cycle c ON c.id = l.cycle_id
        WHERE c.agence_id = p_agence AND l.date_collecte = p_date AND l.origine = 'collecte'), 0)::numeric),
    ('collecte_nb_lignes', COALESCE((SELECT count(*) FROM mf.ligne_collecte l JOIN mf.cycle c ON c.id = l.cycle_id
        WHERE c.agence_id = p_agence AND l.date_collecte = p_date AND l.origine = 'collecte'), 0)::numeric),
    ('mises_collectees', COALESCE((SELECT sum(l.mise_appliquee) FROM mf.ligne_collecte l JOIN mf.cycle c ON c.id = l.cycle_id
        WHERE c.agence_id = p_agence AND l.date_collecte = p_date AND l.origine = 'collecte'), 0)::numeric),
    ('virements_epargne_vers_tontine', COALESCE((SELECT sum(l.montant_collecte) FROM mf.ligne_collecte l JOIN mf.cycle c ON c.id = l.cycle_id
        WHERE c.agence_id = p_agence AND l.date_collecte = p_date AND l.origine = 'virement'), 0)::numeric),
    -- versements et écarts de tournée
    ('versements_agents', COALESCE((SELECT sum(montant_verse) FROM mf.versement_agent
        WHERE agence_id = p_agence AND date_tournee = p_date), 0)::numeric),
    ('versements_manquants', COALESCE((SELECT sum(ecart) FROM mf.versement_agent
        WHERE agence_id = p_agence AND date_tournee = p_date AND ecart > 0), 0)::numeric),
    ('versements_surplus', COALESCE((SELECT -sum(ecart) FROM mf.versement_agent
        WHERE agence_id = p_agence AND date_tournee = p_date AND ecart < 0), 0)::numeric),
    -- retraits et virements de cycle exécutés ce jour
    ('retraits_clients', COALESCE((SELECT sum(montant_paye) FROM mf.retrait
        WHERE agence_id = p_agence AND nature = 'retrait_client' AND statut = 'execute' AND date_operation = p_date), 0)::numeric),
    ('virements_tontine_vers_epargne', COALESCE((SELECT sum(montant_paye) FROM mf.retrait
        WHERE agence_id = p_agence AND nature = 'virement_vers_epargne' AND statut = 'execute' AND date_operation = p_date), 0)::numeric),
    ('ecarts_pertes_agents', COALESCE((SELECT sum(montant) FROM mf.compte_agent
        WHERE agence_id = p_agence AND type = 'perte_retrait' AND date_operation = p_date), 0)::numeric),
    ('ecarts_manquants_agents', COALESCE((SELECT sum(montant) FROM mf.compte_agent
        WHERE agence_id = p_agence AND type = 'manquant_versement' AND date_operation = p_date), 0)::numeric),
    ('retenues_sur_commission', COALESCE((SELECT sum(montant) FROM mf.compte_agent
        WHERE agence_id = p_agence AND type = 'retenue_commission' AND date_operation = p_date), 0)::numeric),
    -- épargne classique
    ('epargne_depots', COALESCE((SELECT sum(m.montant) FROM mf.mouvement_epargne m JOIN mf.compte_epargne c ON c.id = m.compte_id
        WHERE c.agence_id = p_agence AND m.type = 'depot' AND m.date_operation = p_date), 0)::numeric),
    ('epargne_retraits', COALESCE((SELECT sum(m.montant) FROM mf.mouvement_epargne m JOIN mf.compte_epargne c ON c.id = m.compte_id
        WHERE c.agence_id = p_agence AND m.type = 'retrait' AND m.date_operation = p_date), 0)::numeric),
    -- crédits
    ('credits_decaisses_nb', COALESCE((SELECT count(*) FROM mf.credit
        WHERE agence_id = p_agence AND date_deblocage = p_date), 0)::numeric),
    ('credits_decaisses_montant', COALESCE((SELECT sum(montant_accorde) FROM mf.credit
        WHERE agence_id = p_agence AND date_deblocage = p_date), 0)::numeric),
    ('remboursements_capital', COALESCE((SELECT sum(p.capital) FROM mf.paiement_echeance p JOIN mf.credit c ON c.id = p.credit_id
        WHERE c.agence_id = p_agence AND p.date_operation = p_date), 0)::numeric),
    ('remboursements_interets', COALESCE((SELECT sum(p.interet) FROM mf.paiement_echeance p JOIN mf.credit c ON c.id = p.credit_id
        WHERE c.agence_id = p_agence AND p.date_operation = p_date), 0)::numeric),
    ('remboursements_penalites', COALESCE((SELECT sum(p.penalite) FROM mf.paiement_echeance p JOIN mf.credit c ON c.id = p.credit_id
        WHERE c.agence_id = p_agence AND p.date_operation = p_date), 0)::numeric),
    ('remboursements_tontine', COALESCE((SELECT sum(p.capital + p.interet + p.penalite) FROM mf.paiement_echeance p JOIN mf.credit c ON c.id = p.credit_id
        WHERE c.agence_id = p_agence AND p.date_operation = p_date AND p.source = 'tontine'), 0)::numeric),
    ('remboursements_prelevement', COALESCE((SELECT sum(p.capital + p.interet + p.penalite) FROM mf.paiement_echeance p JOIN mf.credit c ON c.id = p.credit_id
        WHERE c.agence_id = p_agence AND p.date_operation = p_date AND p.source = 'prelevement'), 0)::numeric),
    ('remboursements_especes', COALESCE((SELECT sum(p.capital + p.interet + p.penalite) FROM mf.paiement_echeance p JOIN mf.credit c ON c.id = p.credit_id
        WHERE c.agence_id = p_agence AND p.date_operation = p_date AND p.source = 'especes'), 0)::numeric),
    ('saisies_garantie', COALESCE((SELECT sum(p.capital + p.interet + p.penalite) FROM mf.paiement_echeance p JOIN mf.credit c ON c.id = p.credit_id
        WHERE c.agence_id = p_agence AND p.date_operation = p_date AND p.source = 'saisie_garantie'), 0)::numeric),
    -- échéances échues (avant ce jour, impayées à cette date) et à venir (7 jours)
    ('echeances_echues_nb', COALESCE((SELECT count(*) FROM mf.echeance e JOIN mf.credit c ON c.id = e.credit_id
        WHERE c.agence_id = p_agence AND e.date_prevue < p_date AND mf.du_echeance_a_date(e.id, p_date) > 0), 0)::numeric),
    ('echeances_echues_montant', COALESCE((SELECT sum(mf.du_echeance_a_date(e.id, p_date)) FROM mf.echeance e JOIN mf.credit c ON c.id = e.credit_id
        WHERE c.agence_id = p_agence AND e.date_prevue < p_date AND mf.du_echeance_a_date(e.id, p_date) > 0), 0)::numeric),
    ('echeances_a_venir_nb', COALESCE((SELECT count(*) FROM mf.echeance e JOIN mf.credit c ON c.id = e.credit_id
        WHERE c.agence_id = p_agence AND e.date_prevue BETWEEN p_date AND p_date + 7 AND mf.du_echeance_a_date(e.id, p_date) > 0), 0)::numeric),
    ('echeances_a_venir_montant', COALESCE((SELECT sum(mf.du_echeance_a_date(e.id, p_date)) FROM mf.echeance e JOIN mf.credit c ON c.id = e.credit_id
        WHERE c.agence_id = p_agence AND e.date_prevue BETWEEN p_date AND p_date + 7 AND mf.du_echeance_a_date(e.id, p_date) > 0), 0)::numeric),
    -- fidélité
    ('points_fidelite', COALESCE((SELECT sum(p.points) FROM mf.points_fidelite p JOIN mf.client cl ON cl.id = p.client_id
        WHERE cl.agence_id = p_agence AND p.date_operation = p_date), 0)::numeric),
    -- caisse
    ('caisse_encaissements', COALESCE((SELECT sum(o.montant) FROM mf.operation_caisse o
        JOIN mf.session_caisse s ON s.id = o.session_id JOIN mf.caisse k ON k.id = s.caisse_id
        WHERE k.agence_id = p_agence AND o.type = 'encaissement' AND o.date_operation = p_date), 0)::numeric),
    ('caisse_decaissements', COALESCE((SELECT sum(o.montant) FROM mf.operation_caisse o
        JOIN mf.session_caisse s ON s.id = o.session_id JOIN mf.caisse k ON k.id = s.caisse_id
        WHERE k.agence_id = p_agence AND o.type = 'decaissement' AND o.date_operation = p_date), 0)::numeric),
    -- cycles
    ('cycles_clotures', COALESCE((SELECT count(*) FROM mf.cycle WHERE agence_id = p_agence AND date_cloture = p_date), 0)::numeric)
  ) AS v(r, m);
END $$;

-- ---------------------------------------------------------------------
-- Rapport par agent
-- ---------------------------------------------------------------------
CREATE FUNCTION rapport_journalier_agent(p_agence smallint, p_date date)
RETURNS TABLE (agent text, montant_collecte numeric, mises numeric, nb_lignes bigint,
               montant_verse numeric, ecart_versement numeric, pertes_retrait numeric)
LANGUAGE sql STABLE AS $$
  SELECT a.nom::text,
         COALESCE((SELECT sum(l.montant_collecte) FROM mf.ligne_collecte l
                    WHERE l.agent_id = a.id AND l.date_collecte = p_date AND l.origine = 'collecte'), 0)::numeric,
         COALESCE((SELECT sum(l.mise_appliquee) FROM mf.ligne_collecte l
                    WHERE l.agent_id = a.id AND l.date_collecte = p_date AND l.origine = 'collecte'), 0)::numeric,
         (SELECT count(*) FROM mf.ligne_collecte l
           WHERE l.agent_id = a.id AND l.date_collecte = p_date AND l.origine = 'collecte'),
         COALESCE((SELECT v.montant_verse FROM mf.versement_agent v WHERE v.agent_id = a.id AND v.date_tournee = p_date), 0)::numeric,
         COALESCE((SELECT v.ecart FROM mf.versement_agent v WHERE v.agent_id = a.id AND v.date_tournee = p_date), 0)::numeric,
         COALESCE((SELECT sum(c.montant) FROM mf.compte_agent c
                    WHERE c.agent_id = a.id AND c.type = 'perte_retrait' AND c.date_operation = p_date), 0)::numeric
    FROM mf.agent a WHERE a.agence_id = p_agence
   ORDER BY a.matricule
$$;

-- ---------------------------------------------------------------------
-- Rapport par zone : collecte, retraits, remboursements et écarts de retrait
-- ---------------------------------------------------------------------
CREATE FUNCTION rapport_journalier_zone(p_agence smallint, p_date date)
RETURNS TABLE (zone text, collectrice text, montant_collecte numeric, mises numeric, nb_lignes bigint,
               retraits numeric, remboursements numeric, ecarts_retrait numeric)
LANGUAGE sql STABLE AS $$
  SELECT z.code::text,
         (SELECT k.nom FROM mf.affectation_zone a JOIN mf.collectrice k ON k.id = a.collectrice_id
           WHERE a.zone_id = z.id AND p_date >= a.date_debut AND (a.date_fin IS NULL OR p_date <= a.date_fin) LIMIT 1)::text,
         COALESCE((SELECT sum(l.montant_collecte) FROM mf.ligne_collecte l JOIN mf.cycle c ON c.id = l.cycle_id
                    JOIN mf.client cl ON cl.id = c.client_id
                    WHERE cl.zone_id = z.id AND l.date_collecte = p_date AND l.origine = 'collecte'), 0)::numeric,
         COALESCE((SELECT sum(l.mise_appliquee) FROM mf.ligne_collecte l JOIN mf.cycle c ON c.id = l.cycle_id
                    JOIN mf.client cl ON cl.id = c.client_id
                    WHERE cl.zone_id = z.id AND l.date_collecte = p_date AND l.origine = 'collecte'), 0)::numeric,
         (SELECT count(*) FROM mf.ligne_collecte l JOIN mf.cycle c ON c.id = l.cycle_id
            JOIN mf.client cl ON cl.id = c.client_id
           WHERE cl.zone_id = z.id AND l.date_collecte = p_date AND l.origine = 'collecte'),
         COALESCE((SELECT sum(r.montant_paye) FROM mf.retrait r JOIN mf.cycle c ON c.id = r.cycle_id
                    JOIN mf.client cl ON cl.id = c.client_id
                    WHERE cl.zone_id = z.id AND r.statut = 'execute' AND r.date_operation = p_date
                      AND r.nature IN ('retrait_client','virement_vers_epargne')), 0)::numeric,
         COALESCE((SELECT sum(p.capital + p.interet + p.penalite) FROM mf.paiement_echeance p JOIN mf.credit cr ON cr.id = p.credit_id
                    JOIN mf.client cl ON cl.id = cr.client_id
                    WHERE cl.zone_id = z.id AND p.date_operation = p_date), 0)::numeric,
         COALESCE((SELECT sum(d.perte) FROM mf.ecart_retrait_date d JOIN mf.ecart_retrait e ON e.id = d.ecart_id
                    JOIN mf.cycle c ON c.id = e.cycle_id JOIN mf.client cl ON cl.id = c.client_id
                    WHERE cl.zone_id = z.id AND e.traite_le = p_date), 0)::numeric
    FROM mf.zone z WHERE z.agence_id = p_agence
   ORDER BY z.code
$$;

-- ---------------------------------------------------------------------
-- Écrans de crédit
-- ---------------------------------------------------------------------
-- Remboursements échus : échéance dépassée et impayée à cette date.
CREATE FUNCTION remboursements_echus(p_agence smallint, p_date date)
RETURNS TABLE (credit text, client text, no_echeance smallint, date_prevue date, jours_retard integer,
               du numeric, penalite numeric)
LANGUAGE sql STABLE AS $$
  SELECT c.numero::text, cl.nom::text, e.no_echeance, e.date_prevue, (p_date - e.date_prevue)::integer,
         mf.du_echeance_a_date(e.id, p_date),
         mf.calcul_penalite(e.capital, e.capital + e.interet, p_date - e.date_prevue, c.agence_id)
    FROM mf.echeance e JOIN mf.credit c ON c.id = e.credit_id JOIN mf.client cl ON cl.id = c.client_id
   WHERE c.agence_id = p_agence AND e.date_prevue < p_date AND mf.du_echeance_a_date(e.id, p_date) > 0
   ORDER BY e.date_prevue, c.numero, e.no_echeance
$$;

-- Remboursements à venir dans les p_jours jours (jour même inclus).
CREATE FUNCTION remboursements_a_venir(p_agence smallint, p_date date, p_jours integer DEFAULT 7)
RETURNS TABLE (credit text, client text, no_echeance smallint, date_prevue date, du numeric, mode_remboursement text)
LANGUAGE sql STABLE AS $$
  SELECT c.numero::text, cl.nom::text, e.no_echeance, e.date_prevue, mf.du_echeance_a_date(e.id, p_date), c.mode_remboursement::text
    FROM mf.echeance e JOIN mf.credit c ON c.id = e.credit_id JOIN mf.client cl ON cl.id = c.client_id
   WHERE c.agence_id = p_agence AND e.date_prevue BETWEEN p_date AND p_date + p_jours
     AND mf.du_echeance_a_date(e.id, p_date) > 0
   ORDER BY e.date_prevue, c.numero, e.no_echeance
$$;

-- Situation des crédits à une date : capital restant, prochaine échéance, garantie encore bloquée, statut à la date.
CREATE FUNCTION situation_credits(p_agence smallint, p_date date)
RETURNS TABLE (credit text, client text, type text, mode_remboursement text, montant_accorde numeric,
               capital_restant numeric, echeances_restantes bigint, prochaine_echeance date,
               garantie_bloquee numeric, statut_a_date text)
LANGUAGE sql STABLE AS $$
  SELECT c.numero::text, cl.nom::text, c.type::text, c.mode_remboursement::text, c.montant_accorde,
         c.montant_accorde - COALESCE((SELECT sum(p.capital) FROM mf.paiement_echeance p
                                        WHERE p.credit_id = c.id AND p.date_operation <= p_date), 0),
         (SELECT count(*) FROM mf.echeance e WHERE e.credit_id = c.id AND mf.du_echeance_a_date(e.id, p_date) > 0),
         (SELECT min(e.date_prevue) FROM mf.echeance e WHERE e.credit_id = c.id AND mf.du_echeance_a_date(e.id, p_date) > 0),
         CASE WHEN g.id IS NULL OR (g.libere_le IS NOT NULL AND g.libere_le <= p_date) THEN 0
              ELSE g.montant_bloque - COALESCE((SELECT sum(p.capital + p.interet + p.penalite) FROM mf.paiement_echeance p
                                                 WHERE p.credit_id = c.id AND p.source = 'saisie_garantie'
                                                   AND p.date_operation <= p_date), 0) END,
         CASE WHEN c.date_solde IS NOT NULL AND c.date_solde <= p_date THEN 'solde'
              WHEN EXISTS (SELECT 1 FROM mf.echeance e WHERE e.credit_id = c.id AND e.date_prevue < p_date
                              AND mf.du_echeance_a_date(e.id, p_date) > 0) THEN 'en_retard'
              ELSE 'en_cours' END
    FROM mf.credit c JOIN mf.client cl ON cl.id = c.client_id
    LEFT JOIN mf.garantie_compte g ON g.credit_id = c.id
   WHERE c.agence_id = p_agence AND c.date_deblocage <= p_date
   ORDER BY c.numero
$$;

-- =====================================================================
-- MODULE 10_comptabilisation_audit.sql
-- =====================================================================
-- =====================================================================
-- 10_comptabilisation_audit.sql
-- (a) Comptabilisation automatique des événements (brief P1.3) : règles par événement sur les comptes
--     du référentiel SFD UMOA + triggers qui appellent comptabiliser().
-- (b) Piste d'audit (brief P2.4) : trigger générique vers audit_log.
-- Dépend de : 00 à 09.
--
-- La comptabilisation automatique est DÉSACTIVÉE par défaut : parametre 'comptabilisation_auto' = 'non'.
-- Pour l'activer (par agence ou globalement) : créer l'exercice comptable, faire valider les règles
-- ci-dessous par le comptable, puis  UPDATE mf.parametre SET valeur = 'oui' WHERE cle = 'comptabilisation_auto'.
--
-- COMPTES CHOISIS (PROPOSITION À VALIDER par le comptable) :
--   1011  Billets et monnaies émis par la BCEAO (caisse)
--   25111 Comptes ordinaires (épargne classique)        25391 Autres comptes d'épargne à régime spécial (tontine)
--   202211 Crédits à court terme de 0 à 6 mois           70212 Intérêts sur crédits à court terme
--   70293 Autres commissions (mises de tontine, frais)   7711 Pénalités perçues
--   3316 Autres débiteurs divers (dette des agents)      3327 Autres créditeurs divers (surplus, excédents)
--   3322 Personnel   3323 Organismes sociaux   3312 Personnel, avances   641 Salaires   642 Charges sociales
--   602512 Intérêts sur livrets   6716 / 7716 Pertes / produits sur écarts de caisse
-- Simplification : tous les crédits sont classés en 202211 quelle que soit leur durée.
-- =====================================================================
SET search_path = mf, public;

INSERT INTO parametre(cle, valeur, description) VALUES
  ('comptabilisation_auto', 'non', 'oui | non : génère les écritures comptables à chaque opération (voir 10_comptabilisation_audit.sql)');

-- ---------------------------------------------------------------------
-- Règles comptables (globales ; une règle d'agence de même ligne les remplace)
-- ---------------------------------------------------------------------
INSERT INTO regle_comptable(evenement, ligne, compte_debit, compte_credit, cle_montant, journal_code, libelle) VALUES
  ('epargne_depot',                 1, '1011',  '25111',  'montant', 'CAI', 'Dépôt sur compte d''épargne'),
  ('epargne_retrait',               1, '25111', '1011',   'montant', 'CAI', 'Retrait sur compte d''épargne'),
  ('epargne_interet',               1, '602512','25111',  'montant', 'EPA', 'Intérêts sur épargne'),
  ('virement_epargne_vers_tontine', 1, '25111', '25391',  'montant', 'EPA', 'Virement épargne vers tontine'),
  ('deblocage_credit_compte',       1, '202211','25111',  'montant', 'CRE', 'Déblocage de crédit sur compte'),
  ('frais_dossier_compte',          1, '25111', '70293',  'montant', 'CRE', 'Frais de dossier prélevés sur compte'),
  ('deblocage_credit_especes',      1, '202211','1011',   'montant', 'CRE', 'Déblocage de crédit en espèces'),
  ('frais_dossier_especes',         1, '1011',  '70293',  'montant', 'CRE', 'Frais de dossier encaissés'),
  -- fin de tournée : espèces versées, manquant (créance sur l'agent), surplus (dette envers l'agent)
  ('versement_agent',               1, '1011',  '25391',  'cash_collecte', 'AGT', 'Versement de collecte'),
  ('versement_agent',               2, '3316',  '25391',  'manquant',      'AGT', 'Manquant de tournée'),
  ('versement_agent',               3, '1011',  '3327',   'surplus',       'AGT', 'Surplus de tournée'),
  -- retrait de cycle payé au client (espèces)
  ('retrait_client',                1, '25391', '1011',   'paye_cycle',     'CAI', 'Retrait de cycle'),
  ('retrait_client',                2, '3316',  '1011',   'perte',          'CAI', 'Perte sur retrait imputée à l''agent'),
  ('retrait_client',                3, '3327',  '1011',   'surplus_utilise','CAI', 'Surplus utilisé sur retrait'),
  ('retrait_client',                4, '25391', '70293',  'mise',           'CAI', 'Mise de tontine (commission)'),
  ('retrait_client',                5, '25391', '3327',   'excedent',       'CAI', 'Excédent à régulariser'),
  -- retrait de cycle viré sur un compte d'épargne
  ('virement_vers_epargne',         1, '25391', '25111',  'paye_cycle',     'EPA', 'Virement du cycle vers l''épargne'),
  ('virement_vers_epargne',         2, '3316',  '25111',  'perte',          'EPA', 'Perte sur virement imputée à l''agent'),
  ('virement_vers_epargne',         3, '3327',  '25111',  'surplus_utilise','EPA', 'Surplus utilisé sur virement'),
  ('virement_vers_epargne',         4, '25391', '70293',  'mise',           'EPA', 'Mise de tontine (commission)'),
  ('virement_vers_epargne',         5, '25391', '3327',   'excedent',       'EPA', 'Excédent à régulariser'),
  -- remboursements de crédit : capital, intérêts, pénalités selon la source des fonds
  ('remboursement_tontine',         1, '25391', '202211', 'capital',  'CRE', 'Remboursement sur tontine : capital'),
  ('remboursement_tontine',         2, '25391', '70212',  'interet',  'CRE', 'Remboursement sur tontine : intérêts'),
  ('remboursement_tontine',         3, '25391', '7711',   'penalite', 'CRE', 'Remboursement sur tontine : pénalités'),
  ('remboursement_prelevement',     1, '25111', '202211', 'capital',  'CRE', 'Prélèvement : capital'),
  ('remboursement_prelevement',     2, '25111', '70212',  'interet',  'CRE', 'Prélèvement : intérêts'),
  ('remboursement_prelevement',     3, '25111', '7711',   'penalite', 'CRE', 'Prélèvement : pénalités'),
  ('remboursement_especes',         1, '1011',  '202211', 'capital',  'CRE', 'Remboursement en espèces : capital'),
  ('remboursement_especes',         2, '1011',  '70212',  'interet',  'CRE', 'Remboursement en espèces : intérêts'),
  ('remboursement_especes',         3, '1011',  '7711',   'penalite', 'CRE', 'Remboursement en espèces : pénalités'),
  ('remboursement_saisie_garantie', 1, '25111', '202211', 'capital',  'CRE', 'Saisie de garantie : capital'),
  ('remboursement_saisie_garantie', 2, '25111', '70212',  'interet',  'CRE', 'Saisie de garantie : intérêts'),
  ('remboursement_saisie_garantie', 3, '25111', '7711',   'penalite', 'CRE', 'Saisie de garantie : pénalités'),
  -- compte agent
  ('reglement_compte_agent',        1, '1011',  '3316',   'montant', 'AGT', 'Règlement du compte agent par versement'),
  ('retenue_commission_agent',      1, '641',   '3316',   'montant', 'AGT', 'Retenue sur commission'),
  -- paie : brut = net + retenues salariales + avance retenue
  ('paie',                          1, '641',   '3322',   'net',                'PAI', 'Salaires nets à payer'),
  ('paie',                          2, '641',   '3323',   'retenues',           'PAI', 'Retenues salariales'),
  ('paie',                          3, '641',   '3312',   'avance',             'PAI', 'Avances retenues'),
  ('paie',                          4, '642',   '3323',   'charges_patronales', 'PAI', 'Charges patronales'),
  -- écart de caisse constaté à la fermeture
  ('ecart_caisse_perte',            1, '6716',  '1011',   'montant', 'CAI', 'Écart de caisse (manquant)'),
  ('ecart_caisse_gain',             1, '1011',  '7716',   'montant', 'CAI', 'Écart de caisse (excédent)');

CREATE FUNCTION comptabilisation_active(p_agence smallint) RETURNS boolean
LANGUAGE sql STABLE AS $$ SELECT COALESCE(mf.param('comptabilisation_auto', p_agence), 'non') = 'oui' $$;

-- ---------------------------------------------------------------------
-- Triggers de comptabilisation
-- ---------------------------------------------------------------------
-- épargne : dépôts, retraits, intérêts, déblocage et frais de dossier passés sur compte
CREATE FUNCTION trg_compta_mouvement_epargne() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE v_agence smallint; v_evt text;
BEGIN
  v_evt := CASE NEW.type WHEN 'depot' THEN 'epargne_depot' WHEN 'retrait' THEN 'epargne_retrait'
                         WHEN 'interet' THEN 'epargne_interet' WHEN 'deblocage_credit' THEN 'deblocage_credit_compte'
                         WHEN 'frais_dossier' THEN 'frais_dossier_compte' END;
  IF v_evt IS NULL THEN RETURN NULL; END IF;
  SELECT agence_id INTO v_agence FROM mf.compte_epargne WHERE id = NEW.compte_id;
  IF mf.comptabilisation_active(v_agence) THEN
    PERFORM mf.comptabiliser(v_evt, v_agence, NEW.date_operation, jsonb_build_object('montant', NEW.montant),
                             'mouvement_epargne', NEW.id, NEW.libelle);
  END IF;
  RETURN NULL;
END $$;
CREATE TRIGGER compta_mouvement_epargne AFTER INSERT ON mouvement_epargne
  FOR EACH ROW EXECUTE FUNCTION trg_compta_mouvement_epargne();

-- caisse : déblocage de crédit et frais de dossier en espèces ; écart de fermeture
CREATE FUNCTION trg_compta_operation_caisse() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE v_agence smallint; v_evt text;
BEGIN
  v_evt := CASE WHEN NEW.motif = 'deblocage_credit' AND NEW.type = 'decaissement' THEN 'deblocage_credit_especes'
                WHEN NEW.motif = 'frais_dossier' AND NEW.type = 'encaissement' THEN 'frais_dossier_especes' END;
  IF v_evt IS NULL THEN RETURN NULL; END IF;
  SELECT k.agence_id INTO v_agence FROM mf.session_caisse s JOIN mf.caisse k ON k.id = s.caisse_id WHERE s.id = NEW.session_id;
  IF mf.comptabilisation_active(v_agence) THEN
    PERFORM mf.comptabiliser(v_evt, v_agence, NEW.date_operation, jsonb_build_object('montant', NEW.montant),
                             'operation_caisse', NEW.id, NEW.libelle);
  END IF;
  RETURN NULL;
END $$;
CREATE TRIGGER compta_operation_caisse AFTER INSERT ON operation_caisse
  FOR EACH ROW EXECUTE FUNCTION trg_compta_operation_caisse();

CREATE FUNCTION trg_compta_session_caisse() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE v_agence smallint;
BEGIN
  IF NEW.statut = 'fermee' AND OLD.statut = 'ouverte' AND COALESCE(NEW.ecart_fermeture, 0) <> 0 THEN
    SELECT agence_id INTO v_agence FROM mf.caisse WHERE id = NEW.caisse_id;
    IF mf.comptabilisation_active(v_agence) THEN
      PERFORM mf.comptabiliser(CASE WHEN NEW.ecart_fermeture < 0 THEN 'ecart_caisse_perte' ELSE 'ecart_caisse_gain' END,
                               v_agence, NEW.date_session, jsonb_build_object('montant', abs(NEW.ecart_fermeture)),
                               'session_caisse', NEW.id, 'Écart de caisse à la fermeture');
    END IF;
  END IF;
  RETURN NULL;
END $$;
CREATE TRIGGER compta_session_caisse AFTER UPDATE OF statut ON session_caisse
  FOR EACH ROW EXECUTE FUNCTION trg_compta_session_caisse();

-- fin de tournée
CREATE FUNCTION trg_compta_versement_agent() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  IF mf.comptabilisation_active(NEW.agence_id) THEN
    PERFORM mf.comptabiliser('versement_agent', NEW.agence_id, NEW.date_tournee,
      jsonb_build_object('cash_collecte', LEAST(NEW.montant_collecte, NEW.montant_verse),
                         'manquant', GREATEST(NEW.ecart, 0), 'surplus', GREATEST(-NEW.ecart, 0)),
      'versement_agent', NEW.id, 'Versement de la tournée du ' || NEW.date_tournee);
  END IF;
  RETURN NULL;
END $$;
CREATE TRIGGER compta_versement_agent AFTER INSERT ON versement_agent
  FOR EACH ROW EXECUTE FUNCTION trg_compta_versement_agent();

-- règlement et retenue sur le compte agent (manquants et pertes sont déjà comptabilisés par la tournée et le retrait)
CREATE FUNCTION trg_compta_compte_agent() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE v_evt text;
BEGIN
  v_evt := CASE NEW.type WHEN 'versement' THEN 'reglement_compte_agent' WHEN 'retenue_commission' THEN 'retenue_commission_agent' END;
  IF v_evt IS NOT NULL AND mf.comptabilisation_active(NEW.agence_id) THEN
    PERFORM mf.comptabiliser(v_evt, NEW.agence_id, NEW.date_operation, jsonb_build_object('montant', NEW.montant),
                             'compte_agent', NEW.id, NEW.libelle);
  END IF;
  RETURN NULL;
END $$;
CREATE TRIGGER compta_compte_agent AFTER INSERT ON compte_agent
  FOR EACH ROW EXECUTE FUNCTION trg_compta_compte_agent();

-- retrait de cycle exécuté (payé au client ou viré sur un compte)
CREATE FUNCTION trg_compta_retrait() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE v_mise numeric; v_perte numeric := 0; v_surplus numeric := 0; v_exc numeric := 0; v_paye numeric;
BEGIN
  IF NEW.nature NOT IN ('retrait_client','virement_vers_epargne') OR NOT mf.comptabilisation_active(NEW.agence_id) THEN
    RETURN NULL;
  END IF;
  SELECT mise_finale INTO v_mise FROM mf.cycle WHERE id = NEW.cycle_id;
  SELECT COALESCE(sum(d.perte), 0), COALESCE(sum(d.surplus_utilise), 0) INTO v_perte, v_surplus
    FROM mf.ecart_retrait_date d JOIN mf.ecart_retrait e ON e.id = d.ecart_id
   WHERE e.retrait_id = NEW.id AND e.sens = 'livret_sup';
  SELECT COALESCE(sum(montant), 0) INTO v_exc FROM mf.ecart_retrait WHERE retrait_id = NEW.id AND sens = 'machine_sup';
  v_paye := NEW.montant_paye;
  PERFORM mf.comptabiliser(CASE NEW.nature WHEN 'retrait_client' THEN 'retrait_client' ELSE 'virement_vers_epargne' END,
    NEW.agence_id, NEW.date_operation,
    jsonb_build_object('paye_cycle', v_paye - v_perte - v_surplus, 'perte', v_perte, 'surplus_utilise', v_surplus,
                       'mise', v_mise, 'excedent', v_exc),
    'retrait', NEW.id, 'Retrait du cycle ' || (SELECT numero FROM mf.cycle WHERE id = NEW.cycle_id));
  RETURN NULL;
END $$;
CREATE TRIGGER compta_retrait AFTER UPDATE OF statut ON retrait
  FOR EACH ROW WHEN (NEW.statut = 'execute' AND OLD.statut <> 'execute') EXECUTE FUNCTION trg_compta_retrait();

-- virement de l'épargne vers un cycle (le sens inverse est comptabilisé par le retrait de cycle)
CREATE FUNCTION trg_compta_virement() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  IF NEW.sens = 'epargne_vers_cycle' AND mf.comptabilisation_active(NEW.agence_id) THEN
    PERFORM mf.comptabiliser('virement_epargne_vers_tontine', NEW.agence_id, NEW.date_operation,
                             jsonb_build_object('montant', NEW.montant), 'virement', NEW.id);
  END IF;
  RETURN NULL;
END $$;
CREATE TRIGGER compta_virement AFTER INSERT ON virement
  FOR EACH ROW EXECUTE FUNCTION trg_compta_virement();

-- remboursements : capital, intérêts, pénalités par source de fonds
CREATE FUNCTION trg_compta_paiement_echeance() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE v_agence smallint;
BEGIN
  SELECT agence_id INTO v_agence FROM mf.credit WHERE id = NEW.credit_id;
  IF mf.comptabilisation_active(v_agence) THEN
    PERFORM mf.comptabiliser('remboursement_' || NEW.source, v_agence, NEW.date_operation,
      jsonb_build_object('capital', NEW.capital, 'interet', NEW.interet, 'penalite', NEW.penalite),
      'paiement_echeance', NEW.id);
  END IF;
  RETURN NULL;
END $$;
CREATE TRIGGER compta_paiement_echeance AFTER INSERT ON paiement_echeance
  FOR EACH ROW EXECUTE FUNCTION trg_compta_paiement_echeance();

-- paie : à la validation du bulletin, à la fin du mois de paie
CREATE FUNCTION trg_compta_bulletin() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  IF mf.comptabilisation_active(NEW.agence_id) THEN
    PERFORM mf.comptabiliser('paie', NEW.agence_id, (NEW.periode + interval '1 month - 1 day')::date,
      jsonb_build_object('net', NEW.net_a_payer, 'retenues', NEW.retenues, 'avance', NEW.retenue_avance,
                         'charges_patronales', NEW.charges_patronales),
      'bulletin_paie', NEW.id, 'Paie ' || to_char(NEW.periode, 'MM/YYYY'));
  END IF;
  RETURN NULL;
END $$;
CREATE TRIGGER compta_bulletin AFTER UPDATE OF statut ON bulletin_paie
  FOR EACH ROW WHEN (NEW.statut = 'valide' AND OLD.statut = 'brouillon') EXECUTE FUNCTION trg_compta_bulletin();

-- ---------------------------------------------------------------------
-- Piste d'audit : INSERT / UPDATE / DELETE des tables sensibles (retraits, écarts, surplus, compte agent,
-- crédits, garanties, écritures via les pièces, paie, caisse). L'application renseigne l'utilisateur par
--   SET LOCAL mf.utilisateur = '<id ou login>';   (à défaut : l'utilisateur de la base)
-- ---------------------------------------------------------------------
CREATE FUNCTION trg_audit() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE v_user text := COALESCE(NULLIF(current_setting('mf.utilisateur', true), ''), current_user);
        v_row jsonb;
BEGIN
  v_row := CASE WHEN TG_OP = 'DELETE' THEN to_jsonb(OLD) ELSE to_jsonb(NEW) END;
  INSERT INTO mf.audit_log(utilisateur, table_name, operation, ligne_id, avant, apres)
  VALUES (v_user, TG_TABLE_NAME, TG_OP, v_row ->> 'id',
          CASE WHEN TG_OP IN ('UPDATE','DELETE') THEN to_jsonb(OLD) END,
          CASE WHEN TG_OP IN ('INSERT','UPDATE') THEN to_jsonb(NEW) END);
  RETURN NULL;
END $$;

DO $$
DECLARE t text;
BEGIN
  FOREACH t IN ARRAY ARRAY['cycle','retrait','ecart_retrait','ecart_retrait_date','excedent_regularisation','surplus',
                           'compte_agent','versement_agent','virement','credit','echeance','demande_credit',
                           'garantie_compte','piece_comptable','session_caisse','bulletin_paie','avance_salaire',
                           'commission_collectrice','parametre','mouvement_epargne']
  LOOP
    EXECUTE format('CREATE TRIGGER audit_%I AFTER INSERT OR UPDATE OR DELETE ON mf.%I
                    FOR EACH ROW EXECUTE FUNCTION mf.trg_audit()', t, t);
  END LOOP;
END $$;
CREATE INDEX audit_log_table ON audit_log (table_name, ligne_id);
CREATE INDEX audit_log_horodatage ON audit_log (horodatage);

-- =====================================================================
-- MODULE 11_auth.sql
-- =====================================================================
-- =====================================================================
-- 11_auth.sql
-- Colonnes d'authentification des utilisateurs (utilisées par l'API) : mot de passe haché, verrouillage
-- après échecs répétés, lien vers l'agent ou la collectrice correspondant.
-- Dépend de : 00, 01 (agent), 04 (collectrice.agent_id).
-- =====================================================================
SET search_path = mf, public;

ALTER TABLE utilisateur
  ADD COLUMN mot_de_passe_hash  text,
  ADD COLUMN derniere_connexion timestamptz,
  ADD COLUMN echecs_connexion   smallint NOT NULL DEFAULT 0,
  ADD COLUMN verrouille_jusqua  timestamptz,
  ADD COLUMN agent_id           integer REFERENCES agent(id),
  ADD COLUMN collectrice_id     integer REFERENCES collectrice(id);

-- Un rôle d'agence doit avoir une agence ; seuls admin, directeur, comptable et auditeur peuvent être au siège.
ALTER TABLE utilisateur ADD CONSTRAINT utilisateur_agence_selon_role
  CHECK (agence_id IS NOT NULL OR role IN ('admin','directeur','comptable','auditeur'));

-- =====================================================================
-- MODULE 12_planificateur.sql
-- =====================================================================
-- =====================================================================
-- 12_planificateur.sql
-- Journal des tâches quotidiennes lancées par le planificateur (api/app/planificateur.py).
-- Table technique : aucune règle métier. Garantit qu'une tâche n'est réussie qu'une fois par agence et par date
-- (rejouable sans doublon) et garde la trace de chaque exécution, y compris les échecs.
-- Dépend de : 00 (agence).
-- =====================================================================
SET search_path = mf, public;

CREATE TABLE execution_tache (
  id         bigserial PRIMARY KEY,
  agence_id  smallint NOT NULL REFERENCES agence(id),
  date_tache date NOT NULL,                       -- date métier passée à la fonction
  tache      varchar(40) NOT NULL
             CHECK (tache IN ('cloturer_cycles_echus','prelever_echeances_compte','maj_statuts_credit',
                              'saisir_garantie_echeances','purger_dates')),
  statut     varchar(10) NOT NULL CHECK (statut IN ('ok','echec','remplace')),   -- remplace : réussite écartée par un rejeu forcé
  nb_traites integer,                             -- valeur retournée par la fonction
  message    text,                                -- erreur éventuelle
  debut      timestamptz NOT NULL DEFAULT now(),
  fin        timestamptz,
  lance_par  text NOT NULL DEFAULT 'planificateur'
);

-- une seule réussite active par agence, date et tâche
CREATE UNIQUE INDEX execution_tache_ok_uniq ON execution_tache(agence_id, date_tache, tache) WHERE statut = 'ok';
CREATE INDEX execution_tache_date_idx ON execution_tache(date_tache DESC, agence_id);

-- =====================================================================
-- MODULE 13_tresorerie.sql
-- =====================================================================
-- =====================================================================
-- 13_tresorerie.sql
-- Caisses multiples et trésorerie :
--   * ouverture de session avec continuité (le solde d'ouverture doit égaler le solde compté à la fermeture
--     précédente, sinon l'écart est tracé) ;
--   * transferts entre caisses d'une agence (approvisionnement d'un guichet depuis le coffre, etc.) ;
--   * comptes bancaires de l'agence : versements et retraits liés à une session de caisse, autres mouvements,
--     rapprochement ;
--   * état des caisses d'un jour, position de trésorerie, prévision par tranches.
-- Dépend de : 00, 03 (caisse), 05 (règles comptables), 10 (comptabilisation).
-- =====================================================================
SET search_path = mf, public;

ALTER TABLE caisse
  ADD COLUMN libelle        text,
  ADD COLUMN responsable_id integer REFERENCES utilisateur(id),
  ADD COLUMN plafond        numeric(14,0) CHECK (plafond IS NULL OR plafond >= 0);   -- au-delà : à reverser en banque ou au coffre

ALTER TABLE session_caisse
  ADD COLUMN ecart_ouverture numeric(14,0) NOT NULL DEFAULT 0;   -- solde d'ouverture - solde compté à la fermeture précédente

-- ---------------------------------------------------------------------
-- Ouverture de session : une seule session ouverte par caisse, jours strictement croissants,
-- solde d'ouverture = solde compté la veille (sinon refus, sauf p_accepter_ecart : l'écart est alors tracé).
-- La première session d'une caisse fixe librement son fonds de départ.
-- ---------------------------------------------------------------------
CREATE FUNCTION ouvrir_session_caisse(p_caisse integer, p_date date, p_solde_compte numeric,
                                      p_billetage jsonb DEFAULT NULL, p_utilisateur integer DEFAULT NULL,
                                      p_accepter_ecart boolean DEFAULT false) RETURNS integer
LANGUAGE plpgsql AS $$
DECLARE k mf.caisse; prev mf.session_caisse; v_ecart numeric := 0; v_id integer;
BEGIN
  SELECT * INTO k FROM mf.caisse WHERE id = p_caisse FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'caisse % inconnue', p_caisse; END IF;
  IF NOT k.actif THEN RAISE EXCEPTION 'la caisse % est désactivée', k.code; END IF;
  IF p_solde_compte < 0 THEN RAISE EXCEPTION 'solde d''ouverture négatif'; END IF;
  SELECT * INTO prev FROM mf.session_caisse WHERE caisse_id = p_caisse AND statut = 'ouverte' LIMIT 1;
  IF FOUND THEN
    RAISE EXCEPTION 'la caisse % a déjà une session ouverte (jour %) : la fermer d''abord', k.code, prev.date_session;
  END IF;
  SELECT * INTO prev FROM mf.session_caisse WHERE caisse_id = p_caisse ORDER BY date_session DESC LIMIT 1;
  IF FOUND THEN
    IF p_date <= prev.date_session THEN
      RAISE EXCEPTION 'la caisse % a déjà une session au % : ouvrir à une date postérieure', k.code, prev.date_session;
    END IF;
    v_ecart := p_solde_compte - COALESCE(prev.solde_compte, 0);
    IF v_ecart <> 0 AND NOT p_accepter_ecart THEN
      RAISE EXCEPTION 'le solde d''ouverture (%) diffère du solde compté à la fermeture du % (%) : écart de %',
        p_solde_compte, prev.date_session, prev.solde_compte, v_ecart;
    END IF;
  END IF;
  INSERT INTO mf.session_caisse(caisse_id, date_session, solde_ouverture, billetage_ouverture, utilisateur_id, ecart_ouverture)
  VALUES (p_caisse, p_date, p_solde_compte, p_billetage, p_utilisateur, v_ecart)
  RETURNING id INTO v_id;
  RETURN v_id;
END $$;

-- ---------------------------------------------------------------------
-- Transferts entre caisses d'une même agence (les deux sessions doivent être ouvertes)
-- ---------------------------------------------------------------------
CREATE TABLE transfert_caisse (
  id              serial PRIMARY KEY,
  agence_id       smallint NOT NULL REFERENCES agence(id),
  session_source  integer NOT NULL REFERENCES session_caisse(id),
  session_dest    integer NOT NULL REFERENCES session_caisse(id),
  montant         numeric(14,0) NOT NULL CHECK (montant > 0),
  date_operation  date NOT NULL,
  motif           text,
  utilisateur_id  integer REFERENCES utilisateur(id),
  cree_le         timestamptz NOT NULL DEFAULT now(),
  CHECK (session_source <> session_dest)
);
CREATE INDEX transfert_caisse_date ON transfert_caisse (agence_id, date_operation);

CREATE FUNCTION transferer_entre_caisses(p_source integer, p_dest integer, p_montant numeric,
                                         p_date date DEFAULT current_date, p_motif text DEFAULT NULL,
                                         p_utilisateur integer DEFAULT NULL) RETURNS integer
LANGUAGE plpgsql AS $$
DECLARE s1 mf.session_caisse; s2 mf.session_caisse; k1 mf.caisse; k2 mf.caisse; v_id integer;
BEGIN
  IF p_source = p_dest THEN RAISE EXCEPTION 'la caisse source et la caisse destinataire doivent différer'; END IF;
  IF p_montant <= 0 THEN RAISE EXCEPTION 'montant invalide'; END IF;
  -- verrou dans l'ordre des identifiants : pas d'interblocage entre deux transferts croisés
  PERFORM 1 FROM mf.session_caisse WHERE id IN (p_source, p_dest) ORDER BY id FOR UPDATE;
  SELECT * INTO s1 FROM mf.session_caisse WHERE id = p_source;
  SELECT * INTO s2 FROM mf.session_caisse WHERE id = p_dest;
  IF s1.id IS NULL OR s2.id IS NULL THEN RAISE EXCEPTION 'session de caisse inconnue'; END IF;
  IF s1.statut <> 'ouverte' OR s2.statut <> 'ouverte' THEN RAISE EXCEPTION 'les deux sessions doivent être ouvertes'; END IF;
  SELECT * INTO k1 FROM mf.caisse WHERE id = s1.caisse_id;
  SELECT * INTO k2 FROM mf.caisse WHERE id = s2.caisse_id;
  IF k1.agence_id <> k2.agence_id THEN RAISE EXCEPTION 'un transfert de caisse reste dans la même agence'; END IF;
  INSERT INTO mf.transfert_caisse(agence_id, session_source, session_dest, montant, date_operation, motif, utilisateur_id)
  VALUES (k1.agence_id, p_source, p_dest, p_montant, p_date, p_motif, p_utilisateur) RETURNING id INTO v_id;
  PERFORM mf.caisse_operation(p_source, 'decaissement', 'transfert_sortant', p_montant, p_date, 'transfert_caisse', v_id,
                              'Transfert vers ' || k2.code || COALESCE(' : ' || p_motif, ''));
  PERFORM mf.caisse_operation(p_dest, 'encaissement', 'transfert_entrant', p_montant, p_date, 'transfert_caisse', v_id,
                              'Transfert depuis ' || k1.code || COALESCE(' : ' || p_motif, ''));
  RETURN v_id;
END $$;

-- ---------------------------------------------------------------------
-- Comptes bancaires de l'agence
-- ---------------------------------------------------------------------
CREATE TABLE compte_banque (
  id            serial PRIMARY KEY,
  agence_id     smallint NOT NULL REFERENCES agence(id),
  code          varchar(10) NOT NULL,
  libelle       text NOT NULL,
  banque        text,
  numero_compte text,
  actif         boolean NOT NULL DEFAULT true,
  UNIQUE (agence_id, code)
);

CREATE TABLE mouvement_banque (
  id              bigserial PRIMARY KEY,
  compte_banque_id integer NOT NULL REFERENCES compte_banque(id),
  date_operation  date NOT NULL,
  type            varchar(20) NOT NULL CHECK (type IN
                    ('versement_caisse','retrait_caisse','depot_externe','retrait_externe','frais','interets')),
  montant         numeric(14,0) NOT NULL CHECK (montant > 0),
  libelle         text,
  reference_table text,
  reference_id    bigint,
  rapproche       boolean NOT NULL DEFAULT false,      -- pointé sur le relevé de la banque
  rapproche_le    date,
  utilisateur_id  integer REFERENCES utilisateur(id),
  cree_le         timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX mouvement_banque_compte ON mouvement_banque (compte_banque_id, date_operation);

CREATE FUNCTION sens_mouvement_banque(p_type text) RETURNS smallint
LANGUAGE sql IMMUTABLE AS $$
  SELECT CASE WHEN p_type IN ('versement_caisse','depot_externe','interets') THEN 1 ELSE -1 END::smallint
$$;

CREATE VIEW v_solde_compte_banque AS
SELECT b.id AS compte_banque_id, b.agence_id, b.code, b.libelle,
       COALESCE(sum(m.montant * mf.sens_mouvement_banque(m.type)), 0)::numeric(14,0) AS solde
  FROM compte_banque b LEFT JOIN mouvement_banque m ON m.compte_banque_id = b.id
 GROUP BY b.id;

-- Pas de découvert : une sortie ne peut dépasser le solde (verrou sur le compte contre deux sorties simultanées).
CREATE FUNCTION trg_mouvement_banque_controle() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE b mf.compte_banque; v_solde numeric;
BEGIN
  SELECT * INTO b FROM mf.compte_banque WHERE id = NEW.compte_banque_id FOR UPDATE;
  IF NOT b.actif THEN RAISE EXCEPTION 'compte bancaire % désactivé', b.code; END IF;
  IF mf.sens_mouvement_banque(NEW.type) < 0 THEN
    SELECT solde INTO v_solde FROM mf.v_solde_compte_banque WHERE compte_banque_id = NEW.compte_banque_id;
    IF NEW.montant > v_solde THEN
      RAISE EXCEPTION 'solde bancaire insuffisant sur % : % demandé, % disponible', b.code, NEW.montant, v_solde;
    END IF;
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER mouvement_banque_controle BEFORE INSERT ON mouvement_banque
  FOR EACH ROW EXECUTE FUNCTION trg_mouvement_banque_controle();

-- Versement de la caisse en banque : décaissement de caisse + entrée en banque.
CREATE FUNCTION versement_en_banque(p_session integer, p_compte_banque integer, p_montant numeric,
                                    p_date date DEFAULT current_date, p_libelle text DEFAULT NULL,
                                    p_utilisateur integer DEFAULT NULL) RETURNS bigint
LANGUAGE plpgsql AS $$
DECLARE k mf.caisse; b mf.compte_banque; v_op bigint; v_id bigint;
BEGIN
  SELECT c.* INTO k FROM mf.caisse c JOIN mf.session_caisse s ON s.caisse_id = c.id WHERE s.id = p_session;
  IF NOT FOUND THEN RAISE EXCEPTION 'session de caisse % inconnue', p_session; END IF;
  SELECT * INTO b FROM mf.compte_banque WHERE id = p_compte_banque;
  IF NOT FOUND THEN RAISE EXCEPTION 'compte bancaire % inconnu', p_compte_banque; END IF;
  IF b.agence_id <> k.agence_id THEN RAISE EXCEPTION 'la caisse et le compte bancaire sont d''agences différentes'; END IF;
  v_op := mf.caisse_operation(p_session, 'decaissement', 'versement_banque', p_montant, p_date, 'compte_banque', p_compte_banque,
                              COALESCE(p_libelle, 'Versement en banque ' || b.code));
  INSERT INTO mf.mouvement_banque(compte_banque_id, date_operation, type, montant, libelle, reference_table, reference_id, utilisateur_id)
  VALUES (p_compte_banque, p_date, 'versement_caisse', p_montant, COALESCE(p_libelle, 'Versement depuis la caisse ' || k.code),
          'operation_caisse', v_op, p_utilisateur) RETURNING id INTO v_id;
  RETURN v_id;
END $$;

-- Retrait en banque alimentant la caisse : sortie de banque (solde contrôlé) + encaissement de caisse.
CREATE FUNCTION retrait_en_banque(p_session integer, p_compte_banque integer, p_montant numeric,
                                  p_date date DEFAULT current_date, p_libelle text DEFAULT NULL,
                                  p_utilisateur integer DEFAULT NULL) RETURNS bigint
LANGUAGE plpgsql AS $$
DECLARE k mf.caisse; b mf.compte_banque; v_op bigint; v_id bigint;
BEGIN
  SELECT c.* INTO k FROM mf.caisse c JOIN mf.session_caisse s ON s.caisse_id = c.id WHERE s.id = p_session;
  IF NOT FOUND THEN RAISE EXCEPTION 'session de caisse % inconnue', p_session; END IF;
  SELECT * INTO b FROM mf.compte_banque WHERE id = p_compte_banque;
  IF NOT FOUND THEN RAISE EXCEPTION 'compte bancaire % inconnu', p_compte_banque; END IF;
  IF b.agence_id <> k.agence_id THEN RAISE EXCEPTION 'la caisse et le compte bancaire sont d''agences différentes'; END IF;
  INSERT INTO mf.mouvement_banque(compte_banque_id, date_operation, type, montant, libelle, utilisateur_id)
  VALUES (p_compte_banque, p_date, 'retrait_caisse', p_montant, COALESCE(p_libelle, 'Retrait pour la caisse ' || k.code), p_utilisateur)
  RETURNING id INTO v_id;
  v_op := mf.caisse_operation(p_session, 'encaissement', 'retrait_banque', p_montant, p_date, 'compte_banque', p_compte_banque,
                              COALESCE(p_libelle, 'Retrait en banque ' || b.code));
  UPDATE mf.mouvement_banque SET reference_table = 'operation_caisse', reference_id = v_op WHERE id = v_id;
  RETURN v_id;
END $$;

-- Pointage d'un mouvement sur le relevé de la banque.
CREATE FUNCTION rapprocher_mouvement_banque(p_mouvement bigint, p_date date DEFAULT current_date, p_rapproche boolean DEFAULT true)
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  UPDATE mf.mouvement_banque SET rapproche = p_rapproche, rapproche_le = CASE WHEN p_rapproche THEN p_date END WHERE id = p_mouvement;
  IF NOT FOUND THEN RAISE EXCEPTION 'mouvement bancaire % inconnu', p_mouvement; END IF;
END $$;

-- ---------------------------------------------------------------------
-- États : caisses d'un jour, liquidités, indicateurs, prévision
-- ---------------------------------------------------------------------
-- Solde théorique d'une session à une date : ouverture + opérations datées au plus tard ce jour.
CREATE FUNCTION solde_session_a_date(p_session integer, p_date date) RETURNS numeric
LANGUAGE sql STABLE AS $$
  SELECT s.solde_ouverture
         + COALESCE((SELECT sum(CASE o.type WHEN 'encaissement' THEN o.montant ELSE -o.montant END)
                       FROM mf.operation_caisse o WHERE o.session_id = s.id AND o.date_operation <= p_date), 0)
    FROM mf.session_caisse s WHERE s.id = p_session
$$;

-- État de chaque caisse active : non ouverte / ouverte / fermée à la date, solde, dépassement du plafond.
CREATE FUNCTION etat_caisses(p_agence smallint, p_date date)
RETURNS TABLE (caisse_id integer, code varchar, type varchar, libelle text, responsable text, plafond numeric,
               etat text, session_id integer, solde numeric, depassement_plafond numeric)
LANGUAGE sql STABLE AS $$
  SELECT k.id, k.code, k.type, k.libelle, u.nom::text, k.plafond,
         CASE WHEN s.id IS NULL THEN 'non_ouverte' WHEN s.statut = 'ouverte' THEN 'ouverte' ELSE 'fermee' END,
         s.id,
         CASE WHEN s.id IS NULL THEN dernier.solde
              WHEN s.statut = 'fermee' THEN s.solde_compte
              ELSE mf.solde_session_a_date(s.id, p_date) END,
         CASE WHEN k.plafond IS NULL THEN 0
              ELSE GREATEST(COALESCE(CASE WHEN s.id IS NULL THEN dernier.solde
                                          WHEN s.statut = 'fermee' THEN s.solde_compte
                                          ELSE mf.solde_session_a_date(s.id, p_date) END, 0) - k.plafond, 0) END
    FROM mf.caisse k
    LEFT JOIN mf.utilisateur u ON u.id = k.responsable_id
    LEFT JOIN LATERAL (SELECT * FROM mf.session_caisse x WHERE x.caisse_id = k.id AND x.date_session = p_date LIMIT 1) s ON true
    LEFT JOIN LATERAL (SELECT COALESCE(y.solde_compte, mf.solde_session_a_date(y.id, p_date)) AS solde
                         FROM mf.session_caisse y WHERE y.caisse_id = k.id AND y.date_session < p_date
                        ORDER BY y.date_session DESC LIMIT 1) dernier ON true
   WHERE k.agence_id = p_agence AND k.actif
   ORDER BY k.type, k.code
$$;

-- Liquidités à une date : une ligne par caisse (dernier solde connu) et par compte bancaire.
CREATE FUNCTION tresorerie_liquidites(p_agence smallint, p_date date)
RETURNS TABLE (nature text, code text, libelle text, solde numeric, detail text)
LANGUAGE sql STABLE AS $$
  SELECT 'caisse'::text, e.code::text, COALESCE(e.libelle, e.code)::text, COALESCE(e.solde, 0),
         CASE e.etat WHEN 'ouverte' THEN 'session ouverte' WHEN 'fermee' THEN 'session fermée' ELSE 'non ouverte ce jour (dernier solde connu)' END
    FROM mf.etat_caisses(p_agence, p_date) e
  UNION ALL
  SELECT 'banque', b.code::text, (b.libelle || COALESCE(' — ' || b.banque, ''))::text,
         COALESCE((SELECT sum(m.montant * mf.sens_mouvement_banque(m.type)) FROM mf.mouvement_banque m
                    WHERE m.compte_banque_id = b.id AND m.date_operation <= p_date), 0),
         COALESCE((SELECT count(*)::text || ' mouvement(s) non rapproché(s)' FROM mf.mouvement_banque m
                    WHERE m.compte_banque_id = b.id AND m.date_operation <= p_date AND NOT m.rapproche), '')
    FROM mf.compte_banque b WHERE b.agence_id = p_agence AND b.actif
$$;

-- Indicateurs de trésorerie. Les liquidités et les échéances sont calculées à la date demandée ;
-- les engagements envers les clients et les retraits en attente reflètent l'état au moment de la lecture.
CREATE FUNCTION tresorerie_indicateurs(p_agence smallint, p_date date)
RETURNS TABLE (rubrique text, valeur numeric)
LANGUAGE plpgsql STABLE AS $$
DECLARE v_liq numeric; v_epargne numeric; v_tontine numeric; v_eng numeric;
BEGIN
  SELECT COALESCE(sum(solde), 0) INTO v_liq FROM mf.tresorerie_liquidites(p_agence, p_date);
  SELECT COALESCE(sum(v.solde), 0) INTO v_epargne FROM mf.v_solde_compte_epargne v WHERE v.agence_id = p_agence;
  SELECT COALESCE(sum(s.montant_collecte - COALESCE(r.rembourse, 0)), 0) INTO v_tontine
    FROM mf.v_cycle_situation s
    LEFT JOIN (SELECT cycle_id, sum(montant) rembourse FROM mf.retrait WHERE nature = 'remboursement' AND statut <> 'annule' GROUP BY cycle_id) r
           ON r.cycle_id = s.cycle_id
   WHERE s.agence_id = p_agence AND s.statut <> 'retire';
  v_eng := v_epargne + v_tontine;
  RETURN QUERY VALUES
    ('liquidites_caisses'::text, COALESCE((SELECT sum(solde) FROM mf.tresorerie_liquidites(p_agence, p_date) WHERE nature = 'caisse'), 0)::numeric),
    ('liquidites_banques', COALESCE((SELECT sum(solde) FROM mf.tresorerie_liquidites(p_agence, p_date) WHERE nature = 'banque'), 0)::numeric),
    ('liquidites_totales', v_liq),
    ('depassement_plafonds_caisses', COALESCE((SELECT sum(depassement_plafond) FROM mf.etat_caisses(p_agence, p_date)), 0)::numeric),
    ('echeances_en_retard', COALESCE((SELECT sum(mf.du_echeance_a_date(e.id, p_date)) FROM mf.echeance e JOIN mf.credit c ON c.id = e.credit_id
        WHERE c.agence_id = p_agence AND e.date_prevue < p_date AND mf.du_echeance_a_date(e.id, p_date) > 0), 0)::numeric),
    ('a_recevoir_7_jours', COALESCE((SELECT sum(mf.du_echeance_a_date(e.id, p_date)) FROM mf.echeance e JOIN mf.credit c ON c.id = e.credit_id
        WHERE c.agence_id = p_agence AND e.date_prevue BETWEEN p_date AND p_date + 7 AND mf.du_echeance_a_date(e.id, p_date) > 0), 0)::numeric),
    ('a_recevoir_30_jours', COALESCE((SELECT sum(mf.du_echeance_a_date(e.id, p_date)) FROM mf.echeance e JOIN mf.credit c ON c.id = e.credit_id
        WHERE c.agence_id = p_agence AND e.date_prevue BETWEEN p_date AND p_date + 30 AND mf.du_echeance_a_date(e.id, p_date) > 0), 0)::numeric),
    ('retraits_clients_en_attente', COALESCE((SELECT sum(r.montant) FROM mf.retrait r WHERE r.agence_id = p_agence AND r.decaissement
        AND r.statut IN ('demande','ecart_en_traitement','fonds_disponibles')), 0)::numeric),
    ('commissions_a_payer', COALESCE((SELECT sum(commission_nette) FROM mf.commission_collectrice WHERE agence_id = p_agence AND statut = 'calculee'), 0)::numeric),
    ('epargne_classique', v_epargne),
    ('tontine_a_rembourser', v_tontine),
    ('engagements_clients', v_eng),
    ('ratio_liquidite_pct', CASE WHEN v_eng > 0 THEN round(v_liq * 100 / v_eng, 1) ELSE NULL END);
END $$;

-- Prévision par tranches de p_pas jours sur p_jours jours : encaissements = échéances impayées attendues dans la
-- tranche ; décaissements = retraits clients en attente (première tranche). Les autres flux (salaires, charges,
-- collecte à venir) ne sont pas prévisibles ici.
CREATE FUNCTION prevision_tresorerie(p_agence smallint, p_date date, p_jours integer DEFAULT 30, p_pas integer DEFAULT 7)
RETURNS TABLE (debut date, fin date, encaissements numeric, decaissements numeric, solde_projete numeric)
LANGUAGE plpgsql STABLE AS $$
DECLARE v_solde numeric; t record; v_enc numeric; v_dec numeric;
BEGIN
  IF p_pas < 1 OR p_jours < 1 THEN RAISE EXCEPTION 'paramètres de prévision invalides'; END IF;
  SELECT COALESCE(sum(solde), 0) INTO v_solde FROM mf.tresorerie_liquidites(p_agence, p_date);
  FOR t IN SELECT g AS i FROM generate_series(0, p_jours - 1, p_pas) g LOOP
    debut := p_date + t.i;
    fin := LEAST(p_date + t.i + p_pas - 1, p_date + p_jours - 1);
    SELECT COALESCE(sum(mf.du_echeance_a_date(e.id, p_date)), 0) INTO v_enc
      FROM mf.echeance e JOIN mf.credit c ON c.id = e.credit_id
     WHERE c.agence_id = p_agence AND e.date_prevue BETWEEN debut AND fin AND mf.du_echeance_a_date(e.id, p_date) > 0;
    v_dec := CASE WHEN t.i = 0 THEN
      COALESCE((SELECT sum(r.montant) FROM mf.retrait r WHERE r.agence_id = p_agence AND r.decaissement
                 AND r.statut IN ('demande','ecart_en_traitement','fonds_disponibles')), 0) ELSE 0 END;
    v_solde := v_solde + v_enc - v_dec;
    encaissements := v_enc; decaissements := v_dec; solde_projete := v_solde;
    RETURN NEXT;
  END LOOP;
END $$;

-- ---------------------------------------------------------------------
-- Comptabilisation (désactivée par défaut, voir 10) : versement / retrait en banque et frais bancaires.
-- Compte 1141 « Banques et correspondants » ; frais bancaires en 6081 (à valider par le comptable).
-- Les transferts entre caisses n'ont pas d'effet comptable (même compte 1011).
-- ---------------------------------------------------------------------
INSERT INTO regle_comptable(evenement, ligne, compte_debit, compte_credit, cle_montant, journal_code, libelle) VALUES
  ('versement_banque', 1, '1141', '1011', 'montant', 'CAI', 'Versement de la caisse en banque'),
  ('retrait_banque',   1, '1011', '1141', 'montant', 'CAI', 'Retrait en banque pour la caisse'),
  ('frais_bancaires',  1, '6081', '1141', 'montant', 'CAI', 'Frais bancaires');

CREATE FUNCTION trg_compta_mouvement_banque() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE v_agence smallint; v_evt text;
BEGIN
  v_evt := CASE NEW.type WHEN 'versement_caisse' THEN 'versement_banque' WHEN 'retrait_caisse' THEN 'retrait_banque'
                         WHEN 'frais' THEN 'frais_bancaires' END;
  IF v_evt IS NULL THEN RETURN NULL; END IF;
  SELECT agence_id INTO v_agence FROM mf.compte_banque WHERE id = NEW.compte_banque_id;
  IF mf.comptabilisation_active(v_agence) THEN
    PERFORM mf.comptabiliser(v_evt, v_agence, NEW.date_operation, jsonb_build_object('montant', NEW.montant),
                             'mouvement_banque', NEW.id, NEW.libelle);
  END IF;
  RETURN NULL;
END $$;
CREATE TRIGGER compta_mouvement_banque AFTER INSERT ON mouvement_banque
  FOR EACH ROW EXECUTE FUNCTION trg_compta_mouvement_banque();

-- Piste d'audit
CREATE TRIGGER audit_transfert_caisse AFTER INSERT OR UPDATE OR DELETE ON transfert_caisse FOR EACH ROW EXECUTE FUNCTION trg_audit();
CREATE TRIGGER audit_compte_banque AFTER INSERT OR UPDATE OR DELETE ON compte_banque FOR EACH ROW EXECUTE FUNCTION trg_audit();
CREATE TRIGGER audit_mouvement_banque AFTER INSERT OR UPDATE OR DELETE ON mouvement_banque FOR EACH ROW EXECUTE FUNCTION trg_audit();
CREATE TRIGGER audit_caisse AFTER INSERT OR UPDATE OR DELETE ON caisse FOR EACH ROW EXECUTE FUNCTION trg_audit();

-- =====================================================================
-- MODULE 14_rapports_credit_financier.sql
-- =====================================================================
-- =====================================================================
-- 14_rapports_credit_financier.sql
-- Rapports de crédit (portefeuille, portefeuille à risque, retard par tranche, activité d'une période) et rapport
-- financier (compte d'exploitation opérationnel + bilan simplifié issu de la comptabilité).
-- Comme 09_rapports.sql : tout est calculé à partir des DATES MÉTIER, donc reproductible pour une date passée.
-- Lecture seule : aucune table. Dépend de : 03, 04, 05, 08, 09, 13.
-- =====================================================================
SET search_path = mf, public;

-- ---------------------------------------------------------------------
-- Portefeuille à une date : crédits débloqués au plus tard ce jour et non soldés à cette date.
-- jours_retard = ancienneté de l'échéance impayée la plus ancienne (capital + intérêts impayés à cette date).
-- ---------------------------------------------------------------------
CREATE FUNCTION portefeuille_a_date(p_agence smallint, p_date date)
RETURNS TABLE (credit_id integer, numero text, client_id integer, client text, type text, mode_remboursement text,
               produit text, montant_accorde numeric, capital_restant numeric, jours_retard integer,
               nb_echeances_en_retard integer, montant_en_retard numeric, garantie_bloquee numeric)
LANGUAGE sql STABLE AS $$
  SELECT c.id, c.numero::text, c.client_id, cl.nom::text, c.type::text, c.mode_remboursement::text,
         COALESCE(pr.code, '—')::text, c.montant_accorde,
         c.montant_accorde - COALESCE((SELECT sum(p.capital) FROM mf.paiement_echeance p
                                        WHERE p.credit_id = c.id AND p.date_operation <= p_date), 0),
         COALESCE(r.jours, 0), COALESCE(r.nb, 0), COALESCE(r.montant, 0),
         CASE WHEN g.id IS NULL OR (g.libere_le IS NOT NULL AND g.libere_le <= p_date) THEN 0
              ELSE g.montant_bloque - COALESCE((SELECT sum(p.capital + p.interet + p.penalite) FROM mf.paiement_echeance p
                                                  WHERE p.credit_id = c.id AND p.source = 'saisie_garantie'
                                                    AND p.date_operation <= p_date), 0) END
    FROM mf.credit c
    JOIN mf.client cl ON cl.id = c.client_id
    LEFT JOIN mf.demande_credit d ON d.credit_id = c.id
    LEFT JOIN mf.produit_credit_epargne pr ON pr.id = d.produit_id
    LEFT JOIN mf.garantie_compte g ON g.credit_id = c.id
    LEFT JOIN LATERAL (
        SELECT max(p_date - e.date_prevue)::integer AS jours, count(*)::integer AS nb, sum(x.du) AS montant
          FROM mf.echeance e
          CROSS JOIN LATERAL (SELECT mf.du_echeance_a_date(e.id, p_date) AS du) x
         WHERE e.credit_id = c.id AND e.date_prevue < p_date AND x.du > 0) r ON true
   WHERE c.agence_id = p_agence AND c.date_deblocage <= p_date AND (c.date_solde IS NULL OR c.date_solde > p_date)
$$;

-- Indicateurs du portefeuille. PAR n = capital restant des crédits dont l'impayé le plus ancien dépasse n jours.
CREATE FUNCTION rapport_portefeuille(p_agence smallint, p_date date)
RETURNS TABLE (rubrique text, valeur numeric)
LANGUAGE plpgsql STABLE AS $$
DECLARE v_enc numeric; v_nb integer; v_par1 numeric; v_par30 numeric; v_par60 numeric; v_par90 numeric;
BEGIN
  SELECT COALESCE(sum(capital_restant), 0), count(*),
         COALESCE(sum(capital_restant) FILTER (WHERE jours_retard >= 1), 0),
         COALESCE(sum(capital_restant) FILTER (WHERE jours_retard > 30), 0),
         COALESCE(sum(capital_restant) FILTER (WHERE jours_retard > 60), 0),
         COALESCE(sum(capital_restant) FILTER (WHERE jours_retard > 90), 0)
    INTO v_enc, v_nb, v_par1, v_par30, v_par60, v_par90
    FROM mf.portefeuille_a_date(p_agence, p_date);
  RETURN QUERY VALUES
    ('credits_actifs'::text, v_nb::numeric),
    ('encours_capital', v_enc),
    ('credits_en_retard', COALESCE((SELECT count(*) FROM mf.portefeuille_a_date(p_agence, p_date) WHERE jours_retard >= 1), 0)::numeric),
    ('impaye_capital_interets', COALESCE((SELECT sum(montant_en_retard) FROM mf.portefeuille_a_date(p_agence, p_date)), 0)),
    ('par_1_jour', v_par1), ('par_30_jours', v_par30), ('par_60_jours', v_par60), ('par_90_jours', v_par90),
    ('par_1_jour_pct', CASE WHEN v_enc > 0 THEN round(v_par1 * 100 / v_enc, 2) END),
    ('par_30_jours_pct', CASE WHEN v_enc > 0 THEN round(v_par30 * 100 / v_enc, 2) END),
    ('par_60_jours_pct', CASE WHEN v_enc > 0 THEN round(v_par60 * 100 / v_enc, 2) END),
    ('par_90_jours_pct', CASE WHEN v_enc > 0 THEN round(v_par90 * 100 / v_enc, 2) END),
    ('garanties_bloquees', COALESCE((SELECT sum(garantie_bloquee) FROM mf.portefeuille_a_date(p_agence, p_date)), 0)),
    ('credits_soldes_a_ce_jour', COALESCE((SELECT count(*) FROM mf.credit WHERE agence_id = p_agence AND date_solde IS NOT NULL AND date_solde <= p_date), 0)::numeric);
END $$;

-- Retard par tranche d'ancienneté de l'impayé.
CREATE FUNCTION rapport_retard_par_tranche(p_agence smallint, p_date date)
RETURNS TABLE (ordre integer, tranche text, nb_credits bigint, capital_restant numeric, montant_en_retard numeric)
LANGUAGE sql STABLE AS $$
  WITH p AS (SELECT * FROM mf.portefeuille_a_date(p_agence, p_date)),
       t(ordre, tranche, bas, haut) AS (VALUES
         (1, 'À jour', 0, 0), (2, '1 à 30 jours', 1, 30), (3, '31 à 60 jours', 31, 60),
         (4, '61 à 90 jours', 61, 90), (5, '91 à 180 jours', 91, 180), (6, 'Plus de 180 jours', 181, 1000000))
  SELECT t.ordre, t.tranche, count(p.credit_id), COALESCE(sum(p.capital_restant), 0), COALESCE(sum(p.montant_en_retard), 0)
    FROM t LEFT JOIN p ON p.jours_retard BETWEEN t.bas AND t.haut
   GROUP BY t.ordre, t.tranche ORDER BY t.ordre
$$;

-- Répartition de l'encours selon un critère : 'type', 'mode' ou 'produit'.
CREATE FUNCTION portefeuille_repartition(p_agence smallint, p_date date, p_critere text)
RETURNS TABLE (cle text, nb_credits bigint, encours numeric, encours_en_retard numeric)
LANGUAGE plpgsql STABLE AS $$
BEGIN
  IF p_critere NOT IN ('type','mode','produit') THEN RAISE EXCEPTION 'critère inconnu : % (type, mode, produit)', p_critere; END IF;
  RETURN QUERY
  SELECT CASE p_critere WHEN 'type' THEN p.type WHEN 'mode' THEN p.mode_remboursement ELSE p.produit END,
         count(*), COALESCE(sum(p.capital_restant), 0), COALESCE(sum(p.capital_restant) FILTER (WHERE p.jours_retard >= 1), 0)
    FROM mf.portefeuille_a_date(p_agence, p_date) p
   GROUP BY 1 ORDER BY 3 DESC;
END $$;

-- Activité de crédit sur une période : décaissements, recouvrement, soldés.
-- taux_recouvrement_pct = part du capital et des intérêts des échéances tombées dans la période qui est payée à la fin de la période.
CREATE FUNCTION rapport_credits_periode(p_agence smallint, p_du date, p_au date)
RETURNS TABLE (rubrique text, valeur numeric)
LANGUAGE plpgsql STABLE AS $$
DECLARE v_du_attendu numeric; v_recouvre numeric;
BEGIN
  SELECT COALESCE(sum(e.capital + e.interet), 0),
         COALESCE(sum(LEAST(e.capital + e.interet,
                            (SELECT COALESCE(sum(p.capital + p.interet), 0) FROM mf.paiement_echeance p
                              WHERE p.echeance_id = e.id AND p.date_operation <= p_au))), 0)
    INTO v_du_attendu, v_recouvre
    FROM mf.echeance e JOIN mf.credit c ON c.id = e.credit_id
   WHERE c.agence_id = p_agence AND e.date_prevue BETWEEN p_du AND p_au;
  RETURN QUERY VALUES
    ('credits_debloques_nb'::text, COALESCE((SELECT count(*) FROM mf.credit WHERE agence_id = p_agence AND date_deblocage BETWEEN p_du AND p_au), 0)::numeric),
    ('credits_debloques_montant', COALESCE((SELECT sum(montant_accorde) FROM mf.credit WHERE agence_id = p_agence AND date_deblocage BETWEEN p_du AND p_au), 0)),
    ('frais_de_dossier', COALESCE((SELECT sum(frais_dossier) FROM mf.credit WHERE agence_id = p_agence AND date_deblocage BETWEEN p_du AND p_au), 0)),
    ('remboursements_capital', COALESCE((SELECT sum(p.capital) FROM mf.paiement_echeance p JOIN mf.credit c ON c.id = p.credit_id
        WHERE c.agence_id = p_agence AND p.date_operation BETWEEN p_du AND p_au), 0)),
    ('remboursements_interets', COALESCE((SELECT sum(p.interet) FROM mf.paiement_echeance p JOIN mf.credit c ON c.id = p.credit_id
        WHERE c.agence_id = p_agence AND p.date_operation BETWEEN p_du AND p_au), 0)),
    ('remboursements_penalites', COALESCE((SELECT sum(p.penalite) FROM mf.paiement_echeance p JOIN mf.credit c ON c.id = p.credit_id
        WHERE c.agence_id = p_agence AND p.date_operation BETWEEN p_du AND p_au), 0)),
    ('remboursements_par_tontine', COALESCE((SELECT sum(p.capital + p.interet + p.penalite) FROM mf.paiement_echeance p JOIN mf.credit c ON c.id = p.credit_id
        WHERE c.agence_id = p_agence AND p.date_operation BETWEEN p_du AND p_au AND p.source = 'tontine'), 0)),
    ('remboursements_par_prelevement', COALESCE((SELECT sum(p.capital + p.interet + p.penalite) FROM mf.paiement_echeance p JOIN mf.credit c ON c.id = p.credit_id
        WHERE c.agence_id = p_agence AND p.date_operation BETWEEN p_du AND p_au AND p.source = 'prelevement'), 0)),
    ('remboursements_en_especes', COALESCE((SELECT sum(p.capital + p.interet + p.penalite) FROM mf.paiement_echeance p JOIN mf.credit c ON c.id = p.credit_id
        WHERE c.agence_id = p_agence AND p.date_operation BETWEEN p_du AND p_au AND p.source = 'especes'), 0)),
    ('garanties_saisies', COALESCE((SELECT sum(p.capital + p.interet + p.penalite) FROM mf.paiement_echeance p JOIN mf.credit c ON c.id = p.credit_id
        WHERE c.agence_id = p_agence AND p.date_operation BETWEEN p_du AND p_au AND p.source = 'saisie_garantie'), 0)),
    ('credits_soldes', COALESCE((SELECT count(*) FROM mf.credit WHERE agence_id = p_agence AND date_solde BETWEEN p_du AND p_au), 0)::numeric),
    ('echeances_attendues', v_du_attendu),
    ('echeances_recouvrees', v_recouvre),
    ('taux_recouvrement_pct', CASE WHEN v_du_attendu > 0 THEN round(v_recouvre * 100 / v_du_attendu, 1) END);
END $$;

-- ---------------------------------------------------------------------
-- Rapport financier : compte d'exploitation OPÉRATIONNEL d'une période, calculé à partir des opérations
-- (donc disponible même sans comptabilisation automatique). Ce n'est pas un état réglementaire.
--   produits : intérêts, pénalités, frais de dossier, mises de tontine retenues à l'exécution des retraits,
--              excédents de caisse, intérêts bancaires ;
--   charges  : commissions brutes des collectrices, salaires et charges patronales des bulletins validés,
--              manquants de caisse, frais bancaires.
-- Non modélisés : intérêts servis sur l'épargne, provisions, amortissements. Les créances sur les agents
-- (manquants, pertes) ne sont pas des charges tant qu'elles ne sont pas passées en perte : elles figurent en information.
-- ---------------------------------------------------------------------
CREATE FUNCTION rapport_financier(p_agence smallint, p_du date, p_au date)
RETURNS TABLE (section text, rubrique text, libelle text, valeur numeric)
LANGUAGE sql STABLE AS $$
  WITH base(ordre, section, rubrique, libelle, valeur) AS (VALUES
    (1, 'produit', 'interets_credits', 'Intérêts sur crédits',
       COALESCE((SELECT sum(p.interet) FROM mf.paiement_echeance p JOIN mf.credit c ON c.id = p.credit_id
                  WHERE c.agence_id = p_agence AND p.date_operation BETWEEN p_du AND p_au), 0)::numeric),
    (2, 'produit', 'penalites', 'Pénalités de retard',
       COALESCE((SELECT sum(p.penalite) FROM mf.paiement_echeance p JOIN mf.credit c ON c.id = p.credit_id
                  WHERE c.agence_id = p_agence AND p.date_operation BETWEEN p_du AND p_au), 0)::numeric),
    (3, 'produit', 'frais_dossier', 'Frais de dossier',
       COALESCE((SELECT sum(frais_dossier) FROM mf.credit WHERE agence_id = p_agence AND date_deblocage BETWEEN p_du AND p_au), 0)::numeric),
    (4, 'produit', 'mises_tontine', 'Mises de tontine retenues (commission de collecte)',
       COALESCE((SELECT sum(COALESCE(cy.mise_finale, cy.mise_courante)) FROM mf.retrait r JOIN mf.cycle cy ON cy.id = r.cycle_id
                  WHERE r.agence_id = p_agence AND r.statut = 'execute' AND r.nature IN ('retrait_client','virement_vers_epargne')
                    AND r.date_operation BETWEEN p_du AND p_au), 0)::numeric),
    (5, 'produit', 'excedents_caisse', 'Excédents de caisse',
       COALESCE((SELECT sum(s.ecart_fermeture) FROM mf.session_caisse s JOIN mf.caisse k ON k.id = s.caisse_id
                  WHERE k.agence_id = p_agence AND s.date_session BETWEEN p_du AND p_au AND s.ecart_fermeture > 0), 0)::numeric),
    (6, 'produit', 'interets_bancaires', 'Intérêts bancaires',
       COALESCE((SELECT sum(m.montant) FROM mf.mouvement_banque m JOIN mf.compte_banque b ON b.id = m.compte_banque_id
                  WHERE b.agence_id = p_agence AND m.type = 'interets' AND m.date_operation BETWEEN p_du AND p_au), 0)::numeric),
    (7, 'charge', 'commissions_collectrices', 'Commissions des collectrices (brutes)',
       COALESCE((SELECT sum(commission_brute) FROM mf.commission_collectrice
                  WHERE agence_id = p_agence AND periode_fin BETWEEN p_du AND p_au), 0)::numeric),
    (8, 'charge', 'salaires', 'Salaires bruts (bulletins validés)',
       COALESCE((SELECT sum(brut) FROM mf.bulletin_paie WHERE agence_id = p_agence AND statut IN ('valide','paye')
                  AND periode BETWEEN date_trunc('month', p_du)::date AND p_au), 0)::numeric),
    (9, 'charge', 'charges_patronales', 'Charges patronales',
       COALESCE((SELECT sum(charges_patronales) FROM mf.bulletin_paie WHERE agence_id = p_agence AND statut IN ('valide','paye')
                  AND periode BETWEEN date_trunc('month', p_du)::date AND p_au), 0)::numeric),
    (10, 'charge', 'manquants_caisse', 'Manquants de caisse',
       COALESCE((SELECT -sum(s.ecart_fermeture) FROM mf.session_caisse s JOIN mf.caisse k ON k.id = s.caisse_id
                  WHERE k.agence_id = p_agence AND s.date_session BETWEEN p_du AND p_au AND s.ecart_fermeture < 0), 0)::numeric),
    (11, 'charge', 'frais_bancaires', 'Frais bancaires',
       COALESCE((SELECT sum(m.montant) FROM mf.mouvement_banque m JOIN mf.compte_banque b ON b.id = m.compte_banque_id
                  WHERE b.agence_id = p_agence AND m.type = 'frais' AND m.date_operation BETWEEN p_du AND p_au), 0)::numeric)
  ), tot AS (
    SELECT COALESCE(sum(valeur) FILTER (WHERE section = 'produit'), 0) AS prod,
           COALESCE(sum(valeur) FILTER (WHERE section = 'charge'), 0) AS charges FROM base
  )
  SELECT x.section, x.rubrique, x.libelle, x.valeur FROM (
    SELECT ordre, section, rubrique, libelle, valeur FROM base
    UNION ALL SELECT 20, 'resultat', 'total_produits', 'Total des produits', prod FROM tot
    UNION ALL SELECT 21, 'resultat', 'total_charges', 'Total des charges', charges FROM tot
    UNION ALL SELECT 22, 'resultat', 'resultat', 'Résultat de la période', prod - charges FROM tot
    UNION ALL SELECT 30, 'info', 'encours_credits', 'Encours de crédits en fin de période',
         COALESCE((SELECT sum(capital_restant) FROM mf.portefeuille_a_date(p_agence, p_au)), 0)::numeric
    UNION ALL SELECT 31, 'info', 'creances_agents', 'Créances sur les agents (manquants et pertes non recouvrés)',
         COALESCE((SELECT sum(-solde) FROM mf.v_solde_compte_agent WHERE agence_id = p_agence AND solde < 0), 0)::numeric
    UNION ALL SELECT 32, 'info', 'ratio_charges_produits_pct', 'Charges / produits (%)',
         CASE WHEN prod > 0 THEN round(charges * 100 / prod, 1) END FROM tot
  ) x ORDER BY x.ordre
$$;

-- ---------------------------------------------------------------------
-- Bilan simplifié issu de la comptabilité (écritures jusqu'à p_au), par compte de niveau 2 :
-- le solde de chaque compte imputable va à l'actif s'il est débiteur, au passif s'il est créditeur ;
-- les classes 6 et 7 sont résumées en « résultat » ; la classe 9 (hors bilan) est ignorée.
-- Document de travail : ce n'est pas l'état de synthèse réglementaire.
-- ---------------------------------------------------------------------
CREATE FUNCTION bilan_simplifie(p_agence smallint, p_au date)
RETURNS TABLE (cote text, classe char, code varchar, libelle text, montant numeric)
LANGUAGE sql STABLE AS $$
  WITH soldes AS (
    SELECT c.code, c.classe, sum(e.debit - e.credit) AS solde
      FROM mf.ecriture e
      JOIN mf.piece_comptable p ON p.id = e.piece_id
      JOIN mf.compte_comptable c ON c.code = e.compte_code
     WHERE (p_agence IS NULL OR p.agence_id = p_agence) AND p.date_piece <= p_au AND c.classe NOT IN ('6','7','9')
     GROUP BY c.code, c.classe
  ), n2 AS (
    SELECT CASE WHEN solde > 0 THEN 'actif' ELSE 'passif' END AS cote, s.classe, left(s.code, 2) AS code, abs(sum(solde)) AS montant
      FROM soldes s WHERE solde <> 0 GROUP BY 1, 2, 3
  ), res AS (
    SELECT COALESCE(sum(e.credit - e.debit), 0) AS r
      FROM mf.ecriture e JOIN mf.piece_comptable p ON p.id = e.piece_id JOIN mf.compte_comptable c ON c.code = e.compte_code
     WHERE c.classe IN ('6','7') AND (p_agence IS NULL OR p.agence_id = p_agence) AND p.date_piece <= p_au
  )
  SELECT n2.cote, n2.classe, n2.code::varchar, COALESCE(pc.libelle, n2.code), n2.montant
    FROM n2 LEFT JOIN mf.compte_comptable pc ON pc.code = n2.code
  UNION ALL
  SELECT CASE WHEN r >= 0 THEN 'passif' ELSE 'actif' END, '7'::char, 'RES'::varchar, 'Résultat de l''exercice', abs(r) FROM res WHERE r <> 0
  ORDER BY 1, 3
$$;

-- =====================================================================
-- MODULE 15_transferts_clients.sql
-- =====================================================================
-- =====================================================================
-- 15_transferts_clients.sql
-- Transfert d'un client entre zones (même agence) et entre agences.
--  * historique des zones d'un client : la zone qui compte pour une opération est celle de la
--    date de l'opération (collecte, retrait, remboursement), et non la zone actuelle ;
--  * journal des transferts (zone et agence) ;
--  * transfert d'agence refusé tant que le client a une opération en cours.
-- Dépend de : 00 à 14. Le contrôle des rôles est fait par l'API (perm. clients:transferer).
-- LIMITE : aucune écriture comptable inter-agences n'est générée. Le solde d'épargne qui change
-- d'agence est enregistré dans client_transfert.solde_epargne pour permettre le règlement
-- (compte de liaison) par le comptable ; l'historique financier (cycles retirés, crédits soldés,
-- pièces) reste rattaché à l'agence d'origine.
-- =====================================================================
SET search_path = mf, public;

-- ---------------------------------------------------------------------
-- Historique des zones : une ligne par changement (la première = zone à la création)
-- ---------------------------------------------------------------------
CREATE TABLE client_zone_historique (
  client_id      integer NOT NULL REFERENCES client(id),
  date_effet     date NOT NULL,
  zone_id        integer REFERENCES zone(id),            -- NULL = sans zone
  motif          text,
  utilisateur_id integer REFERENCES utilisateur(id),
  cree_le        timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (client_id, date_effet)
);

CREATE TABLE client_transfert (
  id               serial PRIMARY KEY,
  client_id        integer NOT NULL REFERENCES client(id),
  type             varchar(10) NOT NULL CHECK (type IN ('zone','agence')),
  agence_source_id smallint NOT NULL REFERENCES agence(id),
  agence_dest_id   smallint NOT NULL REFERENCES agence(id),
  zone_source_id   integer REFERENCES zone(id),
  zone_dest_id     integer REFERENCES zone(id),
  date_effet       date NOT NULL,
  motif            text,
  ancien_numero    varchar(20),
  nouveau_numero   varchar(20),
  comptes          jsonb,                                -- [{id, ancien, nouveau}] des comptes d'épargne déplacés
  solde_epargne    numeric(14,0),                        -- solde d'épargne qui change d'agence (règlement inter-agences)
  utilisateur_id   integer REFERENCES utilisateur(id),
  cree_le          timestamptz NOT NULL DEFAULT now(),
  CHECK ((type = 'zone') = (agence_source_id = agence_dest_id))
);
CREATE INDEX client_transfert_client ON client_transfert (client_id, date_effet);

-- Zone d'un client à une date : dernière ligne d'historique dont la date d'effet est atteinte.
CREATE FUNCTION zone_client_a_date(p_client integer, p_date date) RETURNS integer
LANGUAGE sql STABLE AS $$
  SELECT h.zone_id FROM mf.client_zone_historique h
   WHERE h.client_id = p_client AND h.date_effet <= p_date
   ORDER BY h.date_effet DESC LIMIT 1
$$;

-- Zone initiale à la création du client
CREATE FUNCTION trg_client_zone_initiale() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  INSERT INTO mf.client_zone_historique(client_id, date_effet, zone_id, motif) VALUES (NEW.id, DATE '1900-01-01', NEW.zone_id, 'création');
  RETURN NEW;
END $$;
CREATE TRIGGER client_zone_initiale AFTER INSERT ON client FOR EACH ROW EXECUTE FUNCTION trg_client_zone_initiale();

-- La zone et l'agence d'un client ne changent que par les fonctions de transfert (historique cohérent).
CREATE FUNCTION trg_client_garde_transfert() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  IF (NEW.zone_id IS DISTINCT FROM OLD.zone_id OR NEW.agence_id <> OLD.agence_id)
     AND COALESCE(current_setting('mf.transfert_client', true), 'off') <> 'on' THEN
    RAISE EXCEPTION 'la zone ou l''agence d''un client change par transferer_client_zone / transferer_client_agence';
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER client_garde_transfert BEFORE UPDATE OF zone_id, agence_id ON client FOR EACH ROW EXECUTE FUNCTION trg_client_garde_transfert();

-- Clients déjà présents (base existante) : une ligne d'historique initiale
INSERT INTO client_zone_historique(client_id, date_effet, zone_id, motif)
SELECT c.id, DATE '1900-01-01', c.zone_id, 'reprise' FROM client c
 WHERE NOT EXISTS (SELECT 1 FROM client_zone_historique h WHERE h.client_id = c.id);

-- ---------------------------------------------------------------------
-- Transfert de zone (même agence)
-- ---------------------------------------------------------------------
CREATE FUNCTION transferer_client_zone(p_client integer, p_zone integer, p_date date DEFAULT current_date,
                                       p_motif text DEFAULT NULL, p_utilisateur integer DEFAULT NULL) RETURNS integer
LANGUAGE plpgsql AS $$
DECLARE v_cl mf.client; v_z mf.zone; v_dernier date; v_id integer;
BEGIN
  SELECT * INTO v_cl FROM mf.client WHERE id = p_client FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'client % inconnu', p_client; END IF;
  SELECT * INTO v_z FROM mf.zone WHERE id = p_zone;
  IF NOT FOUND THEN RAISE EXCEPTION 'zone % inconnue', p_zone; END IF;
  IF v_z.agence_id <> v_cl.agence_id THEN
    RAISE EXCEPTION 'la zone % appartient à une autre agence : utiliser un transfert d''agence', v_z.code;
  END IF;
  IF v_cl.zone_id IS NOT DISTINCT FROM p_zone THEN
    RAISE EXCEPTION 'le client % est déjà dans la zone %', v_cl.numero, v_z.code;
  END IF;
  IF p_date > current_date THEN RAISE EXCEPTION 'la date d''effet ne peut pas être dans le futur'; END IF;
  SELECT max(h.date_effet) INTO v_dernier FROM mf.client_zone_historique h WHERE h.client_id = p_client;
  IF p_date <= v_dernier THEN
    RAISE EXCEPTION 'la date d''effet (%) doit être postérieure au dernier changement de zone (%)', p_date, v_dernier;
  END IF;

  INSERT INTO mf.client_zone_historique(client_id, date_effet, zone_id, motif, utilisateur_id)
  VALUES (p_client, p_date, p_zone, p_motif, p_utilisateur);
  PERFORM set_config('mf.transfert_client', 'on', true);
  UPDATE mf.client SET zone_id = p_zone WHERE id = p_client;
  PERFORM set_config('mf.transfert_client', 'off', true);
  INSERT INTO mf.client_transfert(client_id, type, agence_source_id, agence_dest_id, zone_source_id, zone_dest_id,
                                  date_effet, motif, utilisateur_id)
  VALUES (p_client, 'zone', v_cl.agence_id, v_cl.agence_id, v_cl.zone_id, p_zone, p_date, p_motif, p_utilisateur)
  RETURNING id INTO v_id;
  RETURN v_id;
END $$;

-- ---------------------------------------------------------------------
-- Transfert d'agence
-- Refusé si le client a : un cycle de collecte non retiré (en cours ou clos non payé), un retrait
-- non terminé, un crédit non soldé, une demande de crédit en attente ou une garantie bloquée.
-- Déplace le client et ses comptes d'épargne ; les numéros sont régénérés dans l'agence d'arrivée.
-- ---------------------------------------------------------------------
CREATE FUNCTION transferer_client_agence(p_client integer, p_agence_dest smallint, p_zone_dest integer DEFAULT NULL,
                                         p_date date DEFAULT current_date, p_motif text DEFAULT NULL,
                                         p_utilisateur integer DEFAULT NULL) RETURNS integer
LANGUAGE plpgsql AS $$
DECLARE
  v_cl mf.client; v_dernier date; v_id integer; v_n integer; v_bloc text[] := '{}';
  v_nouveau varchar(20); v_comptes jsonb := '[]'::jsonb; v_solde numeric := 0; v_ce record; v_num varchar(25);
BEGIN
  SELECT * INTO v_cl FROM mf.client WHERE id = p_client FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'client % inconnu', p_client; END IF;
  IF p_agence_dest = v_cl.agence_id THEN RAISE EXCEPTION 'le client est déjà dans cette agence : utiliser un transfert de zone'; END IF;
  IF NOT EXISTS (SELECT 1 FROM mf.agence WHERE id = p_agence_dest) THEN RAISE EXCEPTION 'agence % inconnue', p_agence_dest; END IF;
  IF p_zone_dest IS NOT NULL AND NOT EXISTS (SELECT 1 FROM mf.zone z WHERE z.id = p_zone_dest AND z.agence_id = p_agence_dest) THEN
    RAISE EXCEPTION 'la zone % n''appartient pas à l''agence de destination', p_zone_dest;
  END IF;
  SELECT count(*) INTO v_n FROM mf.cycle WHERE client_id = p_client AND statut <> 'retire';
  IF v_n > 0 THEN v_bloc := v_bloc || (v_n || ' cycle(s) de collecte non retiré(s)'); END IF;
  SELECT count(*) INTO v_n FROM mf.retrait r JOIN mf.cycle c ON c.id = r.cycle_id
   WHERE c.client_id = p_client AND r.statut NOT IN ('execute', 'annule');
  IF v_n > 0 THEN v_bloc := v_bloc || (v_n || ' retrait(s) en cours'); END IF;
  SELECT count(*) INTO v_n FROM mf.credit WHERE client_id = p_client AND statut <> 'solde';
  IF v_n > 0 THEN v_bloc := v_bloc || (v_n || ' crédit(s) non soldé(s)'); END IF;
  SELECT count(*) INTO v_n FROM mf.demande_credit WHERE client_id = p_client AND statut IN ('demandee', 'approuvee');
  IF v_n > 0 THEN v_bloc := v_bloc || (v_n || ' demande(s) de crédit en attente'); END IF;
  SELECT count(*) INTO v_n FROM mf.garantie_compte g JOIN mf.compte_epargne ce ON ce.id = g.compte_id
   WHERE ce.client_id = p_client AND g.statut = 'bloquee';
  IF v_n > 0 THEN v_bloc := v_bloc || (v_n || ' garantie(s) bloquée(s)'); END IF;
  IF cardinality(v_bloc) > 0 THEN
    RAISE EXCEPTION 'transfert d''agence impossible pour le client % : %', v_cl.numero, array_to_string(v_bloc, ', ');
  END IF;
  IF p_date > current_date THEN RAISE EXCEPTION 'la date d''effet ne peut pas être dans le futur'; END IF;
  SELECT max(h.date_effet) INTO v_dernier FROM mf.client_zone_historique h WHERE h.client_id = p_client;
  IF p_date <= v_dernier THEN
    RAISE EXCEPTION 'la date d''effet (%) doit être postérieure au dernier changement de zone (%)', p_date, v_dernier;
  END IF;

  v_nouveau := mf.prochain_numero('client', p_agence_dest, p_date, 'CL');
  FOR v_ce IN SELECT ce.id, ce.numero, COALESCE(s.solde, 0) AS solde FROM mf.compte_epargne ce
                LEFT JOIN mf.v_solde_compte_epargne s ON s.compte_id = ce.id WHERE ce.client_id = p_client ORDER BY ce.id
  LOOP
    v_num := mf.prochain_numero('compte_epargne', p_agence_dest, p_date, 'CE');
    UPDATE mf.compte_epargne SET agence_id = p_agence_dest, numero = v_num WHERE id = v_ce.id;
    v_comptes := v_comptes || jsonb_build_object('id', v_ce.id, 'ancien', v_ce.numero, 'nouveau', v_num);
    v_solde := v_solde + v_ce.solde;
  END LOOP;

  INSERT INTO mf.client_zone_historique(client_id, date_effet, zone_id, motif, utilisateur_id)
  VALUES (p_client, p_date, p_zone_dest, COALESCE(p_motif, 'transfert d''agence'), p_utilisateur);
  PERFORM set_config('mf.transfert_client', 'on', true);
  UPDATE mf.client SET agence_id = p_agence_dest, zone_id = p_zone_dest, numero = v_nouveau WHERE id = p_client;
  PERFORM set_config('mf.transfert_client', 'off', true);
  INSERT INTO mf.client_transfert(client_id, type, agence_source_id, agence_dest_id, zone_source_id, zone_dest_id, date_effet,
                                  motif, ancien_numero, nouveau_numero, comptes, solde_epargne, utilisateur_id)
  VALUES (p_client, 'agence', v_cl.agence_id, p_agence_dest, v_cl.zone_id, p_zone_dest, p_date,
          p_motif, v_cl.numero, v_nouveau, v_comptes, v_solde, p_utilisateur)
  RETURNING id INTO v_id;
  RETURN v_id;
END $$;

-- ---------------------------------------------------------------------
-- Les rapports et la commission utilisent la zone du client À LA DATE de l'opération
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION production_collectrice(p_collectrice integer, p_du date, p_au date) RETURNS numeric
LANGUAGE plpgsql STABLE AS $$
DECLARE v_agence smallint; v_mode text; v_prod numeric;
BEGIN
  SELECT agence_id INTO v_agence FROM mf.collectrice WHERE id = p_collectrice;
  v_mode := mf.param('mode_cloture', v_agence);
  IF v_mode = 'date_fin_client' THEN
    SELECT COALESCE(sum(CASE WHEN c.type_cycle = 3 THEN l.montant_collecte ELSE l.mise_appliquee END), 0)
      INTO v_prod
      FROM mf.ligne_collecte l
      JOIN mf.cycle c   ON c.id = l.cycle_id
      JOIN mf.affectation_zone a ON a.zone_id = mf.zone_client_a_date(c.client_id, l.date_collecte) AND a.collectrice_id = p_collectrice
           AND l.date_collecte >= a.date_debut AND (a.date_fin IS NULL OR l.date_collecte <= a.date_fin)
     WHERE l.origine = 'collecte' AND l.date_collecte BETWEEN p_du AND p_au;
  ELSE
    SELECT COALESCE(sum(CASE WHEN c.type_cycle = 3 THEN l.montant_collecte ELSE l.mise_appliquee END), 0)
      INTO v_prod
      FROM mf.cycle c
      JOIN mf.ligne_collecte l ON l.cycle_id = c.id AND l.origine = 'collecte'
      JOIN mf.affectation_zone a ON a.zone_id = mf.zone_client_a_date(c.client_id, c.date_cloture) AND a.collectrice_id = p_collectrice
           AND c.date_cloture >= a.date_debut AND (a.date_fin IS NULL OR c.date_cloture <= a.date_fin)
     WHERE c.statut IN ('clos','retire') AND c.date_cloture BETWEEN p_du AND p_au;
  END IF;
  RETURN v_prod;
END $$;

CREATE OR REPLACE FUNCTION rapport_journalier_zone(p_agence smallint, p_date date)
RETURNS TABLE (zone text, collectrice text, montant_collecte numeric, mises numeric, nb_lignes bigint,
               retraits numeric, remboursements numeric, ecarts_retrait numeric)
LANGUAGE sql STABLE AS $$
  SELECT z.code::text,
         (SELECT k.nom FROM mf.affectation_zone a JOIN mf.collectrice k ON k.id = a.collectrice_id
           WHERE a.zone_id = z.id AND p_date >= a.date_debut AND (a.date_fin IS NULL OR p_date <= a.date_fin) LIMIT 1)::text,
         COALESCE((SELECT sum(l.montant_collecte) FROM mf.ligne_collecte l JOIN mf.cycle c ON c.id = l.cycle_id
                    WHERE mf.zone_client_a_date(c.client_id, l.date_collecte) = z.id AND l.date_collecte = p_date AND l.origine = 'collecte'), 0)::numeric,
         COALESCE((SELECT sum(l.mise_appliquee) FROM mf.ligne_collecte l JOIN mf.cycle c ON c.id = l.cycle_id
                    WHERE mf.zone_client_a_date(c.client_id, l.date_collecte) = z.id AND l.date_collecte = p_date AND l.origine = 'collecte'), 0)::numeric,
         (SELECT count(*) FROM mf.ligne_collecte l JOIN mf.cycle c ON c.id = l.cycle_id
           WHERE mf.zone_client_a_date(c.client_id, l.date_collecte) = z.id AND l.date_collecte = p_date AND l.origine = 'collecte'),
         COALESCE((SELECT sum(r.montant_paye) FROM mf.retrait r JOIN mf.cycle c ON c.id = r.cycle_id
                    WHERE mf.zone_client_a_date(c.client_id, p_date) = z.id AND r.statut = 'execute' AND r.date_operation = p_date
                      AND r.nature IN ('retrait_client','virement_vers_epargne')), 0)::numeric,
         COALESCE((SELECT sum(p.capital + p.interet + p.penalite) FROM mf.paiement_echeance p JOIN mf.credit cr ON cr.id = p.credit_id
                    WHERE mf.zone_client_a_date(cr.client_id, p_date) = z.id AND p.date_operation = p_date), 0)::numeric,
         COALESCE((SELECT sum(d.perte) FROM mf.ecart_retrait_date d JOIN mf.ecart_retrait e ON e.id = d.ecart_id
                    JOIN mf.cycle c ON c.id = e.cycle_id
                    WHERE mf.zone_client_a_date(c.client_id, p_date) = z.id AND e.traite_le = p_date), 0)::numeric
    FROM mf.zone z WHERE z.agence_id = p_agence
   ORDER BY z.code
$$;

-- Piste d'audit
CREATE TRIGGER audit_client AFTER INSERT OR UPDATE OR DELETE ON client FOR EACH ROW EXECUTE FUNCTION trg_audit();
CREATE TRIGGER audit_client_transfert AFTER INSERT OR UPDATE OR DELETE ON client_transfert FOR EACH ROW EXECUTE FUNCTION trg_audit();
CREATE TRIGGER audit_compte_epargne AFTER INSERT OR UPDATE OR DELETE ON compte_epargne FOR EACH ROW EXECUTE FUNCTION trg_audit();

-- =====================================================================
-- MODULE 16_etats_financiers.sql
-- =====================================================================
-- =====================================================================
-- 16_etats_financiers.sql
-- États financiers issus des écritures comptables : par agence et consolidés (réseau).
--  * compte de résultat : produits (classe 7) et charges (classe 6) par compte de niveau 2, sur une période ;
--  * bilan : soldes cumulés jusqu'à une date, par compte de niveau 2 (hors classes 6, 7 et 9),
--    plus le résultat cumulé (ligne RES) ;
--  * synthèse par agence avec contrôle d'équilibre.
-- Les fonctions renvoient une ligne par agence ; la consolidation (somme des agences) est faite
-- par l'appelant. Dépend de : 05 (écritures), 14.
-- Consolidation = agrégation : aucune écriture inter-agences n'existe (voir 15), donc rien à éliminer.
-- Documents de travail : ce ne sont pas les états réglementaires de la BCEAO.
-- =====================================================================
SET search_path = mf, public;

-- Compte de résultat par agence (p_agence NULL : toutes les agences)
CREATE FUNCTION etat_resultat_par_agence(p_agence smallint, p_du date, p_au date)
RETURNS TABLE (agence_id smallint, agence text, cote text, code varchar, libelle text, montant numeric)
LANGUAGE sql STABLE AS $$
  SELECT x.agence_id, x.agence, x.cote, x.code, COALESCE(pc.libelle, x.code)::text, x.montant
    FROM (
      SELECT p.agence_id, a.code::text AS agence,
             CASE WHEN c.classe = '7' THEN 'produit' ELSE 'charge' END AS cote,
             left(c.code, 2)::varchar AS code,
             sum(CASE WHEN c.classe = '7' THEN e.credit - e.debit ELSE e.debit - e.credit END) AS montant
        FROM mf.ecriture e
        JOIN mf.piece_comptable p ON p.id = e.piece_id
        JOIN mf.agence a ON a.id = p.agence_id
        JOIN mf.compte_comptable c ON c.code = e.compte_code
       WHERE c.classe IN ('6', '7') AND p.date_piece BETWEEN p_du AND p_au
         AND (p_agence IS NULL OR p.agence_id = p_agence)
       GROUP BY p.agence_id, a.code, CASE WHEN c.classe = '7' THEN 'produit' ELSE 'charge' END, left(c.code, 2)
    ) x
    LEFT JOIN mf.compte_comptable pc ON pc.code = x.code
   WHERE x.montant <> 0
   ORDER BY x.cote DESC, x.code, x.agence_id
$$;

-- Bilan par agence : solde signé (débit - crédit) par compte de niveau 2 ; positif = actif, négatif = passif.
-- La ligne RES porte le résultat cumulé (bénéfice = solde négatif, au passif).
CREATE FUNCTION bilan_par_agence(p_agence smallint, p_au date)
RETURNS TABLE (agence_id smallint, agence text, code varchar, libelle text, solde numeric)
LANGUAGE sql STABLE AS $$
  SELECT y.agence_id, y.agence, y.code, COALESCE(pc.libelle, y.code)::text, y.solde
    FROM (
      SELECT p.agence_id, a.code::text AS agence, left(c.code, 2)::varchar AS code, sum(e.debit - e.credit) AS solde
        FROM mf.ecriture e
        JOIN mf.piece_comptable p ON p.id = e.piece_id
        JOIN mf.agence a ON a.id = p.agence_id
        JOIN mf.compte_comptable c ON c.code = e.compte_code
       WHERE c.classe NOT IN ('6', '7', '9') AND p.date_piece <= p_au AND (p_agence IS NULL OR p.agence_id = p_agence)
       GROUP BY p.agence_id, a.code, left(c.code, 2)
    ) y
    LEFT JOIN mf.compte_comptable pc ON pc.code = y.code
   WHERE y.solde <> 0
  UNION ALL
  SELECT p.agence_id, a.code::text, 'RES'::varchar, 'Résultat de l''exercice'::text, sum(e.debit - e.credit)
    FROM mf.ecriture e
    JOIN mf.piece_comptable p ON p.id = e.piece_id
    JOIN mf.agence a ON a.id = p.agence_id
    JOIN mf.compte_comptable c ON c.code = e.compte_code
   WHERE c.classe IN ('6', '7') AND p.date_piece <= p_au AND (p_agence IS NULL OR p.agence_id = p_agence)
   GROUP BY p.agence_id, a.code
  HAVING sum(e.debit - e.credit) <> 0
  ORDER BY 3, 1
$$;

-- Synthèse : une ligne par agence (toutes, même sans écriture) avec produits, charges, résultat de la période,
-- total actif / passif à la date de fin et écart de contrôle (doit être 0).
CREATE FUNCTION synthese_agences(p_du date, p_au date)
RETURNS TABLE (agence_id smallint, agence text, produits numeric, charges numeric, resultat numeric,
               total_actif numeric, total_passif numeric, ecart numeric)
LANGUAGE sql STABLE AS $$
  SELECT a.id, a.code::text,
         COALESCE((SELECT sum(r.montant) FROM mf.etat_resultat_par_agence(a.id, p_du, p_au) r WHERE r.cote = 'produit'), 0),
         COALESCE((SELECT sum(r.montant) FROM mf.etat_resultat_par_agence(a.id, p_du, p_au) r WHERE r.cote = 'charge'), 0),
         COALESCE((SELECT sum(r.montant) FILTER (WHERE r.cote = 'produit') FROM mf.etat_resultat_par_agence(a.id, p_du, p_au) r), 0)
         - COALESCE((SELECT sum(r.montant) FILTER (WHERE r.cote = 'charge') FROM mf.etat_resultat_par_agence(a.id, p_du, p_au) r), 0),
         COALESCE((SELECT sum(b.solde) FROM mf.bilan_par_agence(a.id, p_au) b WHERE b.solde > 0), 0),
         COALESCE((SELECT -sum(b.solde) FROM mf.bilan_par_agence(a.id, p_au) b WHERE b.solde < 0), 0),
         COALESCE((SELECT sum(b.solde) FROM mf.bilan_par_agence(a.id, p_au) b), 0)
    FROM mf.agence a
   ORDER BY a.code
$$;

-- =====================================================================
-- MODULE 17_kyc_lbc.sql
-- =====================================================================
-- =====================================================================
-- 17_kyc_lbc.sql
-- KYC (fiche client enrichie, pièces d'identité, liens entre clients, garants) et conformité LBC/FT
-- (listes de sanctions et de personnes politiquement exposées, filtrage des noms, alertes à examiner).
--  * un client « complet » a une pièce valide, une adresse, (pour une personne physique) une date de
--    naissance, et aucune alerte LBC/FT ouverte ;
--  * une alerte de sanction ouverte ou confirmée bloque toute demande de crédit ;
--  * si le paramètre kyc_obligatoire_credit vaut 'oui', un KYC incomplet bloque aussi la demande ;
--  * le filtrage est un rapprochement approché de noms (jetons triés, similarité trigramme) : il produit
--    des ALERTES à examiner par un humain, jamais une décision automatique.
-- Dépend de : 00 à 16 (client, demande_credit, credit, parametre).
-- =====================================================================
SET search_path = mf, public;
CREATE EXTENSION IF NOT EXISTS pg_trgm SCHEMA public;
CREATE EXTENSION IF NOT EXISTS unaccent SCHEMA public;

INSERT INTO parametre(agence_id, cle, valeur, description) VALUES
  (NULL, 'kyc_obligatoire_credit', 'non', 'oui | non : KYC complet exigé pour déposer une demande de crédit'),
  (NULL, 'lbc_seuil_similarite', '0.7', 'seuil (0 à 1) de rapprochement des noms avec les listes de surveillance')
ON CONFLICT DO NOTHING;

-- ---------------------------------------------------------------------
-- Fiche client enrichie
-- ---------------------------------------------------------------------
ALTER TABLE client
  ADD COLUMN type_client       varchar(20) NOT NULL DEFAULT 'physique'
                               CHECK (type_client IN ('physique','groupe_solidaire','personne_morale','cooperative')),
  ADD COLUMN sexe              char(1) CHECK (sexe IN ('F','M')),
  ADD COLUMN date_naissance    date CHECK (date_naissance <= current_date),
  ADD COLUMN profession        text,
  ADD COLUMN adresse           text,
  ADD COLUMN latitude_domicile  numeric(9,6) CHECK (latitude_domicile BETWEEN -90 AND 90),
  ADD COLUMN longitude_domicile numeric(9,6) CHECK (longitude_domicile BETWEEN -180 AND 180),
  ADD COLUMN latitude_activite  numeric(9,6) CHECK (latitude_activite BETWEEN -90 AND 90),
  ADD COLUMN longitude_activite numeric(9,6) CHECK (longitude_activite BETWEEN -180 AND 180),
  ADD COLUMN photo_ref         text,                       -- référence du fichier photo (stockage hors base)
  ADD COLUMN ppe               boolean NOT NULL DEFAULT false,
  ADD COLUMN statut_kyc        varchar(10) NOT NULL DEFAULT 'incomplet' CHECK (statut_kyc IN ('incomplet','complet')),
  ADD COLUMN kyc_valide_le     date,
  ADD COLUMN kyc_valide_par    integer REFERENCES utilisateur(id);

CREATE TABLE piece_identite (
  id              serial PRIMARY KEY,
  client_id       integer NOT NULL REFERENCES client(id),
  type            varchar(20) NOT NULL CHECK (type IN
                    ('cni','passeport','carte_electeur','permis','carte_consulaire','registre_commerce','statuts','autre')),
  numero          varchar(40) NOT NULL,
  date_emission   date,
  date_expiration date,
  fichier_ref     text,
  cree_le         timestamptz NOT NULL DEFAULT now(),
  CHECK (date_expiration IS NULL OR date_emission IS NULL OR date_expiration >= date_emission),
  UNIQUE (type, numero)                                  -- une même pièce ne sert pas à deux clients
);
CREATE INDEX piece_identite_client ON piece_identite (client_id);

CREATE TABLE lien_client (
  id         serial PRIMARY KEY,
  client_id  integer NOT NULL REFERENCES client(id),
  lie_a_id   integer NOT NULL REFERENCES client(id),
  type       varchar(15) NOT NULL CHECK (type IN ('famille','groupe','employeur','associe','autre')),
  note       text,
  cree_le    timestamptz NOT NULL DEFAULT now(),
  CHECK (client_id <> lie_a_id),
  UNIQUE (client_id, lie_a_id, type)
);

-- Garants d'une demande ou d'un crédit (un client déjà connu du SFD, avec KYC complet)
CREATE TABLE garant_credit (
  id               serial PRIMARY KEY,
  demande_id       integer REFERENCES demande_credit(id),
  credit_id        integer REFERENCES credit(id),
  garant_client_id integer NOT NULL REFERENCES client(id),
  montant_caution  numeric(14,0) NOT NULL CHECK (montant_caution > 0),
  statut           varchar(10) NOT NULL DEFAULT 'actif' CHECK (statut IN ('actif','libere')),
  cree_le          timestamptz NOT NULL DEFAULT now(),
  CHECK (demande_id IS NOT NULL OR credit_id IS NOT NULL)
);
CREATE UNIQUE INDEX garant_credit_unique_demande ON garant_credit (demande_id, garant_client_id) WHERE demande_id IS NOT NULL;
CREATE UNIQUE INDEX garant_credit_unique_credit ON garant_credit (credit_id, garant_client_id) WHERE credit_id IS NOT NULL;

CREATE FUNCTION trg_garant_controle() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE v_emprunteur integer; v_g mf.client;
BEGIN
  SELECT client_id INTO v_emprunteur FROM mf.demande_credit WHERE id = NEW.demande_id;
  IF v_emprunteur IS NULL THEN SELECT client_id INTO v_emprunteur FROM mf.credit WHERE id = NEW.credit_id; END IF;
  IF v_emprunteur IS NULL THEN RAISE EXCEPTION 'demande ou crédit introuvable'; END IF;
  IF v_emprunteur = NEW.garant_client_id THEN RAISE EXCEPTION 'un client ne peut pas se garantir lui-même'; END IF;
  SELECT * INTO v_g FROM mf.client WHERE id = NEW.garant_client_id;
  IF NOT v_g.actif THEN RAISE EXCEPTION 'le garant % est inactif', v_g.numero; END IF;
  IF v_g.statut_kyc <> 'complet' THEN RAISE EXCEPTION 'le KYC du garant % n''est pas complet', v_g.numero; END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER garant_controle BEFORE INSERT ON garant_credit FOR EACH ROW EXECUTE FUNCTION trg_garant_controle();

-- ---------------------------------------------------------------------
-- Listes de surveillance et alertes LBC/FT
-- ---------------------------------------------------------------------
CREATE TABLE liste_surveillance (
  id             serial PRIMARY KEY,
  source         varchar(60) NOT NULL,                   -- ex. ONU, UE, liste nationale, PPE
  categorie      varchar(10) NOT NULL CHECK (categorie IN ('sanction','ppe')),
  nom            text NOT NULL,
  date_naissance date,
  pays           varchar(60),
  reference      varchar(80),
  actif          boolean NOT NULL DEFAULT true,
  cree_le        timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE alerte_lbc (
  id          serial PRIMARY KEY,
  client_id   integer NOT NULL REFERENCES client(id),
  liste_id    integer NOT NULL REFERENCES liste_surveillance(id),
  type        varchar(10) NOT NULL CHECK (type IN ('sanction','ppe')),
  score       numeric(4,3) NOT NULL,
  statut      varchar(10) NOT NULL DEFAULT 'a_examiner' CHECK (statut IN ('a_examiner','confirmee','ecartee')),
  note        text,
  decide_par  integer REFERENCES utilisateur(id),
  decide_le   timestamptz,
  cree_le     timestamptz NOT NULL DEFAULT now(),
  UNIQUE (client_id, liste_id)
);
CREATE INDEX alerte_lbc_statut ON alerte_lbc (statut, client_id);

-- Clé de comparaison d'un nom : sans accents ni ponctuation, jetons triés (l'ordre nom/prénom est indifférent).
CREATE FUNCTION cle_nom(p text) RETURNS text
LANGUAGE sql STABLE AS $$
  SELECT COALESCE(string_agg(t, ' ' ORDER BY t), '')
    FROM unnest(regexp_split_to_array(lower(public.unaccent(COALESCE(p, ''))), '[^a-z0-9]+')) t WHERE t <> ''
$$;

-- Filtre un client contre les listes actives ; retourne le nombre de nouvelles alertes.
-- Deux dates de naissance connues et différentes écartent le rapprochement.
CREATE FUNCTION filtrer_client(p_client integer) RETURNS integer
LANGUAGE plpgsql AS $$
DECLARE v_n integer; v_seuil numeric;
BEGIN
  SELECT mf.param_num('lbc_seuil_similarite', c.agence_id) INTO v_seuil FROM mf.client c WHERE c.id = p_client;
  INSERT INTO mf.alerte_lbc(client_id, liste_id, type, score)
  SELECT c.id, l.id, l.categorie, round(public.similarity(mf.cle_nom(c.nom), mf.cle_nom(l.nom))::numeric, 3)
    FROM mf.client c, mf.liste_surveillance l
   WHERE c.id = p_client AND l.actif
     AND public.similarity(mf.cle_nom(c.nom), mf.cle_nom(l.nom)) >= v_seuil
     AND (c.date_naissance IS NULL OR l.date_naissance IS NULL OR c.date_naissance = l.date_naissance)
  ON CONFLICT (client_id, liste_id) DO NOTHING;
  GET DIAGNOSTICS v_n = ROW_COUNT;
  RETURN v_n;
END $$;

CREATE FUNCTION trg_client_filtrage() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  PERFORM mf.filtrer_client(NEW.id);
  RETURN NULL;
END $$;
CREATE TRIGGER client_filtrage AFTER INSERT OR UPDATE OF nom, date_naissance ON client FOR EACH ROW EXECUTE FUNCTION trg_client_filtrage();

-- Une nouvelle entrée de liste est confrontée à tous les clients existants.
CREATE FUNCTION trg_liste_filtrage() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  INSERT INTO mf.alerte_lbc(client_id, liste_id, type, score)
  SELECT c.id, NEW.id, NEW.categorie, round(public.similarity(mf.cle_nom(c.nom), mf.cle_nom(NEW.nom))::numeric, 3)
    FROM mf.client c
   WHERE NEW.actif AND public.similarity(mf.cle_nom(c.nom), mf.cle_nom(NEW.nom)) >= mf.param_num('lbc_seuil_similarite', c.agence_id)
     AND (c.date_naissance IS NULL OR NEW.date_naissance IS NULL OR c.date_naissance = NEW.date_naissance)
  ON CONFLICT (client_id, liste_id) DO NOTHING;
  RETURN NULL;
END $$;
CREATE TRIGGER liste_filtrage AFTER INSERT ON liste_surveillance FOR EACH ROW EXECUTE FUNCTION trg_liste_filtrage();

-- Décision d'un responsable sur une alerte. Confirmer une alerte PPE marque le client ; confirmer une
-- sanction remet son KYC à « incomplet » (le crédit reste bloqué tant que l'alerte existe).
CREATE FUNCTION traiter_alerte_lbc(p_alerte integer, p_decision text, p_note text DEFAULT NULL, p_utilisateur integer DEFAULT NULL)
RETURNS void LANGUAGE plpgsql AS $$
DECLARE a mf.alerte_lbc;
BEGIN
  IF p_decision NOT IN ('confirmee', 'ecartee') THEN RAISE EXCEPTION 'décision inconnue : % (confirmee | ecartee)', p_decision; END IF;
  SELECT * INTO a FROM mf.alerte_lbc WHERE id = p_alerte FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'alerte % inconnue', p_alerte; END IF;
  IF a.statut <> 'a_examiner' THEN RAISE EXCEPTION 'alerte % déjà traitée (%)', p_alerte, a.statut; END IF;
  IF p_decision = 'ecartee' AND (p_note IS NULL OR btrim(p_note) = '') THEN
    RAISE EXCEPTION 'écarter une alerte exige une justification';
  END IF;
  UPDATE mf.alerte_lbc SET statut = p_decision, note = p_note, decide_par = p_utilisateur, decide_le = now() WHERE id = p_alerte;
  IF p_decision = 'confirmee' THEN
    IF a.type = 'ppe' THEN UPDATE mf.client SET ppe = true WHERE id = a.client_id; END IF;
    IF a.type = 'sanction' THEN UPDATE mf.client SET statut_kyc = 'incomplet', kyc_valide_le = NULL, kyc_valide_par = NULL WHERE id = a.client_id; END IF;
  END IF;
END $$;

-- ---------------------------------------------------------------------
-- Complétude du KYC
-- ---------------------------------------------------------------------
CREATE FUNCTION kyc_manquants(p_client integer) RETURNS text[]
LANGUAGE plpgsql STABLE AS $$
DECLARE c mf.client; m text[] := '{}';
BEGIN
  SELECT * INTO c FROM mf.client WHERE id = p_client;
  IF NOT FOUND THEN RAISE EXCEPTION 'client % inconnu', p_client; END IF;
  IF c.type_client = 'physique' AND c.date_naissance IS NULL THEN m := array_append(m, 'date de naissance'::text); END IF;
  IF c.type_client = 'physique' AND c.sexe IS NULL THEN m := array_append(m, 'sexe'::text); END IF;
  IF c.adresse IS NULL OR btrim(c.adresse) = '' THEN m := array_append(m, 'adresse'::text); END IF;
  IF NOT EXISTS (SELECT 1 FROM mf.piece_identite p WHERE p.client_id = p_client
                  AND (p.date_expiration IS NULL OR p.date_expiration >= current_date)
                  AND (c.type_client = 'physique' AND p.type IN ('cni','passeport','carte_electeur','permis','carte_consulaire')
                       OR c.type_client <> 'physique' AND p.type IN ('registre_commerce','statuts','autre'))) THEN
    m := array_append(m, (CASE WHEN c.type_client = 'physique' THEN 'pièce d''identité valide' ELSE 'document d''existence légale valide' END)::text);
  END IF;
  IF EXISTS (SELECT 1 FROM mf.alerte_lbc WHERE client_id = p_client AND statut = 'a_examiner') THEN m := array_append(m, 'alerte LBC/FT à examiner'::text); END IF;
  IF EXISTS (SELECT 1 FROM mf.alerte_lbc WHERE client_id = p_client AND statut = 'confirmee' AND type = 'sanction') THEN m := array_append(m, 'sanction confirmée'::text); END IF;
  RETURN m;
END $$;

CREATE FUNCTION valider_kyc(p_client integer, p_utilisateur integer DEFAULT NULL, p_date date DEFAULT current_date) RETURNS void
LANGUAGE plpgsql AS $$
DECLARE m text[];
BEGIN
  m := mf.kyc_manquants(p_client);
  IF cardinality(m) > 0 THEN RAISE EXCEPTION 'KYC incomplet : %', array_to_string(m, ', '); END IF;
  UPDATE mf.client SET statut_kyc = 'complet', kyc_valide_le = p_date, kyc_valide_par = p_utilisateur WHERE id = p_client;
END $$;

-- Tâche quotidienne : les clients dont une pièce a expiré (et sans autre pièce valide) repassent à « incomplet ».
CREATE FUNCTION maj_statut_kyc() RETURNS integer
LANGUAGE plpgsql AS $$
DECLARE v_n integer;
BEGIN
  UPDATE mf.client c SET statut_kyc = 'incomplet', kyc_valide_le = NULL, kyc_valide_par = NULL
   WHERE c.statut_kyc = 'complet' AND cardinality(mf.kyc_manquants(c.id)) > 0;
  GET DIAGNOSTICS v_n = ROW_COUNT;
  RETURN v_n;
END $$;

CREATE VIEW v_pieces_a_renouveler AS
SELECT p.id AS piece_id, p.client_id, c.agence_id, c.numero AS client_numero, c.nom, p.type, p.numero, p.date_expiration
  FROM piece_identite p JOIN client c ON c.id = p.client_id
 WHERE p.date_expiration IS NOT NULL AND p.date_expiration <= current_date + 30;

-- ---------------------------------------------------------------------
-- Garde-fous du crédit
-- ---------------------------------------------------------------------
CREATE FUNCTION trg_demande_credit_conformite() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE c mf.client;
BEGIN
  SELECT * INTO c FROM mf.client WHERE id = NEW.client_id;
  IF EXISTS (SELECT 1 FROM mf.alerte_lbc WHERE client_id = NEW.client_id AND type = 'sanction' AND statut IN ('a_examiner', 'confirmee')) THEN
    RAISE EXCEPTION 'demande refusée : alerte de sanction LBC/FT ouverte ou confirmée sur le client %', c.numero;
  END IF;
  IF mf.param('kyc_obligatoire_credit', NEW.agence_id) = 'oui' AND c.statut_kyc <> 'complet' THEN
    RAISE EXCEPTION 'demande refusée : le KYC du client % n''est pas complet', c.numero;
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER demande_credit_conformite BEFORE INSERT ON demande_credit FOR EACH ROW EXECUTE FUNCTION trg_demande_credit_conformite();

-- Piste d'audit
CREATE TRIGGER audit_piece_identite AFTER INSERT OR UPDATE OR DELETE ON piece_identite FOR EACH ROW EXECUTE FUNCTION trg_audit();
CREATE TRIGGER audit_alerte_lbc AFTER INSERT OR UPDATE OR DELETE ON alerte_lbc FOR EACH ROW EXECUTE FUNCTION trg_audit();
CREATE TRIGGER audit_liste_surveillance AFTER INSERT OR UPDATE OR DELETE ON liste_surveillance FOR EACH ROW EXECUTE FUNCTION trg_audit();
CREATE TRIGGER audit_garant_credit AFTER INSERT OR UPDATE OR DELETE ON garant_credit FOR EACH ROW EXECUTE FUNCTION trg_audit();

-- =====================================================================
-- MODULE 18_espace_client.sql
-- =====================================================================
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

-- =====================================================================
-- MODULE 19_etats_reglementaires.sql
-- =====================================================================
-- =====================================================================
-- 19_etats_reglementaires.sql  (données des postes : 19_postes_data.sql)
-- États financiers selon la nomenclature des postes du référentiel comptable des SFD de l'UMOA
-- (annexe 1.1 : codes postes et concordance avec le plan de comptes ; annexes 2 et 3 : bilan, compte de résultat).
--  * poste_etat / poste_compte : nomenclature et concordance, chargées par 19_postes_data.sql ;
--  * valeurs_postes(agence, du, au) : valeur de chaque poste calculée à partir des écritures ;
--  * etat_bilan_reglementaire / etat_resultat_reglementaire / etat_hors_bilan.
-- Règles de calcul (à valider par le comptable) :
--  1. un compte est rattaché à un poste par PRÉFIXE de code ; un compte n'est compté qu'une fois par poste ;
--  2. les signes « + » et « - » de la concordance désignent des comptes de contrepartie (provisions, amortissements) :
--     la valeur d'un poste d'actif ou de charge est la somme des soldes débiteurs (débit - crédit) de ses comptes, celle
--     d'un poste de passif ou de produit la somme des soldes créditeurs (crédit - débit) ; une provision (solde créditeur)
--     vient donc bien en déduction d'un poste d'actif ;
--  3. un compte marqué « ex » peut être débiteur ou créditeur : il figure à l'actif s'il est débiteur, au passif s'il est créditeur ;
--  4. bilan : soldes cumulés jusqu'à la date ; compte de résultat : mouvements de la période ;
--  5. E05 (excédent des charges sur les produits) et L75 (excédent des produits sur les charges) sont les parties positives du
--     résultat cumulé des classes 6 et 7 (aucune clôture d'exercice n'est passée) ;
--  6. hors-bilan : valeur absolue du solde ; seules les valeurs nettes sont produites (pas de colonnes brut / amortissements).
-- Dépend de : 05 (écritures).
-- =====================================================================
SET search_path = mf, public;

CREATE TABLE poste_etat (
  code    varchar(3) PRIMARY KEY,
  cote    varchar(10) NOT NULL CHECK (cote IN ('actif','passif','hors_bilan','charge','produit','autre')),
  libelle text NOT NULL
);

CREATE TABLE poste_compte (
  poste_code varchar(3) NOT NULL REFERENCES poste_etat(code),
  prefixe    varchar(7) NOT NULL,
  signe      smallint NOT NULL CHECK (signe IN (1, -1)),
  ex         boolean NOT NULL DEFAULT false,
  PRIMARY KEY (poste_code, prefixe, ex)
);
CREATE INDEX poste_compte_prefixe ON poste_compte (prefixe text_pattern_ops);

-- Valeur de chaque poste pour une agence (NULL = toutes les agences) ; bilan cumulé jusqu'à p_au, résultat sur [p_du, p_au].
CREATE FUNCTION valeurs_postes(p_agence smallint, p_du date, p_au date)
RETURNS TABLE (code varchar, cote text, libelle text, montant numeric)
LANGUAGE sql STABLE AS $$
  WITH s AS (                                  -- mouvements par compte : cumul jusqu'à la date et période
    SELECT e.compte_code,
           COALESCE(sum(e.debit)  FILTER (WHERE p.date_piece <= p_au), 0) AS d_cum,
           COALESCE(sum(e.credit) FILTER (WHERE p.date_piece <= p_au), 0) AS c_cum,
           COALESCE(sum(e.debit)  FILTER (WHERE p.date_piece BETWEEN p_du AND p_au), 0) AS d_per,
           COALESCE(sum(e.credit) FILTER (WHERE p.date_piece BETWEEN p_du AND p_au), 0) AS c_per
      FROM mf.ecriture e JOIN mf.piece_comptable p ON p.id = e.piece_id
     WHERE p.date_piece <= p_au AND (p_agence IS NULL OR p.agence_id = p_agence)
     GROUP BY e.compte_code
  ), lien AS (                                 -- un compte compte une fois par poste ; « ex » seulement si aucun rattachement ordinaire
    SELECT pc.poste_code, s.compte_code, e.cote, bool_and(pc.ex) AS seulement_ex,
           max(s.d_cum) AS d_cum, max(s.c_cum) AS c_cum, max(s.d_per) AS d_per, max(s.c_per) AS c_per
      FROM mf.poste_compte pc
      JOIN mf.poste_etat e ON e.code = pc.poste_code
      JOIN s ON s.compte_code LIKE pc.prefixe || '%'
     GROUP BY pc.poste_code, s.compte_code, e.cote
  ), val AS (
    SELECT l.poste_code, l.cote,
           CASE l.cote
             WHEN 'actif'      THEN CASE WHEN l.seulement_ex THEN GREATEST(l.d_cum - l.c_cum, 0) ELSE l.d_cum - l.c_cum END
             WHEN 'passif'     THEN CASE WHEN l.seulement_ex THEN GREATEST(l.c_cum - l.d_cum, 0) ELSE l.c_cum - l.d_cum END
             WHEN 'hors_bilan' THEN abs(l.d_cum - l.c_cum)
             WHEN 'charge'     THEN l.d_per - l.c_per
             WHEN 'produit'    THEN l.c_per - l.d_per
             ELSE 0
           END AS m
      FROM lien l
  )
  SELECT pe.code::varchar, pe.cote::text, pe.libelle,
         CASE pe.code
           WHEN 'E05' THEN GREATEST((SELECT COALESCE(sum(d_cum - c_cum), 0) FROM s WHERE compte_code ~ '^[67]'), 0)
           WHEN 'L75' THEN GREATEST((SELECT COALESCE(sum(c_cum - d_cum), 0) FROM s WHERE compte_code ~ '^[67]'), 0)
           ELSE COALESCE((SELECT sum(v.m) FROM val v WHERE v.poste_code = pe.code), 0)
         END
    FROM mf.poste_etat pe
   ORDER BY pe.code
$$;

-- Bilan réglementaire : tous les postes non nuls, avec les totaux E90 (actif) et L90 (passif)
CREATE FUNCTION etat_bilan_reglementaire(p_agence smallint, p_au date)
RETURNS TABLE (cote text, code varchar, libelle text, montant numeric)
LANGUAGE sql STABLE AS $$
  WITH v AS (SELECT * FROM mf.valeurs_postes(p_agence, p_au, p_au) WHERE cote IN ('actif','passif'))
  SELECT v.cote, v.code, v.libelle, v.montant FROM v WHERE v.montant <> 0
  UNION ALL
  SELECT 'actif', 'E90'::varchar, 'TOTAL ACTIF', COALESCE(sum(montant), 0) FROM v WHERE cote = 'actif' AND (code ~ '^[A-D]01$' OR code = 'E01' OR code = 'E05')
  UNION ALL
  SELECT 'passif', 'L90'::varchar, 'TOTAL PASSIF', COALESCE(sum(montant), 0) FROM v WHERE cote = 'passif' AND (code ~ '^[FGHKL]01$' OR code = 'L75')
  ORDER BY 1, 2
$$;

CREATE FUNCTION etat_resultat_reglementaire(p_agence smallint, p_du date, p_au date)
RETURNS TABLE (cote text, code varchar, libelle text, montant numeric)
LANGUAGE sql STABLE AS $$
  SELECT v.cote, v.code, v.libelle, v.montant
    FROM mf.valeurs_postes(p_agence, p_du, p_au) v WHERE v.cote IN ('charge','produit') AND v.montant <> 0
   ORDER BY 1 DESC, 2
$$;

CREATE FUNCTION etat_hors_bilan(p_agence smallint, p_au date)
RETURNS TABLE (code varchar, libelle text, montant numeric)
LANGUAGE sql STABLE AS $$
  SELECT v.code, v.libelle, v.montant FROM mf.valeurs_postes(p_agence, p_au, p_au) v WHERE v.cote = 'hors_bilan' AND v.montant <> 0 ORDER BY v.code
$$;

-- =====================================================================
-- MODULE 19_postes_data.sql
-- =====================================================================
-- Généré par tools/extraire_postes.py à partir du référentiel comptable des SFD de l'UMOA (annexe 1.1).
-- Ne pas modifier à la main : relancer le script. Voir les contrôles dans tests/test_19_etats_reglementaires.sql.
SET search_path = mf, public;
INSERT INTO poste_etat(code, cote, libelle) VALUES ('A01', 'actif', 'OPERATIONS DE TRESORERIE ET AVEC LES INSTITUTIONS FINANCIERES');
INSERT INTO poste_etat(code, cote, libelle) VALUES ('A10', 'actif', 'Valeur en caisse');
INSERT INTO poste_etat(code, cote, libelle) VALUES ('A11', 'actif', 'Billets et monnaies');
INSERT INTO poste_etat(code, cote, libelle) VALUES ('A12', 'actif', 'Comptes ordinaires débiteurs');
INSERT INTO poste_etat(code, cote, libelle) VALUES ('A13', 'actif', 'A13');
INSERT INTO poste_etat(code, cote, libelle) VALUES ('A14', 'actif', 'A14');
INSERT INTO poste_etat(code, cote, libelle) VALUES ('A15', 'actif', 'A15');
INSERT INTO poste_etat(code, cote, libelle) VALUES ('A16', 'actif', 'A16');
INSERT INTO poste_etat(code, cote, libelle) VALUES ('A17', 'actif', 'A17');
INSERT INTO poste_etat(code, cote, libelle) VALUES ('A19', 'actif', 'A19');
INSERT INTO poste_etat(code, cote, libelle) VALUES ('A20', 'actif', 'A20');
INSERT INTO poste_etat(code, cote, libelle) VALUES ('A21', 'actif', 'A21');
INSERT INTO poste_etat(code, cote, libelle) VALUES ('A2A', 'actif', 'Autres comptes de dépôts débiteurs');
INSERT INTO poste_etat(code, cote, libelle) VALUES ('A2H', 'actif', 'Dépôts à terme constitués');
INSERT INTO poste_etat(code, cote, libelle) VALUES ('A2I', 'actif', 'Dépôts de garantie constitués');
INSERT INTO poste_etat(code, cote, libelle) VALUES ('A2J', 'actif', 'Autres dépôts constitués');
INSERT INTO poste_etat(code, cote, libelle) VALUES ('A3A', 'actif', 'Comptes de prêts');
INSERT INTO poste_etat(code, cote, libelle) VALUES ('A3B', 'actif', 'Prêts à moins d''un an');
INSERT INTO poste_etat(code, cote, libelle) VALUES ('A3C', 'actif', 'Prêts à terme');
INSERT INTO poste_etat(code, cote, libelle) VALUES ('A60', 'actif', 'Créances rattachées');
INSERT INTO poste_etat(code, cote, libelle) VALUES ('A70', 'actif', 'Prêts en souffrance et immobilisés Prêts immobilisés');
INSERT INTO poste_etat(code, cote, libelle) VALUES ('A71', 'actif', 'Prêts en souffrance de 6 mois au plus');
INSERT INTO poste_etat(code, cote, libelle) VALUES ('A72', 'actif', 'Prêts en souffrance de plus de 6 mois à 12 mois au plus');
INSERT INTO poste_etat(code, cote, libelle) VALUES ('A73', 'actif', 'Prêts en souffrance de plus de 12 mois à 24 mois au plus');
INSERT INTO poste_etat(code, cote, libelle) VALUES ('B01', 'actif', 'OPERATIONS AVEC LES MEMBRES, BENEFICIAIRES OU CLIENTS');
INSERT INTO poste_etat(code, cote, libelle) VALUES ('B02', 'actif', 'Créances sur les membres, bénéficiaires ou clients');
INSERT INTO poste_etat(code, cote, libelle) VALUES ('B03', 'actif', 'B03');
INSERT INTO poste_etat(code, cote, libelle) VALUES ('B2D', 'actif', 'Crédits à court terme');
INSERT INTO poste_etat(code, cote, libelle) VALUES ('B2N', 'actif', 'Comptes ordinaires débiteurs');
INSERT INTO poste_etat(code, cote, libelle) VALUES ('B30', 'actif', 'Crédits à moyen terme');
INSERT INTO poste_etat(code, cote, libelle) VALUES ('B40', 'actif', 'Crédits à long terme');
INSERT INTO poste_etat(code, cote, libelle) VALUES ('B65', 'actif', 'Créances rattachées');
INSERT INTO poste_etat(code, cote, libelle) VALUES ('B70', 'actif', 'Crédits en souffrance et immobilisés Crédits immobilisés');
INSERT INTO poste_etat(code, cote, libelle) VALUES ('B71', 'actif', 'Crédits en souffrance de 6 mois au plus');
INSERT INTO poste_etat(code, cote, libelle) VALUES ('B72', 'actif', 'Crédits en souffrance de plus de 6 mois à 12 mois au plus');
INSERT INTO poste_etat(code, cote, libelle) VALUES ('B73', 'actif', 'Crédits en souffrance de plus de 12 mois à 24 mois au plus');
INSERT INTO poste_etat(code, cote, libelle) VALUES ('C01', 'actif', 'OPERATIONS SUR TITRES ET OPERATIONS DIVERSES');
INSERT INTO poste_etat(code, cote, libelle) VALUES ('C10', 'actif', 'Titres de placement');
INSERT INTO poste_etat(code, cote, libelle) VALUES ('C30', 'actif', 'Comptes de stocks');
INSERT INTO poste_etat(code, cote, libelle) VALUES ('C31', 'actif', 'Stocks de meubles');
INSERT INTO poste_etat(code, cote, libelle) VALUES ('C32', 'actif', 'Stocks de marchandises');
INSERT INTO poste_etat(code, cote, libelle) VALUES ('C33', 'actif', 'Stocks de fournitures');
INSERT INTO poste_etat(code, cote, libelle) VALUES ('C34', 'actif', 'Autres stocks et assimilés');
INSERT INTO poste_etat(code, cote, libelle) VALUES ('C40', 'actif', 'Débiteurs divers');
INSERT INTO poste_etat(code, cote, libelle) VALUES ('C55', 'actif', 'Créances rattachées');
INSERT INTO poste_etat(code, cote, libelle) VALUES ('C56', 'actif', 'Valeurs à l''encaissement avec crédit immédiat');
INSERT INTO poste_etat(code, cote, libelle) VALUES ('C59', 'actif', 'Valeurs à rejeter');
INSERT INTO poste_etat(code, cote, libelle) VALUES ('C6A', 'actif', 'Comptes d''ordre et divers');
INSERT INTO poste_etat(code, cote, libelle) VALUES ('C6B', 'actif', 'Comptes de liaison');
INSERT INTO poste_etat(code, cote, libelle) VALUES ('C6C', 'actif', 'Comptes de différence de conversion');
INSERT INTO poste_etat(code, cote, libelle) VALUES ('C6D', 'actif', 'C6D');
INSERT INTO poste_etat(code, cote, libelle) VALUES ('C6E', 'actif', 'C6E');
INSERT INTO poste_etat(code, cote, libelle) VALUES ('C6F', 'actif', 'C6F');
INSERT INTO poste_etat(code, cote, libelle) VALUES ('C6G', 'actif', 'Comptes de régularisation actif');
INSERT INTO poste_etat(code, cote, libelle) VALUES ('C6N', 'actif', 'C6N');
INSERT INTO poste_etat(code, cote, libelle) VALUES ('C6Q', 'actif', 'Comptes transitoires');
INSERT INTO poste_etat(code, cote, libelle) VALUES ('C6R', 'actif', 'Comptes d''attente - actif');
INSERT INTO poste_etat(code, cote, libelle) VALUES ('D01', 'actif', 'VALEURS IMMOBILISEES');
INSERT INTO poste_etat(code, cote, libelle) VALUES ('D10', 'actif', 'Prêts et titres subordonnés');
INSERT INTO poste_etat(code, cote, libelle) VALUES ('D1A', 'actif', 'Immobilisations financières');
INSERT INTO poste_etat(code, cote, libelle) VALUES ('D1E', 'actif', 'Titres de participation');
INSERT INTO poste_etat(code, cote, libelle) VALUES ('D1L', 'actif', 'Titres d''investissement');
INSERT INTO poste_etat(code, cote, libelle) VALUES ('D1S', 'actif', 'Dépôts et cautionnements');
INSERT INTO poste_etat(code, cote, libelle) VALUES ('D23', 'actif', 'Immobilisations en cours');
INSERT INTO poste_etat(code, cote, libelle) VALUES ('D24', 'actif', 'Incorporelles');
INSERT INTO poste_etat(code, cote, libelle) VALUES ('D25', 'actif', 'Corporelles');
INSERT INTO poste_etat(code, cote, libelle) VALUES ('D30', 'actif', 'Immobilisations d''exploitation');
INSERT INTO poste_etat(code, cote, libelle) VALUES ('D31', 'actif', 'Incorporelles');
INSERT INTO poste_etat(code, cote, libelle) VALUES ('D32', 'actif', 'Droit au bail');
INSERT INTO poste_etat(code, cote, libelle) VALUES ('D33', 'actif', 'Autres éléments du fonds commercial');
INSERT INTO poste_etat(code, cote, libelle) VALUES ('D34', 'actif', 'Frais d''établissement');
INSERT INTO poste_etat(code, cote, libelle) VALUES ('D35', 'actif', 'Autres immobilisations incorporelles');
INSERT INTO poste_etat(code, cote, libelle) VALUES ('D36', 'actif', 'Corporelles');
INSERT INTO poste_etat(code, cote, libelle) VALUES ('D40', 'actif', 'Immobilisations hors exploitation');
INSERT INTO poste_etat(code, cote, libelle) VALUES ('D41', 'actif', 'Incorporelles');
INSERT INTO poste_etat(code, cote, libelle) VALUES ('D42', 'actif', 'Droit au bail');
INSERT INTO poste_etat(code, cote, libelle) VALUES ('D43', 'actif', 'Autres éléments du fonds commercial');
INSERT INTO poste_etat(code, cote, libelle) VALUES ('D44', 'actif', 'Autres immobilisations incorporelles');
INSERT INTO poste_etat(code, cote, libelle) VALUES ('D45', 'actif', 'Corporelles');
INSERT INTO poste_etat(code, cote, libelle) VALUES ('D46', 'actif', 'Incorporelles');
INSERT INTO poste_etat(code, cote, libelle) VALUES ('D47', 'actif', 'Corporelles');
INSERT INTO poste_etat(code, cote, libelle) VALUES ('D50', 'actif', 'Crédit bail et opérations assimilées');
INSERT INTO poste_etat(code, cote, libelle) VALUES ('D51', 'actif', 'Crédit-bail');
INSERT INTO poste_etat(code, cote, libelle) VALUES ('D52', 'actif', 'L.O.A.');
INSERT INTO poste_etat(code, cote, libelle) VALUES ('D53', 'actif', 'Location-vente');
INSERT INTO poste_etat(code, cote, libelle) VALUES ('D60', 'actif', 'Créances rattachées 0');
INSERT INTO poste_etat(code, cote, libelle) VALUES ('D70', 'actif', 'Créances en souffrance');
INSERT INTO poste_etat(code, cote, libelle) VALUES ('D71', 'actif', 'Créances en souffrance de 6 mois au plus');
INSERT INTO poste_etat(code, cote, libelle) VALUES ('D72', 'actif', 'Créances en souffrance de plus de 6 mois à 12 mois au plus');
INSERT INTO poste_etat(code, cote, libelle) VALUES ('D73', 'actif', 'Créances en souffrance de plus de 12 mois à 24 mois au plus');
INSERT INTO poste_etat(code, cote, libelle) VALUES ('E01', 'actif', 'ACTIONNAIRES, ASSOCIES OU MEMBRES');
INSERT INTO poste_etat(code, cote, libelle) VALUES ('E02', 'actif', 'Actionnaires, associés ou membres, capital non appelé');
INSERT INTO poste_etat(code, cote, libelle) VALUES ('E03', 'actif', 'Actionnaires, associés ou membres, capital appelé non versé');
INSERT INTO poste_etat(code, cote, libelle) VALUES ('E05', 'actif', 'EXCEDENT DES CHARGES SUR LES PRODUITS');
INSERT INTO poste_etat(code, cote, libelle) VALUES ('E90', 'actif', 'TOTAL ACTIF');
INSERT INTO poste_etat(code, cote, libelle) VALUES ('F01', 'passif', 'OPERATIONS DE TRESORERIE ET AVEC LES INSTITUTIONS FINANCIERES');
INSERT INTO poste_etat(code, cote, libelle) VALUES ('F1A', 'passif', 'Comptes ordinaires créditeurs');
INSERT INTO poste_etat(code, cote, libelle) VALUES ('F2A', 'passif', 'Autres comptes de dépôts créditeurs');
INSERT INTO poste_etat(code, cote, libelle) VALUES ('F2B', 'passif', 'Dépôts à terme reçus');
INSERT INTO poste_etat(code, cote, libelle) VALUES ('F2C', 'passif', 'Dépôts de garantie reçus');
INSERT INTO poste_etat(code, cote, libelle) VALUES ('F2D', 'passif', 'Autres dépôts reçus');
INSERT INTO poste_etat(code, cote, libelle) VALUES ('F3A', 'passif', 'Comptes d''emprunts');
INSERT INTO poste_etat(code, cote, libelle) VALUES ('F3E', 'passif', 'Emprunts à moins d''un an');
INSERT INTO poste_etat(code, cote, libelle) VALUES ('F3F', 'passif', 'Emprunts à terme');
INSERT INTO poste_etat(code, cote, libelle) VALUES ('F50', 'passif', 'Autres sommes dues aux institutions financières');
INSERT INTO poste_etat(code, cote, libelle) VALUES ('F55', 'passif', 'Ressources affectées');
INSERT INTO poste_etat(code, cote, libelle) VALUES ('F60', 'passif', 'Dettes rattachées');
INSERT INTO poste_etat(code, cote, libelle) VALUES ('G01', 'passif', 'OPERATIONS AVEC LES MEMBRES, BENEFICIAIRES OU CLIENTS');
INSERT INTO poste_etat(code, cote, libelle) VALUES ('G02', 'passif', 'Dettes l''égard des membres, bénéficiaires ou clients');
INSERT INTO poste_etat(code, cote, libelle) VALUES ('G10', 'passif', 'Comptes ordinaires créditeurs');
INSERT INTO poste_etat(code, cote, libelle) VALUES ('G15', 'passif', 'Dépôts à terme reçus');
INSERT INTO poste_etat(code, cote, libelle) VALUES ('G2A', 'passif', 'Comptes d''épargne à régime spécial');
INSERT INTO poste_etat(code, cote, libelle) VALUES ('G30', 'passif', 'Autres dépôts de garantie reçus');
INSERT INTO poste_etat(code, cote, libelle) VALUES ('G35', 'passif', 'Autres dépôts reçus');
INSERT INTO poste_etat(code, cote, libelle) VALUES ('G60', 'passif', 'Emprunts');
INSERT INTO poste_etat(code, cote, libelle) VALUES ('G70', 'passif', 'Autres sommes dues');
INSERT INTO poste_etat(code, cote, libelle) VALUES ('G90', 'passif', 'Dettes rattachées');
INSERT INTO poste_etat(code, cote, libelle) VALUES ('H01', 'passif', 'OPERATIONS SUR TITRES ET OPERATIONS DIVERSES');
INSERT INTO poste_etat(code, cote, libelle) VALUES ('H10', 'passif', 'Versements restant à effectuer');
INSERT INTO poste_etat(code, cote, libelle) VALUES ('H40', 'passif', 'Créditeurs divers');
INSERT INTO poste_etat(code, cote, libelle) VALUES ('H6A', 'passif', 'Comptes d''ordre et divers');
INSERT INTO poste_etat(code, cote, libelle) VALUES ('H6B', 'passif', 'Comptes de liaison');
INSERT INTO poste_etat(code, cote, libelle) VALUES ('H6C', 'passif', 'Comptes de différences de conversion');
INSERT INTO poste_etat(code, cote, libelle) VALUES ('H6G', 'passif', 'Comptes de régularisation - passif');
INSERT INTO poste_etat(code, cote, libelle) VALUES ('H6P', 'passif', 'Comptes d''attente - passif');
INSERT INTO poste_etat(code, cote, libelle) VALUES ('K01', 'passif', 'VERSEMENTS RESTANT A EFFECTUER SUR IMMOBILISATIONS FINANCIERES');
INSERT INTO poste_etat(code, cote, libelle) VALUES ('K20', 'passif', 'Titres de participation');
INSERT INTO poste_etat(code, cote, libelle) VALUES ('L01', 'passif', 'PROVISIONS, FONDS PROPRES ET ASSIMILES');
INSERT INTO poste_etat(code, cote, libelle) VALUES ('L10', 'passif', 'Subventions d''investissement');
INSERT INTO poste_etat(code, cote, libelle) VALUES ('L20', 'passif', 'Fonds affectés');
INSERT INTO poste_etat(code, cote, libelle) VALUES ('L21', 'passif', 'Fonds de garantie');
INSERT INTO poste_etat(code, cote, libelle) VALUES ('L22', 'passif', 'Fonds d''assurance');
INSERT INTO poste_etat(code, cote, libelle) VALUES ('L23', 'passif', 'Fonds de bonification');
INSERT INTO poste_etat(code, cote, libelle) VALUES ('L24', 'passif', 'Fonds de sécurité');
INSERT INTO poste_etat(code, cote, libelle) VALUES ('L25', 'passif', 'Autres fonds affectés');
INSERT INTO poste_etat(code, cote, libelle) VALUES ('L27', 'passif', 'Fonds de créditD24 Incorporelles');
INSERT INTO poste_etat(code, cote, libelle) VALUES ('L30', 'passif', 'Provisions pour Risques et Charges');
INSERT INTO poste_etat(code, cote, libelle) VALUES ('L31', 'passif', 'Provisions pour charges de retraite');
INSERT INTO poste_etat(code, cote, libelle) VALUES ('L32', 'passif', 'Provisions pour risque d''exécution des engagements par signatureD31 Incorporelles');
INSERT INTO poste_etat(code, cote, libelle) VALUES ('L33', 'passif', 'Autres provisions pour risques et chargesD36 Corporelles');
INSERT INTO poste_etat(code, cote, libelle) VALUES ('L35', 'passif', 'Provisions réglementéesD40 Immobilisations hors exploitation');
INSERT INTO poste_etat(code, cote, libelle) VALUES ('L36', 'passif', 'Provisions pour risques afférents aux opérations de crédits à moyen et long termes');
INSERT INTO poste_etat(code, cote, libelle) VALUES ('L37', 'passif', 'Provision spéciale de réévaluation');
INSERT INTO poste_etat(code, cote, libelle) VALUES ('L41', 'passif', 'Emprunts et titres émis subordonnés');
INSERT INTO poste_etat(code, cote, libelle) VALUES ('L43', 'passif', 'Dettes rattachées aux emprunts et titres émis subordonnés');
INSERT INTO poste_etat(code, cote, libelle) VALUES ('L45', 'passif', 'Fonds pour risques financiers généraux');
INSERT INTO poste_etat(code, cote, libelle) VALUES ('L50', 'passif', 'Primes liées au capital');
INSERT INTO poste_etat(code, cote, libelle) VALUES ('L55', 'passif', 'Réserves');
INSERT INTO poste_etat(code, cote, libelle) VALUES ('L56', 'passif', 'Réserve générale Immobilisations acquises par réalisation de garantie');
INSERT INTO poste_etat(code, cote, libelle) VALUES ('L57', 'passif', 'Réserves facultatives');
INSERT INTO poste_etat(code, cote, libelle) VALUES ('L58', 'passif', 'Autres réserves');
INSERT INTO poste_etat(code, cote, libelle) VALUES ('L59', 'passif', 'Ecart de réévaluation des immobilisations');
INSERT INTO poste_etat(code, cote, libelle) VALUES ('L60', 'passif', 'Capital');
INSERT INTO poste_etat(code, cote, libelle) VALUES ('L61', 'passif', 'Capital appelé');
INSERT INTO poste_etat(code, cote, libelle) VALUES ('L62', 'passif', 'Capital non appelé');
INSERT INTO poste_etat(code, cote, libelle) VALUES ('L65', 'passif', 'Fonds de dotation');
INSERT INTO poste_etat(code, cote, libelle) VALUES ('L70', 'passif', 'Report à nouveau (+ ou -)');
INSERT INTO poste_etat(code, cote, libelle) VALUES ('L75', 'passif', 'Excédent des produits sur les charges');
INSERT INTO poste_etat(code, cote, libelle) VALUES ('L80', 'passif', 'Résultat de l''exercice (+ ou -)');
INSERT INTO poste_etat(code, cote, libelle) VALUES ('L81', 'passif', 'Excédent ou déficit en instance d''approbation');
INSERT INTO poste_etat(code, cote, libelle) VALUES ('L82', 'passif', 'Excédent ou déficit de l''exercice');
INSERT INTO poste_etat(code, cote, libelle) VALUES ('L90', 'passif', 'TOTAL PASSIF');
INSERT INTO poste_etat(code, cote, libelle) VALUES ('N1A', 'hors_bilan', 'ENGAGEMENTS DONNES EN FAVEUR DES INSTITUTIONS FINANCIERES');
INSERT INTO poste_etat(code, cote, libelle) VALUES ('N1H', 'hors_bilan', 'ENGAGEMENTS RECUS DES INSTITUTIONS FINANCIERES');
INSERT INTO poste_etat(code, cote, libelle) VALUES ('N1J', 'hors_bilan', 'ENGAGEMENTS DONNES EN FAVEUR DES MEMBRES, BENEFICIAIRES OU CLIENTS');
INSERT INTO poste_etat(code, cote, libelle) VALUES ('N1K', 'hors_bilan', 'ENGAGEMENTS RECUS DES MEMBRES, BENEFICIAIRES OU CLIENTS ENGAGEMENTS DE GARANTIE');
INSERT INTO poste_etat(code, cote, libelle) VALUES ('N2A', 'hors_bilan', 'D''ordre des institutions financières');
INSERT INTO poste_etat(code, cote, libelle) VALUES ('N2H', 'hors_bilan', 'Reçus des institutions financières');
INSERT INTO poste_etat(code, cote, libelle) VALUES ('N2J', 'hors_bilan', 'D''ordre des membres, bénéficiaires ou clients');
INSERT INTO poste_etat(code, cote, libelle) VALUES ('N2M', 'hors_bilan', 'Reçus des membres, bénéficiaires ou clients ENGAGEMENTS SUR TITRES');
INSERT INTO poste_etat(code, cote, libelle) VALUES ('N3A', 'hors_bilan', 'Titres à livrer');
INSERT INTO poste_etat(code, cote, libelle) VALUES ('N3B', 'hors_bilan', 'Intervention à l''émission');
INSERT INTO poste_etat(code, cote, libelle) VALUES ('N3C', 'hors_bilan', 'Marché gris');
INSERT INTO poste_etat(code, cote, libelle) VALUES ('N3D', 'hors_bilan', 'Autres titres à livrer');
INSERT INTO poste_etat(code, cote, libelle) VALUES ('N3E', 'hors_bilan', 'Titres à recevoir ENGAGEMENTS SUR OPERATIONS EN DEVISES OPERATIONS DE CHANGE AU COMPTANT');
INSERT INTO poste_etat(code, cote, libelle) VALUES ('N3H', 'hors_bilan', 'Autres titres à livrer ENGAGEMENTS SUR OPERATIONS EN DEVISES OPERATIONS DE CHANGE AU COMPTANT');
INSERT INTO poste_etat(code, cote, libelle) VALUES ('N90', 'hors_bilan', 'ENGAGEMENTS DOUTEUX');
INSERT INTO poste_etat(code, cote, libelle) VALUES ('NRF', 'hors_bilan', 'Intervention à l''émission');
INSERT INTO poste_etat(code, cote, libelle) VALUES ('NRG', 'hors_bilan', 'Marché gris');
INSERT INTO poste_etat(code, cote, libelle) VALUES ('P1A', 'hors_bilan', 'Francs CFA achetés non encore reçus');
INSERT INTO poste_etat(code, cote, libelle) VALUES ('P1B', 'hors_bilan', 'Devises achetées non encore reçues');
INSERT INTO poste_etat(code, cote, libelle) VALUES ('P1C', 'hors_bilan', 'Francs CFA vendus non encore livrés');
INSERT INTO poste_etat(code, cote, libelle) VALUES ('P1D', 'hors_bilan', 'Devises vendues non encore livrées PRETS OU EMPRUNTS EN DEVISES');
INSERT INTO poste_etat(code, cote, libelle) VALUES ('P1E', 'hors_bilan', 'Devises prêtées non encore livrées');
INSERT INTO poste_etat(code, cote, libelle) VALUES ('P1F', 'hors_bilan', 'Devises empruntées non encore reçues OPERATIONS DE CHANGE A TERME');
INSERT INTO poste_etat(code, cote, libelle) VALUES ('P1G', 'hors_bilan', 'Opérations de change à terme francs cfa à recevoir contre devises à livrer');
INSERT INTO poste_etat(code, cote, libelle) VALUES ('P1H', 'hors_bilan', 'Opérations de change à terme devises à recevoir contre FCFA à livrer');
INSERT INTO poste_etat(code, cote, libelle) VALUES ('P1J', 'hors_bilan', 'Opérations de change à terme devises à recevoir contre devises à livrer');
INSERT INTO poste_etat(code, cote, libelle) VALUES ('P1K', 'hors_bilan', 'Opérations de change à terme devises à livrer contre devises à recevoir');
INSERT INTO poste_etat(code, cote, libelle) VALUES ('P1L', 'hors_bilan', 'Report/déport non couru à recevoir');
INSERT INTO poste_etat(code, cote, libelle) VALUES ('P1M', 'hors_bilan', 'Report/déport non couru à payer');
INSERT INTO poste_etat(code, cote, libelle) VALUES ('P1R', 'hors_bilan', 'Intérêts non courus en devises couverts à recevoir');
INSERT INTO poste_etat(code, cote, libelle) VALUES ('P1S', 'hors_bilan', 'Intérêts non courus en devises couverts à payer');
INSERT INTO poste_etat(code, cote, libelle) VALUES ('P1V', 'hors_bilan', 'Ajustements devises hors bilan AUTRES ENGAGEMENTS');
INSERT INTO poste_etat(code, cote, libelle) VALUES ('Q1A', 'hors_bilan', 'Engagements donnés');
INSERT INTO poste_etat(code, cote, libelle) VALUES ('Q1B', 'hors_bilan', 'Engagemements reçus OPERATIONS EFFECTUES POUR LE COMPTE DE TIERS');
INSERT INTO poste_etat(code, cote, libelle) VALUES ('Q1C', 'hors_bilan', 'Valeurs à l''encaissement non disponibles');
INSERT INTO poste_etat(code, cote, libelle) VALUES ('Q1F', 'hors_bilan', 'Comptes exigibles après encaissements Q1J Comptes de suivi des engagements de financement consortiaux');
INSERT INTO poste_etat(code, cote, libelle) VALUES ('Q1K', 'hors_bilan', 'Comptes de suivi des engagements de garantie consortiaux');
INSERT INTO poste_etat(code, cote, libelle) VALUES ('Q1L', 'hors_bilan', 'Comptes de suivi des crédits consortiaux');
INSERT INTO poste_etat(code, cote, libelle) VALUES ('Q1M', 'hors_bilan', 'Crédits distribués pour le compte de tiers');
INSERT INTO poste_etat(code, cote, libelle) VALUES ('QIJ', 'hors_bilan', 'QIJ');
INSERT INTO poste_etat(code, cote, libelle) VALUES ('R08', 'charge', 'CHARGES SUR OPERATIONS AVEC LES INSTITUTIONS FINANCIERES');
INSERT INTO poste_etat(code, cote, libelle) VALUES ('R1A', 'charge', 'Intérêts sur comptes ordinaires créditeurs');
INSERT INTO poste_etat(code, cote, libelle) VALUES ('R1B', 'charge', 'Organe financier');
INSERT INTO poste_etat(code, cote, libelle) VALUES ('R1C', 'charge', 'Caisse centrale');
INSERT INTO poste_etat(code, cote, libelle) VALUES ('R1D', 'charge', 'Trésor Public');
INSERT INTO poste_etat(code, cote, libelle) VALUES ('R1E', 'charge', 'R1E');
INSERT INTO poste_etat(code, cote, libelle) VALUES ('R1F', 'charge', 'Banques et correspondants');
INSERT INTO poste_etat(code, cote, libelle) VALUES ('R1H', 'charge', 'Etablissements financiers');
INSERT INTO poste_etat(code, cote, libelle) VALUES ('R1I', 'charge', 'R1I');
INSERT INTO poste_etat(code, cote, libelle) VALUES ('R1K', 'charge', 'Autres institutions financières');
INSERT INTO poste_etat(code, cote, libelle) VALUES ('R1L', 'charge', 'Intérêts sur autres comptes de dépôts créditeurs');
INSERT INTO poste_etat(code, cote, libelle) VALUES ('R1N', 'charge', 'Dépôts à terme reçus');
INSERT INTO poste_etat(code, cote, libelle) VALUES ('R1P', 'charge', 'Dépôts de garantie reçus');
INSERT INTO poste_etat(code, cote, libelle) VALUES ('R1Q', 'charge', 'Autres dépôts reçus');
INSERT INTO poste_etat(code, cote, libelle) VALUES ('R2A', 'charge', 'Intérêts sur comptes d''emprunts');
INSERT INTO poste_etat(code, cote, libelle) VALUES ('R2F', 'charge', 'Intérêts sur emprunts à moins d''un an');
INSERT INTO poste_etat(code, cote, libelle) VALUES ('R2G', 'charge', 'Intérêts sur emprunts à terme');
INSERT INTO poste_etat(code, cote, libelle) VALUES ('R2R', 'charge', 'Autres intérêts');
INSERT INTO poste_etat(code, cote, libelle) VALUES ('R2T', 'charge', 'Divers intérêts');
INSERT INTO poste_etat(code, cote, libelle) VALUES ('R2Z', 'charge', 'Commissions');
INSERT INTO poste_etat(code, cote, libelle) VALUES ('R3A', 'charge', 'CHARGES SUR OPERATIONS AVEC LES MEMBRES, BENEFICIAIRES OU CLIENTS');
INSERT INTO poste_etat(code, cote, libelle) VALUES ('R3C', 'charge', 'Intérêts sur comptes des membres, bénéficiaires ou clients');
INSERT INTO poste_etat(code, cote, libelle) VALUES ('R3D', 'charge', 'Intérêts sur comptes ordinaires créditeurs');
INSERT INTO poste_etat(code, cote, libelle) VALUES ('R3F', 'charge', 'Intérêts sur dépôts à terme reçus');
INSERT INTO poste_etat(code, cote, libelle) VALUES ('R3G', 'charge', 'Intérêts sur comptes d''épargne à régime spécial');
INSERT INTO poste_etat(code, cote, libelle) VALUES ('R3H', 'charge', 'Intérêts sur dépôts de garantie reçus');
INSERT INTO poste_etat(code, cote, libelle) VALUES ('R3J', 'charge', 'Intérêts sur autres dépôts reçus');
INSERT INTO poste_etat(code, cote, libelle) VALUES ('R3N', 'charge', 'Intérêts sur emprunts et autres sommes dues');
INSERT INTO poste_etat(code, cote, libelle) VALUES ('R3Q', 'charge', 'Autres Intérêts');
INSERT INTO poste_etat(code, cote, libelle) VALUES ('R3T', 'charge', 'Commissions');
INSERT INTO poste_etat(code, cote, libelle) VALUES ('R4B', 'charge', 'CHARGES SUR OPERATIONS SUR TITRES ET OPERATIONS DIVERSES');
INSERT INTO poste_etat(code, cote, libelle) VALUES ('R4C', 'charge', 'Charges et pertes sur titres de placement');
INSERT INTO poste_etat(code, cote, libelle) VALUES ('R4K', 'charge', 'Charges sur opérations diverses');
INSERT INTO poste_etat(code, cote, libelle) VALUES ('R4N', 'charge', 'Commissions');
INSERT INTO poste_etat(code, cote, libelle) VALUES ('R5B', 'charge', 'CHARGES SUR IMMOBILISATIONS FINANCIERES');
INSERT INTO poste_etat(code, cote, libelle) VALUES ('R5C', 'charge', 'Frais d''acquisition');
INSERT INTO poste_etat(code, cote, libelle) VALUES ('R5D', 'charge', 'Etalement de la prime');
INSERT INTO poste_etat(code, cote, libelle) VALUES ('R5E', 'charge', 'CHARGES SUR CREDIT BAIL et OPERATIONS ASSIMILEES');
INSERT INTO poste_etat(code, cote, libelle) VALUES ('R5G', 'charge', 'Charges sur opérations de crédit bail');
INSERT INTO poste_etat(code, cote, libelle) VALUES ('R5H', 'charge', 'Dotations aux amortissements');
INSERT INTO poste_etat(code, cote, libelle) VALUES ('R5J', 'charge', 'Dotations aux provisions');
INSERT INTO poste_etat(code, cote, libelle) VALUES ('R5K', 'charge', 'Moins-values de cession');
INSERT INTO poste_etat(code, cote, libelle) VALUES ('R5L', 'charge', 'Autres charges');
INSERT INTO poste_etat(code, cote, libelle) VALUES ('R5M', 'charge', 'Charges sur opérations de location avec option d''achat');
INSERT INTO poste_etat(code, cote, libelle) VALUES ('R5N', 'charge', 'Dotations aux amortissements');
INSERT INTO poste_etat(code, cote, libelle) VALUES ('R5P', 'charge', 'Dotations aux provisions');
INSERT INTO poste_etat(code, cote, libelle) VALUES ('R5Q', 'charge', 'Moins-values de cession');
INSERT INTO poste_etat(code, cote, libelle) VALUES ('R5R', 'charge', 'Autres charges');
INSERT INTO poste_etat(code, cote, libelle) VALUES ('R5S', 'charge', 'Charges sur opérations de location-vente');
INSERT INTO poste_etat(code, cote, libelle) VALUES ('R5T', 'charge', 'Dotations aux amortissements');
INSERT INTO poste_etat(code, cote, libelle) VALUES ('R5U', 'charge', 'Dotations aux provisions');
INSERT INTO poste_etat(code, cote, libelle) VALUES ('R5V', 'charge', 'Moins-values de cession');
INSERT INTO poste_etat(code, cote, libelle) VALUES ('R5X', 'charge', 'Autres charges');
INSERT INTO poste_etat(code, cote, libelle) VALUES ('R5Y', 'charge', 'Charges sur emprunts et titres émis subordonnés');
INSERT INTO poste_etat(code, cote, libelle) VALUES ('R6A', 'charge', 'CHARGES SUR OPERATIONS DE CHANGE');
INSERT INTO poste_etat(code, cote, libelle) VALUES ('R6B', 'charge', 'Pertes sur opérations de change');
INSERT INTO poste_etat(code, cote, libelle) VALUES ('R6C', 'charge', 'Commissions');
INSERT INTO poste_etat(code, cote, libelle) VALUES ('R6F', 'charge', 'CHARGES SUR OPERATIONS HORS BILAN');
INSERT INTO poste_etat(code, cote, libelle) VALUES ('R6K', 'charge', 'Charges sur engagements de financements reçus des institutions financières');
INSERT INTO poste_etat(code, cote, libelle) VALUES ('R6L', 'charge', 'Charges sur engagements de financements reçus des membres, clients ou bénéficiaires');
INSERT INTO poste_etat(code, cote, libelle) VALUES ('R6M', 'charge', 'Charges sur engagements de garantie reçus des institutions financières');
INSERT INTO poste_etat(code, cote, libelle) VALUES ('R6P', 'charge', 'Charges sur engagements de garantie reçus des membres, bénéficiaires ou clients');
INSERT INTO poste_etat(code, cote, libelle) VALUES ('R6S', 'charge', 'Charges sur engagements sur titres');
INSERT INTO poste_etat(code, cote, libelle) VALUES ('R6T', 'charge', 'Charges sur autres engagements reçus');
INSERT INTO poste_etat(code, cote, libelle) VALUES ('R6V', 'charge', 'CHARGES SUR PRESTATIONS DE SERVICES FINANCIERS');
INSERT INTO poste_etat(code, cote, libelle) VALUES ('R6W', 'charge', 'Charges sur les moyens de paiement');
INSERT INTO poste_etat(code, cote, libelle) VALUES ('R6X', 'charge', 'Autres charges sur prestations de services financiers');
INSERT INTO poste_etat(code, cote, libelle) VALUES ('R7A', 'charge', 'AUTRES CHARGES D''EXPLOITATION FINANCIERE');
INSERT INTO poste_etat(code, cote, libelle) VALUES ('R7B', 'charge', 'Moins-values sur cession d''éléments d''actif');
INSERT INTO poste_etat(code, cote, libelle) VALUES ('R7C', 'charge', 'Transferts de produits d''exploitation financière');
INSERT INTO poste_etat(code, cote, libelle) VALUES ('R7D', 'charge', 'Diverses charges d''exploitation financière');
INSERT INTO poste_etat(code, cote, libelle) VALUES ('R8G', 'charge', 'Achats de marchandises');
INSERT INTO poste_etat(code, cote, libelle) VALUES ('R8J', 'charge', 'Stocks vendus');
INSERT INTO poste_etat(code, cote, libelle) VALUES ('R8L', 'charge', 'Variations de stocks marchandises ANNEXE 3.3');
INSERT INTO poste_etat(code, cote, libelle) VALUES ('S02', 'charge', 'FRAIS DE PERSONNEL');
INSERT INTO poste_etat(code, cote, libelle) VALUES ('S03', 'charge', 'Salaires et traitements');
INSERT INTO poste_etat(code, cote, libelle) VALUES ('S04', 'charge', 'Charges sociales');
INSERT INTO poste_etat(code, cote, libelle) VALUES ('S05', 'charge', 'S05');
INSERT INTO poste_etat(code, cote, libelle) VALUES ('S1A', 'charge', 'IMPOTS ET TAXES');
INSERT INTO poste_etat(code, cote, libelle) VALUES ('S1B', 'charge', 'Autres impôts, taxes et versements assimilés sur rémunérations');
INSERT INTO poste_etat(code, cote, libelle) VALUES ('S1C', 'charge', 'Autres impôts , taxes et prélévements assimilés versés à l''administration des impôts');
INSERT INTO poste_etat(code, cote, libelle) VALUES ('S1D', 'charge', 'Impôts directs');
INSERT INTO poste_etat(code, cote, libelle) VALUES ('S1G', 'charge', 'Impôts indirects');
INSERT INTO poste_etat(code, cote, libelle) VALUES ('S1H', 'charge', 'Droits d''enregistrement et de timbre');
INSERT INTO poste_etat(code, cote, libelle) VALUES ('S1J', 'charge', 'Impôts et taxes divers');
INSERT INTO poste_etat(code, cote, libelle) VALUES ('S1K', 'charge', 'Autres impôts, taxes et prélèvements assimilés versés aux autres organismes');
INSERT INTO poste_etat(code, cote, libelle) VALUES ('S2A', 'charge', 'AUTRES CHARGES EXTERNES ET CHARGES DIVERSES D''EXPLOITATION');
INSERT INTO poste_etat(code, cote, libelle) VALUES ('S2B', 'charge', 'Services extérieurs');
INSERT INTO poste_etat(code, cote, libelle) VALUES ('S2C', 'charge', 'Redevances de crédit-bail');
INSERT INTO poste_etat(code, cote, libelle) VALUES ('S2D', 'charge', 'Loyers');
INSERT INTO poste_etat(code, cote, libelle) VALUES ('S2F', 'charge', 'Charges locatives et de co-propriété');
INSERT INTO poste_etat(code, cote, libelle) VALUES ('S2H', 'charge', 'Entretien et réparations');
INSERT INTO poste_etat(code, cote, libelle) VALUES ('S2J', 'charge', 'Primes d''assurance');
INSERT INTO poste_etat(code, cote, libelle) VALUES ('S2K', 'charge', 'Etudes et recherches');
INSERT INTO poste_etat(code, cote, libelle) VALUES ('S2L', 'charge', 'Divers');
INSERT INTO poste_etat(code, cote, libelle) VALUES ('S2M', 'charge', 'Frais de formation du personnel');
INSERT INTO poste_etat(code, cote, libelle) VALUES ('S3A', 'charge', 'Autres services extérieurs');
INSERT INTO poste_etat(code, cote, libelle) VALUES ('S3B', 'charge', 'Personnel extérieur à l''institution');
INSERT INTO poste_etat(code, cote, libelle) VALUES ('S3C', 'charge', 'Rémunérations d''intermédiaires et honoraires');
INSERT INTO poste_etat(code, cote, libelle) VALUES ('S3E', 'charge', 'Publicité, publications et relations publiques');
INSERT INTO poste_etat(code, cote, libelle) VALUES ('S3G', 'charge', 'Transports de biens');
INSERT INTO poste_etat(code, cote, libelle) VALUES ('S3J', 'charge', 'Transports collectifs du personnel');
INSERT INTO poste_etat(code, cote, libelle) VALUES ('S3L', 'charge', 'Déplacements, missions et réceptions');
INSERT INTO poste_etat(code, cote, libelle) VALUES ('S3M', 'charge', 'Achats non stockés de matières et fournitures');
INSERT INTO poste_etat(code, cote, libelle) VALUES ('S3N', 'charge', 'Frais postaux et frais de télécommunication');
INSERT INTO poste_etat(code, cote, libelle) VALUES ('S3P', 'charge', 'Divers');
INSERT INTO poste_etat(code, cote, libelle) VALUES ('S4A', 'charge', 'Charges diverses d''exploitation');
INSERT INTO poste_etat(code, cote, libelle) VALUES ('S4B', 'charge', 'Redevances pour concessions,brevets, licences, procédés, droits et valeurs similaires');
INSERT INTO poste_etat(code, cote, libelle) VALUES ('S4D', 'charge', 'Indemnités de fonction versées');
INSERT INTO poste_etat(code, cote, libelle) VALUES ('S4I', 'charge', 'Frais de tenue d''assemblée');
INSERT INTO poste_etat(code, cote, libelle) VALUES ('S4K', 'charge', 'Moins-values de cession sur immobilisations');
INSERT INTO poste_etat(code, cote, libelle) VALUES ('S4L', 'charge', 'sur immobilisations corporelles et incorporelles');
INSERT INTO poste_etat(code, cote, libelle) VALUES ('S4M', 'charge', 'sur immobilisations financières');
INSERT INTO poste_etat(code, cote, libelle) VALUES ('S4P', 'charge', 'Transferts de produits d''exploitation non financière');
INSERT INTO poste_etat(code, cote, libelle) VALUES ('S4Q', 'charge', 'Produits rétrocédés');
INSERT INTO poste_etat(code, cote, libelle) VALUES ('S4R', 'charge', 'Autres transferts de produits');
INSERT INTO poste_etat(code, cote, libelle) VALUES ('S4S', 'charge', 'Autres charges diverses d''exploitation non financière');
INSERT INTO poste_etat(code, cote, libelle) VALUES ('T50', 'charge', 'DOTATIONS AU FONDS POUR RISQUES FINANCIERS GENERAUX DOTATIONS AUX AMORTISSEMENTS ET AUX PROVISIONS');
INSERT INTO poste_etat(code, cote, libelle) VALUES ('T51', 'charge', 'DOTATIONS AUX AMORTISSEMENTS ET AUX PROVISIONS SUR IMMOBILISATIONS');
INSERT INTO poste_etat(code, cote, libelle) VALUES ('T53', 'charge', 'Dotation aux amortissements de charges à répartir');
INSERT INTO poste_etat(code, cote, libelle) VALUES ('T54', 'charge', 'Dotations aux amortissements des immobilisations d''exploitation');
INSERT INTO poste_etat(code, cote, libelle) VALUES ('T55', 'charge', 'Dotations aux amortissements des immobilisations hors exploitation');
INSERT INTO poste_etat(code, cote, libelle) VALUES ('T56', 'charge', 'Dotations aux provisions pour dépréciation des immobilisations en cours');
INSERT INTO poste_etat(code, cote, libelle) VALUES ('T57', 'charge', 'Dotations aux provisions pour dépréciation des immobilisations d''exploitation');
INSERT INTO poste_etat(code, cote, libelle) VALUES ('T58', 'charge', 'Dotations aux provisions pour dépréciation des immobilisations hors exploitation');
INSERT INTO poste_etat(code, cote, libelle) VALUES ('T6B', 'charge', 'DOTATIONS AUX PROVISIONS ET PERTES SUR CREANCES IRRECOUVRABLES');
INSERT INTO poste_etat(code, cote, libelle) VALUES ('T6C', 'charge', 'Dotations aux provisions sur créances en souffrance');
INSERT INTO poste_etat(code, cote, libelle) VALUES ('T6D', 'charge', 'Dotations aux provisions sur créances en souffrance de 6 mois au plus');
INSERT INTO poste_etat(code, cote, libelle) VALUES ('T6E', 'charge', 'Dotations aux provisions sur créances en souffrance de plus de 6 mois à 12 mois au plus');
INSERT INTO poste_etat(code, cote, libelle) VALUES ('T6F', 'charge', 'Dotations aux provisions sur créances en souffrance de plus de 12 mois à 24 mois au plus');
INSERT INTO poste_etat(code, cote, libelle) VALUES ('T6G', 'charge', 'Dotations aux provisions pour dépréciation d''autres éléments d''actif');
INSERT INTO poste_etat(code, cote, libelle) VALUES ('T6H', 'charge', 'Dotations aux provisions pour risques et charges');
INSERT INTO poste_etat(code, cote, libelle) VALUES ('T6J', 'charge', 'Dotations aux provisions réglementées');
INSERT INTO poste_etat(code, cote, libelle) VALUES ('T6K', 'charge', 'Pertes sur créances irrécouvrables couvertes par des provisions');
INSERT INTO poste_etat(code, cote, libelle) VALUES ('T6L', 'charge', 'Pertes sur créances irrécouvrables non couvertes par des provisions');
INSERT INTO poste_etat(code, cote, libelle) VALUES ('T80', 'charge', 'CHARGES EXCEPTIONNELLES');
INSERT INTO poste_etat(code, cote, libelle) VALUES ('T81', 'charge', 'PERTES SUR EXERCICES ANTERIEURS');
INSERT INTO poste_etat(code, cote, libelle) VALUES ('T82', 'charge', 'IMPOTS SUR LES EXCEDENTS');
INSERT INTO poste_etat(code, cote, libelle) VALUES ('T84', 'charge', 'TOTAL CHARGES');
INSERT INTO poste_etat(code, cote, libelle) VALUES ('V08', 'produit', 'PRODUITS SUR OPERATIONS AVEC LES INSTITUTIONS FINANCIERES');
INSERT INTO poste_etat(code, cote, libelle) VALUES ('V1A', 'produit', 'Intérêts sur comptes ordinaires débiteurs');
INSERT INTO poste_etat(code, cote, libelle) VALUES ('V1B', 'produit', 'Organe financier');
INSERT INTO poste_etat(code, cote, libelle) VALUES ('V1C', 'produit', 'Caisse centrale');
INSERT INTO poste_etat(code, cote, libelle) VALUES ('V1D', 'produit', 'Trésor Public');
INSERT INTO poste_etat(code, cote, libelle) VALUES ('V1E', 'produit', 'V1E');
INSERT INTO poste_etat(code, cote, libelle) VALUES ('V1F', 'produit', 'Banques et correspondants');
INSERT INTO poste_etat(code, cote, libelle) VALUES ('V1H', 'produit', 'Etablissements financiers');
INSERT INTO poste_etat(code, cote, libelle) VALUES ('V1I', 'produit', 'V1I');
INSERT INTO poste_etat(code, cote, libelle) VALUES ('V1K', 'produit', 'Autres institutions financières');
INSERT INTO poste_etat(code, cote, libelle) VALUES ('V1L', 'produit', 'Intérêts sur autres comptes de dépôts débiteurs');
INSERT INTO poste_etat(code, cote, libelle) VALUES ('V1Q', 'produit', 'Intérêts sur dépôts à terme constitués');
INSERT INTO poste_etat(code, cote, libelle) VALUES ('V1R', 'produit', 'Intérêts sur dépôts de garantie constitués');
INSERT INTO poste_etat(code, cote, libelle) VALUES ('V1S', 'produit', 'Intérêts sur autres dépôts constitués');
INSERT INTO poste_etat(code, cote, libelle) VALUES ('V2A', 'produit', 'Intérêts sur comptes de prêts');
INSERT INTO poste_etat(code, cote, libelle) VALUES ('V2C', 'produit', 'Intérêts sur prêts à moins d''un an');
INSERT INTO poste_etat(code, cote, libelle) VALUES ('V2G', 'produit', 'Intérêts sur prêts à terme');
INSERT INTO poste_etat(code, cote, libelle) VALUES ('V2Q', 'produit', 'Autres Intérêts');
INSERT INTO poste_etat(code, cote, libelle) VALUES ('V2S', 'produit', 'Divers Intérêts');
INSERT INTO poste_etat(code, cote, libelle) VALUES ('V2T', 'produit', 'Commissions');
INSERT INTO poste_etat(code, cote, libelle) VALUES ('V3A', 'produit', 'PRODUITS SUR OPERATIONS AVEC LES MEMBRES, BENEFICIAIRES OU CLIENTS');
INSERT INTO poste_etat(code, cote, libelle) VALUES ('V3B', 'produit', 'Intérêts sur crédits aux membres, bénéficiaires ou clients');
INSERT INTO poste_etat(code, cote, libelle) VALUES ('V3G', 'produit', 'Autres crédits à court terme');
INSERT INTO poste_etat(code, cote, libelle) VALUES ('V3M', 'produit', 'Intérêts sur crédits à moyen terme');
INSERT INTO poste_etat(code, cote, libelle) VALUES ('V3N', 'produit', 'Intérêts sur crédits à long terme');
INSERT INTO poste_etat(code, cote, libelle) VALUES ('V3R', 'produit', 'Autres Intérêts');
INSERT INTO poste_etat(code, cote, libelle) VALUES ('V3T', 'produit', 'Divers Intérêts');
INSERT INTO poste_etat(code, cote, libelle) VALUES ('V3X', 'produit', 'Commissions MARGE D''INTERET BENEFICIAIRE MARGE D''INTERET DEFICITAIRE TOTAL CHARGES D''INTERETS TOTAL PRODUITS D''INTERETS');
INSERT INTO poste_etat(code, cote, libelle) VALUES ('V4B', 'produit', 'PRODUITS SUR OPERATIONS SUR TITRES ET SUR OPERATIONS DIVERSES');
INSERT INTO poste_etat(code, cote, libelle) VALUES ('V4C', 'produit', 'Produits et profits sur titres de placement');
INSERT INTO poste_etat(code, cote, libelle) VALUES ('V4D', 'produit', 'Intérêts sur crédits accordés au personnel non membre');
INSERT INTO poste_etat(code, cote, libelle) VALUES ('V4E', 'produit', 'Produits sur opérations diverses');
INSERT INTO poste_etat(code, cote, libelle) VALUES ('V4F', 'produit', 'Commissions');
INSERT INTO poste_etat(code, cote, libelle) VALUES ('V5B', 'produit', 'PRODUITS SUR IMMOBILISATIONS FINANCIERES');
INSERT INTO poste_etat(code, cote, libelle) VALUES ('V5C', 'produit', 'Produits sur prêts et titres subordonnés');
INSERT INTO poste_etat(code, cote, libelle) VALUES ('V5D', 'produit', 'Dividendes et produits assimilés sur titres de participation');
INSERT INTO poste_etat(code, cote, libelle) VALUES ('V5F', 'produit', 'Produits et profits sur titres d''investissement');
INSERT INTO poste_etat(code, cote, libelle) VALUES ('V5G', 'produit', 'PRODUITS SUR OPERATIONS DE CREDIT BAIL ET OPERATIONS ASSIMILEES');
INSERT INTO poste_etat(code, cote, libelle) VALUES ('V5H', 'produit', 'Produits sur opérations de crédit-bail');
INSERT INTO poste_etat(code, cote, libelle) VALUES ('V5J', 'produit', 'Loyers');
INSERT INTO poste_etat(code, cote, libelle) VALUES ('V5K', 'produit', 'Reprises de provisions');
INSERT INTO poste_etat(code, cote, libelle) VALUES ('V5L', 'produit', 'Plus-values de cession');
INSERT INTO poste_etat(code, cote, libelle) VALUES ('V5M', 'produit', 'Autres produits');
INSERT INTO poste_etat(code, cote, libelle) VALUES ('V5N', 'produit', 'Produits sur opérations de location avec option d''achat');
INSERT INTO poste_etat(code, cote, libelle) VALUES ('V5P', 'produit', 'Loyers');
INSERT INTO poste_etat(code, cote, libelle) VALUES ('V5Q', 'produit', 'Reprises de provisions');
INSERT INTO poste_etat(code, cote, libelle) VALUES ('V5R', 'produit', 'Plus-values de cession');
INSERT INTO poste_etat(code, cote, libelle) VALUES ('V5S', 'produit', 'Autres produits');
INSERT INTO poste_etat(code, cote, libelle) VALUES ('V5T', 'produit', 'Produits sur opérations de location vente');
INSERT INTO poste_etat(code, cote, libelle) VALUES ('V5V', 'produit', 'Loyers');
INSERT INTO poste_etat(code, cote, libelle) VALUES ('V5W', 'produit', 'Reprises de provisions');
INSERT INTO poste_etat(code, cote, libelle) VALUES ('V5X', 'produit', 'Plus-values de cession');
INSERT INTO poste_etat(code, cote, libelle) VALUES ('V5Y', 'produit', 'Autres produits');
INSERT INTO poste_etat(code, cote, libelle) VALUES ('V6A', 'produit', 'PRODUITS SUR OPERATIONS DE CHANGE');
INSERT INTO poste_etat(code, cote, libelle) VALUES ('V6B', 'produit', 'Gains sur opérations de change');
INSERT INTO poste_etat(code, cote, libelle) VALUES ('V6C', 'produit', 'Commissions');
INSERT INTO poste_etat(code, cote, libelle) VALUES ('V6F', 'produit', 'PRODUITS SUR OPERATIONS HORS BILAN');
INSERT INTO poste_etat(code, cote, libelle) VALUES ('V6K', 'produit', 'Produits sur engagements de financement donnés aux institutions financières');
INSERT INTO poste_etat(code, cote, libelle) VALUES ('V6L', 'produit', 'Produits sur engagements de financement donnés aux membres, bénéficiaires ou clients');
INSERT INTO poste_etat(code, cote, libelle) VALUES ('V6N', 'produit', 'Produits sur engagements de garantie donnés aux institutions financières');
INSERT INTO poste_etat(code, cote, libelle) VALUES ('V6P', 'produit', 'Produits sur engagements de garantie donnés aux membres, bénéficiaires ou clients');
INSERT INTO poste_etat(code, cote, libelle) VALUES ('V6Q', 'produit', 'Produits sur engagements sur titres');
INSERT INTO poste_etat(code, cote, libelle) VALUES ('V6R', 'produit', 'Produits sur autres engagements donnés');
INSERT INTO poste_etat(code, cote, libelle) VALUES ('V6S', 'produit', 'Produits sur opérations effectuées pour le compte de tiers .0');
INSERT INTO poste_etat(code, cote, libelle) VALUES ('V6U', 'produit', 'PRODUITS SUR PRESTATIONS DE SERVICES FINANCIERS');
INSERT INTO poste_etat(code, cote, libelle) VALUES ('V6V', 'produit', 'Produits sur les moyens de paiement');
INSERT INTO poste_etat(code, cote, libelle) VALUES ('V6W', 'produit', 'Autres produits sur prestations de services financiers');
INSERT INTO poste_etat(code, cote, libelle) VALUES ('V7A', 'produit', 'AUTRES PRODUITS D''EXPLOITATION FINANCIERE');
INSERT INTO poste_etat(code, cote, libelle) VALUES ('V7B', 'produit', 'Plus - values sur cession d''éléments d''actif');
INSERT INTO poste_etat(code, cote, libelle) VALUES ('V7C', 'produit', 'Transferts de charges d''exploitation financière');
INSERT INTO poste_etat(code, cote, libelle) VALUES ('V7D', 'produit', 'V7D');
INSERT INTO poste_etat(code, cote, libelle) VALUES ('V8B', 'produit', 'MARGE COMMERCIALE VENTES s');
INSERT INTO poste_etat(code, cote, libelle) VALUES ('V8C', 'produit', 'Vente de marchandises');
INSERT INTO poste_etat(code, cote, libelle) VALUES ('W4A', 'produit', 'PRODUITS DIVERS D''EXPLOITATION');
INSERT INTO poste_etat(code, cote, libelle) VALUES ('W4B', 'produit', 'Redevances pour concessions, brevets, licences, droits et valeurs similaires');
INSERT INTO poste_etat(code, cote, libelle) VALUES ('W4D', 'produit', 'Indemnités de fonction et rémunération d''administrateurs, gérants reçues');
INSERT INTO poste_etat(code, cote, libelle) VALUES ('W4G', 'produit', 'Plus-values de cession');
INSERT INTO poste_etat(code, cote, libelle) VALUES ('W4H', 'produit', 'sur immobilisations incorporelles et corporelles');
INSERT INTO poste_etat(code, cote, libelle) VALUES ('W4J', 'produit', 'sur immobilisations financières');
INSERT INTO poste_etat(code, cote, libelle) VALUES ('W4K', 'produit', 'Revenus des immeubles hors exploitation');
INSERT INTO poste_etat(code, cote, libelle) VALUES ('W4L', 'produit', 'Transferts de charges d''exploitation non financière');
INSERT INTO poste_etat(code, cote, libelle) VALUES ('W4M', 'produit', 'Charges refacturées');
INSERT INTO poste_etat(code, cote, libelle) VALUES ('W4N', 'produit', 'Charges à répartir sur plusieurs exercices');
INSERT INTO poste_etat(code, cote, libelle) VALUES ('W4P', 'produit', 'Autres transferts de charges');
INSERT INTO poste_etat(code, cote, libelle) VALUES ('W4Q', 'produit', 'AUTRES PRODUITS DIVERS D''EXPLOITATION');
INSERT INTO poste_etat(code, cote, libelle) VALUES ('W50', 'produit', 'PRODUCTION IMMOBILISEE');
INSERT INTO poste_etat(code, cote, libelle) VALUES ('W51', 'produit', 'Immobilisations corporelles');
INSERT INTO poste_etat(code, cote, libelle) VALUES ('W52', 'produit', 'Immobilisations incorporelles');
INSERT INTO poste_etat(code, cote, libelle) VALUES ('W53', 'produit', 'SUBVENTIONS D''EXPLOITATION');
INSERT INTO poste_etat(code, cote, libelle) VALUES ('X50', 'produit', 'REPRISES DU FONDS POUR RISQUES FINANCIERS GENERAUX');
INSERT INTO poste_etat(code, cote, libelle) VALUES ('X51', 'produit', 'REPRISES D''AMORTISSEMENTS ET PROVISIONS SUR IMMOBILISATIONS');
INSERT INTO poste_etat(code, cote, libelle) VALUES ('X54', 'produit', 'Reprises d''amortissements des immobilisations');
INSERT INTO poste_etat(code, cote, libelle) VALUES ('X56', 'produit', 'Reprises de provisions sur immobilisations');
INSERT INTO poste_etat(code, cote, libelle) VALUES ('X6B', 'produit', 'REPRISES DE PROVISIONS ET RECUPERATIONS SUR CREANCES AMORTIES');
INSERT INTO poste_etat(code, cote, libelle) VALUES ('X6C', 'produit', 'Reprises de provisions sur créances en souffrance');
INSERT INTO poste_etat(code, cote, libelle) VALUES ('X6D', 'produit', 'Reprises de provisions sur créances en souffrance de 6 mois au plus');
INSERT INTO poste_etat(code, cote, libelle) VALUES ('X6E', 'produit', 'Reprises de provisions sur créances en souffrance de plus de 6 mois à 12 mois au plus');
INSERT INTO poste_etat(code, cote, libelle) VALUES ('X6F', 'produit', 'Reprises de provisions sur créances en souffrance de plus de 12 mois à 24 mois au plus');
INSERT INTO poste_etat(code, cote, libelle) VALUES ('X6G', 'produit', 'Reprises de provisions pour dépréciation des autres éléments d''actif');
INSERT INTO poste_etat(code, cote, libelle) VALUES ('X6H', 'produit', 'Reprises de provisions pour risques et charges');
INSERT INTO poste_etat(code, cote, libelle) VALUES ('X6I', 'produit', 'Reprises de provisions réglementées');
INSERT INTO poste_etat(code, cote, libelle) VALUES ('X6J', 'produit', 'Récupération sur créances amorties');
INSERT INTO poste_etat(code, cote, libelle) VALUES ('X80', 'produit', 'PRODUITS EXCEPTIONNELS');
INSERT INTO poste_etat(code, cote, libelle) VALUES ('X81', 'produit', 'PROFITS SUR EXERCICES ANTERIEURS');
INSERT INTO poste_etat(code, cote, libelle) VALUES ('X84', 'produit', 'TOTAL PRODUITS');
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('A01', '101', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('A01', '1101', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('A01', '111111', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('A01', '111121', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('A01', '1121', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('A01', '1131', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('A01', '1141', 1, true);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('A01', '1151', 1, true);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('A01', '1161', 1, true);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('A01', '1171', 1, true);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('A01', '111117', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('A01', '111127', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('A01', '1137', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('A01', '1147', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('A01', '1157', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('A01', '1167', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('A01', '1177', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('A01', '1261', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('A01', '1271', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('A01', '1281', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('A01', '1267', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('A01', '1277', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('A01', '1287', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('A01', '1311', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('A01', '1331', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('A01', '1511', 1, true);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('A01', '1521', 1, true);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('A01', '1531', 1, true);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('A01', '1541', 1, true);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('A01', '1551', 1, true);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('A01', '1561', 1, true);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('A01', '1571', 1, true);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('A01', '1317', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('A01', '1337', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('A01', '1517', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('A01', '1527', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('A01', '1537', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('A01', '1547', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('A01', '1557', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('A01', '1567', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('A01', '1577', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('A01', '191', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('A01', '192', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('A01', '193', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('A01', '194', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('A01', '199', -1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('A10', '10', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('A11', '101', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('A12', '1101', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('A12', '1111', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('A12', '1121', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('A12', '1131', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('A12', '1141', 1, true);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('A12', '1151', 1, true);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('A12', '1161', 1, true);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('A12', '1171', 1, true);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('A13', '111111', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('A13', '1511', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('A14', '111121', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('A15', '1121', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('A15', '1521', 1, true);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('A16', '1131', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('A16', '1531', 1, true);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('A17', '1141', 1, true);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('A17', '1541', 1, true);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('A19', '1151', 1, true);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('A19', '1551', 1, true);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('A20', '1161', 1, true);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('A20', '1561', 1, true);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('A21', '1171', 1, true);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('A21', '1571', 1, true);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('A2A', '1261', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('A2A', '1271', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('A2A', '1281', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('A2H', '1261', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('A2I', '1271', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('A2J', '1281', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('A3A', '1311', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('A3A', '1331', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('A3B', '1311', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('A3C', '1331', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('A60', '111117', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('A60', '111127', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('A60', '1137', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('A60', '1147', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('A60', '1157', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('A60', '1167', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('A60', '1177', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('A60', '1267', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('A60', '1277', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('A60', '1287', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('A60', '1317', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('A60', '1337', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('A60', '1517', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('A60', '1527', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('A60', '1537', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('A60', '1547', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('A60', '1557', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('A60', '1567', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('A60', '1577', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('A70', '191', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('A70', '192', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('A70', '193', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('A70', '194', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('A70', '1991', -1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('A70', '1992', -1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('A70', '1993', -1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('A71', '192', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('A71', '1991', -1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('A72', '193', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('A72', '1992', -1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('A73', '194', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('A73', '1993', -1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('B01', '20221', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('B01', '20227', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('B01', '2031', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('B01', '2041', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('B01', '2511', 1, true);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('B01', '2037', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('B01', '2047', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('B01', '291', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('B01', '292', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('B01', '293', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('B01', '294', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('B01', '299', -1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('B02', '20221', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('B02', '2031', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('B02', '2041', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('B02', '2511', 1, true);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('B02', '291', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('B02', '292', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('B02', '293', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('B02', '294', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('B02', '299', -1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('B03', '20221', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('B03', '2031', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('B03', '2041', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('B03', '2511', 1, true);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('B2D', '20221', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('B2D', '20231', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('B2N', '2511', 1, true);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('B30', '2031', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('B40', '2041', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('B65', '20227', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('B65', '20237', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('B65', '2037', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('B65', '2047', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('B70', '291', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('B70', '292', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('B70', '293', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('B70', '294', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('B70', '2991', -1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('B70', '2992', -1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('B70', '2993', -1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('B71', '292', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('B71', '2991', -1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('B72', '293', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('B72', '2992', -1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('B73', '294', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('B73', '2993', -1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('C01', '301', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('C01', '302', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('C01', '303', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('C01', '304', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('C01', '309', -1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('C01', '3211', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('C01', '3221', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('C01', '3231', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('C01', '3241', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('C01', '3219', -1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('C01', '3229', -1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('C01', '3239', -1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('C01', '3249', -1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('C01', '3311', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('C01', '3711', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('C01', '3713', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('C01', '3741', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('C01', '3742', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('C01', '378', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('C01', '3791', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('C01', '381', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('C01', '39', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('C01', '33191', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('C01', '33199', -1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('C10', '301', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('C10', '302', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('C10', '303', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('C10', '304', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('C10', '309', -1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('C30', '3211', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('C30', '3221', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('C30', '3231', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('C30', '3241', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('C30', '3219', -1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('C30', '3229', -1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('C30', '3239', -1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('C30', '3249', -1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('C31', '3211', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('C31', '3219', -1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('C32', '3221', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('C32', '3229', -1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('C33', '3231', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('C33', '3239', -1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('C34', '3241', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('C34', '3249', -1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('C40', '3311', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('C40', '33191', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('C40', '33199', -1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('C55', '307', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('C56', '37111', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('C56', '37112', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('C59', '3713', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('C6A', '3741', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('C6A', '3742', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('C6A', '3791', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('C6A', '378', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('C6A', '3811', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('C6A', '3812', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('C6A', '3814', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('C6A', '3815', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('C6A', '39', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('C6B', '39', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('C6C', '3741', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('C6C', '37421', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('C6C', '37429', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('C6D', '3741', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('C6E', '37421', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('C6F', '37429', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('C6G', '3811', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('C6G', '3812', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('C6G', '3814', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('C6G', '3815', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('C6N', '378', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('C6N', '3791', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('C6Q', '378', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('C6R', '3791', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('D01', '41', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('D01', '43', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('D01', '44', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('D01', '45', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('D01', '46', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('D01', '47', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('D01', '49', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('D10', '4101', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('D10', '4102', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('D1A', '4101', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('D1A', '4102', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('D1A', '4121', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('D1A', '4122', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('D1A', '4123', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('D1A', '4124', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('D1A', '4125', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('D1A', '4141', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('D1A', '4142', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('D1A', '4129', -1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('D1A', '4149', -1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('D1E', '4121', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('D1E', '4122', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('D1E', '4123', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('D1E', '4124', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('D1E', '4125', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('D1E', '4129', -1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('D1L', '4141', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('D1L', '4142', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('D1L', '4149', -1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('D1S', '42', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('D1S', '429', -1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('D23', '4311', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('D23', '4319', -1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('D23', '4321', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('D23', '4329', -1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('D24', '4311', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('D24', '4319', -1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('D25', '4321', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('D25', '4329', -1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('D30', '4411', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('D30', '4412', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('D30', '4413', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('D30', '4421', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('D30', '4418', -1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('D30', '4419', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('D30', '4428', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('D30', '4429', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('D31', '4411', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('D31', '4412', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('D31', '4413', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('D31', '4418', -1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('D31', '4419', -1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('D32', '44111', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('D32', '4418', -1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('D32', '4419', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('D33', '44112', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('D33', '4418', -1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('D33', '4419', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('D34', '4412', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('D34', '4418', -1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('D34', '4419', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('D35', '4413', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('D35', '4418', -1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('D35', '4419', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('D36', '4421', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('D36', '4428', -1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('D36', '4429', -1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('D40', '4511', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('D40', '4513', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('D40', '4518', -1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('D40', '4519', -1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('D40', '4521', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('D40', '4528', -1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('D40', '4529', -1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('D40', '4531', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('D40', '4538', -1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('D40', '4539', -1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('D40', '4541', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('D40', '4548', -1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('D40', '4549', -1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('D41', '4511', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('D41', '4513', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('D41', '4518', -1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('D41', '4519', -1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('D42', '45111', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('D42', '4518', -1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('D42', '4519', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('D43', '45112', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('D43', '4518', -1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('D43', '4519', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('D44', '4513', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('D44', '4518', -1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('D44', '4519', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('D45', '4521', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('D45', '4528', -1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('D45', '4529', -1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('D46', '4531', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('D46', '4538', -1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('D46', '4539', -1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('D47', '4541', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('D47', '4548', -1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('D47', '4549', -1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('D50', '461', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('D50', '462', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('D50', '463', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('D50', '464', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('D50', '468', -1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('D50', '469', -1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('D50', '471', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('D50', '472', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('D50', '473', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('D50', '474', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('D50', '478', -1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('D50', '479', -1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('D51', '461', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('D51', '463', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('D51', '464', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('D51', '468', -1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('D51', '469', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('D52', '462', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('D52', '463', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('D52', '464', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('D52', '468', -1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('D52', '469', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('D53', '471', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('D53', '472', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('D53', '473', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('D53', '474', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('D53', '478', -1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('D53', '479', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('D60', '4107', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('D60', '4127', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('D60', '4147', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('D60', '427', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('D60', '467', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('D60', '477', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('D70', '491', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('D70', '492', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('D70', '493', -1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('D71', '491', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('D71', '49961', -1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('D71', '49971', -1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('D72', '492', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('D72', '49962', -1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('D72', '49972', -1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('D73', '493', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('D73', '49963', -1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('E01', '5731', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('E01', '5732', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('E02', '5731', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('E03', '5732', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('E05', '60', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('E05', '61', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('E05', '62', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('E05', '63', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('E05', '64', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('E05', '65', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('E05', '66', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('E05', '67', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('E05', '70', -1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('E05', '71', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('E05', '72', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('E05', '73', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('E05', '74', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('E05', '75', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('E05', '76', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('E05', '77', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('F01', '111111', 1, true);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('F01', '111121', 1, true);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('F01', '1141', 1, true);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('F01', '1151', 1, true);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('F01', '1161', 1, true);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('F01', '1171', 1, true);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('F01', '1511', 1, true);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('F01', '1521', 1, true);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('F01', '1531', 1, true);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('F01', '1541', 1, true);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('F01', '1551', 1, true);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('F01', '1561', 1, true);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('F01', '1571', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('F01', '111116', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('F01', '111126', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('F01', '1136', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('F01', '1146', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('F01', '1156', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('F01', '1166', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('F01', '1176', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('F01', '1516', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('F01', '1611', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('F01', '1621', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('F01', '1651', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('F01', '1616', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('F01', '1626', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('F01', '1656', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('F01', '1751', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('F01', '1781', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('F01', '1756', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('F01', '1786', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('F01', '179', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('F01', '18', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('F1A', '111111', 1, true);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('F1A', '111121', 1, true);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('F1A', '1141', 1, true);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('F1A', '1151', 1, true);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('F1A', '1161', 1, true);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('F1A', '1171', 1, true);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('F1A', '1521', 1, true);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('F1A', '1531', 1, true);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('F1A', '1541', 1, true);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('F1A', '1511', 1, true);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('F1A', '1551', 1, true);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('F1A', '1561', 1, true);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('F1A', '1571', 1, true);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('F2A', '1611', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('F2A', '1621', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('F2A', '1651', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('F2B', '1611', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('F2C', '1621', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('F2D', '1651', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('F3A', '1751', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('F3A', '1781', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('F3E', '1751', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('F3F', '1781', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('F50', '179', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('F55', '18', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('F60', '111116', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('F60', '111126', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('F60', '1136', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('F60', '1156', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('F60', '1166', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('F60', '1176', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('F60', '1516', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('F60', '1526', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('F60', '1536', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('F60', '1546', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('F60', '1556', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('F60', '1566', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('F60', '1576', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('F60', '1756', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('F60', '1786', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('F60', '1616', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('F60', '1626', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('F60', '1656', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('F60', '114', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('G01', '25111', 1, true);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('G01', '25121', 1, true);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('G01', '2521', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('G01', '25311', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('G01', '25321', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('G01', '25331', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('G01', '25391', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('G01', '2545', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('G01', '2551', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('G01', '2711', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('G01', '2721', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('G01', '2722', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('G01', '2725', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('G01', '25116', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('G01', '25126', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('G01', '2526', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('G01', '2546', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('G01', '2556', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('G01', '25316', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('G01', '25326', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('G01', '25336', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('G01', '25396', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('G01', '2716', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('G01', '2726', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('G02', '25111', 1, true);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('G02', '25121', 1, true);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('G02', '2521', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('G02', '25311', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('G02', '25321', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('G02', '25331', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('G02', '25391', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('G02', '254', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('G02', '2545', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('G02', '2551', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('G02', '2711', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('G02', '2721', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('G02', '2722', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('G02', '2725', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('G10', '25111', 1, true);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('G10', '25121', 1, true);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('G15', '2521', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('G2A', '25311', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('G2A', '25321', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('G2A', '25331', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('G2A', '25391', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('G30', '2545', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('G35', '2551', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('G60', '2711', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('G70', '2721', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('G70', '2722', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('G70', '2725', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('G90', '25116', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('G90', '25126', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('G90', '2526', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('G90', '2546', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('G90', '2556', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('G90', '25316', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('G90', '25326', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('G90', '25336', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('G90', '25396', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('G90', '2716', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('G90', '2726', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('H01', '305', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('H01', '332', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('H01', '3712', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('H01', '3741', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('H01', '3743', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('H01', '3792', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('H01', '382', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('H01', '39', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('H10', '305', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('H40', '332', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('H6A', '3741', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('H6A', '3743', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('H6A', '3792', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('H6A', '3822', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('H6A', '3824', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('H6A', '3825', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('H6A', '39', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('H6B', '39', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('H6C', '3741', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('H6C', '37431', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('H6C', '37439', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('H6G', '3822', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('H6G', '3824', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('H6G', '3825', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('H6P', '3792', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('K01', '4126', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('K20', '4126', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('L01', '501', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('L01', '502', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('L01', '51', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('L01', '52', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('L01', '53', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('L01', '54', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('L01', '55', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('L01', '56', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('L01', '57', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('L01', '58', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('L01', '59', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('L10', '5011', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('L10', '5012', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('L20', '5021', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('L20', '5022', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('L20', '5023', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('L20', '5024', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('L20', '5029', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('L21', '5021', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('L22', '5022', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('L23', '5023', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('L24', '5024', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('L25', '5029', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('L27', '503', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('L30', '511', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('L30', '512', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('L30', '519', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('L31', '511', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('L32', '512', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('L33', '519', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('L35', '52', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('L36', '521', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('L37', '522', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('L41', '532', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('L43', '536', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('L45', '54', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('L50', '551', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('L55', '5521', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('L55', '5522', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('L55', '5523', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('L56', '5521', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('L57', '5522', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('L58', '5523', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('L59', '553', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('L60', '5711', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('L60', '5712', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('L61', '5711', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('L62', '5712', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('L65', '56', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('L70', '58', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('L75', '70', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('L75', '71', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('L75', '72', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('L75', '73', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('L75', '74', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('L75', '75', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('L75', '76', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('L75', '77', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('L75', '60', -1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('L75', '61', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('L75', '62', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('L75', '63', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('L75', '64', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('L75', '65', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('L75', '66', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('L75', '67', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('L80', '59', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('L81', '591', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('L82', '592', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('N1A', '901', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('N1H', '902', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('N1J', '903', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('N1K', '904', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('N2A', '911', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('N2H', '912', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('N2J', '913', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('N2M', '914', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('N3A', '9211', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('N3A', '9212', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('N3A', '9219', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('N3B', '9211', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('N3C', '9212', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('N3D', '9219', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('N3E', '9221', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('N3E', '9222', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('N3E', '9229', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('N3H', '9229', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('N90', '99', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('NRF', '9221', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('NRG', '9222', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('P1A', '9311', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('P1B', '9312', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('P1C', '9313', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('P1D', '9314', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('P1E', '9331', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('P1F', '9332', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('P1G', '9321', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('P1H', '9322', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('P1J', '9323', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('P1K', '9324', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('P1L', '9341', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('P1M', '9342', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('P1R', '9351', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('P1S', '9352', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('P1V', '936', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('Q1A', '951', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('Q1B', '952', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('Q1C', '9611', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('Q1C', '9613', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('Q1F', '9612', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('Q1F', '9614', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('Q1K', '9631', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('Q1L', '9651', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('Q1M', '9661', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('QIJ', '9621', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('R08', '6011', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('R08', '6015', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('R08', '6016', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('R08', '6017', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('R08', '6018', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('R08', '6019', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('R1A', '6011', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('R1A', '6015', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('R1B', '60111', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('R1B', '60151', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('R1C', '60112', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('R1D', '60152', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('R1E', '60113', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('R1E', '60153', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('R1F', '60114', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('R1F', '60154', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('R1H', '60115', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('R1H', '60155', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('R1I', '60116', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('R1I', '60156', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('R1K', '60117', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('R1K', '60157', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('R1L', '6016', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('R1N', '60161', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('R1P', '60162', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('R1Q', '60165', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('R2A', '6017', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('R2F', '60175', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('R2G', '60178', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('R2R', '6018', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('R2T', '60189', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('R2Z', '6019', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('R3A', '6025', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('R3A', '6027', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('R3A', '6028', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('R3A', '6029', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('R3C', '6025', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('R3D', '60251', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('R3F', '60252', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('R3G', '60253', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('R3H', '60254', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('R3J', '60255', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('R3N', '6027', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('R3Q', '6028', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('R3T', '6029', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('R4B', '6031', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('R4B', '6038', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('R4B', '6039', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('R4C', '6031', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('R4K', '6038', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('R4N', '6039', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('R5B', '60411', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('R5B', '60412', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('R5C', '60411', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('R5D', '60412', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('R5E', '6046', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('R5E', '6047', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('R5G', '60461', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('R5G', '60463', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('R5G', '60464', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('R5H', '604611', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('R5H', '604631', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('R5H', '604641', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('R5J', '604612', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('R5J', '604632', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('R5J', '604642', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('R5K', '604613', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('R5K', '604633', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('R5K', '604643', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('R5L', '604619', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('R5L', '604639', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('R5L', '604649', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('R5M', '60462', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('R5M', '60463', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('R5M', '60464', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('R5N', '604621', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('R5N', '604631', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('R5N', '60464', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('R5P', '604622', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('R5P', '604632', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('R5P', '604642', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('R5Q', '604623', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('R5Q', '604633', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('R5Q', '604643', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('R5R', '604629', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('R5R', '604639', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('R5R', '604649', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('R5S', '60471', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('R5S', '60472', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('R5S', '60473', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('R5S', '60474', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('R5T', '604721', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('R5T', '604731', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('R5T', '604741', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('R5U', '604712', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('R5U', '604722', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('R5U', '604732', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('R5U', '604742', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('R5V', '604713', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('R5V', '604723', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('R5V', '604733', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('R5V', '604743', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('R5X', '604719', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('R5X', '604729', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('R5X', '604739', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('R5X', '604749', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('R5Y', '60532', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('R6A', '6061', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('R6A', '6069', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('R6B', '6061', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('R6C', '6069', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('R6F', '6071', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('R6F', '6072', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('R6F', '6073', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('R6F', '6075', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('R6K', '60712', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('R6L', '60714', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('R6M', '60722', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('R6P', '60724', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('R6S', '6073', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('R6T', '6075', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('R6V', '6081', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('R6V', '6089', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('R6W', '6081', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('R6X', '6089', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('R7A', '6091', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('R7A', '6098', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('R7A', '6099', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('R7B', '6091', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('R7C', '6098', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('R7D', '6099', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('R8G', '6117', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('R8G', '6118', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('R8G', '6119', -1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('R8J', '6112', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('R8L', '612', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('S02', '641', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('S02', '642', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('S02', '643', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('S03', '641', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('S04', '642', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('S05', '643', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('S1A', '6311', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('S1A', '6312', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('S1A', '6321', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('S1A', '6323', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('S1A', '6324', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('S1A', '6329', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('S1A', '633', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('S1B', '6311', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('S1B', '6312', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('S1C', '6321', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('S1C', '6323', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('S1C', '6324', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('S1C', '6329', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('S1D', '6321', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('S1G', '6323', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('S1H', '6324', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('S1J', '6329', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('S1K', '633', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('S2A', '6211', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('S2A', '6212', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('S2A', '6213', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('S2A', '6214', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('S2A', '6215', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('S2A', '6216', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('S2A', '6217', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('S2A', '6218', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('S2A', '6219', -1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('S2A', '6221', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('S2A', '6222', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('S2A', '6223', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('S2A', '6224', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('S2A', '6225', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('S2A', '6226', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('S2A', '6227', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('S2A', '6228', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('S2A', '6231', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('S2A', '6232', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('S2A', '6229', -1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('S2A', '6233', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('S2B', '6211', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('S2B', '6212', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('S2B', '6213', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('S2B', '6214', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('S2B', '6215', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('S2B', '6216', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('S2B', '6218', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('S2B', '6219', -1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('S2C', '6211', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('S2C', '6217', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('S2D', '6212', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('S2F', '6213', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('S2H', '6214', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('S2J', '6215', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('S2K', '6216', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('S2L', '6218', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('S2L', '6219', -1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('S2M', '6217', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('S3A', '6221', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('S3A', '6222', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('S3A', '6223', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('S3A', '6224', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('S3A', '6225', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('S3A', '6226', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('S3A', '6227', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('S3A', '6228', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('S3A', '6229', -1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('S3A', '6116', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('S3B', '6221', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('S3C', '6222', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('S3E', '6223', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('S3G', '6224', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('S3J', '6225', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('S3L', '6226', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('S3M', '6116', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('S3N', '6227', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('S3P', '6228', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('S3P', '6229', -1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('S4A', '6231', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('S4A', '6232', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('S4A', '6233', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('S4A', '6235', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('S4A', '6238', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('S4A', '6239', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('S4B', '6231', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('S4D', '6232', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('S4I', '6233', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('S4K', '6235', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('S4L', '62351', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('S4M', '62352', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('S4P', '6238', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('S4Q', '62381', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('S4R', '62389', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('S4S', '6239', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('T50', '65', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('T51', '661', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('T51', '662', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('T51', '663', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('T53', '662', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('T54', '6611', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('T55', '6612', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('T56', '6631', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('T57', '6632', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('T58', '6633', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('T6B', '6641', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('T6B', '6642', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('T6B', '6643', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('T6B', '666', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('T6B', '667', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('T6B', '668', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('T6B', '669', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('T6C', '6641', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('T6C', '6642', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('T6C', '6643', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('T6D', '6641', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('T6E', '6642', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('T6F', '6643', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('T6G', '666', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('T6H', '667', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('T6J', '668', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('T6K', '6691', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('T6L', '6692', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('T80', '671', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('T81', '672', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('T82', '69', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('T84', '60', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('T84', '61', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('T84', '62', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('T84', '63', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('T84', '64', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('T84', '65', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('T84', '66', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('T84', '67', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('T84', '69', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('T84', '59', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('V08', '7011', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('V08', '7012', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('V08', '7013', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('V08', '7015', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('V08', '7018', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('V08', '7019', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('V1A', '7011', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('V1A', '7015', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('V1B', '70111', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('V1B', '70151', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('V1C', '70112', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('V1D', '70152', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('V1E', '70113', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('V1E', '70153', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('V1F', '70114', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('V1F', '70154', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('V1H', '70115', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('V1H', '70155', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('V1I', '70116', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('V1I', '70156', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('V1K', '70117', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('V1K', '70157', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('V1L', '7012', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('V1Q', '70126', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('V1R', '70127', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('V1S', '70128', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('V2A', '7013', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('V2C', '70131', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('V2G', '70133', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('V2Q', '7018', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('V2S', '70189', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('V2T', '7019', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('V3A', '7021', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('V3A', '7028', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('V3A', '7029', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('V3B', '7021', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('V3G', '70212', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('V3M', '70213', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('V3N', '70214', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('V3R', '7028', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('V3T', '70289', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('V3X', '7029', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('V4B', '7031', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('V4B', '703', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('V4B', '7038', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('V4B', '7039', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('V4C', '7031', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('V4D', '703', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('V4E', '7038', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('V4F', '7039', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('V5B', '7041', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('V5C', '70410', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('V5D', '70412', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('V5F', '70414', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('V5G', '7046', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('V5G', '7047', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('V5H', '70461', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('V5H', '70463', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('V5H', '70464', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('V5J', '704611', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('V5J', '704631', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('V5K', '704612', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('V5K', '704632', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('V5K', '704642', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('V5L', '704613', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('V5L', '704633', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('V5L', '704643', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('V5M', '704619', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('V5M', '704639', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('V5M', '704649', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('V5N', '70462', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('V5N', '70463', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('V5N', '70464', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('V5P', '704621', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('V5P', '704631', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('V5Q', '704622', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('V5Q', '704632', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('V5Q', '704642', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('V5R', '704623', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('V5R', '704633', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('V5R', '704643', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('V5S', '704629', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('V5S', '704639', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('V5S', '704649', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('V5T', '7047', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('V5V', '704721', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('V5V', '704731', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('V5W', '704722', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('V5W', '704732', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('V5W', '704742', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('V5X', '704723', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('V5X', '704733', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('V5X', '704743', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('V5Y', '704729', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('V5Y', '704739', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('V5Y', '704749', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('V6A', '7061', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('V6A', '7069', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('V6B', '7061', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('V6C', '7069', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('V6F', '7071', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('V6F', '7072', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('V6F', '7073', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('V6F', '7075', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('V6F', '7076', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('V6K', '70711', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('V6L', '70713', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('V6N', '70721', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('V6P', '70723', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('V6Q', '7073', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('V6R', '7075', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('V6S', '7076', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('V6U', '7081', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('V6U', '7089', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('V6V', '7081', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('V6W', '7089', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('V7A', '7091', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('V7A', '7098', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('V7A', '7099', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('V7B', '7091', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('V7C', '7098', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('V7D', '7099', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('V8B', '7111', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('V8C', '7118', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('V8C', '7119', -1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('W4A', '721', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('W4A', '722', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('W4A', '725', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('W4A', '727', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('W4A', '728', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('W4A', '729', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('W4B', '721', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('W4D', '722', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('W4G', '7251', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('W4G', '7252', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('W4H', '7251', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('W4J', '7252', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('W4K', '727', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('W4L', '7281', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('W4L', '7282', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('W4L', '7289', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('W4M', '7281', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('W4N', '7282', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('W4P', '7289', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('W4Q', '729', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('W50', '731', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('W50', '732', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('W51', '731', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('W52', '732', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('W53', '74', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('X50', '75', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('X51', '761', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('X51', '763', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('X54', '761', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('X56', '763', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('X6B', '7641', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('X6B', '7642', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('X6B', '7643', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('X6B', '766', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('X6B', '767', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('X6B', '768', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('X6B', '769', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('X6C', '7641', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('X6C', '7642', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('X6C', '7643', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('X6D', '7641', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('X6E', '7642', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('X6F', '7643', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('X6G', '766', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('X6H', '767', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('X6I', '768', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('X6J', '769', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('X80', '771', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('X81', '772', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('X84', '70', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('X84', '71', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('X84', '72', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('X84', '73', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('X84', '74', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('X84', '75', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('X84', '76', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('X84', '77', 1, false);
INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ('X84', '59', 1, false);

-- =====================================================================
-- MODULE 20_ratios_prudentiels.sql
-- =====================================================================
-- =====================================================================
-- 20_ratios_prudentiels.sql
-- Ratios prudentiels I à IX du « Guide méthodologique d'audit externe des SFD de la zone UEMOA » (octobre 2010,
-- tableau de l'instruction 6 : pages 48 à 55), calculés sur les postes du module 19.
--   I   limitation des risques (≤ 200 %)           VI   opérations autres que épargne et crédit (≤ 5 %)
--   II  couverture des emplois MLT (≥ 100 %)       VII  réserve générale (dotation ≥ 15 % de l'excédent)
--   III prêts aux dirigeants et au personnel (≤ 10 %)  VIII capitalisation (≥ 15 %)
--   IV  risques sur une seule signature (≤ 5 %)    IX   prises de participation (≤ 25 % des fonds propres)
--   V   liquidité (≥ 100 % / 80 % affilié / 60 % sans dépôts)
-- Seuils paramétrables (table parametre, clés ratio_norme_*). Chaque ratio indique les SAISIES MANQUANTES : certaines
-- données ne sortent pas de la comptabilité (durée résiduelle des dépôts, engagements à court terme, opérations
-- hors épargne et crédit, compléments de provisions exigés) et sont saisies dans donnee_reglementaire ; absentes, elles
-- valent 0 et le ratio est signalé comme incomplet.
-- Interprétations à faire valider : voir le tableau des notes dans la fonction (colonne « note »).
-- Dépend de : 14 (portefeuille_a_date), 19.
-- =====================================================================
SET search_path = mf, public;

ALTER TABLE client ADD COLUMN qualite_interne varchar(15) NOT NULL DEFAULT 'aucune'
  CHECK (qualite_interne IN ('aucune','dirigeant','personnel','personne_liee'));

INSERT INTO parametre(agence_id, cle, valeur, description) VALUES
  (NULL, 'ratio_norme_I',   '200', 'plafond du ratio I (limitation des risques), en %'),
  (NULL, 'ratio_norme_II',  '100', 'plancher du ratio II (couverture des emplois à moyen et long terme), en %'),
  (NULL, 'ratio_norme_III', '10',  'plafond du ratio III (prêts aux dirigeants et au personnel), en % des fonds propres'),
  (NULL, 'ratio_norme_IV',  '5',   'plafond du ratio IV (risques sur une seule signature), en % des fonds propres'),
  (NULL, 'ratio_norme_V_non_affilie', '100', 'plancher du ratio V (liquidité), institution non affiliée, en %'),
  (NULL, 'ratio_norme_V_affilie',     '80',  'plancher du ratio V, institution affiliée, en %'),
  (NULL, 'ratio_norme_V_sans_depots', '60',  'plancher du ratio V, institution qui ne collecte pas de dépôts, en %'),
  (NULL, 'ratio_norme_VI',  '5',   'plafond du ratio VI (opérations autres que épargne et crédit), en %'),
  (NULL, 'ratio_norme_VII', '15',  'dotation minimale à la réserve générale, en % de l''excédent'),
  (NULL, 'ratio_norme_VIII','15',  'plancher du ratio VIII (fonds propres sur total actif), en %'),
  (NULL, 'ratio_norme_IX',  '25',  'plafond du ratio IX (participations), en % des fonds propres'),
  (NULL, 'type_institution_liquidite', 'non_affilie', 'non_affilie | affilie | sans_depots : norme applicable au ratio V')
ON CONFLICT DO NOTHING;

-- ---------------------------------------------------------------------
-- Hypothèses de calcul : points d'interprétation du guide, rendus paramétrables et validables par le comptable.
-- Chaque hypothèse a une valeur retenue (table parametre) ; une validation porte sur une valeur donnée et tombe
-- si la valeur change. Les seuils des ratios (clés ratio_norme_*) se modifient par modifier_norme_ratio.
-- ---------------------------------------------------------------------
INSERT INTO parametre(agence_id, cle, valeur, description) VALUES
  (NULL, 'hyp_ratio_I_depots_garantie', 'non',      'ratio I : oui = les dépôts de garantie reçus (G30) sont déduits des risques portés'),
  (NULL, 'hyp_ratios_A2J',              'II_et_V',  'compte A2J (autres dépôts constitués) : II_et_V | II_seulement | V_seulement'),
  (NULL, 'hyp_ratio_IV_signature',      'client',   'ratio IV : client = un client est une signature ; groupe = les clients liés par un lien groupe ou associé sont regroupés'),
  (NULL, 'hyp_normes_a_jour',           'non_verifiees', 'seuils des ratios : non_verifiees | verifiees (contrôlés contre les instructions BCEAO en vigueur)')
ON CONFLICT DO NOTHING;

CREATE TABLE hypothese_calcul (
  code        varchar(40) PRIMARY KEY,
  cle_param   varchar(60) NOT NULL,
  libelle     text NOT NULL,
  explication text NOT NULL,
  valeurs     text[] NOT NULL
);
INSERT INTO hypothese_calcul(code, cle_param, libelle, explication, valeurs) VALUES
  ('depots_garantie_ratio_I', 'hyp_ratio_I_depots_garantie', 'Dépôts de garantie au ratio I',
   'Le guide parle de montants nets des provisions et des dépôts de garantie. « non » : seules les provisions sont déduites ; « oui » : les dépôts de garantie reçus (poste G30) le sont aussi.', ARRAY['non','oui']),
  ('compte_A2J', 'hyp_ratios_A2J', 'Compte A2J aux ratios II et V',
   'Le guide cite A2J (autres dépôts constitués auprès des institutions financières) dans les emplois à moyen et long terme (II) et dans les valeurs disponibles à court terme (V). Choisir où le compter.', ARRAY['II_et_V','II_seulement','V_seulement']),
  ('signature_ratio_IV', 'hyp_ratio_IV_signature', 'Définition de « une seule signature » au ratio IV',
   '« client » : chaque client est une signature. « groupe » : les clients reliés par un lien de type groupe ou associé forment une seule signature (contrôle conjoint ou influence notable).', ARRAY['client','groupe']),
  ('normes_a_jour', 'hyp_normes_a_jour', 'Seuils des ratios',
   'Le guide date de 2010 : les seuils doivent être contrôlés contre les instructions BCEAO en vigueur. Passer à « verifiees » une fois le contrôle fait.', ARRAY['non_verifiees','verifiees']);

CREATE TABLE hypothese_validation (
  id          serial PRIMARY KEY,
  code        varchar(40) NOT NULL REFERENCES hypothese_calcul(code),
  valeur      text NOT NULL,
  validee_par integer REFERENCES utilisateur(id),
  commentaire text,
  cree_le     timestamptz NOT NULL DEFAULT now()
);
CREATE TRIGGER hypothese_validation_ajout_seul BEFORE UPDATE OR DELETE ON hypothese_validation FOR EACH ROW EXECUTE FUNCTION trg_ajout_seul();
CREATE TRIGGER audit_hypothese_validation AFTER INSERT ON hypothese_validation FOR EACH ROW EXECUTE FUNCTION trg_audit();

CREATE VIEW v_hypotheses AS
SELECT h.code, h.libelle, h.explication, h.valeurs, COALESCE(mf.param(h.cle_param), h.valeurs[1]) AS valeur,
       v.validee_par, u.login AS validee_par_login, v.cree_le AS validee_le, v.commentaire,
       (v.id IS NOT NULL) AS validee
  FROM hypothese_calcul h
  LEFT JOIN LATERAL (SELECT * FROM mf.hypothese_validation x WHERE x.code = h.code AND x.valeur = COALESCE(mf.param(h.cle_param), h.valeurs[1])
                      ORDER BY x.id DESC LIMIT 1) v ON true
  LEFT JOIN utilisateur u ON u.id = v.validee_par;

CREATE FUNCTION modifier_hypothese(p_code text, p_valeur text) RETURNS void
LANGUAGE plpgsql AS $$
DECLARE h mf.hypothese_calcul;
BEGIN
  SELECT * INTO h FROM mf.hypothese_calcul WHERE code = p_code;
  IF NOT FOUND THEN RAISE EXCEPTION 'hypothèse % inconnue', p_code; END IF;
  IF NOT p_valeur = ANY (h.valeurs) THEN RAISE EXCEPTION 'valeur % refusée pour % (valeurs possibles : %)', p_valeur, p_code, array_to_string(h.valeurs, ', '); END IF;
  UPDATE mf.parametre SET valeur = p_valeur WHERE cle = h.cle_param AND agence_id IS NULL;
END $$;

CREATE FUNCTION valider_hypothese(p_code text, p_utilisateur integer DEFAULT NULL, p_commentaire text DEFAULT NULL) RETURNS void
LANGUAGE plpgsql AS $$
DECLARE v text;
BEGIN
  SELECT valeur INTO v FROM mf.v_hypotheses WHERE code = p_code;
  IF NOT FOUND THEN RAISE EXCEPTION 'hypothèse % inconnue', p_code; END IF;
  INSERT INTO mf.hypothese_validation(code, valeur, validee_par, commentaire) VALUES (p_code, v, p_utilisateur, p_commentaire);
END $$;

-- Seuils des ratios : modifiables, valeur contrôlée ; chaque modification est tracée par l'audit du paramètre
CREATE FUNCTION modifier_norme_ratio(p_cle text, p_valeur numeric) RETURNS void
LANGUAGE plpgsql AS $$
BEGIN
  IF p_cle !~ '^ratio_norme_' THEN RAISE EXCEPTION 'paramètre % : ce n''est pas un seuil de ratio', p_cle; END IF;
  IF p_valeur <= 0 OR p_valeur > 1000 THEN RAISE EXCEPTION 'seuil % invalide (entre 0 exclu et 1000)', p_valeur; END IF;
  UPDATE mf.parametre SET valeur = p_valeur::text WHERE cle = p_cle AND agence_id IS NULL;
  IF NOT FOUND THEN RAISE EXCEPTION 'seuil % inconnu', p_cle; END IF;
  UPDATE mf.parametre SET valeur = 'non_verifiees' WHERE cle = 'hyp_normes_a_jour' AND agence_id IS NULL;    -- un seuil modifié est à re-contrôler
END $$;

-- Encours de crédit par signature : un client, ou un groupe de clients reliés (liens groupe et associé)
CREATE FUNCTION encours_par_signature(p_agence smallint, p_date date, p_groupe boolean)
RETURNS TABLE (signature integer, encours numeric)
LANGUAGE sql STABLE AS $$
  WITH RECURSIVE aretes AS (
    SELECT client_id AS a, lie_a_id AS b FROM mf.lien_client WHERE p_groupe AND type IN ('groupe','associe')
    UNION SELECT lie_a_id, client_id FROM mf.lien_client WHERE p_groupe AND type IN ('groupe','associe')
  ), cc(client, rep) AS (
    SELECT c.id, c.id FROM mf.client c
    UNION SELECT a.b, cc.rep FROM cc JOIN aretes a ON a.a = cc.client
  ), comp AS (SELECT client, min(rep) AS rep FROM cc GROUP BY client),
  pf AS (SELECT p.client_id, sum(p.capital_restant) AS cap
           FROM mf.agence ag CROSS JOIN LATERAL mf.portefeuille_a_date(ag.id, p_date) p
          WHERE p_agence IS NULL OR ag.id = p_agence GROUP BY p.client_id)
  SELECT comp.rep, sum(pf.cap) FROM pf JOIN comp ON comp.client = pf.client_id GROUP BY comp.rep
$$;

-- Données réglementaires saisies (par agence, datées, conservées : la plus récente avant la date de calcul fait foi)
CREATE TABLE donnee_reglementaire (
  id          serial PRIMARY KEY,
  agence_id   smallint NOT NULL REFERENCES agence(id),
  code        varchar(40) NOT NULL CHECK (code IN
                ('depots_mlt',                      -- part à plus d'un an des dépôts et dettes (ressources stables, ratio II ; exclue du ratio V)
                 'engagements_ct_donnes',           -- engagements de financement et de garantie à court terme donnés (ratio V, numérateur)
                 'engagements_ct_recus',            -- id. reçus (ratio V, dénominateur)
                 'ops_autres_activites',            -- montant consacré aux opérations autres que épargne et crédit (ratio VI)
                 'complement_provisions_autorites', -- compléments de provisions exigés par les autorités (déduit des fonds propres)
                 'participations_autres_sfd')),     -- participations constituant des fonds propres dans d'autres SFD (déduit)
  date_effet  date NOT NULL,
  valeur      numeric(16,0) NOT NULL CHECK (valeur >= 0),
  commentaire text,
  saisi_par   integer REFERENCES utilisateur(id),
  cree_le     timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX donnee_reglementaire_idx ON donnee_reglementaire (code, agence_id, date_effet DESC, id DESC);
CREATE TRIGGER donnee_reglementaire_ajout_seul BEFORE UPDATE OR DELETE ON donnee_reglementaire FOR EACH ROW EXECUTE FUNCTION trg_ajout_seul();
CREATE TRIGGER audit_donnee_reglementaire AFTER INSERT ON donnee_reglementaire FOR EACH ROW EXECUTE FUNCTION trg_audit();

-- Dernière valeur saisie de chaque agence avant la date, additionnée (une agence : la sienne ; NULL : le réseau)
CREATE FUNCTION donnee_reg(p_code text, p_agence smallint, p_date date) RETURNS numeric
LANGUAGE sql STABLE AS $$
  SELECT COALESCE(sum(x.valeur), 0) FROM (
    SELECT DISTINCT ON (agence_id) valeur FROM mf.donnee_reglementaire
     WHERE code = p_code AND date_effet <= p_date AND (p_agence IS NULL OR agence_id = p_agence)
     ORDER BY agence_id, date_effet DESC, id DESC) x
$$;

CREATE FUNCTION donnee_reg_saisie(p_code text, p_agence smallint, p_date date) RETURNS boolean
LANGUAGE sql STABLE AS $$
  SELECT EXISTS (SELECT 1 FROM mf.donnee_reglementaire WHERE code = p_code AND date_effet <= p_date AND (p_agence IS NULL OR agence_id = p_agence))
$$;

CREATE FUNCTION _pm(m jsonb, c text) RETURNS numeric LANGUAGE sql IMMUTABLE AS $$ SELECT COALESCE((m ->> c)::numeric, 0) $$;

-- Fonds propres retraités (ratios III, IV, VIII, IX) à une date
CREATE FUNCTION fonds_propres_retraites(p_agence smallint, p_date date) RETURNS numeric
LANGUAGE plpgsql STABLE AS $$
DECLARE m jsonb;
BEGIN
  SELECT jsonb_object_agg(code, montant) INTO m FROM mf.valeurs_postes(p_agence, p_date, p_date);
  RETURN mf._pm(m,'L10') + mf._pm(m,'L20') + mf._pm(m,'L30') + mf._pm(m,'L41') + mf._pm(m,'L45') + mf._pm(m,'L50') + mf._pm(m,'L55')
       + mf._pm(m,'L59') + mf._pm(m,'L60') + mf._pm(m,'L65') + mf._pm(m,'L70') + mf._pm(m,'L75') + mf._pm(m,'L80')
       - mf._pm(m,'L62') - mf._pm(m,'E05')
       - (mf._pm(m,'D24') + mf._pm(m,'D31') + mf._pm(m,'D41') + mf._pm(m,'D46'))
       - mf.donnee_reg('complement_provisions_autorites', p_agence, p_date) - mf.donnee_reg('participations_autres_sfd', p_agence, p_date);
END $$;

CREATE FUNCTION ratios_prudentiels(p_agence smallint, p_date date)
RETURNS TABLE (ratio varchar, libelle text, numerateur numeric, denominateur numeric, valeur numeric,
               norme_type text, norme numeric, conforme boolean, saisies_manquantes text[], note text)
LANGUAGE plpgsql STABLE AS $$
DECLARE
  m jsonb; fp numeric; fp_prec numeric; total_actif numeric;
  risques numeric; risques_vi numeric; engagements numeric;
  gros numeric; internes numeric; resultat numeric; base_vii numeric;
  depots_mlt numeric; norme_v numeric; type_inst text;
  a numeric; b numeric; manque text[];
  nm text[] := ARRAY['depots_mlt','engagements_ct_donnes','engagements_ct_recus','ops_autres_activites'];
  agence_param smallint := COALESCE(p_agence, (SELECT min(id) FROM mf.agence));
  hyp_gar text; hyp_a2j text; hyp_sig text; a2j_ii numeric; a2j_v numeric;
BEGIN
  SELECT jsonb_object_agg(code, montant) INTO m FROM mf.valeurs_postes(p_agence, p_date, p_date);
  fp := mf.fonds_propres_retraites(p_agence, p_date);
  fp_prec := mf.fonds_propres_retraites(p_agence, make_date(extract(year FROM p_date)::int - 1, 12, 31));
  total_actif := (SELECT e.montant FROM mf.etat_bilan_reglementaire(p_agence, p_date) e WHERE e.code = 'E90');
  engagements := mf._pm(m,'N1A') + mf._pm(m,'N1J') + mf._pm(m,'N3A') + mf._pm(m,'Q1A');
  depots_mlt := mf.donnee_reg('depots_mlt', p_agence, p_date);
  hyp_gar := COALESCE(mf.param('hyp_ratio_I_depots_garantie', agence_param), 'non');
  hyp_a2j := COALESCE(mf.param('hyp_ratios_A2J', agence_param), 'II_et_V');
  hyp_sig := COALESCE(mf.param('hyp_ratio_IV_signature', agence_param), 'client');
  a2j_ii := CASE WHEN hyp_a2j IN ('II_et_V','II_seulement') THEN mf._pm(m,'A2J') ELSE 0 END;
  a2j_v  := CASE WHEN hyp_a2j IN ('II_et_V','V_seulement') THEN mf._pm(m,'A2J') ELSE 0 END;
  type_inst := COALESCE(mf.param('type_institution_liquidite', agence_param), 'non_affilie');

  SELECT COALESCE(sum(pf.cap) FILTER (WHERE c.qualite_interne <> 'aucune'), 0) INTO internes
    FROM (SELECT p.client_id, sum(p.capital_restant) AS cap
            FROM mf.agence ag CROSS JOIN LATERAL mf.portefeuille_a_date(ag.id, p_date) p
           WHERE p_agence IS NULL OR ag.id = p_agence GROUP BY p.client_id) pf
    JOIN mf.client c ON c.id = pf.client_id;
  SELECT COALESCE(max(encours), 0) INTO gros FROM mf.encours_par_signature(p_agence, p_date, hyp_sig = 'groupe');

  -- I : limitation des risques
  risques := mf._pm(m,'A3A') + mf._pm(m,'A70') + mf._pm(m,'B2D') + mf._pm(m,'B30') + mf._pm(m,'B40') + mf._pm(m,'B70') + mf._pm(m,'C10') + mf._pm(m,'D1L') + engagements;
  a := risques - CASE WHEN hyp_gar = 'oui' THEN mf._pm(m,'G30') ELSE 0 END;
  b := mf._pm(m,'F2A') + mf._pm(m,'F3A') + mf._pm(m,'F50') + mf._pm(m,'G2A') + mf._pm(m,'G10') + mf._pm(m,'G15') + mf._pm(m,'G30') + mf._pm(m,'G35')
     + mf._pm(m,'G60') + mf._pm(m,'G70') + mf._pm(m,'L01');
  ratio := 'I'; libelle := 'Limitation des risques auxquels est exposée l''institution'; numerateur := a; denominateur := b;
  valeur := CASE WHEN b > 0 THEN round(a / b * 100, 2) END; norme_type := 'max'; norme := mf.param_num('ratio_norme_I', agence_param);
  saisies_manquantes := '{}'; note := CASE WHEN hyp_gar = 'oui' THEN 'Risques nets des provisions et des dépôts de garantie reçus (G30).' ELSE 'Risques nets des provisions ; dépôts de garantie non déduits (hypothèse retenue).' END;
  conforme := valeur <= norme; RETURN NEXT;

  -- II : couverture des emplois à moyen et long terme
  a := mf._pm(m,'L01') + mf._pm(m,'F3F') + depots_mlt;
  b := mf._pm(m,'A2H') + mf._pm(m,'A2I') + a2j_ii + mf._pm(m,'A3C') + mf._pm(m,'A70') + mf._pm(m,'B30') + mf._pm(m,'B40') + mf._pm(m,'B70')
     + mf._pm(m,'D1E') + mf._pm(m,'D1L') + mf._pm(m,'D10') + mf._pm(m,'D1S') + mf._pm(m,'D23') + mf._pm(m,'D30') + mf._pm(m,'D40');
  ratio := 'II'; libelle := 'Couverture des emplois à moyen et long terme par des ressources stables'; numerateur := a; denominateur := b;
  valeur := CASE WHEN b > 0 THEN round(a / b * 100, 2) END; norme_type := 'min'; norme := mf.param_num('ratio_norme_II', agence_param);
  saisies_manquantes := CASE WHEN mf.donnee_reg_saisie('depots_mlt', p_agence, p_date) THEN '{}' ELSE ARRAY['depots_mlt'] END;
  note := 'Les durées résiduelles ne sont pas suivies : la part à plus d''un an des dépôts et dettes est saisie (depots_mlt). A2J compté : ' || hyp_a2j || ' (hypothèse retenue).';
  conforme := valeur >= norme OR (b = 0); RETURN NEXT;

  -- III : prêts aux dirigeants, au personnel et aux personnes liées
  ratio := 'III'; libelle := 'Limitation des prêts aux dirigeants, au personnel et aux personnes liées'; numerateur := internes; denominateur := fp;
  valeur := CASE WHEN fp > 0 THEN round(internes / fp * 100, 2) END; norme_type := 'max'; norme := mf.param_num('ratio_norme_III', agence_param);
  saisies_manquantes := '{}'; note := 'Capital restant dû des clients marqués dirigeant, personnel ou personne liée (fiche client) ; engagements par signature non inclus.';
  conforme := CASE WHEN fp > 0 THEN valeur <= norme WHEN internes = 0 THEN true ELSE false END; RETURN NEXT;

  -- IV : risques sur une seule signature
  ratio := 'IV'; libelle := 'Limitation des risques pris sur une seule signature'; numerateur := gros; denominateur := fp;
  valeur := CASE WHEN fp > 0 THEN round(gros / fp * 100, 2) END; norme_type := 'max'; norme := mf.param_num('ratio_norme_IV', agence_param);
  saisies_manquantes := '{}'; note := CASE WHEN hyp_sig = 'groupe' THEN 'Plus gros encours d''un client ou d''un groupe de clients liés (liens groupe et associé).' ELSE 'Plus gros encours d''un même client ; les clients d''un même groupe ne sont pas regroupés (hypothèse retenue).' END;
  conforme := CASE WHEN fp > 0 THEN valeur <= norme WHEN gros = 0 THEN true ELSE false END; RETURN NEXT;

  -- V : liquidité
  norme_v := mf.param_num('ratio_norme_V_' || type_inst, agence_param);
  a := mf._pm(m,'A10') + a2j_v + mf._pm(m,'A3B') + mf._pm(m,'B2D') + mf._pm(m,'C10') + mf._pm(m,'C30') + mf._pm(m,'C40') + mf._pm(m,'C56')
     + mf._pm(m,'A60') + mf._pm(m,'B65') + mf._pm(m,'C55') + mf._pm(m,'D60') + mf.donnee_reg('engagements_ct_donnes', p_agence, p_date);
  b := mf._pm(m,'F1A') + mf._pm(m,'F2A') + mf._pm(m,'F2D') + mf._pm(m,'F3E') + mf._pm(m,'F50') + mf._pm(m,'G10') + mf._pm(m,'G15') + mf._pm(m,'G2A')
     + mf._pm(m,'G30') + mf._pm(m,'G35') + mf._pm(m,'G60') + mf._pm(m,'G70') + mf._pm(m,'H10') + mf._pm(m,'H40')
     + mf.donnee_reg('engagements_ct_recus', p_agence, p_date) - depots_mlt;
  ratio := 'V'; libelle := 'Norme de liquidité (coefficient de liquidité)'; numerateur := a; denominateur := GREATEST(b, 0);
  valeur := CASE WHEN b > 0 THEN round(a / b * 100, 2) END; norme_type := 'min'; norme := norme_v;
  SELECT array_agg(c) INTO manque FROM unnest(ARRAY['depots_mlt','engagements_ct_donnes','engagements_ct_recus']) c WHERE NOT mf.donnee_reg_saisie(c, p_agence, p_date);
  saisies_manquantes := COALESCE(manque, '{}'); note := 'Norme applicable : ' || type_inst || ' (paramètre type_institution_liquidite). Valeurs réalisables et disponibles à court terme / passif exigible à court terme.';
  conforme := CASE WHEN b > 0 THEN valeur >= norme ELSE true END; RETURN NEXT;

  -- VI : opérations autres que l'épargne et le crédit
  a := mf.donnee_reg('ops_autres_activites', p_agence, p_date);
  risques_vi := mf._pm(m,'A3A') + mf._pm(m,'A70') + mf._pm(m,'B2D') + mf._pm(m,'B30') + mf._pm(m,'B40') + mf._pm(m,'B70') + mf._pm(m,'D1E') + mf._pm(m,'D1L') + engagements;
  ratio := 'VI'; libelle := 'Limitation des opérations autres que les activités d''épargne et de crédit'; numerateur := a; denominateur := risques_vi;
  valeur := CASE WHEN risques_vi > 0 THEN round(a / risques_vi * 100, 2) END; norme_type := 'max'; norme := mf.param_num('ratio_norme_VI', agence_param);
  saisies_manquantes := CASE WHEN mf.donnee_reg_saisie('ops_autres_activites', p_agence, p_date) THEN '{}' ELSE ARRAY['ops_autres_activites'] END;
  note := 'Le montant consacré aux autres activités est saisi (ops_autres_activites).';
  conforme := CASE WHEN risques_vi > 0 THEN valeur <= norme ELSE a = 0 END; RETURN NEXT;

  -- VII : réserve générale (dotation de 15 % minimum de l'excédent après imputation du report à nouveau déficitaire)
  resultat := mf._pm(m,'L75') - mf._pm(m,'E05') + mf._pm(m,'L80');
  base_vii := GREATEST(resultat + LEAST(mf._pm(m,'L70'), 0), 0);
  ratio := 'VII'; libelle := 'Constitution de la réserve générale'; numerateur := mf._pm(m,'L56'); denominateur := base_vii;
  valeur := CASE WHEN base_vii > 0 THEN round(mf._pm(m,'L56') / base_vii * 100, 2) END; norme_type := 'min'; norme := mf.param_num('ratio_norme_VII', agence_param);
  saisies_manquantes := '{}'; note := 'Indicatif : compare la réserve générale constituée (L56) à l''excédent de la période ; la dotation annuelle n''est pas isolée.';
  conforme := CASE WHEN base_vii > 0 THEN mf._pm(m,'L56') >= base_vii * norme / 100 ELSE true END; RETURN NEXT;

  -- VIII : capitalisation (fonds propres moyens retraités / total actif)
  a := (fp + fp_prec) / 2;
  ratio := 'VIII'; libelle := 'Norme de capitalisation (fonds propres moyens retraités sur total de l''actif)'; numerateur := a; denominateur := total_actif;
  valeur := CASE WHEN total_actif > 0 THEN round(a / total_actif * 100, 2) END; norme_type := 'min'; norme := mf.param_num('ratio_norme_VIII', agence_param);
  saisies_manquantes := '{}'; note := 'Moyenne des fonds propres retraités au 31/12 de l''exercice précédent et à la date de calcul.';
  conforme := CASE WHEN total_actif > 0 THEN valeur >= norme END; RETURN NEXT;

  -- IX : prises de participation
  ratio := 'IX'; libelle := 'Limitation des prises de participation'; numerateur := mf._pm(m,'D1E'); denominateur := fp;
  valeur := CASE WHEN fp > 0 THEN round(mf._pm(m,'D1E') / fp * 100, 2) END; norme_type := 'max'; norme := mf.param_num('ratio_norme_IX', agence_param);
  saisies_manquantes := '{}'; note := 'Titres de participation (D1E) rapportés aux fonds propres retraités.';
  conforme := CASE WHEN fp > 0 THEN valeur <= norme WHEN mf._pm(m,'D1E') = 0 THEN true ELSE false END; RETURN NEXT;
END $$;

-- Historique : instantané des ratios à une date (pour suivre l'évolution et prouver ce qui a été calculé)
CREATE TABLE ratio_historique (
  id           bigserial PRIMARY KEY,
  agence_id    smallint REFERENCES agence(id),            -- NULL = réseau consolidé
  date_calcul  date NOT NULL,
  ratio        varchar(4) NOT NULL,
  numerateur   numeric,
  denominateur numeric,
  valeur       numeric,
  norme_type   varchar(3),
  norme        numeric,
  conforme     boolean,
  saisies_manquantes text[],
  calcule_par  integer REFERENCES utilisateur(id),
  cree_le      timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX ratio_historique_idx ON ratio_historique (agence_id, ratio, date_calcul DESC, id DESC);
CREATE TRIGGER ratio_historique_ajout_seul BEFORE UPDATE OR DELETE ON ratio_historique FOR EACH ROW EXECUTE FUNCTION trg_ajout_seul();

CREATE FUNCTION enregistrer_ratios(p_agence smallint, p_date date, p_utilisateur integer DEFAULT NULL) RETURNS integer
LANGUAGE plpgsql AS $$
DECLARE v_n integer;
BEGIN
  INSERT INTO mf.ratio_historique(agence_id, date_calcul, ratio, numerateur, denominateur, valeur, norme_type, norme, conforme, saisies_manquantes, calcule_par)
  SELECT p_agence, p_date, r.ratio, r.numerateur, r.denominateur, r.valeur, r.norme_type, r.norme, r.conforme, r.saisies_manquantes, p_utilisateur
    FROM mf.ratios_prudentiels(p_agence, p_date) r;
  GET DIAGNOSTICS v_n = ROW_COUNT;
  RETURN v_n;
END $$;

-- =====================================================================
-- MODULE 21_provisions.sql
-- =====================================================================
-- =====================================================================
-- 21_provisions.sql
-- Classification des créances et provisionnement, selon le référentiel comptable des SFD de l'UMOA
-- (comptes 29 « crédits en souffrance et immobilisés » et 299 « provisions »).
--  * l'ANCIENNETÉ de l'impayé est celle de la plus ancienne échéance impayée du crédit ; le déclassement porte sur la
--    totalité de l'encours du crédit (échu ou non) ;
--  * classes : 0 à 3 mois (compte 2921, déclassement et provision facultatifs), 3 à 6 mois (2922), 6 à 12 mois (293),
--    12 à 24 mois (294), plus de 24 mois (irrécouvrable : à passer en charges, provisionné à 100 % en attendant) ;
--  * provision = taux × solde restant dû, où solde restant dû = encours - dépôts constitués en garantie ;
--    taux réglementaires : 40 % jusqu'à 6 mois, 80 % de 6 à 12 mois, 100 % de 12 à 24 mois ;
--  * une règle interne plus stricte peut être paramétrée (prov_interne_*) : la provision retenue est la plus élevée,
--    les deux sont affichées ;
--  * generer_provisions passe la pièce de dotation ou de reprise (écart entre la provision requise et les comptes 299).
-- Un mois vaut 30 jours (paramètres prov_jours_*). La comptabilisation du déclassement lui-même (transfert de l'encours
-- vers 2921 à 294) et le passage en perte (compte 6691) ne sont pas automatisés : la classification les liste.
-- Dépend de : 14 (portefeuille_a_date), 05 (pièces), 08 (garanties).
-- =====================================================================
SET search_path = mf, public;

INSERT INTO parametre(agence_id, cle, valeur, description) VALUES
  (NULL, 'prov_jours_3m',  '90',  'ancienneté de l''impayé (jours) : fin de la tranche 0 à 3 mois'),
  (NULL, 'prov_jours_6m',  '180', 'fin de la tranche 3 à 6 mois'),
  (NULL, 'prov_jours_12m', '360', 'fin de la tranche 6 à 12 mois'),
  (NULL, 'prov_jours_24m', '720', 'fin de la tranche 12 à 24 mois : au-delà, créance irrécouvrable'),
  (NULL, 'prov_taux_6m',   '40',  'taux de provision réglementaire des crédits en souffrance de 3 à 6 mois, en %'),
  (NULL, 'prov_taux_12m',  '80',  'taux réglementaire de 6 à 12 mois, en %'),
  (NULL, 'prov_taux_24m',  '100', 'taux réglementaire de 12 à 24 mois et au-delà, en %'),
  (NULL, 'prov_declasser_0_3m', 'non', 'oui : les crédits impayés depuis 0 à 3 mois sont déclassés (facultatif dans le référentiel)'),
  (NULL, 'prov_provisionner_0_3m', 'non', 'oui : les crédits déclassés de 0 à 3 mois sont provisionnés (facultatif dans le référentiel)'),
  (NULL, 'prov_taux_0_3m', '40',  'taux appliqué de 0 à 3 mois si prov_provisionner_0_3m = oui, en %')
ON CONFLICT DO NOTHING;
-- Règle interne plus stricte (facultative) : créer les paramètres prov_interne_0_3m, prov_interne_3_6m, prov_interne_6_12m,
-- prov_interne_12_24m (taux en %) ; absents, la provision retenue est la provision réglementaire.

-- Classification de chaque crédit à une date
CREATE FUNCTION classification_creances(p_agence smallint, p_date date)
RETURNS TABLE (credit_id integer, numero text, client_id integer, client text, capital_restant numeric, garantie_bloquee numeric,
               jours_retard integer, classe text, declasse boolean, compte_encours text, solde_restant_du numeric,
               taux_reglementaire numeric, provision_reglementaire numeric, taux_interne numeric, provision_interne numeric,
               provision_retenue numeric, compte_provision text, a_passer_en_perte boolean)
LANGUAGE sql STABLE AS $$
  WITH pf AS (
    SELECT ag.id::smallint AS agence_id, p.* FROM mf.agence ag CROSS JOIN LATERAL mf.portefeuille_a_date(ag.id, p_date) p
     WHERE p_agence IS NULL OR ag.id = p_agence
  ), cl AS (
    SELECT pf.*,
           CASE WHEN pf.jours_retard <= 0 THEN 'sain'
                WHEN pf.jours_retard <= mf.param_num('prov_jours_3m', pf.agence_id)  THEN '0_3'
                WHEN pf.jours_retard <= mf.param_num('prov_jours_6m', pf.agence_id)  THEN '3_6'
                WHEN pf.jours_retard <= mf.param_num('prov_jours_12m', pf.agence_id) THEN '6_12'
                WHEN pf.jours_retard <= mf.param_num('prov_jours_24m', pf.agence_id) THEN '12_24'
                ELSE 'irrecouvrable' END AS classe
      FROM pf
  ), v AS (
    SELECT cl.*,
           (cl.classe <> 'sain' AND (cl.classe <> '0_3' OR mf.param('prov_declasser_0_3m', cl.agence_id) = 'oui')) AS declasse,
           GREATEST(cl.capital_restant - cl.garantie_bloquee, 0) AS srd
      FROM cl
  ), t AS (
    SELECT v.*,
           CASE v.classe WHEN '0_3' THEN CASE WHEN v.declasse AND mf.param('prov_provisionner_0_3m', v.agence_id) = 'oui'
                                              THEN mf.param_num('prov_taux_0_3m', v.agence_id) ELSE 0 END
                         WHEN '3_6' THEN mf.param_num('prov_taux_6m', v.agence_id)
                         WHEN '6_12' THEN mf.param_num('prov_taux_12m', v.agence_id)
                         WHEN '12_24' THEN mf.param_num('prov_taux_24m', v.agence_id)
                         WHEN 'irrecouvrable' THEN mf.param_num('prov_taux_24m', v.agence_id)
                         ELSE 0 END AS taux_reg,
           CASE v.classe WHEN '0_3' THEN mf.param_num('prov_interne_0_3m', v.agence_id)
                         WHEN '3_6' THEN mf.param_num('prov_interne_3_6m', v.agence_id)
                         WHEN '6_12' THEN mf.param_num('prov_interne_6_12m', v.agence_id)
                         WHEN '12_24' THEN mf.param_num('prov_interne_12_24m', v.agence_id)
                         WHEN 'irrecouvrable' THEN mf.param_num('prov_interne_12_24m', v.agence_id)
                         ELSE NULL END AS taux_int
      FROM v
  ), m AS (
    SELECT t.*, round(t.srd * t.taux_reg / 100) AS p_reg, round(t.srd * t.taux_int / 100) AS p_int FROM t
  )
  SELECT m.credit_id, m.numero, m.client_id, m.client, m.capital_restant, m.garantie_bloquee, m.jours_retard, m.classe, m.declasse,
         CASE WHEN NOT m.declasse THEN NULL WHEN m.classe = '0_3' THEN '2921' WHEN m.classe = '3_6' THEN '2922'
              WHEN m.classe = '6_12' THEN '293' ELSE '294' END,
         m.srd, m.taux_reg, m.p_reg, m.taux_int, m.p_int,
         GREATEST(m.p_reg, COALESCE(m.p_int, 0)),
         CASE WHEN GREATEST(m.p_reg, COALESCE(m.p_int, 0)) = 0 THEN NULL
              WHEN m.classe = '0_3' THEN '29911' WHEN m.classe = '3_6' THEN '29912' WHEN m.classe = '6_12' THEN '2992' ELSE '2993' END,
         (m.classe = 'irrecouvrable')
    FROM m ORDER BY m.jours_retard DESC, m.numero
$$;

-- Provisions constituées dans les comptes 299 (solde créditeur) à une date
CREATE FUNCTION provisions_constituees(p_agence smallint, p_date date)
RETURNS TABLE (compte text, montant numeric)
LANGUAGE sql STABLE AS $$
  SELECT c.code::text, COALESCE((SELECT sum(e.credit - e.debit) FROM mf.ecriture e JOIN mf.piece_comptable p ON p.id = e.piece_id
                                  WHERE e.compte_code = c.code AND p.date_piece <= p_date AND (p_agence IS NULL OR p.agence_id = p_agence)), 0)
    FROM mf.compte_comptable c WHERE c.code IN ('29911','29912','2992','2993') ORDER BY c.code
$$;

-- Rapport par classe : encours, solde restant dû, provision réglementaire / interne / retenue
CREATE FUNCTION rapport_provisions(p_agence smallint, p_date date)
RETURNS TABLE (classe text, libelle text, nb_credits bigint, encours numeric, solde_restant_du numeric,
               provision_reglementaire numeric, provision_interne numeric, provision_retenue numeric)
LANGUAGE sql STABLE AS $$
  WITH c AS (SELECT * FROM mf.classification_creances(p_agence, p_date)),
  ref(classe, libelle, ordre) AS (VALUES ('sain','Crédits sains',1), ('0_3','Impayés de 0 à 3 mois',2), ('3_6','Impayés de 3 à 6 mois',3),
        ('6_12','Impayés de 6 à 12 mois',4), ('12_24','Impayés de 12 à 24 mois',5), ('irrecouvrable','Plus de 24 mois : irrécouvrables',6))
  SELECT r.classe, r.libelle, count(c.credit_id), COALESCE(sum(c.capital_restant), 0), COALESCE(sum(c.solde_restant_du), 0),
         COALESCE(sum(c.provision_reglementaire), 0), COALESCE(sum(c.provision_interne), 0), COALESCE(sum(c.provision_retenue), 0)
    FROM ref r LEFT JOIN c ON c.classe = r.classe GROUP BY r.classe, r.libelle, r.ordre ORDER BY r.ordre
$$;

-- Écart par compte entre la provision requise et la provision constituée (dotation si positif, reprise si négatif)
CREATE FUNCTION ecarts_provisions(p_agence smallint, p_date date)
RETURNS TABLE (compte text, dotation text, reprise text, requis numeric, constitue numeric, delta numeric)
LANGUAGE sql STABLE AS $$
  SELECT k.compte, k.dotation, k.reprise, COALESCE(req.montant, 0), COALESCE(cst.montant, 0), COALESCE(req.montant, 0) - COALESCE(cst.montant, 0)
    FROM (VALUES ('29911','66411','76411'), ('29912','66412','76412'), ('2992','6642','7642'), ('2993','6643','7643')) AS k(compte, dotation, reprise)
    LEFT JOIN (SELECT compte_provision, sum(provision_retenue) AS montant FROM mf.classification_creances(p_agence, p_date)
                WHERE compte_provision IS NOT NULL GROUP BY compte_provision) req ON req.compte_provision = k.compte
    LEFT JOIN mf.provisions_constituees(p_agence, p_date) cst ON cst.compte = k.compte
   ORDER BY k.compte
$$;

-- Pièce de dotation ou de reprise : amène chaque compte 299 au niveau de la provision retenue (une pièce par agence et par jour)
CREATE FUNCTION generer_provisions(p_agence smallint, p_date date, p_utilisateur integer DEFAULT NULL) RETURNS bigint
LANGUAGE plpgsql AS $$
DECLARE v_piece bigint; v_ex integer; v_j integer; v_ligne integer := 0; r record;
BEGIN
  IF p_agence IS NULL THEN RAISE EXCEPTION 'agence obligatoire : les provisions se passent agence par agence'; END IF;
  IF EXISTS (SELECT 1 FROM mf.piece_comptable WHERE agence_id = p_agence AND date_piece = p_date AND evenement = 'provision_creances') THEN
    RAISE EXCEPTION 'provisions déjà passées pour l''agence % au % : contrepasser la pièce pour la refaire', p_agence, p_date;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM mf.ecarts_provisions(p_agence, p_date) WHERE delta <> 0) THEN RETURN NULL; END IF;
  SELECT id INTO v_ex FROM mf.exercice_comptable WHERE p_date BETWEEN date_debut AND date_fin AND statut = 'ouvert';
  IF v_ex IS NULL THEN RAISE EXCEPTION 'aucun exercice comptable ouvert pour le %', p_date; END IF;
  SELECT id INTO v_j FROM mf.journal WHERE code = 'OD';
  INSERT INTO mf.piece_comptable(agence_id, journal_id, exercice_id, date_piece, numero, libelle, evenement, origine, utilisateur_id)
  VALUES (p_agence, v_j, v_ex, p_date, mf.prochain_numero('piece', p_agence, p_date, 'PC'), 'Provisions sur crédits en souffrance au ' || p_date,
          'provision_creances', 'manuelle', p_utilisateur)
  RETURNING id INTO v_piece;
  FOR r IN SELECT * FROM mf.ecarts_provisions(p_agence, p_date) WHERE delta <> 0 LOOP
    IF r.delta > 0 THEN
      v_ligne := v_ligne + 1; INSERT INTO mf.ecriture(piece_id, ligne, compte_code, debit, credit) VALUES (v_piece, v_ligne, r.dotation, r.delta, 0);
      v_ligne := v_ligne + 1; INSERT INTO mf.ecriture(piece_id, ligne, compte_code, debit, credit) VALUES (v_piece, v_ligne, r.compte, 0, r.delta);
    ELSE
      v_ligne := v_ligne + 1; INSERT INTO mf.ecriture(piece_id, ligne, compte_code, debit, credit) VALUES (v_piece, v_ligne, r.compte, -r.delta, 0);
      v_ligne := v_ligne + 1; INSERT INTO mf.ecriture(piece_id, ligne, compte_code, debit, credit) VALUES (v_piece, v_ligne, r.reprise, 0, -r.delta);
    END IF;
  END LOOP;
  RETURN v_piece;
END $$;

-- ---------------------------------------------------------------------
-- Mode de passage des écritures : « manuel » (bouton de l'écran) ou « automatique » (tâche quotidienne du planificateur,
-- python -m app.cli planifier). Dans les deux cas la même fonction generer_provisions passe la pièce, une fois par jour.
-- ---------------------------------------------------------------------
INSERT INTO parametre(agence_id, cle, valeur, description) VALUES
  (NULL, 'prov_mode', 'manuel', 'passage des écritures de provisions : manuel (bouton) | automatique (tâche quotidienne du planificateur)')
ON CONFLICT DO NOTHING;

-- Tâche du planificateur : ne fait rien en mode manuel ; en mode automatique passe la pièce du jour si un écart existe.
-- Retourne 1 si une pièce a été passée, 0 sinon. Une erreur (ex. aucun exercice ouvert) remonte et est journalisée.
CREATE FUNCTION generer_provisions_auto(p_agence smallint, p_date date) RETURNS integer
LANGUAGE plpgsql AS $$
BEGIN
  IF COALESCE(mf.param('prov_mode', p_agence), 'manuel') <> 'automatique' THEN RETURN 0; END IF;
  IF EXISTS (SELECT 1 FROM mf.piece_comptable WHERE agence_id = p_agence AND date_piece = p_date AND evenement = 'provision_creances') THEN RETURN 0; END IF;
  RETURN CASE WHEN mf.generer_provisions(p_agence, p_date, NULL) IS NULL THEN 0 ELSE 1 END;
END $$;

ALTER TABLE execution_tache DROP CONSTRAINT execution_tache_tache_check;
ALTER TABLE execution_tache ADD CONSTRAINT execution_tache_tache_check CHECK (tache IN
  ('cloturer_cycles_echus','prelever_echeances_compte','maj_statuts_credit','saisir_garantie_echeances','purger_dates','generer_provisions_auto'));

-- =====================================================================
-- MODULE 22_rapprochement.sql
-- =====================================================================
-- =====================================================================
-- 22_rapprochement.sql
-- Rapprochement entre l'inventaire des fiches (crédits, épargne) et la comptabilité, à une date d'arrêté.
--   1. encours des crédits sains            fiches : capital restant des crédits non déclassés   / comptes 20221, 20231, 2031, 2041
--   2. encours des crédits en souffrance    fiches : capital restant des crédits déclassés        / comptes 291 à 294
--   3. provisions sur crédits en souffrance fiches : provision retenue (module 21)                / comptes 299
--   4. épargne classique                    fiches : mouvements d'épargne jusqu'à la date         / comptes 2511, 2521, 2531
-- Hors périmètre (signalé) : intérêts courus non échus (créances rattachées), tontine, comptes d'attente.
-- Chaque écart supérieur à la tolérance (paramètre rapprochement_tolerance, 0 par défaut) est signalé. Le comptable valide
-- le rapprochement : « conforme » si aucun écart, « écart justifié » avec une justification obligatoire sinon.
-- La régularisation comptable d'un écart (pièce, compte d'attente) reste une saisie du comptable.
-- Dépend de : 05 (pièces), 14, 21 (classification).
-- =====================================================================
SET search_path = mf, public;

INSERT INTO parametre(agence_id, cle, valeur, description) VALUES
  (NULL, 'rapprochement_tolerance', '0', 'écart toléré (en F) entre fiches et comptabilité avant d''être signalé')
ON CONFLICT DO NOTHING;

-- Solde débiteur (débit - crédit) cumulé jusqu'à la date des comptes dont le code commence par l'un des préfixes
CREATE FUNCTION solde_comptes(p_agence smallint, p_date date, p_prefixes text[]) RETURNS numeric
LANGUAGE sql STABLE AS $$
  SELECT COALESCE(sum(e.debit - e.credit), 0)
    FROM mf.ecriture e JOIN mf.piece_comptable p ON p.id = e.piece_id
   WHERE p.date_piece <= p_date AND (p_agence IS NULL OR p.agence_id = p_agence)
     AND EXISTS (SELECT 1 FROM unnest(p_prefixes) x WHERE e.compte_code LIKE x || '%')
$$;

CREATE FUNCTION rapprochement(p_agence smallint, p_date date)
RETURNS TABLE (code text, libelle text, inventaire numeric, comptabilite numeric, ecart numeric, conforme boolean, note text)
LANGUAGE plpgsql STABLE AS $$
DECLARE
  v_tol numeric := COALESCE(mf.param_num('rapprochement_tolerance', p_agence), 0);
  v_sain numeric; v_souf numeric; v_prov numeric; v_epargne numeric;
BEGIN
  SELECT COALESCE(sum(c.capital_restant) FILTER (WHERE NOT c.declasse), 0), COALESCE(sum(c.capital_restant) FILTER (WHERE c.declasse), 0),
         COALESCE(sum(c.provision_retenue), 0)
    INTO v_sain, v_souf, v_prov FROM mf.classification_creances(p_agence, p_date) c;
  SELECT COALESCE(sum(m.montant * mf.sens_mouvement(m.type)), 0) INTO v_epargne
    FROM mf.mouvement_epargne m JOIN mf.compte_epargne ce ON ce.id = m.compte_id
   WHERE m.date_operation <= p_date AND (p_agence IS NULL OR ce.agence_id = p_agence);

  code := 'credits_sains'; libelle := 'Encours des crédits sains'; inventaire := v_sain;
  comptabilite := mf.solde_comptes(p_agence, p_date, ARRAY['20221','20231','2031','2041']);
  ecart := inventaire - comptabilite; conforme := abs(ecart) <= v_tol; note := 'Crédits non déclassés (capital restant) contre les comptes de crédits sains.'; RETURN NEXT;

  code := 'credits_souffrance'; libelle := 'Encours des crédits en souffrance'; inventaire := v_souf;
  comptabilite := mf.solde_comptes(p_agence, p_date, ARRAY['291','292','293','294']);
  ecart := inventaire - comptabilite; conforme := abs(ecart) <= v_tol; note := 'Crédits déclassés contre les comptes 291 à 294 (le déclassement comptable n''est pas automatisé).'; RETURN NEXT;

  code := 'provisions'; libelle := 'Provisions sur crédits en souffrance'; inventaire := v_prov;
  comptabilite := -mf.solde_comptes(p_agence, p_date, ARRAY['299']);
  ecart := inventaire - comptabilite; conforme := abs(ecart) <= v_tol; note := 'Provision retenue (module Provisions) contre les comptes 299.'; RETURN NEXT;

  code := 'epargne'; libelle := 'Épargne classique'; inventaire := v_epargne;
  comptabilite := -mf.solde_comptes(p_agence, p_date, ARRAY['2511','2521','2531']);
  ecart := inventaire - comptabilite; conforme := abs(ecart) <= v_tol; note := 'Soldes des comptes d''épargne contre les comptes 2511, 2521 et 2531. La tontine n''est pas rapprochée.'; RETURN NEXT;
END $$;

-- Validation du rapprochement par le comptable (conservée, non modifiable)
CREATE TABLE rapprochement_validation (
  id            serial PRIMARY KEY,
  agence_id     smallint NOT NULL REFERENCES agence(id),
  date_arrete   date NOT NULL,
  statut        varchar(15) NOT NULL CHECK (statut IN ('conforme','ecart_justifie')),
  ecart_total   numeric NOT NULL,                      -- somme des écarts en valeur absolue au moment de la validation
  justification text,
  valide_par    integer REFERENCES utilisateur(id),
  cree_le       timestamptz NOT NULL DEFAULT now(),
  CHECK (statut = 'conforme' OR (justification IS NOT NULL AND btrim(justification) <> ''))
);
CREATE INDEX rapprochement_validation_idx ON rapprochement_validation (agence_id, date_arrete DESC, id DESC);
CREATE TRIGGER rapprochement_validation_ajout_seul BEFORE UPDATE OR DELETE ON rapprochement_validation FOR EACH ROW EXECUTE FUNCTION trg_ajout_seul();
CREATE TRIGGER audit_rapprochement_validation AFTER INSERT ON rapprochement_validation FOR EACH ROW EXECUTE FUNCTION trg_audit();

CREATE FUNCTION valider_rapprochement(p_agence smallint, p_date date, p_utilisateur integer DEFAULT NULL, p_justification text DEFAULT NULL) RETURNS integer
LANGUAGE plpgsql AS $$
DECLARE v_ecart numeric; v_statut text; v_id integer;
BEGIN
  IF p_agence IS NULL THEN RAISE EXCEPTION 'agence obligatoire : le rapprochement se valide agence par agence'; END IF;
  IF p_date > current_date THEN RAISE EXCEPTION 'date d''arrêté dans le futur'; END IF;
  SELECT COALESCE(sum(abs(r.ecart)), 0), CASE WHEN bool_and(r.conforme) THEN 'conforme' ELSE 'ecart_justifie' END
    INTO v_ecart, v_statut FROM mf.rapprochement(p_agence, p_date) r;
  IF v_statut = 'ecart_justifie' AND (p_justification IS NULL OR btrim(p_justification) = '') THEN
    RAISE EXCEPTION 'écart de % entre fiches et comptabilité : une justification est obligatoire pour valider', v_ecart;
  END IF;
  INSERT INTO mf.rapprochement_validation(agence_id, date_arrete, statut, ecart_total, justification, valide_par)
  VALUES (p_agence, p_date, v_statut, v_ecart, NULLIF(btrim(p_justification), ''), p_utilisateur) RETURNING id INTO v_id;
  RETURN v_id;
END $$;

-- Agences dont le rapprochement n'est pas validé à la date (avant consolidation) : dernière validation du jour, avec son statut
CREATE FUNCTION etat_rapprochement_agences(p_date date)
RETURNS TABLE (agence_id smallint, agence text, validee boolean, statut text, ecart_total numeric, valide_le timestamptz)
LANGUAGE sql STABLE AS $$
  SELECT a.id, a.code::text, (v.id IS NOT NULL), v.statut::text, v.ecart_total, v.cree_le
    FROM mf.agence a
    LEFT JOIN LATERAL (SELECT * FROM mf.rapprochement_validation x WHERE x.agence_id = a.id AND x.date_arrete = p_date ORDER BY x.id DESC LIMIT 1) v ON true
   WHERE a.actif ORDER BY a.code
$$;

-- =====================================================================
-- MODULE 23_validation_collecte.sql
-- =====================================================================
-- =====================================================================
-- 23_validation_collecte.sql
-- Saisie de collecte au guichet : agent responsable d'une zone, correction des lignes et validation globale de la journée.
--   1. zone.agent_id : l'agent commercial qui collecte dans la zone (choisir l'un propose l'autre à la saisie).
--   2. modifier_ligne_collecte / supprimer_ligne_collecte : correction d'une ligne tant que la journée n'est pas validée.
--      Refusée si la journée est validée, si l'agent a déjà versé sa tournée, si le cycle n'est plus en cours,
--      ou si un remboursement de crédit a déjà été déclenché sur ce cycle (garantie tontine).
--   3. validation_collecte : validation globale d'une journée par agence ; elle verrouille les lignes de collecte du jour
--      (saisie, modification, suppression). rouvrir_journee_collecte la lève (traçable).
-- Les lignes de virement (origine 'virement') ne sont pas concernées.
-- Dépend de : 00, 01, 02, 03.
-- =====================================================================
SET search_path = mf, public;

ALTER TABLE zone ADD COLUMN agent_id integer REFERENCES agent(id);

CREATE TABLE validation_collecte (
  agence_id     smallint NOT NULL REFERENCES agence(id),
  date_collecte date NOT NULL,
  valide_par    integer REFERENCES utilisateur(id),
  valide_le     timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (agence_id, date_collecte)
);

CREATE TABLE validation_collecte_journal (
  id            bigserial PRIMARY KEY,
  agence_id     smallint NOT NULL REFERENCES agence(id),
  date_collecte date NOT NULL,
  action        varchar(10) NOT NULL CHECK (action IN ('validee','rouverte')),
  utilisateur_id integer REFERENCES utilisateur(id),
  motif         text,
  cree_le       timestamptz NOT NULL DEFAULT now()
);

-- Verrou : aucune ligne de collecte ne bouge sur une journée validée
CREATE FUNCTION trg_ligne_jour_valide() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE l mf.ligne_collecte; v_agence smallint;
BEGIN
  l := CASE WHEN TG_OP = 'INSERT' THEN NEW ELSE OLD END;
  IF l.origine <> 'collecte' THEN RETURN l; END IF;
  SELECT agence_id INTO v_agence FROM mf.cycle WHERE id = l.cycle_id;
  IF EXISTS (SELECT 1 FROM mf.validation_collecte WHERE agence_id = v_agence AND date_collecte = l.date_collecte) THEN
    RAISE EXCEPTION 'la journée de collecte du % est validée : modification refusée', l.date_collecte;
  END IF;
  IF TG_OP = 'UPDATE' AND NEW.date_collecte <> OLD.date_collecte AND EXISTS
     (SELECT 1 FROM mf.validation_collecte WHERE agence_id = v_agence AND date_collecte = NEW.date_collecte) THEN
    RAISE EXCEPTION 'la journée de collecte du % est validée : modification refusée', NEW.date_collecte;
  END IF;
  RETURN CASE WHEN TG_OP = 'DELETE' THEN OLD ELSE NEW END;
END $$;
CREATE TRIGGER ligne_jour_valide BEFORE INSERT OR UPDATE OR DELETE ON ligne_collecte
  FOR EACH ROW EXECUTE FUNCTION trg_ligne_jour_valide();

-- Contrôles communs à la modification et à la suppression d'une ligne de collecte
CREATE FUNCTION verifier_ligne_modifiable(p_ligne bigint) RETURNS mf.ligne_collecte
LANGUAGE plpgsql AS $$
DECLARE l mf.ligne_collecte; c mf.cycle;
BEGIN
  SELECT * INTO l FROM mf.ligne_collecte WHERE id = p_ligne FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'ligne de collecte % inconnue', p_ligne; END IF;
  IF l.origine <> 'collecte' THEN RAISE EXCEPTION 'une ligne issue d''un virement ne se corrige pas ici'; END IF;
  SELECT * INTO c FROM mf.cycle WHERE id = l.cycle_id FOR UPDATE;
  IF c.statut <> 'en_cours' THEN RAISE EXCEPTION 'cycle % clos : correction refusée', c.numero; END IF;
  IF EXISTS (SELECT 1 FROM mf.validation_collecte WHERE agence_id = c.agence_id AND date_collecte = l.date_collecte) THEN
    RAISE EXCEPTION 'la journée de collecte du % est validée : correction refusée', l.date_collecte;
  END IF;
  IF EXISTS (SELECT 1 FROM mf.versement_agent WHERE agent_id = l.agent_id AND date_tournee = l.date_collecte) THEN
    RAISE EXCEPTION 'la tournée du % est déjà versée par cet agent : correction refusée', l.date_collecte;
  END IF;
  IF EXISTS (SELECT 1 FROM mf.retrait WHERE cycle_id = l.cycle_id AND nature = 'remboursement' AND statut <> 'annule') THEN
    RAISE EXCEPTION 'un remboursement de crédit a déjà été déclenché sur le cycle % : correction refusée', c.numero;
  END IF;
  RETURN l;
END $$;

CREATE FUNCTION modifier_ligne_collecte(p_ligne bigint, p_montant numeric) RETURNS void
LANGUAGE plpgsql AS $$
BEGIN
  IF p_montant IS NULL OR p_montant <= 0 THEN RAISE EXCEPTION 'le montant doit être positif'; END IF;
  PERFORM mf.verifier_ligne_modifiable(p_ligne);
  UPDATE mf.ligne_collecte SET montant_collecte = p_montant WHERE id = p_ligne;
END $$;

CREATE FUNCTION supprimer_ligne_collecte(p_ligne bigint) RETURNS void
LANGUAGE plpgsql AS $$
BEGIN
  PERFORM mf.verifier_ligne_modifiable(p_ligne);
  DELETE FROM mf.ligne_collecte WHERE id = p_ligne;
END $$;

CREATE FUNCTION valider_journee_collecte(p_agence smallint, p_date date, p_utilisateur integer DEFAULT NULL) RETURNS void
LANGUAGE plpgsql AS $$
BEGIN
  IF p_date > current_date THEN RAISE EXCEPTION 'impossible de valider une journée à venir'; END IF;
  IF EXISTS (SELECT 1 FROM mf.validation_collecte WHERE agence_id = p_agence AND date_collecte = p_date) THEN
    RAISE EXCEPTION 'la journée du % est déjà validée', p_date;
  END IF;
  INSERT INTO mf.validation_collecte(agence_id, date_collecte, valide_par) VALUES (p_agence, p_date, p_utilisateur);
  INSERT INTO mf.validation_collecte_journal(agence_id, date_collecte, action, utilisateur_id) VALUES (p_agence, p_date, 'validee', p_utilisateur);
END $$;

CREATE FUNCTION rouvrir_journee_collecte(p_agence smallint, p_date date, p_motif text, p_utilisateur integer DEFAULT NULL) RETURNS void
LANGUAGE plpgsql AS $$
BEGIN
  IF p_motif IS NULL OR btrim(p_motif) = '' THEN RAISE EXCEPTION 'un motif est obligatoire pour rouvrir une journée'; END IF;
  DELETE FROM mf.validation_collecte WHERE agence_id = p_agence AND date_collecte = p_date;
  IF NOT FOUND THEN RAISE EXCEPTION 'la journée du % n''est pas validée', p_date; END IF;
  INSERT INTO mf.validation_collecte_journal(agence_id, date_collecte, action, utilisateur_id, motif)
  VALUES (p_agence, p_date, 'rouverte', p_utilisateur, p_motif);
END $$;

-- =====================================================================
-- MODULE 24_adhesion_parts.sql
-- =====================================================================
-- =====================================================================
-- 24_adhesion_parts.sql
-- Adhésion des membres et souscription de parts sociales (épargne classique réservée aux membres).
--   adhesion            : une seule adhésion par client ; droit d'adhésion payé à l'entrée.
--   souscription_part   : parts souscrites et libérées en une fois (nombre x valeur nominale à la date).
--   membre_en_regle     : adhésion active et au moins `parts_minimum` parts.
-- Paramètres : part_valeur_nominale, parts_minimum, droit_adhesion, adhesion_obligatoire ('oui' : l'ouverture d'un compte
-- d'épargne classique exige un membre en règle, contrôle fait par l'API ; 'non' : pas de contrôle).
-- Non couvert : remboursement des parts à la sortie, dividendes, libération échelonnée, écritures de capital (13/10).
-- Dépend de : 00, 01, 05 (numérotation).
-- =====================================================================
SET search_path = mf, public;

INSERT INTO parametre(agence_id, cle, valeur, description) VALUES
  (NULL, 'part_valeur_nominale', '5000', 'valeur nominale d''une part sociale (F)'),
  (NULL, 'parts_minimum', '1', 'nombre minimal de parts pour être membre en règle'),
  (NULL, 'droit_adhesion', '2000', 'droit d''adhésion payé à l''entrée (F)'),
  (NULL, 'adhesion_obligatoire', 'oui', 'oui : un compte d''épargne classique exige une adhésion et le minimum de parts')
ON CONFLICT DO NOTHING;

CREATE TABLE adhesion (
  id             serial PRIMARY KEY,
  agence_id      smallint NOT NULL REFERENCES agence(id),
  client_id      integer NOT NULL UNIQUE REFERENCES client(id),
  numero         varchar(25) NOT NULL,
  date_adhesion  date NOT NULL,
  droit_adhesion numeric(12,0) NOT NULL CHECK (droit_adhesion >= 0),
  statut         varchar(10) NOT NULL DEFAULT 'active' CHECK (statut IN ('active','radiee')),
  utilisateur_id integer REFERENCES utilisateur(id),
  cree_le        timestamptz NOT NULL DEFAULT now(),
  UNIQUE (agence_id, numero)
);
CREATE TRIGGER adhesion_numero BEFORE INSERT ON adhesion FOR EACH ROW EXECUTE FUNCTION trg_numerotation('AD');

CREATE TABLE souscription_part (
  id               serial PRIMARY KEY,
  adhesion_id      integer NOT NULL REFERENCES adhesion(id),
  nb_parts         integer NOT NULL CHECK (nb_parts > 0),
  valeur_nominale  numeric(12,0) NOT NULL CHECK (valeur_nominale > 0),
  montant          numeric(14,0) NOT NULL CHECK (montant > 0),
  date_souscription date NOT NULL,
  utilisateur_id   integer REFERENCES utilisateur(id),
  cree_le          timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX souscription_part_adhesion ON souscription_part (adhesion_id);

CREATE VIEW v_membre AS
SELECT a.id AS adhesion_id, a.agence_id, a.client_id, a.numero, a.date_adhesion, a.statut,
       COALESCE(sum(s.nb_parts), 0)::integer AS nb_parts, COALESCE(sum(s.montant), 0)::numeric(14,0) AS capital_souscrit
  FROM adhesion a LEFT JOIN souscription_part s ON s.adhesion_id = a.id
 GROUP BY a.id;

CREATE FUNCTION membre_en_regle(p_client integer) RETURNS boolean
LANGUAGE sql STABLE AS $$
  SELECT EXISTS (SELECT 1 FROM mf.v_membre m JOIN mf.client c ON c.id = m.client_id
                  WHERE m.client_id = p_client AND m.statut = 'active'
                    AND m.nb_parts >= COALESCE(mf.param_num('parts_minimum', c.agence_id), 1))
$$;

CREATE FUNCTION adherer(p_client integer, p_date date DEFAULT current_date, p_utilisateur integer DEFAULT NULL) RETURNS integer
LANGUAGE plpgsql AS $$
DECLARE c mf.client; v_id integer;
BEGIN
  SELECT * INTO c FROM mf.client WHERE id = p_client FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'client % inconnu', p_client; END IF;
  IF p_date > current_date THEN RAISE EXCEPTION 'la date d''adhésion ne peut pas être dans le futur'; END IF;
  IF EXISTS (SELECT 1 FROM mf.adhesion WHERE client_id = p_client) THEN
    RAISE EXCEPTION 'le client % a déjà une adhésion', c.numero;
  END IF;
  INSERT INTO mf.adhesion(agence_id, client_id, date_adhesion, droit_adhesion, utilisateur_id)
  VALUES (c.agence_id, p_client, p_date, COALESCE(mf.param_num('droit_adhesion', c.agence_id), 0), p_utilisateur)
  RETURNING id INTO v_id;
  RETURN v_id;
END $$;

CREATE FUNCTION souscrire_parts(p_client integer, p_nb integer, p_date date DEFAULT current_date, p_utilisateur integer DEFAULT NULL) RETURNS integer
LANGUAGE plpgsql AS $$
DECLARE a mf.adhesion; v_val numeric; v_id integer;
BEGIN
  SELECT * INTO a FROM mf.adhesion WHERE client_id = p_client FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'le client % n''a pas d''adhésion : adhérer d''abord', p_client; END IF;
  IF a.statut <> 'active' THEN RAISE EXCEPTION 'adhésion % radiée', a.numero; END IF;
  IF p_nb IS NULL OR p_nb <= 0 THEN RAISE EXCEPTION 'le nombre de parts doit être positif'; END IF;
  IF p_date > current_date THEN RAISE EXCEPTION 'la date de souscription ne peut pas être dans le futur'; END IF;
  v_val := mf.param_num('part_valeur_nominale', a.agence_id);
  IF v_val IS NULL OR v_val <= 0 THEN RAISE EXCEPTION 'valeur nominale de la part non paramétrée'; END IF;
  INSERT INTO mf.souscription_part(adhesion_id, nb_parts, valeur_nominale, montant, date_souscription, utilisateur_id)
  VALUES (a.id, p_nb, v_val, p_nb * v_val, p_date, p_utilisateur) RETURNING id INTO v_id;
  RETURN v_id;
END $$;

-- =====================================================================
-- MODULE 25_liaison_tontine_epargne.sql
-- =====================================================================
-- =====================================================================
-- 25_liaison_tontine_epargne.sql
-- Mise en relation d'un cycle de tontine avec le compte d'épargne classique du même client : le client a deux comptes
-- (souscription de tontine, compte classique) et peut alimenter l'un par l'autre. La liaison désigne, pour un cycle,
-- le compte classique qu'il alimente (virement cycle -> épargne) et dont il reçoit les versements (épargne -> cycle).
-- Les virements eux-mêmes restent ceux du module 07 (circuit de retrait et d'écarts pour cycle -> épargne).
-- Un cycle a au plus une liaison ; elle est modifiable tant que le cycle est en cours.
-- Dépend de : 01, 07.
-- =====================================================================
SET search_path = mf, public;

CREATE TABLE liaison_tontine_epargne (
  id             serial PRIMARY KEY,
  agence_id      smallint NOT NULL REFERENCES agence(id),
  client_id      integer NOT NULL REFERENCES client(id),
  cycle_id       integer NOT NULL UNIQUE REFERENCES cycle(id),
  compte_id      integer NOT NULL REFERENCES compte_epargne(id),
  utilisateur_id integer REFERENCES utilisateur(id),
  cree_le        timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX liaison_compte ON liaison_tontine_epargne (compte_id);

-- Crée ou remplace la liaison d'un cycle. Retourne l'id de la liaison.
CREATE FUNCTION lier_cycle_compte(p_cycle integer, p_compte integer, p_utilisateur integer DEFAULT NULL) RETURNS integer
LANGUAGE plpgsql AS $$
DECLARE c mf.cycle; ce mf.compte_epargne; p mf.produit_epargne; v_id integer;
BEGIN
  SELECT * INTO c FROM mf.cycle WHERE id = p_cycle FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'cycle % inconnu', p_cycle; END IF;
  SELECT * INTO ce FROM mf.compte_epargne WHERE id = p_compte;
  IF NOT FOUND THEN RAISE EXCEPTION 'compte % inconnu', p_compte; END IF;
  IF ce.client_id <> c.client_id THEN RAISE EXCEPTION 'le compte % n''appartient pas au client du cycle %', ce.numero, c.numero; END IF;
  SELECT * INTO p FROM mf.produit_epargne WHERE id = ce.produit_id;
  IF p.categorie <> 'classique' THEN RAISE EXCEPTION 'le compte % n''est pas un compte d''épargne classique', ce.numero; END IF;
  IF ce.statut <> 'actif' THEN RAISE EXCEPTION 'compte % non actif', ce.numero; END IF;
  IF c.statut <> 'en_cours' THEN RAISE EXCEPTION 'cycle % non en cours', c.numero; END IF;
  INSERT INTO mf.liaison_tontine_epargne(agence_id, client_id, cycle_id, compte_id, utilisateur_id)
  VALUES (c.agence_id, c.client_id, p_cycle, p_compte, p_utilisateur)
  ON CONFLICT (cycle_id) DO UPDATE SET compte_id = EXCLUDED.compte_id, utilisateur_id = EXCLUDED.utilisateur_id, cree_le = now()
  RETURNING id INTO v_id;
  RETURN v_id;
END $$;

CREATE FUNCTION delier_cycle_compte(p_cycle integer) RETURNS void
LANGUAGE plpgsql AS $$
BEGIN
  DELETE FROM mf.liaison_tontine_epargne WHERE cycle_id = p_cycle;
  IF NOT FOUND THEN RAISE EXCEPTION 'aucune liaison sur le cycle %', p_cycle; END IF;
END $$;

-- =====================================================================
-- MODULE 26_epargne_journee_sortie.sql
-- =====================================================================
-- =====================================================================
-- 26_epargne_journee_sortie.sql
-- Compléments de l'épargne classique et de l'adhésion.
--   1. Annulation d'un dépôt ou d'un retrait du jour par contre-passation (jamais de suppression : la comptabilisation
--      automatique et la piste d'audit restent cohérentes). Un dépôt ne s'annule que si le solde disponible le permet.
--   2. Validation globale de la journée d'épargne par agence : plus de dépôt, retrait ni annulation ce jour-là.
--      rouvrir_journee_epargne la lève (motif obligatoire, tracée).
--   3. Sortie d'un membre : radier_adhesion rembourse les parts (capital libéré) et radie l'adhésion, à condition qu'aucun
--      compte d'épargne ne soit actif avec un solde, qu'aucun cycle de tontine ne soit en cours et qu'aucun crédit ne soit non soldé.
-- Dépend de : 01, 02 (mouvements), 03 (crédit), 24 (adhésion).
-- =====================================================================
SET search_path = mf, public;

CREATE TABLE annulation_mouvement (
  mouvement_id   bigint PRIMARY KEY REFERENCES mouvement_epargne(id),
  contre_id      bigint NOT NULL UNIQUE REFERENCES mouvement_epargne(id),
  utilisateur_id integer REFERENCES utilisateur(id),
  cree_le        timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE validation_epargne (
  agence_id      smallint NOT NULL REFERENCES agence(id),
  date_operation date NOT NULL,
  valide_par     integer REFERENCES utilisateur(id),
  valide_le      timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (agence_id, date_operation)
);

CREATE TABLE validation_epargne_journal (
  id             bigserial PRIMARY KEY,
  agence_id      smallint NOT NULL REFERENCES agence(id),
  date_operation date NOT NULL,
  action         varchar(10) NOT NULL CHECK (action IN ('validee','rouverte')),
  utilisateur_id integer REFERENCES utilisateur(id),
  motif          text,
  cree_le        timestamptz NOT NULL DEFAULT now()
);

-- Verrou : pas de dépôt ni de retrait sur une journée validée
CREATE FUNCTION trg_epargne_jour_valide() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE v_agence smallint;
BEGIN
  IF NEW.type NOT IN ('depot', 'retrait') THEN RETURN NEW; END IF;
  SELECT agence_id INTO v_agence FROM mf.compte_epargne WHERE id = NEW.compte_id;
  IF EXISTS (SELECT 1 FROM mf.validation_epargne WHERE agence_id = v_agence AND date_operation = NEW.date_operation) THEN
    RAISE EXCEPTION 'la journée d''épargne du % est validée : opération refusée', NEW.date_operation;
  END IF;
  RETURN NEW;
END $$;
-- nom précédant « mouvement_controle » dans l'ordre alphabétique des déclencheurs : le verrou passe en premier
CREATE TRIGGER mouvement_a_jour_valide BEFORE INSERT ON mouvement_epargne
  FOR EACH ROW EXECUTE FUNCTION trg_epargne_jour_valide();

CREATE FUNCTION valider_journee_epargne(p_agence smallint, p_date date, p_utilisateur integer DEFAULT NULL) RETURNS void
LANGUAGE plpgsql AS $$
BEGIN
  IF p_date > current_date THEN RAISE EXCEPTION 'impossible de valider une journée à venir'; END IF;
  IF EXISTS (SELECT 1 FROM mf.validation_epargne WHERE agence_id = p_agence AND date_operation = p_date) THEN
    RAISE EXCEPTION 'la journée d''épargne du % est déjà validée', p_date;
  END IF;
  INSERT INTO mf.validation_epargne(agence_id, date_operation, valide_par) VALUES (p_agence, p_date, p_utilisateur);
  INSERT INTO mf.validation_epargne_journal(agence_id, date_operation, action, utilisateur_id) VALUES (p_agence, p_date, 'validee', p_utilisateur);
END $$;

CREATE FUNCTION rouvrir_journee_epargne(p_agence smallint, p_date date, p_motif text, p_utilisateur integer DEFAULT NULL) RETURNS void
LANGUAGE plpgsql AS $$
BEGIN
  IF p_motif IS NULL OR btrim(p_motif) = '' THEN RAISE EXCEPTION 'un motif est obligatoire pour rouvrir une journée'; END IF;
  DELETE FROM mf.validation_epargne WHERE agence_id = p_agence AND date_operation = p_date;
  IF NOT FOUND THEN RAISE EXCEPTION 'la journée d''épargne du % n''est pas validée', p_date; END IF;
  INSERT INTO mf.validation_epargne_journal(agence_id, date_operation, action, utilisateur_id, motif) VALUES (p_agence, p_date, 'rouverte', p_utilisateur, p_motif);
END $$;

-- Contre-passation d'un dépôt ou d'un retrait (même date que l'opération). Retourne l'id du mouvement inverse.
CREATE FUNCTION annuler_mouvement_epargne(p_mouvement bigint, p_utilisateur integer DEFAULT NULL) RETURNS bigint
LANGUAGE plpgsql AS $$
DECLARE m mf.mouvement_epargne; v_contre bigint;
BEGIN
  SELECT * INTO m FROM mf.mouvement_epargne WHERE id = p_mouvement;
  IF NOT FOUND THEN RAISE EXCEPTION 'mouvement % inconnu', p_mouvement; END IF;
  IF m.type NOT IN ('depot', 'retrait') THEN RAISE EXCEPTION 'seuls un dépôt ou un retrait s''annulent ici'; END IF;
  IF m.reference LIKE 'annulation:%' THEN RAISE EXCEPTION 'une annulation ne s''annule pas'; END IF;
  IF EXISTS (SELECT 1 FROM mf.annulation_mouvement WHERE mouvement_id = p_mouvement) THEN
    RAISE EXCEPTION 'le mouvement % est déjà annulé', p_mouvement;
  END IF;
  INSERT INTO mf.mouvement_epargne(compte_id, type, montant, date_operation, libelle, reference)
  VALUES (m.compte_id, CASE m.type WHEN 'depot' THEN 'retrait' ELSE 'depot' END, m.montant, m.date_operation,
          'Annulation du ' || m.type || ' n° ' || m.id, 'annulation:' || m.id)
  RETURNING id INTO v_contre;
  INSERT INTO mf.annulation_mouvement(mouvement_id, contre_id, utilisateur_id) VALUES (p_mouvement, v_contre, p_utilisateur);
  RETURN v_contre;
END $$;

-- Sortie d'un membre : remboursement des parts et radiation
CREATE TABLE remboursement_part (
  id              serial PRIMARY KEY,
  adhesion_id     integer NOT NULL UNIQUE REFERENCES adhesion(id),
  nb_parts        integer NOT NULL CHECK (nb_parts >= 0),
  montant         numeric(14,0) NOT NULL CHECK (montant >= 0),
  date_operation  date NOT NULL,
  utilisateur_id  integer REFERENCES utilisateur(id),
  cree_le         timestamptz NOT NULL DEFAULT now()
);

CREATE FUNCTION radier_adhesion(p_client integer, p_date date DEFAULT current_date, p_utilisateur integer DEFAULT NULL) RETURNS numeric
LANGUAGE plpgsql AS $$
DECLARE a mf.adhesion; v_parts integer; v_montant numeric;
BEGIN
  SELECT * INTO a FROM mf.adhesion WHERE client_id = p_client FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'le client % n''a pas d''adhésion', p_client; END IF;
  IF a.statut <> 'active' THEN RAISE EXCEPTION 'adhésion % déjà radiée', a.numero; END IF;
  IF p_date > current_date THEN RAISE EXCEPTION 'la date de sortie ne peut pas être dans le futur'; END IF;
  IF EXISTS (SELECT 1 FROM mf.compte_epargne ce JOIN mf.v_solde_compte_epargne v ON v.compte_id = ce.id
              WHERE ce.client_id = p_client AND ce.statut <> 'clos' AND v.solde > 0) THEN
    RAISE EXCEPTION 'sortie refusée : un compte d''épargne du client a encore un solde';
  END IF;
  IF EXISTS (SELECT 1 FROM mf.cycle WHERE client_id = p_client AND statut = 'en_cours') THEN
    RAISE EXCEPTION 'sortie refusée : une souscription de tontine est en cours';
  END IF;
  IF EXISTS (SELECT 1 FROM mf.credit WHERE client_id = p_client AND statut <> 'solde') THEN
    RAISE EXCEPTION 'sortie refusée : un crédit n''est pas soldé';
  END IF;
  SELECT COALESCE(sum(nb_parts), 0), COALESCE(sum(montant), 0) INTO v_parts, v_montant FROM mf.souscription_part WHERE adhesion_id = a.id;
  INSERT INTO mf.remboursement_part(adhesion_id, nb_parts, montant, date_operation, utilisateur_id) VALUES (a.id, v_parts, v_montant, p_date, p_utilisateur);
  UPDATE mf.adhesion SET statut = 'radiee' WHERE id = a.id;
  RETURN v_montant;
END $$;
