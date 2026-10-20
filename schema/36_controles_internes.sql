-- =====================================================================
-- 36_controles_internes.sql
-- Contrôles issus du guide méthodologique du contrôle interne :
--   * seuils de retrait par niveau (caissier / chef d'agence / direction) avec détection du fractionnement
--     (plusieurs retraits du même client le même jour pour rester sous le seuil)
--   * comptes dormants (aucun mouvement depuis N jours)
--   * séparation des tâches approbation / décaissement d'un crédit (paramètre, désactivé par défaut)
--   * journal des connexions en ajout seul (preuve)
-- Dépend de : 00, 01, 18, 34.
-- =====================================================================
SET search_path = mf, public;

INSERT INTO parametre(cle, valeur, description) VALUES
  ('retrait_seuil_caissier', '500000', 'Retrait maximal qu''un caissier exécute seul, cumul journalier du client compris ; au-delà : chef d''agence (provisoire)'),
  ('retrait_seuil_chef', '5000000', 'Retrait maximal qu''un chef d''agence exécute seul ; au-delà : direction (provisoire)'),
  ('dormance_jours', '365', 'Jours sans mouvement après lesquels un compte d''épargne est dit dormant (provisoire)'),
  ('separation_decaissement', '0', '1 = la personne qui décaisse un crédit ne peut pas être celle qui l''a approuvé');

-- Retraits d'un client à une date : retraits d'épargne classique + retraits de tontine exécutés
CREATE FUNCTION retraits_du_jour(p_client integer, p_date date DEFAULT current_date) RETURNS numeric
LANGUAGE sql STABLE AS $$
  SELECT COALESCE((SELECT sum(m.montant) FROM mf.mouvement_epargne m JOIN mf.compte_epargne c ON c.id = m.compte_id
                    WHERE c.client_id = p_client AND m.type = 'retrait' AND m.date_operation = p_date), 0)
       + COALESCE((SELECT sum(r.montant) FROM mf.retrait r JOIN mf.cycle cy ON cy.id = r.cycle_id
                    WHERE cy.client_id = p_client AND r.nature = 'retrait_client' AND r.statut = 'execute' AND r.date_operation = p_date), 0)
$$;

-- Plafond d'autonomie d'un rôle (NULL = sans plafond : direction, administrateur, coordinateur)
CREATE FUNCTION seuil_retrait(p_role text, p_agence smallint) RETURNS numeric
LANGUAGE sql STABLE AS $$
  SELECT CASE p_role
           WHEN 'caissier' THEN mf.param_num('retrait_seuil_caissier', p_agence)
           WHEN 'chef_agence' THEN mf.param_num('retrait_seuil_chef', p_agence)
           WHEN 'agent' THEN 0
           WHEN 'collectrice' THEN 0
           ELSE NULL
         END
$$;

-- Verdict : 'ok', 'seuil' (le montant seul dépasse le plafond) ou 'fractionnement' (le cumul du jour le dépasse)
CREATE FUNCTION controle_seuil_retrait(p_role text, p_client integer, p_agence smallint, p_montant numeric,
                                       p_date date DEFAULT current_date)
RETURNS TABLE(statut text, seuil numeric, cumul numeric)
LANGUAGE plpgsql STABLE AS $$
DECLARE v_seuil numeric; v_cumul numeric;
BEGIN
  v_seuil := mf.seuil_retrait(p_role, p_agence);
  IF v_seuil IS NULL THEN
    RETURN QUERY SELECT 'ok'::text, NULL::numeric, 0::numeric;
    RETURN;
  END IF;
  v_cumul := mf.retraits_du_jour(p_client, p_date);
  IF p_montant > v_seuil THEN
    RETURN QUERY SELECT 'seuil'::text, v_seuil, v_cumul;
  ELSIF v_cumul + p_montant > v_seuil THEN
    RETURN QUERY SELECT 'fractionnement'::text, v_seuil, v_cumul;
  ELSE
    RETURN QUERY SELECT 'ok'::text, v_seuil, v_cumul;
  END IF;
END $$;

-- Comptes dormants : aucun mouvement depuis le nombre de jours paramétré (par agence)
CREATE VIEW v_compte_dormant AS
SELECT c.id AS compte_id, c.agence_id, c.client_id, c.numero, cl.nom AS client,
       COALESCE(max(m.date_operation), c.ouvert_le) AS dernier_mouvement,
       (current_date - COALESCE(max(m.date_operation), c.ouvert_le))::integer AS jours_inactif,
       COALESCE(s.solde, 0) AS solde
FROM mf.compte_epargne c
JOIN mf.client cl ON cl.id = c.client_id
LEFT JOIN mf.mouvement_epargne m ON m.compte_id = c.id
LEFT JOIN mf.v_solde_compte_epargne s ON s.compte_id = c.id
WHERE c.statut = 'actif'
GROUP BY c.id, cl.nom, s.solde
HAVING (current_date - COALESCE(max(m.date_operation), c.ouvert_le)) >= COALESCE(mf.param_num('dormance_jours', c.agence_id), 365);

-- Journal des connexions : ajout seul (preuve conservable), comme le journal d'audit
CREATE TRIGGER journal_connexion_ajout_seul BEFORE UPDATE OR DELETE ON journal_connexion
  FOR EACH ROW EXECUTE FUNCTION trg_ajout_seul();
CREATE TRIGGER journal_connexion_pas_de_vidage BEFORE TRUNCATE ON journal_connexion
  FOR EACH STATEMENT EXECUTE FUNCTION trg_ajout_seul();
