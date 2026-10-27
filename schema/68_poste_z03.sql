SET search_path = mf, public;

-- =====================================================================
-- 68 : Z03 « Immobilisations acquises par réalisation de garantie » = comptes 453 et 454
-- (incorporelles et corporelles, avec leurs sous-comptes 4531 et 4541). Sous-total de mémoire : hors total E90.
-- =====================================================================
INSERT INTO poste_etat(code, cote, libelle) VALUES
  ('Z03', 'actif', 'Immobilisations acquises par réalisation de garantie');

INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES
  ('Z03', '453', 1, false),
  ('Z03', '454', 1, false);
