#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/common.sh"
mode=$(python3 - "$TAP_ENV" <<'PY'
import pathlib,sys
rows=dict(line.split('=',1) for line in pathlib.Path(sys.argv[1]).read_text().splitlines() if line.strip() and not line.lstrip().startswith('#'))
mode=rows.get('TAPCANVAS_BASIC_NO_MODELS','1')
assert mode in ('0','1'),'TAPCANVAS_BASIC_NO_MODELS must be 0 or 1'
print(mode)
PY
)
[[ "$mode" == 1 ]] || { echo 'Basic no-model policy explicitly disabled'; exit 0; }
# Official seeds contain a preconfigured channel credential. A basic deployment
# must never activate it. deploy.sh already created the pre-migration backup.
dc exec -T postgres sh -ec 'psql -U "$POSTGRES_USER" -d tapcanvas_new_api -v ON_ERROR_STOP=1' <<'SQL'
BEGIN;
UPDATE channels SET key = '', status = 2;
UPDATE abilities SET enabled = false;
DO $$ BEGIN
  IF EXISTS (SELECT 1 FROM channels WHERE status = 1 OR length(btrim(key)) > 0)
     OR EXISTS (SELECT 1 FROM abilities WHERE enabled) THEN
    RAISE EXCEPTION 'Basic deployment still has configured model routes';
  END IF;
END $$;
COMMIT;
SQL
echo 'Basic no-model policy applied: no channel credentials or enabled routes'
