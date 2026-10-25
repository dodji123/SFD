SET search_path = mf, public;

-- =====================================================================
-- 60 : caissière qui a payé le retrait (tableau des retraits du jour par caissière)
-- =====================================================================
ALTER TABLE retrait ADD COLUMN execute_par integer REFERENCES utilisateur(id);
COMMENT ON COLUMN retrait.execute_par IS 'Utilisateur qui a exécuté (payé) le retrait';
