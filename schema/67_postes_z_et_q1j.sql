SET search_path = mf, public;

-- =====================================================================
-- 67 : rattachement des postes Z01, Z02 et Q1J du modèle de reporting, d'après le plan comptable.
--  * Z01 « Prêts immobilisés »   = compte 191 (actif, sous-total de mémoire : non ajouté au total E90)
--  * Z02 « Crédits immobilisés » = compte 291 (actif, sous-total de mémoire : non ajouté au total E90)
--  * Q1J « Engagements de financements consortiaux » = comptes 376, 3761, 3762 (hors-bilan)
-- Les totaux E90 et L90 ne prennent que les sous-totaux de groupe : Z01 et Z02 ne les modifient pas.
-- =====================================================================
INSERT INTO poste_etat(code, cote, libelle) VALUES
  ('Z01', 'actif', 'Prêts immobilisés'),
  ('Z02', 'actif', 'Crédits immobilisés'),
  ('Q1J', 'hors_bilan', 'Comptes de suivi des engagements de financements consortiaux');

INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES
  ('Z01', '191', 1, false),
  ('Z02', '291', 1, false),
  ('Q1J', '376', 1, false);
