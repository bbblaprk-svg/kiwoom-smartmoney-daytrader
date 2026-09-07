#!/usr/bin/env bash
set -euo pipefail
BASE=/opt/pulse-edge
SRC="$BASE/PULSE_EDGE_CORE_2_1_3_UI_2_1_9_4_POLL_FIX_SOURCE.tar.gz"
DF="$BASE/Dockerfile"
BUILD=/tmp/pulse-edge-ui-2.1.9.4-poll-fix-build
IMG=pulse-edge:core-2.1.3-runtime-safety-2.1.8-ui-2.1.9.4-poll-fix
CANARY=pulse-edge-canary-ui-2.1.9.4-poll-fix
LIVE=pulse-edge-live-ui-2.1.9.4-poll-fix
NET=kiwoom-net
PUB=https://3-38-25-20.nip.io
MODE=${1:---canary}

build_image(){
  rm -rf "$BUILD" && mkdir -p "$BUILD"
  tar -xzf "$SRC" -C "$BUILD"
  cp "$DF" "$BUILD/Dockerfile"
  echo '[1] isolated UI-only build; core/data logic untouched'
  docker build -t "$IMG" "$BUILD"
}

canary_only(){
  echo '[2] start FEED-OFF canary'
  docker rm -f "$CANARY" >/dev/null 2>&1 || true
  docker run -d --name "$CANARY" --restart unless-stopped \
    --env-file "$BASE/.env" -e PULSE_FEED_ENABLED=false \
    -v "$BASE/data:/app/data:ro" -p 127.0.0.1:180194:8000 "$IMG" >/dev/null
  for i in $(seq 1 40); do
    curl -fsS --max-time 3 http://127.0.0.1:180194/health >/tmp/p2194-health.json 2>/dev/null && break
    sleep 1
  done
  curl -fsS --max-time 5 http://127.0.0.1:180194/health >/tmp/p2194-health.json
  curl -fsS --max-time 5 http://127.0.0.1:180194/assets/pulse.js >/tmp/p2194-pulse.js
  grep -q '/api/smart-money/top?limit=10' /tmp/p2194-pulse.js
  if grep -q '/api/history/candidates' /tmp/p2194-pulse.js; then
    echo 'FAIL: obsolete candidate-history poll still present'; exit 3
  fi
  echo '[3] POLL_FIX_CONTRACT_PASS obsolete /api/history/candidates removed'
  for i in $(seq 1 24); do curl -fsS --max-time 3 http://127.0.0.1:180194/health >/dev/null; sleep 5; done
  echo 'CANARY_120S_PASS'
  echo 'CANARY_FEED=OFF / NO_TOKEN_REQUEST / NO_ALIAS_SWITCH / NO_CADDY_EDIT'
}

find_alias_holder(){
  for c in $(docker ps --format '{{.Names}}'); do
    if docker inspect "$c" --format '{{json .NetworkSettings.Networks}}' 2>/dev/null | grep -q '"Aliases":\[[^]]*"pulse-edge"'; then echo "$c"; return 0; fi
  done
  return 1
}

cutover_live(){
  OLD=$(find_alias_holder || true)
  [ -n "$OLD" ] || { echo 'ERROR: no active pulse-edge alias holder'; exit 4; }
  echo "CURRENT_ACTIVE=$OLD"
  docker stop -t 5 "$OLD" >/dev/null 2>&1 || docker kill "$OLD" >/dev/null 2>&1 || true
  docker rm -f "$LIVE" >/dev/null 2>&1 || true
  docker run -d --name "$LIVE" --restart unless-stopped --env-file "$BASE/.env" \
    -v "$BASE/data:/app/data" -p 127.0.0.1:180294:8000 "$IMG" >/dev/null
  docker network connect --alias pulse-edge "$NET" "$LIVE" >/dev/null 2>&1 || true
  docker restart kiwoom-caddy >/dev/null
  for i in $(seq 1 40); do curl -fsS --max-time 3 http://127.0.0.1:180294/health >/dev/null 2>&1 && break; sleep 1; done
  curl -fsS --max-time 5 http://127.0.0.1:180294/health >/dev/null
  echo '[4] 10-minute live stability validation'
  FAIL=0
  for i in $(seq 1 20); do
    BAD=0
    curl -fsS --max-time 5 http://127.0.0.1:180294/health >/tmp/p2194-live-health.json || BAD=1
    curl -k -fsS --max-time 7 "$PUB/health" >/dev/null || BAD=1
    curl -k -fsS --max-time 8 "$PUB/" >/dev/null || BAD=1
    CPU=$(docker stats --no-stream --format '{{.CPUPerc}}' "$LIVE" 2>/dev/null || echo '?')
    MEM=$(docker stats --no-stream --format '{{.MemPerc}}' "$LIVE" 2>/dev/null || echo '?')
    STAGE=$(python3 - <<'PY'
import json
try: print(json.load(open('/tmp/p2194-live-health.json')).get('runtime_load_stage') or '')
except Exception: print('')
PY
)
    echo "CHECK=$i/20 load=$STAGE cpu=$CPU mem=$MEM"
    [ "$STAGE" = CRITICAL ] && BAD=1
    if [ "$BAD" -ne 0 ]; then FAIL=$((FAIL+1)); else FAIL=0; fi
    if [ "$FAIL" -ge 3 ]; then
      echo 'LIVE_VALIDATION_FAIL; preserving failed live and restoring previous alias target'
      docker stop -t 3 "$LIVE" >/dev/null 2>&1 || true
      docker network disconnect "$NET" "$LIVE" >/dev/null 2>&1 || true
      docker start "$OLD" >/dev/null 2>&1 || true
      docker network disconnect "$NET" "$OLD" >/dev/null 2>&1 || true
      docker network connect --alias pulse-edge "$NET" "$OLD" >/dev/null 2>&1 || true
      docker restart kiwoom-caddy >/dev/null 2>&1 || true
      exit 5
    fi
    sleep 30
  done
  echo 'LIVE_10MIN_PASS'
  echo "ACTIVE=$LIVE"
  echo "PREVIOUS_PRESERVED_STOPPED=$OLD"
  echo 'UI_2.1.9.4_POLL_FIX / CORE_DATA_LOGIC_UNCHANGED'
}

build_image
case "$MODE" in
  --canary) canary_only ;;
  --cutover) canary_only; cutover_live ;;
  *) echo "usage: $0 [--canary|--cutover]"; exit 64 ;;
esac
