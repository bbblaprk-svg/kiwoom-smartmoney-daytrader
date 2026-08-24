#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

APP="${NOVA_APP_CONTAINER:-quant-nova}"
BASELINE_R492="NOVA-3.3.5-R492-FRESH-ENERGY-PATH-SAFE"
STAMP="$(date +%Y%m%d-%H%M%S)"
FAILED="${APP}-failed-manual-mmor1-to-r492-${STAMP}"
LOG="/tmp/nova-r492-mmor1-to-base-${STAMP}.log"
LOCKFILE="/tmp/nova-r492-mmor1-rollback.lock"

exec 9>"$LOCKFILE"
if ! flock -n 9; then
  echo "INFO: rollback is already running. Do not start it twice."
  exit 0
fi

if docker info >/dev/null 2>&1; then DOCKER=(docker)
elif sudo -n docker info >/dev/null 2>&1; then DOCKER=(sudo docker)
else echo "FAIL: Docker 권한을 확인할 수 없습니다."; exit 2
fi

dc(){ "${DOCKER[@]}" "$@"; }
wait_health(){
  local name="$1" i s
  for i in $(seq 1 72); do
    s="$(dc inspect "$name" --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' 2>/dev/null || true)"
    [ "$s" = "healthy" ] && return 0
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

if dc inspect "$APP" >/dev/null 2>&1 && [ "$(image_version "$APP")" = "$BASELINE_R492" ]; then
  dc start "$APP" >/dev/null 2>&1 || true
  wait_health "$APP"
  echo "RESULT=ALREADY_R492 VERSION=$BASELINE_R492 CURRENT=$APP" | tee -a "$LOG"
  exit 0
fi

SOURCE=""
while IFS= read -r cand; do
  [ -n "$cand" ] || continue
  [ "$cand" = "$APP" ] && continue
  [ "$(image_version "$cand")" = "$BASELINE_R492" ] || continue
  [ "$(dc inspect "$cand" --format '{{.State.Running}}' 2>/dev/null || true)" = "false" ] || continue
  SOURCE="$cand"
  break
done < <(dc ps -a --format '{{.Names}}' | sort -r || true)

[ -n "$SOURCE" ] || {
  echo "FAIL: exact R492 backup을 찾지 못했습니다. 현재 앱은 변경하지 않습니다." | tee -a "$LOG"
  exit 1
}
[ "$(image_version "$SOURCE")" = "$BASELINE_R492" ] || {
  echo "FAIL: rollback source version mismatch. 현재 앱은 변경하지 않습니다." | tee -a "$LOG"
  exit 1
}
echo "ROLLBACK_SOURCE=$SOURCE VERSION=$(image_version "$SOURCE")" | tee -a "$LOG"

if dc inspect "$APP" >/dev/null 2>&1; then
  dc stop -t 10 "$APP" >/dev/null 2>&1 || true
  dc rename "$APP" "$FAILED"
fi

dc stop -t 5 "$SOURCE" >/dev/null 2>&1 || true
dc rename "$SOURCE" "$APP"
dc start "$APP" >/dev/null
wait_health "$APP"
[ "$(image_version "$APP")" = "$BASELINE_R492" ] || {
  echo "FAIL: restored container is not exact R492" | tee -a "$LOG"
  exit 1
}

echo "RESULT=ROLLED_BACK CURRENT=$APP RESTORED_VERSION=$(image_version "$APP") FAILED_SAVED=$FAILED LOG=$LOG" | tee -a "$LOG"
