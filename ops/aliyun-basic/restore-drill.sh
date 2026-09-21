#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/common.sh"
[[ $# == 1 ]] || { echo 'Usage: restore-drill.sh /absolute/backup/directory' >&2; exit 1; }
backup=$(realpath "$1")
[[ "$backup" == "$TAP_ROOT/backups/"* && -f "$backup/COMPLETE" ]] || { echo 'A completed TapCanvas backup is required' >&2; exit 1; }
exec 9>"$TAP_ROOT/operation.lock"
flock -n 9 || { echo 'Another operation is active' >&2; exit 1; }
(cd "$backup" && sha256sum --check SHA256SUMS)
prefix="tapcanvas_restore_$(date -u +%Y%m%d%H%M%S)"
report="$TAP_ROOT/releases/restore-drill-$prefix"
mkdir "$report"
for kind in canvas gateway; do
  db="${prefix}_${kind}"
  dc exec -T postgres sh -ec 'createdb -U "$POSTGRES_USER" "$1"' sh "$db"
  dc exec -T postgres sh -ec 'pg_restore -U "$POSTGRES_USER" -d "$1" --no-owner --no-acl --exit-on-error' sh "$db" <"$backup/$kind.dump"
  dc exec -T postgres sh -ec 'psql -U "$POSTGRES_USER" -d "$1" -v ON_ERROR_STOP=1 -At' sh "$db" >"$report/$kind-counts.tsv" <<'SQL'
SELECT format('SELECT %L, count(*) FROM %I.%I;', schemaname || '.' || tablename, schemaname, tablename)
FROM pg_tables WHERE schemaname = 'public' ORDER BY tablename
\gexec
SQL
  dc exec -T postgres sh -ec 'pg_dump -U "$POSTGRES_USER" -d "$1" --schema-only --no-owner --no-acl' sh "$db" >"$report/$kind-schema.sql"
  printf '%s\n' "$db" >>"$report/databases.txt"
done
tar -tzf "$backup/files.tar.gz" >"$report/files.txt"
printf '%s\n' "$backup" >"$report/backup.txt"
touch "$report/COMPLETE"
echo "Restore verified in isolated databases; production unchanged. Report: $report"
echo 'Isolated databases are retained for inspection; remove them explicitly after review.'
