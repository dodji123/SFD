SET search_path = mf, public;

-- Module sous test : 33_reseaux.sql (réseaux d'agences, périmètre des utilisateurs)
INSERT INTO agence(code,libelle) VALUES ('LOM','Lomé'),('KPA','Kpalimé'),('KAR','Kara');
INSERT INTO reseau(code,libelle) VALUES ('SUD','Réseau Sud'),('NRD','Réseau Nord');
UPDATE agence SET reseau_id = (SELECT id FROM reseau WHERE code='SUD') WHERE code IN ('LOM','KPA');
UPDATE agence SET reseau_id = (SELECT id FROM reseau WHERE code='NRD') WHERE code = 'KAR';

INSERT INTO utilisateur(login,nom,role,agence_id) SELECT 'chef.lom','Chef Lomé','chef_agence',id FROM agence WHERE code='LOM';
INSERT INTO utilisateur(login,nom,role,reseau_id) SELECT 'coord.sud','Coordinateur Sud','chef_agence',id FROM reseau WHERE code='SUD';
INSERT INTO utilisateur(login,nom,role) VALUES ('dir','Directeur','directeur');

SELECT t.eq('A périmètre agence', array_length(agences_utilisateur(id),1)::text, '1') FROM utilisateur WHERE login='chef.lom';
SELECT t.eq('A périmètre réseau = 2 agences', array_length(agences_utilisateur(id),1)::text, '2') FROM utilisateur WHERE login='coord.sud';
SELECT t.eq('A siège = toutes (NULL)', COALESCE(agences_utilisateur(id)::text,'NULL'), 'NULL') FROM utilisateur WHERE login='dir';

SELECT t.refuse('B agence ET réseau interdits', 'INSERT INTO mf.utilisateur(login,nom,role,agence_id,reseau_id) SELECT ''x'',''x'',''chef_agence'',a.id,r.id FROM mf.agence a, mf.reseau r LIMIT 1');
SELECT t.refuse('B caissier sans périmètre interdit', 'INSERT INTO mf.utilisateur(login,nom,role) VALUES (''cais'',''Cais'',''caissier'')');
UPDATE reseau SET actif = false WHERE code='NRD';
SELECT t.refuse('B réseau inactif refusé', 'INSERT INTO mf.utilisateur(login,nom,role,reseau_id) SELECT ''y'',''y'',''chef_agence'',id FROM mf.reseau WHERE code=''NRD''');
SELECT t.eq('C réseau audité', (count(*) > 0)::text, 'true') FROM audit_log WHERE table_name = 'reseau';
