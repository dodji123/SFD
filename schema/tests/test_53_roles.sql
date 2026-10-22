SET search_path = mf, public;

-- Module sous test : 53_roles.sql (matrice de droits, rôles personnalisés, affectations datées avec validation)
INSERT INTO agence(code,libelle) VALUES ('LOM','Lomé Centre'),('KPA','Kpalimé');
INSERT INTO utilisateur(login,nom,role,agence_id) VALUES
  ('admin1','Admin','admin',NULL),
  ('dir1','Directeur','directeur',NULL),
  ('chef1','Chef Lomé','chef_agence',1),
  ('caiss1','Caissier Lomé','caissier',1),
  ('aud1','Auditeur','auditeur',NULL);

-- ===== A. Matrice d'origine =====
SELECT t.eq('A permissions reprises (dont celles des modules 52 et 54)', count(*)::text, '103') FROM permission;
SELECT t.eq('A rôles d''origine', count(*)::text, '10') FROM role_droit WHERE systeme;
SELECT t.eq('A l''administrateur gère les rôles', count(*)::text, '1') FROM droit_role WHERE role_code = 'admin' AND perm = 'roles:gerer';
SELECT t.eq('A le caissier ne gère pas les rôles', count(*)::text, '0') FROM droit_role WHERE role_code = 'caissier' AND perm = 'roles:gerer';
SELECT t.eq('A droits de base d''un caissier', count(*)::text, '1') FROM droits_utilisateur((SELECT id FROM utilisateur WHERE login = 'caiss1'), current_date) AS d(perm) WHERE perm = 'caisse:write';
SELECT t.refuse('A permission inconnue', 'INSERT INTO mf.droit_role(role_code, perm) VALUES (''caissier'', ''inexistant:perm'')');
SELECT t.refuse('A rôle inconnu dans la matrice', 'INSERT INTO mf.droit_role(role_code, perm) VALUES (''fantome'', ''caisse:write'')');

-- ===== B. Garde-fous sur la matrice et les rôles =====
SELECT t.refuse('B l''administrateur ne perd pas la gestion des rôles', 'DELETE FROM mf.droit_role WHERE role_code = ''admin'' AND perm = ''roles:gerer''');
SELECT t.refuse('B l''administrateur ne perd pas la gestion des utilisateurs', 'DELETE FROM mf.droit_role WHERE role_code = ''admin'' AND perm = ''users:manage''');
SELECT t.refuse('B un rôle d''origine ne se supprime pas', 'DELETE FROM mf.role_droit WHERE code = ''caissier''');
SELECT t.refuse('B le code d''un rôle d''origine ne change pas', 'UPDATE mf.role_droit SET code = ''caisse_x'' WHERE code = ''caissier''');
SELECT t.refuse('B le rôle administrateur reste actif', 'UPDATE mf.role_droit SET actif = false WHERE code = ''admin''');
INSERT INTO role_droit(code, libelle) VALUES ('superviseur', 'Superviseur de caisse');
INSERT INTO droit_role(role_code, perm) VALUES ('superviseur', 'caisse:write'), ('superviseur', 'caisse:read'), ('superviseur', 'roles:demander');
SELECT t.eq('B rôle personnalisé créé avec ses permissions', count(*)::text, '3') FROM droit_role WHERE role_code = 'superviseur';

-- ===== C. Affectations : demande, contrôles, validation =====
SELECT t.refuse('C affectation dans le passé', 'INSERT INTO mf.affectation_role(utilisateur_id, role_code, agence_id, date_debut, date_fin, motif, demande_par) VALUES ((SELECT id FROM mf.utilisateur WHERE login=''caiss1''), ''superviseur'', 1, current_date - 5, current_date + 10, ''Remplacement pendant congé'', (SELECT id FROM mf.utilisateur WHERE login=''chef1''))');
SELECT t.refuse('C durée supérieure à six mois', 'INSERT INTO mf.affectation_role(utilisateur_id, role_code, agence_id, date_debut, date_fin, motif, demande_par) VALUES ((SELECT id FROM mf.utilisateur WHERE login=''caiss1''), ''superviseur'', 1, current_date + 1, current_date + 300, ''Remplacement pendant congé'', (SELECT id FROM mf.utilisateur WHERE login=''chef1''))');
SELECT t.refuse('C affectation pour une personne du siège', 'INSERT INTO mf.affectation_role(utilisateur_id, role_code, agence_id, date_debut, date_fin, motif, demande_par) VALUES ((SELECT id FROM mf.utilisateur WHERE login=''dir1''), ''superviseur'', 1, current_date + 1, current_date + 30, ''Remplacement pendant congé'', (SELECT id FROM mf.utilisateur WHERE login=''chef1''))');
SELECT t.refuse('C motif trop court', 'INSERT INTO mf.affectation_role(utilisateur_id, role_code, agence_id, date_debut, date_fin, motif, demande_par) VALUES ((SELECT id FROM mf.utilisateur WHERE login=''caiss1''), ''superviseur'', 1, current_date + 1, current_date + 30, ''court'', (SELECT id FROM mf.utilisateur WHERE login=''chef1''))');
SELECT t.refuse('C agence hors du périmètre de l''utilisateur', 'INSERT INTO mf.affectation_role(utilisateur_id, role_code, agence_id, date_debut, date_fin, motif, demande_par) VALUES ((SELECT id FROM mf.utilisateur WHERE login=''caiss1''), ''superviseur'', 2, current_date + 1, current_date + 30, ''Remplacement pendant congé'', (SELECT id FROM mf.utilisateur WHERE login=''chef1''))');
SELECT t.refuse('C rôle qu''il a déjà', 'INSERT INTO mf.affectation_role(utilisateur_id, role_code, agence_id, date_debut, date_fin, motif, demande_par) VALUES ((SELECT id FROM mf.utilisateur WHERE login=''caiss1''), ''caissier'', 1, current_date + 1, current_date + 30, ''Remplacement pendant congé'', (SELECT id FROM mf.utilisateur WHERE login=''chef1''))');
INSERT INTO affectation_role(utilisateur_id, role_code, agence_id, date_debut, date_fin, motif, demande_par) VALUES ((SELECT id FROM utilisateur WHERE login='caiss1'), 'superviseur', 1, current_date, current_date + 30, 'Remplacement pendant le congé du chef', (SELECT id FROM utilisateur WHERE login='chef1'));
SELECT t.eq('C la demande est en attente', statut, 'demandee') FROM affectation_role WHERE role_code = 'superviseur';
SELECT t.eq('C tant qu''elle n''est pas validée, aucun droit en plus', count(*)::text, '0') FROM droits_utilisateur((SELECT id FROM utilisateur WHERE login='caiss1'), current_date) AS d(perm) WHERE perm = 'roles:demander';
SELECT t.refuse('C doublon d''une demande ouverte', 'INSERT INTO mf.affectation_role(utilisateur_id, role_code, agence_id, date_debut, date_fin, motif, demande_par) VALUES ((SELECT id FROM mf.utilisateur WHERE login=''caiss1''), ''superviseur'', 1, current_date + 1, current_date + 30, ''Autre demande identique'', (SELECT id FROM mf.utilisateur WHERE login=''chef1''))');
SELECT t.refuse('C le demandeur ne valide pas sa demande', 'UPDATE mf.affectation_role SET statut = ''active'', valide_par = (SELECT id FROM mf.utilisateur WHERE login=''chef1'') WHERE role_code = ''superviseur''');
SELECT t.refuse('C on ne se donne pas un rôle soi-même', 'UPDATE mf.affectation_role SET statut = ''active'', valide_par = (SELECT id FROM mf.utilisateur WHERE login=''caiss1'') WHERE role_code = ''superviseur''');
SELECT t.refuse('C refus non motivé', 'UPDATE mf.affectation_role SET statut = ''refusee'', valide_par = (SELECT id FROM mf.utilisateur WHERE login=''dir1'') WHERE role_code = ''superviseur''');
SELECT t.refuse('C contenu de la demande non modifiable', 'UPDATE mf.affectation_role SET date_fin = current_date + 60 WHERE role_code = ''superviseur''');
SELECT t.refuse('C demande non supprimable', 'DELETE FROM mf.affectation_role WHERE role_code = ''superviseur''');
UPDATE affectation_role SET statut = 'active', valide_par = (SELECT id FROM utilisateur WHERE login='dir1') WHERE role_code = 'superviseur';
SELECT t.eq('C validée par le directeur : active', statut || '/' || (valide_par IS NOT NULL)::text, 'active/true') FROM affectation_role WHERE role_code = 'superviseur';
SELECT t.refuse('C décision sur une affectation déjà active', 'UPDATE mf.affectation_role SET statut = ''refusee'', valide_par = (SELECT id FROM mf.utilisateur WHERE login=''dir1''), commentaire_decision = ''Trop tard'' WHERE role_code = ''superviseur''');

-- ===== D. Effet sur les droits =====
SELECT t.eq('D le caissier obtient le droit exclusif du superviseur', count(*)::text, '1') FROM droits_utilisateur((SELECT id FROM utilisateur WHERE login='caiss1'), current_date) AS d(perm) WHERE perm = 'roles:demander';
SELECT t.eq('D un autre utilisateur ne l''obtient pas', count(*)::text, '0') FROM droits_utilisateur((SELECT id FROM utilisateur WHERE login='aud1'), current_date) AS d(perm) WHERE perm = 'roles:demander';
SELECT t.eq('D après la date de fin : le droit disparaît', count(*)::text, '0') FROM droits_utilisateur((SELECT id FROM utilisateur WHERE login='caiss1'), current_date + 31) AS d(perm) WHERE perm = 'roles:demander';
SELECT t.eq('D affectation en cours', en_cours::text, 'true') FROM v_affectation_role WHERE role_code = 'superviseur';

-- ===== E. Révocation =====
SELECT t.refuse('E révocation sans motif', 'UPDATE mf.affectation_role SET statut = ''revoquee'', revoque_par = (SELECT id FROM mf.utilisateur WHERE login=''dir1'') WHERE role_code = ''superviseur''');
UPDATE affectation_role SET statut = 'revoquee', revoque_par = (SELECT id FROM utilisateur WHERE login='dir1'), motif_revocation = 'Fin du remplacement' WHERE role_code = 'superviseur';
SELECT t.eq('E révoquée : le droit disparaît aussitôt', count(*)::text, '0') FROM droits_utilisateur((SELECT id FROM utilisateur WHERE login='caiss1'), current_date) AS d(perm) WHERE perm = 'roles:demander';
SELECT t.refuse('E révoquée : pas de retour en arrière', 'UPDATE mf.affectation_role SET statut = ''active'' WHERE role_code = ''superviseur''');
SELECT t.refuse('E rôle encore affecté : suppression refusée', 'DELETE FROM mf.role_droit WHERE code = ''superviseur''');

-- ===== F. Historique =====
SELECT t.eq('F historique conservé', count(*)::text, '1') FROM affectation_role WHERE role_code = 'superviseur';
