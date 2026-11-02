-- =====================================================================
-- 26_epargne_journee_sortie.sql
-- Compléments de l'épargne classique et de l'adhésion.
--   1. Annulation d'un dépôt ou d'un retrait du jour par contre-passation (jamais de suppression : la comptabilisation
--      automatique et la piste d'audit restent cohérentes). Un dépôt ne s'annule que si le solde disponible le permet.
--   2. Dépôt et retrait seulement sur la date d'opération ouverte (module 81) ; l'annulation suit la même règle.
--      Les validations journalières d'épargne sont retirées.
--   3. Sortie d'un membre : radier_adhesion rembourse les parts (capital libéré) et radie l'adhésion, à condition qu'aucun
--      compte d'épargne ne soit actif avec un solde, qu'aucun cycle de tontine ne soit en cours et qu'aucun crédit ne soit non soldé.
-- Dépend de : 01, 02 (mouvements), 03 (crédit), 24 (adhésion).
-- =====================================================================
SET search_path = mf, public;

CREATE TABLE annulation_mouvement (
  mouvement_id   bigint PRIMARY KEY REFERENCES mouvement_epargne(id),
  contre_id      bigint NOT NULL UNIQUE REFERENCES mouvement_epargne(id),
  utilisateur_id integer REFERENCES utilisateur(id),
  cree_le        timestamptz NOT NULL DEFAULT now()
);

-- Dépôt ou retrait : seulement sur la date d'opération ouverte (module 81). Les autres types de mouvement ne sont pas concernés.
CREATE FUNCTION controler_date_epargne() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  IF NEW.type NOT IN ('depot', 'retrait') THEN RETURN NEW; END IF;
  IF NEW.date_operation IS DISTINCT FROM mf.date_operation_courante() THEN
    RAISE EXCEPTION 'une opération d''épargne se saisit sur la date d''opération ouverte (%), pas le %',
      mf.date_operation_courante(), NEW.date_operation;
  END IF;
  RETURN NEW;
END $$;
-- nom précédant « mouvement_controle » dans l'ordre alphabétique des déclencheurs : le contrôle passe en premier
CREATE TRIGGER mouvement_date_operation BEFORE INSERT ON mouvement_epargne
  FOR EACH ROW EXECUTE FUNCTION controler_date_epargne();

-- Contre-passation d'un dépôt ou d'un retrait (même date que l'opération). Retourne l'id du mouvement inverse.
CREATE FUNCTION annuler_mouvement_epargne(p_mouvement bigint, p_utilisateur integer DEFAULT NULL) RETURNS bigint
LANGUAGE plpgsql AS $$
DECLARE m mf.mouvement_epargne; v_contre bigint;
BEGIN
  SELECT * INTO m FROM mf.mouvement_epargne WHERE id = p_mouvement;
  IF NOT FOUND THEN RAISE EXCEPTION 'mouvement % inconnu', p_mouvement; END IF;
  IF m.type NOT IN ('depot', 'retrait') THEN RAISE EXCEPTION 'seuls un dépôt ou un retrait s''annulent ici'; END IF;
  IF m.reference LIKE 'annulation:%' THEN RAISE EXCEPTION 'une annulation ne s''annule pas'; END IF;
  IF EXISTS (SELECT 1 FROM mf.annulation_mouvement WHERE mouvement_id = p_mouvement) THEN
    RAISE EXCEPTION 'le mouvement % est déjà annulé', p_mouvement;
  END IF;
  INSERT INTO mf.mouvement_epargne(compte_id, type, montant, date_operation, libelle, reference)
  VALUES (m.compte_id, CASE m.type WHEN 'depot' THEN 'retrait' ELSE 'depot' END, m.montant, m.date_operation,
          'Annulation du ' || m.type || ' n° ' || m.id, 'annulation:' || m.id)
  RETURNING id INTO v_contre;
  INSERT INTO mf.annulation_mouvement(mouvement_id, contre_id, utilisateur_id) VALUES (p_mouvement, v_contre, p_utilisateur);
  RETURN v_contre;
END $$;

-- Sortie d'un membre : remboursement des parts et radiation
CREATE TABLE remboursement_part (
  id              serial PRIMARY KEY,
  adhesion_id     integer NOT NULL UNIQUE REFERENCES adhesion(id),
  nb_parts        integer NOT NULL CHECK (nb_parts >= 0),
  montant         numeric(14,0) NOT NULL CHECK (montant >= 0),
  date_operation  date NOT NULL,
  utilisateur_id  integer REFERENCES utilisateur(id),
  cree_le         timestamptz NOT NULL DEFAULT now()
);

CREATE FUNCTION radier_adhesion(p_client integer, p_date date DEFAULT current_date, p_utilisateur integer DEFAULT NULL) RETURNS numeric
LANGUAGE plpgsql AS $$
DECLARE a mf.adhesion; v_parts integer; v_montant numeric;
BEGIN
  SELECT * INTO a FROM mf.adhesion WHERE client_id = p_client FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'le client % n''a pas d''adhésion', p_client; END IF;
  IF a.statut <> 'active' THEN RAISE EXCEPTION 'adhésion % déjà radiée', a.numero; END IF;
  IF p_date > current_date THEN RAISE EXCEPTION 'la date de sortie ne peut pas être dans le futur'; END IF;
  IF EXISTS (SELECT 1 FROM mf.compte_epargne ce JOIN mf.v_solde_compte_epargne v ON v.compte_id = ce.id
              WHERE ce.client_id = p_client AND ce.statut <> 'clos' AND v.solde > 0) THEN
    RAISE EXCEPTION 'sortie refusée : un compte d''épargne du client a encore un solde';
  END IF;
  IF EXISTS (SELECT 1 FROM mf.cycle WHERE client_id = p_client AND statut = 'en_cours') THEN
    RAISE EXCEPTION 'sortie refusée : une souscription de tontine est en cours';
  END IF;
  IF EXISTS (SELECT 1 FROM mf.credit WHERE client_id = p_client AND statut <> 'solde') THEN
    RAISE EXCEPTION 'sortie refusée : un crédit n''est pas soldé';
  END IF;
  SELECT COALESCE(sum(nb_parts), 0), COALESCE(sum(montant), 0) INTO v_parts, v_montant FROM mf.souscription_part WHERE adhesion_id = a.id;
  INSERT INTO mf.remboursement_part(adhesion_id, nb_parts, montant, date_operation, utilisateur_id) VALUES (a.id, v_parts, v_montant, p_date, p_utilisateur);
  UPDATE mf.adhesion SET statut = 'radiee' WHERE id = a.id;
  RETURN v_montant;
END $$;
