-- =====================================================================
-- 39_grh_organisation.sql
-- Gestion des ressources humaines — organisation et dossier du personnel :
--   * services (arbre) et postes (fiches de poste, fourchette de salaire, effectif prévu)
--   * dossier de l'employé : état civil, contacts, personne à prévenir, pièce d'identité, CNSS, banque
--   * hiérarchie (supérieur direct, sans cycle) et organigramme
--   * pièces du dossier avec date d'expiration ; périodes d'essai et fins de contrat à surveiller
--   * agents commerciaux dans la RH : fiche RH créée depuis l'agent, tableau de bord par agent
-- Dépend de : 00, 04, 11.
-- =====================================================================
SET search_path = mf, public;

INSERT INTO parametre(cle, valeur, description) VALUES
  ('alerte_contrat_jours', '60', 'Jours avant la fin d''un CDD / stage pour signaler l''échéance'),
  ('alerte_essai_jours', '15', 'Jours avant la fin d''une période d''essai pour la signaler'),
  ('alerte_piece_jours', '60', 'Jours avant l''expiration d''une pièce du dossier pour la signaler');

CREATE TABLE service_rh (
  id          serial PRIMARY KEY,
  code        varchar(15) NOT NULL UNIQUE,
  libelle     text NOT NULL,
  parent_id   integer REFERENCES service_rh(id),
  actif       boolean NOT NULL DEFAULT true,
  CHECK (parent_id IS NULL OR parent_id <> id)
);

CREATE TABLE poste (
  id              serial PRIMARY KEY,
  code            varchar(15) NOT NULL UNIQUE,
  libelle         text NOT NULL,
  service_id      integer REFERENCES service_rh(id),
  description     text,
  competences     text,
  salaire_min     numeric(14,0) CHECK (salaire_min IS NULL OR salaire_min >= 0),
  salaire_max     numeric(14,0),
  effectif_prevu  smallint NOT NULL DEFAULT 1 CHECK (effectif_prevu >= 0),
  actif           boolean NOT NULL DEFAULT true,
  CHECK (salaire_max IS NULL OR salaire_min IS NULL OR salaire_max >= salaire_min)
);

ALTER TABLE employe
  ADD COLUMN poste_id            integer REFERENCES poste(id),
  ADD COLUMN service_id          integer REFERENCES service_rh(id),
  ADD COLUMN superieur_id        integer REFERENCES employe(id),
  ADD COLUMN sexe                char(1) CHECK (sexe IN ('F','M')),
  ADD COLUMN date_naissance      date CHECK (date_naissance IS NULL OR date_naissance < current_date),
  ADD COLUMN lieu_naissance      text,
  ADD COLUMN situation_familiale varchar(15) CHECK (situation_familiale IN ('celibataire','marie','divorce','veuf')),
  ADD COLUMN nb_enfants          smallint NOT NULL DEFAULT 0 CHECK (nb_enfants >= 0),
  ADD COLUMN telephone           varchar(30),
  ADD COLUMN email               varchar(200),
  ADD COLUMN adresse             text,
  ADD COLUMN urgence_nom         text,
  ADD COLUMN urgence_telephone   varchar(30),
  ADD COLUMN piece_identite      text,
  ADD COLUMN numero_cnss         varchar(30),
  ADD COLUMN banque              text,
  ADD COLUMN numero_compte       varchar(40);

ALTER TABLE employe ADD CONSTRAINT employe_pas_son_propre_superieur CHECK (superieur_id IS NULL OR superieur_id <> id);

-- Hiérarchie sans cycle : le supérieur ne doit pas être un subordonné (direct ou indirect)
CREATE FUNCTION trg_employe_hierarchie() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF NEW.superieur_id IS NOT NULL AND (TG_OP = 'INSERT' OR NEW.superieur_id IS DISTINCT FROM OLD.superieur_id) THEN
    IF TG_OP = 'UPDATE' AND EXISTS (
         WITH RECURSIVE sub AS (
           SELECT id FROM mf.employe WHERE superieur_id = NEW.id
           UNION SELECT e.id FROM mf.employe e JOIN sub s ON e.superieur_id = s.id)
         SELECT 1 FROM sub WHERE id = NEW.superieur_id) THEN
      RAISE EXCEPTION 'Hiérarchie circulaire : le supérieur choisi dépend déjà de cet employé';
    END IF;
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER employe_hierarchie BEFORE INSERT OR UPDATE OF superieur_id ON employe FOR EACH ROW EXECUTE FUNCTION trg_employe_hierarchie();

-- Un service ne peut pas devenir son propre descendant
CREATE FUNCTION trg_service_hierarchie() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF TG_OP = 'UPDATE' AND NEW.parent_id IS NOT NULL AND NEW.parent_id IS DISTINCT FROM OLD.parent_id AND EXISTS (
       WITH RECURSIVE sub AS (
         SELECT id FROM mf.service_rh WHERE parent_id = NEW.id
         UNION SELECT s2.id FROM mf.service_rh s2 JOIN sub s ON s2.parent_id = s.id)
       SELECT 1 FROM sub WHERE id = NEW.parent_id) THEN
    RAISE EXCEPTION 'Hiérarchie circulaire entre services';
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER service_hierarchie BEFORE UPDATE OF parent_id ON service_rh FOR EACH ROW EXECUTE FUNCTION trg_service_hierarchie();

-- Pièces du dossier du personnel
CREATE TABLE document_employe (
  id               serial PRIMARY KEY,
  employe_id       integer NOT NULL REFERENCES employe(id),
  type             varchar(20) NOT NULL CHECK (type IN ('identite','diplome','contrat','cnss','certificat_medical','casier_judiciaire','attestation','photo','autre')),
  libelle          text NOT NULL,
  reference        text,
  date_emission    date,
  date_expiration  date,
  note             text,
  cree_le          timestamptz NOT NULL DEFAULT now(),
  CHECK (date_expiration IS NULL OR date_emission IS NULL OR date_expiration >= date_emission)
);
CREATE INDEX document_employe_employe ON document_employe(employe_id);

-- Période d'essai et motif du CDD sur les contrats
ALTER TABLE contrat
  ADD COLUMN periode_essai_fin date,
  ADD COLUMN motif_cdd text,
  ADD COLUMN poste_id integer REFERENCES poste(id),
  ADD CONSTRAINT contrat_essai_dans_le_contrat CHECK (periode_essai_fin IS NULL OR periode_essai_fin >= date_debut);

-- Alertes : fins de contrat, fins de période d'essai, pièces qui expirent (agence de l'employé)
CREATE VIEW v_grh_echeances AS
SELECT 'fin_contrat'::text AS nature, e.id AS employe_id, e.agence_id, e.matricule, e.nom, c.date_fin AS echeance,
       (c.date_fin - current_date) AS jours, c.type::text AS detail
  FROM mf.employe e JOIN mf.contrat c ON c.employe_id = e.id
 WHERE e.statut = 'actif' AND c.type IN ('cdd','stage','journalier') AND c.date_fin IS NOT NULL
   AND c.date_fin BETWEEN current_date AND current_date + COALESCE(mf.param_num('alerte_contrat_jours', e.agence_id), 60)::int
UNION ALL
SELECT 'fin_essai', e.id, e.agence_id, e.matricule, e.nom, c.periode_essai_fin, (c.periode_essai_fin - current_date), c.type::text
  FROM mf.employe e JOIN mf.contrat c ON c.employe_id = e.id
 WHERE e.statut = 'actif' AND c.periode_essai_fin BETWEEN current_date AND current_date + COALESCE(mf.param_num('alerte_essai_jours', e.agence_id), 15)::int
UNION ALL
SELECT 'piece_expire', e.id, e.agence_id, e.matricule, e.nom, d.date_expiration, (d.date_expiration - current_date), d.libelle
  FROM mf.employe e JOIN mf.document_employe d ON d.employe_id = e.id
 WHERE e.statut = 'actif' AND d.date_expiration <= current_date + COALESCE(mf.param_num('alerte_piece_jours', e.agence_id), 60)::int;

-- Organigramme : chaque employé avec son niveau et son chemin hiérarchique
CREATE VIEW v_organigramme AS
WITH RECURSIVE arbre AS (
  SELECT e.id, e.agence_id, e.matricule, e.nom, e.poste_id, e.service_id, e.superieur_id, 0 AS niveau, ARRAY[e.id] AS chemin
    FROM mf.employe e WHERE e.statut = 'actif' AND (e.superieur_id IS NULL OR NOT EXISTS (SELECT 1 FROM mf.employe s WHERE s.id = e.superieur_id AND s.statut = 'actif'))
  UNION ALL
  SELECT e.id, e.agence_id, e.matricule, e.nom, e.poste_id, e.service_id, e.superieur_id, a.niveau + 1, a.chemin || e.id
    FROM mf.employe e JOIN arbre a ON e.superieur_id = a.id WHERE e.statut = 'actif')
SELECT a.*, p.libelle AS poste, s.libelle AS service FROM arbre a
  LEFT JOIN mf.poste p ON p.id = a.poste_id LEFT JOIN mf.service_rh s ON s.id = a.service_id;

-- ---------------------------------------------------------------------
-- Agents commerciaux dans la RH
-- ---------------------------------------------------------------------
-- Fiche RH d'un agent commercial : même matricule et même nom, rattachée à l'agent
CREATE FUNCTION creer_employe_depuis_agent(p_agent integer, p_date_embauche date DEFAULT current_date, p_poste integer DEFAULT NULL)
RETURNS integer LANGUAGE plpgsql AS $$
DECLARE a mf.agent; v_id integer; v_poste integer;
BEGIN
  SELECT * INTO a FROM mf.agent WHERE id = p_agent FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'agent % inconnu', p_agent; END IF;
  IF EXISTS (SELECT 1 FROM mf.employe WHERE agent_id = p_agent) THEN
    RAISE EXCEPTION 'L''agent % a déjà une fiche RH', a.matricule;
  END IF;
  v_poste := COALESCE(p_poste, (SELECT id FROM mf.poste WHERE code = 'AGENT-COM'));
  INSERT INTO mf.employe(agence_id, matricule, nom, poste, poste_id, date_embauche, agent_id)
  VALUES (a.agence_id, a.matricule, a.nom, 'Agent commercial', v_poste, p_date_embauche, p_agent)
  RETURNING id INTO v_id;
  RETURN v_id;
END $$;

INSERT INTO poste(code, libelle, description, effectif_prevu) VALUES
  ('AGENT-COM', 'Agent commercial', 'Collecte de proximité, suivi des clients et des cycles de tontine', 5),
  ('COLLECTRICE', 'Collectrice', 'Collecte journalière auprès des clients', 5);

-- Vue RH des agents commerciaux : fiche RH, contrat, zones, clients et collecte du mois
CREATE VIEW v_agent_rh AS
SELECT a.id AS agent_id, a.agence_id, a.matricule, a.nom, a.actif,
       e.id AS employe_id, e.statut AS statut_rh, e.date_embauche, e.superieur_id,
       (SELECT salaire_base FROM mf.contrat c WHERE c.employe_id = e.id AND c.date_debut <= current_date
           AND (c.date_fin IS NULL OR c.date_fin >= current_date) ORDER BY c.date_debut DESC LIMIT 1) AS salaire_base,
       (SELECT count(*) FROM mf.zone z WHERE z.agent_id = a.id) AS nb_zones,
       (SELECT count(*) FROM mf.client cl JOIN mf.zone z ON z.id = cl.zone_id WHERE z.agent_id = a.id) AS nb_clients,
       COALESCE((SELECT sum(l.montant_collecte) FROM mf.ligne_collecte l
                  WHERE l.agent_id = a.id AND l.date_collecte >= date_trunc('month', current_date)::date), 0) AS collecte_du_mois
  FROM mf.agent a LEFT JOIN mf.employe e ON e.agent_id = a.id;

CREATE TRIGGER audit_poste AFTER INSERT OR UPDATE OR DELETE ON poste FOR EACH ROW EXECUTE FUNCTION trg_audit();
CREATE TRIGGER audit_service_rh AFTER INSERT OR UPDATE OR DELETE ON service_rh FOR EACH ROW EXECUTE FUNCTION trg_audit();
CREATE TRIGGER audit_document_employe AFTER INSERT OR UPDATE OR DELETE ON document_employe FOR EACH ROW EXECUTE FUNCTION trg_audit();
