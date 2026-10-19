-- =====================================================================
-- 15_transferts_clients.sql
-- Transfert d'un client entre zones (même agence) et entre agences.
--  * historique des zones d'un client : la zone qui compte pour une opération est celle de la
--    date de l'opération (collecte, retrait, remboursement), et non la zone actuelle ;
--  * journal des transferts (zone et agence) ;
--  * transfert d'agence refusé tant que le client a une opération en cours.
-- Dépend de : 00 à 14. Le contrôle des rôles est fait par l'API (perm. clients:transferer).
-- LIMITE : aucune écriture comptable inter-agences n'est générée. Le solde d'épargne qui change
-- d'agence est enregistré dans client_transfert.solde_epargne pour permettre le règlement
-- (compte de liaison) par le comptable ; l'historique financier (cycles retirés, crédits soldés,
-- pièces) reste rattaché à l'agence d'origine.
-- =====================================================================
SET search_path = mf, public;

-- ---------------------------------------------------------------------
-- Historique des zones : une ligne par changement (la première = zone à la création)
-- ---------------------------------------------------------------------
CREATE TABLE client_zone_historique (
  client_id      integer NOT NULL REFERENCES client(id),
  date_effet     date NOT NULL,
  zone_id        integer REFERENCES zone(id),            -- NULL = sans zone
  motif          text,
  utilisateur_id integer REFERENCES utilisateur(id),
  cree_le        timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (client_id, date_effet)
);

CREATE TABLE client_transfert (
  id               serial PRIMARY KEY,
  client_id        integer NOT NULL REFERENCES client(id),
  type             varchar(10) NOT NULL CHECK (type IN ('zone','agence')),
  agence_source_id smallint NOT NULL REFERENCES agence(id),
  agence_dest_id   smallint NOT NULL REFERENCES agence(id),
  zone_source_id   integer REFERENCES zone(id),
  zone_dest_id     integer REFERENCES zone(id),
  date_effet       date NOT NULL,
  motif            text,
  ancien_numero    varchar(20),
  nouveau_numero   varchar(20),
  comptes          jsonb,                                -- [{id, ancien, nouveau}] des comptes d'épargne déplacés
  solde_epargne    numeric(14,0),                        -- solde d'épargne qui change d'agence (règlement inter-agences)
  utilisateur_id   integer REFERENCES utilisateur(id),
  cree_le          timestamptz NOT NULL DEFAULT now(),
  CHECK ((type = 'zone') = (agence_source_id = agence_dest_id))
);
CREATE INDEX client_transfert_client ON client_transfert (client_id, date_effet);

-- Zone d'un client à une date : dernière ligne d'historique dont la date d'effet est atteinte.
CREATE FUNCTION zone_client_a_date(p_client integer, p_date date) RETURNS integer
LANGUAGE sql STABLE AS $$
  SELECT h.zone_id FROM mf.client_zone_historique h
   WHERE h.client_id = p_client AND h.date_effet <= p_date
   ORDER BY h.date_effet DESC LIMIT 1
$$;

-- Zone initiale à la création du client
CREATE FUNCTION trg_client_zone_initiale() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  INSERT INTO mf.client_zone_historique(client_id, date_effet, zone_id, motif) VALUES (NEW.id, DATE '1900-01-01', NEW.zone_id, 'création');
  RETURN NEW;
END $$;
CREATE TRIGGER client_zone_initiale AFTER INSERT ON client FOR EACH ROW EXECUTE FUNCTION trg_client_zone_initiale();

-- La zone et l'agence d'un client ne changent que par les fonctions de transfert (historique cohérent).
CREATE FUNCTION trg_client_garde_transfert() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  IF (NEW.zone_id IS DISTINCT FROM OLD.zone_id OR NEW.agence_id <> OLD.agence_id)
     AND COALESCE(current_setting('mf.transfert_client', true), 'off') <> 'on' THEN
    RAISE EXCEPTION 'la zone ou l''agence d''un client change par transferer_client_zone / transferer_client_agence';
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER client_garde_transfert BEFORE UPDATE OF zone_id, agence_id ON client FOR EACH ROW EXECUTE FUNCTION trg_client_garde_transfert();

-- Clients déjà présents (base existante) : une ligne d'historique initiale
INSERT INTO client_zone_historique(client_id, date_effet, zone_id, motif)
SELECT c.id, DATE '1900-01-01', c.zone_id, 'reprise' FROM client c
 WHERE NOT EXISTS (SELECT 1 FROM client_zone_historique h WHERE h.client_id = c.id);

-- ---------------------------------------------------------------------
-- Transfert de zone (même agence)
-- ---------------------------------------------------------------------
CREATE FUNCTION transferer_client_zone(p_client integer, p_zone integer, p_date date DEFAULT current_date,
                                       p_motif text DEFAULT NULL, p_utilisateur integer DEFAULT NULL) RETURNS integer
LANGUAGE plpgsql AS $$
DECLARE v_cl mf.client; v_z mf.zone; v_dernier date; v_id integer;
BEGIN
  SELECT * INTO v_cl FROM mf.client WHERE id = p_client FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'client % inconnu', p_client; END IF;
  SELECT * INTO v_z FROM mf.zone WHERE id = p_zone;
  IF NOT FOUND THEN RAISE EXCEPTION 'zone % inconnue', p_zone; END IF;
  IF v_z.agence_id <> v_cl.agence_id THEN
    RAISE EXCEPTION 'la zone % appartient à une autre agence : utiliser un transfert d''agence', v_z.code;
  END IF;
  IF v_cl.zone_id IS NOT DISTINCT FROM p_zone THEN
    RAISE EXCEPTION 'le client % est déjà dans la zone %', v_cl.numero, v_z.code;
  END IF;
  IF p_date > current_date THEN RAISE EXCEPTION 'la date d''effet ne peut pas être dans le futur'; END IF;
  SELECT max(h.date_effet) INTO v_dernier FROM mf.client_zone_historique h WHERE h.client_id = p_client;
  IF p_date <= v_dernier THEN
    RAISE EXCEPTION 'la date d''effet (%) doit être postérieure au dernier changement de zone (%)', p_date, v_dernier;
  END IF;

  INSERT INTO mf.client_zone_historique(client_id, date_effet, zone_id, motif, utilisateur_id)
  VALUES (p_client, p_date, p_zone, p_motif, p_utilisateur);
  PERFORM set_config('mf.transfert_client', 'on', true);
  UPDATE mf.client SET zone_id = p_zone WHERE id = p_client;
  PERFORM set_config('mf.transfert_client', 'off', true);
  INSERT INTO mf.client_transfert(client_id, type, agence_source_id, agence_dest_id, zone_source_id, zone_dest_id,
                                  date_effet, motif, utilisateur_id)
  VALUES (p_client, 'zone', v_cl.agence_id, v_cl.agence_id, v_cl.zone_id, p_zone, p_date, p_motif, p_utilisateur)
  RETURNING id INTO v_id;
  RETURN v_id;
END $$;

-- ---------------------------------------------------------------------
-- Transfert d'agence
-- Refusé si le client a : un cycle de collecte non retiré (en cours ou clos non payé), un retrait
-- non terminé, un crédit non soldé, une demande de crédit en attente ou une garantie bloquée.
-- Déplace le client et ses comptes d'épargne ; les numéros sont régénérés dans l'agence d'arrivée.
-- ---------------------------------------------------------------------
CREATE FUNCTION transferer_client_agence(p_client integer, p_agence_dest smallint, p_zone_dest integer DEFAULT NULL,
                                         p_date date DEFAULT current_date, p_motif text DEFAULT NULL,
                                         p_utilisateur integer DEFAULT NULL) RETURNS integer
LANGUAGE plpgsql AS $$
DECLARE
  v_cl mf.client; v_dernier date; v_id integer; v_n integer; v_bloc text[] := '{}';
  v_nouveau varchar(20); v_comptes jsonb := '[]'::jsonb; v_solde numeric := 0; v_ce record; v_num varchar(25);
BEGIN
  SELECT * INTO v_cl FROM mf.client WHERE id = p_client FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'client % inconnu', p_client; END IF;
  IF p_agence_dest = v_cl.agence_id THEN RAISE EXCEPTION 'le client est déjà dans cette agence : utiliser un transfert de zone'; END IF;
  IF NOT EXISTS (SELECT 1 FROM mf.agence WHERE id = p_agence_dest) THEN RAISE EXCEPTION 'agence % inconnue', p_agence_dest; END IF;
  IF p_zone_dest IS NOT NULL AND NOT EXISTS (SELECT 1 FROM mf.zone z WHERE z.id = p_zone_dest AND z.agence_id = p_agence_dest) THEN
    RAISE EXCEPTION 'la zone % n''appartient pas à l''agence de destination', p_zone_dest;
  END IF;
  SELECT count(*) INTO v_n FROM mf.cycle WHERE client_id = p_client AND statut <> 'retire';
  IF v_n > 0 THEN v_bloc := v_bloc || (v_n || ' cycle(s) de collecte non retiré(s)'); END IF;
  SELECT count(*) INTO v_n FROM mf.retrait r JOIN mf.cycle c ON c.id = r.cycle_id
   WHERE c.client_id = p_client AND r.statut NOT IN ('execute', 'annule');
  IF v_n > 0 THEN v_bloc := v_bloc || (v_n || ' retrait(s) en cours'); END IF;
  SELECT count(*) INTO v_n FROM mf.credit WHERE client_id = p_client AND statut <> 'solde';
  IF v_n > 0 THEN v_bloc := v_bloc || (v_n || ' crédit(s) non soldé(s)'); END IF;
  SELECT count(*) INTO v_n FROM mf.demande_credit WHERE client_id = p_client AND statut IN ('demandee', 'approuvee');
  IF v_n > 0 THEN v_bloc := v_bloc || (v_n || ' demande(s) de crédit en attente'); END IF;
  SELECT count(*) INTO v_n FROM mf.garantie_compte g JOIN mf.compte_epargne ce ON ce.id = g.compte_id
   WHERE ce.client_id = p_client AND g.statut = 'bloquee';
  IF v_n > 0 THEN v_bloc := v_bloc || (v_n || ' garantie(s) bloquée(s)'); END IF;
  IF cardinality(v_bloc) > 0 THEN
    RAISE EXCEPTION 'transfert d''agence impossible pour le client % : %', v_cl.numero, array_to_string(v_bloc, ', ');
  END IF;
  IF p_date > current_date THEN RAISE EXCEPTION 'la date d''effet ne peut pas être dans le futur'; END IF;
  SELECT max(h.date_effet) INTO v_dernier FROM mf.client_zone_historique h WHERE h.client_id = p_client;
  IF p_date <= v_dernier THEN
    RAISE EXCEPTION 'la date d''effet (%) doit être postérieure au dernier changement de zone (%)', p_date, v_dernier;
  END IF;

  v_nouveau := mf.prochain_numero('client', p_agence_dest, p_date, 'CL');
  FOR v_ce IN SELECT ce.id, ce.numero, COALESCE(s.solde, 0) AS solde FROM mf.compte_epargne ce
                LEFT JOIN mf.v_solde_compte_epargne s ON s.compte_id = ce.id WHERE ce.client_id = p_client ORDER BY ce.id
  LOOP
    v_num := mf.prochain_numero('compte_epargne', p_agence_dest, p_date, 'CE');
    UPDATE mf.compte_epargne SET agence_id = p_agence_dest, numero = v_num WHERE id = v_ce.id;
    v_comptes := v_comptes || jsonb_build_object('id', v_ce.id, 'ancien', v_ce.numero, 'nouveau', v_num);
    v_solde := v_solde + v_ce.solde;
  END LOOP;

  INSERT INTO mf.client_zone_historique(client_id, date_effet, zone_id, motif, utilisateur_id)
  VALUES (p_client, p_date, p_zone_dest, COALESCE(p_motif, 'transfert d''agence'), p_utilisateur);
  PERFORM set_config('mf.transfert_client', 'on', true);
  UPDATE mf.client SET agence_id = p_agence_dest, zone_id = p_zone_dest, numero = v_nouveau WHERE id = p_client;
  PERFORM set_config('mf.transfert_client', 'off', true);
  INSERT INTO mf.client_transfert(client_id, type, agence_source_id, agence_dest_id, zone_source_id, zone_dest_id, date_effet,
                                  motif, ancien_numero, nouveau_numero, comptes, solde_epargne, utilisateur_id)
  VALUES (p_client, 'agence', v_cl.agence_id, p_agence_dest, v_cl.zone_id, p_zone_dest, p_date,
          p_motif, v_cl.numero, v_nouveau, v_comptes, v_solde, p_utilisateur)
  RETURNING id INTO v_id;
  RETURN v_id;
END $$;

-- ---------------------------------------------------------------------
-- Les rapports et la commission utilisent la zone du client À LA DATE de l'opération
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION production_collectrice(p_collectrice integer, p_du date, p_au date) RETURNS numeric
LANGUAGE plpgsql STABLE AS $$
DECLARE v_agence smallint; v_mode text; v_prod numeric;
BEGIN
  SELECT agence_id INTO v_agence FROM mf.collectrice WHERE id = p_collectrice;
  v_mode := mf.param('mode_cloture', v_agence);
  IF v_mode = 'date_fin_client' THEN
    SELECT COALESCE(sum(CASE WHEN c.type_cycle = 3 THEN l.montant_collecte ELSE l.mise_appliquee END), 0)
      INTO v_prod
      FROM mf.ligne_collecte l
      JOIN mf.cycle c   ON c.id = l.cycle_id
      JOIN mf.affectation_zone a ON a.zone_id = mf.zone_client_a_date(c.client_id, l.date_collecte) AND a.collectrice_id = p_collectrice
           AND l.date_collecte >= a.date_debut AND (a.date_fin IS NULL OR l.date_collecte <= a.date_fin)
     WHERE l.origine = 'collecte' AND l.date_collecte BETWEEN p_du AND p_au;
  ELSE
    SELECT COALESCE(sum(CASE WHEN c.type_cycle = 3 THEN l.montant_collecte ELSE l.mise_appliquee END), 0)
      INTO v_prod
      FROM mf.cycle c
      JOIN mf.ligne_collecte l ON l.cycle_id = c.id AND l.origine = 'collecte'
      JOIN mf.affectation_zone a ON a.zone_id = mf.zone_client_a_date(c.client_id, c.date_cloture) AND a.collectrice_id = p_collectrice
           AND c.date_cloture >= a.date_debut AND (a.date_fin IS NULL OR c.date_cloture <= a.date_fin)
     WHERE c.statut IN ('clos','retire') AND c.date_cloture BETWEEN p_du AND p_au;
  END IF;
  RETURN v_prod;
END $$;

CREATE OR REPLACE FUNCTION rapport_journalier_zone(p_agence smallint, p_date date)
RETURNS TABLE (zone text, collectrice text, montant_collecte numeric, mises numeric, nb_lignes bigint,
               retraits numeric, remboursements numeric, ecarts_retrait numeric)
LANGUAGE sql STABLE AS $$
  SELECT z.code::text,
         (SELECT k.nom FROM mf.affectation_zone a JOIN mf.collectrice k ON k.id = a.collectrice_id
           WHERE a.zone_id = z.id AND p_date >= a.date_debut AND (a.date_fin IS NULL OR p_date <= a.date_fin) LIMIT 1)::text,
         COALESCE((SELECT sum(l.montant_collecte) FROM mf.ligne_collecte l JOIN mf.cycle c ON c.id = l.cycle_id
                    WHERE mf.zone_client_a_date(c.client_id, l.date_collecte) = z.id AND l.date_collecte = p_date AND l.origine = 'collecte'), 0)::numeric,
         COALESCE((SELECT sum(l.mise_appliquee) FROM mf.ligne_collecte l JOIN mf.cycle c ON c.id = l.cycle_id
                    WHERE mf.zone_client_a_date(c.client_id, l.date_collecte) = z.id AND l.date_collecte = p_date AND l.origine = 'collecte'), 0)::numeric,
         (SELECT count(*) FROM mf.ligne_collecte l JOIN mf.cycle c ON c.id = l.cycle_id
           WHERE mf.zone_client_a_date(c.client_id, l.date_collecte) = z.id AND l.date_collecte = p_date AND l.origine = 'collecte'),
         COALESCE((SELECT sum(r.montant_paye) FROM mf.retrait r JOIN mf.cycle c ON c.id = r.cycle_id
                    WHERE mf.zone_client_a_date(c.client_id, p_date) = z.id AND r.statut = 'execute' AND r.date_operation = p_date
                      AND r.nature IN ('retrait_client','virement_vers_epargne')), 0)::numeric,
         COALESCE((SELECT sum(p.capital + p.interet + p.penalite) FROM mf.paiement_echeance p JOIN mf.credit cr ON cr.id = p.credit_id
                    WHERE mf.zone_client_a_date(cr.client_id, p_date) = z.id AND p.date_operation = p_date), 0)::numeric,
         COALESCE((SELECT sum(d.perte) FROM mf.ecart_retrait_date d JOIN mf.ecart_retrait e ON e.id = d.ecart_id
                    JOIN mf.cycle c ON c.id = e.cycle_id
                    WHERE mf.zone_client_a_date(c.client_id, p_date) = z.id AND e.traite_le = p_date), 0)::numeric
    FROM mf.zone z WHERE z.agence_id = p_agence
   ORDER BY z.code
$$;

-- Piste d'audit
CREATE TRIGGER audit_client AFTER INSERT OR UPDATE OR DELETE ON client FOR EACH ROW EXECUTE FUNCTION trg_audit();
CREATE TRIGGER audit_client_transfert AFTER INSERT OR UPDATE OR DELETE ON client_transfert FOR EACH ROW EXECUTE FUNCTION trg_audit();
CREATE TRIGGER audit_compte_epargne AFTER INSERT OR UPDATE OR DELETE ON compte_epargne FOR EACH ROW EXECUTE FUNCTION trg_audit();
