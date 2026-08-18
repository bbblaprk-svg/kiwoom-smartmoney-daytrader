#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

REPO="bbblaprk-svg/kiwoom-smartmoney-daytrader"
BRANCH="main"
APP="${NOVA_APP_CONTAINER:-quant-nova}"
EXPECTED_DOCKERFILE_SHA="a9fcdbb8dda18581c6d87efd74cb6f7b928feba3f17ed56f21a49a1d9504bb8e"
EXPECTED_VERSION="NOVA-3.3.4-MARKET-WIDE-ROTATION-VERIFY"
EXPECTED_UI_PATCH="R42_FRESH_SCOUT_DISPLAY_HYSTERESIS_PRICE_TRUTH"
EXPECTED_PRICE_TRUTH_PATCH="OPENING_BRIDGE_LIVE_OR_DATA_WAIT_R41"
EXPECTED_EARLY_EDGE_POLICY="PRE_BREAKOUT_HEADROOM_FRESHNESS15_FAST_SCOUT"
EXPECTED_EARLY_EDGE_SCOPE="DISCOVERY_HOT_ROTATION_LARGECAP_PRE_PREBUY_NXT_EARLY_MAX_PROFIT"
EXPECTED_FRESH_SCOUT_CONTRACT="ANCHOR6_FRESH4_HOLD20_GAP5_FAST90_FRESH180"
EXPECTED_DISPLAY_HYSTERESIS="POSITION_ONLY_LIVE_METRICS"
EXPECTED_HOT_SELECTION="ANCHOR6_FRESH4_FAST_SCOUT_BOUNDED"
IMAGE="quant-nova:3.3.4-r42-fresh-scout"
STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP="${APP}-pre-r42-fresh-scout-${STAMP}"
CANDIDATE="${APP}-candidate-r42-fresh-scout-${STAMP}"
WORK="$(mktemp -d /tmp/nova334-r42-fresh-scout.XXXXXX)"
DOCKERFILE="$WORK/Dockerfile"
ENVFILE="$WORK/current.env"
CAND_DATA="$WORK/candidate-data"
LOG="/tmp/nova334-r42-fresh-scout-deploy-${STAMP}.log"

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

protected_snapshot(){
  for name in nova-http-guard caddy nova-caddy kiwoom-caddy; do
    if dc inspect "$name" >/dev/null 2>&1; then
      printf '%s=%s\n' "$name" "$(dc inspect "$name" --format '{{.Id}}')"
    fi
  done | sort
}

wait_ready(){
  local name="$1"
  for _ in $(seq 1 90); do
    if dc exec "$name" python -c "import json,urllib.request,sys; j=json.load(urllib.request.urlopen('http://127.0.0.1:8000/api/readyz',timeout=2)); sys.exit(0 if j.get('ok') else 1)" >/dev/null 2>&1; then
      return 0
    fi
    sleep 2
  done
  return 1
}

rollback(){
  set +e
  say "AUTO ROLLBACK"
  if [ "$CAND_STARTED" -eq 1 ] && dc inspect "$CANDIDATE" >/dev/null 2>&1; then
    dc rm -f "$CANDIDATE" >/dev/null 2>&1 || true
  fi
  if [ "$NEW_STARTED" -eq 1 ] && dc inspect "$APP" >/dev/null 2>&1; then
    dc logs --tail 250 "$APP" >>"$LOG" 2>&1 || true
    dc rm -f "$APP" >/dev/null 2>&1 || true
  fi
  if [ "$OLD_RENAMED" -eq 1 ] && dc inspect "$BACKUP" >/dev/null 2>&1; then
    dc rename "$BACKUP" "$APP" >/dev/null 2>&1 || true
    [ "$OLD_WAS_RUNNING" -eq 1 ] && dc start "$APP" >/dev/null 2>&1 || true
    [ "$OLD_WAS_RUNNING" -eq 1 ] && wait_ready "$APP" || true
  elif [ "$OLD_STOPPED" -eq 1 ] && dc inspect "$APP" >/dev/null 2>&1; then
    [ "$OLD_WAS_RUNNING" -eq 1 ] && dc start "$APP" >/dev/null 2>&1 || true
    [ "$OLD_WAS_RUNNING" -eq 1 ] && wait_ready "$APP" || true
  fi
  echo "RESULT=ROLLED_BACK CURRENT=$APP LOG=$LOG" | tee -a "$LOG"
}

on_exit(){
  rc=$?
  trap - EXIT INT TERM
  if [ "$rc" -ne 0 ] && [ "$SUCCESS" -ne 1 ]; then rollback; fi
  cleanup
  exit "$rc"
}
trap on_exit EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

say "1/8 FETCH PUBLIC GITHUB DOCKERFILE + SHA LOCK"
curl -fsSL --max-time 40 \
  "https://raw.githubusercontent.com/${REPO}/${BRANCH}/Dockerfile" \
  -o "$DOCKERFILE"

ACTUAL_SHA="$(sha256sum "$DOCKERFILE" | awk '{print $1}')"
echo "DOCKERFILE_SHA256=$ACTUAL_SHA" | tee -a "$LOG"
[ "$ACTUAL_SHA" = "$EXPECTED_DOCKERFILE_SHA" ] || {
  echo "FAIL: GitHub Dockerfile SHA 불일치. R4.2 FRESH-SCOUT 최종본이 아닙니다." | tee -a "$LOG"
  exit 1
}
grep -Fq "$EXPECTED_VERSION" "$DOCKERFILE"
grep -Fq "$EXPECTED_UI_PATCH" "$DOCKERFILE"
grep -Fq "$EXPECTED_PRICE_TRUTH_PATCH" "$DOCKERFILE"
grep -Fq "$EXPECTED_EARLY_EDGE_POLICY" "$DOCKERFILE"
grep -Fq "$EXPECTED_EARLY_EDGE_SCOPE" "$DOCKERFILE"
grep -Fq "$EXPECTED_FRESH_SCOUT_CONTRACT" "$DOCKERFILE"
grep -Fq "$EXPECTED_DISPLAY_HYSTERESIS" "$DOCKERFILE"
grep -Fq "$EXPECTED_HOT_SELECTION" "$DOCKERFILE"

say "2/8 SNAPSHOT CURRENT 3.3.4 + GUARD/CADDY"
dc inspect "$APP" >/dev/null
[ "$(dc inspect "$APP" --format '{{.State.Running}}')" = "true" ] && OLD_WAS_RUNNING=1 || true
[ "$OLD_WAS_RUNNING" -eq 1 ] || { echo "FAIL: 현재 quant-nova가 실행 중이 아닙니다."; exit 1; }

dc inspect "$APP" --format '{{range .Config.Env}}{{println .}}{{end}}' > "$ENVFILE"
protected_snapshot > "$WORK/protected.before"

NETWORK_MODE="$(dc inspect "$APP" --format '{{.HostConfig.NetworkMode}}' | xargs)"
case "$NETWORK_MODE" in
  ""|"default") NETWORK_ARGS=() ;;
  "bridge"|"host"|"none") NETWORK_ARGS=(--network "$NETWORK_MODE") ;;
  container:*) echo "FAIL: unsupported network mode $NETWORK_MODE"; exit 1 ;;
  *) NETWORK_ARGS=(--network "$NETWORK_MODE") ;;
esac

mapfile -t ALL_NETWORKS < <(
  dc inspect "$APP" --format '{{range $name, $_ := .NetworkSettings.Networks}}{{println $name}}{{end}}' |
  sed '/^[[:space:]]*$/d'
)

RESTART="$(dc inspect "$APP" --format '{{.HostConfig.RestartPolicy.Name}}')"
[ -n "$RESTART" ] && [ "$RESTART" != "no" ] || RESTART=unless-stopped
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
  if [[ "$DEST" == /app/* && "$DEST" != /app/data && "$DEST" != /app/data/* ]]; then
    echo "FAIL: source override mount detected: $DEST"; exit 1
  fi
  MODE=""; [ "$RW" = true ] || MODE=":ro"
  if [ "$TYPE" = bind ]; then MOUNT_ARGS+=( -v "${SOURCE}:${DEST}${MODE}" )
  elif [ "$TYPE" = volume ]; then MOUNT_ARGS+=( -v "${NAME}:${DEST}${MODE}" )
  fi
done < <(dc inspect "$APP" --format '{{range .Mounts}}{{println .Type "|" .Source "|" .Destination "|" .RW "|" .Name}}{{end}}')

PORT_ARGS=()
if [ "$NETWORK_MODE" != "host" ]; then
  while IFS='|' read -r HOSTIP HOSTPORT CONTAINERPORT; do
    HOSTIP="$(xargs <<<"$HOSTIP")"; HOSTPORT="$(xargs <<<"$HOSTPORT")"; CONTAINERPORT="$(xargs <<<"$CONTAINERPORT")"
    [ -z "$HOSTPORT" ] && continue
    if [ -n "$HOSTIP" ] && [ "$HOSTIP" != "0.0.0.0" ]; then
      PORT_ARGS+=( -p "${HOSTIP}:${HOSTPORT}:${CONTAINERPORT}" )
    else
      PORT_ARGS+=( -p "${HOSTPORT}:${CONTAINERPORT}" )
    fi
  done < <(dc inspect "$APP" --format '{{range $port, $bindings := .NetworkSettings.Ports}}{{range $bindings}}{{println .HostIp "|" .HostPort "|" $port}}{{end}}{{end}}')
fi

say "3/8 STOP CURRENT TEMPORARILY + BUILD R4.2 FRESH-SCOUT"
dc stop -t 10 "$APP" >/dev/null
OLD_STOPPED=1

AVAIL_MB="$(free -m | awk '/Mem:/{print $7}')"
FREE_KB="$(df -Pk /var/lib/docker 2>/dev/null | awk 'NR==2{print $4}')"
[ -n "$FREE_KB" ] || FREE_KB="$(df -Pk / | awk 'NR==2{print $4}')"
echo "available_mb=$AVAIL_MB free_kb=$FREE_KB" | tee -a "$LOG"
(( AVAIL_MB >= 350 )) || { echo "FAIL: available RAM ${AVAIL_MB}MB < 350MB"; exit 1; }
(( FREE_KB >= 1400000 )) || { echo "FAIL: Docker disk free < 1.4GB"; exit 1; }

DOCKER_BUILDKIT=0 dc build --pull --no-cache -f "$DOCKERFILE" -t "$IMAGE" "$WORK" | tee -a "$LOG"

LABEL_VERSION="$(dc image inspect "$IMAGE" --format '{{index .Config.Labels "org.opencontainers.image.version"}}')"
UI_PATCH="$(dc image inspect "$IMAGE" --format '{{index .Config.Labels "io.quantnova.ui_patch"}}')"
PRICE_TRUTH_PATCH="$(dc image inspect "$IMAGE" --format '{{index .Config.Labels "io.quantnova.price_truth_patch"}}')"
EARLY_EDGE_POLICY="$(dc image inspect "$IMAGE" --format '{{index .Config.Labels "io.quantnova.early_edge_policy"}}')"
EARLY_EDGE_SCOPE="$(dc image inspect "$IMAGE" --format '{{index .Config.Labels "io.quantnova.early_edge_scope"}}')"
FRESH_SCOUT_CONTRACT="$(dc image inspect "$IMAGE" --format '{{index .Config.Labels "io.quantnova.fresh_scout_contract"}}')"
DISPLAY_HYSTERESIS="$(dc image inspect "$IMAGE" --format '{{index .Config.Labels "io.quantnova.display_hysteresis"}}')"
HOT_SELECTION="$(dc image inspect "$IMAGE" --format '{{index .Config.Labels "io.quantnova.hot_selection"}}')"
OFFICIAL_BUY_CHANGED="$(dc image inspect "$IMAGE" --format '{{index .Config.Labels "io.quantnova.official_buy_logic_changed"}}')"
[ "$LABEL_VERSION" = "$EXPECTED_VERSION" ]
[ "$UI_PATCH" = "$EXPECTED_UI_PATCH" ]
[ "$PRICE_TRUTH_PATCH" = "$EXPECTED_PRICE_TRUTH_PATCH" ]
[ "$EARLY_EDGE_POLICY" = "$EXPECTED_EARLY_EDGE_POLICY" ]
[ "$EARLY_EDGE_SCOPE" = "$EXPECTED_EARLY_EDGE_SCOPE" ]
[ "$FRESH_SCOUT_CONTRACT" = "$EXPECTED_FRESH_SCOUT_CONTRACT" ]
[ "$DISPLAY_HYSTERESIS" = "$EXPECTED_DISPLAY_HYSTERESIS" ]
[ "$HOT_SELECTION" = "$EXPECTED_HOT_SELECTION" ]
[ "$OFFICIAL_BUY_CHANGED" = "false" ]

say "4/8 ISOLATED CANDIDATE TEST"
mkdir -p "$CAND_DATA/nova30"
dc rm -f "$CANDIDATE" >/dev/null 2>&1 || true

CAND_ARGS=(run -d --name "$CANDIDATE" --network none --memory 384m --memory-swap 384m --pids-limit 256 --read-only --tmpfs /tmp:rw,noexec,nosuid,size=32m --env-file "$ENVFILE" -e NOVA_CANDIDATE_MODE=1 -e NOVA_OFFLINE=0 -e NOVA_DATA_DIR=/app/data/nova30 -v "$CAND_DATA/nova30:/app/data/nova30")
[ -n "$USER_SPEC" ] && CAND_ARGS+=(--user "$USER_SPEC")
CAND_ARGS+=("$IMAGE")
dc "${CAND_ARGS[@]}" >/dev/null
CAND_STARTED=1
wait_ready "$CANDIDATE"

dc exec "$CANDIDATE" env PYTHONPATH=/app python /app/scripts/master_audit.py | tee -a "$LOG"
dc exec "$CANDIDATE" env PYTHONPATH=/app python /app/scripts/max_profit_acceptance.py | tee -a "$LOG"
dc exec "$CANDIDATE" env PYTHONPATH=/app python /app/scripts/market_rotation_acceptance.py | tee -a "$LOG"
dc exec "$CANDIDATE" env PYTHONPATH=/app python /app/scripts/r42_fresh_scout_acceptance.py | tee -a "$LOG"
dc exec "$CANDIDATE" env PYTHONPATH=/app python -m unittest tests.test_fresh_scout_r42.FreshScoutR42Tests.test_hysteresis_holds_position_but_live_values_continue_changing tests.test_fresh_scout_r42.FreshScoutR42Tests.test_first_capture_top20_gets_fast_track_without_rank_velocity -v | tee -a "$LOG"
dc exec "$CANDIDATE" env PYTHONPATH=/app python /app/scripts/runtime_smoke.py --clients 2 --ready-timeout 30 | tee -a "$LOG"
dc exec "$CANDIDATE" env PYTHONPATH=/app python -m unittest tests.test_opening_profit_bridge_shadow.OpeningProfitBridgeShadowTest.test_active_session_never_renders_stale_reference_as_current tests.test_opening_profit_bridge_shadow.OpeningProfitBridgeShadowTest.test_active_session_renders_fresh_krx_truth_not_reference -v | tee -a "$LOG"
dc exec "$CANDIDATE" env PYTHONPATH=/app python -c "from pathlib import Path; import hashlib,time; from app.signal.early_edge import early_edge,discovery_freshness; from app.domain import Candidate,Venue; c=Candidate('R42TEST'); v=c.venue_state[Venue.KRX]; c.current_venue=Venue.KRX; now=time.time(); v.last_price=10000; v.last_rate=1.8; v.last_tick_at=now; v.metrics.update({'fresh':True,'buy_pressure':66,'buy_pressure_delta_30s':10,'turnover_accel_ready':True,'turnover_accel_30s':2.0,'compression':.8,'session_vwap_gap':.2,'micro_vwap_gap':.1,'impulse_60s':.4}); c.metrics.update({'discovery_first_seen_at':now-10,'discovery_best_rank':12,'discovery_new_sources_60s':1,'discovery_source_count':1,'discovery_rank_velocity_pos':0}); m=discovery_freshness(c,now); e=early_edge(c,now=now); assert m['fast_track'] and e['freshness_score']>=13 and not e['chase_block']; assert hashlib.sha256(Path('/app/app/signal/policy.py').read_bytes()).hexdigest()=='18cb96ef1afb9de48136d39c3e9b8216e62a94dccf0229aa027479783eb9151a'; print('R42_FAST_SCOUT_CANDIDATE=PASS',e['score'])" | tee -a "$LOG"

dc rm -f "$CANDIDATE" >/dev/null
CAND_STARTED=0

say "5/8 CUTOVER -- R4.2 FRESH-SCOUT + DISPLAY HYSTERESIS + PRICE TRUTH; BUY UNCHANGED"
dc rename "$APP" "$BACKUP"
OLD_RENAMED=1

RUN_ARGS=(run -d --name "$APP" --restart "$RESTART")
RUN_ARGS+=("${NETWORK_ARGS[@]}")
RUN_ARGS+=(--env-file "$ENVFILE")
RUN_ARGS+=("${MOUNT_ARGS[@]}" "${PORT_ARGS[@]}")
[ -n "$USER_SPEC" ] && RUN_ARGS+=(--user "$USER_SPEC")
[ "$READONLY" = true ] && RUN_ARGS+=(--read-only --tmpfs /tmp:rw,noexec,nosuid,size=32m)
(( MEMORY > 0 )) && RUN_ARGS+=(--memory "$MEMORY")
(( MEMSWAP > 0 )) && RUN_ARGS+=(--memory-swap "$MEMSWAP")
(( MEMRES > 0 )) && RUN_ARGS+=(--memory-reservation "$MEMRES")
[[ "$PIDSLIMIT" =~ ^[0-9]+$ ]] && (( PIDSLIMIT > 0 )) && RUN_ARGS+=(--pids-limit "$PIDSLIMIT")
RUN_ARGS+=("$IMAGE")

dc "${RUN_ARGS[@]}" >/dev/null
NEW_STARTED=1

PRIMARY_NET="${NETWORK_MODE:-default}"
for net in "${ALL_NETWORKS[@]}"; do
  [ -n "$net" ] || continue
  [ "$net" = "$PRIMARY_NET" ] && continue
  [ "$NETWORK_MODE" = "default" ] && [ "$net" = "bridge" ] && continue
  dc network connect "$net" "$APP" >/dev/null 2>&1 || true
done

wait_ready "$APP"

say "6/8 ACTIVE 3.3.4 VALIDATION"
dc exec "$APP" env PYTHONPATH=/app python /app/scripts/master_audit.py | tee -a "$LOG"
dc exec "$APP" env PYTHONPATH=/app python /app/scripts/max_profit_acceptance.py | tee -a "$LOG"
dc exec "$APP" env PYTHONPATH=/app python /app/scripts/market_rotation_acceptance.py | tee -a "$LOG"
dc exec "$APP" env PYTHONPATH=/app python /app/scripts/r42_fresh_scout_acceptance.py | tee -a "$LOG"
dc exec "$APP" env PYTHONPATH=/app python -m unittest tests.test_fresh_scout_r42.FreshScoutR42Tests.test_membership_is_anchor6_fresh4 tests.test_fresh_scout_r42.FreshScoutR42Tests.test_five_point_superiority_replaces_weakest_during_hold -v | tee -a "$LOG"
dc exec "$APP" env PYTHONPATH=/app python /app/scripts/runtime_smoke.py --clients 2 --ready-timeout 30 | tee -a "$LOG"
dc exec "$APP" env PYTHONPATH=/app python -c "from app.signal.early_edge import early_edge; from app.domain import Candidate,Venue; import time; c=Candidate('R4ACTIVE'); v=c.venue_state[Venue.KRX]; c.current_venue=Venue.KRX; v.last_price=10000; v.last_rate=10.5; v.last_tick_at=time.time(); v.metrics.update({'fresh':True,'buy_pressure':70,'buy_pressure_delta_30s':12,'turnover_accel_ready':True,'turnover_accel_30s':3.0,'compression':.8,'session_vwap_gap':.2,'micro_vwap_gap':.1,'impulse_60s':.5}); e=early_edge(c); assert e['score']<=45 and e['chase_block']; print('EARLY_EDGE_R4_CHASE_GUARD=PASS',e['score'])" | tee -a "$LOG"

say "7/8 UI PATCH + GUARD/CADDY IMMUTABILITY"
ACTIVE_UI_PATCH="$(dc image inspect "$IMAGE" --format '{{index .Config.Labels "io.quantnova.ui_patch"}}')"
ACTIVE_PRICE_TRUTH_PATCH="$(dc image inspect "$IMAGE" --format '{{index .Config.Labels "io.quantnova.price_truth_patch"}}')"
PRICE_TRUTH_PATCH="$(dc image inspect "$IMAGE" --format '{{index .Config.Labels "io.quantnova.price_truth_patch"}}')"
ACTIVE_EARLY_EDGE_POLICY="$(dc image inspect "$IMAGE" --format '{{index .Config.Labels "io.quantnova.early_edge_policy"}}')"
ACTIVE_EARLY_EDGE_SCOPE="$(dc image inspect "$IMAGE" --format '{{index .Config.Labels "io.quantnova.early_edge_scope"}}')"
ACTIVE_FRESH_SCOUT_CONTRACT="$(dc image inspect "$IMAGE" --format '{{index .Config.Labels "io.quantnova.fresh_scout_contract"}}')"
ACTIVE_DISPLAY_HYSTERESIS="$(dc image inspect "$IMAGE" --format '{{index .Config.Labels "io.quantnova.display_hysteresis"}}')"
ACTIVE_HOT_SELECTION="$(dc image inspect "$IMAGE" --format '{{index .Config.Labels "io.quantnova.hot_selection"}}')"
[ "$ACTIVE_UI_PATCH" = "$EXPECTED_UI_PATCH" ] || { echo "FAIL: ui_patch=$ACTIVE_UI_PATCH"; exit 1; }
[ "$ACTIVE_PRICE_TRUTH_PATCH" = "$EXPECTED_PRICE_TRUTH_PATCH" ] || { echo "FAIL: price_truth_patch=$ACTIVE_PRICE_TRUTH_PATCH"; exit 1; }
[ "$ACTIVE_EARLY_EDGE_POLICY" = "$EXPECTED_EARLY_EDGE_POLICY" ] || { echo "FAIL: early_edge_policy=$ACTIVE_EARLY_EDGE_POLICY"; exit 1; }
[ "$ACTIVE_EARLY_EDGE_SCOPE" = "$EXPECTED_EARLY_EDGE_SCOPE" ] || { echo "FAIL: early_edge_scope=$ACTIVE_EARLY_EDGE_SCOPE"; exit 1; }
[ "$ACTIVE_FRESH_SCOUT_CONTRACT" = "$EXPECTED_FRESH_SCOUT_CONTRACT" ] || { echo "FAIL: fresh_scout_contract=$ACTIVE_FRESH_SCOUT_CONTRACT"; exit 1; }
[ "$ACTIVE_DISPLAY_HYSTERESIS" = "$EXPECTED_DISPLAY_HYSTERESIS" ] || { echo "FAIL: display_hysteresis=$ACTIVE_DISPLAY_HYSTERESIS"; exit 1; }
[ "$ACTIVE_HOT_SELECTION" = "$EXPECTED_HOT_SELECTION" ] || { echo "FAIL: hot_selection=$ACTIVE_HOT_SELECTION"; exit 1; }

BEFORE="$(cat "$WORK/protected.before")"
AFTER="$(protected_snapshot)"
[ "$BEFORE" = "$AFTER" ] || { echo "FAIL: Guard/Caddy changed"; exit 1; }

say "8/8 SUCCESS"
dc ps --filter "name=^/${APP}$" --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}' | tee -a "$LOG"
SUCCESS=1
echo "RESULT=SUCCESS" | tee -a "$LOG"
echo "VERSION=$EXPECTED_VERSION" | tee -a "$LOG"
echo "UI_PATCH=$EXPECTED_UI_PATCH" | tee -a "$LOG"
echo "PRICE_TRUTH_PATCH=$EXPECTED_PRICE_TRUTH_PATCH" | tee -a "$LOG"
echo "EARLY_EDGE_POLICY=$EXPECTED_EARLY_EDGE_POLICY" | tee -a "$LOG"
echo "EARLY_EDGE_SCOPE=$EXPECTED_EARLY_EDGE_SCOPE" | tee -a "$LOG"
echo "FRESH_SCOUT=$EXPECTED_FRESH_SCOUT_CONTRACT" | tee -a "$LOG"
echo "DISPLAY_HYSTERESIS=$EXPECTED_DISPLAY_HYSTERESIS" | tee -a "$LOG"
echo "HOT_SELECTION=$EXPECTED_HOT_SELECTION" | tee -a "$LOG"
echo "CURRENT=$APP" | tee -a "$LOG"
echo "ROLLBACK_CONTAINER=$BACKUP" | tee -a "$LOG"
echo "GUARD=NOT_TOUCHED CADDY=NOT_TOUCHED BUY=ENTRY_V18_FROZEN" | tee -a "$LOG"
echo "LOG=$LOG"
