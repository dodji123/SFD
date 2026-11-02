SET search_path = mf, public;

-- Module sous test : 81_date_operation.sql (date d'opération unique, ouverte avant toute opération)

-- ===== A. Avant toute ouverture : aucune opération possible =====
SELECT t.refuse('A pas d''opération sans date ouverte', 'SELECT mf.date_operation_courante()');

-- ===== B. Ouverture =====
SELECT t.refuse('B date future refusée', 'SELECT mf.ouvrir_date_operation(current_date + 1)');
SELECT ouvrir_date_operation(current_date - 2);
SELECT t.eq('B date d''opération ouverte', date_operation_courante()::text, (current_date - 2)::text);
SELECT t.refuse('B deuxième ouverture pendant une journée ouverte', 'SELECT mf.ouvrir_date_operation(current_date - 1)');

-- ===== C. Clôture : valable pour tout le monde =====
SELECT cloturer_date_operation();
SELECT t.refuse('C plus de date ouverte après clôture', 'SELECT mf.date_operation_courante()');
SELECT t.refuse('C clôture sans journée ouverte', 'SELECT mf.cloturer_date_operation()');

-- ===== D. Une date qui existe ne peut pas être recréée =====
SELECT t.refuse('D date déjà existante refusée', 'SELECT mf.ouvrir_date_operation(current_date - 2)');
SELECT t.refuse('D date antérieure refusée', 'SELECT mf.ouvrir_date_operation(current_date - 3)');

-- ===== E. La suite : une date postérieure s'ouvre =====
SELECT ouvrir_date_operation(current_date - 1);
SELECT t.eq('E date suivante ouverte', date_operation_courante()::text, (current_date - 1)::text);
SELECT cloturer_date_operation();
SELECT ouvrir_date_operation(current_date);
SELECT t.eq('E date du jour ouverte', date_operation_courante()::text, current_date::text);
SELECT t.eq('E trois dates enregistrées', count(*)::text, '3') FROM date_operation;
