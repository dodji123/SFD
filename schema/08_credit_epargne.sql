-- =====================================================================
-- 08_credit_epargne.sql
-- Crédit sur épargne classique : produits, demandes, garantie bloquée sur le compte, déblocage
-- (sur compte ou en espèces), prélèvement automatique, saisie de la garantie, remboursement en espèces.
-- Règles : BRIEF_CLAUDE_CODE.md sections 3.4 et 3.6.
--   solde disponible = solde - solde minimum du produit - garanties bloquées (un trigger refuse toute sortie
--   au-delà, voir 01) ; prélèvement : dû complet seulement ; espèces : paiement partiel accepté ;
--   saisie après jours_saisie_garantie de retard ; libération quand le crédit est soldé.
-- Dépend de : 00 à 03, 05 (numérotation).
-- =====================================================================
SET search_path = mf, public;

INSERT INTO parametre(cle, valeur, description) VALUES
  ('seuil_validation_credit', '1000000000',
   'Montant au-delà duquel un validateur est obligatoire pour approuver une demande (PROVISOIRE : pratiquement désactivé)');

CREATE TABLE produit_credit_epargne (
  id                 serial PRIMARY KEY,
  code               varchar(10) NOT NULL UNIQUE,
  libelle            text NOT NULL,
  type               varchar(15) NOT NULL CHECK (type IN ('sur_epargne','sans_epargne')),
  taux_annuel        numeric(7,5) NOT NULL CHECK (taux_annuel >= 0),
  frais_dossier_taux numeric(7,5) NOT NULL DEFAULT 0 CHECK (frais_dossier_taux >= 0),
  periodicite_jours  smallint NOT NULL DEFAULT 30 CHECK (periodicite_jours > 0),
  methode            varchar(20) NOT NULL DEFAULT 'capital_constant' CHECK (methode IN ('capital_constant','annuite_constante')),
  actif              boolean NOT NULL DEFAULT true
);

CREATE TABLE demande_credit (
  id               serial PRIMARY KEY,
  agence_id        smallint NOT NULL REFERENCES agence(id),
  numero           varchar(25) NOT NULL,
  client_id        integer NOT NULL REFERENCES client(id),
  produit_id       integer NOT NULL REFERENCES produit_credit_epargne(id),
  compte_id        integer REFERENCES compte_epargne(id),
  cycle_id         integer REFERENCES cycle(id),
  montant          numeric(14,0) NOT NULL CHECK (montant > 0),
  nb_echeances     smallint NOT NULL CHECK (nb_echeances > 0),
  taux             numeric(7,5) NOT NULL CHECK (taux >= 0),
  garantie_montant numeric(14,0) NOT NULL DEFAULT 0 CHECK (garantie_montant >= 0),  -- négociée, sans plafond
  mode_remboursement varchar(20) NOT NULL CHECK (mode_remboursement IN ('tontine','prelevement_compte','especes')),
  note             text,
  statut           varchar(10) NOT NULL DEFAULT 'demandee' CHECK (statut IN ('demandee','approuvee','refusee','debloquee')),
  date_demande     date NOT NULL DEFAULT current_date,
  date_decision    date,
  validateur_id    integer REFERENCES utilisateur(id),
  commentaire      text,
  credit_id        integer REFERENCES credit(id),
  cree_le          timestamptz NOT NULL DEFAULT now(),
  UNIQUE (agence_id, numero)
);
CREATE TRIGGER demande_credit_numero BEFORE INSERT ON demande_credit FOR EACH ROW EXECUTE FUNCTION trg_numerotation('DC');

-- Garantie bloquée sur un compte d'épargne classique.
CREATE TABLE garantie_compte (
  id              serial PRIMARY KEY,
  credit_id       integer NOT NULL UNIQUE REFERENCES credit(id),
  compte_id       integer NOT NULL REFERENCES compte_epargne(id),
  montant_bloque  numeric(14,0) NOT NULL CHECK (montant_bloque > 0),
  montant_saisi   numeric(14,0) NOT NULL DEFAULT 0,
  montant_restant numeric(14,0) NOT NULL,            -- encore bloqué
  statut          varchar(10) NOT NULL DEFAULT 'bloquee' CHECK (statut IN ('bloquee','liberee')),
  libere_le       date,
  cree_le         timestamptz NOT NULL DEFAULT now(),
  CHECK (montant_saisi >= 0 AND montant_restant >= 0 AND montant_saisi + montant_restant <= montant_bloque)
);
CREATE INDEX garantie_compte_compte ON garantie_compte (compte_id) WHERE statut = 'bloquee';

-- Solde disponible = solde - solde minimum du produit - garanties bloquées.
CREATE OR REPLACE FUNCTION solde_disponible(p_compte integer) RETURNS numeric
LANGUAGE sql STABLE AS $$
  SELECT GREATEST(v.solde - p.solde_minimum
                  - COALESCE((SELECT sum(g.montant_restant) FROM mf.garantie_compte g
                               WHERE g.compte_id = p_compte AND g.statut = 'bloquee'), 0), 0)
    FROM mf.v_solde_compte_epargne v
    JOIN mf.compte_epargne c ON c.id = v.compte_id
    JOIN mf.produit_epargne p ON p.id = c.produit_id
   WHERE v.compte_id = p_compte
$$;

-- ---------------------------------------------------------------------
-- Demande, décision, déblocage
-- ---------------------------------------------------------------------
-- Montant, taux, frais et garantie sont négociés (pas de plafond en pourcentage). Un crédit sur épargne exige
-- une garantie (compte classique, ou cycle de tontine) ; mode « tontine » : cycle obligatoire ;
-- « prélèvement » : compte obligatoire.
CREATE FUNCTION nouvelle_demande_credit(p_client integer, p_compte integer, p_produit integer, p_montant numeric,
                                        p_nb_echeances integer, p_taux numeric DEFAULT NULL,
                                        p_garantie numeric DEFAULT 0, p_mode text DEFAULT 'prelevement_compte',
                                        p_note text DEFAULT NULL, p_cycle integer DEFAULT NULL) RETURNS integer
LANGUAGE plpgsql AS $$
DECLARE cl mf.client; pr mf.produit_credit_epargne; ce mf.compte_epargne; cy mf.cycle; v_id integer;
BEGIN
  SELECT * INTO cl FROM mf.client WHERE id = p_client;
  IF NOT FOUND THEN RAISE EXCEPTION 'client % inconnu', p_client; END IF;
  SELECT * INTO pr FROM mf.produit_credit_epargne WHERE id = p_produit AND actif;
  IF NOT FOUND THEN RAISE EXCEPTION 'produit de crédit % inconnu ou inactif', p_produit; END IF;
  IF p_montant <= 0 OR p_nb_echeances <= 0 THEN RAISE EXCEPTION 'montant ou nombre d''échéances invalide'; END IF;
  IF p_mode NOT IN ('tontine','prelevement_compte','especes') THEN RAISE EXCEPTION 'mode de remboursement inconnu : %', p_mode; END IF;

  IF p_compte IS NOT NULL THEN
    SELECT * INTO ce FROM mf.compte_epargne WHERE id = p_compte;
    IF NOT FOUND OR ce.client_id <> p_client THEN RAISE EXCEPTION 'le compte % n''appartient pas au client %', p_compte, cl.numero; END IF;
    IF ce.statut <> 'actif' THEN RAISE EXCEPTION 'compte % non actif', ce.numero; END IF;
  END IF;
  IF p_cycle IS NOT NULL THEN
    SELECT * INTO cy FROM mf.cycle WHERE id = p_cycle;
    IF NOT FOUND OR cy.client_id <> p_client THEN RAISE EXCEPTION 'le cycle % n''appartient pas au client %', p_cycle, cl.numero; END IF;
    IF cy.statut <> 'en_cours' THEN RAISE EXCEPTION 'cycle % non en cours', cy.numero; END IF;
  END IF;
  IF pr.type = 'sur_epargne' THEN
    IF COALESCE(p_garantie, 0) <= 0 THEN RAISE EXCEPTION 'un crédit sur épargne exige une garantie'; END IF;
    IF p_compte IS NULL AND p_cycle IS NULL THEN RAISE EXCEPTION 'un crédit sur épargne exige un compte ou un cycle en garantie'; END IF;
  END IF;
  IF p_mode = 'tontine' AND p_cycle IS NULL THEN RAISE EXCEPTION 'le remboursement sur tontine exige un cycle'; END IF;
  IF p_mode = 'prelevement_compte' AND p_compte IS NULL THEN RAISE EXCEPTION 'le prélèvement exige un compte'; END IF;

  INSERT INTO mf.demande_credit(agence_id, numero, client_id, produit_id, compte_id, cycle_id, montant, nb_echeances,
                                taux, garantie_montant, mode_remboursement, note)
  VALUES (cl.agence_id, NULL, p_client, p_produit, p_compte, p_cycle, p_montant, p_nb_echeances,
          COALESCE(p_taux, pr.taux_annuel), COALESCE(p_garantie, 0), p_mode, p_note)
  RETURNING id INTO v_id;
  RETURN v_id;
END $$;

CREATE FUNCTION approuver_demande(p_demande integer, p_validateur integer DEFAULT NULL,
                                  p_approuve boolean DEFAULT true, p_commentaire text DEFAULT NULL,
                                  p_date date DEFAULT current_date) RETURNS void
LANGUAGE plpgsql AS $$
DECLARE d mf.demande_credit;
BEGIN
  SELECT * INTO d FROM mf.demande_credit WHERE id = p_demande FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'demande % inconnue', p_demande; END IF;
  IF d.statut <> 'demandee' THEN RAISE EXCEPTION 'demande % déjà traitée (statut %)', d.numero, d.statut; END IF;
  IF p_approuve AND p_validateur IS NULL AND d.montant > mf.param_num('seuil_validation_credit', d.agence_id) THEN
    RAISE EXCEPTION 'la demande % dépasse le seuil de validation : un validateur est obligatoire', d.numero;
  END IF;
  UPDATE mf.demande_credit
     SET statut = CASE WHEN p_approuve THEN 'approuvee' ELSE 'refusee' END,
         validateur_id = p_validateur, commentaire = p_commentaire, date_decision = p_date
   WHERE id = p_demande;
END $$;

-- Déblocage : crée le crédit et son échéancier, bloque la garantie sur compte, décaisse sur le compte
-- (mode 'compte') ou en espèces (mode 'especes', session de caisse obligatoire). Frais de dossier :
-- débités du compte, ou encaissés en caisse. Retourne l'id du crédit.
CREATE FUNCTION debloquer_credit(p_demande integer, p_date date DEFAULT current_date, p_mode text DEFAULT 'compte',
                                 p_session integer DEFAULT NULL, p_utilisateur integer DEFAULT NULL) RETURNS integer
LANGUAGE plpgsql AS $$
DECLARE d mf.demande_credit; pr mf.produit_credit_epargne; v_frais numeric; v_credit integer;
        v_gtype text; v_cycle integer; v_compte integer;
BEGIN
  SELECT * INTO d FROM mf.demande_credit WHERE id = p_demande FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'demande % inconnue', p_demande; END IF;
  IF d.statut <> 'approuvee' THEN RAISE EXCEPTION 'demande % non approuvée (statut %)', d.numero, d.statut; END IF;
  IF p_mode NOT IN ('compte','especes') THEN RAISE EXCEPTION 'mode de décaissement inconnu : %', p_mode; END IF;
  IF p_mode = 'compte' AND d.compte_id IS NULL THEN RAISE EXCEPTION 'décaissement sur compte : aucun compte sur la demande'; END IF;
  IF p_mode = 'especes' AND p_session IS NULL THEN RAISE EXCEPTION 'décaissement en espèces : session de caisse obligatoire'; END IF;
  SELECT * INTO pr FROM mf.produit_credit_epargne WHERE id = d.produit_id;
  v_frais := round(d.montant * pr.frais_dossier_taux);

  v_gtype := CASE WHEN pr.type <> 'sur_epargne' THEN 'aucune' WHEN d.cycle_id IS NOT NULL THEN 'cycle' ELSE 'compte' END;
  -- une garantie sur compte doit être couverte par le disponible
  IF v_gtype = 'compte' AND d.garantie_montant > mf.solde_disponible(d.compte_id) THEN
    RAISE EXCEPTION 'garantie % supérieure au solde disponible % du compte', d.garantie_montant, mf.solde_disponible(d.compte_id);
  END IF;

  INSERT INTO mf.credit(agence_id, numero, client_id, type, montant_accorde, taux, frais_dossier, date_deblocage,
                        nb_echeances, periodicite_jours, methode, mode_remboursement, garantie_type,
                        cycle_garantie_id, compte_id)
  VALUES (d.agence_id, NULL, d.client_id, pr.type, d.montant, d.taux, v_frais, p_date, d.nb_echeances,
          pr.periodicite_jours, pr.methode, d.mode_remboursement, v_gtype,
          CASE WHEN v_gtype = 'cycle' THEN d.cycle_id END, d.compte_id)
  RETURNING id INTO v_credit;
  PERFORM mf.generer_echeancier(v_credit);

  IF v_gtype = 'compte' THEN
    INSERT INTO mf.garantie_compte(credit_id, compte_id, montant_bloque, montant_restant)
    VALUES (v_credit, d.compte_id, d.garantie_montant, d.garantie_montant);
  END IF;

  IF p_mode = 'compte' THEN
    INSERT INTO mf.mouvement_epargne(compte_id, type, montant, date_operation, libelle, reference)
    VALUES (d.compte_id, 'deblocage_credit', d.montant, p_date, 'Déblocage du crédit ' || d.numero, 'credit:' || v_credit);
    IF v_frais > 0 THEN
      INSERT INTO mf.mouvement_epargne(compte_id, type, montant, date_operation, libelle, reference)
      VALUES (d.compte_id, 'frais_dossier', v_frais, p_date, 'Frais de dossier ' || d.numero, 'credit:' || v_credit);
    END IF;
  ELSE
    PERFORM mf.caisse_operation(p_session, 'decaissement', 'deblocage_credit', d.montant, p_date, 'credit', v_credit);
    IF v_frais > 0 THEN
      PERFORM mf.caisse_operation(p_session, 'encaissement', 'frais_dossier', v_frais, p_date, 'credit', v_credit);
    END IF;
  END IF;

  UPDATE mf.demande_credit SET statut = 'debloquee', credit_id = v_credit WHERE id = p_demande;
  RETURN v_credit;
END $$;

-- ---------------------------------------------------------------------
-- Prélèvement automatique : dû complet seulement, sur le solde disponible (garantie exclue).
-- La date d'effet (retard, pénalité, points) est la date du prélèvement, soit le premier jour où le disponible
-- suffit : lancer la tâche chaque jour. Retourne le nombre d'échéances prélevées.
-- ---------------------------------------------------------------------
CREATE FUNCTION prelever_echeances_compte(p_agence smallint, p_date date DEFAULT current_date) RETURNS integer
LANGUAGE plpgsql AS $$
DECLARE c record; e mf.echeance; v_du numeric; n integer := 0;
BEGIN
  FOR c IN SELECT * FROM mf.credit
            WHERE agence_id = p_agence AND mode_remboursement = 'prelevement_compte' AND statut <> 'solde' AND compte_id IS NOT NULL
            ORDER BY id LOOP
    LOOP
      SELECT * INTO e FROM mf.echeance WHERE credit_id = c.id AND statut <> 'payee' ORDER BY no_echeance LIMIT 1;
      EXIT WHEN NOT FOUND OR e.date_prevue > p_date;
      v_du := mf.du_echeance(e.id, p_date);
      EXIT WHEN v_du <= 0 OR v_du > mf.solde_disponible(c.compte_id);
      INSERT INTO mf.mouvement_epargne(compte_id, type, montant, date_operation, libelle, reference)
      VALUES (c.compte_id, 'prelevement_echeance', v_du, p_date,
              'Prélèvement échéance ' || e.no_echeance || ' du crédit ' || c.numero, 'echeance:' || e.id);
      PERFORM mf.imputer_echeance(e.id, v_du, p_date, 'prelevement');
      n := n + 1;
    END LOOP;
  END LOOP;
  RETURN n;
END $$;

-- ---------------------------------------------------------------------
-- Saisie de la garantie : sur l'échéance la plus ancienne impayée dont le retard dépasse jours_saisie_garantie,
-- dans la limite de la garantie encore bloquée. Retourne le nombre de saisies (échéances imputées).
-- ---------------------------------------------------------------------
CREATE FUNCTION saisir_garantie_echeances(p_agence smallint, p_date date DEFAULT current_date) RETURNS integer
LANGUAGE plpgsql AS $$
DECLARE gr record; e mf.echeance; v_du numeric; v_s numeric; v_delai integer; n integer := 0;
BEGIN
  FOR gr IN SELECT gc.*, c.numero AS credit_numero, c.agence_id
             FROM mf.garantie_compte gc JOIN mf.credit c ON c.id = gc.credit_id
            WHERE c.agence_id = p_agence AND gc.statut = 'bloquee' AND gc.montant_restant > 0 AND c.statut <> 'solde'
            ORDER BY gc.id LOOP
    v_delai := mf.param_num('jours_saisie_garantie', gr.agence_id)::integer;
    LOOP
      SELECT * INTO e FROM mf.echeance WHERE credit_id = gr.credit_id AND statut <> 'payee' ORDER BY no_echeance LIMIT 1;
      EXIT WHEN NOT FOUND OR (p_date - e.date_prevue) <= v_delai;
      SELECT montant_restant INTO v_s FROM mf.garantie_compte WHERE id = gr.id;
      EXIT WHEN v_s <= 0;
      v_du := mf.du_echeance(e.id, p_date);
      v_s := LEAST(v_s, v_du);
      EXIT WHEN v_s <= 0;
      -- on réduit d'abord le bloqué, ce qui libère le disponible nécessaire à la sortie
      UPDATE mf.garantie_compte SET montant_saisi = montant_saisi + v_s, montant_restant = montant_restant - v_s WHERE id = gr.id;
      INSERT INTO mf.mouvement_epargne(compte_id, type, montant, date_operation, libelle, reference)
      VALUES (gr.compte_id, 'saisie_garantie', v_s, p_date,
              'Saisie de garantie, échéance ' || e.no_echeance || ' du crédit ' || gr.credit_numero, 'echeance:' || e.id);
      PERFORM mf.imputer_echeance(e.id, v_s, p_date, 'saisie_garantie');
      n := n + 1;
    END LOOP;
  END LOOP;
  RETURN n;
END $$;

-- Libération du solde de la garantie quand le crédit est soldé.
CREATE FUNCTION trg_credit_solde_garantie() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  IF NEW.statut = 'solde' AND OLD.statut <> 'solde' THEN
    UPDATE mf.garantie_compte SET montant_restant = 0, statut = 'liberee', libere_le = NEW.date_solde
     WHERE credit_id = NEW.id AND statut = 'bloquee';
  END IF;
  RETURN NULL;
END $$;
CREATE TRIGGER credit_solde_garantie AFTER UPDATE OF statut ON credit
  FOR EACH ROW EXECUTE FUNCTION trg_credit_solde_garantie();

-- Remboursement en espèces à la caisse : paiement partiel accepté, échéances dans l'ordre.
CREATE FUNCTION rembourser_echeance_especes(p_echeance integer, p_montant numeric, p_session integer,
                                            p_date date DEFAULT current_date) RETURNS void
LANGUAGE plpgsql AS $$
DECLARE cr mf.credit;
BEGIN
  SELECT k.* INTO cr FROM mf.credit k JOIN mf.echeance e ON e.credit_id = k.id WHERE e.id = p_echeance;
  IF NOT FOUND THEN RAISE EXCEPTION 'échéance % inconnue', p_echeance; END IF;
  IF cr.mode_remboursement <> 'especes' THEN
    RAISE EXCEPTION 'le crédit % se rembourse par %, pas en espèces', cr.numero, cr.mode_remboursement;
  END IF;
  PERFORM mf.imputer_echeance(p_echeance, p_montant, p_date, 'especes');
  PERFORM mf.caisse_operation(p_session, 'encaissement', 'remboursement_credit', p_montant, p_date, 'echeance', p_echeance);
END $$;

CREATE VIEW v_credit_epargne_situation AS
SELECT s.credit_id, s.agence_id, s.numero, s.client_id, s.type, s.mode_remboursement, s.capital_restant,
       COALESCE(g.montant_restant, 0)::numeric(14,0) AS garantie_bloquee, s.statut
  FROM v_credit_situation s LEFT JOIN garantie_compte g ON g.credit_id = s.credit_id;
