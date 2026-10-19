-- =====================================================================
-- 10_comptabilisation_audit.sql
-- (a) Comptabilisation automatique des événements (brief P1.3) : règles par événement sur les comptes
--     du référentiel SFD UMOA + triggers qui appellent comptabiliser().
-- (b) Piste d'audit (brief P2.4) : trigger générique vers audit_log.
-- Dépend de : 00 à 09.
--
-- La comptabilisation automatique est DÉSACTIVÉE par défaut : parametre 'comptabilisation_auto' = 'non'.
-- Pour l'activer (par agence ou globalement) : créer l'exercice comptable, faire valider les règles
-- ci-dessous par le comptable, puis  UPDATE mf.parametre SET valeur = 'oui' WHERE cle = 'comptabilisation_auto'.
--
-- COMPTES CHOISIS (PROPOSITION À VALIDER par le comptable) :
--   1011  Billets et monnaies émis par la BCEAO (caisse)
--   25111 Comptes ordinaires (épargne classique)        25391 Autres comptes d'épargne à régime spécial (tontine)
--   202211 Crédits à court terme de 0 à 6 mois           70212 Intérêts sur crédits à court terme
--   70293 Autres commissions (mises de tontine, frais)   7711 Pénalités perçues
--   3316 Autres débiteurs divers (dette des agents)      3327 Autres créditeurs divers (surplus, excédents)
--   3322 Personnel   3323 Organismes sociaux   3312 Personnel, avances   641 Salaires   642 Charges sociales
--   602512 Intérêts sur livrets   6716 / 7716 Pertes / produits sur écarts de caisse
-- Simplification : tous les crédits sont classés en 202211 quelle que soit leur durée.
-- =====================================================================
SET search_path = mf, public;

INSERT INTO parametre(cle, valeur, description) VALUES
  ('comptabilisation_auto', 'non', 'oui | non : génère les écritures comptables à chaque opération (voir 10_comptabilisation_audit.sql)');

-- ---------------------------------------------------------------------
-- Règles comptables (globales ; une règle d'agence de même ligne les remplace)
-- ---------------------------------------------------------------------
INSERT INTO regle_comptable(evenement, ligne, compte_debit, compte_credit, cle_montant, journal_code, libelle) VALUES
  ('epargne_depot',                 1, '1011',  '25111',  'montant', 'CAI', 'Dépôt sur compte d''épargne'),
  ('epargne_retrait',               1, '25111', '1011',   'montant', 'CAI', 'Retrait sur compte d''épargne'),
  ('epargne_interet',               1, '602512','25111',  'montant', 'EPA', 'Intérêts sur épargne'),
  ('virement_epargne_vers_tontine', 1, '25111', '25391',  'montant', 'EPA', 'Virement épargne vers tontine'),
  ('deblocage_credit_compte',       1, '202211','25111',  'montant', 'CRE', 'Déblocage de crédit sur compte'),
  ('frais_dossier_compte',          1, '25111', '70293',  'montant', 'CRE', 'Frais de dossier prélevés sur compte'),
  ('deblocage_credit_especes',      1, '202211','1011',   'montant', 'CRE', 'Déblocage de crédit en espèces'),
  ('frais_dossier_especes',         1, '1011',  '70293',  'montant', 'CRE', 'Frais de dossier encaissés'),
  -- fin de tournée : espèces versées, manquant (créance sur l'agent), surplus (dette envers l'agent)
  ('versement_agent',               1, '1011',  '25391',  'cash_collecte', 'AGT', 'Versement de collecte'),
  ('versement_agent',               2, '3316',  '25391',  'manquant',      'AGT', 'Manquant de tournée'),
  ('versement_agent',               3, '1011',  '3327',   'surplus',       'AGT', 'Surplus de tournée'),
  -- retrait de cycle payé au client (espèces)
  ('retrait_client',                1, '25391', '1011',   'paye_cycle',     'CAI', 'Retrait de cycle'),
  ('retrait_client',                2, '3316',  '1011',   'perte',          'CAI', 'Perte sur retrait imputée à l''agent'),
  ('retrait_client',                3, '3327',  '1011',   'surplus_utilise','CAI', 'Surplus utilisé sur retrait'),
  ('retrait_client',                4, '25391', '70293',  'mise',           'CAI', 'Mise de tontine (commission)'),
  ('retrait_client',                5, '25391', '3327',   'excedent',       'CAI', 'Excédent à régulariser'),
  -- retrait de cycle viré sur un compte d'épargne
  ('virement_vers_epargne',         1, '25391', '25111',  'paye_cycle',     'EPA', 'Virement du cycle vers l''épargne'),
  ('virement_vers_epargne',         2, '3316',  '25111',  'perte',          'EPA', 'Perte sur virement imputée à l''agent'),
  ('virement_vers_epargne',         3, '3327',  '25111',  'surplus_utilise','EPA', 'Surplus utilisé sur virement'),
  ('virement_vers_epargne',         4, '25391', '70293',  'mise',           'EPA', 'Mise de tontine (commission)'),
  ('virement_vers_epargne',         5, '25391', '3327',   'excedent',       'EPA', 'Excédent à régulariser'),
  -- remboursements de crédit : capital, intérêts, pénalités selon la source des fonds
  ('remboursement_tontine',         1, '25391', '202211', 'capital',  'CRE', 'Remboursement sur tontine : capital'),
  ('remboursement_tontine',         2, '25391', '70212',  'interet',  'CRE', 'Remboursement sur tontine : intérêts'),
  ('remboursement_tontine',         3, '25391', '7711',   'penalite', 'CRE', 'Remboursement sur tontine : pénalités'),
  ('remboursement_prelevement',     1, '25111', '202211', 'capital',  'CRE', 'Prélèvement : capital'),
  ('remboursement_prelevement',     2, '25111', '70212',  'interet',  'CRE', 'Prélèvement : intérêts'),
  ('remboursement_prelevement',     3, '25111', '7711',   'penalite', 'CRE', 'Prélèvement : pénalités'),
  ('remboursement_especes',         1, '1011',  '202211', 'capital',  'CRE', 'Remboursement en espèces : capital'),
  ('remboursement_especes',         2, '1011',  '70212',  'interet',  'CRE', 'Remboursement en espèces : intérêts'),
  ('remboursement_especes',         3, '1011',  '7711',   'penalite', 'CRE', 'Remboursement en espèces : pénalités'),
  ('remboursement_saisie_garantie', 1, '25111', '202211', 'capital',  'CRE', 'Saisie de garantie : capital'),
  ('remboursement_saisie_garantie', 2, '25111', '70212',  'interet',  'CRE', 'Saisie de garantie : intérêts'),
  ('remboursement_saisie_garantie', 3, '25111', '7711',   'penalite', 'CRE', 'Saisie de garantie : pénalités'),
  -- compte agent
  ('reglement_compte_agent',        1, '1011',  '3316',   'montant', 'AGT', 'Règlement du compte agent par versement'),
  ('retenue_commission_agent',      1, '641',   '3316',   'montant', 'AGT', 'Retenue sur commission'),
  -- paie : brut = net + retenues salariales + avance retenue
  ('paie',                          1, '641',   '3322',   'net',                'PAI', 'Salaires nets à payer'),
  ('paie',                          2, '641',   '3323',   'retenues',           'PAI', 'Retenues salariales'),
  ('paie',                          3, '641',   '3312',   'avance',             'PAI', 'Avances retenues'),
  ('paie',                          4, '642',   '3323',   'charges_patronales', 'PAI', 'Charges patronales'),
  -- écart de caisse constaté à la fermeture
  ('ecart_caisse_perte',            1, '6716',  '1011',   'montant', 'CAI', 'Écart de caisse (manquant)'),
  ('ecart_caisse_gain',             1, '1011',  '7716',   'montant', 'CAI', 'Écart de caisse (excédent)');

CREATE FUNCTION comptabilisation_active(p_agence smallint) RETURNS boolean
LANGUAGE sql STABLE AS $$ SELECT COALESCE(mf.param('comptabilisation_auto', p_agence), 'non') = 'oui' $$;

-- ---------------------------------------------------------------------
-- Triggers de comptabilisation
-- ---------------------------------------------------------------------
-- épargne : dépôts, retraits, intérêts, déblocage et frais de dossier passés sur compte
CREATE FUNCTION trg_compta_mouvement_epargne() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE v_agence smallint; v_evt text;
BEGIN
  v_evt := CASE NEW.type WHEN 'depot' THEN 'epargne_depot' WHEN 'retrait' THEN 'epargne_retrait'
                         WHEN 'interet' THEN 'epargne_interet' WHEN 'deblocage_credit' THEN 'deblocage_credit_compte'
                         WHEN 'frais_dossier' THEN 'frais_dossier_compte' END;
  IF v_evt IS NULL THEN RETURN NULL; END IF;
  SELECT agence_id INTO v_agence FROM mf.compte_epargne WHERE id = NEW.compte_id;
  IF mf.comptabilisation_active(v_agence) THEN
    PERFORM mf.comptabiliser(v_evt, v_agence, NEW.date_operation, jsonb_build_object('montant', NEW.montant),
                             'mouvement_epargne', NEW.id, NEW.libelle);
  END IF;
  RETURN NULL;
END $$;
CREATE TRIGGER compta_mouvement_epargne AFTER INSERT ON mouvement_epargne
  FOR EACH ROW EXECUTE FUNCTION trg_compta_mouvement_epargne();

-- caisse : déblocage de crédit et frais de dossier en espèces ; écart de fermeture
CREATE FUNCTION trg_compta_operation_caisse() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE v_agence smallint; v_evt text;
BEGIN
  v_evt := CASE WHEN NEW.motif = 'deblocage_credit' AND NEW.type = 'decaissement' THEN 'deblocage_credit_especes'
                WHEN NEW.motif = 'frais_dossier' AND NEW.type = 'encaissement' THEN 'frais_dossier_especes' END;
  IF v_evt IS NULL THEN RETURN NULL; END IF;
  SELECT k.agence_id INTO v_agence FROM mf.session_caisse s JOIN mf.caisse k ON k.id = s.caisse_id WHERE s.id = NEW.session_id;
  IF mf.comptabilisation_active(v_agence) THEN
    PERFORM mf.comptabiliser(v_evt, v_agence, NEW.date_operation, jsonb_build_object('montant', NEW.montant),
                             'operation_caisse', NEW.id, NEW.libelle);
  END IF;
  RETURN NULL;
END $$;
CREATE TRIGGER compta_operation_caisse AFTER INSERT ON operation_caisse
  FOR EACH ROW EXECUTE FUNCTION trg_compta_operation_caisse();

CREATE FUNCTION trg_compta_session_caisse() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE v_agence smallint;
BEGIN
  IF NEW.statut = 'fermee' AND OLD.statut = 'ouverte' AND COALESCE(NEW.ecart_fermeture, 0) <> 0 THEN
    SELECT agence_id INTO v_agence FROM mf.caisse WHERE id = NEW.caisse_id;
    IF mf.comptabilisation_active(v_agence) THEN
      PERFORM mf.comptabiliser(CASE WHEN NEW.ecart_fermeture < 0 THEN 'ecart_caisse_perte' ELSE 'ecart_caisse_gain' END,
                               v_agence, NEW.date_session, jsonb_build_object('montant', abs(NEW.ecart_fermeture)),
                               'session_caisse', NEW.id, 'Écart de caisse à la fermeture');
    END IF;
  END IF;
  RETURN NULL;
END $$;
CREATE TRIGGER compta_session_caisse AFTER UPDATE OF statut ON session_caisse
  FOR EACH ROW EXECUTE FUNCTION trg_compta_session_caisse();

-- fin de tournée
CREATE FUNCTION trg_compta_versement_agent() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  IF mf.comptabilisation_active(NEW.agence_id) THEN
    PERFORM mf.comptabiliser('versement_agent', NEW.agence_id, NEW.date_tournee,
      jsonb_build_object('cash_collecte', LEAST(NEW.montant_collecte, NEW.montant_verse),
                         'manquant', GREATEST(NEW.ecart, 0), 'surplus', GREATEST(-NEW.ecart, 0)),
      'versement_agent', NEW.id, 'Versement de la tournée du ' || NEW.date_tournee);
  END IF;
  RETURN NULL;
END $$;
CREATE TRIGGER compta_versement_agent AFTER INSERT ON versement_agent
  FOR EACH ROW EXECUTE FUNCTION trg_compta_versement_agent();

-- règlement et retenue sur le compte agent (manquants et pertes sont déjà comptabilisés par la tournée et le retrait)
CREATE FUNCTION trg_compta_compte_agent() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE v_evt text;
BEGIN
  v_evt := CASE NEW.type WHEN 'versement' THEN 'reglement_compte_agent' WHEN 'retenue_commission' THEN 'retenue_commission_agent' END;
  IF v_evt IS NOT NULL AND mf.comptabilisation_active(NEW.agence_id) THEN
    PERFORM mf.comptabiliser(v_evt, NEW.agence_id, NEW.date_operation, jsonb_build_object('montant', NEW.montant),
                             'compte_agent', NEW.id, NEW.libelle);
  END IF;
  RETURN NULL;
END $$;
CREATE TRIGGER compta_compte_agent AFTER INSERT ON compte_agent
  FOR EACH ROW EXECUTE FUNCTION trg_compta_compte_agent();

-- retrait de cycle exécuté (payé au client ou viré sur un compte)
CREATE FUNCTION trg_compta_retrait() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE v_mise numeric; v_perte numeric := 0; v_surplus numeric := 0; v_exc numeric := 0; v_paye numeric;
BEGIN
  IF NEW.nature NOT IN ('retrait_client','virement_vers_epargne') OR NOT mf.comptabilisation_active(NEW.agence_id) THEN
    RETURN NULL;
  END IF;
  SELECT mise_finale INTO v_mise FROM mf.cycle WHERE id = NEW.cycle_id;
  SELECT COALESCE(sum(d.perte), 0), COALESCE(sum(d.surplus_utilise), 0) INTO v_perte, v_surplus
    FROM mf.ecart_retrait_date d JOIN mf.ecart_retrait e ON e.id = d.ecart_id
   WHERE e.retrait_id = NEW.id AND e.sens = 'livret_sup';
  SELECT COALESCE(sum(montant), 0) INTO v_exc FROM mf.ecart_retrait WHERE retrait_id = NEW.id AND sens = 'machine_sup';
  v_paye := NEW.montant_paye;
  PERFORM mf.comptabiliser(CASE NEW.nature WHEN 'retrait_client' THEN 'retrait_client' ELSE 'virement_vers_epargne' END,
    NEW.agence_id, NEW.date_operation,
    jsonb_build_object('paye_cycle', v_paye - v_perte - v_surplus, 'perte', v_perte, 'surplus_utilise', v_surplus,
                       'mise', v_mise, 'excedent', v_exc),
    'retrait', NEW.id, 'Retrait du cycle ' || (SELECT numero FROM mf.cycle WHERE id = NEW.cycle_id));
  RETURN NULL;
END $$;
CREATE TRIGGER compta_retrait AFTER UPDATE OF statut ON retrait
  FOR EACH ROW WHEN (NEW.statut = 'execute' AND OLD.statut <> 'execute') EXECUTE FUNCTION trg_compta_retrait();

-- virement de l'épargne vers un cycle (le sens inverse est comptabilisé par le retrait de cycle)
CREATE FUNCTION trg_compta_virement() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  IF NEW.sens = 'epargne_vers_cycle' AND mf.comptabilisation_active(NEW.agence_id) THEN
    PERFORM mf.comptabiliser('virement_epargne_vers_tontine', NEW.agence_id, NEW.date_operation,
                             jsonb_build_object('montant', NEW.montant), 'virement', NEW.id);
  END IF;
  RETURN NULL;
END $$;
CREATE TRIGGER compta_virement AFTER INSERT ON virement
  FOR EACH ROW EXECUTE FUNCTION trg_compta_virement();

-- remboursements : capital, intérêts, pénalités par source de fonds
CREATE FUNCTION trg_compta_paiement_echeance() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE v_agence smallint;
BEGIN
  SELECT agence_id INTO v_agence FROM mf.credit WHERE id = NEW.credit_id;
  IF mf.comptabilisation_active(v_agence) THEN
    PERFORM mf.comptabiliser('remboursement_' || NEW.source, v_agence, NEW.date_operation,
      jsonb_build_object('capital', NEW.capital, 'interet', NEW.interet, 'penalite', NEW.penalite),
      'paiement_echeance', NEW.id);
  END IF;
  RETURN NULL;
END $$;
CREATE TRIGGER compta_paiement_echeance AFTER INSERT ON paiement_echeance
  FOR EACH ROW EXECUTE FUNCTION trg_compta_paiement_echeance();

-- paie : à la validation du bulletin, à la fin du mois de paie
CREATE FUNCTION trg_compta_bulletin() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  IF mf.comptabilisation_active(NEW.agence_id) THEN
    PERFORM mf.comptabiliser('paie', NEW.agence_id, (NEW.periode + interval '1 month - 1 day')::date,
      jsonb_build_object('net', NEW.net_a_payer, 'retenues', NEW.retenues, 'avance', NEW.retenue_avance,
                         'charges_patronales', NEW.charges_patronales),
      'bulletin_paie', NEW.id, 'Paie ' || to_char(NEW.periode, 'MM/YYYY'));
  END IF;
  RETURN NULL;
END $$;
CREATE TRIGGER compta_bulletin AFTER UPDATE OF statut ON bulletin_paie
  FOR EACH ROW WHEN (NEW.statut = 'valide' AND OLD.statut = 'brouillon') EXECUTE FUNCTION trg_compta_bulletin();

-- ---------------------------------------------------------------------
-- Piste d'audit : INSERT / UPDATE / DELETE des tables sensibles (retraits, écarts, surplus, compte agent,
-- crédits, garanties, écritures via les pièces, paie, caisse). L'application renseigne l'utilisateur par
--   SET LOCAL mf.utilisateur = '<id ou login>';   (à défaut : l'utilisateur de la base)
-- ---------------------------------------------------------------------
CREATE FUNCTION trg_audit() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE v_user text := COALESCE(NULLIF(current_setting('mf.utilisateur', true), ''), current_user);
        v_row jsonb;
BEGIN
  v_row := CASE WHEN TG_OP = 'DELETE' THEN to_jsonb(OLD) ELSE to_jsonb(NEW) END;
  INSERT INTO mf.audit_log(utilisateur, table_name, operation, ligne_id, avant, apres)
  VALUES (v_user, TG_TABLE_NAME, TG_OP, v_row ->> 'id',
          CASE WHEN TG_OP IN ('UPDATE','DELETE') THEN to_jsonb(OLD) END,
          CASE WHEN TG_OP IN ('INSERT','UPDATE') THEN to_jsonb(NEW) END);
  RETURN NULL;
END $$;

DO $$
DECLARE t text;
BEGIN
  FOREACH t IN ARRAY ARRAY['cycle','retrait','ecart_retrait','ecart_retrait_date','excedent_regularisation','surplus',
                           'compte_agent','versement_agent','virement','credit','echeance','demande_credit',
                           'garantie_compte','piece_comptable','session_caisse','bulletin_paie','avance_salaire',
                           'commission_collectrice','parametre','mouvement_epargne']
  LOOP
    EXECUTE format('CREATE TRIGGER audit_%I AFTER INSERT OR UPDATE OR DELETE ON mf.%I
                    FOR EACH ROW EXECUTE FUNCTION mf.trg_audit()', t, t);
  END LOOP;
END $$;
CREATE INDEX audit_log_table ON audit_log (table_name, ligne_id);
CREATE INDEX audit_log_horodatage ON audit_log (horodatage);
