-- =====================================================================
-- 80_releve_carnet.sql
-- Relevé du carnet du client pour un cycle de tontine : le contrôleur (ou le gérant) reporte, depuis le carnet,
--   * la date de début et la date de fin du cycle, la mise ;
--   * le total collecté page par page, montant non retiré (une ligne par page du carnet).
-- Un relevé par cycle : il ne se modifie pas et ne se supprime pas (piste d'audit).
-- Rapprochement carnet / machine (vue v_rapprochement_carnet) : dates, mise et total comparés ; l'écart est signalé
-- sans bloquer le cycle. Total machine = collecte du cycle - retraits clients et virements vers l'épargne non annulés
-- (même base que le rapport « solde à retirer »). Hypothèse : la mise n'est pas retranchée du total.
-- Dépend de : 01 (cycle, ligne_collecte, retrait, agence), 10 (trg_audit), 11 (utilisateur).
-- =====================================================================
SET search_path = mf, public;

CREATE TABLE releve_carnet (
  id           integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  agence_id    smallint NOT NULL REFERENCES agence(id),
  cycle_id     integer NOT NULL UNIQUE REFERENCES cycle(id),   -- un relevé par cycle
  releveur_id  integer NOT NULL REFERENCES utilisateur(id),
  cle          text NOT NULL UNIQUE,                             -- identifiant de saisie : une saisie rejouée ne crée pas de doublon
  date_debut   date NOT NULL,
  date_fin     date NOT NULL,
  mise         numeric(12,0) NOT NULL CHECK (mise > 0),
  total_carnet numeric(14,0) NOT NULL CHECK (total_carnet >= 0),
  cree_le      timestamptz NOT NULL DEFAULT now(),
  CHECK (date_fin >= date_debut)
);

CREATE TABLE releve_carnet_page (
  releve_id         integer NOT NULL REFERENCES releve_carnet(id),
  page              smallint NOT NULL CHECK (page > 0),
  montant_non_retire numeric(14,0) NOT NULL CHECK (montant_non_retire >= 0),
  PRIMARY KEY (releve_id, page)
);

CREATE FUNCTION trg_releve_carnet_fige() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  RAISE EXCEPTION 'Un relevé de carnet ne se modifie ni ne se supprime : il reste dans la piste d''audit';
END $$;
CREATE TRIGGER releve_carnet_fige BEFORE UPDATE OR DELETE ON releve_carnet
  FOR EACH ROW EXECUTE FUNCTION trg_releve_carnet_fige();
CREATE TRIGGER releve_carnet_page_fige BEFORE UPDATE OR DELETE ON releve_carnet_page
  FOR EACH ROW EXECUTE FUNCTION trg_releve_carnet_fige();
CREATE TRIGGER audit_releve_carnet AFTER INSERT ON releve_carnet FOR EACH ROW EXECUTE FUNCTION trg_audit();
CREATE TRIGGER audit_releve_carnet_page AFTER INSERT ON releve_carnet_page FOR EACH ROW EXECUTE FUNCTION trg_audit();

-- p_pages : tableau JSON [{"page": 1, "montant": 5000}, ...]. Rejouée avec la même clé : renvoie le relevé déjà enregistré.
CREATE FUNCTION enregistrer_releve_carnet(p_cycle integer, p_utilisateur integer, p_date_debut date, p_date_fin date,
                                          p_mise numeric, p_pages jsonb, p_cle text DEFAULT NULL)
RETURNS integer LANGUAGE plpgsql AS $$
DECLARE
  v_id integer;
  v_cycle integer;
  v_agence smallint;
  v_total numeric;
  v_cle text := COALESCE(p_cle, gen_random_uuid()::text);
BEGIN
  SELECT id, cycle_id INTO v_id, v_cycle FROM releve_carnet WHERE cle = v_cle;
  IF FOUND THEN
    IF v_cycle <> p_cycle THEN
      RAISE EXCEPTION 'Clé de saisie déjà utilisée pour un autre cycle';
    END IF;
    RETURN v_id;
  END IF;
  SELECT agence_id INTO v_agence FROM cycle WHERE id = p_cycle;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Cycle % introuvable', p_cycle;
  END IF;
  IF EXISTS (SELECT 1 FROM releve_carnet WHERE cycle_id = p_cycle) THEN
    RAISE EXCEPTION 'Ce cycle a déjà un relevé de carnet';
  END IF;
  IF p_pages IS NULL OR jsonb_typeof(p_pages) <> 'array' OR jsonb_array_length(p_pages) = 0 THEN
    RAISE EXCEPTION 'Le relevé doit comporter au moins une page';
  END IF;
  SELECT sum((e->>'montant')::numeric) INTO v_total FROM jsonb_array_elements(p_pages) e;
  INSERT INTO releve_carnet (agence_id, cycle_id, releveur_id, cle, date_debut, date_fin, mise, total_carnet)
  VALUES (v_agence, p_cycle, p_utilisateur, v_cle, p_date_debut, p_date_fin, p_mise, v_total)
  RETURNING id INTO v_id;
  INSERT INTO releve_carnet_page (releve_id, page, montant_non_retire)
  SELECT v_id, (e->>'page')::smallint, (e->>'montant')::numeric FROM jsonb_array_elements(p_pages) e;
  RETURN v_id;
END $$;

-- Rapprochement carnet / machine, un cycle par ligne (cycles sans relevé compris).
-- statut : 'sans_releve' | 'conforme' (dates, mise et total égaux) | 'ecart'. ecarts : rubriques qui diffèrent.
CREATE VIEW v_rapprochement_carnet AS
WITH machine AS (
  SELECT c.id AS cycle_id,
         COALESCE((SELECT sum(l.montant_collecte) FROM ligne_collecte l WHERE l.cycle_id = c.id), 0)
         - COALESCE((SELECT sum(r.montant) FROM retrait r WHERE r.cycle_id = c.id AND r.statut <> 'annule'
                       AND r.nature IN ('retrait_client','virement_vers_epargne')), 0) AS total
    FROM cycle c
), rapp AS (
  SELECT c.id AS cycle_id, c.agence_id, c.numero AS cycle_numero, cl.numero AS client_numero, cl.nom AS client,
         c.date_debut AS machine_debut, c.date_fin AS machine_fin, c.mise_initiale AS machine_mise, m.total AS machine_total,
         r.id AS releve_id, r.date_debut AS carnet_debut, r.date_fin AS carnet_fin, r.mise AS carnet_mise, r.total_carnet,
         ARRAY_REMOVE(ARRAY[
           CASE WHEN r.id IS NOT NULL AND (r.date_debut <> c.date_debut OR r.date_fin <> c.date_fin) THEN 'dates' END,
           CASE WHEN r.id IS NOT NULL AND r.mise <> c.mise_initiale THEN 'mise' END,
           CASE WHEN r.id IS NOT NULL AND r.total_carnet <> m.total THEN 'total' END], NULL) AS ecarts
    FROM cycle c
    JOIN client cl ON cl.id = c.client_id
    JOIN machine m ON m.cycle_id = c.id
    LEFT JOIN releve_carnet r ON r.cycle_id = c.id
)
SELECT cycle_id, agence_id, cycle_numero, client_numero, client, machine_debut, machine_fin, machine_mise, machine_total,
       releve_id, carnet_debut, carnet_fin, carnet_mise, total_carnet,
       CASE WHEN releve_id IS NULL THEN 'sans_releve' WHEN cardinality(ecarts) = 0 THEN 'conforme' ELSE 'ecart' END AS statut,
       ecarts,
       CASE WHEN releve_id IS NULL THEN NULL ELSE total_carnet - machine_total END AS ecart_total
  FROM rapp;
