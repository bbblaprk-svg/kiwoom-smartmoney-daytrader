#!/usr/bin/env bash
set -Eeuo pipefail
umask 077
APP="${NOVA_APP_CONTAINER:-quant-nova}"
TARGET_VERSION="NOVA-3.3.5-R492-MARKET-INDEX-VERIFY1"
TARGET_UIFIX7="CLOSE_FROZEN_PERSIST_TRISTATE_SPARSE_IO_R2"
BASE_R492="NOVA-3.3.5-R492-FRESH-ENERGY-PATH-SAFE"
STAMP="$(date +%Y%m%d-%H%M%S)"
FAILED="${APP}-failed-photo-uifix7r2-manual-${STAMP}"

if docker info >/dev/null 2>&1; then DOCKER=(docker)
elif sudo -n docker info >/dev/null 2>&1; then DOCKER=(sudo docker)
else echo "FAIL: Docker 권한을 확인할 수 없습니다."; exit 2
fi
dc(){ "${DOCKER[@]}" "$@"; }
image_id(){ dc inspect "$1" --format '{{.Image}}' 2>/dev/null || true; }
image_label(){ local iid; iid="$(image_id "$1")"; [ -n "$iid" ] || return 0; dc image inspect "$iid" --format "{{index .Config.Labels \"$2\"}}" 2>/dev/null | sed 's/^<no value>$//' || true; }
image_version(){ image_label "$1" org.opencontainers.image.version; }
wait_health(){ local n="$1" i s; for i in $(seq 1 72); do s="$(dc inspect "$n" --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' 2>/dev/null || true)"; [ "$s" = healthy ] && return 0; sleep 5; done; return 1; }

CURRENT="$(image_version "$APP")"
CURRENT_UIFIX7="$(image_label "$APP" io.quantnova.r492_uifix7)"
if [ "$CURRENT" = "$BASE_R492" ]; then
  echo "RESULT=ALREADY_R492 CURRENT=$APP VERSION=$CURRENT"
  exit 0
fi
[ "$CURRENT" = "$TARGET_VERSION" ] && [ "$CURRENT_UIFIX7" = "$TARGET_UIFIX7" ] || {
  echo "FAIL: 현재 앱이 사진 기준 UIFIX7R2가 아닙니다. no change"; exit 1; }

BACKUP=""
while IFS= read -r cand; do
  [ -n "$cand" ] || continue
  if [ "$(image_version "$cand")" = "$BASE_R492" ]; then BACKUP="$cand"; break; fi
done < <(dc ps -a --format '{{.Names}}' | grep -E "^${APP}-pre-photo-uifix7r2-[0-9]{8}-[0-9]{6}$" | sort -r || true)
[ -n "$BACKUP" ] || { echo "FAIL: 사진 기준 배포 직전 exact R492 백업을 찾지 못했습니다. no change"; exit 1; }

dc stop -t 8 "$APP" >/dev/null 2>&1 || true
dc rename "$APP" "$FAILED"
dc rename "$BACKUP" "$APP"
dc start "$APP" >/dev/null
wait_health "$APP"
[ "$(image_version "$APP")" = "$BASE_R492" ]
echo "RESULT=ROLLED_BACK CURRENT=$APP VERSION=$BASE_R492 FAILED_SAVED=$FAILED"
