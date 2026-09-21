#!/usr/bin/env bash
set -euo pipefail
root=/data/tap-canvas
exec 8>"$root/operation.lock"
flock -n 8 || { echo 'Another operation is active' >&2; exit 1; }
current=$(readlink -f "$root/current")
target=$(realpath "${1:-$root/previous}")
[[ "$target" == "$root/releases/"* && -f "$target/version.json" ]] || { echo 'Invalid rollback target' >&2; exit 1; }
python3 - "$root/database-schema-fingerprint" "$target/version.json" <<'PY'
import json,sys,pathlib
a=pathlib.Path(sys.argv[1]).read_text().strip();b=json.load(open(sys.argv[2]))
assert a==b['schemaFingerprint'],'Schema differs: preserve current data and restore a matching backup before rollback'
assert b['status']=='healthy','Target was not previously healthy'
PY
export TAP_RELEASE="$target"
source "$target/source/ops/aliyun-basic/common.sh"
dc stop -t 45 "${tap_writers[@]}"
dc up -d --no-deps --wait --wait-timeout 180 "${tap_runtime[@]}"
bash "$target/source/ops/aliyun-basic/health.sh"
ln -s "$target" "$root/current.next"
mv -Tf "$root/current.next" "$root/current"
ln -s "$current" "$root/previous.next"
mv -Tf "$root/previous.next" "$root/previous"
echo "Rolled back to $target"
