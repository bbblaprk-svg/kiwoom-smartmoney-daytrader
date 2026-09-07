#!/usr/bin/env bash
set -euo pipefail
BASE=/opt/pulse-edge
SRC="$BASE/PULSE_EDGE_CORE_2_1_3_UI_2_1_9_PREOPEN_VISIBLE_SOURCE.tar.gz"
DF="$BASE/Dockerfile"
BUILD=/tmp/pulse-edge-ui-2.1.9-preopen-visible-build
IMG=pulse-edge:core-2.1.3-runtime-safety-2.1.8-ui-2.1.9-preopen-visible
CANARY=pulse-edge-canary-ui-2.1.9-preopen-visible
LIVE=pulse-edge-live-ui-2.1.9-preopen-visible
NET=kiwoom-net
PUB=https://3-38-25-20.nip.io
MODE=${1:---canary}

build_image(){
  rm -rf "$BUILD" && mkdir -p "$BUILD"
  tar -xzf "$SRC" -C "$BUILD"
  cp "$DF" "$BUILD/Dockerfile"
  echo '[1] isolated UI build; existing containers/images untouched'
  docker build -t "$IMG" "$BUILD"
}

canary_only(){
  echo '[2] start FEED-OFF UI canary (no OAuth / no Kiwoom WS)'
  docker rm -f "$CANARY" >/dev/null 2>&1 || true
  docker run -d --name "$CANARY" --restart unless-stopped \
    --env-file "$BASE/.env" -e PULSE_FEED_ENABLED=false \
    -v "$BASE/data:/app/data:ro" -p 127.0.0.1:18019:8000 "$IMG" >/dev/null
  for i in $(seq 1 40); do
    curl -fsS --max-time 3 http://127.0.0.1:18019/health >/tmp/p219-health.json 2>/dev/null && break
    sleep 1
  done
  curl -fsS --max-time 5 http://127.0.0.1:18019/health >/tmp/p219-health.json
  python3 - <<'PY'
import json
j=json.load(open('/tmp/p219-health.json'))
assert j.get('runtime_safety_release') == '2.1.8_RUNTIME_SAFETY', j
assert j.get('feed_enabled') is False, j
print('CANARY_CORE_CONTRACT_PASS runtime_safety=2.1.8 feed_enabled=false')
PY
  curl -fsS --max-time 5 http://127.0.0.1:18019/ >/tmp/p219-page.html
  curl -fsS --max-time 5 http://127.0.0.1:18019/assets/pulse.js >/tmp/p219-pulse.js
  grep -q 'PREOPEN VISIBLE 2.1.9' /tmp/p219-page.html
  grep -q 'preopenVisibleSection' /tmp/p219-page.html
  grep -q '/api/smart-money/top?limit=10' /tmp/p219-pulse.js
  echo '[3] PREOPEN VISIBLE UI contract PASS'
  for i in $(seq 1 24); do curl -fsS --max-time 3 http://127.0.0.1:18019/health >/dev/null; sleep 5; done
  echo 'CANARY_120S_PASS'
  echo 'CANARY_FEED=OFF / NO_TOKEN_REQUEST / NO_ALIAS_SWITCH / NO_CADDY_EDIT'
}

find_alias_holder(){
  for c in $(docker ps --format '{{.Names}}'); do
    if docker inspect "$c" --format '{{json .NetworkSettings.Networks}}' 2>/dev/null | grep -q '"Aliases":\[[^]]*"pulse-edge"'; then echo "$c"; return 0; fi
  done
  return 1
}

rollback_live(){
  local old="$1"
  docker stop -t 3 "$LIVE" >/dev/null 2>&1 || docker kill "$LIVE" >/dev/null 2>&1 || true
  docker network disconnect "$NET" "$LIVE" >/dev/null 2>&1 || true
  if [ -n "$old" ]; then
    docker start "$old" >/dev/null 2>&1 || true
    docker network disconnect "$NET" "$old" >/dev/null 2>&1 || true
    docker network connect --alias pulse-edge "$NET" "$old" >/dev/null 2>&1 || true
  fi
  docker restart kiwoom-caddy >/dev/null 2>&1 || true
  echo 'ROLLBACK_COMPLETE'
}

cutover_live(){
  curl -fsS --max-time 5 http://127.0.0.1:18019/health >/dev/null
  OLD=$(find_alias_holder || true)
  [ -n "$OLD" ] || { echo 'ERROR: no active pulse-edge alias holder'; exit 2; }
  echo "CURRENT_ACTIVE=$OLD"
  echo '[4] stop current feed-on target before new feed-on UI runtime'
  docker stop -t 5 "$OLD" >/dev/null 2>&1 || docker kill "$OLD" >/dev/null 2>&1 || true
  docker rm -f "$LIVE" >/dev/null 2>&1 || true
  docker run -d --name "$LIVE" --restart unless-stopped --env-file "$BASE/.env" \
    -v "$BASE/data:/app/data" -p 127.0.0.1:18029:8000 "$IMG" >/dev/null
  docker network connect --alias pulse-edge "$NET" "$LIVE" >/dev/null 2>&1 || true
  docker restart kiwoom-caddy >/dev/null
  for i in $(seq 1 40); do curl -fsS --max-time 3 http://127.0.0.1:18029/health >/dev/null 2>&1 && break; sleep 1; done
  curl -fsS --max-time 5 http://127.0.0.1:18029/health >/dev/null || { rollback_live "$OLD"; exit 3; }
  echo '[5] 10-minute live stability validation'
  FAIL=0
  for i in $(seq 1 20); do
    BAD=0
    curl -fsS --max-time 5 http://127.0.0.1:18029/health >/tmp/p219-live-health.json || BAD=1
    curl -k -fsS --max-time 7 "$PUB/health" >/dev/null || BAD=1
    curl -k -fsS --max-time 8 "$PUB/" >/dev/null || BAD=1
    STAGE=$(python3 - <<'PY'
import json
try: print(json.load(open('/tmp/p219-live-health.json')).get('runtime_load_stage') or '')
except Exception: print('')
PY
)
    CPU=$(docker stats --no-stream --format '{{.CPUPerc}}' "$LIVE" 2>/dev/null || echo '?')
    MEM=$(docker stats --no-stream --format '{{.MemPerc}}' "$LIVE" 2>/dev/null || echo '?')
    echo "CHECK=$i/20 load=$STAGE cpu=$CPU mem=$MEM"
    [ "$STAGE" = CRITICAL ] && BAD=1
    if [ "$BAD" -ne 0 ]; then FAIL=$((FAIL+1)); else FAIL=0; fi
    [ "$FAIL" -lt 3 ] || { rollback_live "$OLD"; exit 4; }
    sleep 30
  done
  echo 'LIVE_10MIN_PASS'
  echo "ACTIVE=$LIVE"
  echo "PREVIOUS_PRESERVED_STOPPED=$OLD"
  echo 'UI_2.1.9_PREOPEN_VISIBLE / CORE_LOGIC_UNCHANGED'
}

build_image
case "$MODE" in
  --canary) canary_only ;;
  --cutover) canary_only; cutover_live ;;
  *) echo "usage: $0 [--canary|--cutover]"; exit 64 ;;
esac
