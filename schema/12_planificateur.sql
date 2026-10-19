-- =====================================================================
-- 12_planificateur.sql
-- Journal des tâches quotidiennes lancées par le planificateur (api/app/planificateur.py).
-- Table technique : aucune règle métier. Garantit qu'une tâche n'est réussie qu'une fois par agence et par date
-- (rejouable sans doublon) et garde la trace de chaque exécution, y compris les échecs.
-- Dépend de : 00 (agence).
-- =====================================================================
SET search_path = mf, public;

CREATE TABLE execution_tache (
  id         bigserial PRIMARY KEY,
  agence_id  smallint NOT NULL REFERENCES agence(id),
  date_tache date NOT NULL,                       -- date métier passée à la fonction
  tache      varchar(40) NOT NULL
             CHECK (tache IN ('cloturer_cycles_echus','prelever_echeances_compte','maj_statuts_credit',
                              'saisir_garantie_echeances','purger_dates')),
  statut     varchar(10) NOT NULL CHECK (statut IN ('ok','echec','remplace')),   -- remplace : réussite écartée par un rejeu forcé
  nb_traites integer,                             -- valeur retournée par la fonction
  message    text,                                -- erreur éventuelle
  debut      timestamptz NOT NULL DEFAULT now(),
  fin        timestamptz,
  lance_par  text NOT NULL DEFAULT 'planificateur'
);

-- une seule réussite active par agence, date et tâche
CREATE UNIQUE INDEX execution_tache_ok_uniq ON execution_tache(agence_id, date_tache, tache) WHERE statut = 'ok';
CREATE INDEX execution_tache_date_idx ON execution_tache(date_tache DESC, agence_id);
