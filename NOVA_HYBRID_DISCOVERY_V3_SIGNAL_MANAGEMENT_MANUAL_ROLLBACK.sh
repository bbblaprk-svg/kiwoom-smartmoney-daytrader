#!/usr/bin/env bash
set -Eeuo pipefail
CURRENT_CONTAINER="${NOVA_CURRENT_CONTAINER:-quant-nova}"
BACKUP="${1:-}"
if [[ -z "$BACKUP" ]]; then
  BACKUP="$(docker ps -a --format '{{.Names}}' | grep '^quant-nova-backup-hybrid-v3-signal5d-' | sort -r | head -1 || true)"
fi
[[ -n "$BACKUP" ]] || { echo 'ERROR: no HYBRID V3 backup container found'; exit 1; }
docker container inspect "$BACKUP" >/dev/null 2>&1 || { echo "ERROR: backup not found: $BACKUP"; exit 1; }
if docker container inspect "$CURRENT_CONTAINER" >/dev/null 2>&1; then docker rm -f "$CURRENT_CONTAINER" >/dev/null; fi
docker rename "$BACKUP" "$CURRENT_CONTAINER"
docker start "$CURRENT_CONTAINER" >/dev/null
for _ in $(seq 1 30); do
  if docker exec "$CURRENT_CONTAINER" python - <<'PY' >/dev/null 2>&1
import json,urllib.request,sys
try:
 j=json.load(urllib.request.urlopen('http://127.0.0.1:8000/api/livez',timeout=2));sys.exit(0 if j.get('ok') else 1)
except Exception:sys.exit(1)
PY
  then echo "ROLLBACK=SUCCESS CURRENT=$CURRENT_CONTAINER"; exit 0; fi
  sleep 2
done
echo 'ROLLBACK=STARTED_BUT_HEALTH_NOT_READY'; exit 2
