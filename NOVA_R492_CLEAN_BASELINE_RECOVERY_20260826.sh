#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

APP="${NOVA_APP_CONTAINER:-quant-nova}"
BASE_DOCKERFILE="Dockerfile_R492_BASELINE_20260825_143621"
BASE_SHA="0801d26de8bbb0a741051d4ac0b7bdeca20e400fa7c9e9eae4b4bc6fc325a358"
BASE_EMBEDDED_SHA="0d2f300af673c7187ae51b3ec9acc0e13e1dfaa6211d7b76a4f721130df632fc"
BASE_VERSION="NOVA-3.3.5-R492-MARKET-INDEX-VERIFY1"
BASE_URL="${NOVA_BASE_DOCKERFILE_URL:-https://raw.githubusercontent.com/bbblaprk-svg/kiwoom-smartmoney-daytrader/main/${BASE_DOCKERFILE}}"
IMAGE="${NOVA_BASE_IMAGE:-quant-nova:r492-baseline-20260825-143621}"
STAMP="$(date +%Y%m%d-%H%M%S)"
WORK="$(mktemp -d /tmp/nova-r492-clean-recovery.XXXXXX)"
LOG="/tmp/nova-r492-clean-recovery-${STAMP}.log"
ENVFILE="$WORK/runtime.env"
DOCKERFILE="$WORK/Dockerfile"
BACKUP="${APP}-pre-clean-recovery-${STAMP}"
SOURCE_CONTAINER=""
NEW_STARTED=0
CUTOVER_STARTED=0

if docker info >/dev/null 2>&1; then DOCKER=(docker)
elif sudo -n docker info >/dev/null 2>&1; then DOCKER=(sudo docker)
else echo "FAIL: Docker 권한을 확인할 수 없습니다."; exit 2
fi
dc(){ "${DOCKER[@]}" "$@"; }
say(){ printf '\n===== %s =====\n' "$*" | tee -a "$LOG"; }
cleanup(){ rm -rf -- "$WORK" 2>/dev/null || true; }
trap cleanup EXIT

zombies(){ ps -eo stat= 2>/dev/null | awk '$1 ~ /^Z/ {n++} END {print n+0}'; }

fetch(){
  local url="$1" out="$2"
  if command -v curl >/dev/null 2>&1; then
    curl -fL --retry 5 --retry-delay 2 --connect-timeout 10 "$url" -o "$out"
  elif command -v wget >/dev/null 2>&1; then
    wget -O "$out" "$url"
  else
    echo "FAIL: curl/wget 없음"; return 1
  fi
}

wait_health(){
  local name="$1" status
  for _ in $(seq 1 80); do
    status="$(dc inspect "$name" --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' 2>/dev/null || true)"
    if [ "$status" = healthy ]; then return 0; fi
    if [ "$status" = exited ] || [ "$status" = dead ]; then return 1; fi
    sleep 2
  done
  return 1
}

is_nova_container(){
  local name="$1" title
  title="$(dc inspect "$name" --format '{{index .Config.Labels "org.opencontainers.image.title"}}' 2>/dev/null || true)"
  [ "$title" = "QUANT NOVA" ] || [[ "$name" == quant-nova* ]]
}

rollback(){
  local rc=$?
  trap - ERR INT TERM
  say "ROLLBACK"
  if [ "$NEW_STARTED" -eq 1 ] && dc inspect "$APP" >/dev/null 2>&1; then
    dc logs --tail 200 "$APP" >>"$LOG" 2>&1 || true
    dc stop -t 15 "$APP" >/dev/null 2>&1 || true
    dc rm "$APP" >/dev/null 2>&1 || true
  fi
  if dc inspect "$BACKUP" >/dev/null 2>&1; then
    dc rename "$BACKUP" "$APP" >/dev/null 2>&1 || true
    dc start "$APP" >/dev/null 2>&1 || true
    wait_health "$APP" || true
  elif [ -n "$SOURCE_CONTAINER" ] && dc inspect "$SOURCE_CONTAINER" >/dev/null 2>&1; then
    dc start "$SOURCE_CONTAINER" >/dev/null 2>&1 || true
  fi
  echo "RESULT=ROLLED_BACK LOG=$LOG" | tee -a "$LOG"
  exit "${rc:-1}"
}
trap rollback ERR INT TERM

say "0. ROOT CAUSE INVENTORY — BEFORE TOUCHING ANYTHING"
echo "TIME=$(date -Is)" | tee -a "$LOG"
echo "HOST_ZOMBIES_BEFORE=$(zombies)" | tee -a "$LOG"
dc ps -a --format 'NAME={{.Names}} STATUS={{.Status}} IMAGE={{.Image}} ID={{.ID}}' | tee -a "$LOG"

mapfile -t RUNNING_NOVA < <(dc ps --format '{{.Names}}' | while read -r n; do if is_nova_container "$n"; then echo "$n"; fi; done)
echo "RUNNING_NOVA_COUNT=${#RUNNING_NOVA[@]} NAMES=${RUNNING_NOVA[*]:-(none)}" | tee -a "$LOG"

# Prefer the canonical container as the runtime-contract source. Otherwise use newest running NOVA.
if dc inspect "$APP" >/dev/null 2>&1; then
  SOURCE_CONTAINER="$APP"
elif [ "${#RUNNING_NOVA[@]}" -gt 0 ]; then
  SOURCE_CONTAINER="${RUNNING_NOVA[0]}"
else
  echo "FAIL: runtime contract를 복원할 NOVA 컨테이너가 없습니다." | tee -a "$LOG"
  exit 3
fi

echo "RUNTIME_SOURCE=$SOURCE_CONTAINER" | tee -a "$LOG"

say "1. FETCH + VERIFY EXACT 2026-08-25 14:36 BASELINE"
fetch "$BASE_URL" "$DOCKERFILE"
ACTUAL_SHA="$(sha256sum "$DOCKERFILE" | awk '{print $1}')"
echo "BASELINE_DOCKERFILE_SHA256=$ACTUAL_SHA" | tee -a "$LOG"
[ "$ACTUAL_SHA" = "$BASE_SHA" ] || { echo "FAIL: baseline SHA mismatch actual=$ACTUAL_SHA expected=$BASE_SHA"; exit 4; }
grep -Fq "org.opencontainers.image.version=\"$BASE_VERSION\"" "$DOCKERFILE"
grep -Fq "expected='$BASE_EMBEDDED_SHA'" "$DOCKERFILE"
if grep -Fq 'io.quantnova.fresh_rotation_fix=' "$DOCKERFILE"; then echo "FAIL: fresh-rotation mutation found in baseline"; exit 5; fi
if grep -Fq 'io.quantnova.market_index_price_truth=' "$DOCKERFILE"; then echo "FAIL: price-truth mutation found in baseline"; exit 5; fi

say "2. CAPTURE EXACT RUNTIME CONTRACT FROM $SOURCE_CONTAINER"
dc inspect "$SOURCE_CONTAINER" --format '{{range .Config.Env}}{{println .}}{{end}}' >"$ENVFILE"
chmod 600 "$ENVFILE"
RESTART="$(dc inspect "$SOURCE_CONTAINER" --format '{{.HostConfig.RestartPolicy.Name}}')"; [ -n "$RESTART" ] || RESTART=unless-stopped
NETMODE="$(dc inspect "$SOURCE_CONTAINER" --format '{{.HostConfig.NetworkMode}}')"
mapfile -t NETWORKS < <(dc inspect "$SOURCE_CONTAINER" --format '{{range $name, $_ := .NetworkSettings.Networks}}{{println $name}}{{end}}' | awk 'NF')
PRIMARY_NETWORK=""
NETWORK_ARGS=()
if [ "${#NETWORKS[@]}" -gt 0 ]; then PRIMARY_NETWORK="${NETWORKS[0]}"; NETWORK_ARGS+=(--network "$PRIMARY_NETWORK")
elif [ -n "$NETMODE" ] && [ "$NETMODE" != default ]; then PRIMARY_NETWORK="$NETMODE"; NETWORK_ARGS+=(--network "$PRIMARY_NETWORK"); fi

MOUNT_ARGS=()
while IFS='|' read -r TYPE SOURCE DEST RW NAME; do
  TYPE="$(xargs <<<"$TYPE")"; SOURCE="$(xargs <<<"$SOURCE")"; DEST="$(xargs <<<"$DEST")"; RW="$(xargs <<<"$RW")"; NAME="$(xargs <<<"$NAME")"
  [ -z "$TYPE" ] && continue
  MODE=""; [ "$RW" = true ] || MODE=":ro"
  if [[ "$DEST" == /app/* && "$DEST" != /app/data && "$DEST" != /app/data/* ]]; then
    echo "FAIL: source overwrite mount detected: $DEST"; exit 6
  fi
  if [ "$TYPE" = bind ]; then MOUNT_ARGS+=(-v "${SOURCE}:${DEST}${MODE}")
  elif [ "$TYPE" = volume ]; then MOUNT_ARGS+=(-v "${NAME}:${DEST}${MODE}"); fi
done < <(dc inspect "$SOURCE_CONTAINER" --format '{{range .Mounts}}{{println .Type "|" .Source "|" .Destination "|" .RW "|" .Name}}{{end}}')

PORT_ARGS=()
while IFS='|' read -r HOSTIP HOSTPORT CONTAINERPORT; do
  HOSTIP="$(xargs <<<"$HOSTIP")"; HOSTPORT="$(xargs <<<"$HOSTPORT")"; CONTAINERPORT="$(xargs <<<"$CONTAINERPORT")"
  [ -z "$HOSTPORT" ] && continue
  if [ -n "$HOSTIP" ] && [ "$HOSTIP" != 0.0.0.0 ]; then PORT_ARGS+=(-p "${HOSTIP}:${HOSTPORT}:${CONTAINERPORT}")
  else PORT_ARGS+=(-p "${HOSTPORT}:${CONTAINERPORT}"); fi
done < <(dc inspect "$SOURCE_CONTAINER" --format '{{range $port, $bindings := .NetworkSettings.Ports}}{{range $bindings}}{{println .HostIp "|" .HostPort "|" $port}}{{end}}{{end}}')

echo "NETWORK_MODE=$NETMODE NETWORKS=${NETWORKS[*]:-(none)} RESTART=$RESTART" | tee -a "$LOG"

say "3. STOP EVERY RUNNING QUANT NOVA INSTANCE — KEEP GUARD/CADDY UNTOUCHED"
for n in "${RUNNING_NOVA[@]}"; do
  echo "STOP_NOVA=$n" | tee -a "$LOG"
  dc stop -t 20 "$n" >/dev/null || true
done
sleep 3
echo "HOST_ZOMBIES_AFTER_NOVA_STOP=$(zombies)" | tee -a "$LOG"

# Preserve only the canonical source container as one stopped emergency backup.
if dc inspect "$SOURCE_CONTAINER" >/dev/null 2>&1; then
  dc rename "$SOURCE_CONTAINER" "$BACKUP"
  SOURCE_CONTAINER="$BACKUP"
fi

# Remove stale/failed duplicate NOVA containers. Never touch Guard/Caddy.
mapfile -t ALL_NOVA < <(dc ps -a --format '{{.Names}}' | while read -r n; do if is_nova_container "$n"; then echo "$n"; fi; done)
for n in "${ALL_NOVA[@]}"; do
  [ "$n" = "$BACKUP" ] && continue
  case "$n" in nova-http-guard|caddy|nova-caddy) continue;; esac
  echo "REMOVE_STALE_NOVA=$n" | tee -a "$LOG"
  dc rm -f "$n" >/dev/null 2>&1 || true
done

say "4. BUILD EXACT BASELINE — ORIGINAL DOCKERFILE RUNS ITS OWN FULL ACCEPTANCE"
mkdir -p "$WORK/buildctx"
cp "$DOCKERFILE" "$WORK/buildctx/Dockerfile"
dc build --progress=plain --pull -t "$IMAGE" "$WORK/buildctx" 2>&1 | tee -a "$LOG"
IMG_VER="$(dc image inspect "$IMAGE" --format '{{index .Config.Labels "org.opencontainers.image.version"}}')"
IMG_EMB="$(dc image inspect "$IMAGE" --format '{{index .Config.Labels "io.quantnova.embedded_source_sha256"}}' 2>/dev/null || true)"
[ "$IMG_VER" = "$BASE_VERSION" ] || { echo "FAIL: image version mismatch: $IMG_VER"; exit 7; }
# The baseline Dockerfile itself already validates embedded source during build; label may not exist on the old baseline.
echo "BASE_IMAGE=$IMAGE VERSION=$IMG_VER EMBEDDED_LABEL=${IMG_EMB:-legacy-none}" | tee -a "$LOG"

say "5. START ONE AND ONLY ONE BASELINE NOVA"
CUTOVER_STARTED=1
dc run -d --name "$APP" --restart "$RESTART" --env-file "$ENVFILE" \
  "${NETWORK_ARGS[@]}" "${MOUNT_ARGS[@]}" "${PORT_ARGS[@]}" "$IMAGE" >/dev/null
NEW_STARTED=1

# Connect any additional networks captured from the original runtime contract.
if [ "${#NETWORKS[@]}" -gt 1 ]; then
  for net in "${NETWORKS[@]:1}"; do dc network connect "$net" "$APP" >/dev/null 2>&1 || true; done
fi

wait_health "$APP" || { echo "FAIL: baseline quant-nova did not become healthy"; dc logs --tail 250 "$APP" | tee -a "$LOG"; exit 8; }

say "6. SINGLE-INSTANCE + HEALTH + PROCESS ACCEPTANCE"
mapfile -t FINAL_RUNNING < <(dc ps --format '{{.Names}}' | while read -r n; do if is_nova_container "$n"; then echo "$n"; fi; done)
printf 'FINAL_RUNNING_NOVA_COUNT=%s NAMES=%s\n' "${#FINAL_RUNNING[@]}" "${FINAL_RUNNING[*]:-(none)}" | tee -a "$LOG"
[ "${#FINAL_RUNNING[@]}" -eq 1 ] || { echo "FAIL: more than one NOVA is running"; exit 9; }
[ "${FINAL_RUNNING[0]}" = "$APP" ] || { echo "FAIL: canonical quant-nova is not the sole running NOVA"; exit 9; }

dc exec -i "$APP" python - <<'PY' | tee -a "$LOG"
import json,urllib.request
for path in ('/api/livez','/health'):
    try:
        with urllib.request.urlopen('http://127.0.0.1:8000'+path,timeout=4) as r:
            print(path, r.status, r.read(800).decode('utf-8','replace'))
    except Exception as e:
        print(path,'ERROR',repr(e))
PY

RUNNING_UVICORN="$(pgrep -af 'uvicorn app.main:app' | wc -l | tr -d ' ')"
HOST_Z_AFTER="$(zombies)"
echo "HOST_UVICORN_MATCHES=$RUNNING_UVICORN" | tee -a "$LOG"
echo "HOST_ZOMBIES_FINAL=$HOST_Z_AFTER" | tee -a "$LOG"
free -h | tee -a "$LOG"

dc ps --filter "name=^/${APP}$" --format 'CURRENT={{.Names}} STATUS={{.Status}} IMAGE={{.Image}}' | tee -a "$LOG"

echo "RESULT=SUCCESS BASELINE_SHA=$BASE_SHA SINGLE_NOVA=1 BACKUP_STOPPED=$BACKUP LOG=$LOG" | tee -a "$LOG"
if [ "$HOST_Z_AFTER" -gt 30 ]; then
  echo "NOTE=Host zombie count is still high after all duplicate NOVA containers were stopped. A controlled host reboot should be considered after confirming the dashboard is healthy." | tee -a "$LOG"
fi
trap - ERR INT TERM
