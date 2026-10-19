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
