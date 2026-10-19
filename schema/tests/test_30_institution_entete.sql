SET search_path = mf, public;

-- Module sous test : 30_institution_entete.sql (fiche de l'institution, coordonnées des agences)
INSERT INTO agence(code,libelle) VALUES ('LOM','Lomé Centre');

SELECT t.eq('A la fiche existe dès le départ', count(*)::text || '/' || raison_sociale, '1/Institution de microfinance') FROM institution GROUP BY raison_sociale;
SELECT t.refuse('A une seule fiche', 'INSERT INTO mf.institution(id, raison_sociale) VALUES (2, ''Autre'')');
SELECT t.refuse('A raison sociale obligatoire', 'UPDATE mf.institution SET raison_sociale = NULL');
UPDATE institution SET raison_sociale = 'Caisse de Test', sigle = 'CDT', adresse = '12 rue du Commerce', telephone = '+228 22 00 00 00' WHERE id = 1;
SELECT t.eq('A fiche modifiée', raison_sociale || '/' || sigle || '/' || telephone, 'Caisse de Test/CDT/+228 22 00 00 00') FROM institution;

SELECT t.refuse('B logo : pas de HTML', 'UPDATE mf.institution SET logo = ''data:text/html;base64,PHNjcmlwdD4=''');
SELECT t.refuse('B logo : trop lourd', 'UPDATE mf.institution SET logo = ''data:image/png;base64,'' || repeat(''A'', 400000)');
UPDATE institution SET logo = 'data:image/png;base64,iVBORw0KGgo=' WHERE id = 1;
SELECT t.eq('B logo image accepté', (logo IS NOT NULL)::text, 'true') FROM institution;

UPDATE agence SET adresse = 'Boulevard du Mono', ville = 'Lomé', telephone = '+228 90 00 00 01', email = 'lome@cdt.tg' WHERE code = 'LOM';
SELECT t.eq('C coordonnées de l''agence', adresse || '/' || ville || '/' || telephone || '/' || email, 'Boulevard du Mono/Lomé/+228 90 00 00 01/lome@cdt.tg') FROM agence WHERE code = 'LOM';
