#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

REPO="bbblaprk-svg/kiwoom-smartmoney-daytrader"
BRANCH="main"
APP="${NOVA_APP_CONTAINER:-quant-nova}"
EXPECTED_DOCKERFILE_SHA="f3fa8e4ea250d035925df04a2565780e312c0ee6cf4b376ab0ca823efeba4f34"
EXPECTED_VERSION="NOVA-3.3.5-R492-FRESH-ENERGY-PATH-SAFE"
EXPECTED_BASELINE_VERSION="NOVA-3.3.4-MARKET-WIDE-ROTATION-VERIFY"
IMAGE="quant-nova:3.3.5-r492-safe-local"
STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP="${APP}-pre-r492-${STAMP}"
FAILED="${APP}-failed-r492-${STAMP}"
CANDIDATE="${APP}-candidate-r492-${STAMP}"
WORK="$(mktemp -d /tmp/nova-r492-safe.XXXXXX)"
DOCKERFILE="$WORK/Dockerfile"
ENVFILE="$WORK/current.env"
CAND_DATA="$WORK/candidate-data"
LOG="/tmp/nova-r492-safe-deploy-${STAMP}.log"
OLD_WAS_RUNNING=0
OLD_STOPPED=0
OLD_RENAMED=0
NEW_STARTED=0
CAND_STARTED=0
SUCCESS=0

if docker info >/dev/null 2>&1; then DOCKER=(docker)
elif sudo -n docker info >/dev/null 2>&1; then DOCKER=(sudo docker)
else echo "FAIL: Docker 권한을 확인할 수 없습니다."; exit 2
fi
dc(){ "${DOCKER[@]}" "$@"; }
say(){ printf '\n===== %s =====\n' "$*" | tee -a "$LOG"; }
cleanup(){ rm -rf -- "$WORK" 2>/dev/null || true; }
recover_previous_if_needed(){
  local latest status
  if dc inspect "$APP" >/dev/null 2>&1; then
    status="$(dc inspect "$APP" --format '{{.State.Status}}' 2>/dev/null || true)"
    if [ "$status" != "running" ]; then
      echo "INFO: existing $APP is $status; starting it before snapshot" | tee -a "$LOG"
      dc start "$APP" >/dev/null 2>&1 || true
    fi
    return 0
  fi
  latest="$(dc ps -a --format '{{.Names}}' | grep -E "^${APP}-pre-r(492|491|49|48|47)-[0-9]{8}-[0-9]{6}$" | sort | tail -n 1 || true)"
  if [ -n "$latest" ]; then
    echo "INFO: restoring previous container $latest -> $APP" | tee -a "$LOG"
    dc rename "$latest" "$APP"
    dc start "$APP" >/dev/null 2>&1 || true
    wait_health "$APP" || true
  fi
}
protected_snapshot(){
  for name in nova-http-guard caddy nova-caddy kiwoom-caddy; do
    if dc inspect "$name" >/dev/null 2>&1; then printf '%s=%s\n' "$name" "$(dc inspect "$name" --format '{{.Id}}')"; fi
  done | sort
}
wait_health(){
  local name="$1" i status
  for i in $(seq 1 72); do
    status="$(dc inspect "$name" --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' 2>/dev/null || true)"
    [ "$status" = "healthy" ] && return 0
    sleep 5
  done
  return 1
}
fetch_dockerfile(){
  local remote="QUANT_NOVA_3.3.5_R492_FRESH_ENERGY_PATH_SAFE_20260821.Dockerfile"
  local raw="https://raw.githubusercontent.com/${REPO}/${BRANCH}/${remote}"
  if curl -fsSL --max-time 30 "$raw" -o "$DOCKERFILE" 2>/dev/null; then return 0; fi
  # fallback: if user uploaded the approved file as repository-root Dockerfile
  raw="https://raw.githubusercontent.com/${REPO}/${BRANCH}/Dockerfile"
  if curl -fsSL --max-time 30 "$raw" -o "$DOCKERFILE" 2>/dev/null; then return 0; fi
  local token="${GH_TOKEN:-${GITHUB_TOKEN:-}}"
  if [ -z "$token" ]; then
    printf '\nGitHub Private 저장소입니다. Contents: Read 권한의 GitHub token을 입력하세요.\n' >&2
    read -rsp 'GitHub token: ' token
    printf '\n' >&2
  fi
  [ -n "$token" ] || return 1
  if ! curl -fsSL --max-time 40 \
    -H 'Accept: application/vnd.github.raw+json' \
    -H "Authorization: Bearer ${token}" \
    -H 'X-GitHub-Api-Version: 2026-03-10' \
    "https://api.github.com/repos/${REPO}/contents/${remote}?ref=${BRANCH}" \
    -o "$DOCKERFILE"; then
      curl -fsSL --max-time 40 \
        -H 'Accept: application/vnd.github.raw+json' \
        -H "Authorization: Bearer ${token}" \
        -H 'X-GitHub-Api-Version: 2026-03-10' \
        "https://api.github.com/repos/${REPO}/contents/Dockerfile?ref=${BRANCH}" \
        -o "$DOCKERFILE"
  fi
  unset token GH_TOKEN GITHUB_TOKEN 2>/dev/null || true
}
verify_protected(){
  [ "$(cat "$WORK/protected.before")" = "$(protected_snapshot)" ] || {
    echo "FAIL: Guard/Caddy 컨테이너가 변경됐습니다." | tee -a "$LOG"; return 1; }
}
rollback(){
  local rc=$?
  trap - ERR INT TERM EXIT
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
  echo "RESULT=ROLLED_BACK CURRENT=$APP LOG=$LOG" | tee -a "$LOG"
  exit "${rc:-1}"
}
trap rollback ERR INT TERM EXIT

recover_previous_if_needed

say "1/9 FETCH R492 SAFE DOCKERFILE + SHA LOCK"
fetch_dockerfile
ACTUAL_SHA="$(sha256sum "$DOCKERFILE" | awk '{print $1}')"
echo "DOCKERFILE_SHA256=$ACTUAL_SHA" | tee -a "$LOG"
[ "$ACTUAL_SHA" = "$EXPECTED_DOCKERFILE_SHA" ] || { echo "FAIL: GitHub Dockerfile이 승인본과 다릅니다."; exit 1; }

grep -Fq 'NOVA-3.3.5-R492-FRESH-ENERGY-PATH-SAFE' "$DOCKERFILE"

say "2/9 SNAPSHOT CURRENT R491 / GUARD / CADDY"
dc inspect "$APP" >/dev/null
CURRENT_IMAGE_ID="$(dc inspect "$APP" --format '{{.Image}}')"
CURRENT_VERSION="$(dc image inspect "$CURRENT_IMAGE_ID" --format '{{index .Config.Labels "org.opencontainers.image.version"}}' 2>/dev/null || true)"
echo "current_version=${CURRENT_VERSION:-UNKNOWN}" | tee -a "$LOG"
[ "$CURRENT_VERSION" = "$EXPECTED_BASELINE_VERSION" ] || {
  echo "FAIL: 현재 $APP 는 승인 R491 기준본($EXPECTED_BASELINE_VERSION)이 아닙니다. 원본 복귀 안전성을 위해 R492 덮어배포를 중단합니다." | tee -a "$LOG"
  exit 1
}
[ "$(dc inspect "$APP" --format '{{.State.Running}}')" = "true" ] && OLD_WAS_RUNNING=1 || true
dc inspect "$APP" --format '{{range .Config.Env}}{{println .}}{{end}}' > "$ENVFILE"
protected_snapshot > "$WORK/protected.before"
NETWORK_MODE="$(dc inspect "$APP" --format '{{.HostConfig.NetworkMode}}' | xargs)"
mapfile -t NETWORKS < <(dc inspect "$APP" --format '{{range $name, $_ := .NetworkSettings.Networks}}{{println $name}}{{end}}' | awk 'NF' | sort -u)
case "$NETWORK_MODE" in
  host|none|container:*) PRIMARY_NETWORK="$NETWORK_MODE" ;;
  default|"")
    if [ "${#NETWORKS[@]}" -gt 0 ]; then PRIMARY_NETWORK="${NETWORKS[0]}"; else PRIMARY_NETWORK="bridge"; fi ;;
  *)
    if [ "${#NETWORKS[@]}" -gt 0 ]; then PRIMARY_NETWORK="${NETWORKS[0]}"; else PRIMARY_NETWORK="$NETWORK_MODE"; fi ;;
esac
[ -n "$PRIMARY_NETWORK" ] || { echo "FAIL: unable to resolve Docker network mode"; exit 1; }
echo "network_mode=$NETWORK_MODE primary_network=$PRIMARY_NETWORK attached_networks=${NETWORKS[*]:-none}" | tee -a "$LOG"
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
  if [ "$TYPE" = bind ]; then MOUNT_ARGS+=( -v "${SOURCE}:${DEST}${MODE}" );
  elif [ "$TYPE" = volume ]; then MOUNT_ARGS+=( -v "${NAME}:${DEST}${MODE}" ); fi
done < <(dc inspect "$APP" --format '{{range .Mounts}}{{println .Type "|" .Source "|" .Destination "|" .RW "|" .Name}}{{end}}')
PORT_ARGS=()
while IFS='|' read -r HOSTIP HOSTPORT CONTAINERPORT; do
  HOSTIP="$(xargs <<<"$HOSTIP")"; HOSTPORT="$(xargs <<<"$HOSTPORT")"; CONTAINERPORT="$(xargs <<<"$CONTAINERPORT")"
  [ -z "$HOSTPORT" ] && continue
  if [ -n "$HOSTIP" ] && [ "$HOSTIP" != "0.0.0.0" ]; then PORT_ARGS+=( -p "${HOSTIP}:${HOSTPORT}:${CONTAINERPORT}" ); else PORT_ARGS+=( -p "${HOSTPORT}:${CONTAINERPORT}" ); fi
done < <(dc inspect "$APP" --format '{{range $port, $bindings := .NetworkSettings.Ports}}{{range $bindings}}{{println .HostIp "|" .HostPort "|" $port}}{{end}}{{end}}')

say "3/9 STOP OLD TEMPORARILY TO FREE 1GB HOST, THEN BUILD"
if [ "$OLD_WAS_RUNNING" -eq 1 ]; then dc stop -t 10 "$APP" >/dev/null; OLD_STOPPED=1; fi
AVAIL_MB="$(free -m | awk '/Mem:/{print $7}')"
FREE_KB="$(df -Pk /var/lib/docker 2>/dev/null | awk 'NR==2{print $4}')"
[ -n "$FREE_KB" ] || FREE_KB="$(df -Pk / | awk 'NR==2{print $4}')"
echo "available_mb=$AVAIL_MB free_kb=$FREE_KB" | tee -a "$LOG"
(( AVAIL_MB >= 350 )) || { echo "FAIL: available RAM ${AVAIL_MB}MB < 350MB"; exit 1; }
(( FREE_KB >= 1400000 )) || { echo "FAIL: Docker disk free ${FREE_KB}KB < 1.4GB"; exit 1; }
DOCKER_BUILDKIT=1 dc build --pull --no-cache -f "$DOCKERFILE" -t "$IMAGE" "$WORK" | tee -a "$LOG"
LABEL_VERSION="$(dc image inspect "$IMAGE" --format '{{index .Config.Labels "org.opencontainers.image.version"}}')"
UI_PATCH_ACTUAL="$(dc image inspect "$IMAGE" --format '{{index .Config.Labels "io.quantnova.ui_patch"}}')"
SESSION_CLOSE_ACTUAL="$(dc image inspect "$IMAGE" --format '{{index .Config.Labels "io.quantnova.session_close_policy"}}')"
CLOSE_HISTORY_ACTUAL="$(dc image inspect "$IMAGE" --format '{{index .Config.Labels "io.quantnova.close_signal_history"}}')"
LARGECAP_CLOSE_ACTUAL="$(dc image inspect "$IMAGE" --format '{{index .Config.Labels "io.quantnova.largecap_close_policy"}}')"
echo "labels: version=$LABEL_VERSION ui_patch=$UI_PATCH_ACTUAL" | tee -a "$LOG"
echo "labels: session_close=$SESSION_CLOSE_ACTUAL close_history=$CLOSE_HISTORY_ACTUAL largecap_close=$LARGECAP_CLOSE_ACTUAL" | tee -a "$LOG"
[ "$LABEL_VERSION" = "$EXPECTED_VERSION" ]
[ "$(dc image inspect "$IMAGE" --format '{{index .Config.Labels "io.quantnova.ui_patch"}}')" = "R492_FRESH_ENERGY_PATH_SAFE" ]
[ "$(dc image inspect "$IMAGE" --format '{{index .Config.Labels "io.quantnova.board_independence"}}')" = "PREIGNITION_SIGNAL_ACCEL__PREBUY_ENTRY_PROXIMITY__NXT_EARLY_SMART_FLOW_2PLUS" ]
[ "$(dc image inspect "$IMAGE" --format '{{index .Config.Labels "io.quantnova.board_force_fill"}}')" = "DISABLED_ALLOW_PARTIAL_ROWS" ]
[ "$(dc image inspect "$IMAGE" --format '{{index .Config.Labels "io.quantnova.signal_acceleration"}}')" = "TOP20_5M15M30M_PLUS_LIVE_RANK30_DWELL60_GAP3" ]
[ "$(dc image inspect "$IMAGE" --format '{{index .Config.Labels "io.quantnova.pre_signal_live_evidence"}}')" = "3PLUS_LIVE_4PLUS_ENTRY_EPISODE600_RESET60" ]
[ "$(dc image inspect "$IMAGE" --format '{{index .Config.Labels "io.quantnova.entry_candidate"}}')" = "DISPLAY_ONLY_4OF5_FORMAL_OR_LIVE_EVIDENCE_NO_ENTRY_V18_MUTATION" ]
[ "$(dc image inspect "$IMAGE" --format '{{index .Config.Labels "io.quantnova.pre_antistickiness"}}')" = "STALE_PIN_CURRENT_EVIDENCE_REQUIRED_LIVE_EPISODE_10M" ]
[ "$(dc image inspect "$IMAGE" --format '{{index .Config.Labels "io.quantnova.session_close_policy"}}')" = "HARD_FREEZE_DROP_LATE_SCORE_QUEUE_NO_RANK_NO_EVENT_WRITERS" ]
[ "$(dc image inspect "$IMAGE" --format '{{index .Config.Labels "io.quantnova.close_signal_history"}}')" = "FROZEN_LAST_LIVE_NO_POST_CLOSE_ENTRY_OR_TOP10_EVENTS" ]
[ "$(dc image inspect "$IMAGE" --format '{{index .Config.Labels "io.quantnova.largecap_close_policy"}}')" = "LAST_LIVE_ONLY_NO_RECONSTRUCTION_NO_DATA_WAIT" ]
[ "$(dc image inspect "$IMAGE" --format '{{index .Config.Labels "io.quantnova.primary_board_order"}}')" = "PREIGNITION_PREBUY_NXT_EARLY" ]
[ "$(dc image inspect "$IMAGE" --format '{{index .Config.Labels "io.quantnova.prior_candidate_ttl"}}')" = "NEXT_TRADING_DAY_ONLY_REQUALIFY_REQUIRED" ]
[ "$(dc image inspect "$IMAGE" --format '{{index .Config.Labels "io.quantnova.r492_extension"}}')" = "CORE16_FRESH4_ENERGY25_PATH30_SHARED40" ]
[ "$(dc image inspect "$IMAGE" --format '{{index .Config.Labels "io.quantnova.r492_new_broker_rest_calls"}}')" = "0" ]
[ "$(dc image inspect "$IMAGE" --format '{{index .Config.Labels "io.quantnova.r492_new_ws_subscription_types"}}')" = "0" ]

say "4/9 ISOLATED CANDIDATE TEST"
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
dc exec "$CANDIDATE" env PYTHONPATH=/app python -m unittest tests.test_r49_signal_acceleration -q | tee -a "$LOG"
dc exec "$CANDIDATE" env PYTHONPATH=/app python /app/scripts/runtime_smoke.py --clients 2 --ready-timeout 30 | tee -a "$LOG"
dc rm -f "$CANDIDATE" >/dev/null
CAND_STARTED=0

say "5/9 ATOMIC CUTOVER; OLD R491 CONTAINER PRESERVED"
dc rename "$APP" "$BACKUP"
OLD_RENAMED=1
RUN_ARGS=(run -d --name "$APP" --restart "$RESTART" --network "$PRIMARY_NETWORK" --env-file "$ENVFILE")
RUN_ARGS+=("${MOUNT_ARGS[@]}")
case "$PRIMARY_NETWORK" in
  host|none|container:*) ;;
  *) RUN_ARGS+=("${PORT_ARGS[@]}") ;;
esac
[ -n "$USER_SPEC" ] && RUN_ARGS+=(--user "$USER_SPEC")
[ "$READONLY" = true ] && RUN_ARGS+=(--read-only --tmpfs /tmp:rw,noexec,nosuid,size=32m)
(( MEMORY > 0 )) && RUN_ARGS+=(--memory "$MEMORY")
(( MEMSWAP > 0 )) && RUN_ARGS+=(--memory-swap "$MEMSWAP")
(( MEMRES > 0 )) && RUN_ARGS+=(--memory-reservation "$MEMRES")
[[ "$PIDSLIMIT" =~ ^[0-9]+$ ]] && (( PIDSLIMIT > 0 )) && RUN_ARGS+=(--pids-limit "$PIDSLIMIT")
RUN_ARGS+=("$IMAGE")
dc "${RUN_ARGS[@]}" >/dev/null
NEW_STARTED=1
case "$PRIMARY_NETWORK" in
  host|none|container:*) ;;
  *)
    for net in "${NETWORKS[@]}"; do
      [ -n "$net" ] || continue
      [ "$net" = "$PRIMARY_NETWORK" ] && continue
      dc network connect "$net" "$APP" >/dev/null
    done
    ;;
esac
wait_health "$APP"

say "6/9 ACTIVE VERSION / API / WS / VERIFY GATES"
dc exec "$APP" env PYTHONPATH=/app python /app/scripts/max_profit_acceptance.py | tee -a "$LOG"
dc exec "$APP" env PYTHONPATH=/app python /app/scripts/market_rotation_acceptance.py | tee -a "$LOG"
dc exec "$APP" env PYTHONPATH=/app python /app/scripts/r42_fresh_scout_acceptance.py | tee -a "$LOG"
dc exec "$APP" env PYTHONPATH=/app python /app/scripts/r492_safe_extension_acceptance.py | tee -a "$LOG"
dc exec "$APP" env PYTHONPATH=/app python -m unittest tests.test_r49_signal_acceleration -q | tee -a "$LOG"
dc exec "$APP" env PYTHONPATH=/app python /app/scripts/runtime_smoke.py --clients 2 --ready-timeout 30 | tee -a "$LOG"
dc exec "$APP" python - "$EXPECTED_VERSION" <<'PY' | tee -a "$LOG"
import json,os,sys,urllib.request
expected=sys.argv[1]
token=(os.getenv('NOVA_UI_ACCESS_TOKEN') or os.getenv('APP_ACCESS_TOKEN') or '').strip()
h={'X-App-Token':token,'Authorization':'Bearer '+token} if token else {}
def get(p):
    with urllib.request.urlopen(urllib.request.Request('http://127.0.0.1:8000'+p,headers=h),timeout=8) as r:return json.load(r)
live=get('/api/livez'); ready=get('/api/readyz'); lab=get('/api/max-profit-lab'); health=get('/api/realtime-health'); panels=get('/api/decision-panels')
assert live.get('ok') and live.get('version')==expected,live
assert ready.get('ok') is True,ready
assert lab.get('mode')=='VERIFY_ONLY',lab
c=lab.get('contracts') or {}
assert c.get('official_buy_logic_changed') is False,c
assert c.get('new_broker_rest_calls')==0 and c.get('new_ws_subscription_types')==0,c
assert c.get('bounded_trade_rotation') is True and c.get('exploration_official_buy_blocked') is True,c
assert len(lab.get('rows') or [])<=10
assert float((health.get('memory') or {}).get('swap_mb') or 0)==0,health.get('memory')
pc=panels.get('contracts') or {}
assert panels.get('ok') is True,panels
assert pc.get('official_buy_logic_changed') is False,pc
assert pc.get('pre_signal_slots')==20 and float(pc.get('pre_rank_commit_sec') or 0)==30.0,pc
assert float(pc.get('pre_min_dwell_sec') or 0)==60.0 and float(pc.get('pre_newcomer_gap') or 0)==3.0,pc
assert float(pc.get('live_evidence_episode_sec') or 0)==600.0 and float(pc.get('live_evidence_reset_sec') or 0)==60.0,pc
assert 'DISPLAY ONLY' in str(pc.get('entry_candidate_policy') or '') and 'before formal SIGNAL' in str(pc.get('entry_candidate_policy') or ''),pc
assert len(panels.get('preignition') or [])<=20
assert pc.get('r492_new_broker_rest_calls')==0 and pc.get('r492_new_ws_subscription_types')==0,pc
assert 'CORE16+FRESH4' in str(pc.get('r492_fresh_lane') or ''),pc
assert len(panels.get('energy') or [])<=10 and len(panels.get('path') or [])<=10,panels
r492=panels.get('r492') or {}
assert str(r492.get('mode') or '') in ('NORMAL','DEGRADED','R491_SAFE','FROZEN'),r492
print(json.dumps({'ok':True,'version':expected,'verify':'PASS','rotation':'PASS','r492_mode':r492.get('mode'),'signal_accel':'TOP20_PLUS_LIVE_RANK30_DWELL60_GAP3','energy_rows':len(panels.get('energy') or []),'path_rows':len(panels.get('path') or []),'entry_target':'DISPLAY_ONLY','swap_mb':0},ensure_ascii=False))
PY
verify_protected

say "7/9 R492 10-MIN LIVE LOAD OBSERVATION (AUTO ROLLBACK ON CRITICAL PERSISTENCE)"
OBSERVE_SEC="${NOVA_R492_OBSERVE_SEC:-600}"
BAD_STREAK=0
START_OBS="$(date +%s)"
while (( $(date +%s) - START_OBS < OBSERVE_SEC )); do
  if dc exec "$APP" python - <<'R492PY' >>"$LOG" 2>&1
import json,os,urllib.request
T=(os.getenv('NOVA_UI_ACCESS_TOKEN') or os.getenv('APP_ACCESS_TOKEN') or '').strip()
h={'X-App-Token':T,'Authorization':'Bearer '+T} if T else {}
def get(p):
    with urllib.request.urlopen(urllib.request.Request('http://127.0.0.1:8000'+p,headers=h),timeout=5) as r:return json.load(r)
h=get('/api/realtime-health');p=get('/api/decision-panels')
m=h.get('memory') or {};mode=str(h.get('load_mode') or '')
swap=float(m.get('swap_mb') or 0);lag=float(h.get('event_loop_lag_p95_ms') or 0);qage=float(h.get('trade_queue_oldest_age_ms') or 0);q=int(h.get('trade_queue_depth') or 0)
r=p.get('r492') or {}
print(json.dumps({'load':mode,'r492':r.get('mode'),'swap':swap,'lag_p95':lag,'queue_age_ms':qage,'queue':q,'energy':len(p.get('energy') or []),'path':len(p.get('path') or [])},ensure_ascii=False))
assert swap==0
assert lag<=250
assert qage<=750
assert mode!='CRITICAL'
R492PY
  then BAD_STREAK=0
  else BAD_STREAK=$((BAD_STREAK+1)); echo "WARN: R492 load guard bad_streak=$BAD_STREAK" | tee -a "$LOG"
  fi
  if (( BAD_STREAK >= 3 )); then echo "FAIL: R492 sustained critical/lag condition -> rollback" | tee -a "$LOG"; false; fi
  sleep 10
done
verify_protected

say "8/9 FINAL CONTAINER STATUS"
dc ps --filter "name=^/${APP}$" --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}' | tee -a "$LOG"
dc image inspect "$IMAGE" --format 'VERSION={{index .Config.Labels "org.opencontainers.image.version"}}' | tee -a "$LOG"
dc image inspect "$IMAGE" --format 'UI_PATCH={{index .Config.Labels "io.quantnova.ui_patch"}} R492={{index .Config.Labels "io.quantnova.r492_extension"}} PRIOR_TTL={{index .Config.Labels "io.quantnova.prior_candidate_ttl"}} ORDER={{index .Config.Labels "io.quantnova.primary_board_order"}}' | tee -a "$LOG"

say "9/9 SUCCESS"
SUCCESS=1
trap - ERR INT TERM EXIT
cleanup
echo "RESULT=SUCCESS VERSION=$EXPECTED_VERSION CURRENT=$APP NETWORK=$PRIMARY_NETWORK ROLLBACK_CONTAINER=$BACKUP" | tee -a "$LOG"
echo "GUARD=NOT_TOUCHED CADDY=NOT_TOUCHED BUY=ENTRY_V18_FROZEN R492=SAFE_EXTENSION" | tee -a "$LOG"
echo "LOG=$LOG"
