SET search_path = mf, public;

-- Module sous test : 47_controle_livrets.sql (constat terrain d'un livret, écarts, validation, inaltérabilité)
INSERT INTO agence(code,libelle) VALUES ('LOM','Lomé Centre');
INSERT INTO agent(agence_id,matricule,nom) VALUES (1,'A01','Agent un');
INSERT INTO client(agence_id,nom) VALUES (1,'Cliente un');
INSERT INTO utilisateur(login,nom,role,agence_id) VALUES ('ctrl','Contrôleur','chef_agence',1),('chef','Chef','chef_agence',1);
INSERT INTO produit_epargne(code,libelle,categorie) VALUES ('TON','Tontine','collecte');
INSERT INTO cycle(agence_id,numero,client_id,produit_id,type_cycle,mise_initiale,mise_courante,objectif,date_debut,date_fin)
  VALUES (1,'CY-1',1,1,2,1000,1000,31000,'2026-10-01','2026-10-31');
INSERT INTO ligne_collecte(cycle_id,page,no_ligne,date_collecte,agent_id,montant_collecte) VALUES
  (1,1,1,'2026-10-02',1,1000),(1,1,2,'2026-10-03',1,1000),(1,1,3,'2026-10-04',1,1000);

-- ===== A. Constat rapproché du système =====
INSERT INTO controle_livret(cycle_id,controleur_id,etat_livret,nb_lignes_constatees,total_constate,cle)
  VALUES (1,(SELECT id FROM utilisateur WHERE login='ctrl'),'conforme',3,3000,'k-1');
SELECT t.eq('A instantané du système : lignes/total/agence', nb_lignes_systeme || '/' || total_systeme || '/' || agence_id, '3/3000/1') FROM controle_livret WHERE cle = 'k-1';
SELECT t.eq('A écart nul', ecart_montant::text, '0') FROM controle_livret WHERE cle = 'k-1';
SELECT t.refuse('A conforme avec un écart', 'INSERT INTO mf.controle_livret(cycle_id,controleur_id,etat_livret,nb_lignes_constatees,total_constate,commentaire) VALUES (1,(SELECT id FROM mf.utilisateur WHERE login=''ctrl''),''conforme'',3,4000,''écart constaté'')');
SELECT t.refuse('A écart non commenté', 'INSERT INTO mf.controle_livret(cycle_id,controleur_id,etat_livret,nb_lignes_constatees,total_constate) VALUES (1,(SELECT id FROM mf.utilisateur WHERE login=''ctrl''),''incomplet'',2,2000)');
SELECT t.refuse('A constat sans total', 'INSERT INTO mf.controle_livret(cycle_id,controleur_id,etat_livret,nb_lignes_constatees) VALUES (1,(SELECT id FROM mf.utilisateur WHERE login=''ctrl''),''abime'',3)');
SELECT t.refuse('A livret perdu non commenté', 'INSERT INTO mf.controle_livret(cycle_id,controleur_id,etat_livret) VALUES (1,(SELECT id FROM mf.utilisateur WHERE login=''ctrl''),''perdu'')');
SELECT t.refuse('A clé d''opération rejouée', 'INSERT INTO mf.controle_livret(cycle_id,controleur_id,etat_livret,nb_lignes_constatees,total_constate,cle) VALUES (1,(SELECT id FROM mf.utilisateur WHERE login=''ctrl''),''conforme'',3,3000,''k-1'')');
INSERT INTO controle_livret(cycle_id,controleur_id,etat_livret,nb_lignes_constatees,total_constate,commentaire,cle)
  VALUES (1,(SELECT id FROM utilisateur WHERE login='ctrl'),'incomplet',2,2000,'Une ligne du 3/10 absente du livret','k-2');
SELECT t.eq('A écart de montant calculé', ecart_montant::text, '-1000') FROM controle_livret WHERE cle = 'k-2';

-- ===== B. Écarts ligne à ligne =====
INSERT INTO controle_livret_ligne(controle_id,no_ligne,date_collecte,montant_systeme,nature) SELECT id,3,'2026-10-04',1000,'absente_livret' FROM controle_livret WHERE cle = 'k-2';
SELECT t.refuse('B écart absent du livret avec un montant livret', 'INSERT INTO mf.controle_livret_ligne(controle_id,no_ligne,montant_livret,montant_systeme,nature) SELECT id,4,500,1000,''absente_livret'' FROM mf.controle_livret WHERE cle = ''k-2''');
SELECT t.refuse('B montant différent mais identique', 'INSERT INTO mf.controle_livret_ligne(controle_id,no_ligne,montant_livret,montant_systeme,nature) SELECT id,5,1000,1000,''montant_different'' FROM mf.controle_livret WHERE cle = ''k-2''');
SELECT t.refuse('B ligne en double', 'INSERT INTO mf.controle_livret_ligne(controle_id,no_ligne,date_collecte,montant_systeme,nature) SELECT id,3,''2026-10-04'',1000,''absente_livret'' FROM mf.controle_livret WHERE cle = ''k-2''');

-- ===== C. Validation par un responsable =====
SELECT t.refuse('C le contrôleur valide son propre contrôle', 'UPDATE mf.controle_livret SET statut = ''valide'', decide_par = controleur_id WHERE cle = ''k-2''');
SELECT t.refuse('C validation sans auteur', 'UPDATE mf.controle_livret SET statut = ''valide'' WHERE cle = ''k-2''');
SELECT t.refuse('C rejet non motivé', 'UPDATE mf.controle_livret SET statut = ''rejete'', decide_par = (SELECT id FROM mf.utilisateur WHERE login=''chef'') WHERE cle = ''k-2''');
SELECT t.refuse('C le constat ne change pas à la décision', 'UPDATE mf.controle_livret SET statut = ''valide'', total_constate = 3000, decide_par = (SELECT id FROM mf.utilisateur WHERE login=''chef'') WHERE cle = ''k-2''');
UPDATE controle_livret SET statut = 'valide', decide_par = (SELECT id FROM utilisateur WHERE login='chef') WHERE cle = 'k-2';
SELECT t.eq('C décision horodatée', (decide_le IS NOT NULL)::text, 'true') FROM controle_livret WHERE cle = 'k-2';
SELECT t.refuse('C contrôle décidé non modifiable', 'UPDATE mf.controle_livret SET commentaire = ''autre'' WHERE cle = ''k-2''');
SELECT t.refuse('C écarts d''un contrôle décidé non modifiables', 'DELETE FROM mf.controle_livret_ligne');
SELECT t.refuse('C contrôle non supprimable', 'DELETE FROM mf.controle_livret');

-- ===== D. Vue de consultation =====
SELECT t.eq('D vue : client, produit, contrôleur, nombre d''écarts', client || '/' || produit || '/' || controleur || '/' || nb_ecarts_lignes, 'Cliente un/TON/Contrôleur/1') FROM v_controle_livret WHERE cle = 'k-2';
