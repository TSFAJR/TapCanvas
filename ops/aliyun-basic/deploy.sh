#!/usr/bin/env bash
set -euo pipefail
umask 077
[[ $# == 1 ]] || { echo 'Usage: deploy.sh /absolute/path/images.env' >&2; exit 1; }
manifest=$(realpath "$1")
repo=/srv/tap-canvas
root=/data/tap-canvas
mkdir -p "$root/releases" "$root/backups"
exec 8>"$root/operation.lock"
flock -n 8 || { echo 'Another deployment/backup is active' >&2; exit 1; }
export TAP_OPERATION_LOCK_HELD=1
sha=$(python3 - "$manifest" <<'PY'
import pathlib,re,sys
rows=dict(line.split('=',1) for line in pathlib.Path(sys.argv[1]).read_text().splitlines() if line.strip())
keys={'TAPCANVAS_API_IMAGE','TAPCANVAS_AGENTS_BRIDGE_IMAGE','NEW_API_IMAGE','TAPCANVAS_WEB_IMAGE','SOURCE_COMMIT'}
assert set(rows)==keys,'Unexpected manifest fields'
assert re.fullmatch('[0-9a-f]{40}',rows['SOURCE_COMMIT']),'A full source SHA is required'
for k,v in rows.items():
    if k!='SOURCE_COMMIT': assert re.fullmatch(r'ghcr\.io/tsfajr/tap-canvas-(api|agents-bridge|new-api|web)@sha256:[0-9a-f]{64}',v),'Digest-pinned owned image required'
print(rows['SOURCE_COMMIT'])
PY
)
git -C "$repo" cat-file -e "$sha^{commit}"
release="$root/releases/$(date -u +%Y%m%dT%H%M%SZ)-${sha:0:12}"
mkdir "$release"
cp "$manifest" "$release/images.env"
git -C "$repo" worktree add --detach "$release/source" "$sha"
schema=$(git -C "$repo" ls-tree -r "$sha" -- apps/hono-api/prisma apps/hono-api/schema.sql apps/hono-api/scripts/seed-postgres-patches.mjs apps/hono-api/scripts/migrate-deploy.mjs apps/hono-api/scripts/baseline-repair-sql.mjs apps/new-api/model apps/new-api/patches | sha256sum | cut -d' ' -f1)
python3 - "$release/version.json" "$sha" "$schema" <<'PY'
import json,sys,datetime
json.dump({'commit':sys.argv[2],'schemaFingerprint':sys.argv[3],'createdAt':datetime.datetime.now(datetime.timezone.utc).isoformat(),'status':'prepared'},open(sys.argv[1],'w'),indent=2)
PY
previous=$(readlink -f "$root/current" || true)
if [[ -n "$previous" && -f "$previous/images.env" ]]; then
  TAP_RELEASE="$previous" bash "$previous/source/ops/aliyun-basic/backup.sh"
fi
export TAP_RELEASE="$release"
source "$release/source/ops/aliyun-basic/common.sh"
dc config --quiet
dc pull --policy missing "${tap_runtime[@]}" new-api-db-init new-api-schema-init new-api-patch api-init new-api-channel-audit
if [[ -n "$previous" && -f "$previous/images.env" ]]; then dc stop -t 45 "${tap_writers[@]}"; fi
# On migration failure, leave the frontend stopped and preserve both data and logs.
failure() {
  dc stop web >/dev/null 2>&1 || true
  echo "Deployment failed; data preserved. Inspect $release and restore the pre-migration backup if required." >&2
}
trap failure ERR
dc up -d --wait --wait-timeout 120 postgres redis
printf '%s\n' "$schema" >"$root/database-schema-fingerprint"
for step in new-api-db-init new-api-schema-init new-api-patch api-init new-api-channel-audit; do
  dc up --no-deps --force-recreate --abort-on-container-exit --exit-code-from "$step" "$step" >"$release/$step.log" 2>&1
done
dc up -d --no-deps --wait --wait-timeout 180 new-api
dc up -d --no-deps --wait --wait-timeout 180 agents-bridge agents-bridge-lb
dc up -d --no-deps --wait --wait-timeout 180 api
dc up -d --no-deps --wait --wait-timeout 120 web
bash "$release/source/ops/aliyun-basic/health.sh"
dc exec -T postgres sh -ec 'psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -v ON_ERROR_STOP=1 -Atc "SELECT migration_name, checksum, finished_at FROM _prisma_migrations ORDER BY started_at"' >"$release/migrations.tsv"
docker inspect --format '{{.Name}} {{.Config.Image}} {{.Image}}' $(dc ps -q) >"$release/running-images.txt"
python3 - "$release/version.json" <<'PY'
import json,sys
p=sys.argv[1];d=json.load(open(p));d['status']='healthy';json.dump(d,open(p,'w'),indent=2)
PY
if [[ -n "$previous" && -f "$previous/images.env" ]]; then
  ln -s "$previous" "$root/previous.next"
  mv -Tf "$root/previous.next" "$root/previous"
fi
ln -s "$release" "$root/current.next"
mv -Tf "$root/current.next" "$root/current"
trap - ERR
echo "Released $sha at $release"
