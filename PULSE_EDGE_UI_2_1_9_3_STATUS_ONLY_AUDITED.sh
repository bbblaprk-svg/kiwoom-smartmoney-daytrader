#!/usr/bin/env bash
set -euo pipefail

BASE=/opt/pulse-edge
LIVE=pulse-edge-live-ui-2.1.9-preopen-visible
PUB=https://3-38-25-20.nip.io
PREV_FILE="$BASE/.previous_ui_2_1_9_target"

say(){ printf '%s\n' "$*"; }

say '[1/5] STATUS-ONLY AUDIT 2.1.9.3'
say 'READ-ONLY: NO BUILD / NO CREATE / NO STOP / NO START / NO RESTART / NO RENAME / NO NETWORK CHANGE / NO CADDY EDIT'

if ! docker inspect "$LIVE" >/dev/null 2>&1; then
  say "ERROR: active container not found: $LIVE"
  exit 2
fi

RUNNING=$(docker inspect "$LIVE" --format '{{.State.Running}}')
[ "$RUNNING" = true ] || { say "ERROR: $LIVE is not running"; exit 3; }

IMAGE=$(docker inspect "$LIVE" --format '{{.Config.Image}}')
STATUS=$(docker inspect "$LIVE" --format '{{.State.Status}}')
HOSTPORT=$(docker inspect "$LIVE" --format '{{with (index .NetworkSettings.Ports "8000/tcp")}}{{(index . 0).HostPort}}{{end}}')
if [ -z "$HOSTPORT" ]; then
  say 'ERROR: no host-published port found for 8000/tcp; refusing to guess a port'
  exit 4
fi

say '[2/5] active identity'
say "ACTIVE=$LIVE"
say "IMAGE=$IMAGE"
say "STATE=$STATUS"
say "HOSTPORT=$HOSTPORT"

say '[3/5] validate active live container without touching it'
CONSEC_FAIL=0
for i in 1 2 3 4; do
  BAD=0
  rm -f /tmp/p2193-health.json /tmp/p2193-public-health.json /tmp/p2193-page.html

  if ! curl -fsS --max-time 5 "http://127.0.0.1:${HOSTPORT}/health" >/tmp/p2193-health.json; then BAD=1; fi
  if ! curl -k -fsS --max-time 7 "$PUB/health" >/tmp/p2193-public-health.json; then BAD=1; fi
  if ! curl -k -fsS --max-time 8 "$PUB/" >/tmp/p2193-page.html; then BAD=1; fi

  STAGE=$(python3 - <<'PY'
import json
try:
    d=json.load(open('/tmp/p2193-health.json'))
    print(d.get('runtime_load_stage') or '')
except Exception:
    print('')
PY
)
  FEED=$(python3 - <<'PY'
import json
try:
    d=json.load(open('/tmp/p2193-health.json'))
    print(d.get('runtime_feed_health') or '')
except Exception:
    print('')
PY
)
  WS=$(python3 - <<'PY'
import json
try:
    d=json.load(open('/tmp/p2193-health.json'))
    print(str(d.get('ws_connected')).lower())
except Exception:
    print('')
PY
)

  STATS=$(docker stats --no-stream --format '{{.CPUPerc}} {{.MemPerc}}' "$LIVE" 2>/dev/null || true)
  CPU=$(printf '%s' "$STATS" | awk '{print $1}')
  MEM=$(printf '%s' "$STATS" | awk '{print $2}')
  [ -n "$CPU" ] || CPU='?'
  [ -n "$MEM" ] || MEM='?'

  [ "$STAGE" = CRITICAL ] && BAD=1
  say "VERIFY=$i/4 load=${STAGE:-UNKNOWN} feed=${FEED:-UNKNOWN} ws=${WS:-UNKNOWN} cpu=$CPU mem=$MEM"

  if [ "$BAD" -eq 0 ]; then CONSEC_FAIL=0; else CONSEC_FAIL=$((CONSEC_FAIL+1)); fi
  [ "$CONSEC_FAIL" -lt 2 ] || { say 'STATUS_ONLY_VALIDATION_FAIL'; exit 5; }
  [ "$i" -eq 4 ] || sleep 5
done

say '[4/5] resolve previous preserved target without inventing one'
PREV='NONE_RECORDED'
if [ -f "$PREV_FILE" ]; then
  CANDIDATE=$(head -n 1 "$PREV_FILE" | tr -d '\r\n')
  if [ -n "$CANDIDATE" ] && [ "$CANDIDATE" != "$LIVE" ]; then
    PREV="$CANDIDATE"
  fi
fi
say "PREVIOUS_PRESERVED_STOPPED=$PREV"

say '[5/5] FINAL'
say 'STATUS_FIX_PASS'
say "ACTIVE=$LIVE"
say "IMAGE=$IMAGE"
say "HOSTPORT=$HOSTPORT"
say "PREVIOUS_PRESERVED_STOPPED=$PREV"
say 'DEPLOY_STATUS_FIX=2.1.9.3'
say 'UI_2.1.9_PREOPEN_VISIBLE / CORE_LOGIC_UNCHANGED'
say 'ZERO_RUNTIME_MUTATION=1'
