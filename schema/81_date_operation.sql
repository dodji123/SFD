SET search_path = mf, public;

-- =====================================================================
-- 81 : date d'opération, journée comptable unique de l'institution.
--  * à l'ouverture du logiciel, une date d'opération doit être ouverte avant toute opération ;
--  * les opérations se font sur cette date ; la clôture vaut pour tout le monde ;
--  * une date d'opération ne peut pas être future (postérieure à la date du jour) ;
--  * une date qui existe ne peut pas être recréée : les dates ouvertes sont strictement croissantes.
-- =====================================================================
CREATE TABLE date_operation (
  date_operation  date PRIMARY KEY,
  statut          varchar(10) NOT NULL DEFAULT 'ouverte' CHECK (statut IN ('ouverte','cloturee')),
  ouverte_par     integer REFERENCES utilisateur(id),
  ouverte_le      timestamptz NOT NULL DEFAULT now(),
  cloturee_par    integer REFERENCES utilisateur(id),
  cloturee_le     timestamptz,
  CHECK ((statut = 'cloturee') = (cloturee_le IS NOT NULL))
);
-- une seule date ouverte à la fois
CREATE UNIQUE INDEX date_operation_une_ouverte ON date_operation ((statut)) WHERE statut = 'ouverte';

CREATE FUNCTION ouvrir_date_operation(p_date date, p_utilisateur integer DEFAULT NULL) RETURNS void
LANGUAGE plpgsql AS $$
BEGIN
  IF p_date IS NULL THEN RAISE EXCEPTION 'une date d''opération est obligatoire'; END IF;
  IF p_date > current_date THEN RAISE EXCEPTION 'une date d''opération ne peut pas être future (%)', p_date; END IF;
  IF EXISTS (SELECT 1 FROM date_operation WHERE statut = 'ouverte') THEN
    RAISE EXCEPTION 'une date d''opération est déjà ouverte : la clôturer d''abord';
  END IF;
  IF EXISTS (SELECT 1 FROM date_operation WHERE date_operation >= p_date) THEN
    RAISE EXCEPTION 'la date d''opération % existe déjà ou est dépassée : elle ne peut pas être recréée', p_date;
  END IF;
  INSERT INTO date_operation(date_operation, ouverte_par) VALUES (p_date, p_utilisateur);
END $$;

CREATE FUNCTION cloturer_date_operation(p_utilisateur integer DEFAULT NULL) RETURNS void
LANGUAGE plpgsql AS $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM date_operation WHERE statut = 'ouverte') THEN
    RAISE EXCEPTION 'aucune date d''opération n''est ouverte';
  END IF;
  UPDATE date_operation SET statut = 'cloturee', cloturee_par = p_utilisateur, cloturee_le = now()
   WHERE statut = 'ouverte';
END $$;

-- Date sur laquelle toute opération doit se faire. Lève une erreur si aucune date n'est ouverte.
CREATE FUNCTION date_operation_courante() RETURNS date
LANGUAGE plpgsql STABLE AS $$
DECLARE v_date date;
BEGIN
  SELECT date_operation INTO v_date FROM date_operation WHERE statut = 'ouverte';
  IF v_date IS NULL THEN RAISE EXCEPTION 'aucune date d''opération ouverte : ouvrir la journée avant toute opération'; END IF;
  RETURN v_date;
END $$;
