SET search_path = mf, public;

-- =====================================================================
-- 83 : date système propre au logiciel. Le logiciel mémorise le plus tard instant qu'il a vu ;
-- si l'horloge de la machine revient en arrière au-delà de la tolérance, toute écriture est refusée
-- tant que l'horloge n'est pas corrigée. Une horloge qui avance reste acceptée.
-- =====================================================================
CREATE TABLE horloge_systeme (
  id               integer PRIMARY KEY CHECK (id = 1),
  dernier_instant  timestamptz NOT NULL,
  mis_a_jour_le    timestamptz NOT NULL DEFAULT now()
);
INSERT INTO horloge_systeme(id, dernier_instant) VALUES (1, now());

CREATE FUNCTION controler_horloge(p_instant timestamptz) RETURNS void
LANGUAGE plpgsql AS $$
DECLARE v_dernier timestamptz;
BEGIN
  SELECT dernier_instant INTO v_dernier FROM mf.horloge_systeme WHERE id = 1 FOR UPDATE;
  IF p_instant < v_dernier - interval '5 minutes' THEN
    RAISE EXCEPTION 'la date système de cette machine est antérieure à la dernière date enregistrée (%) : opérations bloquées tant que l''horloge n''est pas corrigée', v_dernier;
  END IF;
  UPDATE mf.horloge_systeme SET dernier_instant = greatest(dernier_instant, p_instant), mis_a_jour_le = now() WHERE id = 1;
END $$;
