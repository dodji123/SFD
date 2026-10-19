-- =====================================================================
-- 27_adhesion_par_compte.sql
-- Chaque compte d'épargne a sa propre adhésion et sa propre souscription de parts sociales (capital).
--   adhesion.compte_id : l'adhésion appartient à un compte (une adhésion par compte, plusieurs comptes possibles par client).
--   ouvrir_compte_adherent : ouvre le compte, l'adhésion (droit d'adhésion) et la souscription des parts en une seule opération ;
--                            le nombre de parts doit atteindre `parts_minimum`.
--   adherer_compte / souscrire_parts_compte : pour un compte ouvert sans adhésion (données antérieures) ou des parts supplémentaires.
--   radier_adhesion_compte : sortie du compte : rembourse les parts, radie l'adhésion et clôt le compte (solde nul exigé).
--   membre_en_regle(compte) : adhésion active et au moins `parts_minimum` parts pour ce compte.
-- Les adhésions existantes (une par client) sont rattachées au premier compte du client.
-- Remplace les fonctions par client des modules 24 et 26.
-- Dépend de : 01, 24, 26.
-- =====================================================================
SET search_path = mf, public;

ALTER TABLE adhesion DROP CONSTRAINT adhesion_client_id_key;
ALTER TABLE adhesion ADD COLUMN compte_id integer UNIQUE REFERENCES compte_epargne(id);
UPDATE adhesion a SET compte_id = (SELECT min(ce.id) FROM compte_epargne ce WHERE ce.client_id = a.client_id);

DROP VIEW v_membre;
CREATE VIEW v_membre AS
SELECT a.id AS adhesion_id, a.agence_id, a.client_id, a.compte_id, a.numero, a.date_adhesion, a.statut,
       COALESCE(sum(s.nb_parts), 0)::integer AS nb_parts, COALESCE(sum(s.montant), 0)::numeric(14,0) AS capital_souscrit
  FROM adhesion a LEFT JOIN souscription_part s ON s.adhesion_id = a.id
 GROUP BY a.id;

DROP FUNCTION membre_en_regle(integer);
DROP FUNCTION adherer(integer, date, integer);
DROP FUNCTION souscrire_parts(integer, integer, date, integer);
DROP FUNCTION radier_adhesion(integer, date, integer);

CREATE FUNCTION membre_en_regle(p_compte integer) RETURNS boolean
LANGUAGE sql STABLE AS $$
  SELECT EXISTS (SELECT 1 FROM mf.v_membre m JOIN mf.compte_epargne ce ON ce.id = m.compte_id
                  WHERE m.compte_id = p_compte AND m.statut = 'active'
                    AND m.nb_parts >= COALESCE(mf.param_num('parts_minimum', ce.agence_id), 1))
$$;

CREATE FUNCTION adherer_compte(p_compte integer, p_date date DEFAULT current_date, p_utilisateur integer DEFAULT NULL) RETURNS integer
LANGUAGE plpgsql AS $$
DECLARE ce mf.compte_epargne; v_id integer;
BEGIN
  SELECT * INTO ce FROM mf.compte_epargne WHERE id = p_compte FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'compte % inconnu', p_compte; END IF;
  IF ce.statut = 'clos' THEN RAISE EXCEPTION 'compte % clos', ce.numero; END IF;
  IF p_date > current_date THEN RAISE EXCEPTION 'la date d''adhésion ne peut pas être dans le futur'; END IF;
  IF EXISTS (SELECT 1 FROM mf.adhesion WHERE compte_id = p_compte) THEN
    RAISE EXCEPTION 'le compte % a déjà une adhésion', ce.numero;
  END IF;
  INSERT INTO mf.adhesion(agence_id, client_id, compte_id, date_adhesion, droit_adhesion, utilisateur_id)
  VALUES (ce.agence_id, ce.client_id, p_compte, p_date, COALESCE(mf.param_num('droit_adhesion', ce.agence_id), 0), p_utilisateur)
  RETURNING id INTO v_id;
  RETURN v_id;
END $$;

CREATE FUNCTION souscrire_parts_compte(p_compte integer, p_nb integer, p_date date DEFAULT current_date, p_utilisateur integer DEFAULT NULL) RETURNS integer
LANGUAGE plpgsql AS $$
DECLARE a mf.adhesion; v_val numeric; v_id integer;
BEGIN
  SELECT * INTO a FROM mf.adhesion WHERE compte_id = p_compte FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'le compte % n''a pas d''adhésion : adhérer d''abord', p_compte; END IF;
  IF a.statut <> 'active' THEN RAISE EXCEPTION 'adhésion % radiée', a.numero; END IF;
  IF p_nb IS NULL OR p_nb <= 0 THEN RAISE EXCEPTION 'le nombre de parts doit être positif'; END IF;
  IF p_date > current_date THEN RAISE EXCEPTION 'la date de souscription ne peut pas être dans le futur'; END IF;
  v_val := mf.param_num('part_valeur_nominale', a.agence_id);
  IF v_val IS NULL OR v_val <= 0 THEN RAISE EXCEPTION 'valeur nominale de la part non paramétrée'; END IF;
  INSERT INTO mf.souscription_part(adhesion_id, nb_parts, valeur_nominale, montant, date_souscription, utilisateur_id)
  VALUES (a.id, p_nb, v_val, p_nb * v_val, p_date, p_utilisateur) RETURNING id INTO v_id;
  RETURN v_id;
END $$;

-- Ouverture d'un compte d'épargne classique avec son adhésion et ses parts. Retourne l'id du compte.
CREATE FUNCTION ouvrir_compte_adherent(p_client integer, p_produit integer, p_nb_parts integer, p_date date DEFAULT current_date,
                                       p_utilisateur integer DEFAULT NULL) RETURNS integer
LANGUAGE plpgsql AS $$
DECLARE c mf.client; p mf.produit_epargne; v_min integer; v_compte integer;
BEGIN
  SELECT * INTO c FROM mf.client WHERE id = p_client FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'client % inconnu', p_client; END IF;
  SELECT * INTO p FROM mf.produit_epargne WHERE id = p_produit AND actif;
  IF NOT FOUND OR p.categorie <> 'classique' THEN RAISE EXCEPTION 'le produit doit être un produit d''épargne classique'; END IF;
  v_min := COALESCE(mf.param_num('parts_minimum', c.agence_id), 1);
  IF p_nb_parts IS NULL OR p_nb_parts < v_min THEN
    RAISE EXCEPTION 'il faut souscrire au moins % part(s) pour ouvrir un compte', v_min;
  END IF;
  INSERT INTO mf.compte_epargne(agence_id, client_id, produit_id, ouvert_le) VALUES (c.agence_id, p_client, p_produit, p_date)
  RETURNING id INTO v_compte;
  PERFORM mf.adherer_compte(v_compte, p_date, p_utilisateur);
  PERFORM mf.souscrire_parts_compte(v_compte, p_nb_parts, p_date, p_utilisateur);
  RETURN v_compte;
END $$;

-- Sortie : parts remboursées, adhésion radiée, compte clos (solde nul exigé, aucune liaison de tontine active sur ce compte)
CREATE FUNCTION radier_adhesion_compte(p_compte integer, p_date date DEFAULT current_date, p_utilisateur integer DEFAULT NULL) RETURNS numeric
LANGUAGE plpgsql AS $$
DECLARE a mf.adhesion; ce mf.compte_epargne; v_parts integer; v_montant numeric;
BEGIN
  SELECT * INTO ce FROM mf.compte_epargne WHERE id = p_compte FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'compte % inconnu', p_compte; END IF;
  SELECT * INTO a FROM mf.adhesion WHERE compte_id = p_compte FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'le compte % n''a pas d''adhésion', ce.numero; END IF;
  IF a.statut <> 'active' THEN RAISE EXCEPTION 'adhésion % déjà radiée', a.numero; END IF;
  IF p_date > current_date THEN RAISE EXCEPTION 'la date de sortie ne peut pas être dans le futur'; END IF;
  IF EXISTS (SELECT 1 FROM mf.v_solde_compte_epargne v WHERE v.compte_id = p_compte AND v.solde > 0) THEN
    RAISE EXCEPTION 'sortie refusée : le compte % a encore un solde', ce.numero;
  END IF;
  IF EXISTS (SELECT 1 FROM mf.liaison_tontine_epargne l JOIN mf.cycle cy ON cy.id = l.cycle_id WHERE l.compte_id = p_compte AND cy.statut = 'en_cours') THEN
    RAISE EXCEPTION 'sortie refusée : une souscription de tontine en cours est reliée au compte %', ce.numero;
  END IF;
  IF EXISTS (SELECT 1 FROM mf.credit WHERE client_id = ce.client_id AND statut <> 'solde' AND mode_remboursement = 'prelevement_compte') THEN
    RAISE EXCEPTION 'sortie refusée : un crédit non soldé est remboursé par prélèvement sur le compte';
  END IF;
  SELECT COALESCE(sum(nb_parts), 0), COALESCE(sum(montant), 0) INTO v_parts, v_montant FROM mf.souscription_part WHERE adhesion_id = a.id;
  INSERT INTO mf.remboursement_part(adhesion_id, nb_parts, montant, date_operation, utilisateur_id) VALUES (a.id, v_parts, v_montant, p_date, p_utilisateur);
  UPDATE mf.adhesion SET statut = 'radiee' WHERE id = a.id;
  UPDATE mf.compte_epargne SET statut = 'clos' WHERE id = p_compte;
  RETURN v_montant;
END $$;
