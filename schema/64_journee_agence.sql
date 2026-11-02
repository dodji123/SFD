SET search_path = mf, public;

-- =====================================================================
-- 64 : ouverture et clôture de la journée de l'agence.
--  * une journée s'ouvre si la précédente est close ; une seule journée ouverte par agence ;
--  * la clôture exige : aucune session de caisse ouverte pour la date, la collecte de la date validée
--    (s'il y a des lignes), l'épargne de la date validée (s'il y a des mouvements) ;
--  * une journée close se rouvre seulement avec un motif, et la réouverture est tracée.
-- =====================================================================
CREATE TABLE journee_agence (
  agence_id     smallint NOT NULL REFERENCES agence(id),
  date_journee  date NOT NULL,
  statut        varchar(10) NOT NULL DEFAULT 'ouverte' CHECK (statut IN ('ouverte','cloturee')),
  ouverte_par   integer REFERENCES utilisateur(id),
  ouverte_le    timestamptz NOT NULL DEFAULT now(),
  cloturee_par  integer REFERENCES utilisateur(id),
  cloturee_le   timestamptz,
  PRIMARY KEY (agence_id, date_journee),
  CHECK ((statut = 'cloturee') = (cloturee_le IS NOT NULL))
);

CREATE TABLE journee_agence_journal (
  id           bigserial PRIMARY KEY,
  agence_id    smallint NOT NULL REFERENCES agence(id),
  date_journee date NOT NULL,
  action       varchar(12) NOT NULL CHECK (action IN ('ouverture','cloture','reouverture')),
  utilisateur_id integer REFERENCES utilisateur(id),
  motif        text,
  cree_le      timestamptz NOT NULL DEFAULT now()
);

CREATE FUNCTION ouvrir_journee(p_agence smallint, p_date date, p_utilisateur integer DEFAULT NULL) RETURNS void
LANGUAGE plpgsql AS $$
BEGIN
  IF p_date > current_date THEN RAISE EXCEPTION 'impossible d''ouvrir une journée à venir'; END IF;
  IF EXISTS (SELECT 1 FROM journee_agence WHERE agence_id = p_agence AND statut = 'ouverte') THEN
    RAISE EXCEPTION 'une journée est déjà ouverte pour cette agence : la clôturer d''abord';
  END IF;
  IF EXISTS (SELECT 1 FROM journee_agence WHERE agence_id = p_agence AND date_journee >= p_date) THEN
    RAISE EXCEPTION 'la journée du % a déjà été ouverte', p_date;
  END IF;
  INSERT INTO journee_agence(agence_id, date_journee, ouverte_par) VALUES (p_agence, p_date, p_utilisateur);
  INSERT INTO journee_agence_journal(agence_id, date_journee, action, utilisateur_id) VALUES (p_agence, p_date, 'ouverture', p_utilisateur);
END $$;

CREATE FUNCTION cloturer_journee(p_agence smallint, p_date date, p_utilisateur integer DEFAULT NULL) RETURNS void
LANGUAGE plpgsql AS $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM journee_agence WHERE agence_id = p_agence AND date_journee = p_date AND statut = 'ouverte') THEN
    RAISE EXCEPTION 'la journée du % n''est pas ouverte', p_date;
  END IF;
  IF EXISTS (SELECT 1 FROM session_caisse s JOIN caisse k ON k.id = s.caisse_id
              WHERE k.agence_id = p_agence AND s.date_session = p_date AND s.statut = 'ouverte') THEN
    RAISE EXCEPTION 'des sessions de caisse sont encore ouvertes le % : les fermer d''abord', p_date;
  END IF;
  IF EXISTS (SELECT 1 FROM ligne_collecte l JOIN cycle c ON c.id = l.cycle_id
              WHERE c.agence_id = p_agence AND l.date_collecte = p_date)
     AND NOT EXISTS (SELECT 1 FROM validation_collecte v WHERE v.agence_id = p_agence AND v.date_collecte = p_date) THEN
    RAISE EXCEPTION 'la collecte du % n''est pas validée', p_date;
  END IF;
  IF EXISTS (SELECT 1 FROM mouvement_epargne m JOIN compte_epargne ce ON ce.id = m.compte_id
              WHERE ce.agence_id = p_agence AND m.date_operation = p_date)
     AND NOT EXISTS (SELECT 1 FROM validation_epargne v WHERE v.agence_id = p_agence AND v.date_operation = p_date) THEN
    RAISE EXCEPTION 'l''épargne du % n''est pas validée', p_date;
  END IF;
  UPDATE journee_agence SET statut = 'cloturee', cloturee_par = p_utilisateur, cloturee_le = now()
   WHERE agence_id = p_agence AND date_journee = p_date;
  INSERT INTO journee_agence_journal(agence_id, date_journee, action, utilisateur_id) VALUES (p_agence, p_date, 'cloture', p_utilisateur);
END $$;

CREATE FUNCTION rouvrir_journee(p_agence smallint, p_date date, p_motif text, p_utilisateur integer DEFAULT NULL) RETURNS void
LANGUAGE plpgsql AS $$
BEGIN
  IF p_motif IS NULL OR btrim(p_motif) = '' THEN RAISE EXCEPTION 'un motif est obligatoire pour rouvrir une journée'; END IF;
  IF EXISTS (SELECT 1 FROM journee_agence WHERE agence_id = p_agence AND statut = 'ouverte') THEN
    RAISE EXCEPTION 'une journée est déjà ouverte pour cette agence';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM journee_agence WHERE agence_id = p_agence AND date_journee = p_date AND statut = 'cloturee'
                 AND date_journee = (SELECT max(date_journee) FROM journee_agence WHERE agence_id = p_agence)) THEN
    RAISE EXCEPTION 'seule la dernière journée close peut être rouverte';
  END IF;
  UPDATE journee_agence SET statut = 'ouverte', cloturee_par = NULL, cloturee_le = NULL
   WHERE agence_id = p_agence AND date_journee = p_date;
  INSERT INTO journee_agence_journal(agence_id, date_journee, action, utilisateur_id, motif)
  VALUES (p_agence, p_date, 'reouverture', p_utilisateur, p_motif);
END $$;
