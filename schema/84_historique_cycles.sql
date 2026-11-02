SET search_path = mf, public;

-- 84 : totaux historiques des cycles repris de l'ancien logiciel (cycles clos sans lignes de collecte complètes).
-- Renseignés seulement par le chargement de reprise ; les cycles créés dans l'application les laissent vides.
ALTER TABLE cycle ADD COLUMN IF NOT EXISTS historique_collecte numeric,
                  ADD COLUMN IF NOT EXISTS historique_retrait numeric,
                  ADD COLUMN IF NOT EXISTS historique_net numeric;
