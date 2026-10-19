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
