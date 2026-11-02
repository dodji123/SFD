SET search_path = mf, public;

-- =====================================================================
-- 82 : une ligne de collecte se saisit sur la date d'opération ouverte (module 81), et nulle part ailleurs.
-- =====================================================================
CREATE FUNCTION controler_date_collecte() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  IF NEW.date_collecte IS DISTINCT FROM date_operation_courante() THEN
    RAISE EXCEPTION 'une collecte se saisit sur la date d''opération ouverte (%), pas le %',
      date_operation_courante(), NEW.date_collecte;
  END IF;
  RETURN NEW;
END $$;

CREATE TRIGGER trg_controle_date_collecte BEFORE INSERT OR UPDATE OF date_collecte ON ligne_collecte
  FOR EACH ROW EXECUTE FUNCTION controler_date_collecte();
