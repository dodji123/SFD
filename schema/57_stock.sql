-- =====================================================================
-- 57_stock.sql
-- Stock des fournitures : consommables (livrets, reçus, papeterie) en quantité, immobilisations (matériel) à l'unité.
--   * articles : catalogue, seuil d'alerte, coût moyen pondéré ; un article « immobilisable » (téléphone, ordinateur, coffre...)
--     n'a pas de quantité : chaque unité est une ligne du registre des immobilisations (module 52, colonne article_id)
--   * lieux de stock : siège, agence, agent (un lieu par agent)
--   * mouvements en AJOUT SEUL : entrée, sortie, transfert (deux lignes), inventaire (écart), rebut ; solde par vue, jamais négatif
--   * demandes : sortie, rebut, ajustement d'inventaire et mise au rebut d'une immobilisation exigent la décision d'UNE AUTRE personne
--     (contrôlée par la base : un mouvement sensible sans demande validée par un autre utilisateur est refusé)
--   * valorisation au coût moyen pondéré ; alertes de seuil par périmètre (siège, agence avec ses agents)
--   * affectation des immobilisations à un agent (historique), clôturée à la sortie de l'immobilisation
--   * écritures comptables des consommables d'une agence ou du siège (entrée, sortie, rebut, écart d'inventaire) si la comptabilisation automatique est active ;
--     la pièce est retrouvée par v_mouvement_stock (reference_table = 'mouvement_stock')
-- Dépend de : 00 (agence, utilisateur), 05 (comptabilité), 10 (comptabiliser), 18 (trg_ajout_seul), 51 (tiers), 52 (immobilisations).
-- =====================================================================
SET search_path = mf, public;

-- ---------------------------------------------------------------- articles
CREATE TABLE article (
  id                       serial PRIMARY KEY,
  code                     varchar(30) NOT NULL UNIQUE CHECK (code ~ '^[A-Z0-9_-]+$'),
  designation              text NOT NULL CHECK (length(btrim(designation)) >= 3),
  type                     varchar(14) NOT NULL CHECK (type IN ('consommable','immobilisable')),
  unite                    varchar(20) NOT NULL DEFAULT 'unité',
  seuil_alerte             numeric(14,3) NOT NULL DEFAULT 0 CHECK (seuil_alerte >= 0),
  categorie_immobilisation varchar(30) REFERENCES categorie_immobilisation(code),
  cout_moyen               numeric(14,2) NOT NULL DEFAULT 0 CHECK (cout_moyen >= 0),
  actif                    boolean NOT NULL DEFAULT true,
  cree_le                  timestamptz NOT NULL DEFAULT now(),
  CHECK ((type = 'immobilisable') = (categorie_immobilisation IS NOT NULL))
);
COMMENT ON COLUMN article.cout_moyen IS 'Coût moyen pondéré des consommables, tenu à jour par les entrées (jamais saisi).';

CREATE FUNCTION trg_article_regles() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF (NEW.code, NEW.type) IS DISTINCT FROM (OLD.code, OLD.type) THEN RAISE EXCEPTION 'Le code et le type d''un article ne se modifient pas'; END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER article_regles BEFORE UPDATE ON article FOR EACH ROW EXECUTE FUNCTION trg_article_regles();
CREATE TRIGGER audit_article AFTER INSERT OR UPDATE ON article FOR EACH ROW EXECUTE FUNCTION trg_audit();

-- ---------------------------------------------------------------- lieux
CREATE TABLE lieu_stock (
  id             serial PRIMARY KEY,
  type           varchar(6) NOT NULL CHECK (type IN ('siege','agence','agent')),
  agence_id      smallint REFERENCES agence(id),
  utilisateur_id integer REFERENCES utilisateur(id),
  libelle        text NOT NULL,
  actif          boolean NOT NULL DEFAULT true,
  CHECK ((type = 'siege' AND agence_id IS NULL AND utilisateur_id IS NULL)
      OR (type = 'agence' AND agence_id IS NOT NULL AND utilisateur_id IS NULL)
      OR (type = 'agent' AND agence_id IS NOT NULL AND utilisateur_id IS NOT NULL))
);
CREATE UNIQUE INDEX lieu_stock_siege ON lieu_stock(type) WHERE type = 'siege';
CREATE UNIQUE INDEX lieu_stock_agence ON lieu_stock(agence_id) WHERE type = 'agence';
CREATE UNIQUE INDEX lieu_stock_agent ON lieu_stock(utilisateur_id) WHERE type = 'agent';
CREATE TRIGGER audit_lieu_stock AFTER INSERT OR UPDATE ON lieu_stock FOR EACH ROW EXECUTE FUNCTION trg_audit();
INSERT INTO lieu_stock(type, libelle) VALUES ('siege', 'Siège');

-- retrouve ou crée le lieu d'une agence ou d'un agent
CREATE FUNCTION lieu_stock_pour(p_type text, p_agence smallint, p_utilisateur integer DEFAULT NULL) RETURNS integer
LANGUAGE plpgsql AS $$
DECLARE v_id integer; u mf.utilisateur; k mf.agence;
BEGIN
  IF p_type = 'siege' THEN
    SELECT id INTO v_id FROM mf.lieu_stock WHERE type = 'siege';
  ELSIF p_type = 'agence' THEN
    SELECT id INTO v_id FROM mf.lieu_stock WHERE type = 'agence' AND agence_id = p_agence;
    IF v_id IS NULL THEN
      SELECT * INTO k FROM mf.agence WHERE id = p_agence;
      IF k.id IS NULL THEN RAISE EXCEPTION 'Agence inconnue'; END IF;
      INSERT INTO mf.lieu_stock(type, agence_id, libelle) VALUES ('agence', p_agence, 'Agence ' || k.libelle) RETURNING id INTO v_id;
    END IF;
  ELSIF p_type = 'agent' THEN
    SELECT id INTO v_id FROM mf.lieu_stock WHERE type = 'agent' AND utilisateur_id = p_utilisateur;
    IF v_id IS NULL THEN
      SELECT * INTO u FROM mf.utilisateur WHERE id = p_utilisateur AND actif;
      IF u.id IS NULL OR u.agence_id IS NULL THEN RAISE EXCEPTION 'Agent inconnu, inactif ou sans agence'; END IF;
      INSERT INTO mf.lieu_stock(type, agence_id, utilisateur_id, libelle) VALUES ('agent', u.agence_id, u.id, 'Agent ' || u.nom) RETURNING id INTO v_id;
    END IF;
  ELSE
    RAISE EXCEPTION 'Type de lieu inconnu';
  END IF;
  RETURN v_id;
END $$;

-- ---------------------------------------------------------------- demandes (décision par une autre personne)
CREATE TABLE demande_stock (
  id                serial PRIMARY KEY,
  type              varchar(20) NOT NULL CHECK (type IN ('sortie','rebut','inventaire','rebut_immobilisation')),
  article_id        integer REFERENCES article(id),
  lieu_id           integer REFERENCES lieu_stock(id),
  immobilisation_id integer REFERENCES immobilisation(id),
  quantite          numeric(14,3) CHECK (quantite >= 0),         -- sortie, rebut : quantité à retirer (> 0) ; inventaire : quantité comptée
  date_effet        date NOT NULL DEFAULT current_date,
  motif             text NOT NULL CHECK (length(btrim(motif)) >= 5),
  statut            varchar(10) NOT NULL DEFAULT 'en_attente' CHECK (statut IN ('en_attente','validee','rejetee')),
  demande_par       integer NOT NULL REFERENCES utilisateur(id),
  demande_le        timestamptz NOT NULL DEFAULT now(),
  decide_par        integer REFERENCES utilisateur(id),
  decide_le         timestamptz,
  motif_decision    text,
  CHECK ((type IN ('sortie','rebut','inventaire') AND article_id IS NOT NULL AND lieu_id IS NOT NULL AND quantite IS NOT NULL AND immobilisation_id IS NULL
          AND (type = 'inventaire' OR quantite > 0))
      OR (type = 'rebut_immobilisation' AND immobilisation_id IS NOT NULL AND article_id IS NULL AND lieu_id IS NULL AND quantite IS NULL)),
  CHECK ((statut = 'en_attente') = (decide_par IS NULL)),
  CHECK (decide_par IS NULL OR decide_par <> demande_par)
);
CREATE INDEX demande_stock_statut ON demande_stock(statut);

CREATE FUNCTION trg_demande_stock_regles() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE a mf.article;
BEGIN
  IF TG_OP = 'DELETE' THEN RAISE EXCEPTION 'Une demande de stock ne se supprime pas'; END IF;
  IF TG_OP = 'INSERT' THEN
    IF NEW.article_id IS NOT NULL THEN
      SELECT * INTO a FROM mf.article WHERE id = NEW.article_id AND actif;
      IF a.id IS NULL OR a.type <> 'consommable' THEN RAISE EXCEPTION 'Article inconnu, inactif ou sans quantité (immobilisable)'; END IF;
    END IF;
    NEW.statut := 'en_attente'; NEW.decide_par := NULL; NEW.decide_le := NULL;
    RETURN NEW;
  END IF;
  IF OLD.statut <> 'en_attente' THEN RAISE EXCEPTION 'Cette demande est déjà décidée'; END IF;
  IF NEW.decide_par IS NULL OR NEW.decide_par = OLD.demande_par THEN
    RAISE EXCEPTION 'La décision doit venir d''une autre personne que le demandeur';
  END IF;
  IF (to_jsonb(NEW) - 'statut' - 'decide_par' - 'decide_le' - 'motif_decision') <> (to_jsonb(OLD) - 'statut' - 'decide_par' - 'decide_le' - 'motif_decision') THEN
    RAISE EXCEPTION 'Seule la décision peut être renseignée';
  END IF;
  NEW.decide_le := now();
  RETURN NEW;
END $$;
CREATE TRIGGER demande_stock_regles BEFORE INSERT OR UPDATE OR DELETE ON demande_stock FOR EACH ROW EXECUTE FUNCTION trg_demande_stock_regles();
CREATE TRIGGER audit_demande_stock AFTER INSERT OR UPDATE ON demande_stock FOR EACH ROW EXECUTE FUNCTION trg_audit();

-- ---------------------------------------------------------------- mouvements (ajout seul)
CREATE SEQUENCE mouvement_stock_groupe_seq;
CREATE TABLE mouvement_stock (
  id                bigserial PRIMARY KEY,
  groupe_id         bigint NOT NULL DEFAULT nextval('mouvement_stock_groupe_seq'),   -- commun aux deux lignes d'un transfert
  date_mouvement    date NOT NULL DEFAULT current_date,
  type              varchar(10) NOT NULL CHECK (type IN ('entree','sortie','transfert','inventaire','rebut')),
  article_id        integer NOT NULL REFERENCES article(id),
  lieu_id           integer NOT NULL REFERENCES lieu_stock(id),
  quantite          numeric(14,3) NOT NULL CHECK (quantite <> 0),                    -- signée : + entre dans le lieu, - en sort
  cout_unitaire     numeric(14,2) NOT NULL DEFAULT 0 CHECK (cout_unitaire >= 0),
  demande_id        integer REFERENCES demande_stock(id),
  reference_facture text,
  tiers_id          integer REFERENCES tiers(id),
  motif             text,
  cree_par          integer REFERENCES utilisateur(id),
  cree_le           timestamptz NOT NULL DEFAULT now(),
  CHECK ((type = 'entree' AND quantite > 0) OR (type IN ('sortie','rebut') AND quantite < 0) OR type IN ('transfert','inventaire'))
);
CREATE INDEX mouvement_stock_article_lieu ON mouvement_stock(article_id, lieu_id);
CREATE TRIGGER mouvement_stock_ajout_seul BEFORE UPDATE OR DELETE ON mouvement_stock FOR EACH ROW EXECUTE FUNCTION trg_ajout_seul();
CREATE TRIGGER mouvement_stock_pas_de_vidage BEFORE TRUNCATE ON mouvement_stock FOR EACH STATEMENT EXECUTE FUNCTION trg_ajout_seul();
CREATE TRIGGER audit_mouvement_stock AFTER INSERT ON mouvement_stock FOR EACH ROW EXECUTE FUNCTION trg_audit();

CREATE FUNCTION solde_stock(p_article integer, p_lieu integer) RETURNS numeric LANGUAGE sql STABLE AS $$
  SELECT COALESCE(sum(quantite), 0) FROM mf.mouvement_stock WHERE article_id = p_article AND lieu_id = p_lieu $$;

CREATE FUNCTION trg_mouvement_stock_regles() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE a mf.article; l mf.lieu_stock; d mf.demande_stock; v_total numeric;
BEGIN
  SELECT * INTO a FROM mf.article WHERE id = NEW.article_id FOR UPDATE;              -- sérialise les mouvements d'un même article
  IF a.id IS NULL OR NOT a.actif THEN RAISE EXCEPTION 'Article inconnu ou inactif'; END IF;
  IF a.type <> 'consommable' THEN RAISE EXCEPTION 'Un article immobilisable n''a pas de quantité : ses unités sont au registre des immobilisations'; END IF;
  SELECT * INTO l FROM mf.lieu_stock WHERE id = NEW.lieu_id AND actif;
  IF l.id IS NULL THEN RAISE EXCEPTION 'Lieu de stock inconnu ou inactif'; END IF;

  -- sortie, rebut, ajustement d'inventaire : demande validée par une autre personne que le demandeur
  IF NEW.type IN ('sortie','rebut','inventaire') THEN
    SELECT * INTO d FROM mf.demande_stock WHERE id = NEW.demande_id;
    IF d.id IS NULL OR d.statut <> 'validee' OR d.decide_par IS NULL OR d.decide_par = d.demande_par
       OR d.type <> NEW.type OR d.article_id <> NEW.article_id OR d.lieu_id <> NEW.lieu_id THEN
      RAISE EXCEPTION 'Ce mouvement exige une demande validée par une autre personne que le demandeur';
    END IF;
  END IF;

  SELECT COALESCE(sum(quantite), 0) INTO v_total FROM mf.mouvement_stock WHERE article_id = NEW.article_id;
  IF NEW.quantite < 0 AND mf.solde_stock(NEW.article_id, NEW.lieu_id) + NEW.quantite < 0 THEN
    RAISE EXCEPTION 'Stock insuffisant (disponible : %)', mf.solde_stock(NEW.article_id, NEW.lieu_id);
  END IF;
  IF NEW.type = 'entree' THEN
    IF NEW.cout_unitaire <= 0 THEN RAISE EXCEPTION 'Le coût unitaire d''une entrée est obligatoire'; END IF;
    UPDATE mf.article SET cout_moyen = round((v_total * a.cout_moyen + NEW.quantite * NEW.cout_unitaire) / (v_total + NEW.quantite), 2) WHERE id = a.id;
  ELSE
    NEW.cout_unitaire := a.cout_moyen;                                              -- les autres mouvements sont valorisés au coût moyen
  END IF;
  IF NEW.type <> 'entree' AND (NEW.motif IS NULL OR length(btrim(NEW.motif)) < 5) THEN RAISE EXCEPTION 'Le motif est obligatoire'; END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER mouvement_stock_regles BEFORE INSERT ON mouvement_stock FOR EACH ROW EXECUTE FUNCTION trg_mouvement_stock_regles();

-- écritures des consommables : celles de l'agence du lieu, ou de l'agence « siège » (agence.siege) pour le lieu Siège
INSERT INTO regle_comptable(evenement, ligne, compte_debit, compte_credit, cle_montant, journal_code, libelle) VALUES
  ('stock_entree',      1, '3231',  '33211', 'montant', 'OD', 'Entrée en stock de fournitures'),
  ('stock_sortie',      1, '612',   '3231',  'montant', 'OD', 'Sortie de stock (consommation)'),
  ('stock_rebut',       1, '62392', '3231',  'montant', 'OD', 'Mise au rebut de fournitures'),
  ('stock_ecart_plus',  1, '3231',  '612',   'montant', 'OD', 'Inventaire : excédent de stock'),
  ('stock_ecart_moins', 1, '62392', '3231',  'montant', 'OD', 'Inventaire : manquant de stock');

CREATE FUNCTION trg_mouvement_stock_compta() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE v_agence smallint; v_evt text;
BEGIN
  v_evt := CASE NEW.type WHEN 'entree' THEN 'stock_entree' WHEN 'sortie' THEN 'stock_sortie' WHEN 'rebut' THEN 'stock_rebut'
                         WHEN 'inventaire' THEN CASE WHEN NEW.quantite > 0 THEN 'stock_ecart_plus' ELSE 'stock_ecart_moins' END END;
  IF v_evt IS NULL THEN RETURN NULL; END IF;
  SELECT agence_id INTO v_agence FROM mf.lieu_stock WHERE id = NEW.lieu_id;
  IF v_agence IS NULL THEN SELECT id INTO v_agence FROM mf.agence WHERE siege AND actif ORDER BY id LIMIT 1; END IF;   -- le siège tient sa propre comptabilité
  IF v_agence IS NOT NULL AND mf.comptabilisation_active(v_agence) AND NEW.cout_unitaire > 0 THEN
    PERFORM mf.comptabiliser(v_evt, v_agence, NEW.date_mouvement, jsonb_build_object('montant', round(abs(NEW.quantite) * NEW.cout_unitaire)),
                             'mouvement_stock', NEW.id, 'Stock : ' || NEW.type || ' ' || COALESCE(NEW.reference_facture, ''), NEW.cree_par);
  END IF;
  RETURN NULL;
END $$;
CREATE TRIGGER mouvement_stock_compta AFTER INSERT ON mouvement_stock FOR EACH ROW EXECUTE FUNCTION trg_mouvement_stock_compta();

-- entrée en stock
CREATE FUNCTION entrer_stock(p_article integer, p_lieu integer, p_quantite numeric, p_cout numeric, p_date date, p_facture text, p_tiers integer, p_utilisateur integer) RETURNS bigint
LANGUAGE plpgsql AS $$
DECLARE v_id bigint;
BEGIN
  IF p_tiers IS NOT NULL AND NOT EXISTS (SELECT 1 FROM mf.tiers WHERE id = p_tiers AND actif) THEN RAISE EXCEPTION 'Fournisseur inconnu ou inactif'; END IF;
  INSERT INTO mf.mouvement_stock(date_mouvement, type, article_id, lieu_id, quantite, cout_unitaire, reference_facture, tiers_id, motif, cree_par)
    VALUES (COALESCE(p_date, current_date), 'entree', p_article, p_lieu, p_quantite, p_cout, p_facture, p_tiers, 'Entrée en stock', p_utilisateur) RETURNING id INTO v_id;
  RETURN v_id;
END $$;

-- transfert entre deux lieux : deux lignes de même groupe
CREATE FUNCTION transferer_stock(p_article integer, p_source integer, p_destination integer, p_quantite numeric, p_date date, p_motif text, p_utilisateur integer) RETURNS bigint
LANGUAGE plpgsql AS $$
DECLARE v_groupe bigint := nextval('mf.mouvement_stock_groupe_seq');
BEGIN
  IF p_source = p_destination THEN RAISE EXCEPTION 'Le lieu d''origine et le lieu de destination sont identiques'; END IF;
  IF p_quantite IS NULL OR p_quantite <= 0 THEN RAISE EXCEPTION 'La quantité transférée doit être positive'; END IF;
  INSERT INTO mf.mouvement_stock(groupe_id, date_mouvement, type, article_id, lieu_id, quantite, motif, cree_par)
    VALUES (v_groupe, COALESCE(p_date, current_date), 'transfert', p_article, p_source, -p_quantite, p_motif, p_utilisateur);
  INSERT INTO mf.mouvement_stock(groupe_id, date_mouvement, type, article_id, lieu_id, quantite, motif, cree_par)
    VALUES (v_groupe, COALESCE(p_date, current_date), 'transfert', p_article, p_destination, p_quantite, p_motif, p_utilisateur);
  RETURN v_groupe;
END $$;

-- décision sur une demande : l'effet (mouvement ou sortie d'immobilisation) n'a lieu qu'à la validation
CREATE FUNCTION decider_demande_stock(p_id integer, p_valider boolean, p_utilisateur integer, p_motif text) RETURNS text
LANGUAGE plpgsql AS $$
DECLARE d mf.demande_stock; v_solde numeric; v_ecart numeric;
BEGIN
  SELECT * INTO d FROM mf.demande_stock WHERE id = p_id FOR UPDATE;
  IF d.id IS NULL THEN RAISE EXCEPTION 'Demande introuvable'; END IF;
  IF d.statut <> 'en_attente' THEN RAISE EXCEPTION 'Cette demande est déjà décidée'; END IF;
  IF p_utilisateur = d.demande_par THEN RAISE EXCEPTION 'La décision doit venir d''une autre personne que le demandeur'; END IF;
  IF NOT p_valider AND length(btrim(COALESCE(p_motif, ''))) < 5 THEN RAISE EXCEPTION 'Le motif du rejet est obligatoire'; END IF;
  UPDATE mf.demande_stock SET statut = CASE WHEN p_valider THEN 'validee' ELSE 'rejetee' END, decide_par = p_utilisateur, motif_decision = p_motif WHERE id = p_id;
  IF NOT p_valider THEN RETURN 'rejetee'; END IF;
  IF d.type IN ('sortie','rebut') THEN
    INSERT INTO mf.mouvement_stock(date_mouvement, type, article_id, lieu_id, quantite, demande_id, motif, cree_par)
      VALUES (d.date_effet, d.type, d.article_id, d.lieu_id, -d.quantite, d.id, d.motif, p_utilisateur);
  ELSIF d.type = 'inventaire' THEN
    v_solde := mf.solde_stock(d.article_id, d.lieu_id);
    v_ecart := d.quantite - v_solde;
    IF v_ecart <> 0 THEN
      INSERT INTO mf.mouvement_stock(date_mouvement, type, article_id, lieu_id, quantite, demande_id, motif, cree_par)
        VALUES (d.date_effet, 'inventaire', d.article_id, d.lieu_id, v_ecart, d.id, d.motif, p_utilisateur);
    END IF;
  ELSE
    PERFORM mf.sortir_immobilisation(d.immobilisation_id, d.date_effet, 'rebut', NULL, d.motif, p_utilisateur);
  END IF;
  RETURN 'validee';
END $$;

-- ---------------------------------------------------------------- vues : soldes, valorisation, alertes
CREATE VIEW v_solde_stock AS
SELECT m.article_id, a.code AS article_code, a.designation, a.unite, m.lieu_id, l.libelle AS lieu, l.type AS lieu_type, l.agence_id,
       sum(m.quantite) AS quantite, a.cout_moyen, round(sum(m.quantite) * a.cout_moyen)::numeric(14,0) AS valeur
FROM mf.mouvement_stock m
JOIN mf.article a ON a.id = m.article_id
JOIN mf.lieu_stock l ON l.id = m.lieu_id
GROUP BY m.article_id, a.code, a.designation, a.unite, a.cout_moyen, m.lieu_id, l.libelle, l.type, l.agence_id;

-- périmètre = siège (agence_id vide) ou agence avec ses agents
CREATE VIEW v_alerte_stock AS
SELECT s.agence_id, s.article_id, s.article_code, s.designation, s.unite, sum(s.quantite) AS quantite, a.seuil_alerte,
       (sum(s.quantite) <= 0) AS rupture
FROM mf.v_solde_stock s JOIN mf.article a ON a.id = s.article_id
WHERE a.seuil_alerte > 0 AND a.actif
GROUP BY s.agence_id, s.article_id, s.article_code, s.designation, s.unite, a.seuil_alerte
HAVING sum(s.quantite) <= a.seuil_alerte;

CREATE VIEW v_mouvement_stock AS
SELECT m.*, a.code AS article_code, a.designation, a.unite, l.libelle AS lieu, l.agence_id, u.nom AS cree_par_nom,
       round(abs(m.quantite) * m.cout_unitaire)::numeric(14,0) AS valeur,
       p.id AS piece_id, p.numero AS piece_numero
FROM mf.mouvement_stock m
JOIN mf.article a ON a.id = m.article_id
JOIN mf.lieu_stock l ON l.id = m.lieu_id
LEFT JOIN mf.utilisateur u ON u.id = m.cree_par
LEFT JOIN mf.piece_comptable p ON p.reference_table = 'mouvement_stock' AND p.reference_id = m.id;

CREATE VIEW v_demande_stock AS
SELECT d.*, a.code AS article_code, a.designation, l.libelle AS lieu, l.agence_id AS lieu_agence_id, i.numero AS immobilisation_numero, i.agence_id AS immo_agence_id,
       COALESCE(l.agence_id, i.agence_id) AS agence_id, u1.nom AS demande_par_nom, u2.nom AS decide_par_nom
FROM mf.demande_stock d
LEFT JOIN mf.article a ON a.id = d.article_id
LEFT JOIN mf.lieu_stock l ON l.id = d.lieu_id
LEFT JOIN mf.immobilisation i ON i.id = d.immobilisation_id
LEFT JOIN mf.utilisateur u1 ON u1.id = d.demande_par
LEFT JOIN mf.utilisateur u2 ON u2.id = d.decide_par;

-- ---------------------------------------------------------------- immobilisations : article et affectation à un agent
ALTER TABLE immobilisation ADD COLUMN article_id integer REFERENCES article(id);

CREATE TABLE affectation_immobilisation (
  id                serial PRIMARY KEY,
  immobilisation_id integer NOT NULL REFERENCES immobilisation(id),
  utilisateur_id    integer NOT NULL REFERENCES utilisateur(id),
  date_debut        date NOT NULL DEFAULT current_date,
  date_fin          date,
  motif             text,
  cree_par          integer REFERENCES utilisateur(id),
  cree_le           timestamptz NOT NULL DEFAULT now(),
  CHECK (date_fin IS NULL OR date_fin >= date_debut)
);
CREATE UNIQUE INDEX affectation_immobilisation_ouverte ON affectation_immobilisation(immobilisation_id) WHERE date_fin IS NULL;

CREATE FUNCTION trg_affectation_immobilisation_regles() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE i mf.immobilisation; u mf.utilisateur;
BEGIN
  IF TG_OP = 'DELETE' THEN RAISE EXCEPTION 'L''historique des affectations ne se supprime pas'; END IF;
  IF TG_OP = 'INSERT' THEN
    SELECT * INTO i FROM mf.immobilisation WHERE id = NEW.immobilisation_id;
    IF i.id IS NULL OR i.statut = 'sortie' THEN RAISE EXCEPTION 'Immobilisation inconnue ou sortie de l''inventaire'; END IF;
    SELECT * INTO u FROM mf.utilisateur WHERE id = NEW.utilisateur_id AND actif;
    IF u.id IS NULL OR u.agence_id IS DISTINCT FROM i.agence_id THEN RAISE EXCEPTION 'L''agent doit être actif et de la même agence que l''immobilisation'; END IF;
    NEW.date_fin := NULL;
    RETURN NEW;
  END IF;
  IF OLD.date_fin IS NOT NULL THEN RAISE EXCEPTION 'Cette affectation est déjà clôturée'; END IF;
  IF NEW.date_fin IS NULL OR (to_jsonb(NEW) - 'date_fin') <> (to_jsonb(OLD) - 'date_fin') THEN RAISE EXCEPTION 'Seule la date de fin peut être renseignée'; END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER affectation_immobilisation_regles BEFORE INSERT OR UPDATE OR DELETE ON affectation_immobilisation FOR EACH ROW EXECUTE FUNCTION trg_affectation_immobilisation_regles();
CREATE TRIGGER audit_affectation_immobilisation AFTER INSERT OR UPDATE ON affectation_immobilisation FOR EACH ROW EXECUTE FUNCTION trg_audit();

-- affecte (ou réaffecte) une immobilisation à un agent : l'affectation en cours est clôturée à la veille
CREATE FUNCTION affecter_immobilisation(p_immobilisation integer, p_utilisateur integer, p_date date, p_motif text, p_par integer) RETURNS integer
LANGUAGE plpgsql AS $$
DECLARE v_id integer; o mf.affectation_immobilisation;
BEGIN
  SELECT * INTO o FROM mf.affectation_immobilisation WHERE immobilisation_id = p_immobilisation AND date_fin IS NULL FOR UPDATE;
  IF o.id IS NOT NULL THEN
    IF o.utilisateur_id = p_utilisateur THEN RAISE EXCEPTION 'Cette immobilisation est déjà affectée à cet agent'; END IF;
    IF COALESCE(p_date, current_date) < o.date_debut THEN RAISE EXCEPTION 'La nouvelle affectation ne peut précéder la précédente'; END IF;
    UPDATE mf.affectation_immobilisation SET date_fin = COALESCE(p_date, current_date) WHERE id = o.id;
  END IF;
  INSERT INTO mf.affectation_immobilisation(immobilisation_id, utilisateur_id, date_debut, motif, cree_par)
    VALUES (p_immobilisation, p_utilisateur, COALESCE(p_date, current_date), p_motif, p_par) RETURNING id INTO v_id;
  RETURN v_id;
END $$;

CREATE FUNCTION restituer_immobilisation(p_immobilisation integer, p_date date) RETURNS void
LANGUAGE plpgsql AS $$
BEGIN
  UPDATE mf.affectation_immobilisation SET date_fin = GREATEST(COALESCE(p_date, current_date), date_debut) WHERE immobilisation_id = p_immobilisation AND date_fin IS NULL;
  IF NOT FOUND THEN RAISE EXCEPTION 'Cette immobilisation n''est affectée à personne'; END IF;
END $$;

-- la sortie de l'inventaire clôture l'affectation en cours
CREATE FUNCTION trg_immobilisation_sortie_affectation() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  UPDATE mf.affectation_immobilisation SET date_fin = GREATEST(NEW.date_sortie, date_debut) WHERE immobilisation_id = NEW.id AND date_fin IS NULL;
  RETURN NULL;
END $$;
CREATE TRIGGER immobilisation_sortie_affectation AFTER UPDATE ON immobilisation FOR EACH ROW WHEN (NEW.statut = 'sortie' AND OLD.statut <> 'sortie') EXECUTE FUNCTION trg_immobilisation_sortie_affectation();

CREATE VIEW v_immobilisation_stock AS
SELECT v.*, i.article_id AS article_id, a.code AS article_code, a.designation AS article_designation, f.utilisateur_id AS affecte_a_id, u.nom AS affecte_a, f.date_debut AS affecte_depuis
FROM mf.v_immobilisation v
JOIN mf.immobilisation i ON i.id = v.id
LEFT JOIN mf.article a ON a.id = i.article_id
LEFT JOIN mf.affectation_immobilisation f ON f.immobilisation_id = v.id AND f.date_fin IS NULL
LEFT JOIN mf.utilisateur u ON u.id = f.utilisateur_id;
