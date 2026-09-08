#!/usr/bin/env bash
set -Eeuo pipefail

# PULSE EDGE DEPLOY GUARD 2.1.9.11 — FULL END-TO-END PREFLIGHT / ONE-SHOT
# App payload is the pinned 2.1.9.4 UI poll-fix source:
#   CORE 2.1.3 + RUNTIME SAFETY 2.1.8 + UI PREOPEN VISIBLE / POLL FIX
# This script does not edit data/Feed/RS/DUAL/PRICE HOLD/PRE-BUY/NXT logic.

BASE=/opt/pulse-edge
ENV_FILE="$BASE/.env"
DATA_DIR="$BASE/data"
NET=kiwoom-net
CADDY=kiwoom-caddy
PUB=https://3-38-25-20.nip.io

PINNED_COMMIT=f41fedc
DF_URL="https://raw.githubusercontent.com/bbblaprk-svg/kiwoom-smartmoney-daytrader/${PINNED_COMMIT}/Dockerfile"
SRC_URL="https://raw.githubusercontent.com/bbblaprk-svg/kiwoom-smartmoney-daytrader/${PINNED_COMMIT}/PULSE_EDGE_CORE_2_1_3_UI_2_1_9_4_POLL_FIX_SOURCE.tar.gz"
EXPECTED_DF_SHA=1d9cccdeee60317c9d6d2a355acb3fd74547c2ce5b482416c760c7bf7ec4456a
EXPECTED_SRC_SHA=d1862b4e831bdfe4f342dc06d706bd79097983025fe43718bdf215102a207e72

RUN_ID="$(date +%Y%m%d-%H%M%S)-$$"
WORK="/tmp/pulse-edge-deploy-2.1.9.11-${RUN_ID}"
DF="$WORK/Dockerfile"
SRC="$WORK/source.tar.gz"
BUILD="$WORK/build"

IMG="pulse-edge:core-2.1.3-runtime-safety-2.1.8-ui-2.1.9.4-poll-fix-${RUN_ID}"
CANARY="pulse-edge-canary-ui-2.1.9.11-${RUN_ID}"
LIVE="pulse-edge-live-ui-2.1.9.11-${RUN_ID}"

CANARY_PORT=""
LIVE_PORT=""
OLD=""
CANARY_STARTED=0
LIVE_STARTED=0
CUTOVER_STARTED=0
EXTRA_FEED_ON=()

log(){ printf '%s\n' "$*"; }
die(){ log "ERROR: $*"; exit 1; }
require(){ command -v "$1" >/dev/null 2>&1 || die "missing command: $1"; }

for c in docker curl tar python3 ss awk grep seq sha256sum mkdir date df free; do require "$c"; done
[ -s "$ENV_FILE" ] || die "missing $ENV_FILE"
[ -d "$DATA_DIR" ] || die "missing $DATA_DIR"
docker inspect "$CADDY" >/dev/null 2>&1 || die "missing $CADDY"
docker network inspect "$NET" >/dev/null 2>&1 || die "missing network $NET"

find_free_port(){
  local start="$1" end="$2" p
  for p in $(seq "$start" "$end"); do
    if ! ss -ltnH 2>/dev/null | awk '{print $4}' | grep -Eq "(^|:)${p}$"; then
      echo "$p"
      return 0
    fi
  done
  return 1
}

has_pulse_alias(){
  local c="$1"
  docker inspect "$c" --format '{{json .NetworkSettings.Networks}}' 2>/dev/null |
    python3 -c 'import json,sys
net=sys.argv[1]
d=json.load(sys.stdin)
aliases=((d or {}).get(net) or {}).get("Aliases") or []
raise SystemExit(0 if "pulse-edge" in aliases else 1)' "$NET"
}

alias_holders(){
  local c
  while IFS= read -r c; do
    [ -n "$c" ] || continue
    has_pulse_alias "$c" && echo "$c"
  done < <(docker ps --format '{{.Names}}')
}

container_feed_env(){
  local c="$1"
  docker inspect "$c" --format '{{range .Config.Env}}{{println .}}{{end}}' 2>/dev/null |
    awk -F= '
      BEGIN{found=0}
      $1=="PULSE_FEED_ENABLED"{v=tolower($2); print v; found=1; exit}
      END{if(found==0) print "unset"}'
}

health_field(){
  local file="$1" field="$2"
  python3 - "$file" "$field" <<'PY'
import json,sys
p,f=sys.argv[1:3]
try:
    d=json.load(open(p))
    v=d.get(f)
    if isinstance(v,bool):
        print("true" if v else "false")
    elif v is None:
        print("")
    else:
        print(v)
except Exception:
    print("")
PY
}

stop_preserve(){
  local c="$1"
  [ -n "$c" ] || return 0
  docker inspect "$c" >/dev/null 2>&1 || return 0
  docker stop -t 5 "$c" >/dev/null 2>&1 || docker kill "$c" >/dev/null 2>&1 || true
}

restore_old(){
  set +e
  log "ROLLBACK_BEGIN old=${OLD:-NONE} failed_live=${LIVE:-NONE}"

  if [ "$LIVE_STARTED" -eq 1 ]; then
    stop_preserve "$LIVE"
    docker network disconnect "$NET" "$LIVE" >/dev/null 2>&1 || true
  fi

  if [ -n "$OLD" ] && docker inspect "$OLD" >/dev/null 2>&1; then
    docker start "$OLD" >/dev/null 2>&1 || true
    docker network disconnect "$NET" "$OLD" >/dev/null 2>&1 || true
    docker network connect --alias pulse-edge "$NET" "$OLD" >/dev/null 2>&1 || true
  fi

  docker restart "$CADDY" >/dev/null 2>&1 || true
  sleep 5

  if curl -k -fsS --max-time 8 "$PUB/health" >/dev/null 2>&1; then
    log "ROLLBACK_PUBLIC_HEALTH=200"
  else
    log "ROLLBACK_PUBLIC_HEALTH=FAIL"
  fi
  log "ROLLBACK_END"
}

on_exit(){
  local rc=$?
  trap - EXIT INT TERM
  if [ "$rc" -ne 0 ] && [ "$CUTOVER_STARTED" -eq 1 ]; then
    restore_old
  fi
  if [ "$rc" -ne 0 ] && [ "$CANARY_STARTED" -eq 1 ]; then
    stop_preserve "$CANARY"
  fi
  exit "$rc"
}
trap on_exit EXIT INT TERM

log "============================================================"
log "PULSE EDGE 2.1.9.11 FULL PREFLIGHT / ONE-SHOT"
log "Pinned payload: f41fedc / UI 2.1.9.4 POLL FIX"
log "============================================================"

log "[0/12] HOST / DOCKER SAFETY AUDIT"
ROOT_FREE_KB=$(df -Pk / | awk 'NR==2{print $4}')
[ "${ROOT_FREE_KB:-0}" -ge 1572864 ] || die "less than 1.5 GiB free on /"
MEM_AVAIL_KB=$(awk '/MemAvailable:/{print $2}' /proc/meminfo)
[ "${MEM_AVAIL_KB:-0}" -ge 262144 ] || die "less than 256 MiB MemAvailable"

docker ps --format '{{.Names}}' | grep -qx "$CADDY" || die "Caddy is not running"
docker exec "$CADDY" sh -c 'grep -Eq "reverse_proxy[[:space:]]+pulse-edge:8000" /etc/caddy/Caddyfile' ||
  die "Caddy target is not pulse-edge:8000"

mapfile -t HOLDERS < <(alias_holders)
[ "${#HOLDERS[@]}" -eq 1 ] || {
  printf 'ALIAS_HOLDERS=%s\n' "${HOLDERS[*]:-NONE}"
  die "expected exactly one running pulse-edge alias holder before deploy"
}
OLD="${HOLDERS[0]}"
log "CURRENT_ACTIVE=$OLD"

# Detect all other running PULSE containers that may have Feed ON.
# Explicit false is safe. true or unset is treated as potentially Feed-ON.
while IFS= read -r c; do
  [ -n "$c" ] || continue
  [ "$c" = "$OLD" ] && continue
  mode=$(container_feed_env "$c")
  if [ "$mode" != "false" ] && [ "$mode" != "0" ] && [ "$mode" != "no" ]; then
    EXTRA_FEED_ON+=("$c")
  fi
done < <(docker ps --format '{{.Names}}' | grep '^pulse-edge' || true)

if [ "${#EXTRA_FEED_ON[@]}" -gt 0 ]; then
  log "EXTRA_POTENTIAL_FEED_ON=${EXTRA_FEED_ON[*]}"
  log "They will NOT be deleted or renamed; they will be stopped only after canary PASS, before cutover."
else
  log "EXTRA_POTENTIAL_FEED_ON=NONE"
fi

# Current service may already be degraded; record it but do not block repair.
if docker exec "$CADDY" wget -T 5 -qO- "http://${OLD}:8000/health" >/tmp/p21910-old-direct.json 2>/dev/null; then
  log "CURRENT_DIRECT_HEALTH=200 feed=$(health_field /tmp/p21910-old-direct.json feed_enabled) ws=$(health_field /tmp/p21910-old-direct.json ws_connected) load=$(health_field /tmp/p21910-old-direct.json runtime_load_stage)"
else
  log "CURRENT_DIRECT_HEALTH=DEGRADED"
fi
if curl -k -fsS --max-time 8 "$PUB/health" >/tmp/p21910-old-public.json 2>/dev/null; then
  log "CURRENT_PUBLIC_HEALTH=200"
else
  log "CURRENT_PUBLIC_HEALTH=DEGRADED"
fi

log "[1/12] DOWNLOAD EXACT PINNED ARTIFACTS"
mkdir -p "$BUILD"
curl -fL --retry 4 --retry-delay 2 --connect-timeout 8 --max-time 120 -o "$DF" "$DF_URL"
curl -fL --retry 4 --retry-delay 2 --connect-timeout 8 --max-time 180 -o "$SRC" "$SRC_URL"

DF_SHA=$(sha256sum "$DF" | awk '{print $1}')
SRC_SHA=$(sha256sum "$SRC" | awk '{print $1}')
[ "$DF_SHA" = "$EXPECTED_DF_SHA" ] || die "Dockerfile SHA mismatch: $DF_SHA"
[ "$SRC_SHA" = "$EXPECTED_SRC_SHA" ] || die "source SHA mismatch: $SRC_SHA"
log "PINNED_SHA_PASS"

log "[2/12] SOURCE CONTENT AUDIT"
tar -tzf "$SRC" >/tmp/p21910-tar-list.txt
grep -qx 'pulse_edge/web/pulse.js' /tmp/p21910-tar-list.txt || die "pulse.js missing in archive"
grep -qx 'pulse_edge/web/index.html' /tmp/p21910-tar-list.txt || die "index.html missing in archive"
grep -qx 'pulse_edge/main.py' /tmp/p21910-tar-list.txt || die "main.py missing in archive"

tar -xzf "$SRC" -C "$BUILD"
cp "$DF" "$BUILD/Dockerfile"

[ -s "$BUILD/pulse_edge/web/pulse.js" ] || die "pulse.js empty"
[ -s "$BUILD/pulse_edge/web/index.html" ] || die "index.html empty"
[ -s "$BUILD/pulse_edge/main.py" ] || die "main.py empty"

grep -q '/api/smart-money/top?limit=10' "$BUILD/pulse_edge/web/pulse.js" || die "PREOPEN poll missing"
! grep -q '/api/history/candidates' "$BUILD/pulse_edge/web/pulse.js" || die "obsolete Candidate History poll still present"
grep -q 'PREOPEN VISIBLE' "$BUILD/pulse_edge/web/index.html" || die "PREOPEN VISIBLE marker missing"
grep -q '@app.get("/api/smart-money/top")' "$BUILD/pulse_edge/main.py" || die "smart-money endpoint missing"
grep -q '@app.get("/api/presentation/current-decision")' "$BUILD/pulse_edge/main.py" || die "presentation endpoint missing"

python3 -m compileall -q "$BUILD/pulse_edge"
if command -v node >/dev/null 2>&1; then
  node --check "$BUILD/pulse_edge/web/pulse.js"
  log "NODE_JS_SYNTAX=PASS"
else
  log "NODE_JS_SYNTAX=SKIP(node-not-installed)"
fi
log "SOURCE_AUDIT=PASS"

log "[3/12] BUILD UNIQUE IMAGE"
docker image inspect "$IMG" >/dev/null 2>&1 && die "unique image tag unexpectedly already exists"
docker build -t "$IMG" "$BUILD"

log "[4/12] FEED-OFF CANARY — NO OAUTH / NO KIWOOM WS"
CANARY_PORT=$(find_free_port 18194 18260) || die "no free canary port"
docker run -d \
  --name "$CANARY" \
  --restart no \
  --env-file "$ENV_FILE" \
  -e PULSE_FEED_ENABLED=false \
  -v "$DATA_DIR:/app/data:ro" \
  -p "127.0.0.1:${CANARY_PORT}:8000" \
  "$IMG" >/dev/null
CANARY_STARTED=1

READY=0
for i in $(seq 1 60); do
  if curl -fsS --max-time 3 "http://127.0.0.1:${CANARY_PORT}/health" >/tmp/p21910-canary-health.json 2>/dev/null; then
    READY=1
    break
  fi
  sleep 1
done
[ "$READY" -eq 1 ] || {
  docker logs --tail 200 "$CANARY" || true
  die "canary health not ready"
}

[ "$(health_field /tmp/p21910-canary-health.json feed_enabled)" = false ] || die "canary Feed is not OFF"
curl -fsS --max-time 5 "http://127.0.0.1:${CANARY_PORT}/" >/tmp/p21910-canary-page.html
curl -fsS --max-time 5 "http://127.0.0.1:${CANARY_PORT}/assets/pulse.js" >/tmp/p21910-canary-pulse.js
grep -q '/api/smart-money/top?limit=10' /tmp/p21910-canary-pulse.js || die "canary PREOPEN poll missing"
! grep -q '/api/history/candidates' /tmp/p21910-canary-pulse.js || die "canary obsolete history poll present"
curl -fsS --max-time 5 "http://127.0.0.1:${CANARY_PORT}/api/smart-money/top?limit=10" >/dev/null || die "canary smart-money API execution failed"
curl -fsS --max-time 5 "http://127.0.0.1:${CANARY_PORT}/api/presentation/current-decision" >/dev/null || die "canary presentation API execution failed"
log "CANARY_CRITICAL_APIS=PASS"

log "[5/12] CANARY 120-SECOND RESPONSIVENESS"
BAD=0
for i in $(seq 1 24); do
  curl -fsS --max-time 3 "http://127.0.0.1:${CANARY_PORT}/health" >/dev/null 2>&1 || BAD=$((BAD+1))
  curl -fsS --max-time 4 "http://127.0.0.1:${CANARY_PORT}/" >/dev/null 2>&1 || BAD=$((BAD+1))
  [ "$BAD" -lt 2 ] || die "canary responsiveness failed twice"
  sleep 5
done
log "CANARY_120S_PASS port=$CANARY_PORT"

log "[6/12] PRE-CUTOVER ROUTE RECHECK"
mapfile -t HOLDERS2 < <(alias_holders)
[ "${#HOLDERS2[@]}" -eq 1 ] && [ "${HOLDERS2[0]}" = "$OLD" ] ||
  die "active pulse-edge alias holder changed during canary test"

log "[7/12] ENFORCE SINGLE FEED-ON ENGINE"
# Stop only extra running PULSE containers that were already potentially Feed-ON.
# Preserve names/images/files for diagnosis; no delete/rename.
for c in "${EXTRA_FEED_ON[@]:-}"; do
  [ -n "$c" ] || continue
  log "STOP_EXTRA_FEED_ON_PRESERVE=$c"
  stop_preserve "$c"
done

log "[8/12] CUTOVER — OLD OFF FIRST, NEW FEED-ON SECOND"
LIVE_PORT=$(find_free_port 18294 18360) || die "no free live port"
CUTOVER_STARTED=1
stop_preserve "$OLD"
# Remove the stopped old endpoint before reusing the stable alias.
docker network disconnect "$NET" "$OLD" >/dev/null 2>&1 || true

docker run -d \
  --name "$LIVE" \
  --restart unless-stopped \
  --env-file "$ENV_FILE" \
  -e PULSE_FEED_ENABLED=true \
  -v "$DATA_DIR:/app/data" \
  --network "$NET" \
  --network-alias pulse-edge \
  -p "127.0.0.1:${LIVE_PORT}:8000" \
  "$IMG" >/dev/null
LIVE_STARTED=1

READY=0
for i in $(seq 1 90); do
  rm -f /tmp/p21910-live-health.json
  if curl -fsS --max-time 3 "http://127.0.0.1:${LIVE_PORT}/health" >/tmp/p21910-live-health.json 2>/dev/null; then
    READY=1
    break
  fi
  sleep 1
done
[ "$READY" -eq 1 ] || {
  docker logs --tail 240 "$LIVE" || true
  die "new live health not ready"
}
[ "$(health_field /tmp/p21910-live-health.json feed_enabled)" = true ] || die "new live Feed is not ON"

mapfile -t HOLDERS3 < <(alias_holders)
[ "${#HOLDERS3[@]}" -eq 1 ] && [ "${HOLDERS3[0]}" = "$LIVE" ] || {
  printf 'POST_CUTOVER_ALIAS_HOLDERS=%s\n' "${HOLDERS3[*]:-NONE}"
  die "new live is not the only pulse-edge alias holder"
}

# Ensure there is exactly one running potentially Feed-ON PULSE container after cutover.
POTENTIAL_ON=()
while IFS= read -r c; do
  [ -n "$c" ] || continue
  mode=$(container_feed_env "$c")
  if [ "$mode" != "false" ] && [ "$mode" != "0" ] && [ "$mode" != "no" ]; then
    POTENTIAL_ON+=("$c")
  fi
done < <(docker ps --format '{{.Names}}' | grep '^pulse-edge' || true)
[ "${#POTENTIAL_ON[@]}" -eq 1 ] && [ "${POTENTIAL_ON[0]}" = "$LIVE" ] || {
  printf 'RUNNING_POTENTIAL_FEED_ON=%s\n' "${POTENTIAL_ON[*]:-NONE}"
  die "Feed singleton invariant failed after cutover"
}

docker restart "$CADDY" >/dev/null
sleep 5

log "[9/12] PUBLIC CONTRACT"
curl -k -fsS --max-time 8 "$PUB/health" >/tmp/p21910-public-health.json || die "public health failed"
curl -k -fsS --max-time 10 "$PUB/" >/tmp/p21910-public-page.html || die "public page failed"
curl -k -fsS --max-time 8 "$PUB/assets/pulse.js" >/tmp/p21910-public-pulse.js || die "public pulse.js failed"
grep -q '/api/smart-money/top?limit=10' /tmp/p21910-public-pulse.js || die "public PREOPEN poll missing"
! grep -q '/api/history/candidates' /tmp/p21910-public-pulse.js || die "public obsolete history poll present"
grep -q 'PREOPEN VISIBLE' /tmp/p21910-public-page.html || die "public PREOPEN VISIBLE marker missing"
curl -k -fsS --max-time 7 "$PUB/api/smart-money/top?limit=10" >/dev/null || die "public smart-money API failed"
curl -k -fsS --max-time 7 "$PUB/api/presentation/current-decision" >/dev/null || die "public presentation API failed"
log "PUBLIC_CONTRACT=PASS"

log "[10/12] 10-MINUTE LIVE DATA / API / RESOURCE VALIDATION"
BAD_STREAK=0
for i in $(seq 1 20); do
  BAD_NOW=0
  rm -f /tmp/p21910-live-health.json

  curl -fsS --max-time 5 "http://127.0.0.1:${LIVE_PORT}/health" >/tmp/p21910-live-health.json 2>/dev/null || BAD_NOW=1
  curl -k -fsS --max-time 7 "$PUB/health" >/dev/null 2>&1 || BAD_NOW=1
  curl -k -fsS --max-time 8 "$PUB/" >/dev/null 2>&1 || BAD_NOW=1

  # UI-critical APIs only; no writes and no strategy mutation.
  curl -fsS --max-time 5 "http://127.0.0.1:${LIVE_PORT}/api/smart-money/top?limit=10" >/dev/null 2>&1 || BAD_NOW=1
  curl -fsS --max-time 5 "http://127.0.0.1:${LIVE_PORT}/api/presentation/current-decision" >/dev/null 2>&1 || BAD_NOW=1

  STATS=$(docker stats --no-stream --format '{{.CPUPerc}} {{.MemPerc}}' "$LIVE" 2>/dev/null || echo "? ?")
  CPU=$(awk '{print $1}' <<<"$STATS")
  MEM=$(awk '{print $2}' <<<"$STATS")
  CPU_NUM=${CPU%%%}
  STAGE=$(health_field /tmp/p21910-live-health.json runtime_load_stage)
  FEED=$(health_field /tmp/p21910-live-health.json runtime_feed_health)
  WS=$(health_field /tmp/p21910-live-health.json ws_connected)

  [ -n "$STAGE" ] || BAD_NOW=1
  [ -n "$FEED" ] || BAD_NOW=1
  [ -n "$WS" ] || BAD_NOW=1

  [ "$STAGE" = "CRITICAL" ] && BAD_NOW=1
  [ "$FEED" = "OFFLINE" ] && BAD_NOW=1
  [ "$WS" = "false" ] && [ "$i" -ge 4 ] && BAD_NOW=1

  if [[ "$CPU_NUM" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
    if awk -v c="$CPU_NUM" 'BEGIN{exit !(c>=80)}'; then
      BAD_NOW=1
    fi
  fi

  DHEALTH=$(docker inspect "$LIVE" --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' 2>/dev/null || echo unknown)
  [ "$DHEALTH" = "unhealthy" ] && BAD_NOW=1
  [ "$DHEALTH" = "unknown" ] && BAD_NOW=1

  log "CHECK=$i/20 load=${STAGE:-?} feed=${FEED:-?} ws=${WS:-?} docker_health=$DHEALTH cpu=$CPU mem=$MEM bad=$BAD_NOW"

  if [ "$BAD_NOW" -eq 1 ]; then
    BAD_STREAK=$((BAD_STREAK+1))
  else
    BAD_STREAK=0
  fi
  [ "$BAD_STREAK" -lt 3 ] || die "live validation failed 3 consecutive checks"
  sleep 30
done

log "[11/12] FINAL ROUTE / VERSION / PROCESS AUDIT"
mapfile -t HOLDERS4 < <(alias_holders)
[ "${#HOLDERS4[@]}" -eq 1 ] && [ "${HOLDERS4[0]}" = "$LIVE" ] || die "final alias holder mismatch"

docker ps --format '{{.Names}}' | grep -qx "$LIVE" || die "final live container is not running"
FINAL_DHEALTH=$(docker inspect "$LIVE" --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' 2>/dev/null || echo unknown)
[ "$FINAL_DHEALTH" != "unhealthy" ] && [ "$FINAL_DHEALTH" != "unknown" ] || die "final Docker health is $FINAL_DHEALTH"
curl -k -fsS --max-time 8 "$PUB/health" >/tmp/p21910-final-health.json || die "final public health failed"
curl -k -fsS --max-time 8 "$PUB/" >/dev/null || die "final public page failed"

log "[12/12] DEPLOY PASS"
CUTOVER_STARTED=0
stop_preserve "$CANARY"

log "ACTIVE=$LIVE"
log "IMAGE=$IMG"
log "LIVE_PORT=$LIVE_PORT"
log "PREVIOUS_PRESERVED_STOPPED=$OLD"
if [ "${#EXTRA_FEED_ON[@]}" -gt 0 ]; then
  log "EXTRA_FEED_ON_PRESERVED_STOPPED=${EXTRA_FEED_ON[*]}"
else
  log "EXTRA_FEED_ON_PRESERVED_STOPPED=NONE"
fi
log "PUBLIC_HEALTH=200"
log "PUBLIC_PAGE=200"
log "DEPLOY_GUARD=2.1.9.11_FULL_END_TO_END"
log "APP_PAYLOAD=CORE_2.1.3_RUNTIME_2.1.8_UI_2.1.9.4_POLL_FIX"
log "NO_DATA_LOGIC_EDIT / NO_RENAME / NO_IMAGE_OVERWRITE / NO_CADDYFILE_EDIT / NO_DELETE"
