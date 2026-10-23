SET search_path = mf, public;

-- Module sous test : 55_totp_personnel.sql (second facteur TOTP du personnel)
INSERT INTO utilisateur(login,nom,role,agence_id) VALUES ('admin1','Admin','admin',NULL),('dir1','Directeur','directeur',NULL);

-- ===== A. Secret : inactif tant que non prouvé =====
INSERT INTO utilisateur_totp(utilisateur_id, secret_chiffre) SELECT id, 'v1:gAAAAAB-secret-chiffre-factice' FROM utilisateur WHERE login = 'admin1';
SELECT t.eq('A secret créé inactif', actif::text, 'false') FROM utilisateur_totp;
SELECT t.refuse('A actif sans date d''activation', 'UPDATE mf.utilisateur_totp SET actif = true');
SELECT t.refuse('A date d''activation sans être actif', 'UPDATE mf.utilisateur_totp SET active_le = now()');
UPDATE utilisateur_totp SET actif = true, active_le = now(), dernier_pas = 100;
SELECT t.eq('A activé', actif::text, 'true') FROM utilisateur_totp;

-- ===== B. Anti-rejeu et immutabilité =====
SELECT t.refuse('B le pas ne recule pas', 'UPDATE mf.utilisateur_totp SET dernier_pas = 99');
UPDATE utilisateur_totp SET dernier_pas = 101;
SELECT t.eq('B le pas avance', dernier_pas::text, '101') FROM utilisateur_totp;
SELECT t.refuse('B le secret actif ne change pas', 'UPDATE mf.utilisateur_totp SET secret_chiffre = ''v1:autre-secret-chiffre-factice-xx''');
SELECT t.refuse('B pas de désactivation par mise à jour', 'UPDATE mf.utilisateur_totp SET actif = false, active_le = NULL');
SELECT t.refuse('B un seul secret par utilisateur', 'INSERT INTO mf.utilisateur_totp(utilisateur_id, secret_chiffre) SELECT id, ''v1:gAAAAAB-secret-chiffre-factice'' FROM mf.utilisateur WHERE login = ''admin1''');
SELECT t.refuse('B secret trop court', 'INSERT INTO mf.utilisateur_totp(utilisateur_id, secret_chiffre) SELECT id, ''court'' FROM mf.utilisateur WHERE login = ''dir1''');

-- ===== C. Codes de secours =====
INSERT INTO code_secours_totp(utilisateur_id, code_hash) SELECT id, repeat('a', 64) FROM utilisateur WHERE login = 'admin1';
SELECT t.refuse('C même code deux fois', 'INSERT INTO mf.code_secours_totp(utilisateur_id, code_hash) SELECT id, repeat(''a'', 64) FROM mf.utilisateur WHERE login = ''admin1''');
UPDATE code_secours_totp SET utilise_le = now();
SELECT t.refuse('C un code utilisé ne se réactive pas', 'UPDATE mf.code_secours_totp SET utilise_le = NULL');
SELECT t.refuse('C le haché ne change pas', 'UPDATE mf.code_secours_totp SET code_hash = repeat(''b'', 64)');

-- ===== D. Réinitialisation, sessions, journal, permission =====
DELETE FROM code_secours_totp;
DELETE FROM utilisateur_totp;
SELECT t.eq('D réinitialisation : plus de secret', count(*)::text, '0') FROM utilisateur_totp;
UPDATE utilisateur SET sessions_depuis = now() WHERE login = 'admin1';
SELECT t.eq('D sessions_depuis posé', (sessions_depuis > now() - interval '1 minute')::text, 'true') FROM utilisateur WHERE login = 'admin1';
INSERT INTO journal_connexion(login, utilisateur_id, evenement) SELECT login, id, 'totp_reinit' FROM utilisateur WHERE login = 'admin1';
INSERT INTO alerte_securite(type, gravite, utilisateur_id, detail) SELECT 'totp_reinit', 'moyenne', id, 'test' FROM utilisateur WHERE login = 'admin1';
SELECT t.eq('D événement et alerte acceptés', (SELECT count(*) FROM journal_connexion WHERE evenement = 'totp_reinit') || '/' || (SELECT count(*) FROM alerte_securite WHERE type = 'totp_reinit'), '1/1');
SELECT t.refuse('D événement inconnu refusé', 'INSERT INTO mf.journal_connexion(login, evenement) VALUES (''x'', ''inconnu'')');
SELECT t.eq('D droit de réinitialisation : admin et directeur', string_agg(role_code, ',' ORDER BY role_code), 'admin,directeur') FROM droit_role WHERE perm = 'totp:reinitialiser';
