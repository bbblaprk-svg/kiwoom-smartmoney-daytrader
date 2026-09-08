#!/usr/bin/env bash
set -Eeuo pipefail

# PULSE EDGE 2.1.10 RUNTIME HOTLOOP GUARD — ONE SHOT
# Baseline UI: 2.1.9.4 POLL FIX (unchanged)
# Runtime optimization only: exact-semantics hot path optimization.
# No strategy thresholds/formulas changed.

BASE=/opt/pulse-edge
ENV_FILE="$BASE/.env"
DATA_DIR="$BASE/data"
NET=kiwoom-net
CADDY=kiwoom-caddy
PUB=https://3-38-25-20.nip.io

DF="$BASE/Dockerfile"
SRC="$BASE/PULSE_EDGE_CORE_2_1_3_RUNTIME_2_1_10_HOTLOOP_GUARD_UI_2_1_9_4_SOURCE.tar.gz"
EXPECTED_DF_SHA=1d9cccdeee60317c9d6d2a355acb3fd74547c2ce5b482416c760c7bf7ec4456a
EXPECTED_SRC_SHA=92bb28eb464076728e63732d78575a5b2399d7c26113f33c218b75d3d2675f6c

RUN_ID="$(date +%Y%m%d-%H%M%S)-$$"
BUILD="/tmp/pulse-edge-2.1.10-${RUN_ID}"
IMG="pulse-edge:core-2.1.3-runtime-2.1.10-hotloop-guard-ui-2.1.9.4-${RUN_ID}"
CANARY="pulse-edge-canary-runtime-2.1.10-${RUN_ID}"
LIVE="pulse-edge-live-runtime-2.1.10-${RUN_ID}"
OLD=""
CANARY_PORT=""
LIVE_PORT=""
CANARY_STARTED=0
LIVE_STARTED=0
CUTOVER_STARTED=0

log(){ printf '%s\n' "$*"; }
die(){ log "ERROR: $*"; exit 1; }
need(){ command -v "$1" >/dev/null 2>&1 || die "missing command: $1"; }

for c in docker curl tar python3 ss awk grep seq sha256sum df free; do need "$c"; done
[ -s "$ENV_FILE" ] || die "missing $ENV_FILE"
[ -d "$DATA_DIR" ] || die "missing $DATA_DIR"
[ -s "$DF" ] || die "missing $DF"
[ -s "$SRC" ] || die "missing $SRC"
docker inspect "$CADDY" >/dev/null 2>&1 || die "missing $CADDY"
docker network inspect "$NET" >/dev/null 2>&1 || die "missing network $NET"

health_field(){
  python3 - "$1" "$2" <<'PY'
import json,sys
p,f=sys.argv[1:3]
try:
    d=json.load(open(p))
    v=d.get(f)
    if isinstance(v,bool): print("true" if v else "false")
    elif v is None: print("")
    else: print(v)
except Exception:
    print("")
PY
}

has_alias(){
  docker inspect "$1" --format '{{json .NetworkSettings.Networks}}' 2>/dev/null |
    python3 -c 'import json,sys
net=sys.argv[1]
d=json.load(sys.stdin)
a=((d or {}).get(net) or {}).get("Aliases") or []
raise SystemExit(0 if "pulse-edge" in a else 1)' "$NET"
}

alias_holders(){
  local c
  while IFS= read -r c; do
    [ -n "$c" ] || continue
    has_alias "$c" && echo "$c"
  done < <(docker ps --format '{{.Names}}')
}

feed_mode(){
  docker inspect "$1" --format '{{range .Config.Env}}{{println .}}{{end}}' 2>/dev/null |
    awk -F= 'BEGIN{found=0} $1=="PULSE_FEED_ENABLED"{v=tolower($2); print v; found=1; exit} END{if(found==0) print "unset"}'
}

free_port(){
  local p
  for p in $(seq "$1" "$2"); do
    if ! ss -ltnH 2>/dev/null | awk '{print $4}' | grep -Eq "(^|:)${p}$"; then
      echo "$p"; return 0
    fi
  done
  return 1
}

stop_preserve(){
  local c="$1"
  [ -n "$c" ] || return 0
  docker inspect "$c" >/dev/null 2>&1 || return 0
  docker stop -t 5 "$c" >/dev/null 2>&1 || docker kill "$c" >/dev/null 2>&1 || true
}

wait_public(){
  local i code
  for i in $(seq 1 30); do
    code=$(curl -k -sS --max-time 4 -o /tmp/p2110-public-wait -w '%{http_code}' "$PUB/health" || true)
    [ "$code" = "200" ] && return 0
    sleep 2
  done
  return 1
}

rollback(){
  set +e
  log "ROLLBACK_BEGIN"
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
  code=$(curl -k -sS --max-time 8 -o /tmp/p2110-rb -w '%{http_code}' "$PUB/health" || true)
  log "ROLLBACK_PUBLIC_HEALTH=$code"
  log "ROLLBACK_END"
}

cleanup(){
  rc=$?
  trap - EXIT INT TERM
  if [ "$rc" -ne 0 ] && [ "$CUTOVER_STARTED" -eq 1 ]; then rollback; fi
  if [ "$rc" -ne 0 ] && [ "$CANARY_STARTED" -eq 1 ]; then stop_preserve "$CANARY"; fi
  exit "$rc"
}
trap cleanup EXIT INT TERM

log "============================================================"
log "PULSE EDGE 2.1.10 RUNTIME HOTLOOP GUARD"
log "============================================================"

log "[0/15] CURRENT ROUTE / RESOURCE SAFETY"
docker ps --format '{{.Names}}' | grep -qx "$CADDY" || die "Caddy not running"
docker exec "$CADDY" sh -c 'grep -Eq "reverse_proxy[[:space:]]+pulse-edge:8000" /etc/caddy/Caddyfile' || die "Caddy target is not pulse-edge:8000"
mapfile -t HOLDERS < <(alias_holders)
[ "${#HOLDERS[@]}" -eq 1 ] || { printf 'ALIAS_HOLDERS=%s\n' "${HOLDERS[*]:-NONE}"; die "expected exactly one current pulse-edge alias holder"; }
OLD="${HOLDERS[0]}"
log "CURRENT_ACTIVE=$OLD"

# Stale Feed-OFF canaries waste memory but are preserved (stopped only).
while IFS= read -r c; do
  [ -n "$c" ] || continue
  [ "$c" = "$OLD" ] && continue
  mode=$(feed_mode "$c")
  if [ "$mode" = "false" ] || [ "$mode" = "0" ] || [ "$mode" = "no" ]; then
    log "STOP_STALE_FEED_OFF_CANARY=$c"
    stop_preserve "$c"
  fi
done < <(docker ps --format '{{.Names}}' | grep '^pulse-edge-canary-' || true)

MEM_AVAIL_KB=$(awk '/MemAvailable:/{print $2}' /proc/meminfo)
if [ "${MEM_AVAIL_KB:-0}" -lt 196608 ]; then
  log "LOW_MEMORY_BEFORE_BUILD=${MEM_AVAIL_KB}KB -> restart current active once, preserve name/image"
  docker restart "$OLD" >/dev/null
  wait_public || die "current active did not recover after memory-relief restart"
  sleep 5
  MEM_AVAIL_KB=$(awk '/MemAvailable:/{print $2}' /proc/meminfo)
fi
[ "${MEM_AVAIL_KB:-0}" -ge 196608 ] || die "less than 192 MiB MemAvailable after safe cleanup/restart"
ROOT_FREE_KB=$(df -Pk / | awk 'NR==2{print $4}')
[ "${ROOT_FREE_KB:-0}" -ge 1048576 ] || die "less than 1 GiB free on /"

log "[1/15] EXACT ARTIFACT SHA"
DF_SHA=$(sha256sum "$DF" | awk '{print $1}')
SRC_SHA=$(sha256sum "$SRC" | awk '{print $1}')
[ "$DF_SHA" = "$EXPECTED_DF_SHA" ] || die "Dockerfile SHA mismatch: $DF_SHA"
[ "$SRC_SHA" = "$EXPECTED_SRC_SHA" ] || die "SOURCE SHA mismatch: $SRC_SHA"
log "ARTIFACT_SHA_PASS"

log "[2/15] SOURCE ARCHIVE / REQUIRED FILES / CONTRACT"
rm -rf "$BUILD"; mkdir -p "$BUILD"
tar -tzf "$SRC" >/tmp/p2110-list.txt
for f in requirements-runtime.txt pulse_edge/main.py pulse_edge/features/engine.py pulse_edge/features/rs.py pulse_edge/storage/baseline.py pulse_edge/web/pulse.js; do
  grep -Eq "^\\./${f}$|^${f}$" /tmp/p2110-list.txt || die "missing in archive: $f"
done
tar -xzf "$SRC" -C "$BUILD"
cp "$DF" "$BUILD/Dockerfile"
grep -q '2.1.10_RUNTIME_HOTLOOP_GUARD' "$BUILD/pulse_edge/main.py" || die "runtime marker missing"
grep -q '/api/smart-money/top?limit=10' "$BUILD/pulse_edge/web/pulse.js" || die "PREOPEN poll missing"
! grep -q '/api/history/candidates' "$BUILD/pulse_edge/web/pulse.js" || die "obsolete Candidate History poll reintroduced"
python3 -m compileall -q "$BUILD/pulse_edge"
if command -v node >/dev/null 2>&1; then node --check "$BUILD/pulse_edge/web/pulse.js"; fi
log "SOURCE_CONTRACT_PASS"

log "[3/15] BUILD UNIQUE IMAGE"
docker image inspect "$IMG" >/dev/null 2>&1 && die "unique image tag collision"
docker build -t "$IMG" "$BUILD"

log "[4/15] FEED-OFF CANARY"
CANARY_PORT=$(free_port 18410 18480) || die "no free canary port"
docker run -d --name "$CANARY" --restart no --env-file "$ENV_FILE" -e PULSE_FEED_ENABLED=false -v "$DATA_DIR:/app/data:ro" -p "127.0.0.1:${CANARY_PORT}:8000" "$IMG" >/dev/null
CANARY_STARTED=1
READY=0
for i in $(seq 1 60); do
  if curl -fsS --max-time 3 "http://127.0.0.1:${CANARY_PORT}/health" >/tmp/p2110-canary-health.json 2>/dev/null; then READY=1; break; fi
  sleep 1
done
[ "$READY" -eq 1 ] || { docker logs --tail 160 "$CANARY" || true; die "canary health not ready"; }
[ "$(health_field /tmp/p2110-canary-health.json feed_enabled)" = "false" ] || die "canary Feed not OFF"
[ "$(health_field /tmp/p2110-canary-health.json runtime_safety_release)" = "2.1.10_RUNTIME_HOTLOOP_GUARD" ] || die "runtime version mismatch"
curl -fsS --max-time 5 "http://127.0.0.1:${CANARY_PORT}/" >/dev/null
curl -fsS --max-time 5 "http://127.0.0.1:${CANARY_PORT}/api/smart-money/top?limit=10" >/dev/null
curl -fsS --max-time 5 "http://127.0.0.1:${CANARY_PORT}/api/presentation/current-decision" >/dev/null
log "CANARY_API_CONTRACT_PASS"

log "[5/15] 120-SECOND FEED-OFF CANARY SOAK"
BAD=0
for i in $(seq 1 24); do
  curl -fsS --max-time 3 "http://127.0.0.1:${CANARY_PORT}/health" >/dev/null 2>&1 || BAD=$((BAD+1))
  curl -fsS --max-time 4 "http://127.0.0.1:${CANARY_PORT}/" >/dev/null 2>&1 || BAD=$((BAD+1))
  [ "$BAD" -lt 2 ] || die "canary responsiveness failed twice"
  sleep 5
done
log "CANARY_120S_PASS"

log "[6/15] PRE-CUTOVER ALIAS / FEED SINGLETON"
mapfile -t HOLDERS2 < <(alias_holders)
[ "${#HOLDERS2[@]}" -eq 1 ] && [ "${HOLDERS2[0]}" = "$OLD" ] || die "active alias changed during canary"
EXTRA_ON=()
while IFS= read -r c; do
  [ -n "$c" ] || continue
  [ "$c" = "$OLD" ] && continue
  mode=$(feed_mode "$c")
  if [ "$mode" != "false" ] && [ "$mode" != "0" ] && [ "$mode" != "no" ]; then EXTRA_ON+=("$c"); fi
done < <(docker ps --format '{{.Names}}' | grep '^pulse-edge' || true)
if [ "${#EXTRA_ON[@]}" -gt 0 ]; then
  log "STOP_EXTRA_POTENTIAL_FEED_ON=${EXTRA_ON[*]}"
  for c in "${EXTRA_ON[@]}"; do stop_preserve "$c"; done
fi

log "[7/15] CUTOVER: OLD OFF + NETWORK DETACH"
CUTOVER_STARTED=1
stop_preserve "$OLD"
docker network disconnect "$NET" "$OLD" >/dev/null 2>&1 || true

log "[8/15] START 2.1.10 LIVE FEED-ON"
LIVE_PORT=$(free_port 18510 18580) || die "no free live port"
docker run -d --name "$LIVE" --restart unless-stopped --env-file "$ENV_FILE" -e PULSE_FEED_ENABLED=true -v "$DATA_DIR:/app/data" --network "$NET" --network-alias pulse-edge -p "127.0.0.1:${LIVE_PORT}:8000" "$IMG" >/dev/null
LIVE_STARTED=1
READY=0
for i in $(seq 1 90); do
  if curl -fsS --max-time 3 "http://127.0.0.1:${LIVE_PORT}/health" >/tmp/p2110-live-health.json 2>/dev/null; then READY=1; break; fi
  sleep 1
done
[ "$READY" -eq 1 ] || { docker logs --tail 220 "$LIVE" || true; die "new live health not ready"; }
[ "$(health_field /tmp/p2110-live-health.json feed_enabled)" = "true" ] || die "new live Feed not ON"
[ "$(health_field /tmp/p2110-live-health.json runtime_safety_release)" = "2.1.10_RUNTIME_HOTLOOP_GUARD" ] || die "new live runtime version mismatch"

log "[9/15] POST-CUTOVER SINGLETON"
mapfile -t HOLDERS3 < <(alias_holders)
[ "${#HOLDERS3[@]}" -eq 1 ] && [ "${HOLDERS3[0]}" = "$LIVE" ] || die "new live is not sole pulse-edge alias holder"
POTENTIAL_ON=()
while IFS= read -r c; do
  [ -n "$c" ] || continue
  mode=$(feed_mode "$c")
  if [ "$mode" != "false" ] && [ "$mode" != "0" ] && [ "$mode" != "no" ]; then POTENTIAL_ON+=("$c"); fi
done < <(docker ps --format '{{.Names}}' | grep '^pulse-edge' || true)
[ "${#POTENTIAL_ON[@]}" -eq 1 ] && [ "${POTENTIAL_ON[0]}" = "$LIVE" ] || die "Feed-ON singleton failed"

docker restart "$CADDY" >/dev/null
sleep 5

log "[10/15] PUBLIC HEALTH / PAGE / UI / CRITICAL APIs"
curl -k -fsS --max-time 8 "$PUB/health" >/tmp/p2110-pub-health.json
curl -k -fsS --max-time 10 "$PUB/" >/tmp/p2110-page.html
curl -k -fsS --max-time 8 "$PUB/assets/pulse.js" >/tmp/p2110-pulse.js
grep -q '/api/smart-money/top?limit=10' /tmp/p2110-pulse.js || die "public PREOPEN poll missing"
! grep -q '/api/history/candidates' /tmp/p2110-pulse.js || die "obsolete public history poll present"
curl -k -fsS --max-time 7 "$PUB/api/smart-money/top?limit=10" >/dev/null
curl -k -fsS --max-time 7 "$PUB/api/presentation/current-decision" >/dev/null
log "PUBLIC_CONTRACT_PASS"

log "[11/15] 120-SECOND LIVE WARMUP"
sleep 120

log "[12/15] 10-MINUTE LIVE SOAK"
BAD_STREAK=0
for i in $(seq 1 20); do
  BAD_NOW=0
  curl -fsS --max-time 5 "http://127.0.0.1:${LIVE_PORT}/health" >/tmp/p2110-live-health.json 2>/dev/null || BAD_NOW=1
  curl -k -fsS --max-time 7 "$PUB/health" >/dev/null 2>&1 || BAD_NOW=1
  curl -k -fsS --max-time 8 "$PUB/" >/dev/null 2>&1 || BAD_NOW=1
  curl -fsS --max-time 5 "http://127.0.0.1:${LIVE_PORT}/api/smart-money/top?limit=10" >/dev/null 2>&1 || BAD_NOW=1
  curl -fsS --max-time 5 "http://127.0.0.1:${LIVE_PORT}/api/presentation/current-decision" >/dev/null 2>&1 || BAD_NOW=1

  STATS=$(docker stats --no-stream --format '{{.CPUPerc}} {{.MemPerc}}' "$LIVE" 2>/dev/null || echo '? ?')
  CPU=$(awk '{print $1}' <<<"$STATS"); MEM=$(awk '{print $2}' <<<"$STATS"); CPU_NUM=${CPU%%%}
  STAGE=$(health_field /tmp/p2110-live-health.json runtime_load_stage)
  FEED=$(health_field /tmp/p2110-live-health.json runtime_feed_health)
  WS=$(health_field /tmp/p2110-live-health.json ws_connected)
  [ -n "$STAGE" ] || BAD_NOW=1
  [ -n "$FEED" ] || BAD_NOW=1
  [ -n "$WS" ] || BAD_NOW=1
  [ "$STAGE" = "CRITICAL" ] && BAD_NOW=1
  [ "$FEED" = "OFFLINE" ] && BAD_NOW=1
  [ "$WS" = "false" ] && [ "$i" -ge 4 ] && BAD_NOW=1
  if [[ "$CPU_NUM" =~ ^[0-9]+([.][0-9]+)?$ ]]; then awk -v c="$CPU_NUM" 'BEGIN{exit !(c>=90)}' && BAD_NOW=1 || true; fi
  AVAIL=$(awk '/MemAvailable:/{print $2}' /proc/meminfo)
  [ "${AVAIL:-0}" -ge 131072 ] || BAD_NOW=1
  DHEALTH=$(docker inspect "$LIVE" --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' 2>/dev/null || echo unknown)
  [ "$DHEALTH" = "unhealthy" ] && BAD_NOW=1
  [ "$DHEALTH" = "unknown" ] && BAD_NOW=1
  log "CHECK=$i/20 load=${STAGE:-?} feed=${FEED:-?} ws=${WS:-?} docker_health=$DHEALTH cpu=$CPU mem=$MEM avail_kb=$AVAIL bad=$BAD_NOW"
  if [ "$BAD_NOW" -eq 1 ]; then BAD_STREAK=$((BAD_STREAK+1)); else BAD_STREAK=0; fi
  [ "$BAD_STREAK" -lt 3 ] || die "live validation failed 3 consecutive checks"
  sleep 30
done

log "[13/15] FINAL VERSION / ROUTE / PUBLIC"
curl -k -fsS --max-time 8 "$PUB/health" >/tmp/p2110-final-health.json
curl -k -fsS --max-time 8 "$PUB/" >/dev/null
[ "$(health_field /tmp/p2110-final-health.json runtime_safety_release)" = "2.1.10_RUNTIME_HOTLOOP_GUARD" ] || die "final runtime version mismatch"
mapfile -t HOLDERS4 < <(alias_holders)
[ "${#HOLDERS4[@]}" -eq 1 ] && [ "${HOLDERS4[0]}" = "$LIVE" ] || die "final alias holder mismatch"
docker ps --format '{{.Names}}' | grep -qx "$LIVE" || die "new live not running"

log "[14/15] STOP FEED-OFF CANARY / PRESERVE ALL ARTIFACTS"
stop_preserve "$CANARY"

log "[15/15] DEPLOY PASS"
CUTOVER_STARTED=0
log "ACTIVE=$LIVE"
log "IMAGE=$IMG"
log "RUNTIME_SAFETY_RELEASE=2.1.10_RUNTIME_HOTLOOP_GUARD"
log "UI_RELEASE=2.1.9.4_POLL_FIX"
log "PREVIOUS_PRESERVED_STOPPED=$OLD"
log "PUBLIC_HEALTH=200"
log "PUBLIC_PAGE=200"
log "NO_STRATEGY_FORMULA_CHANGE / NO_RENAME / NO_IMAGE_OVERWRITE / NO_CADDYFILE_EDIT / NO_DELETE"
