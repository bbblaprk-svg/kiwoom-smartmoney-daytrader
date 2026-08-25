#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

REPO="bbblaprk-svg/kiwoom-smartmoney-daytrader"
BRANCH="main"
APP="${NOVA_APP_CONTAINER:-quant-nova}"
REMOTE_DOCKERFILE="Dockerfile"
EXPECTED_DOCKERFILE_SHA="a995560056f021a68d919bf2af11cb4825a3356eac46e5051aa65179c8290c2d"
EXPECTED_VERSION="NOVA-3.3.5-R492-MARKET-INDEX-VERIFY1"
EXPECTED_UIFIX7="CLOSE_FROZEN_PERSIST_TRISTATE_SPARSE_IO_R2"
BASE_R492="NOVA-3.3.5-R492-FRESH-ENERGY-PATH-SAFE"
IMAGE="quant-nova:photo-baseline-uifix7r2-20260825"
STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP="${APP}-pre-photo-uifix7r2-${STAMP}"
FAILED="${APP}-failed-photo-uifix7r2-${STAMP}"
WORK="$(mktemp -d /tmp/nova-photo-uifix7r2.XXXXXX)"
DOCKERFILE="$WORK/Dockerfile"
ENVFILE="$WORK/current.env"
LOG="/tmp/nova-photo-uifix7r2-restore-${STAMP}.log"
LOCKFILE="/tmp/nova-photo-uifix7r2-restore.lock"
STATE_MUTATED=0
OLD_WAS_RUNNING=0
NEW_STARTED=0

exec 9>"$LOCKFILE"
if ! flock -n 9; then
  echo "INFO: photo baseline restore already running"
  exit 0
fi

if docker info >/dev/null 2>&1; then DOCKER=(docker)
elif sudo -n docker info >/dev/null 2>&1; then DOCKER=(sudo docker)
else echo "FAIL: Docker 권한을 확인할 수 없습니다."; exit 2
fi

dc(){ "${DOCKER[@]}" "$@"; }
say(){ printf '\n===== %s =====\n' "$*" | tee -a "$LOG"; }
cleanup(){ rm -rf -- "$WORK" 2>/dev/null || true; }
image_id(){ dc inspect "$1" --format '{{.Image}}' 2>/dev/null || true; }
image_label(){ local iid; iid="$(image_id "$1")"; [ -n "$iid" ] || return 0; dc image inspect "$iid" --format "{{index .Config.Labels \"$2\"}}" 2>/dev/null | sed 's/^<no value>$//' || true; }
image_version(){ image_label "$1" org.opencontainers.image.version; }
wait_health(){
  local n="$1" i s
  for i in $(seq 1 72); do
    s="$(dc inspect "$n" --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' 2>/dev/null || true)"
    [ "$s" = "healthy" ] && return 0
    sleep 5
  done
  return 1
}

restore_previous(){
  local cur
  trap - ERR INT TERM
  if [ "$NEW_STARTED" -eq 1 ] && dc inspect "$APP" >/dev/null 2>&1; then
    dc logs --tail 200 "$APP" >>"$LOG" 2>&1 || true
    dc stop -t 5 "$APP" >/dev/null 2>&1 || true
    if dc inspect "$FAILED" >/dev/null 2>&1; then dc rm -f "$FAILED" >/dev/null 2>&1 || true; fi
    dc rename "$APP" "$FAILED" >/dev/null 2>&1 || true
  fi
  if dc inspect "$BACKUP" >/dev/null 2>&1; then
    dc rename "$BACKUP" "$APP" >/dev/null
    if [ "$OLD_WAS_RUNNING" -eq 1 ]; then dc start "$APP" >/dev/null; wait_health "$APP" || true; fi
  fi
  cur="$(image_version "$APP")"
  echo "RESULT=ROLLED_BACK CURRENT=$APP VERSION=${cur:-UNKNOWN} LOG=$LOG" | tee -a "$LOG"
  cleanup
  exit 1
}

on_error(){
  local rc=$?
  if [ "$STATE_MUTATED" -eq 1 ]; then restore_previous; fi
  trap - ERR INT TERM
  echo "RESULT=ABORTED_NO_CHANGE CURRENT=$APP LOG=$LOG" | tee -a "$LOG"
  cleanup
  exit "$rc"
}
trap on_error ERR INT TERM

say "1/7 FETCH PHOTO BASELINE DOCKERFILE + SHA LOCK"
raw="https://raw.githubusercontent.com/${REPO}/${BRANCH}/${REMOTE_DOCKERFILE}?ts=$(date +%s)"
curl -fL --retry 2 --retry-delay 2 --connect-timeout 10 --max-time 60 -H 'Cache-Control: no-cache' "$raw" -o "$DOCKERFILE"
ACTUAL_SHA="$(sha256sum "$DOCKERFILE" | awk '{print $1}')"
echo "DOCKERFILE_SHA256=$ACTUAL_SHA" | tee -a "$LOG"
[ "$ACTUAL_SHA" = "$EXPECTED_DOCKERFILE_SHA" ] || { echo "FAIL: GitHub Dockerfile이 사진 기준본과 다릅니다."; false; }
grep -Fq "org.opencontainers.image.version=\"$EXPECTED_VERSION\"" "$DOCKERFILE" || grep -Fq "org.opencontainers.image.version=\"NOVA-3.3.5-R492-MARKET-INDEX-VERIFY1\"" "$DOCKERFILE"
grep -Fq "io.quantnova.r492_uifix7=\"$EXPECTED_UIFIX7\"" "$DOCKERFILE"

say "2/7 VERIFY CURRENT APP + SNAPSHOT RUNTIME"
dc inspect "$APP" >/dev/null
CURRENT_VERSION="$(image_version "$APP")"
CURRENT_UIFIX7="$(image_label "$APP" io.quantnova.r492_uifix7)"
echo "current_version=${CURRENT_VERSION:-UNKNOWN} current_uifix7=${CURRENT_UIFIX7:-NONE}" | tee -a "$LOG"
if [ "$CURRENT_VERSION" = "$EXPECTED_VERSION" ] && [ "$CURRENT_UIFIX7" = "$EXPECTED_UIFIX7" ]; then
  wait_health "$APP"
  echo "RESULT=ALREADY_PHOTO_BASELINE VERSION=$CURRENT_VERSION UIFIX7=$CURRENT_UIFIX7 CURRENT=$APP LOG=$LOG"
  trap - ERR INT TERM
  cleanup
  exit 0
fi
[ "$CURRENT_VERSION" = "$BASE_R492" ] || {
  echo "FAIL: 현재 앱이 exact R492 또는 사진 기준 UIFIX7R2가 아닙니다. no change" | tee -a "$LOG"; false; }

[ "$(dc inspect "$APP" --format '{{.State.Running}}')" = "true" ] && OLD_WAS_RUNNING=1 || true
dc inspect "$APP" --format '{{range .Config.Env}}{{println .}}{{end}}' > "$ENVFILE"

NETWORK_MODE="$(dc inspect "$APP" --format '{{.HostConfig.NetworkMode}}' | xargs)"
mapfile -t NETWORKS < <(dc inspect "$APP" --format '{{range $name, $_ := .NetworkSettings.Networks}}{{println $name}}{{end}}' | awk 'NF' | sort -u)
case "$NETWORK_MODE" in
  host|none|container:*) PRIMARY_NETWORK="$NETWORK_MODE" ;;
  default|"") if [ "${#NETWORKS[@]}" -gt 0 ]; then PRIMARY_NETWORK="${NETWORKS[0]}"; else PRIMARY_NETWORK="bridge"; fi ;;
  *) if [ "${#NETWORKS[@]}" -gt 0 ]; then PRIMARY_NETWORK="${NETWORKS[0]}"; else PRIMARY_NETWORK="$NETWORK_MODE"; fi ;;
esac
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
  MODE=""; [ "$RW" = true ] || MODE=":ro"
  if [ "$TYPE" = bind ]; then MOUNT_ARGS+=( -v "${SOURCE}:${DEST}${MODE}" )
  elif [ "$TYPE" = volume ]; then MOUNT_ARGS+=( -v "${NAME}:${DEST}${MODE}" ); fi
done < <(dc inspect "$APP" --format '{{range .Mounts}}{{println .Type "|" .Source "|" .Destination "|" .RW "|" .Name}}{{end}}')

PORT_ARGS=()
while IFS='|' read -r HOSTIP HOSTPORT CONTAINERPORT; do
  HOSTIP="$(xargs <<<"$HOSTIP")"; HOSTPORT="$(xargs <<<"$HOSTPORT")"; CONTAINERPORT="$(xargs <<<"$CONTAINERPORT")"
  [ -z "$HOSTPORT" ] && continue
  if [ -n "$HOSTIP" ] && [ "$HOSTIP" != "0.0.0.0" ]; then PORT_ARGS+=( -p "${HOSTIP}:${HOSTPORT}:${CONTAINERPORT}" ); else PORT_ARGS+=( -p "${HOSTPORT}:${CONTAINERPORT}" ); fi
done < <(dc inspect "$APP" --format '{{range $port, $bindings := .NetworkSettings.Ports}}{{range $bindings}}{{println .HostIp "|" .HostPort "|" $port}}{{end}}{{end}}')

echo "runtime_snapshot=PASS network=$PRIMARY_NETWORK mounts=${#MOUNT_ARGS[@]} ports=${#PORT_ARGS[@]}" | tee -a "$LOG"

say "3/7 BUILD EXACT PHOTO BASELINE — CURRENT APP UNTOUCHED"
dc build --pull=false -t "$IMAGE" -f "$DOCKERFILE" "$WORK" | tee -a "$LOG"
[ "$(dc image inspect "$IMAGE" --format '{{index .Config.Labels "org.opencontainers.image.version"}}')" = "$EXPECTED_VERSION" ]
[ "$(dc image inspect "$IMAGE" --format '{{index .Config.Labels "io.quantnova.r492_uifix7"}}')" = "$EXPECTED_UIFIX7" ]

say "4/7 CUTOVER — PRESERVE EXACT CURRENT R492"
if [ "$OLD_WAS_RUNNING" -eq 1 ]; then dc stop -t 8 "$APP" >/dev/null; fi
dc rename "$APP" "$BACKUP"
STATE_MUTATED=1
[ "$(image_version "$BACKUP")" = "$BASE_R492" ]

RUN_ARGS=(run -d --name "$APP" --restart "$RESTART" --network "$PRIMARY_NETWORK" --env-file "$ENVFILE")
RUN_ARGS+=("${MOUNT_ARGS[@]}")
case "$PRIMARY_NETWORK" in host|none|container:*) ;; *) RUN_ARGS+=("${PORT_ARGS[@]}") ;; esac
[ -n "$USER_SPEC" ] && RUN_ARGS+=(--user "$USER_SPEC")
[ "$READONLY" = true ] && RUN_ARGS+=(--read-only --tmpfs /tmp:rw,noexec,nosuid,size=32m)
[[ "$MEMORY" =~ ^[0-9]+$ ]] && (( MEMORY > 0 )) && RUN_ARGS+=(--memory "$MEMORY")
[[ "$MEMSWAP" =~ ^-?[0-9]+$ ]] && (( MEMSWAP > 0 )) && RUN_ARGS+=(--memory-swap "$MEMSWAP")
[[ "$MEMRES" =~ ^[0-9]+$ ]] && (( MEMRES > 0 )) && RUN_ARGS+=(--memory-reservation "$MEMRES")
[[ "$PIDSLIMIT" =~ ^-?[0-9]+$ ]] && (( PIDSLIMIT > 0 )) && RUN_ARGS+=(--pids-limit "$PIDSLIMIT")
RUN_ARGS+=("$IMAGE")
dc "${RUN_ARGS[@]}" >/dev/null
NEW_STARTED=1
case "$PRIMARY_NETWORK" in host|none|container:*) ;; *)
  for net in "${NETWORKS[@]}"; do [ -n "$net" ] || continue; [ "$net" = "$PRIMARY_NETWORK" ] && continue; dc network connect "$net" "$APP" >/dev/null; done
;; esac

say "5/7 HEALTH + TARGET IDENTITY"
wait_health "$APP"
[ "$(image_version "$APP")" = "$EXPECTED_VERSION" ]
[ "$(image_label "$APP" io.quantnova.r492_uifix7)" = "$EXPECTED_UIFIX7" ]

say "6/7 RUNTIME SMOKE"
dc exec "$APP" python - <<'PY' | tee -a "$LOG"
import json, os, urllib.request
t=(os.getenv("NOVA_UI_ACCESS_TOKEN") or os.getenv("APP_ACCESS_TOKEN") or "").strip()
h={"X-App-Token":t,"Authorization":"Bearer "+t} if t else {}
def get(path):
    with urllib.request.urlopen(urllib.request.Request("http://127.0.0.1:8000"+path,headers=h),timeout=8) as r:
        return json.load(r)
live=get("/api/livez")
health=get("/api/realtime-health")
assert live.get("ok") is True, live
assert live.get("version")=="NOVA-3.3.5-R492-MARKET-INDEX-VERIFY1", live
m=health.get("memory") or {}
swap=float(m.get("swap_mb") or 0)
lag=float(health.get("event_loop_lag_p95_ms") or 0)
qage=float(health.get("trade_queue_oldest_age_ms") or 0)
assert swap <= 8.0, m
assert lag <= 250.0, health
assert qage <= 750.0, health
print(json.dumps({"runtime_smoke":"PASS","swap_mb":swap,"lag_p95_ms":lag,"queue_age_ms":qage},ensure_ascii=False))
PY

say "7/7 SUCCESS"
trap - ERR INT TERM
cleanup
echo "RESULT=SUCCESS PHOTO_BASELINE=UIFIX7R2 VERSION=$EXPECTED_VERSION UIFIX7=$EXPECTED_UIFIX7 CURRENT=$APP ROLLBACK_CONTAINER=$BACKUP LOG=$LOG"
