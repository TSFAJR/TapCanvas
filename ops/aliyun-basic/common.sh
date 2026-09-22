#!/usr/bin/env bash
set -euo pipefail
umask 077
TAP_ROOT=/data/tap-canvas
TAP_ENV=/etc/tap-canvas/runtime.env
tap_generation=$(python3 - "$TAP_ENV" <<'PY'
import pathlib,sys
rows=dict(line.split('=',1) for line in pathlib.Path(sys.argv[1]).read_text().splitlines() if line and not line.startswith('#') and '=' in line)
value=rows.get('TAPCANVAS_GENERATION_ENABLED','0')
assert value in ('0','1'),'TAPCANVAS_GENERATION_ENABLED must be 0 or 1'
print(value)
PY
)
tap_profiles=()
[[ "$tap_generation" != 1 ]] || tap_profiles=(--profile fullblast)
TAP_RELEASE=${TAP_RELEASE:-$(readlink -f "$TAP_ROOT/current")}
[[ -n "$TAP_RELEASE" && "$TAP_RELEASE" == "$TAP_ROOT/releases/"* && -f "$TAP_RELEASE/images.env" ]] || { echo 'A valid TapCanvas release is required' >&2; exit 1; }
TAP_SOURCE="$TAP_RELEASE/source"
dc() {
  docker compose -p tapcanvas --project-directory "$TAP_SOURCE" \
    --env-file "$TAP_ENV" --env-file "$TAP_RELEASE/images.env" \
    -f "$TAP_SOURCE/docker-compose.prod.yml" \
    -f "$TAP_SOURCE/ops/aliyun-basic/compose.basic.yml" "${tap_profiles[@]}" "$@"
}
tap_runtime=(postgres redis new-api agents-bridge agents-bridge-lb api web)
tap_writers=(web api agents-bridge-lb agents-bridge new-api)
tap_generation_workers=()
if [[ "$tap_generation" == 1 ]]; then
  tap_generation_workers=(credit-finalizer-worker async-image-worker)
  tap_runtime+=("${tap_generation_workers[@]}")
  tap_writers=("${tap_generation_workers[@]}" "${tap_writers[@]}")
fi
