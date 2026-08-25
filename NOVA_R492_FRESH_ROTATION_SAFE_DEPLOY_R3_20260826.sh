#!/usr/bin/env bash
set -euo pipefail
umask 077

APP="${NOVA_APP_CONTAINER:-quant-nova}"
EXPECTED_VERSION="NOVA-3.3.5-R492-MARKET-INDEX-VERIFY1"
EXPECTED_DOCKER_SHA="0820ae66df2296690afba3f91324b1338488e707c2fa47d96af448bc0cd281bf"
EXPECTED_EMBEDDED_SHA="1674cb2277c42673f637c16dc9449703d9c384b28a75d0d9655a468f66293151"
EXPECTED_FIX="STALE_PIN_TTL900_MID10_SHADOW_FRESH_LASTLIVE_PERSIST_COLD2"
DEFAULT_URL="https://raw.githubusercontent.com/bbblaprk-svg/kiwoom-smartmoney-daytrader/main/Dockerfile"
DOCKERFILE_SOURCE="${1:-${NOVA_DOCKERFILE_SOURCE:-}}"
IMAGE="${NOVA_FRESHROT_IMAGE:-quant-nova:r492-freshrot-20260825}"
STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP="${APP}-pre-freshrot-${STAMP}"
FAILED="${APP}-failed-freshrot-${STAMP}"
WORK="$(mktemp -d /tmp/nova-r492-freshrot-r3.XXXXXX)"
ENVFILE="$WORK/current.env"
BUILDCTX="$WORK/buildctx"
LOG="/tmp/nova-r492-freshrot-r3-${STAMP}.log"
NEW_STARTED=0
OLD_RENAMED=0
OLD_STOPPED=0
ROLLBACK_DONE=0

if docker info >/dev/null 2>&1; then DOCKER=(docker)
elif sudo -n docker info >/dev/null 2>&1; then DOCKER=(sudo docker)
else echo "FAIL: Docker 권한을 확인할 수 없습니다."; exit 2
fi
dc(){ "${DOCKER[@]}" "$@"; }
say(){ printf '\n===== %s =====\n' "$*" | tee -a "$LOG"; }
cleanup(){
  if [ -d "$WORK" ] && [[ "$WORK" == /tmp/nova-r492-freshrot-r3.* ]]; then
    find "$WORK" -type f -exec chmod 600 {} \; 2>/dev/null || true
    rm -rf -- "$WORK"
  fi
}
protected_snapshot(){
  for name in nova-http-guard caddy nova-caddy; do
    if dc inspect "$name" >/dev/null 2>&1; then printf '%s=%s\n' "$name" "$(dc inspect "$name" --format '{{.Id}}')"; fi
  done | sort
}
wait_health(){
  local name="$1" status
  for _ in $(seq 1 60); do
    status="$(dc inspect "$name" --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' 2>/dev/null || true)"
    [ "$status" = "healthy" ] && return 0
    sleep 3
  done
  return 1
}
verify_protected_services(){
  local before after
  [ -f "$WORK/protected.before" ] || return 0
  before="$(cat "$WORK/protected.before")"; after="$(protected_snapshot)"
  [ "$before" = "$after" ] || { echo "FAIL: Guard/Caddy 컨테이너가 변경됐습니다." | tee -a "$LOG"; return 1; }
}
rollback(){
  local rc=$?
  trap - ERR INT TERM
  if [ "$ROLLBACK_DONE" -eq 1 ]; then exit "${rc:-1}"; fi
  ROLLBACK_DONE=1
  say "AUTO ROLLBACK -> EXACT PRE-CUTOVER CONTAINER"
  if [ "$NEW_STARTED" -eq 1 ] && dc inspect "$APP" >/dev/null 2>&1; then
    dc logs --tail 300 "$APP" >>"$LOG" 2>&1 || true
    dc stop "$APP" >/dev/null 2>&1 || true
    dc rename "$APP" "$FAILED" >/dev/null 2>&1 || true
  fi
  if [ "$OLD_RENAMED" -eq 1 ] && dc inspect "$BACKUP" >/dev/null 2>&1; then
    dc rename "$BACKUP" "$APP" >/dev/null 2>&1 || true
    dc start "$APP" >/dev/null 2>&1 || true
    wait_health "$APP" || true
  elif [ "$OLD_STOPPED" -eq 1 ] && dc inspect "$APP" >/dev/null 2>&1; then
    dc start "$APP" >/dev/null 2>&1 || true
    wait_health "$APP" || true
  fi
  verify_protected_services || true
  echo "RESULT=ROLLED_BACK CURRENT=$APP FAILED=$FAILED LOG=$LOG" | tee -a "$LOG"
  cleanup
  exit "${rc:-1}"
}
recover_previous_interrupted_cutover(){
  if dc inspect "$APP" >/dev/null 2>&1; then return 0; fi
  local candidate
  candidate="$(dc ps -a --format '{{.Names}}' | grep -E "^${APP}-pre-freshrot-[0-9]{8}-[0-9]{6}$" | sort -r | head -n1 || true)"
  [ -n "$candidate" ] || { echo "FAIL: $APP 컨테이너가 없고 복구 가능한 freshrot 백업도 없습니다."; return 1; }
  echo "RECOVER_PREVIOUS_INTERRUPTED=$candidate -> $APP"
  dc rename "$candidate" "$APP" >/dev/null
  dc start "$APP" >/dev/null
  wait_health "$APP" || { echo "FAIL: 이전 컨테이너 복구 후 healthy가 되지 않았습니다."; return 1; }
}
fetch_file(){
  local src="$1" dest="$2"
  if [[ "$src" =~ ^https?:// ]]; then
    if command -v curl >/dev/null 2>&1; then curl -fL --retry 3 --connect-timeout 10 "$src" -o "$dest"
    elif command -v wget >/dev/null 2>&1; then wget -O "$dest" "$src"
    else echo "FAIL: curl/wget 없음"; return 1; fi
  else
    cp -- "$src" "$dest"
  fi
}
image_contract_ok(){
  dc image inspect "$IMAGE" >/dev/null 2>&1 || return 1
  local v f e
  v="$(dc image inspect "$IMAGE" --format '{{index .Config.Labels "org.opencontainers.image.version"}}' 2>/dev/null || true)"
  f="$(dc image inspect "$IMAGE" --format '{{index .Config.Labels "io.quantnova.fresh_rotation_fix"}}' 2>/dev/null || true)"
  e="$(dc image inspect "$IMAGE" --format '{{index .Config.Labels "io.quantnova.embedded_source_sha256"}}' 2>/dev/null || true)"
  [ "$v" = "$EXPECTED_VERSION" ] && [ "$f" = "$EXPECTED_FIX" ] && [ "$e" = "$EXPECTED_EMBEDDED_SHA" ]
}
static_image_acceptance(){
  say "2A. EXACT IMAGE STATIC ACCEPTANCE"
  dc run --rm --entrypoint python "$IMAGE" /app/scripts/r492_large_mid_pre_fixed_acceptance.py | tee -a "$LOG"
  dc run --rm --entrypoint python "$IMAGE" /app/scripts/r492_market_index_verify_acceptance.py | tee -a "$LOG"
  dc run --rm --entrypoint python "$IMAGE" /app/scripts/r42_fresh_scout_acceptance.py | tee -a "$LOG"
  dc run --rm --entrypoint python "$IMAGE" /app/scripts/market_rotation_acceptance.py | tee -a "$LOG"
  dc run --rm --entrypoint sh "$IMAGE" -lc '
    test "$(sha256sum /app/app/signal/policy.py | awk '\''{print $1}'\'')" = 18cb96ef1afb9de48136d39c3e9b8216e62a94dccf0229aa027479783eb9151a &&
    test "$(sha256sum /app/app/broker/kiwoom.py | awk '\''{print $1}'\'')" = e10d936a2540a70d8a488e0460608a3c2a1a8bfaf95dc6206e706cce3afab0d1 &&
    test "$(sha256sum /app/app/broker/websocket.py | awk '\''{print $1}'\'')" = 50fefc5faa1457210af758636279bea0bc3926e505bc91317962a0d451e35602 &&
    test "$(sha256sum /app/app/broker/discovery.py | awk '\''{print $1}'\'')" = 2b12de4c44af1242287c5b9883c2ffc4e646522d13a0dfa0a243c3e4c024fa59 &&
    test "$(sha256sum /app/app/service.py | awk '\''{print $1}'\'')" = e325b7a76d6ddfa291b800ef97fb13e6b85fa9bb9ccb2365130ef2d5abf512c3 &&
    test "$(sha256sum /app/app/addons/energy_path.py | awk '\''{print $1}'\'')" = cd403cda76cb9d515c9228bf310287ad639bed125075fa835a3607cac2e81595 &&
    test "$(sha256sum /app/app/runtime/state.py | awk '\''{print $1}'\'')" = 28e835a781ed4a0a00bf4ab1fb1f2dcfb6c3c23ed77750c492788a168c80451b &&
    test "$(sha256sum /app/static/nova.js | awk '\''{print $1}'\'')" = 8f0904af264a3a8eda2d874dda25ce8086fb66d1751b592a9be0d6069b5ee1f6 &&
    test "$(sha256sum /app/ops/http_guard_v2.py | awk '\''{print $1}'\'')" = c07332eb6951c51b433f42059133dd22b5e28a0c137f07b9f177f814dbe1ec1b
  '
}

recover_previous_interrupted_cutover
trap rollback ERR INT TERM

say "1. CURRENT CONTAINER + DOCKERFILE PRECHECK — R3 REUSE-EXACT-IMAGE"
dc inspect "$APP" >/dev/null
protected_snapshot >"$WORK/protected.before"
mkdir -p "$BUILDCTX"
if [ -n "$DOCKERFILE_SOURCE" ]; then
  fetch_file "$DOCKERFILE_SOURCE" "$BUILDCTX/Dockerfile"
elif [ -f "$(cd "$(dirname "$0")" 2>/dev/null && pwd)/Dockerfile" ]; then
  cp -- "$(cd "$(dirname "$0")" && pwd)/Dockerfile" "$BUILDCTX/Dockerfile"
elif [ -f ./Dockerfile ]; then
  cp -- ./Dockerfile "$BUILDCTX/Dockerfile"
else
  fetch_file "${NOVA_DOCKERFILE_URL:-$DEFAULT_URL}" "$BUILDCTX/Dockerfile"
fi
ACTUAL_DOCKER_SHA="$(sha256sum "$BUILDCTX/Dockerfile" | awk '{print $1}')"
[ "$ACTUAL_DOCKER_SHA" = "$EXPECTED_DOCKER_SHA" ] || { echo "FAIL: Dockerfile SHA 불일치 actual=$ACTUAL_DOCKER_SHA expected=$EXPECTED_DOCKER_SHA"; exit 3; }
grep -Fq "io.quantnova.fresh_rotation_fix=\"$EXPECTED_FIX\"" "$BUILDCTX/Dockerfile"
grep -Fq "io.quantnova.embedded_source_sha256=\"$EXPECTED_EMBEDDED_SHA\"" "$BUILDCTX/Dockerfile"
echo "DOCKERFILE_SHA256=$ACTUAL_DOCKER_SHA" | tee -a "$LOG"

if image_contract_ok; then
  say "2. REUSE EXACT IMAGE — SKIP REDUNDANT FULL REBUILD"
  echo "IMAGE_REUSE=YES IMAGE=$IMAGE ID=$(dc image inspect "$IMAGE" --format '{{.Id}}')" | tee -a "$LOG"
else
  say "2. EXACT IMAGE ABSENT/MISMATCH — BUILD WITH CACHE"
  # Do not use --no-cache. The same Dockerfile already completed once; reuse exact successful layers when available.
  dc build --progress=plain --pull -t "$IMAGE" "$BUILDCTX" 2>&1 | tee -a "$LOG"
  image_contract_ok || { echo "FAIL: built image labels/contracts mismatch"; exit 5; }
fi
static_image_acceptance

say "3. CAPTURE EXACT CURRENT RUNTIME CONTRACT"
dc inspect "$APP" --format '{{range .Config.Env}}{{println .}}{{end}}' >"$ENVFILE"
chmod 600 "$ENVFILE"
NETMODE="$(dc inspect "$APP" --format '{{.HostConfig.NetworkMode}}')"
mapfile -t NETWORKS < <(dc inspect "$APP" --format '{{range $name, $_ := .NetworkSettings.Networks}}{{println $name}}{{end}}' | awk 'NF')
NETWORK_ARGS=(); PRIMARY_NETWORK=""
if [ "${#NETWORKS[@]}" -gt 0 ] && [ -n "${NETWORKS[0]}" ]; then
  PRIMARY_NETWORK="${NETWORKS[0]}"; NETWORK_ARGS+=( --network "$PRIMARY_NETWORK" )
elif [ -n "$NETMODE" ] && [ "$NETMODE" != "default" ]; then
  PRIMARY_NETWORK="$NETMODE"; NETWORK_ARGS+=( --network "$PRIMARY_NETWORK" )
fi
echo "RUNTIME_NETWORK_MODE=${NETMODE:-default} NETWORKS=${NETWORKS[*]:-(none)} PRIMARY=${PRIMARY_NETWORK:-docker-default}" | tee -a "$LOG"
RESTART="$(dc inspect "$APP" --format '{{.HostConfig.RestartPolicy.Name}}')"; [ -n "$RESTART" ] || RESTART=unless-stopped
MOUNT_ARGS=()
while IFS='|' read -r TYPE SOURCE DEST RW NAME; do
  TYPE="$(xargs <<<"$TYPE")"; SOURCE="$(xargs <<<"$SOURCE")"; DEST="$(xargs <<<"$DEST")"; RW="$(xargs <<<"$RW")"; NAME="$(xargs <<<"$NAME")"
  [ -z "$TYPE" ] && continue; MODE=""; [ "$RW" = "true" ] || MODE=":ro"
  if [[ "$DEST" == /app/* && "$DEST" != /app/data && "$DEST" != /app/data/* ]]; then echo "FAIL: 소스 덮어쓰기 마운트 감지 $DEST"; exit 4; fi
  if [ "$TYPE" = bind ]; then MOUNT_ARGS+=( -v "${SOURCE}:${DEST}${MODE}" )
  elif [ "$TYPE" = volume ]; then MOUNT_ARGS+=( -v "${NAME}:${DEST}${MODE}" ); fi
done < <(dc inspect "$APP" --format '{{range .Mounts}}{{println .Type "|" .Source "|" .Destination "|" .RW "|" .Name}}{{end}}')
PORT_ARGS=()
while IFS='|' read -r HOSTIP HOSTPORT CONTAINERPORT; do
  HOSTIP="$(xargs <<<"$HOSTIP")"; HOSTPORT="$(xargs <<<"$HOSTPORT")"; CONTAINERPORT="$(xargs <<<"$CONTAINERPORT")"
  [ -z "$HOSTPORT" ] && continue
  if [ -n "$HOSTIP" ] && [ "$HOSTIP" != "0.0.0.0" ]; then PORT_ARGS+=( -p "${HOSTIP}:${HOSTPORT}:${CONTAINERPORT}" )
  else PORT_ARGS+=( -p "${HOSTPORT}:${CONTAINERPORT}" ); fi
done < <(dc inspect "$APP" --format '{{range $port, $bindings := .NetworkSettings.Ports}}{{range $bindings}}{{println .HostIp "|" .HostPort "|" $port}}{{end}}{{end}}')

say "4. CUTOVER QUANT-NOVA ONLY"
dc stop "$APP" >/dev/null; OLD_STOPPED=1
dc rename "$APP" "$BACKUP"; OLD_RENAMED=1
dc run -d --name "$APP" --restart "$RESTART" "${NETWORK_ARGS[@]}" --env-file "$ENVFILE" "${MOUNT_ARGS[@]}" "${PORT_ARGS[@]}" "$IMAGE" >/dev/null
NEW_STARTED=1
if [ "${#NETWORKS[@]}" -gt 1 ]; then
  for net in "${NETWORKS[@]:1}"; do [ -n "$net" ] && dc network connect "$net" "$APP" >/dev/null; done
fi
wait_health "$APP"

say "5. INTERNAL R492 / FRESH ROTATION ACCEPTANCE"
dc exec "$APP" python /app/scripts/r492_large_mid_pre_fixed_acceptance.py | tee -a "$LOG"
dc exec "$APP" python /app/scripts/r492_market_index_verify_acceptance.py | tee -a "$LOG"
dc exec "$APP" python /app/scripts/r42_fresh_scout_acceptance.py | tee -a "$LOG"
dc exec "$APP" python /app/scripts/market_rotation_acceptance.py | tee -a "$LOG"
dc exec "$APP" python - "$EXPECTED_VERSION" <<'PY' | tee -a "$LOG"
import json,os,sys,urllib.request
expected=sys.argv[1]
token=os.getenv('NOVA_UI_ACCESS_TOKEN','').strip()
headers={'X-App-Token':token,'Authorization':'Bearer '+token} if token else {}
def get(path):
    req=urllib.request.Request('http://127.0.0.1:8000'+path,headers=headers)
    with urllib.request.urlopen(req,timeout=8) as r:return json.load(r)
live=get('/api/livez'); lmp=get('/api/large-mid-pre'); health=get('/api/realtime-health')
assert live.get('ok') and live.get('version')==expected,live
ct=lmp.get('contracts') or {}; pipe=lmp.get('pipeline') or {}
assert ct.get('fixed_slots')==20 and ct.get('primary_slots')==10 and ct.get('shadow_slots')==10,ct
assert ct.get('fresh_slot_cap')==10,ct
assert float(ct.get('stale_signal_pin_ttl_sec') or 0)==900.0,ct
assert ct.get('close_snapshot_persisted') is True and ct.get('closed_cold_bootstrap_rest_max')==2,ct
assert ct.get('official_buy_logic_changed') is False and ct.get('official_pre_membership_changed') is False,ct
assert ct.get('existing_discovery_rank_calls_changed') is False,ct
assert ct.get('new_ws_subscription_types')==0 and ct.get('ws_item_ceiling_increase')==0,ct
assert ct.get('additional_rest_calls_per_refresh_max')==2,ct
assert lmp.get('data_state') in ('LIVE','FROZEN','FROZEN_RECONSTRUCTED','NO_DATA'),lmp.get('data_state')
tele=health.get('telemetry') or {}; ws=health.get('ws') or {}
assert int(tele.get('signal_price_mismatch_count') or 0)==0,tele.get('signal_price_mismatch_count')
assert int(tele.get('wrong_venue_price_count') or 0)==0,tele.get('wrong_venue_price_count')
print(json.dumps({'ok':True,'version':expected,'large_mid_state':lmp.get('data_state'),'pipeline':pipe,'fresh_slot_cap':ct.get('fresh_slot_cap'),'stale_pin_ttl_sec':ct.get('stale_signal_pin_ttl_sec'),'ws_registered':ws.get('registered'),'official_buy_changed':False,'official_pre_changed':False},ensure_ascii=False))
PY
verify_protected_services

say "6. SUCCESS"
trap - ERR INT TERM
echo "RESULT=SUCCESS VERSION=$EXPECTED_VERSION CURRENT=$APP ROLLBACK_CONTAINER=$BACKUP" | tee -a "$LOG"
echo "IMAGE_STRATEGY=REUSE_EXACT_IF_PRESENT BUILD_CACHE_IF_NEEDED NO_REDUNDANT_NO_CACHE_REBUILD=1" | tee -a "$LOG"
echo "FRESH_ROTATION=STALE_PIN_TTL900 MID_CAP_SLOTS_MAX10 SHADOW_FRESH_PRIORITY LASTLIVE_PERSIST=ON" | tee -a "$LOG"
echo "PROTECTED_CORE=9/9 BUY_PRE_NXT_ENERGY_PATH=UNCHANGED NEW_WS_TYPE=0 WS_CEILING_DELTA=0" | tee -a "$LOG"
echo "LOG=$LOG"
cleanup
