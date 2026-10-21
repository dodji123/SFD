-- =====================================================================
-- 45_sync_mobile.sql
-- Application mobile du collecteur : synchronisation hors ligne idempotente.
--   * chaque saisie faite sur le téléphone porte une clé d'opération (UUID) générée côté client
--   * la clé est enregistrée dans la même transaction que la ligne de collecte : la rejouer ne crée rien
-- Dépend de : 01 (utilisateur), 07 (cycle, ligne_collecte).
-- =====================================================================
SET search_path = mf, public;

CREATE TABLE operation_mobile (
  cle            varchar(64) PRIMARY KEY,
  utilisateur_id integer NOT NULL REFERENCES utilisateur(id),
  cycle_id       integer NOT NULL REFERENCES cycle(id),
  ligne_id       integer REFERENCES ligne_collecte(id) ON DELETE SET NULL,
  recu_le        timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX operation_mobile_cycle_idx ON operation_mobile(cycle_id);
COMMENT ON TABLE operation_mobile IS 'Clés d''opération des saisies mobiles : une collecte envoyée plusieurs fois n''est enregistrée qu''une fois.';
