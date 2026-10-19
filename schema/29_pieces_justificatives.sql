-- =====================================================================
-- 29_pieces_justificatives.sql
-- Pièces justificatives des opérations au guichet (reçus numérotés, remis au client et archivés) :
--   dépôt et retrait d'épargne, adhésion, souscription de parts, dépôt de garantie et sa libération, dépôt à terme et son
--   déblocage ou sa rupture, retrait de tontine.
--   Pas de pièce pour le dépôt de tontine (lignes de collecte). Les retraits de plusieurs cycles d'un même client se compilent
--   sur UNE seule pièce (une ligne par retrait).
-- Chaque ligne porte la source de l'opération (ex. « mouvement_epargne:12 », « retrait:5 ») : une opération n'a qu'une pièce
-- et un retrait de tontine ne figure que sur une pièce. Les pièces sont immuables (ni modification ni suppression).
-- Distinct des pièces comptables (module 05) : une pièce justificative est un document remis au client, pas une écriture.
-- Dépend de : 00, 01, 05 (numérotation).
-- =====================================================================
SET search_path = mf, public;

CREATE TABLE piece_justificative (
  id             serial PRIMARY KEY,
  agence_id      smallint NOT NULL REFERENCES agence(id),
  numero         varchar(25) NOT NULL,
  type           varchar(25) NOT NULL CHECK (type IN
                   ('depot_epargne','retrait_epargne','adhesion','souscription_parts','depot_garantie','liberation_garantie',
                    'depot_terme','deblocage_terme','rupture_terme','retrait_tontine')),
  client_id      integer NOT NULL REFERENCES client(id),
  compte_id      integer REFERENCES compte_epargne(id),
  date_piece     date NOT NULL,
  libelle        text NOT NULL,
  montant        numeric(14,0) NOT NULL CHECK (montant >= 0),
  utilisateur_id integer REFERENCES utilisateur(id),
  cree_le        timestamptz NOT NULL DEFAULT now(),
  UNIQUE (agence_id, numero)
);
CREATE INDEX piece_justificative_client ON piece_justificative (client_id, date_piece);
CREATE INDEX piece_justificative_date ON piece_justificative (agence_id, date_piece);
CREATE TRIGGER piece_justificative_numero BEFORE INSERT ON piece_justificative FOR EACH ROW EXECUTE FUNCTION trg_numerotation('PJ');

CREATE TABLE piece_justificative_ligne (
  id        serial PRIMARY KEY,
  piece_id  integer NOT NULL REFERENCES piece_justificative(id),
  ligne     smallint NOT NULL CHECK (ligne >= 1),
  libelle   text NOT NULL,
  montant   numeric(14,0) NOT NULL CHECK (montant >= 0),
  source    varchar(60) NOT NULL UNIQUE,
  UNIQUE (piece_id, ligne)
);

CREATE FUNCTION trg_piece_immuable() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  RAISE EXCEPTION 'une pièce justificative est immuable (%)', TG_OP;
END $$;
CREATE TRIGGER piece_justificative_immuable BEFORE UPDATE OR DELETE ON piece_justificative FOR EACH ROW EXECUTE FUNCTION trg_piece_immuable();
CREATE TRIGGER piece_justificative_ligne_immuable BEFORE UPDATE OR DELETE ON piece_justificative_ligne FOR EACH ROW EXECUTE FUNCTION trg_piece_immuable();

-- Crée une pièce : p_lignes = tableau JSON de {libelle, montant, source}. Retourne l'id de la pièce.
CREATE FUNCTION creer_piece(p_type text, p_client integer, p_compte integer, p_date date, p_libelle text, p_lignes jsonb,
                            p_utilisateur integer DEFAULT NULL) RETURNS integer
LANGUAGE plpgsql AS $$
DECLARE c mf.client; v_id integer; l jsonb; v_n smallint := 0; v_total numeric := 0;
BEGIN
  SELECT * INTO c FROM mf.client WHERE id = p_client;
  IF NOT FOUND THEN RAISE EXCEPTION 'client % inconnu', p_client; END IF;
  IF p_lignes IS NULL OR jsonb_typeof(p_lignes) <> 'array' OR jsonb_array_length(p_lignes) = 0 THEN
    RAISE EXCEPTION 'une pièce justificative a au moins une ligne';
  END IF;
  IF p_compte IS NOT NULL AND NOT EXISTS (SELECT 1 FROM mf.compte_epargne WHERE id = p_compte AND client_id = p_client) THEN
    RAISE EXCEPTION 'le compte % n''appartient pas au client %', p_compte, p_client;
  END IF;
  FOR l IN SELECT * FROM jsonb_array_elements(p_lignes) LOOP
    IF EXISTS (SELECT 1 FROM mf.piece_justificative_ligne WHERE source = l->>'source') THEN
      RAISE EXCEPTION 'l''opération % a déjà une pièce justificative', l->>'source';
    END IF;
    v_total := v_total + (l->>'montant')::numeric;
  END LOOP;
  INSERT INTO mf.piece_justificative(agence_id, type, client_id, compte_id, date_piece, libelle, montant, utilisateur_id)
  VALUES (c.agence_id, p_type, p_client, p_compte, p_date, p_libelle, v_total, p_utilisateur) RETURNING id INTO v_id;
  FOR l IN SELECT * FROM jsonb_array_elements(p_lignes) LOOP
    v_n := v_n + 1;
    INSERT INTO mf.piece_justificative_ligne(piece_id, ligne, libelle, montant, source) VALUES (v_id, v_n, l->>'libelle', (l->>'montant')::numeric, l->>'source');
  END LOOP;
  RETURN v_id;
END $$;

-- Pièce unique pour les retraits de tontine exécutés d'un même client (plusieurs cycles sur la même pièce).
-- Sont admis les retraits « retrait_client » et « virement_vers_epargne » exécutés ; les remboursements de crédit ne le sont pas.
CREATE FUNCTION creer_piece_retraits_tontine(p_retraits integer[], p_date date DEFAULT current_date, p_utilisateur integer DEFAULT NULL) RETURNS integer
LANGUAGE plpgsql AS $$
DECLARE r record; v_client integer; v_lignes jsonb := '[]'::jsonb; v_nb integer := 0;
BEGIN
  IF p_retraits IS NULL OR cardinality(p_retraits) = 0 THEN RAISE EXCEPTION 'aucun retrait sélectionné'; END IF;
  IF cardinality(p_retraits) <> (SELECT count(DISTINCT x) FROM unnest(p_retraits) x) THEN RAISE EXCEPTION 'retrait sélectionné plusieurs fois'; END IF;
  FOR r IN SELECT rt.id, rt.nature, rt.statut, rt.montant_paye, rt.date_operation, cy.numero AS cycle, cy.client_id, ce.numero AS compte
             FROM unnest(p_retraits) WITH ORDINALITY u(id, ord)
             LEFT JOIN mf.retrait rt ON rt.id = u.id
             LEFT JOIN mf.cycle cy ON cy.id = rt.cycle_id
             LEFT JOIN mf.virement v ON v.retrait_id = rt.id
             LEFT JOIN mf.compte_epargne ce ON ce.id = v.compte_id
            ORDER BY u.ord LOOP
    IF r.id IS NULL THEN RAISE EXCEPTION 'retrait inconnu'; END IF;
    IF r.nature NOT IN ('retrait_client', 'virement_vers_epargne') THEN RAISE EXCEPTION 'le retrait % n''est pas un retrait de tontine', r.id; END IF;
    IF r.statut <> 'execute' THEN RAISE EXCEPTION 'le retrait % n''est pas exécuté', r.id; END IF;
    IF v_client IS NULL THEN v_client := r.client_id;
    ELSIF v_client <> r.client_id THEN RAISE EXCEPTION 'les retraits d''une même pièce doivent concerner le même client'; END IF;
    v_nb := v_nb + 1;
    v_lignes := v_lignes || jsonb_build_object(
      'libelle', CASE WHEN r.nature = 'virement_vers_epargne' THEN 'Virement du cycle ' || r.cycle || ' vers le compte ' || COALESCE(r.compte, '?')
                      ELSE 'Retrait du cycle ' || r.cycle END || ' (exécuté le ' || to_char(r.date_operation, 'DD/MM/YYYY') || ')',
      'montant', COALESCE(r.montant_paye, 0), 'source', 'retrait:' || r.id);
  END LOOP;
  RETURN mf.creer_piece('retrait_tontine', v_client, NULL, p_date,
                        CASE WHEN v_nb = 1 THEN 'Retrait de tontine' ELSE 'Retraits de tontine : ' || v_nb || ' cycles' END, v_lignes, p_utilisateur);
END $$;
