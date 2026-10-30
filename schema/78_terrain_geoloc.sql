-- =====================================================================
-- 78_terrain_geoloc.sql
-- Visites terrain et recouvrement : positions GPS des lieux de travail (emprunteur, caution) et des lieux visités.
--   * localisation : une position GPS rattachée à une personne (lieu de travail) ou à une visite ;
--   * visite_terrain : une sortie de l'agent (visite de suivi ou recouvrement) sur un crédit, avec son lieu ;
--   * les coordonnées sont validées (latitude -90..90, longitude -180..180) ; la précision est en mètres.
-- Dépend de : 03 (credit), 17 (garant_credit), 37 (dossier_recouvrement), 10 (trg_audit), 11 (utilisateur).
-- =====================================================================
SET search_path = mf, public;

CREATE TABLE localisation (
  id            bigserial PRIMARY KEY,
  cle           varchar(64),                      -- identifiant donné par le téléphone (saisie hors ligne), pour ne pas rejouer deux fois
  agence_id     smallint NOT NULL REFERENCES agence(id),
  client_id     integer NOT NULL REFERENCES client(id),
  role          varchar(20) NOT NULL CHECK (role IN ('lieu_travail','caution','visite')),
  libelle       text,
  latitude      numeric(9,6) NOT NULL CHECK (latitude BETWEEN -90 AND 90),
  longitude     numeric(9,6) NOT NULL CHECK (longitude BETWEEN -180 AND 180),
  precision_m   numeric(8,1) CHECK (precision_m IS NULL OR precision_m >= 0),
  releve_par    integer REFERENCES utilisateur(id),
  releve_le     timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX localisation_client_idx ON localisation (client_id, role);

CREATE TABLE visite_terrain (
  id             bigserial PRIMARY KEY,
  cle            varchar(64),                     -- identifiant donné par le téléphone (saisie hors ligne)
  agence_id      smallint NOT NULL REFERENCES agence(id),
  date_visite    date NOT NULL DEFAULT current_date,
  type           varchar(15) NOT NULL CHECK (type IN ('visite','recouvrement')),
  agent_id       integer NOT NULL REFERENCES utilisateur(id),
  client_id      integer NOT NULL REFERENCES client(id),
  credit_id      integer REFERENCES credit(id),
  localisation_id bigint REFERENCES localisation(id),
  resultat       text,
  cree_le        timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX visite_terrain_credit_idx ON visite_terrain (credit_id, date_visite);
CREATE INDEX visite_terrain_date_idx ON visite_terrain (agence_id, date_visite);

CREATE UNIQUE INDEX localisation_cle_idx ON localisation (cle) WHERE cle IS NOT NULL;
CREATE UNIQUE INDEX visite_terrain_cle_idx ON visite_terrain (cle) WHERE cle IS NOT NULL;

CREATE TRIGGER audit_localisation AFTER INSERT ON localisation FOR EACH ROW EXECUTE FUNCTION trg_audit();
CREATE TRIGGER audit_visite_terrain AFTER INSERT ON visite_terrain FOR EACH ROW EXECUTE FUNCTION trg_audit();

-- Enregistre la position d'un lieu de travail (emprunteur ou caution) ou d'une visite.
CREATE FUNCTION enregistrer_localisation(p_client integer, p_role text, p_lat numeric, p_lon numeric,
                                         p_libelle text DEFAULT NULL, p_precision numeric DEFAULT NULL,
                                         p_utilisateur integer DEFAULT NULL, p_cle text DEFAULT NULL) RETURNS bigint
LANGUAGE plpgsql AS $$
DECLARE c mf.client; v_id bigint;
BEGIN
  IF p_cle IS NOT NULL THEN                       -- déjà reçue (rejeu d'une synchronisation) : même identifiant
    SELECT id INTO v_id FROM mf.localisation WHERE cle = p_cle;
    IF FOUND THEN RETURN v_id; END IF;
  END IF;
  SELECT * INTO c FROM mf.client WHERE id = p_client;
  IF NOT FOUND THEN RAISE EXCEPTION 'client % inconnu', p_client; END IF;
  INSERT INTO mf.localisation(cle, agence_id, client_id, role, libelle, latitude, longitude, precision_m, releve_par)
  VALUES (p_cle, c.agence_id, p_client, p_role, p_libelle, p_lat, p_lon, p_precision, p_utilisateur)
  RETURNING id INTO v_id;
  RETURN v_id;
END $$;

-- Enregistre une visite de terrain sur un crédit : le client et l'agence sont ceux du crédit.
CREATE FUNCTION enregistrer_visite_terrain(p_credit integer, p_type text, p_utilisateur integer,
                                           p_localisation bigint DEFAULT NULL, p_resultat text DEFAULT NULL,
                                           p_date date DEFAULT current_date, p_cle text DEFAULT NULL) RETURNS bigint
LANGUAGE plpgsql AS $$
DECLARE k mf.credit; v_id bigint;
BEGIN
  IF p_cle IS NOT NULL THEN                       -- déjà reçue (rejeu d'une synchronisation) : même identifiant
    SELECT id INTO v_id FROM mf.visite_terrain WHERE cle = p_cle;
    IF FOUND THEN RETURN v_id; END IF;
  END IF;
  SELECT * INTO k FROM mf.credit WHERE id = p_credit;
  IF NOT FOUND THEN RAISE EXCEPTION 'crédit % inconnu', p_credit; END IF;
  IF p_type NOT IN ('visite', 'recouvrement') THEN RAISE EXCEPTION 'type de visite inconnu : %', p_type; END IF;
  IF p_localisation IS NOT NULL THEN
    PERFORM 1 FROM mf.localisation WHERE id = p_localisation AND client_id = k.client_id;
    IF NOT FOUND THEN RAISE EXCEPTION 'position % n''appartient pas au client du crédit', p_localisation; END IF;
  END IF;
  INSERT INTO mf.visite_terrain(cle, agence_id, date_visite, type, agent_id, client_id, credit_id, localisation_id, resultat)
  VALUES (p_cle, k.agence_id, p_date, p_type, p_utilisateur, k.client_id, p_credit, p_localisation, p_resultat)
  RETURNING id INTO v_id;
  RETURN v_id;
END $$;
