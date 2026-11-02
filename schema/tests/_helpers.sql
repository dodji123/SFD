-- Aides de test : chaque assertion échoue bruyamment (ON_ERROR_STOP) en cas d'écart.
CREATE SCHEMA IF NOT EXISTS t;

CREATE OR REPLACE FUNCTION t.eq(p_label text, p_actual text, p_expected text) RETURNS void
LANGUAGE plpgsql AS $$
BEGIN
  IF p_actual IS DISTINCT FROM p_expected THEN
    RAISE EXCEPTION 'ECHEC % : obtenu [%], attendu [%]', p_label, p_actual, p_expected;
  END IF;
  RAISE NOTICE 'OK    % = %', p_label, p_actual;
END $$;

-- Le SQL fourni DOIT lever une exception, sinon le test échoue.
CREATE OR REPLACE FUNCTION t.refuse(p_label text, p_sql text) RETURNS void
LANGUAGE plpgsql AS $$
DECLARE v_refuse boolean := false; v_msg text;
BEGIN
  BEGIN
    EXECUTE p_sql;
  EXCEPTION WHEN OTHERS THEN
    v_refuse := true; v_msg := SQLERRM;
  END;
  IF NOT v_refuse THEN
    RAISE EXCEPTION 'ECHEC % : devait être refusé', p_label;
  END IF;
  RAISE NOTICE 'OK    % refusé (%)', p_label, left(v_msg, 70);
END $$;

-- Date d'opération de test : ferme la journée ouverte si elle est différente, puis ouvre p_date.
-- Les dates ne se rouvrent pas : un jeu de test doit saisir ses lignes dans l'ordre chronologique.
CREATE OR REPLACE FUNCTION t.ouvrir(p_date date) RETURNS void
LANGUAGE plpgsql AS $$
BEGIN
  IF EXISTS (SELECT 1 FROM mf.date_operation WHERE statut = 'ouverte' AND date_operation IS DISTINCT FROM p_date) THEN
    PERFORM mf.cloturer_date_operation();
  END IF;
  IF NOT EXISTS (SELECT 1 FROM mf.date_operation WHERE statut = 'ouverte' AND date_operation = p_date) THEN
    PERFORM mf.ouvrir_date_operation(p_date);
  END IF;
END $$;
