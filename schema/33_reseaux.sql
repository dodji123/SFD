-- =====================================================================
-- 33_reseaux.sql
-- Réseaux d'agences : un réseau regroupe plusieurs agences. Un utilisateur a un périmètre :
--   agence (agence_id)  |  réseau (reseau_id, plusieurs agences)  |  siège (ni l'un ni l'autre : tout).
-- Nouveau rôle « coordinateur » (direction d'un réseau). Sa contrainte est posée dans le module 34
-- (une valeur d'enum ajoutée ne peut pas être utilisée dans la transaction qui l'ajoute).
-- Dépend de : 00, 11.
-- =====================================================================
SET search_path = mf, public;

ALTER TYPE role_utilisateur ADD VALUE IF NOT EXISTS 'coordinateur';

CREATE TABLE reseau (
  id       smallserial PRIMARY KEY,
  code     varchar(10) NOT NULL UNIQUE,
  libelle  text NOT NULL,
  actif    boolean NOT NULL DEFAULT true,
  cree_le  timestamptz NOT NULL DEFAULT now()
);

ALTER TABLE agence      ADD COLUMN reseau_id smallint REFERENCES reseau(id);
ALTER TABLE utilisateur ADD COLUMN reseau_id smallint REFERENCES reseau(id);

-- un périmètre à la fois : agence OU réseau (jamais les deux)
ALTER TABLE utilisateur ADD CONSTRAINT utilisateur_perimetre_unique
  CHECK (agence_id IS NULL OR reseau_id IS NULL);

-- l'ancienne règle « sans agence => siège » doit tolérer un utilisateur de réseau
ALTER TABLE utilisateur DROP CONSTRAINT utilisateur_agence_selon_role;
ALTER TABLE utilisateur ADD CONSTRAINT utilisateur_agence_selon_role
  CHECK (agence_id IS NOT NULL OR reseau_id IS NOT NULL OR role IN ('admin','directeur','comptable','auditeur'));

CREATE INDEX agence_reseau_idx ON agence(reseau_id);

-- Agences accessibles à un utilisateur ; NULL = toutes (siège).
CREATE FUNCTION agences_utilisateur(p_user integer) RETURNS integer[]
LANGUAGE sql STABLE AS $$
  SELECT CASE
           WHEN u.agence_id IS NOT NULL THEN ARRAY[u.agence_id::int]
           WHEN u.reseau_id IS NOT NULL THEN COALESCE((SELECT array_agg(a.id::int ORDER BY a.id) FROM agence a WHERE a.reseau_id = u.reseau_id), ARRAY[]::int[])
           ELSE NULL
         END
  FROM utilisateur u WHERE u.id = p_user
$$;

-- Garde-fou : un utilisateur de réseau ne peut pas désigner un réseau inactif.
CREATE FUNCTION trg_utilisateur_reseau() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF NEW.reseau_id IS NOT NULL AND NOT EXISTS (SELECT 1 FROM reseau WHERE id = NEW.reseau_id AND actif) THEN
    RAISE EXCEPTION 'Réseau inactif ou inconnu';
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER utilisateur_reseau BEFORE INSERT OR UPDATE OF reseau_id ON utilisateur
  FOR EACH ROW EXECUTE FUNCTION trg_utilisateur_reseau();

CREATE TRIGGER audit_reseau AFTER INSERT OR UPDATE OR DELETE ON reseau
  FOR EACH ROW EXECUTE FUNCTION trg_audit();
