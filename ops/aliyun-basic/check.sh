#!/usr/bin/env bash
set -euo pipefail
for file in ops/aliyun-basic/*.sh; do bash -n "$file"; done
# Render with throwaway values only. Never print the production configuration.
tmp=$(mktemp -d)
trap 'rm -f "$tmp/runtime.env" "$tmp/config.json"; rmdir "$tmp"' EXIT
cat >"$tmp/runtime.env" <<'EOF'
POSTGRES_PASSWORD=validation-only
JWT_SECRET=validation-only
INTERNAL_WORKER_TOKEN=validation-only
AGENTS_BRIDGE_TOKEN=validation-only
NEW_API_INTERNAL_TOKEN=validation-only
NEW_API_SESSION_SECRET=validation-only
NEW_API_CRYPTO_SECRET=validation-only
NEW_API_USD_EXCHANGE_RATE=7.3
NEW_API_PUBLIC_BASE_URL=http://127.0.0.1:4455
EOF
TAPCANVAS_ENV_FILE="$tmp/runtime.env" docker compose --env-file "$tmp/runtime.env" \
  -f docker-compose.prod.yml -f ops/aliyun-basic/compose.basic.yml config --format json >"$tmp/config.json"
python3 - "$tmp/config.json" <<'PY'
import json,sys
c=json.load(open(sys.argv[1]))
s=c['services']
assert set(s)=={'postgres','redis','new-api-db-init','new-api-schema-init','new-api-patch','api-init','new-api-channel-audit','new-api','agents-bridge','agents-bridge-lb','api','web'},set(s)
assert s['agents-bridge']['deploy']['replicas']==1
assert s['api']['environment']['NODE_OPTIONS']=='--max-old-space-size=512'
for name,svc in s.items():
    for port in svc.get('ports',[]):
        assert name=='web' or port.get('host_ip')=='127.0.0.1',(name,port)
assert sum(int(s[n]['deploy']['resources']['limits']['memory']) for n in ['postgres','redis','api','new-api','agents-bridge','agents-bridge-lb','web']) <= 2500*1024*1024
assert s['new-api']['networks']=={'default':None} or set(s['new-api']['networks'])=={'default'}
assert all(v['source'] != '.' for v in s['api']['volumes'])
print('Basic topology, exposure, memory, and shell checks passed')
PY
