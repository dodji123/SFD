-- =====================================================================
-- 13_tresorerie.sql
-- Caisses multiples et trésorerie :
--   * ouverture de session avec continuité (le solde d'ouverture doit égaler le solde compté à la fermeture
--     précédente, sinon l'écart est tracé) ;
--   * transferts entre caisses d'une agence (approvisionnement d'un guichet depuis le coffre, etc.) ;
--   * comptes bancaires de l'agence : versements et retraits liés à une session de caisse, autres mouvements,
--     rapprochement ;
--   * état des caisses d'un jour, position de trésorerie, prévision par tranches.
-- Dépend de : 00, 03 (caisse), 05 (règles comptables), 10 (comptabilisation).
-- =====================================================================
SET search_path = mf, public;

ALTER TABLE caisse
  ADD COLUMN libelle        text,
  ADD COLUMN responsable_id integer REFERENCES utilisateur(id),
  ADD COLUMN plafond        numeric(14,0) CHECK (plafond IS NULL OR plafond >= 0);   -- au-delà : à reverser en banque ou au coffre

ALTER TABLE session_caisse
  ADD COLUMN ecart_ouverture numeric(14,0) NOT NULL DEFAULT 0;   -- solde d'ouverture - solde compté à la fermeture précédente

-- ---------------------------------------------------------------------
-- Ouverture de session : une seule session ouverte par caisse, jours strictement croissants,
-- solde d'ouverture = solde compté la veille (sinon refus, sauf p_accepter_ecart : l'écart est alors tracé).
-- La première session d'une caisse fixe librement son fonds de départ.
-- ---------------------------------------------------------------------
CREATE FUNCTION ouvrir_session_caisse(p_caisse integer, p_date date, p_solde_compte numeric,
                                      p_billetage jsonb DEFAULT NULL, p_utilisateur integer DEFAULT NULL,
                                      p_accepter_ecart boolean DEFAULT false) RETURNS integer
LANGUAGE plpgsql AS $$
DECLARE k mf.caisse; prev mf.session_caisse; v_ecart numeric := 0; v_id integer;
BEGIN
  SELECT * INTO k FROM mf.caisse WHERE id = p_caisse FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'caisse % inconnue', p_caisse; END IF;
  IF NOT k.actif THEN RAISE EXCEPTION 'la caisse % est désactivée', k.code; END IF;
  IF p_solde_compte < 0 THEN RAISE EXCEPTION 'solde d''ouverture négatif'; END IF;
  SELECT * INTO prev FROM mf.session_caisse WHERE caisse_id = p_caisse AND statut = 'ouverte' LIMIT 1;
  IF FOUND THEN
    RAISE EXCEPTION 'la caisse % a déjà une session ouverte (jour %) : la fermer d''abord', k.code, prev.date_session;
  END IF;
  SELECT * INTO prev FROM mf.session_caisse WHERE caisse_id = p_caisse ORDER BY date_session DESC LIMIT 1;
  IF FOUND THEN
    IF p_date <= prev.date_session THEN
      RAISE EXCEPTION 'la caisse % a déjà une session au % : ouvrir à une date postérieure', k.code, prev.date_session;
    END IF;
    v_ecart := p_solde_compte - COALESCE(prev.solde_compte, 0);
    IF v_ecart <> 0 AND NOT p_accepter_ecart THEN
      RAISE EXCEPTION 'le solde d''ouverture (%) diffère du solde compté à la fermeture du % (%) : écart de %',
        p_solde_compte, prev.date_session, prev.solde_compte, v_ecart;
    END IF;
  END IF;
  INSERT INTO mf.session_caisse(caisse_id, date_session, solde_ouverture, billetage_ouverture, utilisateur_id, ecart_ouverture)
  VALUES (p_caisse, p_date, p_solde_compte, p_billetage, p_utilisateur, v_ecart)
  RETURNING id INTO v_id;
  RETURN v_id;
END $$;

-- ---------------------------------------------------------------------
-- Transferts entre caisses d'une même agence (les deux sessions doivent être ouvertes)
-- ---------------------------------------------------------------------
CREATE TABLE transfert_caisse (
  id              serial PRIMARY KEY,
  agence_id       smallint NOT NULL REFERENCES agence(id),
  session_source  integer NOT NULL REFERENCES session_caisse(id),
  session_dest    integer NOT NULL REFERENCES session_caisse(id),
  montant         numeric(14,0) NOT NULL CHECK (montant > 0),
  date_operation  date NOT NULL,
  motif           text,
  utilisateur_id  integer REFERENCES utilisateur(id),
  cree_le         timestamptz NOT NULL DEFAULT now(),
  CHECK (session_source <> session_dest)
);
CREATE INDEX transfert_caisse_date ON transfert_caisse (agence_id, date_operation);

CREATE FUNCTION transferer_entre_caisses(p_source integer, p_dest integer, p_montant numeric,
                                         p_date date DEFAULT current_date, p_motif text DEFAULT NULL,
                                         p_utilisateur integer DEFAULT NULL) RETURNS integer
LANGUAGE plpgsql AS $$
DECLARE s1 mf.session_caisse; s2 mf.session_caisse; k1 mf.caisse; k2 mf.caisse; v_id integer;
BEGIN
  IF p_source = p_dest THEN RAISE EXCEPTION 'la caisse source et la caisse destinataire doivent différer'; END IF;
  IF p_montant <= 0 THEN RAISE EXCEPTION 'montant invalide'; END IF;
  -- verrou dans l'ordre des identifiants : pas d'interblocage entre deux transferts croisés
  PERFORM 1 FROM mf.session_caisse WHERE id IN (p_source, p_dest) ORDER BY id FOR UPDATE;
  SELECT * INTO s1 FROM mf.session_caisse WHERE id = p_source;
  SELECT * INTO s2 FROM mf.session_caisse WHERE id = p_dest;
  IF s1.id IS NULL OR s2.id IS NULL THEN RAISE EXCEPTION 'session de caisse inconnue'; END IF;
  IF s1.statut <> 'ouverte' OR s2.statut <> 'ouverte' THEN RAISE EXCEPTION 'les deux sessions doivent être ouvertes'; END IF;
  SELECT * INTO k1 FROM mf.caisse WHERE id = s1.caisse_id;
  SELECT * INTO k2 FROM mf.caisse WHERE id = s2.caisse_id;
  IF k1.agence_id <> k2.agence_id THEN RAISE EXCEPTION 'un transfert de caisse reste dans la même agence'; END IF;
  INSERT INTO mf.transfert_caisse(agence_id, session_source, session_dest, montant, date_operation, motif, utilisateur_id)
  VALUES (k1.agence_id, p_source, p_dest, p_montant, p_date, p_motif, p_utilisateur) RETURNING id INTO v_id;
  PERFORM mf.caisse_operation(p_source, 'decaissement', 'transfert_sortant', p_montant, p_date, 'transfert_caisse', v_id,
                              'Transfert vers ' || k2.code || COALESCE(' : ' || p_motif, ''));
  PERFORM mf.caisse_operation(p_dest, 'encaissement', 'transfert_entrant', p_montant, p_date, 'transfert_caisse', v_id,
                              'Transfert depuis ' || k1.code || COALESCE(' : ' || p_motif, ''));
  RETURN v_id;
END $$;

-- ---------------------------------------------------------------------
-- Comptes bancaires de l'agence
-- ---------------------------------------------------------------------
CREATE TABLE compte_banque (
  id            serial PRIMARY KEY,
  agence_id     smallint NOT NULL REFERENCES agence(id),
  code          varchar(10) NOT NULL,
  libelle       text NOT NULL,
  banque        text,
  numero_compte text,
  actif         boolean NOT NULL DEFAULT true,
  UNIQUE (agence_id, code)
);

CREATE TABLE mouvement_banque (
  id              bigserial PRIMARY KEY,
  compte_banque_id integer NOT NULL REFERENCES compte_banque(id),
  date_operation  date NOT NULL,
  type            varchar(20) NOT NULL CHECK (type IN
                    ('versement_caisse','retrait_caisse','depot_externe','retrait_externe','frais','interets')),
  montant         numeric(14,0) NOT NULL CHECK (montant > 0),
  libelle         text,
  reference_table text,
  reference_id    bigint,
  rapproche       boolean NOT NULL DEFAULT false,      -- pointé sur le relevé de la banque
  rapproche_le    date,
  utilisateur_id  integer REFERENCES utilisateur(id),
  cree_le         timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX mouvement_banque_compte ON mouvement_banque (compte_banque_id, date_operation);

CREATE FUNCTION sens_mouvement_banque(p_type text) RETURNS smallint
LANGUAGE sql IMMUTABLE AS $$
  SELECT CASE WHEN p_type IN ('versement_caisse','depot_externe','interets') THEN 1 ELSE -1 END::smallint
$$;

CREATE VIEW v_solde_compte_banque AS
SELECT b.id AS compte_banque_id, b.agence_id, b.code, b.libelle,
       COALESCE(sum(m.montant * mf.sens_mouvement_banque(m.type)), 0)::numeric(14,0) AS solde
  FROM compte_banque b LEFT JOIN mouvement_banque m ON m.compte_banque_id = b.id
 GROUP BY b.id;

-- Pas de découvert : une sortie ne peut dépasser le solde (verrou sur le compte contre deux sorties simultanées).
CREATE FUNCTION trg_mouvement_banque_controle() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE b mf.compte_banque; v_solde numeric;
BEGIN
  SELECT * INTO b FROM mf.compte_banque WHERE id = NEW.compte_banque_id FOR UPDATE;
  IF NOT b.actif THEN RAISE EXCEPTION 'compte bancaire % désactivé', b.code; END IF;
  IF mf.sens_mouvement_banque(NEW.type) < 0 THEN
    SELECT solde INTO v_solde FROM mf.v_solde_compte_banque WHERE compte_banque_id = NEW.compte_banque_id;
    IF NEW.montant > v_solde THEN
      RAISE EXCEPTION 'solde bancaire insuffisant sur % : % demandé, % disponible', b.code, NEW.montant, v_solde;
    END IF;
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER mouvement_banque_controle BEFORE INSERT ON mouvement_banque
  FOR EACH ROW EXECUTE FUNCTION trg_mouvement_banque_controle();

-- Versement de la caisse en banque : décaissement de caisse + entrée en banque.
CREATE FUNCTION versement_en_banque(p_session integer, p_compte_banque integer, p_montant numeric,
                                    p_date date DEFAULT current_date, p_libelle text DEFAULT NULL,
                                    p_utilisateur integer DEFAULT NULL) RETURNS bigint
LANGUAGE plpgsql AS $$
DECLARE k mf.caisse; b mf.compte_banque; v_op bigint; v_id bigint;
BEGIN
  SELECT c.* INTO k FROM mf.caisse c JOIN mf.session_caisse s ON s.caisse_id = c.id WHERE s.id = p_session;
  IF NOT FOUND THEN RAISE EXCEPTION 'session de caisse % inconnue', p_session; END IF;
  SELECT * INTO b FROM mf.compte_banque WHERE id = p_compte_banque;
  IF NOT FOUND THEN RAISE EXCEPTION 'compte bancaire % inconnu', p_compte_banque; END IF;
  IF b.agence_id <> k.agence_id THEN RAISE EXCEPTION 'la caisse et le compte bancaire sont d''agences différentes'; END IF;
  v_op := mf.caisse_operation(p_session, 'decaissement', 'versement_banque', p_montant, p_date, 'compte_banque', p_compte_banque,
                              COALESCE(p_libelle, 'Versement en banque ' || b.code));
  INSERT INTO mf.mouvement_banque(compte_banque_id, date_operation, type, montant, libelle, reference_table, reference_id, utilisateur_id)
  VALUES (p_compte_banque, p_date, 'versement_caisse', p_montant, COALESCE(p_libelle, 'Versement depuis la caisse ' || k.code),
          'operation_caisse', v_op, p_utilisateur) RETURNING id INTO v_id;
  RETURN v_id;
END $$;

-- Retrait en banque alimentant la caisse : sortie de banque (solde contrôlé) + encaissement de caisse.
CREATE FUNCTION retrait_en_banque(p_session integer, p_compte_banque integer, p_montant numeric,
                                  p_date date DEFAULT current_date, p_libelle text DEFAULT NULL,
                                  p_utilisateur integer DEFAULT NULL) RETURNS bigint
LANGUAGE plpgsql AS $$
DECLARE k mf.caisse; b mf.compte_banque; v_op bigint; v_id bigint;
BEGIN
  SELECT c.* INTO k FROM mf.caisse c JOIN mf.session_caisse s ON s.caisse_id = c.id WHERE s.id = p_session;
  IF NOT FOUND THEN RAISE EXCEPTION 'session de caisse % inconnue', p_session; END IF;
  SELECT * INTO b FROM mf.compte_banque WHERE id = p_compte_banque;
  IF NOT FOUND THEN RAISE EXCEPTION 'compte bancaire % inconnu', p_compte_banque; END IF;
  IF b.agence_id <> k.agence_id THEN RAISE EXCEPTION 'la caisse et le compte bancaire sont d''agences différentes'; END IF;
  INSERT INTO mf.mouvement_banque(compte_banque_id, date_operation, type, montant, libelle, utilisateur_id)
  VALUES (p_compte_banque, p_date, 'retrait_caisse', p_montant, COALESCE(p_libelle, 'Retrait pour la caisse ' || k.code), p_utilisateur)
  RETURNING id INTO v_id;
  v_op := mf.caisse_operation(p_session, 'encaissement', 'retrait_banque', p_montant, p_date, 'compte_banque', p_compte_banque,
                              COALESCE(p_libelle, 'Retrait en banque ' || b.code));
  UPDATE mf.mouvement_banque SET reference_table = 'operation_caisse', reference_id = v_op WHERE id = v_id;
  RETURN v_id;
END $$;

-- Pointage d'un mouvement sur le relevé de la banque.
CREATE FUNCTION rapprocher_mouvement_banque(p_mouvement bigint, p_date date DEFAULT current_date, p_rapproche boolean DEFAULT true)
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  UPDATE mf.mouvement_banque SET rapproche = p_rapproche, rapproche_le = CASE WHEN p_rapproche THEN p_date END WHERE id = p_mouvement;
  IF NOT FOUND THEN RAISE EXCEPTION 'mouvement bancaire % inconnu', p_mouvement; END IF;
END $$;

-- ---------------------------------------------------------------------
-- États : caisses d'un jour, liquidités, indicateurs, prévision
-- ---------------------------------------------------------------------
-- Solde théorique d'une session à une date : ouverture + opérations datées au plus tard ce jour.
CREATE FUNCTION solde_session_a_date(p_session integer, p_date date) RETURNS numeric
LANGUAGE sql STABLE AS $$
  SELECT s.solde_ouverture
         + COALESCE((SELECT sum(CASE o.type WHEN 'encaissement' THEN o.montant ELSE -o.montant END)
                       FROM mf.operation_caisse o WHERE o.session_id = s.id AND o.date_operation <= p_date), 0)
    FROM mf.session_caisse s WHERE s.id = p_session
$$;

-- État de chaque caisse active : non ouverte / ouverte / fermée à la date, solde, dépassement du plafond.
CREATE FUNCTION etat_caisses(p_agence smallint, p_date date)
RETURNS TABLE (caisse_id integer, code varchar, type varchar, libelle text, responsable text, plafond numeric,
               etat text, session_id integer, solde numeric, depassement_plafond numeric)
LANGUAGE sql STABLE AS $$
  SELECT k.id, k.code, k.type, k.libelle, u.nom::text, k.plafond,
         CASE WHEN s.id IS NULL THEN 'non_ouverte' WHEN s.statut = 'ouverte' THEN 'ouverte' ELSE 'fermee' END,
         s.id,
         CASE WHEN s.id IS NULL THEN dernier.solde
              WHEN s.statut = 'fermee' THEN s.solde_compte
              ELSE mf.solde_session_a_date(s.id, p_date) END,
         CASE WHEN k.plafond IS NULL THEN 0
              ELSE GREATEST(COALESCE(CASE WHEN s.id IS NULL THEN dernier.solde
                                          WHEN s.statut = 'fermee' THEN s.solde_compte
                                          ELSE mf.solde_session_a_date(s.id, p_date) END, 0) - k.plafond, 0) END
    FROM mf.caisse k
    LEFT JOIN mf.utilisateur u ON u.id = k.responsable_id
    LEFT JOIN LATERAL (SELECT * FROM mf.session_caisse x WHERE x.caisse_id = k.id AND x.date_session = p_date LIMIT 1) s ON true
    LEFT JOIN LATERAL (SELECT COALESCE(y.solde_compte, mf.solde_session_a_date(y.id, p_date)) AS solde
                         FROM mf.session_caisse y WHERE y.caisse_id = k.id AND y.date_session < p_date
                        ORDER BY y.date_session DESC LIMIT 1) dernier ON true
   WHERE k.agence_id = p_agence AND k.actif
   ORDER BY k.type, k.code
$$;

-- Liquidités à une date : une ligne par caisse (dernier solde connu) et par compte bancaire.
CREATE FUNCTION tresorerie_liquidites(p_agence smallint, p_date date)
RETURNS TABLE (nature text, code text, libelle text, solde numeric, detail text)
LANGUAGE sql STABLE AS $$
  SELECT 'caisse'::text, e.code::text, COALESCE(e.libelle, e.code)::text, COALESCE(e.solde, 0),
         CASE e.etat WHEN 'ouverte' THEN 'session ouverte' WHEN 'fermee' THEN 'session fermée' ELSE 'non ouverte ce jour (dernier solde connu)' END
    FROM mf.etat_caisses(p_agence, p_date) e
  UNION ALL
  SELECT 'banque', b.code::text, (b.libelle || COALESCE(' — ' || b.banque, ''))::text,
         COALESCE((SELECT sum(m.montant * mf.sens_mouvement_banque(m.type)) FROM mf.mouvement_banque m
                    WHERE m.compte_banque_id = b.id AND m.date_operation <= p_date), 0),
         COALESCE((SELECT count(*)::text || ' mouvement(s) non rapproché(s)' FROM mf.mouvement_banque m
                    WHERE m.compte_banque_id = b.id AND m.date_operation <= p_date AND NOT m.rapproche), '')
    FROM mf.compte_banque b WHERE b.agence_id = p_agence AND b.actif
$$;

-- Indicateurs de trésorerie. Les liquidités et les échéances sont calculées à la date demandée ;
-- les engagements envers les clients et les retraits en attente reflètent l'état au moment de la lecture.
CREATE FUNCTION tresorerie_indicateurs(p_agence smallint, p_date date)
RETURNS TABLE (rubrique text, valeur numeric)
LANGUAGE plpgsql STABLE AS $$
DECLARE v_liq numeric; v_epargne numeric; v_tontine numeric; v_eng numeric;
BEGIN
  SELECT COALESCE(sum(solde), 0) INTO v_liq FROM mf.tresorerie_liquidites(p_agence, p_date);
  SELECT COALESCE(sum(v.solde), 0) INTO v_epargne FROM mf.v_solde_compte_epargne v WHERE v.agence_id = p_agence;
  SELECT COALESCE(sum(s.montant_collecte - COALESCE(r.rembourse, 0)), 0) INTO v_tontine
    FROM mf.v_cycle_situation s
    LEFT JOIN (SELECT cycle_id, sum(montant) rembourse FROM mf.retrait WHERE nature = 'remboursement' AND statut <> 'annule' GROUP BY cycle_id) r
           ON r.cycle_id = s.cycle_id
   WHERE s.agence_id = p_agence AND s.statut <> 'retire';
  v_eng := v_epargne + v_tontine;
  RETURN QUERY VALUES
    ('liquidites_caisses'::text, COALESCE((SELECT sum(solde) FROM mf.tresorerie_liquidites(p_agence, p_date) WHERE nature = 'caisse'), 0)::numeric),
    ('liquidites_banques', COALESCE((SELECT sum(solde) FROM mf.tresorerie_liquidites(p_agence, p_date) WHERE nature = 'banque'), 0)::numeric),
    ('liquidites_totales', v_liq),
    ('depassement_plafonds_caisses', COALESCE((SELECT sum(depassement_plafond) FROM mf.etat_caisses(p_agence, p_date)), 0)::numeric),
    ('echeances_en_retard', COALESCE((SELECT sum(mf.du_echeance_a_date(e.id, p_date)) FROM mf.echeance e JOIN mf.credit c ON c.id = e.credit_id
        WHERE c.agence_id = p_agence AND e.date_prevue < p_date AND mf.du_echeance_a_date(e.id, p_date) > 0), 0)::numeric),
    ('a_recevoir_7_jours', COALESCE((SELECT sum(mf.du_echeance_a_date(e.id, p_date)) FROM mf.echeance e JOIN mf.credit c ON c.id = e.credit_id
        WHERE c.agence_id = p_agence AND e.date_prevue BETWEEN p_date AND p_date + 7 AND mf.du_echeance_a_date(e.id, p_date) > 0), 0)::numeric),
    ('a_recevoir_30_jours', COALESCE((SELECT sum(mf.du_echeance_a_date(e.id, p_date)) FROM mf.echeance e JOIN mf.credit c ON c.id = e.credit_id
        WHERE c.agence_id = p_agence AND e.date_prevue BETWEEN p_date AND p_date + 30 AND mf.du_echeance_a_date(e.id, p_date) > 0), 0)::numeric),
    ('retraits_clients_en_attente', COALESCE((SELECT sum(r.montant) FROM mf.retrait r WHERE r.agence_id = p_agence AND r.decaissement
        AND r.statut IN ('demande','ecart_en_traitement','fonds_disponibles')), 0)::numeric),
    ('commissions_a_payer', COALESCE((SELECT sum(commission_nette) FROM mf.commission_collectrice WHERE agence_id = p_agence AND statut = 'calculee'), 0)::numeric),
    ('epargne_classique', v_epargne),
    ('tontine_a_rembourser', v_tontine),
    ('engagements_clients', v_eng),
    ('ratio_liquidite_pct', CASE WHEN v_eng > 0 THEN round(v_liq * 100 / v_eng, 1) ELSE NULL END);
END $$;

-- Prévision par tranches de p_pas jours sur p_jours jours : encaissements = échéances impayées attendues dans la
-- tranche ; décaissements = retraits clients en attente (première tranche). Les autres flux (salaires, charges,
-- collecte à venir) ne sont pas prévisibles ici.
CREATE FUNCTION prevision_tresorerie(p_agence smallint, p_date date, p_jours integer DEFAULT 30, p_pas integer DEFAULT 7)
RETURNS TABLE (debut date, fin date, encaissements numeric, decaissements numeric, solde_projete numeric)
LANGUAGE plpgsql STABLE AS $$
DECLARE v_solde numeric; t record; v_enc numeric; v_dec numeric;
BEGIN
  IF p_pas < 1 OR p_jours < 1 THEN RAISE EXCEPTION 'paramètres de prévision invalides'; END IF;
  SELECT COALESCE(sum(solde), 0) INTO v_solde FROM mf.tresorerie_liquidites(p_agence, p_date);
  FOR t IN SELECT g AS i FROM generate_series(0, p_jours - 1, p_pas) g LOOP
    debut := p_date + t.i;
    fin := LEAST(p_date + t.i + p_pas - 1, p_date + p_jours - 1);
    SELECT COALESCE(sum(mf.du_echeance_a_date(e.id, p_date)), 0) INTO v_enc
      FROM mf.echeance e JOIN mf.credit c ON c.id = e.credit_id
     WHERE c.agence_id = p_agence AND e.date_prevue BETWEEN debut AND fin AND mf.du_echeance_a_date(e.id, p_date) > 0;
    v_dec := CASE WHEN t.i = 0 THEN
      COALESCE((SELECT sum(r.montant) FROM mf.retrait r WHERE r.agence_id = p_agence AND r.decaissement
                 AND r.statut IN ('demande','ecart_en_traitement','fonds_disponibles')), 0) ELSE 0 END;
    v_solde := v_solde + v_enc - v_dec;
    encaissements := v_enc; decaissements := v_dec; solde_projete := v_solde;
    RETURN NEXT;
  END LOOP;
END $$;

-- ---------------------------------------------------------------------
-- Comptabilisation (désactivée par défaut, voir 10) : versement / retrait en banque et frais bancaires.
-- Compte 1141 « Banques et correspondants » ; frais bancaires en 6081 (à valider par le comptable).
-- Les transferts entre caisses n'ont pas d'effet comptable (même compte 1011).
-- ---------------------------------------------------------------------
INSERT INTO regle_comptable(evenement, ligne, compte_debit, compte_credit, cle_montant, journal_code, libelle) VALUES
  ('versement_banque', 1, '1141', '1011', 'montant', 'CAI', 'Versement de la caisse en banque'),
  ('retrait_banque',   1, '1011', '1141', 'montant', 'CAI', 'Retrait en banque pour la caisse'),
  ('frais_bancaires',  1, '6081', '1141', 'montant', 'CAI', 'Frais bancaires');

CREATE FUNCTION trg_compta_mouvement_banque() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE v_agence smallint; v_evt text;
BEGIN
  v_evt := CASE NEW.type WHEN 'versement_caisse' THEN 'versement_banque' WHEN 'retrait_caisse' THEN 'retrait_banque'
                         WHEN 'frais' THEN 'frais_bancaires' END;
  IF v_evt IS NULL THEN RETURN NULL; END IF;
  SELECT agence_id INTO v_agence FROM mf.compte_banque WHERE id = NEW.compte_banque_id;
  IF mf.comptabilisation_active(v_agence) THEN
    PERFORM mf.comptabiliser(v_evt, v_agence, NEW.date_operation, jsonb_build_object('montant', NEW.montant),
                             'mouvement_banque', NEW.id, NEW.libelle);
  END IF;
  RETURN NULL;
END $$;
CREATE TRIGGER compta_mouvement_banque AFTER INSERT ON mouvement_banque
  FOR EACH ROW EXECUTE FUNCTION trg_compta_mouvement_banque();

-- Piste d'audit
CREATE TRIGGER audit_transfert_caisse AFTER INSERT OR UPDATE OR DELETE ON transfert_caisse FOR EACH ROW EXECUTE FUNCTION trg_audit();
CREATE TRIGGER audit_compte_banque AFTER INSERT OR UPDATE OR DELETE ON compte_banque FOR EACH ROW EXECUTE FUNCTION trg_audit();
CREATE TRIGGER audit_mouvement_banque AFTER INSERT OR UPDATE OR DELETE ON mouvement_banque FOR EACH ROW EXECUTE FUNCTION trg_audit();
CREATE TRIGGER audit_caisse AFTER INSERT OR UPDATE OR DELETE ON caisse FOR EACH ROW EXECUTE FUNCTION trg_audit();
