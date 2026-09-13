#!/usr/bin/env bash
set -Eeuo pipefail

RELEASE="3.8.16_REALTIME_HIDDEN_GEM"
BASE="${PULSE_GF_BASE:-/opt/pulse-edge-gf3}"
DATA_DIR="$BASE/data"
ENV_FILE="$BASE/runtime.env"
ENV_SOURCE="${PULSE_GF_ENV_SOURCE:-/opt/pulse-edge/.env}"
NET="${PULSE_DEPLOY_NETWORK:-kiwoom-net}"
CADDY="${PULSE_DEPLOY_CADDY:-kiwoom-caddy}"
PUB="${PULSE_DEPLOY_PUBLIC_URL:-https://3-38-25-20.nip.io}"
SRC_NAME="PULSE_EDGE_GREENFIELD_3_8_16_REALTIME_HIDDEN_GEM_SOURCE.tar.gz"
EXPECTED_SRC_SHA="a1a70a7585624b64cabafe795d16ddbd373c0911fa956c6a98b9b686f3107ca9"
EXPECTED_DF_SHA="a30bce01a57db7d032a5edd9391b4256cf4b2ed04feeccfd55f33fd4badbea11"
MODE="${1:-deploy}"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
RUN_ID="$(date +%Y%m%d-%H%M%S)-$$"
RUN_DIR="$BASE/deployments/$RUN_ID"
CANARY_DATA="$RUN_DIR/canary-data"
IMG="pulse-edge:gf3816-hidden-$RUN_ID"
CANARY="pulse-edge-gf3816-canary-$RUN_ID"
LIVE="pulse-edge-gf3816-live-$RUN_ID"
OLD=""
OLD_RUNNING=false
OLD_RESTART="no"
CUTOVER=0
SUCCESS=0

log(){ printf '%s\n' "$*"; }
die(){ log "ERROR: $*" >&2; exit 1; }
need(){ command -v "$1" >/dev/null 2>&1 || die "missing command: $1"; }
running(){ [ "$(docker inspect -f '{{.State.Running}}' "$1" 2>/dev/null || true)" = true ]; }
exists(){ docker inspect "$1" >/dev/null 2>&1; }
container_ip(){ docker inspect -f "{{with index .NetworkSettings.Networks \"$NET\"}}{{.IPAddress}}{{end}}" "$1" 2>/dev/null || true; }
stopc(){ exists "$1" || return 0; docker update --restart=no "$1" >/dev/null 2>&1 || true; running "$1" && docker stop -t 25 "$1" >/dev/null || true; ! running "$1"; }
rmc(){ exists "$1" || return 0; stopc "$1" || true; docker rm "$1" >/dev/null 2>&1 || true; }

feedon_contract(){
  python3 - "$1" "$RELEASE" <<'PYCONTRACT'
import json,sys,urllib.request,urllib.error
base=sys.argv[1].rstrip('/'); release=sys.argv[2]

def get(path, allowed=(200,)):
    url=base+path
    try:
        with urllib.request.urlopen(url,timeout=6) as r:
            code=r.getcode(); body=r.read()
    except urllib.error.HTTPError as e:
        code=e.code; body=e.read()
    if code not in allowed:
        raise AssertionError((path,code,body[:300]))
    return code,json.loads(body.decode())

_,h=get('/health'); assert h.get('ok') is True and h.get('runtime_safety_release')==release,h
_,q=get('/api/hidden-gem/top?limit=3'); assert q.get('release')==release,q
_,c=get('/api/coiled-spring/top?limit=5'); assert c.get('release')==release and isinstance(c.get('rows'),list),c
_,hist=get('/api/signal-history?limit=3'); assert isinstance(hist.get('rows'),list),hist
_,push=get('/api/push/public-key'); assert 'enabled' in push and 'public_key' in push,push
_,truth=get('/api/feed-truth'); assert truth.get('data_truth_policy')=='NO_DELAYED_OR_CROSS_VENUE_DATA_FOR_BUY_DECISION',truth
_,sess=get('/api/session'); assert sess.get('release')==release and sess.get('automatic_orders') is False,sess
get('/api/runtime-truth')
code,rd=get('/api/readiness',(200,503))
assert rd.get('release')==release and rd.get('feed_enabled') is True,rd
venue=rd.get('active_venue'); checks=rd.get('checks') or {}
if venue:
    assert code==200 and rd.get('ready') is True and rd.get('live_market_verified') is True,rd
    assert checks.get('ws_connected') is True and checks.get('ws_recent') is True and checks.get('trade_recent') is True,rd
    print('HTTP_CONTRACT_PASS LIVE venue='+str(venue))
else:
    assert rd.get('note')=='MARKET_CLOSED_OR_SESSION_GAP_LIVE_TICK_NOT_VERIFIABLE',rd
    assert checks.get('market_context') is True,rd
    print('HTTP_CONTRACT_PASS CLOSED_SESSION readiness_http='+str(code)+' live_ticks_not_required')
PYCONTRACT
}

readiness_acceptable(){
  python3 - "$1" "$2" "$RELEASE" <<'PYREADY'
import json,sys
p=sys.argv[1]; code=int(sys.argv[2]); release=sys.argv[3]
q=json.load(open(p)); assert q.get('release')==release and q.get('feed_enabled') is True,q
venue=q.get('active_venue'); checks=q.get('checks') or {}
if venue:
    assert code==200 and q.get('ready') is True and q.get('live_market_verified') is True,q
    assert checks.get('ws_connected') is True and checks.get('ws_recent') is True and checks.get('trade_recent') is True,q
    print('LIVE_MARKET_VERIFIED venue='+str(venue))
else:
    assert code in (200,503),q
    assert q.get('note')=='MARKET_CLOSED_OR_SESSION_GAP_LIVE_TICK_NOT_VERIFIABLE',q
    assert checks.get('market_context') is True,q
    print('CLOSED_SESSION_VERIFIED live_tick_ws_universe_not_required')
PYREADY
}

closed_coiled_pipeline_acceptable(){
  python3 - "$1" <<'PYCLOSED'
import json,sys,time
q=json.load(open(sys.argv[1])); assert q.get('active_venue') is None,q
jobs=q.get('jobs') or {}; seeds=int(q.get('coiled_seed_count') or 0)
seed_job=jobs.get('coiled-seeds') or {}; daily_job=jobs.get('daily') or {}
assert seed_job.get('last_ok'), ('coiled-seeds not successful',seed_job,q.get('errors'))
assert daily_job.get('last_ok'), ('daily context not successful',daily_job,q.get('errors'))
assert seeds>0, ('closed-session seed set empty',q.get('errors'))
print('CLOSED_COILED_PIPELINE_PASS seeds='+str(seeds)+' coiled='+str(q.get('coiled_count') or 0))
PYCLOSED
}

for x in docker curl python3 sha256sum awk grep sed flock df; do need "$x"; done
[ "$EUID" -eq 0 ] || die "run with: sudo bash $0"
[ "$MODE" = deploy ] || [ "$MODE" = --preflight ] || die "usage: sudo bash $0 [--preflight]"
mkdir -p "$BASE" "$DATA_DIR/pulse_edge" "$BASE/deployments"
exec 9>"$BASE/.deploy.lock"; flock -n 9 || die "another deployment is running"
mkdir -p "$RUN_DIR/build" "$RUN_DIR/source" "$CANARY_DATA/pulse_edge"
exec > >(tee -a "$RUN_DIR/deploy.log") 2>&1

rollback(){
  set +e
  if [ -n "$OLD" ] && exists "$OLD"; then log "ROLLBACK_BEGIN optional_previous=$OLD"; else log "FRESH_REVERT_BEGIN no_previous_runtime"; fi
  stopc "$LIVE"
  rmc "$LIVE"
  if [ -n "$OLD" ] && exists "$OLD"; then
    docker network connect --alias pulse-edge "$NET" "$OLD" >/dev/null 2>&1 || true
    [ "$OLD_RUNNING" = true ] && docker start "$OLD" >/dev/null 2>&1 || true
    docker update --restart="$OLD_RESTART" "$OLD" >/dev/null 2>&1 || true
  fi
  if [ -n "$OLD" ] && exists "$OLD"; then log "ROLLBACK_END restored_optional_previous=$OLD"; else log "FRESH_REVERT_END new_runtime_removed_no_previous_to_restore"; fi
}
on_exit(){
  rc=$?
  set +e
  rmc "$CANARY"
  if [ $rc -ne 0 ] && [ "$CUTOVER" -eq 1 ]; then rollback; fi
  if [ $rc -ne 0 ]; then log "DEPLOY_FAILED rc=$rc log=$RUN_DIR/deploy.log"; fi
  exit $rc
}
trap on_exit EXIT

log "[0/13] GREENFIELD FRESH-INSTALL $RELEASE"
log "BASE=$BASE"

log "[1/13] Validate exact release artifacts and archive"
[ -f "$SCRIPT_DIR/Dockerfile" ] || die "Dockerfile missing"
[ -f "$SCRIPT_DIR/$SRC_NAME" ] || die "$SRC_NAME missing"
REAL_SRC="$(sha256sum "$SCRIPT_DIR/$SRC_NAME" | awk '{print $1}')"
REAL_DF="$(sha256sum "$SCRIPT_DIR/Dockerfile" | awk '{print $1}')"
[ "$REAL_SRC" = "$EXPECTED_SRC_SHA" ] || die "SOURCE SHA mismatch expected=$EXPECTED_SRC_SHA actual=$REAL_SRC"
[ "$REAL_DF" = "$EXPECTED_DF_SHA" ] || die "Dockerfile SHA mismatch expected=$EXPECTED_DF_SHA actual=$REAL_DF"
cp "$SCRIPT_DIR/Dockerfile" "$RUN_DIR/build/Dockerfile"
cp "$SCRIPT_DIR/$SRC_NAME" "$RUN_DIR/build/$SRC_NAME"
python3 - "$RUN_DIR/build/$SRC_NAME" "$RUN_DIR/source" <<'PY'
import pathlib,sys,tarfile
src=pathlib.Path(sys.argv[1]); out=pathlib.Path(sys.argv[2])
with tarfile.open(src,'r:gz') as t:
    names=set()
    for m in t.getmembers():
        p=pathlib.PurePosixPath(m.name)
        if p.is_absolute() or '..' in p.parts or not (m.isfile() or m.isdir()) or str(p) in names:
            raise SystemExit('unsafe archive member: '+m.name)
        names.add(str(p))
    t.extractall(out,filter='data')
for req in ['requirements-runtime.txt','pulse_edge/main.py','pulse_edge/config.py','pulse_edge/models.py','pulse_edge/feed/kiwoom.py','pulse_edge/engine/features.py','pulse_edge/engine/scorer.py','pulse_edge/engine/coiled.py','pulse_edge/storage/baseline.py','pulse_edge/storage/signals.py','pulse_edge/web/index.html','pulse_edge/web/pulse.js','pulse_edge/web/sw.js','deploy/offline_tests.py','deploy/verify.py']:
    if not (out/req).is_file(): raise SystemExit('archive missing '+req)
print('ARCHIVE_PASS files='+str(len(names)))
PY
LEGACY_TOKEN="$(printf '\116\117\126\101')"
if grep -RniI --exclude='README.txt' -w "$LEGACY_TOKEN" "$RUN_DIR/source" >/dev/null; then die "legacy executable/source token found"; fi
python3 -m compileall -q "$RUN_DIR/source/pulse_edge" "$RUN_DIR/source/deploy"
if command -v node >/dev/null 2>&1; then node --check "$RUN_DIR/source/pulse_edge/web/pulse.js"; node --check "$RUN_DIR/source/pulse_edge/web/sw.js"; fi

log "[2/13] Direct credential env + non-secret runtime overrides"
CRED_SOURCE="$ENV_SOURCE"
[ -s "$CRED_SOURCE" ] || die "credential source missing: $ENV_SOURCE"
python3 - "$CRED_SOURCE" "$ENV_FILE" <<'PYDIRECT'
import pathlib,sys,os
src=pathlib.Path(sys.argv[1]); dst=pathlib.Path(sys.argv[2])
raw=src.read_bytes()
present=set()
for physical in raw.splitlines():
    stripped=physical.lstrip()
    if not stripped or stripped.startswith(b'#') or b'=' not in stripped:
        continue
    key,val=stripped.split(b'=',1); key=key.strip()
    if key in (b'PULSE_KIWOOM_APPKEY',b'PULSE_KIWOOM_SECRETKEY') and val.strip():
        present.add(key)
for req in (b'PULSE_KIWOOM_APPKEY',b'PULSE_KIWOOM_SECRETKEY'):
    if req not in present:
        raise SystemExit('Kiwoom credentials missing from direct env source')
fixed={
'PULSE_RELEASE':'3.8.16_REALTIME_HIDDEN_GEM','PULSE_FEED_ENABLED':'true','PULSE_DATA_DIR':'/app/data/pulse_edge',
'PULSE_BASELINE_DB':'/app/data/pulse_edge/tod_baseline.sqlite3','PULSE_HISTORY_DB':'/app/data/pulse_edge/signal_history.sqlite3','PULSE_HISTORY_LIMIT':'400','PULSE_NOW_HISTORY_LIMIT':'200','PULSE_COILED_HISTORY_LIMIT':'200',
'PULSE_PUSH_ENABLED':'true','PULSE_WS_DYNAMIC_MAX_ITEMS':'34','PULSE_WS_BACKGROUND_RESERVE_ITEMS':'14','PULSE_WS_QUOTE_FOCUS_ITEMS':'4','PULSE_PRIORITY_IDLE_SEC':'600','PULSE_DISCOVERY_NEW_SEC':'180','PULSE_DISCOVERY_FRESH_SLOTS':'6','PULSE_LATENCY_SAMPLE_SIZE':'300','PULSE_EVENT_LOOP_PROBE_SEC':'0.5','PULSE_PROBE_REST_CONFIRM_MIN_SCORE':'60','PULSE_PROBE_REST_CONFIRM_COOLDOWN_SEC':'20','PULSE_URGENT_BASELINE_MIN_SCORE':'60','PULSE_URGENT_BASELINE_COOLDOWN_SEC':'20','PULSE_QUOTE_NEWCOMER_SLOTS':'2','PULSE_ZERO_TRADE_MINUTE_COVERAGE_SAMPLES':'45','PULSE_BID_ABSORPTION_MIN_SCORE':'60','PULSE_BID_ABSORPTION_WINDOW_SEC':'90','PULSE_BID_ABSORPTION_ABS_FLOOR_KRW':'5000000','PULSE_BID_ABSORPTION_SELL_RATIO_MIN':'0.20','PULSE_EARLY_ABSORPTION_MIN_OBSERVED_SEC':'180','PULSE_EARLY_HIDDEN_GEM_MIN_SCORE':'60','PULSE_EARLY_HIDDEN_GEM_CHANGE_MIN':'-1.5','PULSE_EARLY_HIDDEN_GEM_CHANGE_MAX':'2.5','PULSE_MODEL_A2_ABSORB_RATIO_MIN':'0.75',
'PULSE_RANK_COMMIT_SEC':'30','PULSE_BACKGROUND_ROTATE_SEC':'4','PULSE_SCAN_INTERVAL_SEC':'20','PULSE_INVESTOR_REFRESH_SEC':'20','PULSE_DAILY_CONTEXT_REFRESH_SEC':'120','PULSE_DAILY_CONTEXT_SYMBOLS':'20','PULSE_COILED_REFRESH_SEC':'60','PULSE_COILED_SEED_LIMIT':'30','PULSE_COILED_TOP_LIMIT':'5','PULSE_BASELINE_BOOTSTRAP_INTERVAL_SEC':'60','PULSE_BASELINE_BOOTSTRAP_SYMBOLS_PER_CYCLE':'2','PULSE_SUPPLY_TIGHT_MIN_CONDITIONS':'8','PULSE_SUPPLY_EXHAUSTION_MIN_SIGNALS':'7','PULSE_IGNITION_TRIGGER_MIN_COUNT':'2'}
out=''.join(f'{k}={v}\n' for k,v in fixed.items())
tmp=dst.with_name(dst.name+'.tmp-'+str(os.getpid()))
tmp.write_text(out); tmp.chmod(0o600); os.replace(tmp,dst)
print('KIWOOM_DIRECT_ENV_SOURCE=PASS')
print('KIWOOM_CREDENTIAL_REWRITE=NONE')
PYDIRECT
FREE_KB="$(df -Pk "$BASE" | awk 'NR==2{print $4}')"; [ "$FREE_KB" -ge 716800 ] || die "disk free below 700MB"
python3 - <<'PY'
mem={}
for l in open('/proc/meminfo'):
    if ':' in l:
        k,v=l.split(':',1); mem[k]=int(v.split()[0])
avail=mem.get('MemAvailable',0)+mem.get('SwapFree',0)
assert avail>=358400, f'RAM+swap headroom below 350MB: {avail}KB'
print('RESOURCE_PASS available_plus_swap_kb='+str(avail))
PY
docker info >/dev/null || die "Docker unavailable"
docker network inspect "$NET" >/dev/null || die "network missing: $NET"
running "$CADDY" || die "Caddy not running: $CADDY"
CADDY_IP="$(container_ip "$CADDY")"; [ -n "$CADDY_IP" ] || die "Caddy is not attached to network $NET: $CADDY"
log "CADDY_NETWORK_PASS ip=$CADDY_IP"

alias_owners(){
  local c
  while IFS= read -r c; do
    [ -n "$c" ] || continue
    docker inspect "$c" --format '{{json .NetworkSettings.Networks}}' 2>/dev/null | python3 -c 'import json,sys; d=json.load(sys.stdin); n=sys.argv[1]; sys.exit(0 if "pulse-edge" in ((d.get(n) or {}).get("Aliases") or []) else 1)' "$NET" >/dev/null 2>&1 && echo "$c"
  done < <(docker ps -a --format '{{.Names}}')
}
mapfile -t ALIAS_OWNERS < <(alias_owners)
[ "${#ALIAS_OWNERS[@]}" -le 1 ] || die "multiple pulse-edge network alias owners: ${ALIAS_OWNERS[*]}"
OLD="${ALIAS_OWNERS[0]:-}"
if [ -n "$OLD" ]; then
  OLD_RUNNING="$(docker inspect -f '{{.State.Running}}' "$OLD")"; OLD_RESTART="$(docker inspect -f '{{.HostConfig.RestartPolicy.Name}}' "$OLD")"
  log "OPTIONAL_PREVIOUS_ROUTE_OWNER=$OLD running=$OLD_RUNNING restart=$OLD_RESTART"
else
  log "FRESH_INSTALL_MODE no_previous_route_owner"
fi
mapfile -t FEED_ON < <(docker ps --format '{{.Names}}' | while read -r c; do docker inspect "$c" --format '{{range .Config.Env}}{{println .}}{{end}}' 2>/dev/null | grep -qx 'PULSE_FEED_ENABLED=true' && echo "$c"; done | grep '^pulse-edge' || true)
[ "${#FEED_ON[@]}" -le 1 ] || die "multiple pre-existing Feed-ON containers: ${FEED_ON[*]}"
if [ "${#FEED_ON[@]}" -eq 1 ]; then
  [ -n "$OLD" ] || die "stray Feed-ON container exists without pulse-edge route alias: ${FEED_ON[0]}"
  [ "${FEED_ON[0]}" = "$OLD" ] || die "Feed-ON container is not route owner: ${FEED_ON[0]} vs $OLD"
fi

log "[3/13] Docker build + embedded offline tests"
if docker image inspect python:3.12-slim >/dev/null 2>&1; then log "BASE_IMAGE_LOCAL_PASS python:3.12-slim"; else
  ok=0; for n in 1 2 3 4 5; do if docker pull python:3.12-slim; then ok=1; break; fi; sleep $((n*5)); done; [ "$ok" -eq 1 ] || die "cannot obtain python:3.12-slim"
fi
(cd "$RUN_DIR/build" && DOCKER_BUILDKIT=0 docker build --pull=false -t "$IMG" .)
docker run --rm --network none -e PULSE_FEED_ENABLED=false "$IMG" python -m deploy.offline_tests

log "[3.5/13] Secret-safe Kiwoom OAuth + REST preflight"
docker run --rm -i --network "$NET" --env-file "$CRED_SOURCE" --env-file "$ENV_FILE" "$IMG" python - <<'PYKIWOOM'
import asyncio, sys
import httpx
from pulse_edge.config import Settings
from pulse_edge.feed.kiwoom import Auth, Rest

async def main():
    s=Settings()
    if not s.kiwoom_appkey or not s.kiwoom_secretkey:
        print('KIWOOM_ENV_READ=FAIL')
        return 20
    print('KIWOOM_ENV_READ=PASS')
    auth=Auth(s.kiwoom_rest_base,s.kiwoom_appkey,s.kiwoom_secretkey)
    rest=None
    try:
        try:
            await auth.token()
        except httpx.HTTPStatusError as e:
            print('KIWOOM_OAUTH=FAIL HTTP_STATUS='+str(e.response.status_code))
            return 21
        except Exception as e:
            print('KIWOOM_OAUTH=FAIL ERROR_TYPE='+type(e).__name__)
            return 22
        print('KIWOOM_OAUTH=PASS')
        rest=Rest(s.kiwoom_rest_base,auth)
        try:
            body,_=await rest.post('ka10099','/api/dostk/stkinfo',{'mrkt_tp':'0'})
            rows=body.get('list') or []
            if not isinstance(rows,list):
                print('KIWOOM_REST=FAIL CONTRACT')
                return 23
            print('KIWOOM_REST=PASS')
        except httpx.HTTPStatusError as e:
            print('KIWOOM_REST=FAIL HTTP_STATUS='+str(e.response.status_code))
            return 24
        except Exception as e:
            print('KIWOOM_REST=FAIL ERROR_TYPE='+type(e).__name__)
            return 25
        return 0
    finally:
        if rest is not None:
            await rest.close()
        await auth.close()

raise SystemExit(asyncio.run(main()))
PYKIWOOM
if ! grep -q '^PULSE_VAPID_PRIVATE_KEY=' "$CRED_SOURCE" || ! grep -q '^PULSE_VAPID_PUBLIC_KEY=' "$CRED_SOURCE"; then
  docker run --rm --network none -e PULSE_PUBLIC_URL="$PUB" "$IMG" python -m pulse_edge.generate_vapid >>"$ENV_FILE"; chmod 600 "$ENV_FILE"; log "VAPID_KEYS_GENERATED_IN_RUNTIME_OVERRIDE"
fi
if [ "$MODE" = --preflight ]; then log "PREFLIGHT_PASS"; SUCCESS=1; trap - EXIT; exit 0; fi

log "[4/13] Feed-OFF canary with isolated writable data"
docker run -d --name "$CANARY" --restart=no --network "$NET" --env-file "$CRED_SOURCE" --env-file "$ENV_FILE" -e PULSE_FEED_ENABLED=false --mount "type=bind,src=$CANARY_DATA,dst=/app/data" "$IMG" >/dev/null
CIP="$(container_ip "$CANARY")"; [ -n "$CIP" ] || die "canary IP missing"; CURL="http://$CIP:8000"
ready=0
for i in $(seq 1 90); do
  code="$(curl -sS -o "$RUN_DIR/canary-ready.json" -w '%{http_code}' --max-time 4 "$CURL/api/readiness" 2>/dev/null || true)"
  if [ "$code" = 200 ]; then python3 - "$RUN_DIR/canary-ready.json" <<'PY' && ready=1 && break || true
import json,sys
q=json.load(open(sys.argv[1])); assert q['release']=='3.8.16_REALTIME_HIDDEN_GEM' and q['ready'] is True and q['feed_enabled'] is False
PY
  fi
  running "$CANARY" || { docker logs --tail 100 "$CANARY" || true; die "canary stopped"; }; sleep 1
done
[ "$ready" -eq 1 ] || die "canary readiness failed"
python3 "$RUN_DIR/source/deploy/verify.py" "$CURL"

log "[5/13] Feed-OFF canary responsiveness 60 seconds"
for i in $(seq 1 12); do
  curl -fsS --max-time 4 "$CURL/health" >/dev/null
  curl -fsS --max-time 4 "$CURL/api/readiness" >/dev/null
  curl -fsS --max-time 5 "$CURL/api/signal-history?limit=3" >/dev/null
  curl -fsS --max-time 5 "$CURL/api/push/public-key" >/dev/null
  curl -fsS --max-time 5 "$CURL/" >/dev/null
  sleep 5
done
rmc "$CANARY"

log "[6/13] Prepare cutover; previous runtime is OPTIONAL, never required"
CUTOVER=1
if [ -n "$OLD" ]; then stopc "$OLD" || die "cannot stop old route owner"; docker network disconnect -f "$NET" "$OLD" >/dev/null 2>&1 || true; fi

log "[7/13] Start singleton Feed-ON live"
docker run -d --name "$LIVE" --restart=unless-stopped --network "$NET" --network-alias pulse-edge --env-file "$CRED_SOURCE" --env-file "$ENV_FILE" -e PULSE_FEED_ENABLED=true --mount "type=bind,src=$DATA_DIR,dst=/app/data" "$IMG" >/dev/null
LIP="$(container_ip "$LIVE")"; [ -n "$LIP" ] || die "live IP missing"; LURL="http://$LIP:8000"

log "[8/13] Live readiness: require live ticks only when an active venue exists"
ready=0
for i in $(seq 1 180); do
  code="$(curl -sS -o "$RUN_DIR/live-ready.json" -w '%{http_code}' --max-time 4 "$LURL/api/readiness" 2>/dev/null || true)"
  if [ "$code" = 200 ] || [ "$code" = 503 ]; then
    readiness_acceptable "$RUN_DIR/live-ready.json" "$code" && ready=1 && break || true
  fi
  running "$LIVE" || { docker logs --tail 150 "$LIVE" || true; die "live stopped"; }; sleep 1
done
[ "$ready" -eq 1 ] || { cat "$RUN_DIR/live-ready.json" 2>/dev/null || true; die "live readiness failed"; }
feedon_contract "$LURL"

# On closed sessions, prove that the 1-2D pipeline actually ran against a non-empty
# after-close seed set. Candidate rows may legitimately be zero after scoring filters.
if python3 - "$RUN_DIR/live-ready.json" <<'PY'
import json,sys
q=json.load(open(sys.argv[1])); raise SystemExit(0 if q.get('active_venue') is None else 1)
PY
then
  closed_ok=0
  for i in $(seq 1 180); do
    if curl -fsS --max-time 6 "$LURL/health" >"$RUN_DIR/closed-coiled-health.json" 2>/dev/null; then
      closed_coiled_pipeline_acceptable "$RUN_DIR/closed-coiled-health.json" && closed_ok=1 && break || true
    fi
    running "$LIVE" || die "live stopped while waiting for closed-session 1-2D pipeline"
    sleep 1
  done
  [ "$closed_ok" -eq 1 ] || { cat "$RUN_DIR/closed-coiled-health.json" 2>/dev/null || true; die "closed-session 1-2D pipeline failed to establish seeds/daily context"; }
  curl -fsS --max-time 6 "$LURL/api/coiled-spring/top?limit=5" >"$RUN_DIR/closed-coiled-top.json"
  python3 - "$RUN_DIR/closed-coiled-top.json" <<'PY'
import json,sys
q=json.load(open(sys.argv[1])); assert q.get('release')=='3.8.16_REALTIME_HIDDEN_GEM' and isinstance(q.get('rows'),list),q
print('CLOSED_COILED_ENDPOINT_PASS source='+str(q.get('source'))+' rows='+str(len(q.get('rows') or [])))
PY
fi

log "[9/13] Caddy route and certificate-valid public HTTPS"
docker exec "$CADDY" sh -c '
  if command -v wget >/dev/null 2>&1; then
    wget -q -T 8 -O - http://pulse-edge:8000/health
  elif command -v curl >/dev/null 2>&1; then
    curl -fsS --max-time 8 http://pulse-edge:8000/health
  elif command -v busybox >/dev/null 2>&1; then
    busybox wget -q -T 8 -O - http://pulse-edge:8000/health
  else
    exit 127
  fi
' >"$RUN_DIR/caddy-health.json" || die "Caddy container cannot resolve/reach pulse-edge:8000 or lacks an HTTP client"
python3 - "$RUN_DIR/caddy-health.json" <<'PY'
import json,sys
h=json.load(open(sys.argv[1])); assert h.get('runtime_safety_release')=='3.8.16_REALTIME_HIDDEN_GEM'
PY
public=0
for i in $(seq 1 20); do
  # Deliberately no -k: deployment must prove a valid HTTPS certificate.
  if curl -fsS --max-time 8 "$PUB/health" >"$RUN_DIR/public-health.json" 2>/dev/null && curl -fsS --max-time 8 "$PUB/" >/dev/null 2>&1; then public=1; break; fi
  sleep 3
done
[ "$public" -eq 1 ] || die "public HTTPS/certificate did not validate"

log "[10/13] Two-minute public warmup"
for i in 1 2 3 4; do curl -fsS --max-time 8 "$PUB/health" >/dev/null; sleep 30; done

log "[11/13] Ten-minute responsiveness + CPU/memory/disk guard"
BAD=0
for i in $(seq 1 20); do
  b=0
  curl -fsS --max-time 6 "$LURL/health" >"$RUN_DIR/health-$i.json" || b=1
  if [ "$b" -eq 0 ]; then
    python3 - "$RUN_DIR/health-$i.json" "$i" <<'PY' || b=1
import json,sys
from pathlib import Path
q=json.load(open(sys.argv[1])); idx=int(sys.argv[2])
assert q.get('ok') is True, q
assert int(q.get('eval_seq') or 0)>0, q
assert q.get('last_eval_ts') is not None, q
if idx>1:
    prev_path=Path(sys.argv[1]).with_name(f'health-{idx-1}.json')
    if prev_path.exists():
        prev=json.load(open(prev_path))
        assert int(q.get('eval_seq') or 0) > int(prev.get('eval_seq') or 0), (prev,q)
        assert float(q.get('last_eval_ts') or 0) > float(prev.get('last_eval_ts') or 0), (prev,q)
lat=q.get('latency') or {}
if idx>=3:
    assert lat.get('event_loop_lag_ms_p95') is not None, lat
    assert lat.get('evaluate_ms_p95') is not None, lat
    assert float(lat.get('event_loop_lag_ms_p95') or 0) < 500.0, lat
    assert float(lat.get('evaluate_ms_p95') or 0) < 800.0, lat
if q.get('active_venue'):
    assert q.get('ws_connected') is True, q
    age=q.get('ws_last_message_age_sec')
    assert age is not None and float(age)<=30.0, q
PY
  fi
  curl -fsS --max-time 6 "$LURL/api/hidden-gem/top?limit=3" >/dev/null || b=1
  curl -fsS --max-time 6 "$LURL/api/coiled-spring/top?limit=5" >/dev/null || b=1
  curl -fsS --max-time 6 "$LURL/api/signal-history?limit=3" >/dev/null || b=1
  curl -fsS --max-time 6 "$LURL/api/push/public-key" >/dev/null || b=1
  curl -fsS --max-time 8 "$PUB/" >/dev/null || b=1
  ST="$(docker stats --no-stream --format '{{.CPUPerc}} {{.MemPerc}}' "$LIVE" 2>/dev/null || true)"; [ -n "$ST" ] || b=1
  if [ -n "$ST" ]; then
    CPU="${ST%% *}"; MEM="${ST##* }"; CPU="${CPU%%%}"; MEM="${MEM%%%}"
    python3 - "$CPU" "$MEM" <<'PY' || b=1
import sys
cpu=float(sys.argv[1]); mem=float(sys.argv[2])
assert cpu<90.0, f'CPU guard {cpu}%'
assert mem<85.0, f'MEM guard {mem}%'
PY
  fi
  FREE_NOW="$(df -Pk "$BASE" | awk 'NR==2{print $4}')"; [ "$FREE_NOW" -ge 307200 ] || b=1
  log "LIVE_CHECK=$i bad=$b stats=$ST free_kb=$FREE_NOW"
  [ "$b" -eq 0 ] && BAD=0 || BAD=$((BAD+1))
  [ "$BAD" -lt 3 ] || die "three consecutive health/resource checks failed"
  sleep 30
done
[ "$BAD" -eq 0 ] || die "last live check failed"
python3 - "$RUN_DIR/health-1.json" "$RUN_DIR/health-20.json" <<'PY'
import json,sys
a=json.load(open(sys.argv[1])); b=json.load(open(sys.argv[2]))
assert int(b.get('eval_seq') or 0)>int(a.get('eval_seq') or 0), (a,b)
if b.get('active_venue'):
    ta=a.get('latest_trade_event_ts'); tb=b.get('latest_trade_event_ts')
    assert ta is not None and tb is not None and float(tb)>float(ta), (ta,tb)
if (a.get('candidate_count') or 0)>0 and a.get('candidate_fingerprint')==b.get('candidate_fingerprint'):
    print('SOAK_WARN candidate fingerprint unchanged across soak; engine/trade progression still verified')
print('SOAK_PROGRESS_PASS',a.get('eval_seq'),b.get('eval_seq'),a.get('latest_trade_event_ts'),b.get('latest_trade_event_ts'))
PY

log "[12/13] Final singleton, readiness, fresh-install viability and public contract"
mapfile -t FINAL_FEEDS < <(docker ps --format '{{.Names}}' | while read -r c; do docker inspect "$c" --format '{{range .Config.Env}}{{println .}}{{end}}' 2>/dev/null | grep -qx 'PULSE_FEED_ENABLED=true' && echo "$c"; done | grep '^pulse-edge' || true)
[ "${#FINAL_FEEDS[@]}" -eq 1 ] || die "Feed-ON singleton mismatch: ${FINAL_FEEDS[*]}"
[ "${FINAL_FEEDS[0]}" = "$LIVE" ] || die "unexpected Feed-ON owner: ${FINAL_FEEDS[0]}"
exists "$LIVE" || die "live container disappeared"
if [ -n "$OLD" ]; then exists "$OLD" || die "optional previous container disappeared unexpectedly"; fi
feedon_contract "$PUB"

log "[13/13] DEPLOY_PASS"
touch "$RUN_DIR/deploy-passed"; CUTOVER=0; SUCCESS=1
trap - EXIT
log "ACTIVE=$LIVE"
log "PUBLIC=$PUB"
log "LOG=$RUN_DIR/deploy.log"
