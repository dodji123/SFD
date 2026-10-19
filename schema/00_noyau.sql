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
