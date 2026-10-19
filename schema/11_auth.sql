-- =====================================================================
-- 11_auth.sql
-- Colonnes d'authentification des utilisateurs (utilisées par l'API) : mot de passe haché, verrouillage
-- après échecs répétés, lien vers l'agent ou la collectrice correspondant.
-- Dépend de : 00, 01 (agent), 04 (collectrice.agent_id).
-- =====================================================================
SET search_path = mf, public;

ALTER TABLE utilisateur
  ADD COLUMN mot_de_passe_hash  text,
  ADD COLUMN derniere_connexion timestamptz,
  ADD COLUMN echecs_connexion   smallint NOT NULL DEFAULT 0,
  ADD COLUMN verrouille_jusqua  timestamptz,
  ADD COLUMN agent_id           integer REFERENCES agent(id),
  ADD COLUMN collectrice_id     integer REFERENCES collectrice(id);

-- Un rôle d'agence doit avoir une agence ; seuls admin, directeur, comptable et auditeur peuvent être au siège.
ALTER TABLE utilisateur ADD CONSTRAINT utilisateur_agence_selon_role
  CHECK (agence_id IS NOT NULL OR role IN ('admin','directeur','comptable','auditeur'));
