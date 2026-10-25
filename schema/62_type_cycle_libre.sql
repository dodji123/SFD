SET search_path = mf, public;

-- =====================================================================
-- 62 : le type de cycle se choisit à chaque cycle, pour tout produit.
-- Le type défini sur le produit n'est plus une contrainte : c'est seulement une suggestion.
-- =====================================================================
CREATE OR REPLACE FUNCTION trg_cycle_avant() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE p mf.produit_epargne; c mf.client;
BEGIN
  SELECT * INTO p FROM mf.produit_epargne WHERE id = NEW.produit_id;
  IF p.categorie <> 'collecte' THEN
    RAISE EXCEPTION 'le produit % n''est pas un produit de collecte', p.code;
  END IF;
  SELECT * INTO c FROM mf.client WHERE id = NEW.client_id;
  IF c.agence_id <> NEW.agence_id THEN
    RAISE EXCEPTION 'le client % n''appartient pas à l''agence %', c.numero, NEW.agence_id;
  END IF;
  IF NEW.nb_lignes_prevues IS NULL THEN NEW.nb_lignes_prevues := 31 * p.nb_pages_livret; END IF;
  IF NEW.mise_courante IS NULL THEN NEW.mise_courante := NEW.mise_initiale; END IF;
  RETURN NEW;
END $$;
