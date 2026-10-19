#!/usr/bin/env bash
# Pour chaque fichier de test : recrée une base vierge, charge les modules dans l'ordre, puis exécute le test.
# Usage : schema/tools/run_tests.sh [motif]   (ex. 01 ; sans motif : tous les tests)
# Sortie : une ligne par assertion (OK ...) ; en cas d'écart la ligne ECHEC / ERROR s'affiche et le code retour est 1.
set -uo pipefail
cd "$(dirname "$0")/.."
C=${SFD_CONTAINER:-sfd-pg}; DB=sfd_test; rc=0
psqlc() { docker exec -i "$C" psql -U postgres -v ON_ERROR_STOP=1 -q "$@"; }
for t in tests/test_${1:-}*.sql; do
  [ -e "$t" ] || { echo "aucun test pour le motif '${1:-}'"; exit 1; }
  psqlc -d postgres -c "DROP DATABASE IF EXISTS $DB WITH (FORCE)" -c "CREATE DATABASE $DB" >/dev/null 2>&1
  for f in 0[0-5]_*.sql 07_*.sql 08_*.sql 09_*.sql [123][0-9]_*.sql; do
    [ -e "$f" ] || continue
    echo "== charge $f"
    psqlc -d $DB < "$f" >/dev/null || { echo "ECHEC chargement $f"; rc=1; }
  done
  psqlc -d $DB < tests/_helpers.sql >/dev/null
  echo "== test $t"
  out=$(psqlc -d $DB < "$t" 2>&1)
  echo "$out" | grep -E "ECHEC|ERROR|ERREUR|NOTICE" | sed -e 's/^psql:[^ ]* //' -e 's/^NOTICE:  //'
  echo "$out" | grep -qE "ECHEC|ERROR" && rc=1
done
exit $rc
