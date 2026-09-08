#!/usr/bin/env bash
set -Eeuo pipefail

# PULSE EDGE 2.1.11.1 PROFILED COALESCING GUARD — ONE SHOT
# Evidence basis: live py-spy capture at CPU 608.49% showed feed/ws.py:_run_once,
# feed/service.py:ingest[_raw], FeatureEngine windows and synchronous refresh work.
# Runtime-only change: preserve every accepted event/state update but coalesce expensive
# per-symbol derived FeatureFrame recalculation; background sync refresh yields to backlog.
# No strategy score/threshold/ranking/DUAL/PRICE HOLD/PRE-BUY/NXT formula changes.

BASE=/opt/pulse-edge
ENV_FILE="$BASE/.env"
DATA_DIR="$BASE/data"
NET=kiwoom-net
CADDY=kiwoom-caddy
PUB=https://3-38-25-20.nip.io

DF="$BASE/Dockerfile"
SRC="$BASE/PULSE_EDGE_CORE_2_1_3_RUNTIME_2_1_11_1_PROFILED_COALESCING_GUARD_UI_2_1_9_4_SOURCE.tar.gz"
EXPECTED_DF_SHA=1d9cccdeee60317c9d6d2a355acb3fd74547c2ce5b482416c760c7bf7ec4456a
EXPECTED_SRC_SHA=87acfb9a2321c367f320ad4cc5e3abeeb213f0823823a93a7a3e9ff08af80f50

RUN_ID="$(date +%Y%m%d-%H%M%S)-$$"
BUILD="/tmp/pulse-edge-2.1.11.1-${RUN_ID}"
IMG="pulse-edge:core-2.1.3-runtime-2.1.11.1-profiled-coalescing-ui-2.1.9.4-${RUN_ID}"
CANARY="pulse-edge-canary-runtime-2.1.11.1-${RUN_ID}"
LIVE="pulse-edge-live-runtime-2.1.11.1-${RUN_ID}"
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

json_path(){
  python3 - "$1" "$2" <<'PY'
import json,sys
p,path=sys.argv[1:3]
try:
    v=json.load(open(p))
    for part in path.split('.'):
        v=v.get(part) if isinstance(v,dict) else None
    if isinstance(v,bool): print('true' if v else 'false')
    elif v is None: print('')
    else: print(v)
except Exception:
    print('')
PY
}

has_alias(){
  docker inspect "$1" --format '{{json .NetworkSettings.Networks}}' 2>/dev/null |
    python3 -c 'import json,sys
net=sys.argv[1]; d=json.load(sys.stdin); a=((d or {}).get(net) or {}).get("Aliases") or []
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
    if ! ss -ltnH 2>/dev/null | awk '{print $4}' | grep -Eq "(^|:)${p}$"; then echo "$p"; return 0; fi
  done
  return 1
}

stop_preserve(){
  local c="$1"
  [ -n "$c" ] || return 0
  docker inspect "$c" >/dev/null 2>&1 || return 0
  docker stop -t 5 "$c" >/dev/null 2>&1 || docker kill "$c" >/dev/null 2>&1 || true
}

wait_public_200(){
  local attempts="${1:-30}" i code
  for i in $(seq 1 "$attempts"); do
    code=$(curl -k -sS --max-time 5 -o /tmp/p21111-public-wait -w '%{http_code}' "$PUB/health" || true)
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
  # Flush Caddy's upstream resolution after the stable alias has been restored.
  docker restart "$CADDY" >/dev/null 2>&1 || true
  if wait_public_200 30; then
    log "ROLLBACK_PUBLIC_HEALTH=200"
  else
    # One extra Caddy restart handles slow old-app startup/DNS propagation.
    docker restart "$CADDY" >/dev/null 2>&1 || true
    if wait_public_200 30; then
      log "ROLLBACK_PUBLIC_HEALTH=200"
    else
      code=$(curl -k -sS --max-time 5 -o /tmp/p21111-rb -w '%{http_code}' "$PUB/health" || true)
      log "ROLLBACK_PUBLIC_HEALTH=${code:-000}"
    fi
  fi
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
log "PULSE EDGE 2.1.11.1 PROFILED COALESCING GUARD"
log "============================================================"

log "[0/17] CURRENT ROUTE / RESOURCE / SINGLETON SAFETY"
docker ps --format '{{.Names}}' | grep -qx "$CADDY" || die "Caddy not running"
docker exec "$CADDY" sh -c 'grep -Eq "reverse_proxy[[:space:]]+pulse-edge:8000" /etc/caddy/Caddyfile' || die "Caddy target is not pulse-edge:8000"
mapfile -t HOLDERS < <(alias_holders)
[ "${#HOLDERS[@]}" -eq 1 ] || { printf 'ALIAS_HOLDERS=%s\n' "${HOLDERS[*]:-NONE}"; die "expected exactly one current pulse-edge alias holder"; }
OLD="${HOLDERS[0]}"
log "CURRENT_ACTIVE=$OLD"

# Eliminate any pre-existing duplicate potential Feed-ON PULSE engines before
# build/canary. They are stopped only, never deleted/renamed, preventing OAuth/WS
# token competition while preserving forensic evidence.
while IFS= read -r c; do
  [ -n "$c" ] || continue
  [ "$c" = "$OLD" ] && continue
  mode=$(feed_mode "$c")
  if [ "$mode" != "false" ] && [ "$mode" != "0" ] && [ "$mode" != "no" ]; then
    log "STOP_PREEXISTING_POTENTIAL_FEED_ON=$c"
    stop_preserve "$c"
  fi
done < <(docker ps --format '{{.Names}}' | grep '^pulse-edge' || true)

# Stop only stale FEED-OFF canaries. Never delete/rename old evidence.
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
[ "${MEM_AVAIL_KB:-0}" -ge 196608 ] || die "less than 192 MiB MemAvailable after safe Feed-OFF canary cleanup"
SWAP_TOTAL_KB=$(awk '/SwapTotal:/{print $2}' /proc/meminfo)
SWAP_FREE_KB=$(awk '/SwapFree:/{print $2}' /proc/meminfo)
if [ "${SWAP_TOTAL_KB:-0}" -gt 0 ]; then
  [ "${SWAP_FREE_KB:-0}" -ge 524288 ] || die "less than 512 MiB swap free"
fi
ROOT_FREE_KB=$(df -Pk / | awk 'NR==2{print $4}')
[ "${ROOT_FREE_KB:-0}" -ge 1048576 ] || die "less than 1 GiB free on /"
log "RESOURCE_PREFLIGHT mem_available_kb=$MEM_AVAIL_KB swap_free_kb=${SWAP_FREE_KB:-0} root_free_kb=$ROOT_FREE_KB"

log "[1/17] EXACT ARTIFACT SHA"
DF_SHA=$(sha256sum "$DF" | awk '{print $1}')
SRC_SHA=$(sha256sum "$SRC" | awk '{print $1}')
[ "$DF_SHA" = "$EXPECTED_DF_SHA" ] || die "Dockerfile SHA mismatch: $DF_SHA"
[ "$SRC_SHA" = "$EXPECTED_SRC_SHA" ] || die "SOURCE SHA mismatch: $SRC_SHA"
log "ARTIFACT_SHA_PASS"

log "[2/17] SOURCE ARCHIVE / REQUIRED FILES / PATH NORMALIZATION"
rm -rf "$BUILD"; mkdir -p "$BUILD"
tar -tzf "$SRC" | sed 's#^\./##' >/tmp/p21111-list.txt
python3 - "$SRC" <<'PYSEC'
import pathlib, sys, tarfile
p=sys.argv[1]
with tarfile.open(p, 'r:gz') as t:
    for m in t.getmembers():
        parts=pathlib.PurePosixPath(m.name).parts
        if m.name.startswith('/') or '..' in parts:
            raise SystemExit(f'unsafe archive path: {m.name}')
        if m.issym() or m.islnk():
            raise SystemExit(f'archive link not allowed: {m.name} -> {m.linkname}')
print('ARCHIVE_PATH_SECURITY_PASS')
PYSEC
for f in requirements-runtime.txt pulse_edge/main.py pulse_edge/feed/service.py pulse_edge/features/engine.py pulse_edge/features/rs.py pulse_edge/storage/baseline.py pulse_edge/web/pulse.js; do
  grep -Fxq "$f" /tmp/p21111-list.txt || die "missing in archive: $f"
done
tar -xzf "$SRC" -C "$BUILD"
cp "$DF" "$BUILD/Dockerfile"

log "[3/17] SOURCE CONTRACT / NO UI REGRESSION"
grep -q '2.1.11.1_PROFILED_COALESCING_GUARD' "$BUILD/pulse_edge/main.py" || die "runtime marker missing"
grep -q '_feature_recalc_loop' "$BUILD/pulse_edge/main.py" || die "feature coalescer task missing"
grep -q '_request_recalc' "$BUILD/pulse_edge/features/engine.py" || die "recalc coalescer missing"
grep -q 'if not self.trades.get(key)' "$BUILD/pulse_edge/features/engine.py" || die "quote-before-trade CPU guard missing"
grep -q '_REFRESH_MAX_BACKLOG_DEFER_SEC = 2.5' "$BUILD/pulse_edge/main.py" || die "bounded refresh-defer guard missing"
grep -q 'min_interval_ms' "$BUILD/pulse_edge/features/engine.py" || die "recalc diagnostics missing"
grep -q '/api/smart-money/top?limit=10' "$BUILD/pulse_edge/web/pulse.js" || die "PREOPEN poll missing"
! grep -q '/api/history/candidates' "$BUILD/pulse_edge/web/pulse.js" || die "obsolete Candidate History poll reintroduced"
python3 -m compileall -q "$BUILD/pulse_edge"
if command -v node >/dev/null 2>&1; then node --check "$BUILD/pulse_edge/web/pulse.js"; fi
log "SOURCE_CONTRACT_PASS"

log "[4/17] SYNTHETIC BURST SEMANTICS + PERFORMANCE SELF-TEST"
PYTHONPATH="$BUILD" python3 - <<'PY'
import time, types
from datetime import datetime, timezone, timedelta
from pulse_edge.core.models import NormalizedEvent, Venue
from pulse_edge.features.engine import FeatureEngine
from pulse_edge.session.router import SessionRouter

router=SessionRouter()
immediate=FeatureEngine(router,None,None)
coalesced=FeatureEngine(router,None,None)
# Reference engine uses the exact same 2.1.11.1 formulas/state path but forces the
# historical immediate-recalc scheduling behavior.
def immediate_request(self,key,ts):
    self.recalc_requested += 1
    self._recalc(key,ts)
    self.recalc_executed += 1
immediate._request_recalc=types.MethodType(immediate_request, immediate)
base=datetime(2026,9,8,3,0,0,tzinfo=timezone.utc)

def event(rt,symbol,n,data):
    ts=base+timedelta(milliseconds=20*n)
    return NormalizedEvent(receive_time=ts,event_time=ts,source='burst-test',real_type=rt,symbol=symbol,venue=Venue.KRX,data=data)

events=[]
for si,symbol in enumerate(('005930','000660','035420','005380')):
    for i in range(220):
        n=si*10000+i*3
        price=70000+si*1000+(i%17)*10
        events.append(event('0B',symbol,n,{'price':str(price),'trade_volume':str(10+i%7),'change_rate':'0.5','cumulative_volume':str(10000+i*10),'cumulative_amount':str(700000000+i*700000),'buy_exec_volume':str(8+i%3),'sell_exec_volume':str(5+i%2),'net_buy_exec_volume':'3','instant_amount':str(price*(10+i%7))}))
        events.append(event('0D',symbol,n+1,{'ask1':str(price+10),'bid1':str(price-10),'ask1_qty':'100','bid1_qty':'120','total_ask_qty':'1000','total_bid_qty':'1200'}))
        if i%5==0:
            events.append(event('0w',symbol,n+2,{'program_net_buy_qty':str(i),'program_net_buy_qty_delta':'1','program_net_buy_amount':str(i*1000),'program_net_buy_amount_delta':'1000'}))

t0=time.perf_counter()
for e in events: immediate.ingest(e)
ref_sec=time.perf_counter()-t0

t0=time.perf_counter()
for e in events: coalesced.ingest(e)
coalesced.flush_due(force=True,max_batch=10000)
new_sec=time.perf_counter()-t0

for symbol in ('005930','000660','035420','005380'):
    key=(Venue.KRX,symbol)
    a=immediate.frames[key].model_dump()
    b=coalesced.frames[key].model_dump()
    if a != b:
        diffs=[k for k in a if a[k] != b[k]]
        raise SystemExit(f'FINAL_FRAME_MISMATCH {symbol} {diffs[:10]}')

stats=coalesced.recalc_runtime_stats()
if stats['pending'] != 0: raise SystemExit('PENDING_NOT_FLUSHED')
if stats['executed'] >= stats['requested'] // 4: raise SystemExit(f'COALESCING_TOO_WEAK {stats}')
ratio=new_sec/max(ref_sec,1e-9)
if ratio >= 0.60: raise SystemExit(f'BURST_SPEEDUP_INSUFFICIENT ref={ref_sec:.4f} new={new_sec:.4f} ratio={ratio:.3f}')
print(f'BURST_SEMANTICS_PASS events={len(events)} ref_sec={ref_sec:.4f} new_sec={new_sec:.4f} ratio={ratio:.3f} stats={stats}')

# Quote/program-before-first-trade regression: these events must be stored without
# repeatedly invoking a derived recalculation that cannot produce a frame.
pre=FeatureEngine(router,None,None)
for i in range(1000):
    pre.ingest(event('0D','051910',50000+i,{'ask1':'10010','bid1':'10000','ask1_qty':'100','bid1_qty':'120'}))
    if i % 5 == 0:
        pre.ingest(event('0w','051910',60000+i,{'program_net_buy_qty':str(i),'program_net_buy_qty_delta':'1'}))
pre_stats=pre.recalc_runtime_stats()
if pre.frames:
    raise SystemExit(f'QUOTE_ONLY_UNEXPECTED_FRAME {len(pre.frames)}')
if pre_stats['executed'] != 0 or pre_stats['pending'] != 0:
    raise SystemExit(f'QUOTE_ONLY_RECALC_REGRESSION {pre_stats}')
pre.ingest(event('0B','051910',70000,{'price':'10000','trade_volume':'10','change_rate':'0.1','cumulative_volume':'100','cumulative_amount':'1000000','instant_amount':'100000'}))
if (Venue.KRX,'051910') not in pre.frames:
    raise SystemExit('FIRST_TRADE_DID_NOT_CREATE_FRAME')
print(f'QUOTE_BEFORE_TRADE_GUARD_PASS stats={pre_stats}')
PY

log "[5/17] BUILD UNIQUE IMAGE"
docker image inspect "$IMG" >/dev/null 2>&1 && die "unique image tag collision"
docker build -t "$IMG" "$BUILD"

log "[6/17] FEED-OFF CANARY"
# Print only non-secret effective capacity settings from the built image/env.
docker run --rm --env-file "$ENV_FILE" -e PULSE_FEED_ENABLED=false "$IMG" python3 - <<'PYCFG'
from pulse_edge.config import get_settings
s=get_settings()
print(f"EFFECTIVE_RUNTIME_CONFIG ws_dynamic_max_items={s.ws_dynamic_max_items} background_batch_size={s.background_batch_size} ws_background_reserve_items={s.ws_background_reserve_items}")
assert s.ws_dynamic_max_items > 0
assert s.background_batch_size > 0
PYCFG
CANARY_PORT=$(free_port 18610 18680) || die "no free canary port"
docker run -d --name "$CANARY" --restart no --env-file "$ENV_FILE" -e PULSE_FEED_ENABLED=false -v "$DATA_DIR:/app/data:ro" -p "127.0.0.1:${CANARY_PORT}:8000" "$IMG" >/dev/null
CANARY_STARTED=1
READY=0
for i in $(seq 1 60); do
  if curl -fsS --max-time 3 "http://127.0.0.1:${CANARY_PORT}/health" >/tmp/p21111-canary-health.json 2>/dev/null; then READY=1; break; fi
  sleep 1
done
[ "$READY" -eq 1 ] || { docker logs --tail 180 "$CANARY" || true; die "canary health not ready"; }
[ "$(json_path /tmp/p21111-canary-health.json feed_enabled)" = "false" ] || die "canary Feed not OFF"
[ "$(json_path /tmp/p21111-canary-health.json runtime_safety_release)" = "2.1.11.1_PROFILED_COALESCING_GUARD" ] || die "runtime version mismatch"
[ "$(json_path /tmp/p21111-canary-health.json runtime_feature_recalc.min_interval_ms)" = "500" ] || die "coalescer health contract missing"
curl -fsS --max-time 5 "http://127.0.0.1:${CANARY_PORT}/" >/dev/null
curl -fsS --max-time 5 "http://127.0.0.1:${CANARY_PORT}/api/smart-money/top?limit=10" >/dev/null
curl -fsS --max-time 5 "http://127.0.0.1:${CANARY_PORT}/api/presentation/current-decision" >/dev/null
log "CANARY_API_CONTRACT_PASS"

log "[7/17] 120-SECOND FEED-OFF CANARY SOAK"
BAD=0
for i in $(seq 1 24); do
  curl -fsS --max-time 3 "http://127.0.0.1:${CANARY_PORT}/health" >/dev/null 2>&1 || BAD=$((BAD+1))
  curl -fsS --max-time 4 "http://127.0.0.1:${CANARY_PORT}/" >/dev/null 2>&1 || BAD=$((BAD+1))
  [ "$BAD" -lt 2 ] || die "canary responsiveness failed twice"
  sleep 5
done
log "CANARY_120S_PASS"

log "[8/17] PRE-CUTOVER ALIAS / FEED SINGLETON"
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

log "[9/17] CUTOVER: OLD OFF + NETWORK DETACH"
CUTOVER_STARTED=1
stop_preserve "$OLD"
docker network disconnect "$NET" "$OLD" >/dev/null 2>&1 || true

log "[10/17] START 2.1.11.1 LIVE FEED-ON"
LIVE_PORT=$(free_port 18710 18780) || die "no free live port"
docker run -d --name "$LIVE" --restart unless-stopped --env-file "$ENV_FILE" -e PULSE_FEED_ENABLED=true -v "$DATA_DIR:/app/data" --network "$NET" --network-alias pulse-edge -p "127.0.0.1:${LIVE_PORT}:8000" "$IMG" >/dev/null
LIVE_STARTED=1
READY=0
for i in $(seq 1 90); do
  if curl -fsS --max-time 3 "http://127.0.0.1:${LIVE_PORT}/health" >/tmp/p21111-live-health.json 2>/dev/null; then READY=1; break; fi
  sleep 1
done
[ "$READY" -eq 1 ] || { docker logs --tail 220 "$LIVE" || true; die "new live health not ready"; }
[ "$(json_path /tmp/p21111-live-health.json feed_enabled)" = "true" ] || die "new live Feed not ON"
[ "$(json_path /tmp/p21111-live-health.json runtime_safety_release)" = "2.1.11.1_PROFILED_COALESCING_GUARD" ] || die "new live runtime version mismatch"

log "[11/17] POST-CUTOVER SINGLETON / CADDY DNS REFRESH"
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
wait_public_200 30 || die "public health did not recover after cutover"

log "[12/17] PUBLIC HEALTH / PAGE / UI / CRITICAL APIs"
curl -k -fsS --max-time 8 "$PUB/health" >/tmp/p21111-pub-health.json
curl -k -fsS --max-time 10 "$PUB/" >/tmp/p21111-page.html
curl -k -fsS --max-time 8 "$PUB/assets/pulse.js" >/tmp/p21111-pulse.js
grep -q '/api/smart-money/top?limit=10' /tmp/p21111-pulse.js || die "public PREOPEN poll missing"
! grep -q '/api/history/candidates' /tmp/p21111-pulse.js || die "obsolete public history poll present"
[ "$(json_path /tmp/p21111-pub-health.json runtime_safety_release)" = "2.1.11.1_PROFILED_COALESCING_GUARD" ] || die "public runtime version mismatch"
curl -k -fsS --max-time 7 "$PUB/api/smart-money/top?limit=10" >/dev/null
curl -k -fsS --max-time 7 "$PUB/api/presentation/current-decision" >/dev/null
log "PUBLIC_CONTRACT_PASS"

log "[13/17] 120-SECOND LIVE WARMUP"
sleep 120

log "[14/17] 10-MINUTE LIVE SOAK: CPU / MEMORY / FEED / RECALC BACKLOG"
BAD_STREAK=0
for i in $(seq 1 20); do
  BAD_NOW=0
  curl -fsS --max-time 5 "http://127.0.0.1:${LIVE_PORT}/health" >/tmp/p21111-live-health.json 2>/dev/null || BAD_NOW=1
  curl -k -fsS --max-time 7 "$PUB/health" >/dev/null 2>&1 || BAD_NOW=1
  curl -k -fsS --max-time 8 "$PUB/" >/dev/null 2>&1 || BAD_NOW=1
  curl -fsS --max-time 5 "http://127.0.0.1:${LIVE_PORT}/api/smart-money/top?limit=10" >/dev/null 2>&1 || BAD_NOW=1
  curl -fsS --max-time 5 "http://127.0.0.1:${LIVE_PORT}/api/presentation/current-decision" >/dev/null 2>&1 || BAD_NOW=1

  STATS=$(docker stats --no-stream --format '{{.CPUPerc}} {{.MemPerc}}' "$LIVE" 2>/dev/null || echo '? ?')
  CPU=$(awk '{print $1}' <<<"$STATS"); MEM=$(awk '{print $2}' <<<"$STATS"); CPU_NUM=${CPU%%%}
  STAGE=$(json_path /tmp/p21111-live-health.json runtime_load_stage)
  FEED=$(json_path /tmp/p21111-live-health.json runtime_feed_health)
  WS=$(json_path /tmp/p21111-live-health.json ws_connected)
  PENDING=$(json_path /tmp/p21111-live-health.json runtime_feature_recalc.pending)
  REQ=$(json_path /tmp/p21111-live-health.json runtime_feature_recalc.requested)
  EXEC=$(json_path /tmp/p21111-live-health.json runtime_feature_recalc.executed)
  COAL=$(json_path /tmp/p21111-live-health.json runtime_feature_recalc.coalesced)

  [ -n "$STAGE" ] || BAD_NOW=1
  [ -n "$FEED" ] || BAD_NOW=1
  [ -n "$WS" ] || BAD_NOW=1
  [ "$STAGE" = "CRITICAL" ] && BAD_NOW=1
  [ "$FEED" = "OFFLINE" ] && BAD_NOW=1
  [ "$WS" = "false" ] && [ "$i" -ge 4 ] && BAD_NOW=1
  if [[ "$PENDING" =~ ^[0-9]+$ ]] && [ "$PENDING" -ge 40 ]; then BAD_NOW=1; fi
  if [[ "$CPU_NUM" =~ ^[0-9]+([.][0-9]+)?$ ]]; then awk -v c="$CPU_NUM" 'BEGIN{exit !(c>=90)}' && BAD_NOW=1 || true; fi
  AVAIL=$(awk '/MemAvailable:/{print $2}' /proc/meminfo)
  [ "${AVAIL:-0}" -ge 131072 ] || BAD_NOW=1
  DHEALTH=$(docker inspect "$LIVE" --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' 2>/dev/null || echo unknown)
  [ "$DHEALTH" = "unhealthy" ] && BAD_NOW=1
  [ "$DHEALTH" = "unknown" ] && BAD_NOW=1
  log "CHECK=$i/20 load=${STAGE:-?} feed=${FEED:-?} ws=${WS:-?} pending=${PENDING:-?} req=${REQ:-?} exec=${EXEC:-?} coal=${COAL:-?} docker_health=$DHEALTH cpu=$CPU mem=$MEM avail_kb=$AVAIL bad=$BAD_NOW"
  if [ "$BAD_NOW" -eq 1 ]; then BAD_STREAK=$((BAD_STREAK+1)); else BAD_STREAK=0; fi
  [ "$BAD_STREAK" -lt 3 ] || die "live validation failed 3 consecutive checks"
  sleep 30
done

log "[15/17] FINAL VERSION / ROUTE / PUBLIC / RECALC CONTRACT"
curl -k -fsS --max-time 8 "$PUB/health" >/tmp/p21111-final-health.json
curl -k -fsS --max-time 8 "$PUB/" >/dev/null
[ "$(json_path /tmp/p21111-final-health.json runtime_safety_release)" = "2.1.11.1_PROFILED_COALESCING_GUARD" ] || die "final runtime version mismatch"
[ "$(json_path /tmp/p21111-final-health.json runtime_feature_recalc.min_interval_ms)" = "500" ] || die "final recalc contract mismatch"
mapfile -t HOLDERS4 < <(alias_holders)
[ "${#HOLDERS4[@]}" -eq 1 ] && [ "${HOLDERS4[0]}" = "$LIVE" ] || die "final alias holder mismatch"
docker ps --format '{{.Names}}' | grep -qx "$LIVE" || die "new live not running"

log "[16/17] STOP FEED-OFF CANARY / PRESERVE ALL ARTIFACTS"
stop_preserve "$CANARY"

log "[17/17] DEPLOY PASS"
CUTOVER_STARTED=0
log "ACTIVE=$LIVE"
log "IMAGE=$IMG"
log "RUNTIME_SAFETY_RELEASE=2.1.11.1_PROFILED_COALESCING_GUARD"
log "UI_RELEASE=2.1.9.4_POLL_FIX"
log "PREVIOUS_PRESERVED_STOPPED=$OLD"
log "PUBLIC_HEALTH=200"
log "PUBLIC_PAGE=200"
log "NO_STRATEGY_FORMULA_CHANGE / EVERY_ACCEPTED_EVENT_PRESERVED / NO_RENAME / NO_IMAGE_OVERWRITE / NO_CADDYFILE_EDIT / NO_DELETE"
