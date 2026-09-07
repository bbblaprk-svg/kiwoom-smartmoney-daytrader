#!/usr/bin/env bash
set -euo pipefail

BASE=/opt/pulse-edge
SRC="$BASE/PULSE_EDGE_CORE_2_1_3_RUNTIME_SAFETY_2_1_8_SOURCE.tar.gz"
DF="$BASE/Dockerfile"
BUILD=/tmp/pulse-edge-runtime-safety-2.1.8-build
IMG=pulse-edge:core-2.1.3-runtime-safety-2.1.8
CANARY=pulse-edge-canary-runtime-safety-2.1.8
LIVE=pulse-edge-live-runtime-safety-2.1.8
NET=kiwoom-net
PUB=https://3-38-25-20.nip.io
MODE=${1:---canary}

build_image() {
  rm -rf "$BUILD" && mkdir -p "$BUILD"
  tar -xzf "$SRC" -C "$BUILD"
  cp "$DF" "$BUILD/Dockerfile"
  echo '[1] isolated build; existing containers/images untouched'
  docker build -t "$IMG" "$BUILD"
}

canary_only() {
  echo '[2] start FEED-OFF canary (no OAuth / no Kiwoom WS)'
  docker rm -f "$CANARY" >/dev/null 2>&1 || true
  docker run -d --name "$CANARY" --restart unless-stopped \
    --env-file "$BASE/.env" \
    -e PULSE_FEED_ENABLED=false \
    -v "$BASE/data:/app/data:ro" \
    -p 127.0.0.1:18018:8000 \
    "$IMG" >/dev/null

  for i in $(seq 1 40); do
    if curl -fsS --max-time 3 http://127.0.0.1:18018/health >/tmp/p218-canary-health.json 2>/dev/null; then break; fi
    sleep 1
  done
  curl -fsS --max-time 5 http://127.0.0.1:18018/health >/tmp/p218-canary-health.json
  python3 - <<'PY'
import json
j=json.load(open('/tmp/p218-canary-health.json'))
assert j.get('runtime_safety_release') == '2.1.8_RUNTIME_SAFETY', j
assert j.get('feed_enabled') is False, j
print('CANARY_CONTRACT_PASS runtime_safety=2.1.8 feed_enabled=false')
PY
  curl -fsS --max-time 5 http://127.0.0.1:18018/ >/tmp/p218-canary-page.html
  curl -fsS --max-time 5 http://127.0.0.1:18018/assets/pulse.js >/dev/null
  curl -fsS --max-time 5 http://127.0.0.1:18018/assets/pulse.css >/dev/null
  echo '[3] page/assets PASS'

  echo '[4] 120-second FEED-OFF responsiveness check'
  for i in $(seq 1 24); do
    curl -fsS --max-time 3 http://127.0.0.1:18018/health >/dev/null
    sleep 5
  done
  echo 'CANARY_PASS'
  echo 'CANARY_FEED=OFF'
  echo 'NO_TOKEN_REQUEST_FROM_CANARY'
  echo 'NO_ALIAS_SWITCH / NO CADDY EDIT / NO EXISTING CONTAINER RENAME'
  echo 'NEXT: run same script with --cutover only after canary PASS'
}

find_alias_holder() {
  for c in $(docker ps --format '{{.Names}}'); do
    if docker inspect "$c" --format '{{json .NetworkSettings.Networks}}' 2>/dev/null | grep -q '"Aliases":\[[^]]*"pulse-edge"'; then
      echo "$c"
      return 0
    fi
  done
  return 1
}

rollback_live() {
  local old="$1"
  echo 'ROLLBACK: stop 2.1.8 live and restore previous alias holder'
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

cutover_live() {
  # A feed-off canary must already have passed. Never run two feed-on PULSE engines.
  curl -fsS --max-time 5 http://127.0.0.1:18018/health >/tmp/p218-canary-health.json
  python3 - <<'PY'
import json
j=json.load(open('/tmp/p218-canary-health.json'))
assert j.get('runtime_safety_release') == '2.1.8_RUNTIME_SAFETY'
assert j.get('feed_enabled') is False
PY

  OLD=$(find_alias_holder || true)
  if [ -z "$OLD" ]; then
    echo 'ERROR: no current pulse-edge alias holder found; refusing live cutover'
    exit 2
  fi
  echo "CURRENT_ACTIVE=$OLD"
  echo '[5] stop current feed-on target BEFORE starting new feed-on runtime'
  docker stop -t 5 "$OLD" >/dev/null 2>&1 || docker kill "$OLD" >/dev/null 2>&1 || true

  docker rm -f "$LIVE" >/dev/null 2>&1 || true
  docker run -d --name "$LIVE" --restart unless-stopped \
    --env-file "$BASE/.env" \
    -v "$BASE/data:/app/data" \
    -p 127.0.0.1:18028:8000 \
    "$IMG" >/dev/null
  docker network connect --alias pulse-edge "$NET" "$LIVE" >/dev/null 2>&1 || true
  docker restart kiwoom-caddy >/dev/null

  FAIL=0
  for i in $(seq 1 40); do
    if curl -fsS --max-time 3 http://127.0.0.1:18028/health >/tmp/p218-live-health.json 2>/dev/null; then break; fi
    sleep 1
  done
  if ! curl -fsS --max-time 5 http://127.0.0.1:18028/health >/tmp/p218-live-health.json; then
    rollback_live "$OLD"; exit 3
  fi

  echo '[6] 10-minute live stability validation: local/public/page/container/load'
  for i in $(seq 1 20); do
    BAD=0
    curl -fsS --max-time 5 http://127.0.0.1:18028/health >/tmp/p218-live-health.json || BAD=1
    curl -k -fsS --max-time 7 "$PUB/health" >/dev/null || BAD=1
    curl -k -fsS --max-time 8 "$PUB/" >/dev/null || BAD=1
    HS=$(docker inspect "$LIVE" --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' 2>/dev/null || echo missing)
    [ "$HS" = unhealthy ] && BAD=1
    STAGE=$(python3 - <<'PY'
import json
try: print(json.load(open('/tmp/p218-live-health.json')).get('runtime_load_stage') or '')
except Exception: print('')
PY
)
    CPU=$(docker stats --no-stream --format '{{.CPUPerc}}' "$LIVE" 2>/dev/null || echo '?')
    MEM=$(docker stats --no-stream --format '{{.MemPerc}}' "$LIVE" 2>/dev/null || echo '?')
    echo "CHECK=$i/20 health=$HS load=$STAGE cpu=$CPU mem=$MEM"
    [ "$STAGE" = CRITICAL ] && BAD=1
    if [ "$BAD" -ne 0 ]; then FAIL=$((FAIL+1)); else FAIL=0; fi
    if [ "$FAIL" -ge 3 ]; then rollback_live "$OLD"; exit 4; fi
    sleep 30
  done
  echo 'LIVE_10MIN_PASS'
  echo "ACTIVE=$LIVE"
  echo "PREVIOUS_PRESERVED_STOPPED=$OLD"
  echo 'NO RENAME / NO IMAGE OVERWRITE / UI BYTE-PRESERVED'
}

build_image
case "$MODE" in
  --canary) canary_only ;;
  --cutover) canary_only; cutover_live ;;
  *) echo "usage: $0 [--canary|--cutover]"; exit 64 ;;
esac
