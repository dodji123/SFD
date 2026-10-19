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
