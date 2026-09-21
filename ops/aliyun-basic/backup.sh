#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/common.sh"
if [[ ${TAP_OPERATION_LOCK_HELD:-0} != 1 ]]; then
  exec 9>"$TAP_ROOT/operation.lock"
  flock -n 9 || { echo 'Another operation is active' >&2; exit 1; }
fi
backup="$TAP_ROOT/backups/$(date -u +%Y%m%dT%H%M%SZ)-$(basename "$TAP_RELEASE")"
mkdir -p "$backup"
restore_services() { dc up -d --no-deps redis "${tap_writers[@]}" >/dev/null; }
trap restore_services EXIT
dc stop -t 45 "${tap_writers[@]}"
dc exec -T postgres sh -ec 'pg_dump -U "$POSTGRES_USER" -d "$POSTGRES_DB" -Fc' >"$backup/canvas.dump"
dc exec -T postgres sh -ec 'pg_dump -U "$POSTGRES_USER" -d tapcanvas_new_api -Fc' >"$backup/gateway.dump"
dc exec -T redis redis-cli SAVE | grep -qx OK
dc stop -t 30 redis
tar -C "$TAP_ROOT" -czf "$backup/files.tar.gz" project-data public-assets agents-memory agents-runtime new-api-data redis
tar -C /etc/tap-canvas -czf "$backup/config.tar.gz" runtime.env
cp "$TAP_RELEASE/images.env" "$TAP_RELEASE/version.json" "$backup/"
cp "$TAP_ROOT/database-schema-fingerprint" "$backup/"
cp "$TAP_ROOT/redis/dump.rdb" "$backup/redis.rdb"
(cd "$backup" && sha256sum canvas.dump gateway.dump files.tar.gz config.tar.gz images.env version.json database-schema-fingerprint redis.rdb > SHA256SUMS)
touch "$backup/COMPLETE"
restore_services
trap - EXIT
python3 - "$TAP_ROOT/backups" <<'PY'
import pathlib,shutil,sys
root=pathlib.Path(sys.argv[1]).resolve()
items=sorted((p for p in root.iterdir() if p.is_dir() and (p/'COMPLETE').exists()), reverse=True)
for p in items[7:]:
    if p.is_symlink() or p.resolve().parent != root: raise RuntimeError('Unsafe backup path')
    shutil.rmtree(p)
PY
echo "$backup"
