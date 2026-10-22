-- =====================================================================
-- 50_operations_standard.sql
-- Opérations standard paramétrables (de caisse / hors caisse) et transfert de fonds avec accusé de réception.
--   * catalogue d'opérations standard : famille « caisse » (mouvement d'espèces dans une session ouverte) ou
--     « hors caisse » (aucun mouvement d'espèces : virement, facture à payer, dotation...), catégorie, sens,
--     comptes débité/crédité, justificatif obligatoire, seuil au-delà duquel un second responsable valide
--   * les comptes du catalogue alimentent les règles comptables (regle_comptable, événement « op_<code> ») ; le comptable
--     les valide (comptes_valides) ; les écritures ne sont générées que si la comptabilisation automatique est active
--   * une opération de caisse ne touche la caisse qu'une fois validée ; le validateur n'est jamais le saisisseur
--   * transfert de fonds entre caisses (même agence ou non) en deux temps : envoi (fonds en transit), réception confirmée
--     par un AUTRE utilisateur avec constat de l'écart, ou refus avec retour à la caisse d'origine
--   * tout est journalisé et inaltérable une fois décidé
-- Dépend de : 00 (agence, utilisateur, parametre), 03 (caisse, session_caisse, caisse_operation), 05 (comptabilité, règles).
-- =====================================================================
SET search_path = mf, public;

-- ---------------------------------------------------------------- catalogue des opérations standard
CREATE TABLE operation_standard (
  code                     varchar(30) PRIMARY KEY CHECK (code ~ '^[a-z0-9_]+$'),
  libelle                  text NOT NULL,
  famille                  varchar(12) NOT NULL CHECK (famille IN ('caisse','hors_caisse')),
  categorie                varchar(14) NOT NULL CHECK (categorie IN ('charge','produit','immobilisation','regularisation','autre')),
  sens                     varchar(7) NOT NULL CHECK (sens IN ('entree','sortie')),
  compte_debit             varchar(7) REFERENCES compte_comptable(code),
  compte_credit            varchar(7) REFERENCES compte_comptable(code),
  journal_code             varchar(6) NOT NULL DEFAULT 'OD' REFERENCES journal(code),
  justificatif_obligatoire boolean NOT NULL DEFAULT false,
  seuil_validation         numeric(14,0) CHECK (seuil_validation IS NULL OR seuil_validation >= 0),
  comptes_valides          boolean NOT NULL DEFAULT false,
  actif                    boolean NOT NULL DEFAULT true,
  CHECK ((compte_debit IS NULL) = (compte_credit IS NULL))
);
COMMENT ON TABLE operation_standard IS 'Opérations standard paramétrables : de caisse (espèces) ou hors caisse ; leurs comptes alimentent regle_comptable.';

CREATE FUNCTION trg_operation_standard_regles() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF NEW.compte_debit IS NOT NULL THEN
    IF NEW.famille = 'caisse' THEN
      -- le compte de caisse du côté de l'espèce : entrée = caisse débitée, sortie = caisse créditée
      IF NEW.sens = 'entree' AND NEW.compte_debit <> '1011' THEN RAISE EXCEPTION 'Une entrée de caisse débite le compte de caisse 1011'; END IF;
      IF NEW.sens = 'sortie' AND NEW.compte_credit <> '1011' THEN RAISE EXCEPTION 'Une sortie de caisse crédite le compte de caisse 1011'; END IF;
    ELSIF NEW.compte_debit = '1011' OR NEW.compte_credit = '1011' THEN
      RAISE EXCEPTION 'Une opération hors caisse ne touche pas le compte de caisse 1011';
    END IF;
  ELSIF NEW.comptes_valides THEN
    RAISE EXCEPTION 'Des comptes à valider doivent d''abord être renseignés';
  END IF;
  IF TG_OP = 'UPDATE' THEN
    IF NEW.famille <> OLD.famille AND EXISTS (SELECT 1 FROM mf.operation_generale WHERE code_operation = OLD.code) THEN
      RAISE EXCEPTION 'La famille d''une opération déjà utilisée ne se change pas';
    END IF;
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER operation_standard_regles BEFORE INSERT OR UPDATE ON operation_standard FOR EACH ROW EXECUTE FUNCTION trg_operation_standard_regles();

-- synchronisation avec les règles comptables (événement « op_<code> »)
CREATE FUNCTION trg_operation_standard_sync() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF NEW.compte_debit IS NOT NULL THEN
    INSERT INTO mf.regle_comptable(evenement, ligne, compte_debit, compte_credit, cle_montant, journal_code, libelle, actif)
    VALUES ('op_' || NEW.code, 1, NEW.compte_debit, NEW.compte_credit, 'montant', NEW.journal_code, NEW.libelle, NEW.actif)
    ON CONFLICT (evenement, ligne, (COALESCE(agence_id, 0)))
    DO UPDATE SET compte_debit = EXCLUDED.compte_debit, compte_credit = EXCLUDED.compte_credit, journal_code = EXCLUDED.journal_code,
                  libelle = EXCLUDED.libelle, actif = EXCLUDED.actif;
  ELSE
    UPDATE mf.regle_comptable SET actif = false WHERE evenement = 'op_' || NEW.code;
  END IF;
  RETURN NULL;
END $$;
CREATE TRIGGER operation_standard_sync AFTER INSERT OR UPDATE ON operation_standard FOR EACH ROW EXECUTE FUNCTION trg_operation_standard_sync();
CREATE TRIGGER audit_operation_standard AFTER INSERT OR UPDATE ON operation_standard FOR EACH ROW EXECUTE FUNCTION trg_audit();

-- opérations proposées (comptes à faire valider par le comptable)
INSERT INTO operation_standard(code, libelle, famille, categorie, sens, compte_debit, compte_credit, journal_code, justificatif_obligatoire, seuil_validation) VALUES
  ('achat_fournitures',        'Achat de fournitures de bureau',              'caisse',      'charge',  'sortie', '6218',   '1011',   'CAI', true,  50000),
  ('paiement_loyer',           'Paiement de loyer',                           'caisse',      'charge',  'sortie', '6212',   '1011',   'CAI', true,  100000),
  ('paiement_eau',             'Paiement de la facture d''eau',               'caisse',      'charge',  'sortie', '611621', '1011',   'CAI', true,  50000),
  ('paiement_electricite',     'Paiement de la facture d''électricité',       'caisse',      'charge',  'sortie', '611622', '1011',   'CAI', true,  50000),
  ('frais_communication',      'Frais de communication et de poste',          'caisse',      'charge',  'sortie', '6227',   '1011',   'CAI', false, 50000),
  ('frais_deplacement',        'Frais de déplacement',                        'caisse',      'charge',  'sortie', '62261',  '1011',   'CAI', false, 50000),
  ('carburant',                'Carburant et lubrifiants',                    'caisse',      'charge',  'sortie', '61161',  '1011',   'CAI', true,  50000),
  ('entretien_reparation',     'Entretien et réparation payés comptant',      'caisse',      'charge',  'sortie', '6214',   '1011',   'CAI', true,  50000),
  ('depense_diverse',          'Dépense diverse',                             'caisse',      'charge',  'sortie', '6228',   '1011',   'CAI', true,  25000),
  ('produit_divers',           'Produit divers encaissé',                     'caisse',      'produit', 'entree', '1011',   '7038',   'CAI', false, NULL),
  ('loyer_percu',              'Loyer perçu',                                 'caisse',      'produit', 'entree', '1011',   '704611', 'CAI', false, NULL),
  ('facture_loyer_a_payer',    'Loyer facturé, à payer (charge à payer)',     'hors_caisse', 'charge',  'sortie', '6212',   '33211',  'OD',  true,  NULL),
  ('facture_entretien_a_payer','Entretien et réparation facturés, à payer',   'hors_caisse', 'charge',  'sortie', '6214',   '33211',  'OD',  true,  NULL),
  ('virement_fournisseur',     'Règlement d''un fournisseur par la banque',   'hors_caisse', 'regularisation', 'sortie', '33211', '1141', 'OD', true,  NULL);

-- ---------------------------------------------------------------- exécution des opérations
CREATE TABLE operation_generale (
  id                    bigserial PRIMARY KEY,
  agence_id             smallint NOT NULL REFERENCES agence(id),
  code_operation        varchar(30) NOT NULL REFERENCES operation_standard(code),
  date_operation        date NOT NULL,
  montant               numeric(14,0) NOT NULL CHECK (montant > 0),
  tiers                 text,
  reference_justificatif text,
  libelle               text,
  session_id            integer REFERENCES session_caisse(id),
  operation_caisse_id   bigint REFERENCES operation_caisse(id),
  piece_id              bigint REFERENCES piece_comptable(id),
  statut                varchar(10) NOT NULL DEFAULT 'a_valider' CHECK (statut IN ('a_valider','valide','rejete','annule')),
  cle                   varchar(64) UNIQUE,
  saisi_par             integer REFERENCES utilisateur(id),
  saisi_le              timestamptz NOT NULL DEFAULT now(),
  decide_par            integer REFERENCES utilisateur(id),
  decide_le             timestamptz,
  commentaire_decision  text
);
CREATE INDEX operation_generale_idx ON operation_generale(agence_id, date_operation DESC);
CREATE INDEX operation_generale_statut_idx ON operation_generale(agence_id, statut);

CREATE FUNCTION trg_operation_generale_regles() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE v_seuil numeric;
BEGIN
  IF TG_OP = 'DELETE' THEN RAISE EXCEPTION 'Une opération ne se supprime pas : annulez-la ou rejetez-la'; END IF;
  IF OLD.statut <> 'a_valider' THEN RAISE EXCEPTION 'Une opération décidée ne se modifie plus'; END IF;
  IF (NEW.agence_id, NEW.code_operation, NEW.date_operation, NEW.montant, NEW.saisi_par) IS DISTINCT FROM (OLD.agence_id, OLD.code_operation, OLD.date_operation, OLD.montant, OLD.saisi_par) THEN
    RAISE EXCEPTION 'Le contenu d''une opération saisie ne se modifie pas : annulez-la et ressaisissez-la';
  END IF;
  IF NEW.statut IN ('valide','rejete') THEN
    IF NEW.decide_par IS NULL THEN RAISE EXCEPTION 'La décision doit être attribuée à son auteur'; END IF;
    -- au-dessus du seuil de validation, le validateur n'est jamais le saisisseur
    SELECT seuil_validation INTO v_seuil FROM mf.operation_standard WHERE code = OLD.code_operation;
    IF NEW.decide_par IS NOT DISTINCT FROM OLD.saisi_par AND v_seuil IS NOT NULL AND OLD.montant >= v_seuil THEN
      RAISE EXCEPTION 'Séparation des tâches : on ne valide pas sa propre opération au-dessus du seuil de validation';
    END IF;
    IF NEW.statut = 'rejete' AND length(btrim(COALESCE(NEW.commentaire_decision, ''))) < 5 THEN RAISE EXCEPTION 'Un rejet doit être motivé'; END IF;
    NEW.decide_le := now();
  ELSIF NEW.statut = 'annule' THEN
    NEW.decide_le := now();
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER operation_generale_regles BEFORE UPDATE OR DELETE ON operation_generale FOR EACH ROW EXECUTE FUNCTION trg_operation_generale_regles();
CREATE TRIGGER audit_operation_generale AFTER INSERT OR UPDATE ON operation_generale FOR EACH ROW EXECUTE FUNCTION trg_audit();

-- mouvement de caisse et écritures : appelé quand l'opération devient valide
CREATE FUNCTION executer_operation_generale(p_id bigint, p_session integer DEFAULT NULL) RETURNS void LANGUAGE plpgsql AS $$
DECLARE o mf.operation_generale; s mf.operation_standard; v_session integer; v_op bigint; v_piece bigint; k mf.caisse;
BEGIN
  SELECT * INTO o FROM mf.operation_generale WHERE id = p_id FOR UPDATE;
  SELECT * INTO s FROM mf.operation_standard WHERE code = o.code_operation;
  IF s.famille = 'caisse' THEN
    v_session := COALESCE(p_session, o.session_id);
    IF v_session IS NULL THEN RAISE EXCEPTION 'Une opération de caisse exige une session de caisse ouverte'; END IF;
    SELECT c.* INTO k FROM mf.session_caisse sc JOIN mf.caisse c ON c.id = sc.caisse_id WHERE sc.id = v_session;
    IF k.id IS NULL OR k.agence_id <> o.agence_id THEN RAISE EXCEPTION 'La session de caisse n''appartient pas à l''agence de l''opération'; END IF;
    v_op := mf.caisse_operation(v_session, CASE s.sens WHEN 'entree' THEN 'encaissement' ELSE 'decaissement' END, s.code, o.montant,
                                o.date_operation, 'operation_generale', o.id, s.libelle || COALESCE(' — ' || o.tiers, ''));
  END IF;
  IF s.compte_debit IS NOT NULL AND mf.comptabilisation_active(o.agence_id) THEN
    v_piece := mf.comptabiliser('op_' || s.code, o.agence_id, o.date_operation, jsonb_build_object('montant', o.montant), 'operation_generale', o.id,
                                COALESCE(o.libelle, s.libelle));
  END IF;
  UPDATE mf.operation_generale SET session_id = v_session, operation_caisse_id = v_op, piece_id = v_piece WHERE id = p_id;
END $$;

CREATE FUNCTION saisir_operation_generale(p_agence smallint, p_code text, p_date date, p_montant numeric, p_tiers text, p_reference text,
                                          p_libelle text, p_session integer, p_utilisateur integer, p_cle text DEFAULT NULL) RETURNS bigint
LANGUAGE plpgsql AS $$
DECLARE s mf.operation_standard; v_id bigint; v_statut text;
BEGIN
  IF p_cle IS NOT NULL THEN
    SELECT id INTO v_id FROM mf.operation_generale WHERE cle = p_cle;
    IF v_id IS NOT NULL THEN RETURN v_id; END IF;
  END IF;
  SELECT * INTO s FROM mf.operation_standard WHERE code = p_code AND actif;
  IF s.code IS NULL THEN RAISE EXCEPTION 'Opération standard % inconnue ou inactive', p_code; END IF;
  IF s.justificatif_obligatoire AND length(btrim(COALESCE(p_reference, ''))) = 0 THEN
    RAISE EXCEPTION 'Un justificatif (référence de la pièce) est obligatoire pour « % »', s.libelle;
  END IF;
  IF s.famille = 'caisse' AND p_session IS NULL THEN RAISE EXCEPTION 'Une opération de caisse exige une session de caisse ouverte'; END IF;
  IF s.famille = 'caisse' AND NOT EXISTS (SELECT 1 FROM mf.session_caisse WHERE id = p_session AND statut = 'ouverte') THEN
    RAISE EXCEPTION 'La session de caisse n''est pas ouverte';
  END IF;
  IF s.famille = 'hors_caisse' AND p_session IS NOT NULL THEN RAISE EXCEPTION 'Une opération hors caisse n''utilise pas de session de caisse'; END IF;
  v_statut := CASE WHEN s.seuil_validation IS NOT NULL AND p_montant >= s.seuil_validation THEN 'a_valider' ELSE 'valide' END;
  INSERT INTO mf.operation_generale(agence_id, code_operation, date_operation, montant, tiers, reference_justificatif, libelle, session_id, statut, cle, saisi_par)
    VALUES (p_agence, p_code, p_date, p_montant, p_tiers, p_reference, p_libelle, p_session, 'a_valider', p_cle, p_utilisateur) RETURNING id INTO v_id;
  IF v_statut = 'valide' THEN
    PERFORM mf.executer_operation_generale(v_id, p_session);
    -- sous le seuil : validée à la saisie par son auteur (aucun second validateur exigé)
    UPDATE mf.operation_generale SET statut = 'valide', decide_par = p_utilisateur, commentaire_decision = 'Sous le seuil de validation' WHERE id = v_id;
  END IF;
  RETURN v_id;
END $$;

-- décision d'un second responsable sur une opération au-dessus du seuil
CREATE FUNCTION decider_operation_generale(p_id bigint, p_valide boolean, p_utilisateur integer, p_commentaire text DEFAULT NULL,
                                           p_session integer DEFAULT NULL) RETURNS text LANGUAGE plpgsql AS $$
DECLARE o mf.operation_generale;
BEGIN
  SELECT * INTO o FROM mf.operation_generale WHERE id = p_id FOR UPDATE;
  IF o.id IS NULL THEN RAISE EXCEPTION 'Opération % introuvable', p_id; END IF;
  IF o.statut <> 'a_valider' THEN RAISE EXCEPTION 'Cette opération est déjà %', o.statut; END IF;
  IF p_valide THEN
    PERFORM mf.executer_operation_generale(p_id, p_session);      -- mouvement de caisse et écritures d'abord : un refus annule tout
    UPDATE mf.operation_generale SET statut = 'valide', decide_par = p_utilisateur, commentaire_decision = p_commentaire WHERE id = p_id;
    RETURN 'valide';
  END IF;
  UPDATE mf.operation_generale SET statut = 'rejete', decide_par = p_utilisateur, commentaire_decision = p_commentaire WHERE id = p_id;
  RETURN 'rejete';
END $$;

CREATE VIEW v_operation_generale AS
SELECT o.*, s.libelle AS operation, s.famille, s.categorie, s.sens, s.seuil_validation, us.nom AS saisi_par_nom, ud.nom AS decide_par_nom,
       k.code AS caisse
FROM mf.operation_generale o
JOIN mf.operation_standard s ON s.code = o.code_operation
LEFT JOIN mf.utilisateur us ON us.id = o.saisi_par
LEFT JOIN mf.utilisateur ud ON ud.id = o.decide_par
LEFT JOIN mf.session_caisse sc ON sc.id = o.session_id
LEFT JOIN mf.caisse k ON k.id = sc.caisse_id;

-- ---------------------------------------------------------------- transfert de fonds entre caisses (avec accusé de réception)
INSERT INTO regle_comptable(evenement, ligne, compte_debit, compte_credit, cle_montant, journal_code, libelle) VALUES
  ('transfert_fonds_envoi',      1, '378',  '1011', 'montant',      'CAI', 'Transfert de fonds : envoi (fonds en transit)'),
  ('transfert_fonds_reception',  1, '1011', '378',  'montant_recu', 'CAI', 'Transfert de fonds : réception'),
  ('transfert_fonds_reception',  2, '6716', '378',  'manque',       'CAI', 'Transfert de fonds : manquant constaté à la réception'),
  ('transfert_fonds_reception',  3, '378',  '7716', 'surplus',      'CAI', 'Transfert de fonds : excédent constaté à la réception'),
  ('transfert_fonds_retour',     1, '1011', '378',  'montant',      'CAI', 'Transfert de fonds refusé : retour à la caisse d''origine');

INSERT INTO parametre(cle, valeur, description) VALUES
  ('transfert_fonds_delai_alerte_heures', '24', 'Heures au-delà desquelles un transfert de fonds non réceptionné est signalé en retard')
ON CONFLICT DO NOTHING;

CREATE TABLE transfert_fonds (
  id                   serial PRIMARY KEY,
  reference            varchar(20) UNIQUE,
  caisse_source_id     integer NOT NULL REFERENCES caisse(id),
  caisse_dest_id       integer NOT NULL REFERENCES caisse(id),
  montant              numeric(14,0) NOT NULL CHECK (montant > 0),
  motif                text,
  statut               varchar(8) NOT NULL DEFAULT 'envoye' CHECK (statut IN ('envoye','recu','refuse')),
  date_envoi           date NOT NULL DEFAULT current_date,
  session_source_id    integer NOT NULL REFERENCES session_caisse(id),
  operation_sortie_id  bigint REFERENCES operation_caisse(id),
  envoye_par           integer REFERENCES utilisateur(id),
  envoye_le            timestamptz NOT NULL DEFAULT now(),
  session_dest_id      integer REFERENCES session_caisse(id),
  operation_entree_id  bigint REFERENCES operation_caisse(id),
  montant_recu         numeric(14,0) CHECK (montant_recu IS NULL OR montant_recu >= 0),
  ecart                numeric(14,0),
  commentaire_reception text,
  recu_par             integer REFERENCES utilisateur(id),
  recu_le              timestamptz,
  operation_retour_id  bigint REFERENCES operation_caisse(id),
  CHECK (caisse_source_id <> caisse_dest_id)
);
CREATE INDEX transfert_fonds_statut_idx ON transfert_fonds(statut, caisse_dest_id);
COMMENT ON TABLE transfert_fonds IS 'Transfert de fonds entre caisses en deux temps : envoi (fonds en transit) puis réception confirmée ou refus.';

CREATE FUNCTION trg_transfert_fonds_regles() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF TG_OP = 'DELETE' THEN RAISE EXCEPTION 'Un transfert de fonds ne se supprime pas'; END IF;
  IF OLD.statut <> 'envoye' THEN RAISE EXCEPTION 'Un transfert réceptionné ou refusé ne se modifie plus'; END IF;
  IF (NEW.caisse_source_id, NEW.caisse_dest_id, NEW.montant, NEW.envoye_par, NEW.reference) IS DISTINCT FROM (OLD.caisse_source_id, OLD.caisse_dest_id, OLD.montant, OLD.envoye_par, OLD.reference) THEN
    RAISE EXCEPTION 'Le contenu d''un transfert envoyé ne se modifie pas';
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER transfert_fonds_regles BEFORE UPDATE OR DELETE ON transfert_fonds FOR EACH ROW EXECUTE FUNCTION trg_transfert_fonds_regles();
CREATE TRIGGER audit_transfert_fonds AFTER INSERT OR UPDATE ON transfert_fonds FOR EACH ROW EXECUTE FUNCTION trg_audit();

CREATE FUNCTION envoyer_fonds(p_session_source integer, p_caisse_dest integer, p_montant numeric, p_motif text, p_utilisateur integer,
                              p_date date DEFAULT current_date) RETURNS integer LANGUAGE plpgsql AS $$
DECLARE s mf.session_caisse; k1 mf.caisse; k2 mf.caisse; v_id integer; v_op bigint;
BEGIN
  IF p_montant IS NULL OR p_montant <= 0 THEN RAISE EXCEPTION 'Montant invalide'; END IF;
  SELECT * INTO s FROM mf.session_caisse WHERE id = p_session_source;
  IF s.id IS NULL OR s.statut <> 'ouverte' THEN RAISE EXCEPTION 'La session de caisse d''envoi doit être ouverte'; END IF;
  SELECT * INTO k1 FROM mf.caisse WHERE id = s.caisse_id;
  SELECT * INTO k2 FROM mf.caisse WHERE id = p_caisse_dest AND actif;
  IF k2.id IS NULL THEN RAISE EXCEPTION 'Caisse destinataire inconnue ou inactive'; END IF;
  IF k1.id = k2.id THEN RAISE EXCEPTION 'La caisse source et la caisse destinataire doivent différer'; END IF;
  v_id := nextval(pg_get_serial_sequence('mf.transfert_fonds', 'id'));
  INSERT INTO mf.transfert_fonds(id, reference, caisse_source_id, caisse_dest_id, montant, motif, date_envoi, session_source_id, envoye_par)
    VALUES (v_id, 'TF-' || lpad(v_id::text, 8, '0'), k1.id, k2.id, p_montant, p_motif, p_date, s.id, p_utilisateur);
  v_op := mf.caisse_operation(s.id, 'decaissement', 'transfert_fonds_envoi', p_montant, p_date, 'transfert_fonds', v_id,
                              'Envoi de fonds vers ' || k2.code || COALESCE(' : ' || p_motif, ''));
  UPDATE mf.transfert_fonds SET operation_sortie_id = v_op WHERE id = v_id;
  IF mf.comptabilisation_active(k1.agence_id) THEN
    PERFORM mf.comptabiliser('transfert_fonds_envoi', k1.agence_id, p_date, jsonb_build_object('montant', p_montant), 'transfert_fonds', v_id, 'Envoi de fonds vers ' || k2.code);
  END IF;
  RETURN v_id;
END $$;

CREATE FUNCTION recevoir_fonds(p_id integer, p_session_dest integer, p_montant_recu numeric, p_utilisateur integer, p_commentaire text DEFAULT NULL,
                               p_date date DEFAULT current_date) RETURNS numeric LANGUAGE plpgsql AS $$
DECLARE t mf.transfert_fonds; s mf.session_caisse; k mf.caisse; v_ecart numeric; v_op bigint;
BEGIN
  SELECT * INTO t FROM mf.transfert_fonds WHERE id = p_id FOR UPDATE;
  IF t.id IS NULL THEN RAISE EXCEPTION 'Transfert % introuvable', p_id; END IF;
  IF t.statut <> 'envoye' THEN RAISE EXCEPTION 'Ce transfert est déjà %', t.statut; END IF;
  IF t.envoye_par IS NOT DISTINCT FROM p_utilisateur THEN RAISE EXCEPTION 'Séparation des tâches : on ne réceptionne pas ses propres fonds'; END IF;
  SELECT * INTO s FROM mf.session_caisse WHERE id = p_session_dest;
  IF s.id IS NULL OR s.statut <> 'ouverte' OR s.caisse_id <> t.caisse_dest_id THEN RAISE EXCEPTION 'La réception exige une session ouverte de la caisse destinataire'; END IF;
  IF p_montant_recu IS NULL OR p_montant_recu < 0 THEN RAISE EXCEPTION 'Montant reçu invalide'; END IF;
  v_ecart := p_montant_recu - t.montant;
  IF v_ecart <> 0 AND length(btrim(COALESCE(p_commentaire, ''))) < 5 THEN RAISE EXCEPTION 'Un écart de réception (% F) doit être expliqué', v_ecart; END IF;
  SELECT * INTO k FROM mf.caisse WHERE id = t.caisse_dest_id;
  IF p_montant_recu > 0 THEN
    v_op := mf.caisse_operation(s.id, 'encaissement', 'transfert_fonds_reception', p_montant_recu, p_date, 'transfert_fonds', t.id,
                                'Réception de fonds ' || t.reference);
  END IF;
  UPDATE mf.transfert_fonds SET statut = 'recu', session_dest_id = s.id, operation_entree_id = v_op, montant_recu = p_montant_recu, ecart = v_ecart,
         commentaire_reception = p_commentaire, recu_par = p_utilisateur, recu_le = now() WHERE id = t.id;
  IF mf.comptabilisation_active(k.agence_id) THEN
    PERFORM mf.comptabiliser('transfert_fonds_reception', k.agence_id, p_date,
                             jsonb_build_object('montant_recu', p_montant_recu, 'manque', GREATEST(-v_ecart, 0), 'surplus', GREATEST(v_ecart, 0)),
                             'transfert_fonds', t.id, 'Réception de fonds ' || t.reference);
  END IF;
  RETURN v_ecart;
END $$;

CREATE FUNCTION refuser_fonds(p_id integer, p_session_retour integer, p_utilisateur integer, p_motif text, p_date date DEFAULT current_date) RETURNS void
LANGUAGE plpgsql AS $$
DECLARE t mf.transfert_fonds; s mf.session_caisse; k mf.caisse; v_op bigint;
BEGIN
  SELECT * INTO t FROM mf.transfert_fonds WHERE id = p_id FOR UPDATE;
  IF t.id IS NULL THEN RAISE EXCEPTION 'Transfert % introuvable', p_id; END IF;
  IF t.statut <> 'envoye' THEN RAISE EXCEPTION 'Ce transfert est déjà %', t.statut; END IF;
  IF t.envoye_par IS NOT DISTINCT FROM p_utilisateur THEN RAISE EXCEPTION 'Séparation des tâches : on ne refuse pas son propre transfert'; END IF;
  IF length(btrim(COALESCE(p_motif, ''))) < 5 THEN RAISE EXCEPTION 'Un refus doit être motivé'; END IF;
  SELECT * INTO s FROM mf.session_caisse WHERE id = p_session_retour;
  IF s.id IS NULL OR s.statut <> 'ouverte' OR s.caisse_id <> t.caisse_source_id THEN RAISE EXCEPTION 'Le retour exige une session ouverte de la caisse d''origine'; END IF;
  v_op := mf.caisse_operation(s.id, 'encaissement', 'transfert_fonds_retour', t.montant, p_date, 'transfert_fonds', t.id, 'Retour de fonds refusés ' || t.reference);
  UPDATE mf.transfert_fonds SET statut = 'refuse', commentaire_reception = p_motif, recu_par = p_utilisateur, recu_le = now(), operation_retour_id = v_op WHERE id = t.id;
  SELECT * INTO k FROM mf.caisse WHERE id = t.caisse_source_id;
  IF mf.comptabilisation_active(k.agence_id) THEN
    PERFORM mf.comptabiliser('transfert_fonds_retour', k.agence_id, p_date, jsonb_build_object('montant', t.montant), 'transfert_fonds', t.id, 'Retour de fonds ' || t.reference);
  END IF;
END $$;

CREATE VIEW v_transfert_fonds AS
SELECT t.*, k1.code AS caisse_source, k1.agence_id AS agence_source_id, k2.code AS caisse_dest, k2.agence_id AS agence_dest_id,
       ue.nom AS envoye_par_nom, ur.nom AS recu_par_nom,
       (t.statut = 'envoye' AND t.envoye_le < now() - make_interval(hours => COALESCE(mf.param_num('transfert_fonds_delai_alerte_heures', k1.agence_id), 24)::int)) AS en_retard
FROM mf.transfert_fonds t
JOIN mf.caisse k1 ON k1.id = t.caisse_source_id
JOIN mf.caisse k2 ON k2.id = t.caisse_dest_id
LEFT JOIN mf.utilisateur ue ON ue.id = t.envoye_par
LEFT JOIN mf.utilisateur ur ON ur.id = t.recu_par;

-- fonds en transit : envoyés, pas encore réceptionnés
CREATE VIEW v_fonds_en_transit AS
SELECT agence_source_id AS agence_id, count(*) AS nb, sum(montant)::numeric(14,0) AS montant, bool_or(en_retard) AS en_retard
FROM mf.v_transfert_fonds WHERE statut = 'envoye' GROUP BY agence_source_id;

