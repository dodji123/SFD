SET search_path = mf, public;

-- =====================================================================
-- 66 : un client ne peut avoir qu'un cycle en cours pour un produit donné.
-- Contrôlé à la création d'un cycle. Les cycles déjà présents ne sont pas modifiés.
-- =====================================================================
CREATE FUNCTION trg_cycle_un_en_cours() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  IF NEW.statut = 'en_cours' AND EXISTS (
       SELECT 1 FROM mf.cycle c
        WHERE c.client_id = NEW.client_id AND c.produit_id = NEW.produit_id AND c.statut = 'en_cours') THEN
    RAISE EXCEPTION 'ce client a déjà un cycle en cours pour ce produit : clôturer le cycle existant d''abord';
  END IF;
  RETURN NEW;
END $$;

CREATE TRIGGER cycle_un_en_cours BEFORE INSERT ON cycle
  FOR EACH ROW EXECUTE FUNCTION trg_cycle_un_en_cours();
