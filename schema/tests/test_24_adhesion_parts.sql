SET search_path = mf, public;

-- Module sous test : 24_adhesion_parts.sql (adhésion, parts sociales, membre en règle)
INSERT INTO agence(code,libelle) VALUES ('LOM','Lomé Centre');
INSERT INTO utilisateur(agence_id,login,nom,role) VALUES (1,'caisse','Caissier','caissier');
INSERT INTO client(agence_id,nom) VALUES (1,'Membre un'),(1,'Membre deux');

SELECT t.eq('A paramètres par défaut', mf.param_num('part_valeur_nominale', 1::smallint)::text || '/' || mf.param_num('droit_adhesion', 1::smallint)::text, '5000/2000');
SELECT t.eq('A pas membre sans adhésion', membre_en_regle(1)::text, 'false');
SELECT t.refuse('A parts sans adhésion', 'SELECT mf.souscrire_parts(1, 1, current_date, 1)');

SELECT adherer(1, current_date, 1);
SELECT t.eq('B adhésion numérotée', numero || ' ' || statut || ' ' || droit_adhesion, 'AD-LOM-' || extract(year FROM current_date) || '-000001 active 2000') FROM adhesion WHERE client_id = 1;
SELECT t.refuse('B une seule adhésion par client', 'SELECT mf.adherer(1, current_date, 1)');
SELECT t.refuse('B adhésion future', 'SELECT mf.adherer(2, current_date + 1, 1)');
SELECT t.eq('B adhérent sans part : pas en règle', membre_en_regle(1)::text, 'false');

SELECT t.refuse('C zéro part', 'SELECT mf.souscrire_parts(1, 0, current_date, 1)');
SELECT t.refuse('C part future', 'SELECT mf.souscrire_parts(1, 1, current_date + 1, 1)');
SELECT souscrire_parts(1, 3, current_date, 1);
SELECT t.eq('C 3 parts de 5000', nb_parts || '/' || capital_souscrit, '3/15000') FROM v_membre WHERE client_id = 1;
SELECT t.eq('C membre en règle', membre_en_regle(1)::text, 'true');
-- la valeur nominale figée à la souscription ne bouge plus si le paramètre change
UPDATE parametre SET valeur = '10000' WHERE cle = 'part_valeur_nominale';
SELECT souscrire_parts(1, 1, current_date, 1);
SELECT t.eq('C ancienne souscription conserve sa valeur', capital_souscrit::text, '25000') FROM v_membre WHERE client_id = 1;
UPDATE parametre SET valeur = '3' WHERE cle = 'parts_minimum';
SELECT t.eq('C minimum relevé : 4 parts suffisent', membre_en_regle(1)::text, 'true');
UPDATE parametre SET valeur = '5' WHERE cle = 'parts_minimum';
SELECT t.eq('C minimum relevé à 5 : plus en règle', membre_en_regle(1)::text, 'false');
UPDATE adhesion SET statut = 'radiee' WHERE client_id = 1;
SELECT t.refuse('D adhésion radiée : pas de nouvelles parts', 'SELECT mf.souscrire_parts(1, 1, current_date, 1)');
