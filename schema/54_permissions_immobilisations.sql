-- =====================================================================
-- 54_permissions_immobilisations.sql
-- Permissions des immobilisations et de la maintenance (module 52), enregistrées dans la matrice de droits (module 53).
-- Dépend de : 53 (permission, droit_role).
-- =====================================================================
SET search_path = mf, public;
INSERT INTO permission(code, categorie) VALUES
  ('immobilisation:read', 'immobilisation'),
  ('immobilisation:gerer', 'immobilisation'),
  ('maintenance:signaler', 'maintenance'),
  ('maintenance:gerer', 'maintenance');
INSERT INTO droit_role(role_code, perm) VALUES
  ('admin', 'immobilisation:read'),
  ('auditeur', 'immobilisation:read'),
  ('chef_agence', 'immobilisation:read'),
  ('comptable', 'immobilisation:read'),
  ('coordinateur', 'immobilisation:read'),
  ('directeur', 'immobilisation:read'),
  ('admin', 'immobilisation:gerer'),
  ('chef_agence', 'immobilisation:gerer'),
  ('comptable', 'immobilisation:gerer'),
  ('coordinateur', 'immobilisation:gerer'),
  ('directeur', 'immobilisation:gerer'),
  ('admin', 'maintenance:signaler'),
  ('caissier', 'maintenance:signaler'),
  ('chef_agence', 'maintenance:signaler'),
  ('comptable', 'maintenance:signaler'),
  ('coordinateur', 'maintenance:signaler'),
  ('directeur', 'maintenance:signaler'),
  ('admin', 'maintenance:gerer'),
  ('chef_agence', 'maintenance:gerer'),
  ('comptable', 'maintenance:gerer'),
  ('coordinateur', 'maintenance:gerer'),
  ('directeur', 'maintenance:gerer');
