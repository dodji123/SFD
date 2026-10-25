SET search_path = mf, public;

-- Module 60 : la colonne execute_par identifie la caissière qui a payé le retrait.
SELECT t.eq('colonne execute_par présente sur retrait',
  (SELECT count(*)::text FROM information_schema.columns WHERE table_schema = 'mf' AND table_name = 'retrait' AND column_name = 'execute_par'), '1');
SELECT t.eq('execute_par référence un utilisateur',
  (SELECT count(*)::text FROM information_schema.table_constraints tc
     JOIN information_schema.constraint_column_usage ccu ON ccu.constraint_name = tc.constraint_name
    WHERE tc.table_schema = 'mf' AND tc.table_name = 'retrait' AND tc.constraint_type = 'FOREIGN KEY' AND ccu.table_name = 'utilisateur'), '1');
