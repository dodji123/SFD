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
