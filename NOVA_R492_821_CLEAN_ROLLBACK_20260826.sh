#!/usr/bin/env bash
set -Eeuo pipefail
umask 077
APP="quant-nova"
STAMP="$(date +%Y%m%d-%H%M%S)"
MARKER="/home/ubuntu/quant-nova/.r492-clean821-last"
FAILED="${APP}-failed-clean821-${STAMP}"

if docker info >/dev/null 2>&1; then DOCKER=(docker)
elif sudo -n docker info >/dev/null 2>&1; then DOCKER=(sudo docker)
else echo "FAIL: Docker access unavailable"; exit 2
fi
dc(){ "${DOCKER[@]}" "$@"; }

[ -f "$MARKER" ] || { echo "FAIL: rollback marker not found: $MARKER"; exit 10; }
# shellcheck disable=SC1090
source "$MARKER"

if dc inspect "$APP" >/dev/null 2>&1; then
  dc stop -t 15 "$APP" >/dev/null 2>&1 || true
  dc rename "$APP" "$FAILED"
fi

RESTORED=""
if [ -n "${BACKUP_CONTAINER:-}" ] && dc inspect "$BACKUP_CONTAINER" >/dev/null 2>&1; then
  dc rename "$BACKUP_CONTAINER" "$APP"
  dc start "$APP" >/dev/null
  RESTORED="$APP"
else
  IFS=',' read -r -a PREV <<< "${RUNNING_BEFORE:-}"
  for n in "${PREV[@]}"; do
    [ -n "$n" ] || continue
    dc inspect "$n" >/dev/null 2>&1 || continue
    dc start "$n" >/dev/null 2>&1 || true
    [ -z "$RESTORED" ] && RESTORED="$n"
  done
fi

[ -n "$RESTORED" ] || { echo "CRITICAL: no recorded pre-clean application container is available"; exit 12; }

# If canonical quant-nova was restored, verify its internal livez.
if [ "$RESTORED" = "$APP" ]; then
  GOOD=0
  for i in $(seq 1 40); do
    set +e
    OUT="$(dc exec "$APP" python -c 'import json,urllib.request,sys;j=json.load(urllib.request.urlopen("http://127.0.0.1:8000/api/livez",timeout=5));print(json.dumps(j,ensure_ascii=False));sys.exit(0 if j.get("ok") else 1)' 2>&1)"
    RC=$?
    set -e
    echo "$OUT"
    if [ "$RC" -eq 0 ]; then GOOD=1; break; fi
    sleep 3
  done
  [ "$GOOD" -eq 1 ] || { echo "CRITICAL: previous canonical container restored but livez failed; inspect $APP and $FAILED"; exit 20; }
fi

echo "RESULT=SUCCESS RESTORED=$RESTORED FAILED_CLEAN=$FAILED"
