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
