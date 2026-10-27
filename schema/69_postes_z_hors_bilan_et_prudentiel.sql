SET search_path = mf, public;

-- =====================================================================
-- 69 : rattachement des postes Z11 à Z19 (engagements hors bilan) et Z51 à Z53 (dispositif prudentiel),
-- d'après le plan comptable (classe 9 et comptes 51, 52, 53). Hypothèse de regroupement à faire valider
-- par le comptable : le modèle de reporting n'est pas dans le dépôt.
--  * Z11 engagements de financement donnés       = 901, 903
--  * Z12 engagements de financement reçus        = 902, 904
--  * Z13 engagements de garantie donnés          = 911, 913
--  * Z14 engagements de garantie reçus           = 912, 914
--  * Z15 titres à livrer                         = 921
--  * Z16 titres à recevoir                       = 922
--  * Z17 opérations de change au comptant et à terme = 931, 932
--  * Z18 prêts/emprunts en devises, report/déport, intérêts non courus et ajustements = 933 à 938
--  * Z19 autres engagements et opérations pour compte de tiers = 951, 952, 961, 962, 963, 965, 966
--  * Z51 provisions pour risques et charges      = 51 (511, 512, 519)
--  * Z52 provisions réglementées                 = 52 (521, 522)
--  * Z53 emprunts et titres émis subordonnés     = 53 (532, 536)
-- Hors bilan : montant = |débit − crédit| (règle de valeurs_postes). Z51 à Z53 sont des passifs : crédit − débit.
-- Sous-totaux de mémoire : ils n'entrent pas dans les totaux E90 et L90.
-- =====================================================================
INSERT INTO poste_etat(code, cote, libelle) VALUES
  ('Z11', 'hors_bilan', 'Engagements de financement donnés'),
  ('Z12', 'hors_bilan', 'Engagements de financement reçus'),
  ('Z13', 'hors_bilan', 'Engagements de garantie donnés'),
  ('Z14', 'hors_bilan', 'Engagements de garantie reçus'),
  ('Z15', 'hors_bilan', 'Titres à livrer'),
  ('Z16', 'hors_bilan', 'Titres à recevoir'),
  ('Z17', 'hors_bilan', 'Opérations de change au comptant et à terme'),
  ('Z18', 'hors_bilan', 'Prêts et emprunts en devises, report/déport, intérêts non courus et ajustements'),
  ('Z19', 'hors_bilan', 'Autres engagements et opérations pour compte de tiers'),
  ('Z51', 'passif', 'Provisions pour risques et charges'),
  ('Z52', 'passif', 'Provisions réglementées'),
  ('Z53', 'passif', 'Emprunts et titres émis subordonnés');

INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES
  ('Z11', '901', 1, false), ('Z11', '903', 1, false),
  ('Z12', '902', 1, false), ('Z12', '904', 1, false),
  ('Z13', '911', 1, false), ('Z13', '913', 1, false),
  ('Z14', '912', 1, false), ('Z14', '914', 1, false),
  ('Z15', '921', 1, false),
  ('Z16', '922', 1, false),
  ('Z17', '931', 1, false), ('Z17', '932', 1, false),
  ('Z18', '933', 1, false), ('Z18', '934', 1, false), ('Z18', '935', 1, false),
  ('Z18', '936', 1, false), ('Z18', '937', 1, false), ('Z18', '938', 1, false),
  ('Z19', '951', 1, false), ('Z19', '952', 1, false), ('Z19', '961', 1, false),
  ('Z19', '962', 1, false), ('Z19', '963', 1, false), ('Z19', '965', 1, false), ('Z19', '966', 1, false),
  ('Z51', '51', 1, false),
  ('Z52', '52', 1, false),
  ('Z53', '53', 1, false);
