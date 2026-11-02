SET search_path = mf, public;

-- Module sous test : 83_horloge_systeme.sql (date système du logiciel, recul de l'horloge refusé)
SELECT t.eq('A horloge initialisée', (SELECT count(*)::text FROM horloge_systeme), '1');
SELECT controler_horloge(now());
SELECT controler_horloge(now() - interval '2 minutes');
SELECT t.eq('A léger retard toléré (2 min)', (SELECT count(*)::text FROM horloge_systeme WHERE dernier_instant >= now() - interval '1 minute'), '1');
SELECT t.refuse('B recul d''une heure refusé', 'SELECT mf.controler_horloge(now() - interval ''1 hour'')');
SELECT t.refuse('B recul de 6 minutes refusé', 'SELECT mf.controler_horloge(now() - interval ''6 minutes'')');
SELECT t.refuse('B recul d''un jour refusé', 'SELECT mf.controler_horloge(now() - interval ''1 day'')');
-- C. Avance de l'horloge : acceptée, mais la date enregistrée reste la plus tardive vue
SELECT controler_horloge(now() + interval '3 days');
SELECT t.refuse('C retour à l''heure réelle refusé après une avance', 'SELECT mf.controler_horloge(now())');
