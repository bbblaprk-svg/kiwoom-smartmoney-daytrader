#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

REPO="bbblaprk-svg/kiwoom-smartmoney-daytrader"
BRANCH="main"
APP="${NOVA_APP_CONTAINER:-quant-nova}"
REMOTE_SOURCE="QUANT_NOVA_3.3.6_R493_FULL_SOURCE_20260822.tar.gz"
EXPECTED_SOURCE_SHA="b74cde0bd7c239e60e3ef3cc8b3df04280dc5714b195ea3ddbfb73e4f6ff9da9"
EXPECTED_TREE_SHA="3d47ea82ca1757394e24eb956e7fcbc346f6b2b813a0c08a62fbbb9a1fde752c"
EXPECTED_FILE_COUNT=142
EXPECTED_VERSION="NOVA-3.3.6-R493-MARKET-RELATIVE-SAFE"
EXPECTED_DEPLOY_MODEL="FULL_SOURCE_ARCHIVE_BUILD"
BASELINE_R492="NOVA-3.3.5-R492-FRESH-ENERGY-PATH-SAFE"
BASELINE_R491="NOVA-3.3.4-MARKET-WIDE-ROTATION-VERIFY"
IMAGE="quant-nova:3.3.6-r493-full-source-local"
STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP="${APP}-pre-r493-${STAMP}"
CANDIDATE="${APP}-candidate-r493full-${STAMP}"
WORK="$(mktemp -d /tmp/nova-r493-full.XXXXXX)"
ARCHIVE="$WORK/source.tar.gz"
SRC="$WORK/src"
ENVFILE="$WORK/current.env"
CAND_DATA="$WORK/candidate-data"
LOG="/tmp/nova-r493-full-deploy-${STAMP}.log"
LOCKFILE="/tmp/nova-r493-full-deploy.lock"
OLD_WAS_RUNNING=0
OLD_STOPPED=0
OLD_RENAMED=0
NEW_STARTED=0
CAND_STARTED=0
STATE_MUTATED=0
PROTECTED_SNAPSHOT_READY=0

exec 9>"$LOCKFILE"
if ! flock -n 9; then
  echo "INFO: R493 FULL SOURCE deploy is already running in another terminal."
  exit 0
fi

if docker info >/dev/null 2>&1; then DOCKER=(docker)
elif sudo -n docker info >/dev/null 2>&1; then DOCKER=(sudo docker)
else echo "FAIL: Docker 권한을 확인할 수 없습니다."; exit 2
fi
dc(){ "${DOCKER[@]}" "$@"; }
say(){ printf '\n===== %s =====\n' "$*" | tee -a "$LOG"; }
cleanup(){ rm -rf -- "$WORK" 2>/dev/null || true; }
wait_health(){
  local name="$1" i status
  for i in $(seq 1 72); do
    status="$(dc inspect "$name" --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' 2>/dev/null || true)"
    [ "$status" = "healthy" ] && return 0
    sleep 5
  done
  return 1
}
image_version(){
  local name="$1" iid
  iid="$(dc inspect "$name" --format '{{.Image}}' 2>/dev/null || true)"
  [ -n "$iid" ] || return 0
  dc image inspect "$iid" --format '{{index .Config.Labels "org.opencontainers.image.version"}}' 2>/dev/null || true
}
image_label(){
  local name="$1" key="$2" iid
  iid="$(dc inspect "$name" --format '{{.Image}}' 2>/dev/null || true)"
  [ -n "$iid" ] || return 0
  dc image inspect "$iid" --format "{{index .Config.Labels \"$key\"}}" 2>/dev/null || true
}
protected_snapshot(){
  for name in nova-http-guard caddy nova-caddy kiwoom-caddy; do
    if dc inspect "$name" >/dev/null 2>&1; then printf '%s=%s\n' "$name" "$(dc inspect "$name" --format '{{.Id}}')"; fi
  done | sort
}
verify_protected(){
  [ "$PROTECTED_SNAPSHOT_READY" -eq 1 ] || return 0
  [ -f "$WORK/protected.before" ] || return 0
  [ "$(cat "$WORK/protected.before")" = "$(protected_snapshot)" ] || { echo "FAIL: Guard/Caddy 컨테이너가 변경됐습니다." | tee -a "$LOG"; return 1; }
}
fetch_source(){
  local raw="https://raw.githubusercontent.com/${REPO}/${BRANCH}/${REMOTE_SOURCE}"
  if curl -fsSL --max-time 60 "$raw" -o "$ARCHIVE" 2>/dev/null; then return 0; fi
  local token="${GH_TOKEN:-${GITHUB_TOKEN:-}}"
  if [ -z "$token" ]; then
    printf '\nGitHub Private 저장소이면 Contents: Read 권한 token을 입력하세요.\n' >&2
    read -rsp 'GitHub token: ' token
    printf '\n' >&2
  fi
  [ -n "$token" ] || return 1
  curl -fsSL --max-time 90 \
    -H 'Accept: application/vnd.github.raw+json' \
    -H "Authorization: Bearer ${token}" \
    -H 'X-GitHub-Api-Version: 2026-03-10' \
    "https://api.github.com/repos/${REPO}/contents/${REMOTE_SOURCE}?ref=${BRANCH}" \
    -o "$ARCHIVE"
  unset token GH_TOKEN GITHUB_TOKEN 2>/dev/null || true
}
rollback(){
  local rc=$?
  trap - ERR INT TERM EXIT
  if [ "$STATE_MUTATED" -eq 0 ]; then
    cleanup
    echo "RESULT=ABORTED_NO_CHANGE CURRENT=$APP LOG=$LOG" | tee -a "$LOG"
    exit "${rc:-1}"
  fi
  say "AUTO ROLLBACK -> PRE-DEPLOY CONTAINER"
  if [ "$CAND_STARTED" -eq 1 ] && dc inspect "$CANDIDATE" >/dev/null 2>&1; then dc rm -f "$CANDIDATE" >/dev/null 2>&1 || true; fi
  if [ "$NEW_STARTED" -eq 1 ] && dc inspect "$APP" >/dev/null 2>&1; then
    dc logs --tail 250 "$APP" >>"$LOG" 2>&1 || true
    dc rm -f "$APP" >/dev/null 2>&1 || true
  fi
  if [ "$OLD_RENAMED" -eq 1 ] && dc inspect "$BACKUP" >/dev/null 2>&1; then
    dc rename "$BACKUP" "$APP" >/dev/null 2>&1 || true
    [ "$OLD_WAS_RUNNING" -eq 1 ] && dc start "$APP" >/dev/null 2>&1 || true
    [ "$OLD_WAS_RUNNING" -eq 1 ] && wait_health "$APP" || true
  elif [ "$OLD_STOPPED" -eq 1 ] && dc inspect "$APP" >/dev/null 2>&1; then
    [ "$OLD_WAS_RUNNING" -eq 1 ] && dc start "$APP" >/dev/null 2>&1 || true
    [ "$OLD_WAS_RUNNING" -eq 1 ] && wait_health "$APP" || true
  fi
  verify_protected || true
  cleanup
  echo "RESULT=ROLLED_BACK CURRENT=$APP RESTORED_VERSION=$(image_version "$APP") LOG=$LOG" | tee -a "$LOG"
  exit "${rc:-1}"
}
trap rollback ERR INT TERM EXIT

say "1/9 FETCH FULL SOURCE ARCHIVE + SHA LOCK"
fetch_source
ACTUAL_SOURCE_SHA="$(sha256sum "$ARCHIVE" | awk '{print $1}')"
echo "SOURCE_ARCHIVE_SHA256=$ACTUAL_SOURCE_SHA" | tee -a "$LOG"
[ "$ACTUAL_SOURCE_SHA" = "$EXPECTED_SOURCE_SHA" ] || { echo "FAIL: GitHub source archive SHA mismatch"; exit 1; }

say "1A/9 FULL SOURCE PREFLIGHT (CURRENT APP UNTOUCHED)"
gzip -t "$ARCHIVE"
# reject absolute/traversal paths before extract
if tar -tzf "$ARCHIVE" | grep -Eq '(^/|(^|/)\.\.(/|$))'; then echo "FAIL: unsafe path in source archive"; exit 1; fi
mkdir -p "$SRC"
tar -xzf "$ARCHIVE" -C "$SRC"
cd "$SRC"
FILE_COUNT="$(find . -type f ! -path '*/__pycache__/*' ! -name '*.pyc' | wc -l | tr -d ' ')"
[ "$FILE_COUNT" -eq "$EXPECTED_FILE_COUNT" ] || { echo "FAIL: source file count $FILE_COUNT != $EXPECTED_FILE_COUNT"; exit 1; }
TREE_SHA="$(sha256sum SOURCE_MANIFEST.sha256 | awk '{print $1}')"
[ "$TREE_SHA" = "$EXPECTED_TREE_SHA" ] || { echo "FAIL: SOURCE_MANIFEST SHA mismatch"; exit 1; }
sha256sum -c SOURCE_MANIFEST.sha256 >/dev/null
for f in Dockerfile app/main.py app/service.py app/broker/market_index.py app/addons/market_relative.py scripts/master_audit.py scripts/r493_market_relative_acceptance.py; do [ -f "$f" ] || { echo "FAIL: missing $f"; exit 1; }; done
grep -Fq "org.opencontainers.image.version=\"$EXPECTED_VERSION\"" Dockerfile
grep -Fq "io.quantnova.deploy_model=\"$EXPECTED_DEPLOY_MODEL\"" Dockerfile
grep -Fq "API_ID = 'ka20001'" app/broker/market_index.py
grep -Fq "API_PATH = '/api/dostk/sect'" app/broker/market_index.py
if command -v python3 >/dev/null 2>&1; then
  python3 -m py_compile app/broker/market_index.py app/addons/market_relative.py app/service.py app/addons/decision_panels.py
fi
echo "FULL_SOURCE_PREFLIGHT=PASS files=$FILE_COUNT tree_sha=$TREE_SHA" | tee -a "$LOG"

say "2/9 SNAPSHOT CURRENT APP + GUARD/CADDY"
dc inspect "$APP" >/dev/null
CURRENT_VERSION="$(image_version "$APP")"
CURRENT_DEPLOY_MODEL="$(image_label "$APP" io.quantnova.deploy_model)"
echo "current_version=${CURRENT_VERSION:-UNKNOWN} current_deploy_model=${CURRENT_DEPLOY_MODEL:-UNKNOWN}" | tee -a "$LOG"
if [ "$CURRENT_VERSION" = "$EXPECTED_VERSION" ] && [ "$CURRENT_DEPLOY_MODEL" = "$EXPECTED_DEPLOY_MODEL" ]; then
  echo "INFO: exact FULL SOURCE R493 already deployed; health/acceptance only." | tee -a "$LOG"
  wait_health "$APP"
  dc exec "$APP" env PYTHONPATH=/app python /app/scripts/r493_market_relative_acceptance.py | tee -a "$LOG"
  trap - ERR INT TERM EXIT
  cleanup
  echo "RESULT=ALREADY_DEPLOYED VERSION=$EXPECTED_VERSION CURRENT=$APP LOG=$LOG"
  exit 0
fi
case "$CURRENT_VERSION" in
  "$BASELINE_R492"|"$BASELINE_R491"|"$EXPECTED_VERSION") ;;
  *) echo "FAIL: current version $CURRENT_VERSION is not approved R492/R491/R493; no change" | tee -a "$LOG"; exit 1 ;;
esac
[ "$(dc inspect "$APP" --format '{{.State.Running}}')" = "true" ] && OLD_WAS_RUNNING=1 || true
dc inspect "$APP" --format '{{range .Config.Env}}{{println .}}{{end}}' > "$ENVFILE"
protected_snapshot > "$WORK/protected.before"
PROTECTED_SNAPSHOT_READY=1
NETWORK_MODE="$(dc inspect "$APP" --format '{{.HostConfig.NetworkMode}}' | xargs)"
mapfile -t NETWORKS < <(dc inspect "$APP" --format '{{range $name, $_ := .NetworkSettings.Networks}}{{println $name}}{{end}}' | awk 'NF' | sort -u)
case "$NETWORK_MODE" in
  host|none|container:*) PRIMARY_NETWORK="$NETWORK_MODE" ;;
  default|"") if [ "${#NETWORKS[@]}" -gt 0 ]; then PRIMARY_NETWORK="${NETWORKS[0]}"; else PRIMARY_NETWORK="bridge"; fi ;;
  *) if [ "${#NETWORKS[@]}" -gt 0 ]; then PRIMARY_NETWORK="${NETWORKS[0]}"; else PRIMARY_NETWORK="$NETWORK_MODE"; fi ;;
esac
[ -n "$PRIMARY_NETWORK" ] || { echo "FAIL: unable to resolve Docker network"; exit 1; }
RESTART="$(dc inspect "$APP" --format '{{.HostConfig.RestartPolicy.Name}}')"; [ -n "$RESTART" ] || RESTART=unless-stopped
USER_SPEC="$(dc inspect "$APP" --format '{{.Config.User}}')"
READONLY="$(dc inspect "$APP" --format '{{.HostConfig.ReadonlyRootfs}}')"
MEMORY="$(dc inspect "$APP" --format '{{.HostConfig.Memory}}')"
MEMSWAP="$(dc inspect "$APP" --format '{{.HostConfig.MemorySwap}}')"
MEMRES="$(dc inspect "$APP" --format '{{.HostConfig.MemoryReservation}}')"
PIDSLIMIT="$(dc inspect "$APP" --format '{{.HostConfig.PidsLimit}}')"
MOUNT_ARGS=()
while IFS='|' read -r TYPE SOURCE DEST RW NAME; do
  TYPE="$(xargs <<<"$TYPE")"; SOURCE="$(xargs <<<"$SOURCE")"; DEST="$(xargs <<<"$DEST")"; RW="$(xargs <<<"$RW")"; NAME="$(xargs <<<"$NAME")"
  [ -z "$TYPE" ] && continue
  if [[ "$DEST" == /app/* && "$DEST" != /app/data && "$DEST" != /app/data/* ]]; then echo "FAIL: app source override mount: $DEST"; exit 1; fi
  MODE=""; [ "$RW" = true ] || MODE=":ro"
  if [ "$TYPE" = bind ]; then MOUNT_ARGS+=( -v "${SOURCE}:${DEST}${MODE}" ); elif [ "$TYPE" = volume ]; then MOUNT_ARGS+=( -v "${NAME}:${DEST}${MODE}" ); fi
done < <(dc inspect "$APP" --format '{{range .Mounts}}{{println .Type "|" .Source "|" .Destination "|" .RW "|" .Name}}{{end}}')
PORT_ARGS=()
while IFS='|' read -r HOSTIP HOSTPORT CONTAINERPORT; do
  HOSTIP="$(xargs <<<"$HOSTIP")"; HOSTPORT="$(xargs <<<"$HOSTPORT")"; CONTAINERPORT="$(xargs <<<"$CONTAINERPORT")"
  [ -z "$HOSTPORT" ] && continue
  if [ -n "$HOSTIP" ] && [ "$HOSTIP" != "0.0.0.0" ]; then PORT_ARGS+=( -p "${HOSTIP}:${HOSTPORT}:${CONTAINERPORT}" ); else PORT_ARGS+=( -p "${HOSTPORT}:${CONTAINERPORT}" ); fi
done < <(dc inspect "$APP" --format '{{range $port, $bindings := .NetworkSettings.Ports}}{{range $bindings}}{{println .HostIp "|" .HostPort "|" $port}}{{end}}{{end}}')

echo "network=$PRIMARY_NETWORK memory=$MEMORY memswap=$MEMSWAP pids=$PIDSLIMIT" | tee -a "$LOG"

say "3/9 RESOURCE CHECK -> STOP OLD TEMPORARILY -> BUILD FULL SOURCE"
FREE_KB="$(df -Pk /var/lib/docker 2>/dev/null | awk 'NR==2{print $4}')"; [ -n "$FREE_KB" ] || FREE_KB="$(df -Pk / | awk 'NR==2{print $4}')"
(( FREE_KB >= 1400000 )) || { echo "FAIL: Docker disk free ${FREE_KB}KB < 1.4GB; current app untouched"; exit 1; }
if [ "$OLD_WAS_RUNNING" -eq 1 ]; then dc stop -t 10 "$APP" >/dev/null; OLD_STOPPED=1; STATE_MUTATED=1; fi
AVAIL_MB="$(free -m | awk '/Mem:/{print $7}')"
echo "available_mb=$AVAIL_MB free_kb=$FREE_KB" | tee -a "$LOG"
(( AVAIL_MB >= 350 )) || { echo "FAIL: available RAM ${AVAIL_MB}MB < 350MB"; exit 1; }
BUILD_CREATED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
DOCKER_BUILDKIT=1 dc build --pull --no-cache \
  --build-arg BUILD_GIT_SHA="$ACTUAL_SOURCE_SHA" \
  --build-arg SOURCE_ZIP_SHA="$ACTUAL_SOURCE_SHA" \
  --build-arg SOURCE_TREE_SHA="$TREE_SHA" \
  --build-arg BUILD_CREATED_AT="$BUILD_CREATED_AT" \
  -f "$SRC/Dockerfile" -t "$IMAGE" "$SRC" | tee -a "$LOG"
[ "$(dc image inspect "$IMAGE" --format '{{index .Config.Labels "org.opencontainers.image.version"}}')" = "$EXPECTED_VERSION" ]
[ "$(dc image inspect "$IMAGE" --format '{{index .Config.Labels "io.quantnova.deploy_model"}}')" = "$EXPECTED_DEPLOY_MODEL" ]
[ "$(dc image inspect "$IMAGE" --format '{{index .Config.Labels "io.quantnova.r492_extension"}}')" = "CORE16_FRESH4_ENERGY25_PATH30_SHARED40" ]
[ "$(dc image inspect "$IMAGE" --format '{{index .Config.Labels "io.quantnova.r493_market_rest_calls_per_refresh"}}')" = "2" ]
[ "$(dc image inspect "$IMAGE" --format '{{index .Config.Labels "io.quantnova.r493_new_ws_subscription_types"}}')" = "0" ]
[ "$(dc image inspect "$IMAGE" --format '{{index .Config.Labels "io.quantnova.packaging_revision"}}')" = "FULL_SOURCE_CLEAN_20260822" ]

say "4/9 ISOLATED CANDIDATE ACCEPTANCE"
mkdir -p "$CAND_DATA/nova30"
dc rm -f "$CANDIDATE" >/dev/null 2>&1 || true
CAND_ARGS=(run -d --name "$CANDIDATE" --network none --memory 384m --memory-swap 384m --pids-limit 256 --read-only --tmpfs /tmp:rw,noexec,nosuid,size=32m --env-file "$ENVFILE" -e NOVA_CANDIDATE_MODE=1 -e NOVA_OFFLINE=0 -e NOVA_DATA_DIR=/app/data/nova30 -v "$CAND_DATA/nova30:/app/data/nova30")
[ -n "$USER_SPEC" ] && CAND_ARGS+=(--user "$USER_SPEC")
CAND_ARGS+=("$IMAGE")
dc "${CAND_ARGS[@]}" >/dev/null
CAND_STARTED=1
wait_health "$CANDIDATE"
dc exec "$CANDIDATE" env PYTHONPATH=/app python /app/scripts/max_profit_acceptance.py | tee -a "$LOG"
dc exec "$CANDIDATE" env PYTHONPATH=/app python /app/scripts/market_rotation_acceptance.py | tee -a "$LOG"
dc exec "$CANDIDATE" env PYTHONPATH=/app python /app/scripts/r42_fresh_scout_acceptance.py | tee -a "$LOG"
dc exec "$CANDIDATE" env PYTHONPATH=/app python /app/scripts/r492_safe_extension_acceptance.py | tee -a "$LOG"
dc exec "$CANDIDATE" env PYTHONPATH=/app python /app/scripts/r493_market_relative_acceptance.py | tee -a "$LOG"
dc exec "$CANDIDATE" env PYTHONPATH=/app python -m unittest tests.test_r49_signal_acceleration tests.test_r493_market_relative -q | tee -a "$LOG"
dc exec "$CANDIDATE" env PYTHONPATH=/app python /app/scripts/runtime_smoke.py --clients 2 --ready-timeout 30 | tee -a "$LOG"
dc rm -f "$CANDIDATE" >/dev/null
CAND_STARTED=0

say "5/9 ATOMIC CUTOVER; PRE-DEPLOY CONTAINER PRESERVED"
if [ "$(dc inspect "$APP" --format '{{.State.Running}}')" = "true" ]; then dc stop -t 5 "$APP" >/dev/null; OLD_STOPPED=1; STATE_MUTATED=1; fi
dc rename "$APP" "$BACKUP"
OLD_RENAMED=1
STATE_MUTATED=1
RUN_ARGS=(run -d --name "$APP" --restart "$RESTART" --network "$PRIMARY_NETWORK" --env-file "$ENVFILE")
RUN_ARGS+=("${MOUNT_ARGS[@]}")
case "$PRIMARY_NETWORK" in host|none|container:*) ;; *) RUN_ARGS+=("${PORT_ARGS[@]}") ;; esac
[ -n "$USER_SPEC" ] && RUN_ARGS+=(--user "$USER_SPEC")
[ "$READONLY" = true ] && RUN_ARGS+=(--read-only --tmpfs /tmp:rw,noexec,nosuid,size=32m)
(( MEMORY > 0 )) && RUN_ARGS+=(--memory "$MEMORY")
(( MEMSWAP > 0 )) && RUN_ARGS+=(--memory-swap "$MEMSWAP")
(( MEMRES > 0 )) && RUN_ARGS+=(--memory-reservation "$MEMRES")
[[ "$PIDSLIMIT" =~ ^[0-9]+$ ]] && (( PIDSLIMIT > 0 )) && RUN_ARGS+=(--pids-limit "$PIDSLIMIT")
RUN_ARGS+=("$IMAGE")
dc "${RUN_ARGS[@]}" >/dev/null
NEW_STARTED=1
case "$PRIMARY_NETWORK" in host|none|container:*) ;; *) for net in "${NETWORKS[@]}"; do [ -n "$net" ] || continue; [ "$net" = "$PRIMARY_NETWORK" ] && continue; dc network connect "$net" "$APP" >/dev/null; done ;; esac
wait_health "$APP"

say "6/9 ACTIVE VERSION / API / BUY / R492 / R493 GATES"
dc exec "$APP" env PYTHONPATH=/app python /app/scripts/max_profit_acceptance.py | tee -a "$LOG"
dc exec "$APP" env PYTHONPATH=/app python /app/scripts/market_rotation_acceptance.py | tee -a "$LOG"
dc exec "$APP" env PYTHONPATH=/app python /app/scripts/r42_fresh_scout_acceptance.py | tee -a "$LOG"
dc exec "$APP" env PYTHONPATH=/app python /app/scripts/r492_safe_extension_acceptance.py | tee -a "$LOG"
dc exec "$APP" env PYTHONPATH=/app python /app/scripts/r493_market_relative_acceptance.py | tee -a "$LOG"
dc exec "$APP" env PYTHONPATH=/app python /app/scripts/runtime_smoke.py --clients 2 --ready-timeout 30 | tee -a "$LOG"
dc exec "$APP" python - "$EXPECTED_VERSION" <<'PY' | tee -a "$LOG"
import json,os,sys,urllib.request
expected=sys.argv[1]
t=(os.getenv('NOVA_UI_ACCESS_TOKEN') or os.getenv('APP_ACCESS_TOKEN') or '').strip()
h={'X-App-Token':t,'Authorization':'Bearer '+t} if t else {}
def get(p):
    with urllib.request.urlopen(urllib.request.Request('http://127.0.0.1:8000'+p,headers=h),timeout=8) as r:return json.load(r)
live=get('/api/livez'); ready=get('/api/readyz'); lab=get('/api/max-profit-lab'); health=get('/api/realtime-health'); panels=get('/api/decision-panels')
assert live.get('ok') and live.get('version')==expected,live
assert ready.get('ok') is True,ready
assert lab.get('mode')=='VERIFY_ONLY',lab
c=lab.get('contracts') or {}; pc=panels.get('contracts') or {}
assert c.get('official_buy_logic_changed') is False,c
assert c.get('new_broker_rest_calls')==0 and c.get('new_ws_subscription_types')==0,c
assert panels.get('ok') is True,panels
assert pc.get('official_buy_logic_changed') is False,pc
assert pc.get('pre_signal_slots')==20 and float(pc.get('pre_rank_commit_sec') or 0)==30.0,pc
assert pc.get('r492_new_broker_rest_calls')==0 and pc.get('r492_new_ws_subscription_types')==0,pc
assert pc.get('new_broker_rest_calls')==2 and pc.get('new_ws_subscriptions')==0,pc
assert pc.get('r493_market_index_rest_calls_per_refresh')==2 and pc.get('r493_new_ws_subscription_types')==0,pc
assert len(panels.get('preignition') or [])<=20 and len(panels.get('energy') or [])<=10 and len(panels.get('path') or [])<=10,panels
assert float((health.get('memory') or {}).get('swap_mb') or 0)==0,health.get('memory')
print(json.dumps({'ok':True,'version':expected,'verify':'PASS','market_index':health.get('market_index'),'load_mode':health.get('load_mode'),'energy_rows':len(panels.get('energy') or []),'path_rows':len(panels.get('path') or [])},ensure_ascii=False))
PY
verify_protected

say "7/9 10-MIN LOAD OBSERVATION (PROGRESS EVERY 10s)"
OBSERVE_SEC="${NOVA_R493_OBSERVE_SEC:-600}"
BAD_STREAK=0
START_OBS="$(date +%s)"
while (( $(date +%s) - START_OBS < OBSERVE_SEC )); do
  ELAPSED=$(( $(date +%s) - START_OBS ))
  if OBS_LINE="$(dc exec "$APP" python - <<'PY' 2>&1
import json,os,urllib.request
T=(os.getenv('NOVA_UI_ACCESS_TOKEN') or os.getenv('APP_ACCESS_TOKEN') or '').strip()
h={'X-App-Token':T,'Authorization':'Bearer '+T} if T else {}
def get(p):
    with urllib.request.urlopen(urllib.request.Request('http://127.0.0.1:8000'+p,headers=h),timeout=5) as r:return json.load(r)
x=get('/api/realtime-health'); p=get('/api/decision-panels')
m=x.get('memory') or {}; mode=str(x.get('load_mode') or '')
swap=float(m.get('swap_mb') or 0); lag=float(x.get('event_loop_lag_p95_ms') or 0); qage=float(x.get('trade_queue_oldest_age_ms') or 0); q=int(x.get('trade_queue_depth') or 0)
mi=x.get('market_index') or {}; ctx=x.get('market_context') or {}
print(json.dumps({'load':mode,'swap':swap,'lag_p95':lag,'queue_age_ms':qage,'queue':q,'energy':len(p.get('energy') or []),'path':len(p.get('path') or []),'market_index_active':mi.get('active'),'market_index_latency_ms':mi.get('latency_ms'),'market_errors':mi.get('errors'),'kospi':(ctx.get('KOSPI') or {}).get('change_rate'),'kosdaq':(ctx.get('KOSDAQ') or {}).get('change_rate')},ensure_ascii=False))
assert swap==0
assert lag<=250
assert qage<=750
assert mode!='CRITICAL'
PY
)"; then
    BAD_STREAK=0
    echo "OBSERVE ${ELAPSED}/${OBSERVE_SEC}s · ${OBS_LINE}" | tee -a "$LOG"
  else
    BAD_STREAK=$((BAD_STREAK+1))
    echo "WARN ${ELAPSED}/${OBSERVE_SEC}s · bad_streak=$BAD_STREAK · ${OBS_LINE}" | tee -a "$LOG"
  fi
  if (( BAD_STREAK >= 3 )); then echo "FAIL: sustained critical/lag condition -> automatic rollback" | tee -a "$LOG"; false; fi
  sleep 10
done
verify_protected

say "8/9 FINAL STATUS"
dc ps --filter "name=^/${APP}$" --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}' | tee -a "$LOG"
dc image inspect "$IMAGE" --format 'VERSION={{index .Config.Labels "org.opencontainers.image.version"}} DEPLOY={{index .Config.Labels "io.quantnova.deploy_model"}} PACKAGING={{index .Config.Labels "io.quantnova.packaging_revision"}} R493_INDEX={{index .Config.Labels "io.quantnova.r493_market_index"}}' | tee -a "$LOG"

say "9/9 SUCCESS"
trap - ERR INT TERM EXIT
cleanup
echo "RESULT=SUCCESS VERSION=$EXPECTED_VERSION CURRENT=$APP NETWORK=$PRIMARY_NETWORK ROLLBACK_CONTAINER=$BACKUP" | tee -a "$LOG"
echo "SOURCE_SHA=$ACTUAL_SOURCE_SHA TREE_SHA=$TREE_SHA BUY=ENTRY_V18_FROZEN R492=RETAINED R493=MARKET_RELATIVE_SAFE" | tee -a "$LOG"
echo "LOG=$LOG"
