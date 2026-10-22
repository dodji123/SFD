-- =====================================================================
-- 53_roles.sql
-- Attribution des rôles : matrice de droits éditable, rôles personnalisés, affectations datées avec validation.
--   * la matrice (droit_role) remplace la liste codée en Python : chaque rôle (système ou personnalisé) reçoit des permissions
--   * les rôles système (les dix rôles d'origine) ne se suppriment pas ; l'administrateur garde toujours la gestion des rôles
--   * un utilisateur garde son rôle de base (utilisateur.role) et peut recevoir des affectations temporaires d'un autre rôle,
--     pour une agence de son périmètre et pour une durée limitée (6 mois au plus)
--   * une affectation est demandée, puis validée ou refusée par un AUTRE responsable ; on ne valide jamais sa propre demande
--     ni un rôle qu'on se donne soi-même
--   * une affectation active se révoque ; elle ne se modifie pas ; tout est journalisé
-- Dépend de : 00 (utilisateur, agence).
-- =====================================================================
SET search_path = mf, public;

CREATE TABLE permission (
  code       varchar(60) PRIMARY KEY CHECK (code ~ '^[a-z0-9_-]+:[a-z0-9_-]+$'),
  categorie  varchar(30) NOT NULL DEFAULT 'autre'
);
COMMENT ON TABLE permission IS 'Permissions de l''application (chaque route protégée en porte une).';

CREATE TABLE role_droit (
  code      varchar(30) PRIMARY KEY CHECK (code ~ '^[a-z0-9_]{2,30}$'),
  libelle   text NOT NULL CHECK (length(btrim(libelle)) >= 3),
  systeme   boolean NOT NULL DEFAULT false,          -- rôle d'origine : ne se supprime pas
  actif     boolean NOT NULL DEFAULT true,
  cree_par  integer REFERENCES utilisateur(id),
  cree_le   timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE droit_role (
  role_code   varchar(30) NOT NULL REFERENCES role_droit(code),
  perm        varchar(60) NOT NULL REFERENCES permission(code),
  PRIMARY KEY (role_code, perm)
);

-- ---------------------------------------------------------------- rôles
CREATE FUNCTION trg_role_droit_regles() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF TG_OP = 'DELETE' THEN
    IF OLD.systeme THEN RAISE EXCEPTION 'Un rôle d''origine ne se supprime pas : désactivez-le'; END IF;
    IF EXISTS (SELECT 1 FROM mf.affectation_role WHERE role_code = OLD.code AND statut = 'active') THEN
      RAISE EXCEPTION 'Ce rôle est encore affecté à des utilisateurs';
    END IF;
    RETURN OLD;
  END IF;
  IF TG_OP = 'UPDATE' THEN
    IF OLD.systeme AND NEW.code <> OLD.code THEN RAISE EXCEPTION 'Le code d''un rôle d''origine ne change pas'; END IF;
    IF OLD.code = 'admin' AND NEW.actif = false THEN RAISE EXCEPTION 'Le rôle administrateur reste actif'; END IF;
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER role_droit_regles BEFORE INSERT OR UPDATE OR DELETE ON role_droit FOR EACH ROW EXECUTE FUNCTION trg_role_droit_regles();
CREATE TRIGGER audit_role_droit AFTER INSERT OR UPDATE OR DELETE ON role_droit FOR EACH ROW EXECUTE FUNCTION trg_audit();

-- ---------------------------------------------------------------- matrice
-- l'administrateur garde la gestion des rôles et des utilisateurs : sinon plus personne ne peut rétablir la matrice
CREATE FUNCTION trg_droit_role_garde() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF TG_OP = 'DELETE' THEN
    IF OLD.role_code = 'admin' AND OLD.perm IN ('roles:gerer', 'users:manage') THEN
      RAISE EXCEPTION 'Le rôle administrateur garde la gestion des rôles et des utilisateurs';
    END IF;
    RETURN OLD;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM mf.role_droit WHERE code = NEW.role_code AND actif) THEN
    RAISE EXCEPTION 'Rôle inconnu ou inactif : %', NEW.role_code;
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER droit_role_garde BEFORE INSERT OR DELETE ON droit_role FOR EACH ROW EXECUTE FUNCTION trg_droit_role_garde();
CREATE TRIGGER audit_droit_role AFTER INSERT OR DELETE ON droit_role FOR EACH ROW EXECUTE FUNCTION trg_audit();

-- ---------------------------------------------------------------- affectations temporaires
CREATE TABLE affectation_role (
  id                   serial PRIMARY KEY,
  utilisateur_id       integer NOT NULL REFERENCES utilisateur(id),
  role_code            varchar(30) NOT NULL REFERENCES role_droit(code),
  agence_id            smallint NOT NULL REFERENCES agence(id),
  date_debut           date NOT NULL,
  date_fin             date NOT NULL,
  motif                text NOT NULL CHECK (length(btrim(motif)) >= 10),
  statut               varchar(10) NOT NULL DEFAULT 'demandee' CHECK (statut IN ('demandee','active','refusee','revoquee')),
  demande_par          integer NOT NULL REFERENCES utilisateur(id),
  demande_le           timestamptz NOT NULL DEFAULT now(),
  valide_par           integer REFERENCES utilisateur(id),
  valide_le            timestamptz,
  commentaire_decision text,
  revoque_par          integer REFERENCES utilisateur(id),
  revoque_le           timestamptz,
  motif_revocation     text,
  CHECK (date_fin > date_debut),
  CHECK (date_fin - date_debut <= 183)
);
-- une seule affectation ouverte (demandée ou active) pour un même rôle, un même utilisateur et une même agence
CREATE UNIQUE INDEX affectation_role_ouverte ON affectation_role(utilisateur_id, role_code, agence_id) WHERE statut IN ('demandee','active');

CREATE FUNCTION trg_affectation_role_regles() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE u mf.utilisateur; r mf.role_droit;
BEGIN
  IF TG_OP = 'INSERT' THEN
    SELECT * INTO u FROM mf.utilisateur WHERE id = NEW.utilisateur_id;
    IF u.id IS NULL OR NOT u.actif THEN RAISE EXCEPTION 'Utilisateur inconnu ou désactivé'; END IF;
    SELECT * INTO r FROM mf.role_droit WHERE code = NEW.role_code;
    IF r.code IS NULL OR NOT r.actif THEN RAISE EXCEPTION 'Rôle inconnu ou inactif'; END IF;
    IF u.role::text = NEW.role_code THEN RAISE EXCEPTION 'L''utilisateur a déjà ce rôle de base'; END IF;
    -- une affectation a le périmètre d'une seule agence : elle ne vaut que pour une personne rattachée à cette agence
    IF u.agence_id IS NULL THEN RAISE EXCEPTION 'Une affectation temporaire ne concerne qu''une personne rattachée à une agence'; END IF;
    IF u.agence_id <> NEW.agence_id THEN
      RAISE EXCEPTION 'Une affectation ne peut viser que l''agence de l''utilisateur (agence de base : %)', u.agence_id;
    END IF;
    IF NEW.date_debut < current_date THEN RAISE EXCEPTION 'La date de début ne peut être dans le passé'; END IF;
    NEW.statut := 'demandee';
    NEW.valide_par := NULL; NEW.valide_le := NULL;
    RETURN NEW;
  END IF;
  IF TG_OP = 'DELETE' THEN RAISE EXCEPTION 'Une affectation ne se supprime pas : elle reste dans l''historique'; END IF;
  -- UPDATE : le contenu de la demande ne bouge pas
  IF (NEW.utilisateur_id, NEW.role_code, NEW.agence_id, NEW.date_debut, NEW.date_fin, NEW.motif, NEW.demande_par)
     IS DISTINCT FROM (OLD.utilisateur_id, OLD.role_code, OLD.agence_id, OLD.date_debut, OLD.date_fin, OLD.motif, OLD.demande_par) THEN
    RAISE EXCEPTION 'Le contenu d''une affectation ne se modifie pas : demandez-en une nouvelle';
  END IF;
  IF OLD.statut = 'demandee' AND NEW.statut IN ('active','refusee') THEN
    IF NEW.valide_par IS NULL THEN RAISE EXCEPTION 'La décision doit être attribuée à son auteur'; END IF;
    IF NEW.valide_par = OLD.demande_par THEN RAISE EXCEPTION 'Séparation des tâches : on ne valide pas sa propre demande de rôle'; END IF;
    IF NEW.valide_par = OLD.utilisateur_id THEN RAISE EXCEPTION 'On ne valide pas un rôle qu''on se donne soi-même'; END IF;
    IF NEW.statut = 'refusee' AND length(btrim(COALESCE(NEW.commentaire_decision, ''))) < 5 THEN RAISE EXCEPTION 'Un refus doit être motivé'; END IF;
    IF NEW.statut = 'active' AND NEW.date_fin < current_date THEN RAISE EXCEPTION 'Une affectation échue ne s''active plus'; END IF;
    NEW.valide_le := now();
    RETURN NEW;
  END IF;
  IF OLD.statut = 'active' AND NEW.statut = 'revoquee' THEN
    IF NEW.revoque_par IS NULL OR length(btrim(COALESCE(NEW.motif_revocation, ''))) < 5 THEN
      RAISE EXCEPTION 'La révocation exige son auteur et un motif';
    END IF;
    NEW.revoque_le := now();
    RETURN NEW;
  END IF;
  RAISE EXCEPTION 'Changement d''état impossible : % -> %', OLD.statut, NEW.statut;
END $$;
CREATE TRIGGER affectation_role_regles BEFORE INSERT OR UPDATE OR DELETE ON affectation_role FOR EACH ROW EXECUTE FUNCTION trg_affectation_role_regles();
CREATE TRIGGER audit_affectation_role AFTER INSERT OR UPDATE ON affectation_role FOR EACH ROW EXECUTE FUNCTION trg_audit();

CREATE VIEW v_affectation_role AS
SELECT a.*, u.login, u.nom AS utilisateur_nom, u.role::text AS role_base, ag.code AS agence, r.libelle AS role_libelle,
       d.nom AS demande_par_nom, v.nom AS valide_par_nom,
       (a.statut = 'active' AND current_date BETWEEN a.date_debut AND a.date_fin) AS en_cours
FROM mf.affectation_role a
JOIN mf.utilisateur u ON u.id = a.utilisateur_id
JOIN mf.role_droit r ON r.code = a.role_code
JOIN mf.agence ag ON ag.id = a.agence_id
LEFT JOIN mf.utilisateur d ON d.id = a.demande_par
LEFT JOIN mf.utilisateur v ON v.id = a.valide_par;

-- droits effectifs d'un utilisateur à une date : rôle de base + affectations actives en cours, dans son périmètre d'agence
CREATE FUNCTION droits_utilisateur(p_utilisateur integer, p_date date DEFAULT current_date) RETURNS SETOF varchar
LANGUAGE sql STABLE AS $$
  SELECT DISTINCT dr.perm::varchar FROM mf.droit_role dr
  JOIN mf.role_droit rd ON rd.code = dr.role_code AND rd.actif
  WHERE dr.role_code IN (
    SELECT u.role::text FROM mf.utilisateur u WHERE u.id = p_utilisateur AND u.actif
    UNION
    SELECT a.role_code FROM mf.affectation_role a
     JOIN mf.utilisateur u ON u.id = a.utilisateur_id AND u.actif AND u.agence_id = a.agence_id
     WHERE a.utilisateur_id = p_utilisateur AND a.statut = 'active' AND p_date BETWEEN a.date_debut AND a.date_fin)
$$;

-- ---------------------------------------------------------------- seed : rôles d'origine
INSERT INTO role_droit(code, libelle, systeme) VALUES
  ('admin', 'Administrateur', true), ('directeur', 'Directeur', true), ('chef_agence', 'Chef d''agence', true),
  ('caissier', 'Caissier', true), ('comptable', 'Comptable', true), ('agent', 'Agent de collecte', true),
  ('collectrice', 'Collectrice', true), ('rh', 'Ressources humaines', true), ('auditeur', 'Auditeur', true),
  ('coordinateur', 'Coordinateur de réseau', true);

-- permissions de l'application (reprises de api/app/perms.py à la date de ce module)
INSERT INTO permission(code, categorie) VALUES
  ('acces_client:manage', 'acces_client'),
  ('adhesion:write', 'adhesion'),
  ('agences:write', 'agences'),
  ('audit:read', 'audit'),
  ('budget:gerer', 'budget'),
  ('caisse:read', 'caisse'),
  ('caisse:write', 'caisse'),
  ('carnet:read', 'carnet'),
  ('carnet:write', 'carnet'),
  ('charge:gerer', 'charge'),
  ('cheque:prepare', 'cheque'),
  ('cheque:read', 'cheque'),
  ('cheque:sign', 'cheque'),
  ('clients:transfer-agence', 'clients'),
  ('clients:transfer-zone', 'clients'),
  ('collecte:admin', 'collecte'),
  ('collecte:read', 'collecte'),
  ('collecte:valider', 'collecte'),
  ('collecte:write', 'collecte'),
  ('comite:manage', 'comite'),
  ('comite:participer', 'comite'),
  ('comite:read', 'comite'),
  ('compta:read', 'compta'),
  ('compta:write', 'compta'),
  ('conge:decider', 'conge'),
  ('consent:write', 'consent'),
  ('credit:approve', 'credit'),
  ('credit:disburse', 'credit'),
  ('credit:read', 'credit'),
  ('credit:repay', 'credit'),
  ('credit:request', 'credit'),
  ('cycle:prolongation-decider', 'cycle'),
  ('delegation:write', 'delegation'),
  ('demande-retrait:decider', 'demande-retrait'),
  ('depot:debloquer', 'depot'),
  ('epargne:dormant', 'epargne'),
  ('epargne:read', 'epargne'),
  ('epargne:write', 'epargne'),
  ('etats:consolide', 'etats'),
  ('evaluation:ecrire', 'evaluation'),
  ('evaluation:valider', 'evaluation'),
  ('grh:read', 'grh'),
  ('grh:self', 'grh'),
  ('grh:write', 'grh'),
  ('kyc:validate', 'kyc'),
  ('lbc:listes', 'lbc'),
  ('lbc:read', 'lbc'),
  ('lbc:write', 'lbc'),
  ('livret:controler', 'livret'),
  ('livret:read', 'livret'),
  ('livret:valider', 'livret'),
  ('operation:comptes-valider', 'operation'),
  ('operation:param', 'operation'),
  ('operation:read', 'operation'),
  ('operation:saisir', 'operation'),
  ('operation:valider', 'operation'),
  ('paiement-mobile:read', 'paiement-mobile'),
  ('paiement-mobile:rembourser', 'paiement-mobile'),
  ('params:read', 'params'),
  ('params:write', 'params'),
  ('procuration:valider', 'procuration'),
  ('procuration:write', 'procuration'),
  ('provisions:generer', 'provisions'),
  ('provisions:parametrer', 'provisions'),
  ('provisions:read', 'provisions'),
  ('rapports:read', 'rapports'),
  ('rapprochement:valider', 'rapprochement'),
  ('ratios:enregistrer', 'ratios'),
  ('ratios:parametrer', 'ratios'),
  ('ratios:saisir', 'ratios'),
  ('ratios:valider', 'ratios'),
  ('recouvrement:perte', 'recouvrement'),
  ('recouvrement:read', 'recouvrement'),
  ('recouvrement:write', 'recouvrement'),
  ('recrutement:decider', 'recrutement'),
  ('ref:read', 'ref'),
  ('ref:write', 'ref'),
  ('reseaux:read', 'reseaux'),
  ('reseaux:write', 'reseaux'),
  ('retrait:ecart', 'retrait'),
  ('retrait:execute', 'retrait'),
  ('retrait:request', 'retrait'),
  ('rh:read', 'rh'),
  ('rh:write', 'rh'),
  ('roles:demander', 'roles'),
  ('roles:gerer', 'roles'),
  ('roles:valider', 'roles'),
  ('sanction:write', 'sanction'),
  ('sauvegarde:tester', 'sauvegarde'),
  ('sauvegarde:write', 'sauvegarde'),
  ('securite:alertes', 'securite'),
  ('securite:read', 'securite'),
  ('securite:write', 'securite'),
  ('sortie:write', 'sortie'),
  ('taches:run', 'taches'),
  ('tresorerie:read', 'tresorerie'),
  ('tresorerie:write', 'tresorerie'),
  ('users:manage', 'users'),
  ('versement:write', 'versement');

-- matrice d'origine : quel rôle a quelle permission
INSERT INTO droit_role(role_code, perm) VALUES
  ('admin', 'acces_client:manage'),
  ('chef_agence', 'acces_client:manage'),
  ('coordinateur', 'acces_client:manage'),
  ('directeur', 'acces_client:manage'),
  ('admin', 'adhesion:write'),
  ('caissier', 'adhesion:write'),
  ('chef_agence', 'adhesion:write'),
  ('admin', 'agences:write'),
  ('admin', 'audit:read'),
  ('auditeur', 'audit:read'),
  ('directeur', 'audit:read'),
  ('admin', 'budget:gerer'),
  ('chef_agence', 'budget:gerer'),
  ('comptable', 'budget:gerer'),
  ('coordinateur', 'budget:gerer'),
  ('directeur', 'budget:gerer'),
  ('admin', 'caisse:read'),
  ('auditeur', 'caisse:read'),
  ('caissier', 'caisse:read'),
  ('chef_agence', 'caisse:read'),
  ('comptable', 'caisse:read'),
  ('coordinateur', 'caisse:read'),
  ('directeur', 'caisse:read'),
  ('admin', 'caisse:write'),
  ('caissier', 'caisse:write'),
  ('chef_agence', 'caisse:write'),
  ('admin', 'carnet:read'),
  ('auditeur', 'carnet:read'),
  ('caissier', 'carnet:read'),
  ('chef_agence', 'carnet:read'),
  ('coordinateur', 'carnet:read'),
  ('directeur', 'carnet:read'),
  ('admin', 'carnet:write'),
  ('chef_agence', 'carnet:write'),
  ('coordinateur', 'carnet:write'),
  ('directeur', 'carnet:write'),
  ('admin', 'charge:gerer'),
  ('chef_agence', 'charge:gerer'),
  ('comptable', 'charge:gerer'),
  ('coordinateur', 'charge:gerer'),
  ('directeur', 'charge:gerer'),
  ('admin', 'cheque:prepare'),
  ('caissier', 'cheque:prepare'),
  ('chef_agence', 'cheque:prepare'),
  ('comptable', 'cheque:prepare'),
  ('admin', 'cheque:read'),
  ('auditeur', 'cheque:read'),
  ('chef_agence', 'cheque:read'),
  ('comptable', 'cheque:read'),
  ('directeur', 'cheque:read'),
  ('admin', 'cheque:sign'),
  ('comptable', 'cheque:sign'),
  ('directeur', 'cheque:sign'),
  ('admin', 'clients:transfer-agence'),
  ('directeur', 'clients:transfer-agence'),
  ('admin', 'clients:transfer-zone'),
  ('chef_agence', 'clients:transfer-zone'),
  ('coordinateur', 'clients:transfer-zone'),
  ('directeur', 'clients:transfer-zone'),
  ('admin', 'collecte:admin'),
  ('chef_agence', 'collecte:admin'),
  ('admin', 'collecte:read'),
  ('agent', 'collecte:read'),
  ('auditeur', 'collecte:read'),
  ('caissier', 'collecte:read'),
  ('chef_agence', 'collecte:read'),
  ('collectrice', 'collecte:read'),
  ('coordinateur', 'collecte:read'),
  ('directeur', 'collecte:read'),
  ('admin', 'collecte:valider'),
  ('caissier', 'collecte:valider'),
  ('chef_agence', 'collecte:valider'),
  ('admin', 'collecte:write'),
  ('agent', 'collecte:write'),
  ('chef_agence', 'collecte:write'),
  ('collectrice', 'collecte:write'),
  ('admin', 'comite:manage'),
  ('chef_agence', 'comite:manage'),
  ('coordinateur', 'comite:manage'),
  ('directeur', 'comite:manage'),
  ('admin', 'comite:participer'),
  ('agent', 'comite:participer'),
  ('auditeur', 'comite:participer'),
  ('caissier', 'comite:participer'),
  ('chef_agence', 'comite:participer'),
  ('collectrice', 'comite:participer'),
  ('comptable', 'comite:participer'),
  ('coordinateur', 'comite:participer'),
  ('directeur', 'comite:participer'),
  ('rh', 'comite:participer'),
  ('admin', 'comite:read'),
  ('agent', 'comite:read'),
  ('auditeur', 'comite:read'),
  ('caissier', 'comite:read'),
  ('chef_agence', 'comite:read'),
  ('collectrice', 'comite:read'),
  ('comptable', 'comite:read'),
  ('coordinateur', 'comite:read'),
  ('directeur', 'comite:read'),
  ('rh', 'comite:read'),
  ('admin', 'compta:read'),
  ('auditeur', 'compta:read'),
  ('chef_agence', 'compta:read'),
  ('comptable', 'compta:read'),
  ('coordinateur', 'compta:read'),
  ('directeur', 'compta:read'),
  ('admin', 'compta:write'),
  ('comptable', 'compta:write'),
  ('admin', 'conge:decider'),
  ('chef_agence', 'conge:decider'),
  ('coordinateur', 'conge:decider'),
  ('directeur', 'conge:decider'),
  ('rh', 'conge:decider'),
  ('admin', 'consent:write'),
  ('caissier', 'consent:write'),
  ('chef_agence', 'consent:write'),
  ('coordinateur', 'consent:write'),
  ('directeur', 'consent:write'),
  ('admin', 'credit:approve'),
  ('chef_agence', 'credit:approve'),
  ('coordinateur', 'credit:approve'),
  ('directeur', 'credit:approve'),
  ('admin', 'credit:disburse'),
  ('caissier', 'credit:disburse'),
  ('chef_agence', 'credit:disburse'),
  ('admin', 'credit:read'),
  ('agent', 'credit:read'),
  ('auditeur', 'credit:read'),
  ('caissier', 'credit:read'),
  ('chef_agence', 'credit:read'),
  ('collectrice', 'credit:read'),
  ('comptable', 'credit:read'),
  ('coordinateur', 'credit:read'),
  ('directeur', 'credit:read'),
  ('admin', 'credit:repay'),
  ('caissier', 'credit:repay'),
  ('chef_agence', 'credit:repay'),
  ('admin', 'credit:request'),
  ('agent', 'credit:request'),
  ('chef_agence', 'credit:request'),
  ('collectrice', 'credit:request'),
  ('admin', 'cycle:prolongation-decider'),
  ('chef_agence', 'cycle:prolongation-decider'),
  ('coordinateur', 'cycle:prolongation-decider'),
  ('directeur', 'cycle:prolongation-decider'),
  ('admin', 'delegation:write'),
  ('coordinateur', 'delegation:write'),
  ('directeur', 'delegation:write'),
  ('admin', 'demande-retrait:decider'),
  ('caissier', 'demande-retrait:decider'),
  ('chef_agence', 'demande-retrait:decider'),
  ('coordinateur', 'demande-retrait:decider'),
  ('directeur', 'demande-retrait:decider'),
  ('admin', 'depot:debloquer'),
  ('chef_agence', 'depot:debloquer'),
  ('admin', 'epargne:dormant'),
  ('chef_agence', 'epargne:dormant'),
  ('admin', 'epargne:read'),
  ('agent', 'epargne:read'),
  ('auditeur', 'epargne:read'),
  ('caissier', 'epargne:read'),
  ('chef_agence', 'epargne:read'),
  ('collectrice', 'epargne:read'),
  ('comptable', 'epargne:read'),
  ('coordinateur', 'epargne:read'),
  ('directeur', 'epargne:read'),
  ('admin', 'epargne:write'),
  ('caissier', 'epargne:write'),
  ('chef_agence', 'epargne:write'),
  ('admin', 'etats:consolide'),
  ('auditeur', 'etats:consolide'),
  ('comptable', 'etats:consolide'),
  ('directeur', 'etats:consolide'),
  ('admin', 'evaluation:ecrire'),
  ('chef_agence', 'evaluation:ecrire'),
  ('coordinateur', 'evaluation:ecrire'),
  ('directeur', 'evaluation:ecrire'),
  ('rh', 'evaluation:ecrire'),
  ('admin', 'evaluation:valider'),
  ('coordinateur', 'evaluation:valider'),
  ('directeur', 'evaluation:valider'),
  ('rh', 'evaluation:valider'),
  ('admin', 'grh:read'),
  ('auditeur', 'grh:read'),
  ('chef_agence', 'grh:read'),
  ('coordinateur', 'grh:read'),
  ('directeur', 'grh:read'),
  ('rh', 'grh:read'),
  ('admin', 'grh:self'),
  ('agent', 'grh:self'),
  ('auditeur', 'grh:self'),
  ('caissier', 'grh:self'),
  ('chef_agence', 'grh:self'),
  ('collectrice', 'grh:self'),
  ('comptable', 'grh:self'),
  ('coordinateur', 'grh:self'),
  ('directeur', 'grh:self'),
  ('rh', 'grh:self'),
  ('admin', 'grh:write'),
  ('coordinateur', 'grh:write'),
  ('directeur', 'grh:write'),
  ('rh', 'grh:write'),
  ('admin', 'kyc:validate'),
  ('chef_agence', 'kyc:validate'),
  ('coordinateur', 'kyc:validate'),
  ('directeur', 'kyc:validate'),
  ('admin', 'lbc:listes'),
  ('directeur', 'lbc:listes'),
  ('admin', 'lbc:read'),
  ('auditeur', 'lbc:read'),
  ('chef_agence', 'lbc:read'),
  ('comptable', 'lbc:read'),
  ('coordinateur', 'lbc:read'),
  ('directeur', 'lbc:read'),
  ('admin', 'lbc:write'),
  ('directeur', 'lbc:write'),
  ('admin', 'livret:controler'),
  ('chef_agence', 'livret:controler'),
  ('coordinateur', 'livret:controler'),
  ('directeur', 'livret:controler'),
  ('admin', 'livret:read'),
  ('auditeur', 'livret:read'),
  ('chef_agence', 'livret:read'),
  ('coordinateur', 'livret:read'),
  ('directeur', 'livret:read'),
  ('admin', 'livret:valider'),
  ('chef_agence', 'livret:valider'),
  ('coordinateur', 'livret:valider'),
  ('directeur', 'livret:valider'),
  ('admin', 'operation:comptes-valider'),
  ('comptable', 'operation:comptes-valider'),
  ('admin', 'operation:param'),
  ('comptable', 'operation:param'),
  ('coordinateur', 'operation:param'),
  ('directeur', 'operation:param'),
  ('admin', 'operation:read'),
  ('auditeur', 'operation:read'),
  ('caissier', 'operation:read'),
  ('chef_agence', 'operation:read'),
  ('comptable', 'operation:read'),
  ('coordinateur', 'operation:read'),
  ('directeur', 'operation:read'),
  ('admin', 'operation:saisir'),
  ('caissier', 'operation:saisir'),
  ('chef_agence', 'operation:saisir'),
  ('comptable', 'operation:saisir'),
  ('admin', 'operation:valider'),
  ('chef_agence', 'operation:valider'),
  ('coordinateur', 'operation:valider'),
  ('directeur', 'operation:valider'),
  ('admin', 'paiement-mobile:read'),
  ('auditeur', 'paiement-mobile:read'),
  ('caissier', 'paiement-mobile:read'),
  ('chef_agence', 'paiement-mobile:read'),
  ('comptable', 'paiement-mobile:read'),
  ('coordinateur', 'paiement-mobile:read'),
  ('directeur', 'paiement-mobile:read'),
  ('admin', 'paiement-mobile:rembourser'),
  ('chef_agence', 'paiement-mobile:rembourser'),
  ('comptable', 'paiement-mobile:rembourser'),
  ('admin', 'params:read'),
  ('auditeur', 'params:read'),
  ('chef_agence', 'params:read'),
  ('comptable', 'params:read'),
  ('coordinateur', 'params:read'),
  ('directeur', 'params:read'),
  ('admin', 'params:write'),
  ('admin', 'procuration:valider'),
  ('chef_agence', 'procuration:valider'),
  ('admin', 'procuration:write'),
  ('caissier', 'procuration:write'),
  ('chef_agence', 'procuration:write'),
  ('admin', 'provisions:generer'),
  ('comptable', 'provisions:generer'),
  ('admin', 'provisions:parametrer'),
  ('comptable', 'provisions:parametrer'),
  ('directeur', 'provisions:parametrer'),
  ('admin', 'provisions:read'),
  ('auditeur', 'provisions:read'),
  ('chef_agence', 'provisions:read'),
  ('comptable', 'provisions:read'),
  ('coordinateur', 'provisions:read'),
  ('directeur', 'provisions:read'),
  ('admin', 'rapports:read'),
  ('auditeur', 'rapports:read'),
  ('caissier', 'rapports:read'),
  ('chef_agence', 'rapports:read'),
  ('comptable', 'rapports:read'),
  ('coordinateur', 'rapports:read'),
  ('directeur', 'rapports:read'),
  ('admin', 'rapprochement:valider'),
  ('comptable', 'rapprochement:valider'),
  ('admin', 'ratios:enregistrer'),
  ('comptable', 'ratios:enregistrer'),
  ('directeur', 'ratios:enregistrer'),
  ('admin', 'ratios:parametrer'),
  ('comptable', 'ratios:parametrer'),
  ('directeur', 'ratios:parametrer'),
  ('admin', 'ratios:saisir'),
  ('chef_agence', 'ratios:saisir'),
  ('comptable', 'ratios:saisir'),
  ('directeur', 'ratios:saisir'),
  ('admin', 'ratios:valider'),
  ('comptable', 'ratios:valider'),
  ('directeur', 'ratios:valider'),
  ('admin', 'recouvrement:perte'),
  ('coordinateur', 'recouvrement:perte'),
  ('directeur', 'recouvrement:perte'),
  ('admin', 'recouvrement:read'),
  ('agent', 'recouvrement:read'),
  ('auditeur', 'recouvrement:read'),
  ('chef_agence', 'recouvrement:read'),
  ('collectrice', 'recouvrement:read'),
  ('comptable', 'recouvrement:read'),
  ('coordinateur', 'recouvrement:read'),
  ('directeur', 'recouvrement:read'),
  ('admin', 'recouvrement:write'),
  ('agent', 'recouvrement:write'),
  ('chef_agence', 'recouvrement:write'),
  ('collectrice', 'recouvrement:write'),
  ('admin', 'recrutement:decider'),
  ('coordinateur', 'recrutement:decider'),
  ('directeur', 'recrutement:decider'),
  ('admin', 'ref:read'),
  ('agent', 'ref:read'),
  ('auditeur', 'ref:read'),
  ('caissier', 'ref:read'),
  ('chef_agence', 'ref:read'),
  ('collectrice', 'ref:read'),
  ('comptable', 'ref:read'),
  ('coordinateur', 'ref:read'),
  ('directeur', 'ref:read'),
  ('rh', 'ref:read'),
  ('admin', 'ref:write'),
  ('chef_agence', 'ref:write'),
  ('coordinateur', 'ref:write'),
  ('directeur', 'ref:write'),
  ('admin', 'reseaux:read'),
  ('auditeur', 'reseaux:read'),
  ('coordinateur', 'reseaux:read'),
  ('directeur', 'reseaux:read'),
  ('admin', 'reseaux:write'),
  ('admin', 'retrait:ecart'),
  ('chef_agence', 'retrait:ecart'),
  ('coordinateur', 'retrait:ecart'),
  ('directeur', 'retrait:ecart'),
  ('admin', 'retrait:execute'),
  ('caissier', 'retrait:execute'),
  ('chef_agence', 'retrait:execute'),
  ('admin', 'retrait:request'),
  ('agent', 'retrait:request'),
  ('caissier', 'retrait:request'),
  ('chef_agence', 'retrait:request'),
  ('collectrice', 'retrait:request'),
  ('admin', 'rh:read'),
  ('auditeur', 'rh:read'),
  ('coordinateur', 'rh:read'),
  ('directeur', 'rh:read'),
  ('rh', 'rh:read'),
  ('admin', 'rh:write'),
  ('rh', 'rh:write'),
  ('admin', 'roles:demander'),
  ('chef_agence', 'roles:demander'),
  ('coordinateur', 'roles:demander'),
  ('directeur', 'roles:demander'),
  ('admin', 'roles:gerer'),
  ('admin', 'roles:valider'),
  ('coordinateur', 'roles:valider'),
  ('directeur', 'roles:valider'),
  ('admin', 'sanction:write'),
  ('chef_agence', 'sanction:write'),
  ('coordinateur', 'sanction:write'),
  ('directeur', 'sanction:write'),
  ('rh', 'sanction:write'),
  ('auditeur', 'sauvegarde:tester'),
  ('directeur', 'sauvegarde:tester'),
  ('admin', 'sauvegarde:write'),
  ('admin', 'securite:alertes'),
  ('auditeur', 'securite:alertes'),
  ('directeur', 'securite:alertes'),
  ('admin', 'securite:read'),
  ('auditeur', 'securite:read'),
  ('directeur', 'securite:read'),
  ('admin', 'securite:write'),
  ('admin', 'sortie:write'),
  ('coordinateur', 'sortie:write'),
  ('directeur', 'sortie:write'),
  ('rh', 'sortie:write'),
  ('admin', 'taches:run'),
  ('chef_agence', 'taches:run'),
  ('admin', 'tresorerie:read'),
  ('auditeur', 'tresorerie:read'),
  ('caissier', 'tresorerie:read'),
  ('chef_agence', 'tresorerie:read'),
  ('comptable', 'tresorerie:read'),
  ('coordinateur', 'tresorerie:read'),
  ('directeur', 'tresorerie:read'),
  ('admin', 'tresorerie:write'),
  ('chef_agence', 'tresorerie:write'),
  ('coordinateur', 'tresorerie:write'),
  ('directeur', 'tresorerie:write'),
  ('admin', 'users:manage'),
  ('admin', 'versement:write'),
  ('caissier', 'versement:write'),
  ('chef_agence', 'versement:write');
