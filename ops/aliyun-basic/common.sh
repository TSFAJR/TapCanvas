#!/usr/bin/env bash
set -euo pipefail
umask 077
TAP_ROOT=/data/tap-canvas
TAP_ENV=/etc/tap-canvas/runtime.env
TAP_RELEASE=${TAP_RELEASE:-$(readlink -f "$TAP_ROOT/current")}
[[ -n "$TAP_RELEASE" && "$TAP_RELEASE" == "$TAP_ROOT/releases/"* && -f "$TAP_RELEASE/images.env" ]] || { echo 'A valid TapCanvas release is required' >&2; exit 1; }
TAP_SOURCE="$TAP_RELEASE/source"
dc() {
  docker compose -p tapcanvas --project-directory "$TAP_SOURCE" \
    --env-file "$TAP_ENV" --env-file "$TAP_RELEASE/images.env" \
    -f "$TAP_SOURCE/docker-compose.prod.yml" \
    -f "$TAP_SOURCE/ops/aliyun-basic/compose.basic.yml" "$@"
}
tap_runtime=(postgres redis new-api agents-bridge agents-bridge-lb api web)
tap_writers=(web api agents-bridge-lb agents-bridge new-api)
