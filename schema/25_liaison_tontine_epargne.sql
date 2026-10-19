-- =====================================================================
-- 25_liaison_tontine_epargne.sql
-- Mise en relation d'un cycle de tontine avec le compte d'épargne classique du même client : le client a deux comptes
-- (souscription de tontine, compte classique) et peut alimenter l'un par l'autre. La liaison désigne, pour un cycle,
-- le compte classique qu'il alimente (virement cycle -> épargne) et dont il reçoit les versements (épargne -> cycle).
-- Les virements eux-mêmes restent ceux du module 07 (circuit de retrait et d'écarts pour cycle -> épargne).
-- Un cycle a au plus une liaison ; elle est modifiable tant que le cycle est en cours.
-- Dépend de : 01, 07.
-- =====================================================================
SET search_path = mf, public;

CREATE TABLE liaison_tontine_epargne (
  id             serial PRIMARY KEY,
  agence_id      smallint NOT NULL REFERENCES agence(id),
  client_id      integer NOT NULL REFERENCES client(id),
  cycle_id       integer NOT NULL UNIQUE REFERENCES cycle(id),
  compte_id      integer NOT NULL REFERENCES compte_epargne(id),
  utilisateur_id integer REFERENCES utilisateur(id),
  cree_le        timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX liaison_compte ON liaison_tontine_epargne (compte_id);

-- Crée ou remplace la liaison d'un cycle. Retourne l'id de la liaison.
CREATE FUNCTION lier_cycle_compte(p_cycle integer, p_compte integer, p_utilisateur integer DEFAULT NULL) RETURNS integer
LANGUAGE plpgsql AS $$
DECLARE c mf.cycle; ce mf.compte_epargne; p mf.produit_epargne; v_id integer;
BEGIN
  SELECT * INTO c FROM mf.cycle WHERE id = p_cycle FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'cycle % inconnu', p_cycle; END IF;
  SELECT * INTO ce FROM mf.compte_epargne WHERE id = p_compte;
  IF NOT FOUND THEN RAISE EXCEPTION 'compte % inconnu', p_compte; END IF;
  IF ce.client_id <> c.client_id THEN RAISE EXCEPTION 'le compte % n''appartient pas au client du cycle %', ce.numero, c.numero; END IF;
  SELECT * INTO p FROM mf.produit_epargne WHERE id = ce.produit_id;
  IF p.categorie <> 'classique' THEN RAISE EXCEPTION 'le compte % n''est pas un compte d''épargne classique', ce.numero; END IF;
  IF ce.statut <> 'actif' THEN RAISE EXCEPTION 'compte % non actif', ce.numero; END IF;
  IF c.statut <> 'en_cours' THEN RAISE EXCEPTION 'cycle % non en cours', c.numero; END IF;
  INSERT INTO mf.liaison_tontine_epargne(agence_id, client_id, cycle_id, compte_id, utilisateur_id)
  VALUES (c.agence_id, c.client_id, p_cycle, p_compte, p_utilisateur)
  ON CONFLICT (cycle_id) DO UPDATE SET compte_id = EXCLUDED.compte_id, utilisateur_id = EXCLUDED.utilisateur_id, cree_le = now()
  RETURNING id INTO v_id;
  RETURN v_id;
END $$;

CREATE FUNCTION delier_cycle_compte(p_cycle integer) RETURNS void
LANGUAGE plpgsql AS $$
BEGIN
  DELETE FROM mf.liaison_tontine_epargne WHERE cycle_id = p_cycle;
  IF NOT FOUND THEN RAISE EXCEPTION 'aucune liaison sur le cycle %', p_cycle; END IF;
END $$;
