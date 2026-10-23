-- =====================================================================
-- 58_permissions_stock.sql
-- Permissions du stock des fournitures (module 57), enregistrées dans la matrice de droits (module 53).
--   stock:read    consulter articles, soldes, mouvements, alertes
--   stock:gerer   catalogue d'articles, lieux
--   stock:mouvoir entrées, transferts, demandes de sortie / rebut / inventaire, affectation des immobilisations
--   stock:valider décider une demande (toujours une autre personne que le demandeur)
-- Dépend de : 53 (permission, droit_role).
-- =====================================================================
SET search_path = mf, public;
INSERT INTO permission(code, categorie) VALUES
  ('stock:read', 'stock'),
  ('stock:gerer', 'stock'),
  ('stock:mouvoir', 'stock'),
  ('stock:valider', 'stock');
INSERT INTO droit_role(role_code, perm) VALUES
  ('admin', 'stock:read'), ('auditeur', 'stock:read'), ('caissier', 'stock:read'), ('chef_agence', 'stock:read'),
  ('comptable', 'stock:read'), ('coordinateur', 'stock:read'), ('directeur', 'stock:read'),
  ('admin', 'stock:gerer'), ('chef_agence', 'stock:gerer'), ('coordinateur', 'stock:gerer'), ('directeur', 'stock:gerer'),
  ('admin', 'stock:mouvoir'), ('caissier', 'stock:mouvoir'), ('chef_agence', 'stock:mouvoir'), ('comptable', 'stock:mouvoir'),
  ('coordinateur', 'stock:mouvoir'), ('directeur', 'stock:mouvoir'),
  ('admin', 'stock:valider'), ('chef_agence', 'stock:valider'), ('comptable', 'stock:valider'), ('coordinateur', 'stock:valider'), ('directeur', 'stock:valider');
