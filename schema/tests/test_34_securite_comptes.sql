SET search_path = mf, public;

-- Module sous test : 34_securite_comptes.sql (historique des mots de passe, jetons, alertes, sauvegardes)
INSERT INTO agence(code,libelle) VALUES ('LOM','Lomé');
INSERT INTO reseau(code,libelle) VALUES ('SUD','Réseau Sud');
INSERT INTO utilisateur(login,nom,role,agence_id,mot_de_passe_hash) SELECT 'chef','Chef','chef_agence',id,'h1' FROM agence;
INSERT INTO utilisateur(login,nom,role) VALUES ('adm','Admin','admin'),('aud','Auditeur','auditeur');

SELECT t.eq('A historique alimenté à la création', count(*)::text, '1') FROM historique_mdp h JOIN utilisateur u ON u.id = h.utilisateur_id WHERE u.login = 'chef';
UPDATE utilisateur SET mot_de_passe_hash = 'h2' WHERE login = 'chef';
UPDATE utilisateur SET nom = 'Chef Lomé' WHERE login = 'chef';
SELECT t.eq('A historique : un ajout par changement de haché seulement', count(*)::text, '2') FROM historique_mdp h JOIN utilisateur u ON u.id = h.utilisateur_id WHERE u.login = 'chef';

SELECT t.refuse('B coordinateur sans réseau refusé', 'INSERT INTO mf.utilisateur(login,nom,role) VALUES (''co1'',''Co'',''coordinateur'')');
SELECT t.refuse('B coordinateur avec agence refusé', 'INSERT INTO mf.utilisateur(login,nom,role,agence_id) SELECT ''co2'',''Co'',''coordinateur'',id FROM mf.agence');
INSERT INTO utilisateur(login,nom,role,reseau_id) SELECT 'co3','Co','coordinateur',id FROM reseau;
SELECT t.eq('B coordinateur de réseau accepté', agences_utilisateur(id)::text, '{}') FROM utilisateur WHERE login = 'co3';

INSERT INTO jeton_reinit_mdp(utilisateur_id, jeton_hash, expire_le)
  SELECT id, repeat('a', 64), now() + interval '30 minutes' FROM utilisateur WHERE login = 'chef';
SELECT t.refuse('C haché de jeton unique', 'INSERT INTO mf.jeton_reinit_mdp(utilisateur_id, jeton_hash, expire_le) SELECT id, repeat(''a'',64), now() FROM mf.utilisateur LIMIT 1');

SELECT t.refuse('D événement de connexion inconnu', 'INSERT INTO mf.journal_connexion(login, evenement) VALUES (''x'',''bizarre'')');
INSERT INTO journal_connexion(login, evenement) VALUES ('chef','succes');
INSERT INTO alerte_securite(type, detail) VALUES ('verrouillage','5 échecs');
SELECT t.refuse('D alerte traitée sans traitant', 'UPDATE mf.alerte_securite SET traitee_le = now()');

INSERT INTO sauvegarde(effectuee_le, type, support, effectuee_par) SELECT now() - interval '2 days', 'complete', 'Disque coffre', id FROM utilisateur WHERE login = 'adm';
SELECT t.eq('E aucune sauvegarde fiable avant test', COALESCE(derniere_fiable::text,'aucune'), 'aucune') FROM v_sauvegarde_fiable;
SELECT t.refuse('E test par l''auteur refusé', 'UPDATE mf.sauvegarde SET test_restaure_le = now(), test_resultat = ''reussi'', test_par = effectuee_par');
SELECT t.refuse('E résultat sans date refusé', 'UPDATE mf.sauvegarde SET test_resultat = ''reussi'', test_par = (SELECT id FROM mf.utilisateur WHERE login=''aud'')');
UPDATE sauvegarde SET test_restaure_le = now(), test_resultat = 'reussi', test_par = (SELECT id FROM utilisateur WHERE login='aud');
SELECT t.eq('E sauvegarde fiable après test réussi', (derniere_fiable IS NOT NULL)::text, 'true') FROM v_sauvegarde_fiable;
