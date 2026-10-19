SET search_path = mf, public;

-- Module sous test : 25_liaison_tontine_epargne.sql (liaison cycle de tontine / compte classique)
INSERT INTO agence(code,libelle) VALUES ('LOM','Lomé Centre');
INSERT INTO utilisateur(agence_id,login,nom,role) VALUES (1,'chef','Chef','chef_agence');
INSERT INTO produit_epargne(code,libelle,categorie,type_cycle) VALUES ('T1','Tontine','collecte',1);
INSERT INTO produit_epargne(code,libelle,categorie) VALUES ('CL','Classique','classique');
INSERT INTO client(agence_id,nom) VALUES (1,'Client un'),(1,'Client deux');
INSERT INTO compte_epargne(agence_id,client_id,produit_id) VALUES (1,1,2),(1,2,2);
INSERT INTO cycle(agence_id,client_id,produit_id,type_cycle,mise_initiale,mise_courante,objectif,nb_lignes_prevues,date_debut,date_fin)
VALUES (1,1,1,1,500,500,15500,31,'2025-01-01','2025-12-31'),(1,2,1,1,500,500,15500,31,'2025-01-01','2025-12-31');

SELECT t.eq('A liaison créée', (lier_cycle_compte(1, 1, 1) IS NOT NULL)::text, 'true');
SELECT t.refuse('A compte d''un autre client', 'SELECT mf.lier_cycle_compte(1, 2, 1)');
SELECT t.refuse('A cycle inconnu', 'SELECT mf.lier_cycle_compte(99, 1, 1)');
SELECT t.eq('A une seule liaison par cycle (remplacement)', count(*)::text, '1') FROM liaison_tontine_epargne WHERE cycle_id = 1;
INSERT INTO compte_epargne(agence_id,client_id,produit_id) VALUES (1,1,2);
SELECT lier_cycle_compte(1, 3, 1);
SELECT t.eq('A le second compte remplace le premier', compte_id::text, '3') FROM liaison_tontine_epargne WHERE cycle_id = 1;
SELECT t.eq('A pas de doublon', count(*)::text, '1') FROM liaison_tontine_epargne;
UPDATE compte_epargne SET statut = 'bloque' WHERE id = 3;
SELECT t.refuse('B compte non actif', 'SELECT mf.lier_cycle_compte(1, 3, 1)');
SELECT t.refuse('B compte de tontine refusé comme cible', 'SELECT mf.lier_cycle_compte(1, (SELECT id FROM mf.compte_epargne WHERE client_id = 1 AND statut = ''actif'' ORDER BY id LIMIT 1) + 100, 1)');
SELECT delier_cycle_compte(1);
SELECT t.eq('C liaison supprimée', count(*)::text, '0') FROM liaison_tontine_epargne;
SELECT t.refuse('C rien à délier', 'SELECT mf.delier_cycle_compte(1)');
