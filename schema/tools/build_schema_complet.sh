#!/usr/bin/env bash
# Concatène les modules dans l'ordre de chargement : schema/mf_schema_complet.sql
# Ordre : 00 à 05 (dont 05_plan_comptable_data), 07, 08, 09, 10.  (Le 06 du brief est devenu 09.)
set -euo pipefail
cd "$(dirname "$0")/.."
OUT=mf_schema_complet.sql
{
  echo "-- Schéma complet mf : généré par tools/build_schema_complet.sh (ne pas éditer : modifier les modules)."
  echo "-- Chargement : psql -v ON_ERROR_STOP=1 -f mf_schema_complet.sql   (PostgreSQL 14+, extension btree_gist)"
  for f in 0[0-5]_*.sql 07_*.sql 08_*.sql 09_*.sql [12][0-9]_*.sql; do
    [ -e "$f" ] || continue
    printf '\n-- =====================================================================\n-- MODULE %s\n-- =====================================================================\n' "$f"
    cat "$f"
  done
} > "$OUT"
echo "$OUT : $(wc -l < "$OUT") lignes"
