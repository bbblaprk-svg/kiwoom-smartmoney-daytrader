#!/usr/bin/env bash
set -euo pipefail
umask 077

APP="${NOVA_APP_CONTAINER:-quant-nova}"
EXPECTED_VERSION="NOVA-3.3.5-R492-MARKET-INDEX-VERIFY1"
EXPECTED_DOCKER_SHA="b0e1f57a69a0da7d7fd1a8dc48c0dd19f252749adfaf49c008448103ab2796bb"
EXPECTED_EMBEDDED_SHA="726fa88ba443a1776efdb8b2ca3c54ef9a9e6c48e666a7c0abbc22e3a5adb889"
EXPECTED_FIX="ACTIVE_VENUE_TRADE_ONLY_MAXAGE15"
DEFAULT_URL="https://raw.githubusercontent.com/bbblaprk-svg/kiwoom-smartmoney-daytrader/main/Dockerfile"
DOCKERFILE_SOURCE="${1:-${NOVA_DOCKERFILE_SOURCE:-}}"
IMAGE="${NOVA_PRICE_TRUTH_IMAGE:-quant-nova:r492-price-truth-20260826}"
STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP="${APP}-pre-pricetruth-${STAMP}"
FAILED="${APP}-failed-pricetruth-${STAMP}"
WORK="$(mktemp -d /tmp/nova-r492-pricetruth.XXXXXX)"
ENVFILE="$WORK/current.env"
BUILDCTX="$WORK/buildctx"
LOG="/tmp/nova-r492-pricetruth-${STAMP}.log"
NEW_STARTED=0
OLD_RENAMED=0
ROLLBACK_DONE=0

if docker info >/dev/null 2>&1; then DOCKER=(docker)
elif sudo -n docker info >/dev/null 2>&1; then DOCKER=(sudo docker)
else echo "FAIL: Docker 권한을 확인할 수 없습니다."; exit 2
fi
dc(){ "${DOCKER[@]}" "$@"; }
say(){ printf '\n===== %s =====\n' "$*" | tee -a "$LOG"; }
cleanup(){ rm -rf -- "$WORK" 2>/dev/null || true; }
wait_health(){
  local name="$1" status
  for _ in $(seq 1 60); do
    status="$(dc inspect "$name" --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' 2>/dev/null || true)"
    [ "$status" = "healthy" ] && return 0
    sleep 3
  done
  return 1
}
protected_snapshot(){
  for name in nova-http-guard caddy nova-caddy; do
    if dc inspect "$name" >/dev/null 2>&1; then printf '%s=%s\n' "$name" "$(dc inspect "$name" --format '{{.Id}}')"; fi
  done | sort
}
verify_protected_services(){
  [ -f "$WORK/protected.before" ] || return 0
  [ "$(cat "$WORK/protected.before")" = "$(protected_snapshot)" ]
}
rollback(){
  local rc=$?
  trap - ERR INT TERM
  [ "$ROLLBACK_DONE" -eq 0 ] || exit "${rc:-1}"
  ROLLBACK_DONE=1
  say "AUTO ROLLBACK -> EXACT PRE-CUTOVER CONTAINER"
  if [ "$NEW_STARTED" -eq 1 ] && dc inspect "$APP" >/dev/null 2>&1; then
    dc logs --tail 250 "$APP" >>"$LOG" 2>&1 || true
    dc stop "$APP" >/dev/null 2>&1 || true
    dc rename "$APP" "$FAILED" >/dev/null 2>&1 || true
  fi
  if [ "$OLD_RENAMED" -eq 1 ] && dc inspect "$BACKUP" >/dev/null 2>&1; then
    dc rename "$BACKUP" "$APP" >/dev/null 2>&1 || true
    dc start "$APP" >/dev/null 2>&1 || true
    wait_health "$APP" || true
  fi
  verify_protected_services || true
  echo "RESULT=ROLLED_BACK CURRENT=$APP FAILED=$FAILED LOG=$LOG" | tee -a "$LOG"
  cleanup
  exit "${rc:-1}"
}
fetch_file(){
  local src="$1" dest="$2"
  if [[ "$src" =~ ^https?:// ]]; then
    curl -fL --retry 3 --connect-timeout 10 "$src" -o "$dest"
  else
    cp -- "$src" "$dest"
  fi
}
recover_if_missing(){
  dc inspect "$APP" >/dev/null 2>&1 && return 0
  local candidate
  candidate="$(dc ps -a --format '{{.Names}}' | grep -E "^${APP}-pre-(freshrot|pricetruth)-[0-9]{8}-[0-9]{6}$" | sort -r | head -n1 || true)"
  [ -n "$candidate" ] || { echo "FAIL: $APP 컨테이너가 없고 복구 가능한 백업도 없습니다."; return 1; }
  dc rename "$candidate" "$APP" >/dev/null
  dc start "$APP" >/dev/null
  wait_health "$APP"
}
image_contract_ok(){
  dc image inspect "$IMAGE" >/dev/null 2>&1 || return 1
  local v f e r
  v="$(dc image inspect "$IMAGE" --format '{{index .Config.Labels "org.opencontainers.image.version"}}' 2>/dev/null || true)"
  f="$(dc image inspect "$IMAGE" --format '{{index .Config.Labels "io.quantnova.market_index_price_truth"}}' 2>/dev/null || true)"
  e="$(dc image inspect "$IMAGE" --format '{{index .Config.Labels "io.quantnova.embedded_source_sha256"}}' 2>/dev/null || true)"
  r="$(dc image inspect "$IMAGE" --format '{{index .Config.Labels "io.quantnova.data_supply_restore"}}' 2>/dev/null || true)"
  [ "$v" = "$EXPECTED_VERSION" ] && [ "$f" = "$EXPECTED_FIX" ] && [ "$e" = "$EXPECTED_EMBEDDED_SHA" ] && [ "$r" = "BASELINE_20260825_143621" ]
}
static_acceptance(){
  say "2A. PRICE TRUTH + BASELINE SUPPLY ACCEPTANCE"
  dc run --rm -w /app -e PYTHONPATH=/app --entrypoint python "$IMAGE" /app/scripts/r492_market_index_verify_acceptance.py | tee -a "$LOG"
  dc run --rm -w /app -e PYTHONPATH=/app --entrypoint python "$IMAGE" /app/scripts/r492_large_mid_pre_fixed_acceptance.py | tee -a "$LOG"
  dc run --rm --entrypoint sh "$IMAGE" -lc '
    echo "2b12de4c44af1242287c5b9883c2ffc4e646522d13a0dfa0a243c3e4c024fa59  /app/app/broker/discovery.py" | sha256sum -c - &&
    echo "50fefc5faa1457210af758636279bea0bc3926e505bc91317962a0d451e35602  /app/app/broker/websocket.py" | sha256sum -c - &&
    echo "e325b7a76d6ddfa291b800ef97fb13e6b85fa9bb9ccb2365130ef2d5abf512c3  /app/app/service.py" | sha256sum -c - &&
    echo "d8bd47d4b897237cd23abd645bc8b974b9d9e9029253ccdd58958827a8868642  /app/app/addons/large_mid_pre.py" | sha256sum -c - &&
    echo "11b799353ffee0720f37f7f7476c3ad5c19504000e67e9420abfcb04ac4fa3a4  /app/app/config.py" | sha256sum -c - &&
    echo "28e835a781ed4a0a00bf4ab1fb1f2dcfb6c3c23ed77750c492788a168c80451b  /app/app/runtime/state.py" | sha256sum -c -
  ' | tee -a "$LOG"
}

recover_if_missing
trap rollback ERR INT TERM

say "1. PRECHECK — DOCKERFILE + CURRENT CONTAINER"
dc inspect "$APP" >/dev/null
protected_snapshot >"$WORK/protected.before"
mkdir -p "$BUILDCTX"
if [ -n "$DOCKERFILE_SOURCE" ]; then
  fetch_file "$DOCKERFILE_SOURCE" "$BUILDCTX/Dockerfile"
elif [ -f ./Dockerfile ]; then
  cp -- ./Dockerfile "$BUILDCTX/Dockerfile"
else
  fetch_file "${NOVA_DOCKERFILE_URL:-$DEFAULT_URL}" "$BUILDCTX/Dockerfile"
fi
ACTUAL="$(sha256sum "$BUILDCTX/Dockerfile" | awk '{print $1}')"
[ "$ACTUAL" = "$EXPECTED_DOCKER_SHA" ] || { echo "FAIL: Dockerfile SHA mismatch actual=$ACTUAL expected=$EXPECTED_DOCKER_SHA"; exit 3; }
grep -Fq 'io.quantnova.market_index_price_truth="ACTIVE_VENUE_TRADE_ONLY_MAXAGE15"' "$BUILDCTX/Dockerfile"
grep -Fq 'io.quantnova.data_supply_restore="BASELINE_20260825_143621"' "$BUILDCTX/Dockerfile"
echo "DOCKERFILE_SHA256=$ACTUAL" | tee -a "$LOG"

if image_contract_ok; then
  say "2. REUSE EXACT PRICE-TRUTH IMAGE"
  echo "IMAGE_REUSE=YES IMAGE=$IMAGE" | tee -a "$LOG"
else
  say "2. BUILD PRICE-TRUTH IMAGE"
  dc build --progress=plain --pull -t "$IMAGE" "$BUILDCTX" 2>&1 | tee -a "$LOG"
  image_contract_ok
fi
static_acceptance

say "3. CAPTURE CURRENT RUNTIME CONTRACT"
dc inspect "$APP" --format '{{range .Config.Env}}{{println .}}{{end}}' >"$ENVFILE"
chmod 600 "$ENVFILE"
NETMODE="$(dc inspect "$APP" --format '{{.HostConfig.NetworkMode}}')"
mapfile -t NETWORKS < <(dc inspect "$APP" --format '{{range $name, $_ := .NetworkSettings.Networks}}{{println $name}}{{end}}' | awk 'NF')
NETWORK_ARGS=(); PRIMARY_NETWORK=""
if [ "${#NETWORKS[@]}" -gt 0 ] && [ -n "${NETWORKS[0]}" ]; then PRIMARY_NETWORK="${NETWORKS[0]}"; NETWORK_ARGS+=(--network "$PRIMARY_NETWORK")
elif [ -n "$NETMODE" ] && [ "$NETMODE" != "default" ] && [ "$NETMODE" != "bridge" ]; then PRIMARY_NETWORK="$NETMODE"; NETWORK_ARGS+=(--network "$PRIMARY_NETWORK"); fi
RESTART="$(dc inspect "$APP" --format '{{.HostConfig.RestartPolicy.Name}}')"; [ -n "$RESTART" ] || RESTART=unless-stopped
MOUNT_ARGS=()
while IFS='|' read -r TYPE SOURCE DEST RW NAME; do
  TYPE="$(xargs <<<"$TYPE")"; SOURCE="$(xargs <<<"$SOURCE")"; DEST="$(xargs <<<"$DEST")"; RW="$(xargs <<<"$RW")"; NAME="$(xargs <<<"$NAME")"
  [ -z "$TYPE" ] && continue; MODE=""; [ "$RW" = "true" ] || MODE=":ro"
  if [[ "$DEST" == /app/* && "$DEST" != /app/data && "$DEST" != /app/data/* ]]; then echo "FAIL: source override mount $DEST"; exit 4; fi
  if [ "$TYPE" = bind ]; then MOUNT_ARGS+=(-v "${SOURCE}:${DEST}${MODE}"); elif [ "$TYPE" = volume ]; then MOUNT_ARGS+=(-v "${NAME}:${DEST}${MODE}"); fi
done < <(dc inspect "$APP" --format '{{range .Mounts}}{{println .Type "|" .Source "|" .Destination "|" .RW "|" .Name}}{{end}}')
PORT_ARGS=()
while IFS='|' read -r HOSTIP HOSTPORT CONTAINERPORT; do
  HOSTIP="$(xargs <<<"$HOSTIP")"; HOSTPORT="$(xargs <<<"$HOSTPORT")"; CONTAINERPORT="$(xargs <<<"$CONTAINERPORT")"
  [ -z "$HOSTPORT" ] && continue
  if [ -n "$HOSTIP" ] && [ "$HOSTIP" != "0.0.0.0" ]; then PORT_ARGS+=(-p "${HOSTIP}:${HOSTPORT}:${CONTAINERPORT}"); else PORT_ARGS+=(-p "${HOSTPORT}:${CONTAINERPORT}"); fi
done < <(dc inspect "$APP" --format '{{range $port, $bindings := .NetworkSettings.Ports}}{{range $bindings}}{{println .HostIp "|" .HostPort "|" $port}}{{end}}{{end}}')
echo "NETWORK=${PRIMARY_NETWORK:-docker-default} RESTART=$RESTART" | tee -a "$LOG"

say "4. CUTOVER QUANT-NOVA ONLY"
dc stop "$APP" >/dev/null
dc rename "$APP" "$BACKUP" >/dev/null
OLD_RENAMED=1
dc run -d --name "$APP" --restart "$RESTART" --env-file "$ENVFILE" "${NETWORK_ARGS[@]}" "${MOUNT_ARGS[@]}" "${PORT_ARGS[@]}" "$IMAGE" >/dev/null
NEW_STARTED=1
if [ "${#NETWORKS[@]}" -gt 1 ]; then
  for net in "${NETWORKS[@]:1}"; do dc network connect "$net" "$APP" >/dev/null 2>&1 || true; done
fi
wait_health "$APP"
verify_protected_services

say "5. POST-CUTOVER INTERNAL ACCEPTANCE"
dc exec -e PYTHONPATH=/app -w /app "$APP" python /app/scripts/r492_market_index_verify_acceptance.py | tee -a "$LOG"
dc exec -e PYTHONPATH=/app -w /app "$APP" python /app/scripts/r492_large_mid_pre_fixed_acceptance.py | tee -a "$LOG"
dc exec "$APP" sh -lc "grep -Fq 'LIVE_PRICE_MAX_AGE_SEC = 15.0' /app/app/broker/market_index_verify.py && grep -Fq \"relative_price_truth_gate': 'ACTIVE_VENUE_TRADE_ONLY'\" /app/app/broker/market_index_verify.py"

trap - ERR INT TERM
say "6. SUCCESS"
echo "RESULT=SUCCESS VERSION=$EXPECTED_VERSION CURRENT=$APP ROLLBACK_CONTAINER=$BACKUP PRICE_TRUTH=ACTIVE_VENUE_MAXAGE15 DATA_SUPPLY=RESTORED_BASELINE_20260825_143621 NEW_WS_TYPE=0" | tee -a "$LOG"
cleanup
