-- =====================================================================
-- 32_analyse_capacite_politique.sql
-- Compléments de l'analyse de capacité (module 31) : politique de crédit paramétrable et données du dossier.
--   Paramètres (surchargeables par agence) : couverture minimale par les garanties, poids des cinq critères du score
--   (capacité, endettement, garanties et caution, ancienneté, historique), seuils de l'avis (favorable, sous conditions, risqué)
--   et plafonds de crédit par cycle (0 = sans plafond). Les valeurs de départ sont des repères, à remplacer par celles de l'institution.
--   Colonnes de l'analyse : cycle, caution, historique, garanties avec décote, ventes mois par mois (activité saisonnière),
--   scénarios comparés, membres d'un groupe solidaire, score et avis.
-- Dépend de : 31.
-- =====================================================================
SET search_path = mf, public;

INSERT INTO parametre(agence_id, cle, valeur, description) VALUES
  (NULL, 'garantie_min_pct', '100', 'garanties retenues (après décote) exigées, en % du crédit'),
  (NULL, 'score_poids_capacite', '35', 'poids du critère capacité de paiement dans le score (les cinq poids sont ramenés à 100)'),
  (NULL, 'score_poids_endettement', '20', 'poids du critère endettement dans le score'),
  (NULL, 'score_poids_garanties', '15', 'poids du critère garanties et caution dans le score'),
  (NULL, 'score_poids_anciennete', '15', 'poids du critère ancienneté de l''activité dans le score'),
  (NULL, 'score_poids_historique', '15', 'poids du critère historique de crédit dans le score'),
  (NULL, 'score_seuil_favorable', '75', 'score minimal (sur 100) de l''avis « Favorable »'),
  (NULL, 'score_seuil_conditions', '55', 'score minimal de l''avis « Sous conditions »'),
  (NULL, 'score_seuil_risque', '35', 'score minimal de l''avis « Risqué » (en dessous : « Défavorable »)'),
  (NULL, 'plafond_cycle_1', '300000', 'plafond de crédit du 1er cycle (F, 0 = sans plafond)'),
  (NULL, 'plafond_cycle_2', '500000', 'plafond de crédit du 2e cycle (F)'),
  (NULL, 'plafond_cycle_3', '800000', 'plafond de crédit du 3e cycle (F)'),
  (NULL, 'plafond_cycle_4', '1200000', 'plafond de crédit du 4e cycle (F)'),
  (NULL, 'plafond_cycle_5', '2000000', 'plafond de crédit du 5e cycle et suivants (F)')
ON CONFLICT DO NOTHING;

ALTER TABLE analyse_capacite ADD COLUMN cycle smallint NOT NULL DEFAULT 1 CHECK (cycle BETWEEN 1 AND 5);
ALTER TABLE analyse_capacite ADD COLUMN caution varchar(10) NOT NULL DEFAULT 'perso' CHECK (caution IN ('aucune','perso','groupe'));
ALTER TABLE analyse_capacite ADD COLUMN historique varchar(10) NOT NULL DEFAULT 'bon' CHECK (historique IN ('nouveau','bon','mineur','grave'));
ALTER TABLE analyse_capacite ADD COLUMN garanties jsonb NOT NULL DEFAULT '[]'::jsonb;        -- [{libelle, type, valeur, decote}]
ALTER TABLE analyse_capacite ADD COLUMN ventes_par_mois jsonb CHECK (ventes_par_mois IS NULL OR jsonb_array_length(ventes_par_mois) = 12);
ALTER TABLE analyse_capacite ADD COLUMN scenarios jsonb NOT NULL DEFAULT '[]'::jsonb;        -- [{libelle, montant, nb_echeances, taux, methode, differe}]
ALTER TABLE analyse_capacite ADD COLUMN groupe jsonb NOT NULL DEFAULT '[]'::jsonb;           -- [{nom, montant, disponible}]
ALTER TABLE analyse_capacite ADD COLUMN score numeric(5,1);
ALTER TABLE analyse_capacite ADD COLUMN avis varchar(20);
