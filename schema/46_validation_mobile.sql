-- =====================================================================
-- 46_validation_mobile.sql
-- Application mobile : file de VALIDATION. Les opérations du téléphone (nouveau client, ouverture de cycle,
-- collecte, clôture) ne s'écrivent plus directement : elles sont mises en attente ici, puis validées ou rejetées
-- (avec motif) par un opérateur de saisie. La validation les rejoue dans les données vives.
-- Dépend de : 45 (operation_mobile), 00 (utilisateur, agence), 01 (agent).
-- =====================================================================
SET search_path = mf, public;

ALTER TABLE operation_mobile ALTER COLUMN cycle_id DROP NOT NULL;
ALTER TABLE operation_mobile
  ADD COLUMN agence_id  smallint REFERENCES agence(id),
  ADD COLUMN agent_id   integer REFERENCES agent(id),
  ADD COLUMN type       varchar(10) NOT NULL DEFAULT 'collecte' CHECK (type IN ('client','cycle','collecte','cloture')),
  ADD COLUMN payload    jsonb NOT NULL DEFAULT '{}'::jsonb,
  ADD COLUMN rang       smallint NOT NULL DEFAULT 3,            -- ordre de rejeu : client 1, cycle 2, collecte 3, clôture 4
  ADD COLUMN statut     varchar(10) NOT NULL DEFAULT 'en_attente' CHECK (statut IN ('en_attente','validee','rejetee')),
  ADD COLUMN code       varchar(30),
  ADD COLUMN motif      text,
  ADD COLUMN decide_par integer REFERENCES utilisateur(id),
  ADD COLUMN decide_le  timestamptz,
  ADD COLUMN resultat_id integer,                                -- client / cycle / ligne créé par la validation
  ADD CONSTRAINT operation_mobile_rejet_motif CHECK (statut <> 'rejetee' OR motif IS NOT NULL);

-- lignes déjà reçues avant cette évolution : elles avaient été écrites directement, donc déjà validées
UPDATE operation_mobile SET statut = 'validee', decide_le = recu_le, resultat_id = ligne_id WHERE ligne_id IS NOT NULL;

CREATE INDEX operation_mobile_file_idx ON operation_mobile(agence_id, statut, agent_id);
COMMENT ON COLUMN operation_mobile.statut IS 'en_attente : reçue du téléphone, pas encore dans les données vives ; validee : rejouée ; rejetee : refusée avec motif.';
