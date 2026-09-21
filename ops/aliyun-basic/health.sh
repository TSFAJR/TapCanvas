#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/common.sh"
for service in "${tap_runtime[@]}"; do
  cid=$(dc ps -q "$service")
  [[ -n "$cid" ]] || { echo "$service is absent" >&2; exit 1; }
  state=$(docker inspect --format '{{.State.Status}} {{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}} {{.State.OOMKilled}}' "$cid")
  [[ "$state" == 'running healthy false' || ( "$service" == redis && "$state" == 'running none false' ) ]] || { echo "$service: $state" >&2; exit 1; }
done
dc exec -T postgres sh -ec 'psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -v ON_ERROR_STOP=1 -Atc "SELECT 1"' | grep -qx 1
dc exec -T redis redis-cli PING | grep -qx PONG
curl --fail --silent --show-error --max-time 10 http://127.0.0.1/api/health/version >/dev/null
curl --fail --silent --show-error --max-time 10 http://127.0.0.1/ >/dev/null
echo 'TapCanvas basic services healthy'
