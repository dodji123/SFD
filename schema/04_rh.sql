-- =====================================================================
-- 04_rh.sql
-- Employés, contrats, congés, présences, rubriques et bulletins de paie, avances sur salaire,
-- commission de collectrice (production x taux, nette de la retenue sur le compte agent).
-- Règles : BRIEF_CLAUDE_CODE.md sections 3.2 et P1.8.
-- Dépend de : 00, 01, 02.
-- Les taux de cotisations sociales et d'impôt sur salaire ne sont PAS fournis (brief P0.5) :
-- aucune rubrique n'est préchargée, elles se saisissent dans rubrique_paie.
-- =====================================================================
SET search_path = mf, public;

-- Une collectrice peut être aussi un agent : sa dette (compte agent) est retenue sur sa commission.
ALTER TABLE collectrice ADD COLUMN agent_id integer REFERENCES agent(id);

CREATE TABLE employe (
  id             serial PRIMARY KEY,
  agence_id      smallint NOT NULL REFERENCES agence(id),
  matricule      varchar(20) NOT NULL,
  nom            text NOT NULL,
  poste          text,
  date_embauche  date NOT NULL,
  date_sortie    date,
  statut         varchar(10) NOT NULL DEFAULT 'actif' CHECK (statut IN ('actif','sorti')),
  collectrice_id integer REFERENCES collectrice(id),   -- sa commission entre dans son bulletin
  agent_id       integer REFERENCES agent(id),
  utilisateur_id integer REFERENCES utilisateur(id),
  UNIQUE (agence_id, matricule)
);

CREATE TABLE contrat (
  id            serial PRIMARY KEY,
  employe_id    integer NOT NULL REFERENCES employe(id),
  type          varchar(10) NOT NULL CHECK (type IN ('cdi','cdd','stage','journalier')),
  date_debut    date NOT NULL,
  date_fin      date,
  salaire_base  numeric(14,0) NOT NULL CHECK (salaire_base >= 0),
  CHECK (date_fin IS NULL OR date_fin >= date_debut),
  EXCLUDE USING gist (employe_id WITH =, daterange(date_debut, date_fin, '[]') WITH &&)
);

CREATE TABLE conge (
  id         serial PRIMARY KEY,
  employe_id integer NOT NULL REFERENCES employe(id),
  type       varchar(15) NOT NULL CHECK (type IN ('annuel','maladie','maternite','sans_solde','autre')),
  date_debut date NOT NULL,
  date_fin   date NOT NULL,
  statut     varchar(10) NOT NULL DEFAULT 'demande' CHECK (statut IN ('demande','approuve','refuse')),
  CHECK (date_fin >= date_debut)
);

CREATE TABLE presence (
  id         serial PRIMARY KEY,
  employe_id integer NOT NULL REFERENCES employe(id),
  date_jour  date NOT NULL,
  statut     varchar(10) NOT NULL CHECK (statut IN ('present','absent','retard','conge')),
  heures     numeric(4,1),
  UNIQUE (employe_id, date_jour)
);

-- Rubriques de paie paramétrables. base : 'brut' ou 'salaire_base'.
CREATE TABLE rubrique_paie (
  id       serial PRIMARY KEY,
  agence_id smallint REFERENCES agence(id),            -- NULL = toutes les agences
  code     varchar(20) NOT NULL,
  libelle  text NOT NULL,
  type     varchar(20) NOT NULL CHECK (type IN ('gain','retenue_salariale','charge_patronale')),
  mode     varchar(12) NOT NULL CHECK (mode IN ('fixe','pourcentage')),
  valeur   numeric(12,5) NOT NULL CHECK (valeur >= 0),
  base     varchar(12) NOT NULL DEFAULT 'brut' CHECK (base IN ('brut','salaire_base')),
  actif    boolean NOT NULL DEFAULT true,
  ordre    smallint NOT NULL DEFAULT 100
);
CREATE UNIQUE INDEX rubrique_paie_code ON rubrique_paie (code, COALESCE(agence_id, 0));

CREATE TABLE avance_salaire (
  id          serial PRIMARY KEY,
  employe_id  integer NOT NULL REFERENCES employe(id),
  date_avance date NOT NULL,
  montant     numeric(14,0) NOT NULL CHECK (montant > 0),
  restant     numeric(14,0) NOT NULL,
  statut      varchar(10) NOT NULL DEFAULT 'en_cours' CHECK (statut IN ('en_cours','soldee')),
  CHECK (restant BETWEEN 0 AND montant)
);

-- ---------------------------------------------------------------------
-- Commission de collectrice : production x taux_commission, nette de la retenue sur le compte agent
-- (plafonnée par plafond_retenue). La production dépend de mode_cloture (voir production_collectrice).
-- ---------------------------------------------------------------------
CREATE TABLE commission_collectrice (
  id               serial PRIMARY KEY,
  agence_id        smallint NOT NULL REFERENCES agence(id),
  collectrice_id   integer NOT NULL REFERENCES collectrice(id),
  periode_debut    date NOT NULL,
  periode_fin      date NOT NULL,
  production       numeric(14,0) NOT NULL,
  taux             numeric(7,5) NOT NULL,
  commission_brute numeric(14,0) NOT NULL,
  retenue_agent    numeric(14,0) NOT NULL DEFAULT 0,
  commission_nette numeric(14,0) NOT NULL,
  statut           varchar(10) NOT NULL DEFAULT 'calculee' CHECK (statut IN ('calculee','payee')),
  calcule_le       timestamptz NOT NULL DEFAULT now(),
  CHECK (periode_fin >= periode_debut),
  UNIQUE (collectrice_id, periode_debut, periode_fin)
);

CREATE FUNCTION calculer_commission(p_collectrice integer, p_du date, p_au date) RETURNS integer
LANGUAGE plpgsql AS $$
DECLARE c mf.collectrice; v_prod numeric; v_taux numeric; v_brute numeric; v_ret numeric := 0; v_id integer;
BEGIN
  SELECT * INTO c FROM mf.collectrice WHERE id = p_collectrice FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'collectrice % inconnue', p_collectrice; END IF;
  IF EXISTS (SELECT 1 FROM mf.commission_collectrice WHERE collectrice_id = p_collectrice
              AND periode_debut = p_du AND periode_fin = p_au) THEN
    RAISE EXCEPTION 'commission déjà calculée pour la collectrice % sur % - %', c.matricule, p_du, p_au;
  END IF;
  v_prod  := mf.production_collectrice(p_collectrice, p_du, p_au);
  v_taux  := mf.param_num('taux_commission', c.agence_id);
  v_brute := round(v_prod * v_taux);
  IF c.agent_id IS NOT NULL THEN
    v_ret := mf.retenue_sur_commission(c.agent_id, v_brute, p_au);
  END IF;
  INSERT INTO mf.commission_collectrice(agence_id, collectrice_id, periode_debut, periode_fin, production,
                                        taux, commission_brute, retenue_agent, commission_nette)
  VALUES (c.agence_id, p_collectrice, p_du, p_au, v_prod, v_taux, v_brute, v_ret, v_brute - v_ret)
  RETURNING id INTO v_id;
  RETURN v_id;
END $$;

-- ---------------------------------------------------------------------
-- Bulletins de paie
-- ---------------------------------------------------------------------
CREATE TABLE bulletin_paie (
  id               serial PRIMARY KEY,
  agence_id        smallint NOT NULL REFERENCES agence(id),
  employe_id       integer NOT NULL REFERENCES employe(id),
  periode          date NOT NULL,                   -- 1er jour du mois
  salaire_base     numeric(14,0) NOT NULL,
  commission_nette numeric(14,0) NOT NULL DEFAULT 0,
  brut             numeric(14,0) NOT NULL,
  retenues         numeric(14,0) NOT NULL,          -- retenues salariales (hors avance)
  retenue_avance   numeric(14,0) NOT NULL DEFAULT 0,
  charges_patronales numeric(14,0) NOT NULL DEFAULT 0,
  net_a_payer      numeric(14,0) NOT NULL,
  statut           varchar(10) NOT NULL DEFAULT 'brouillon' CHECK (statut IN ('brouillon','valide','paye')),
  commission_id    integer REFERENCES commission_collectrice(id),
  cree_le          timestamptz NOT NULL DEFAULT now(),
  UNIQUE (employe_id, periode)
);

CREATE TABLE ligne_bulletin (
  id          serial PRIMARY KEY,
  bulletin_id integer NOT NULL REFERENCES bulletin_paie(id) ON DELETE CASCADE,
  code        varchar(20) NOT NULL,
  libelle     text NOT NULL,
  type        varchar(20) NOT NULL,
  base        numeric(14,0),
  taux        numeric(12,5),
  montant     numeric(14,0) NOT NULL
);

-- Génère le bulletin d'un employé pour un mois : salaire de base du contrat en vigueur, commission nette
-- de la période (si la collectrice a une commission calculée sur le mois), rubriques actives, retenue d'avance
-- (dans la limite du net restant). Pas de retenue pour absence : non spécifiée dans le brief.
CREATE FUNCTION generer_bulletin(p_employe integer, p_periode date) RETURNS integer
LANGUAGE plpgsql AS $$
DECLARE e mf.employe; v_mois date := date_trunc('month', p_periode)::date; v_fin date;
        v_base numeric; v_comm numeric := 0; v_comm_id integer; v_brut numeric; v_gains numeric := 0;
        v_ret numeric := 0; v_pat numeric := 0; v_net numeric; v_avance numeric := 0; v_id integer;
        r record; v_m numeric; v_b numeric;
BEGIN
  v_fin := (v_mois + interval '1 month - 1 day')::date;
  SELECT * INTO e FROM mf.employe WHERE id = p_employe FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'employé % inconnu', p_employe; END IF;
  SELECT salaire_base INTO v_base FROM mf.contrat
   WHERE employe_id = p_employe AND date_debut <= v_fin AND (date_fin IS NULL OR date_fin >= v_mois)
   ORDER BY date_debut DESC LIMIT 1;
  IF v_base IS NULL THEN RAISE EXCEPTION 'aucun contrat pour % sur %', e.matricule, v_mois; END IF;
  IF EXISTS (SELECT 1 FROM mf.bulletin_paie WHERE employe_id = p_employe AND periode = v_mois) THEN
    RAISE EXCEPTION 'bulletin déjà généré pour % sur %', e.matricule, v_mois;
  END IF;

  IF e.collectrice_id IS NOT NULL THEN
    SELECT id, commission_nette INTO v_comm_id, v_comm FROM mf.commission_collectrice
     WHERE collectrice_id = e.collectrice_id AND statut = 'calculee'
       AND periode_debut >= v_mois AND periode_fin <= v_fin
     ORDER BY periode_fin DESC LIMIT 1;
    v_comm := COALESCE(v_comm, 0);
  END IF;

  INSERT INTO mf.bulletin_paie(agence_id, employe_id, periode, salaire_base, commission_nette, brut, retenues,
                               net_a_payer, commission_id)
  VALUES (e.agence_id, p_employe, v_mois, v_base, v_comm, v_base + v_comm, 0, 0, v_comm_id)
  RETURNING id INTO v_id;
  INSERT INTO mf.ligne_bulletin(bulletin_id, code, libelle, type, montant) VALUES (v_id, 'BASE', 'Salaire de base', 'gain', v_base);
  IF v_comm > 0 THEN
    INSERT INTO mf.ligne_bulletin(bulletin_id, code, libelle, type, montant) VALUES (v_id, 'COMMISSION', 'Commission nette', 'gain', v_comm);
  END IF;

  -- gains paramétrés (sur le salaire de base), puis brut
  FOR r IN SELECT * FROM mf.rubrique_paie WHERE actif AND type = 'gain' AND (agence_id IS NULL OR agence_id = e.agence_id) ORDER BY ordre, id LOOP
    v_m := CASE WHEN r.mode = 'fixe' THEN r.valeur ELSE round(v_base * r.valeur) END;
    v_gains := v_gains + v_m;
    INSERT INTO mf.ligne_bulletin(bulletin_id, code, libelle, type, base, taux, montant)
    VALUES (v_id, r.code, r.libelle, 'gain', CASE WHEN r.mode = 'pourcentage' THEN v_base END,
            CASE WHEN r.mode = 'pourcentage' THEN r.valeur END, v_m);
  END LOOP;
  v_brut := v_base + v_comm + v_gains;

  FOR r IN SELECT * FROM mf.rubrique_paie WHERE actif AND type IN ('retenue_salariale','charge_patronale')
              AND (agence_id IS NULL OR agence_id = e.agence_id) ORDER BY ordre, id LOOP
    v_b := CASE WHEN r.base = 'brut' THEN v_brut ELSE v_base END;
    v_m := CASE WHEN r.mode = 'fixe' THEN r.valeur ELSE round(v_b * r.valeur) END;
    IF r.type = 'retenue_salariale' THEN v_ret := v_ret + v_m; ELSE v_pat := v_pat + v_m; END IF;
    INSERT INTO mf.ligne_bulletin(bulletin_id, code, libelle, type, base, taux, montant)
    VALUES (v_id, r.code, r.libelle, r.type, CASE WHEN r.mode = 'pourcentage' THEN v_b END,
            CASE WHEN r.mode = 'pourcentage' THEN r.valeur END, v_m);
  END LOOP;

  -- retenue d'avances : tout le restant dû, dans la limite du net disponible
  SELECT COALESCE(sum(restant), 0) INTO v_avance FROM mf.avance_salaire WHERE employe_id = p_employe AND statut = 'en_cours';
  v_avance := LEAST(v_avance, GREATEST(v_brut - v_ret, 0));
  IF v_avance > 0 THEN
    INSERT INTO mf.ligne_bulletin(bulletin_id, code, libelle, type, montant) VALUES (v_id, 'AVANCE', 'Retenue d''avance', 'retenue_salariale', v_avance);
  END IF;
  v_net := v_brut - v_ret - v_avance;
  UPDATE mf.bulletin_paie
     SET brut = v_brut, retenues = v_ret, retenue_avance = v_avance, charges_patronales = v_pat, net_a_payer = v_net
   WHERE id = v_id;
  RETURN v_id;
END $$;

CREATE FUNCTION generer_bulletins(p_agence smallint, p_periode date) RETURNS integer
LANGUAGE plpgsql AS $$
DECLARE x record; n integer := 0; v_mois date := date_trunc('month', p_periode)::date;
BEGIN
  FOR x IN SELECT e.id FROM mf.employe e
            WHERE e.agence_id = p_agence AND e.statut = 'actif'
              AND NOT EXISTS (SELECT 1 FROM mf.bulletin_paie b WHERE b.employe_id = e.id AND b.periode = v_mois)
              AND EXISTS (SELECT 1 FROM mf.contrat c WHERE c.employe_id = e.id AND c.date_debut <= (v_mois + interval '1 month - 1 day')::date
                           AND (c.date_fin IS NULL OR c.date_fin >= v_mois))
            ORDER BY e.id LOOP
    PERFORM mf.generer_bulletin(x.id, v_mois);
    n := n + 1;
  END LOOP;
  RETURN n;
END $$;

-- Validation : impute la retenue d'avance et marque la commission comme payée.
CREATE FUNCTION valider_bulletin(p_bulletin integer) RETURNS void
LANGUAGE plpgsql AS $$
DECLARE b mf.bulletin_paie; v_reste numeric; a record; v_use numeric;
BEGIN
  SELECT * INTO b FROM mf.bulletin_paie WHERE id = p_bulletin FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'bulletin % inconnu', p_bulletin; END IF;
  IF b.statut <> 'brouillon' THEN RAISE EXCEPTION 'bulletin % déjà validé', p_bulletin; END IF;
  v_reste := b.retenue_avance;
  FOR a IN SELECT * FROM mf.avance_salaire WHERE employe_id = b.employe_id AND statut = 'en_cours' ORDER BY date_avance, id FOR UPDATE LOOP
    EXIT WHEN v_reste <= 0;
    v_use := LEAST(v_reste, a.restant);
    UPDATE mf.avance_salaire SET restant = restant - v_use, statut = CASE WHEN restant - v_use = 0 THEN 'soldee' ELSE statut END WHERE id = a.id;
    v_reste := v_reste - v_use;
  END LOOP;
  IF b.commission_id IS NOT NULL THEN
    UPDATE mf.commission_collectrice SET statut = 'payee' WHERE id = b.commission_id;
  END IF;
  UPDATE mf.bulletin_paie SET statut = 'valide' WHERE id = p_bulletin;
END $$;
