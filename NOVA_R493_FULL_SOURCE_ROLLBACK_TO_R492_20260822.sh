#!/usr/bin/env bash
set -Eeuo pipefail
umask 077
APP="${NOVA_APP_CONTAINER:-quant-nova}"
EXPECTED="NOVA-3.3.5-R492-FRESH-ENERGY-PATH-SAFE"
STAMP="$(date +%Y%m%d-%H%M%S)"
FAILED="${APP}-failed-r493-manual-${STAMP}"
LOG="/tmp/nova-r493-full-to-r492-${STAMP}.log"
if docker info >/dev/null 2>&1; then DOCKER=(docker)
elif sudo -n docker info >/dev/null 2>&1; then DOCKER=(sudo docker)
else echo "FAIL: Docker 권한을 확인할 수 없습니다."; exit 2
fi
dc(){ "${DOCKER[@]}" "$@"; }
wait_health(){ local n="$1" i s; for i in $(seq 1 72); do s="$(dc inspect "$n" --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' 2>/dev/null || true)"; [ "$s" = healthy ] && return 0; sleep 5; done; return 1; }
version_of(){ local n="$1" iid; iid="$(dc inspect "$n" --format '{{.Image}}' 2>/dev/null || true)"; [ -n "$iid" ] && dc image inspect "$iid" --format '{{index .Config.Labels "org.opencontainers.image.version"}}' 2>/dev/null || true; }
CURRENT="$(version_of "$APP")"
if [ "$CURRENT" = "$EXPECTED" ]; then wait_health "$APP"; echo "RESULT=ALREADY_R492 CURRENT=$APP VERSION=$CURRENT"; exit 0; fi
BACKUP=""
while IFS= read -r cand; do
  [ -n "$cand" ] || continue
  [ "$(version_of "$cand")" = "$EXPECTED" ] && { BACKUP="$cand"; break; }
done < <(dc ps -a --format '{{.Names}}' | grep -E "^${APP}-pre-r493-[0-9]{8}-[0-9]{6}$" | sort -r)
[ -n "$BACKUP" ] || { echo "FAIL: 승인 R492 백업을 찾지 못했습니다. 현재 앱은 변경하지 않습니다."; exit 1; }
echo "ROLLBACK_SOURCE=$BACKUP EXPECTED_VERSION=$EXPECTED" | tee -a "$LOG"
if dc inspect "$APP" >/dev/null 2>&1; then dc stop -t 10 "$APP" >/dev/null 2>&1 || true; dc rename "$APP" "$FAILED"; fi
dc rename "$BACKUP" "$APP"
dc start "$APP" >/dev/null
wait_health "$APP"
[ "$(version_of "$APP")" = "$EXPECTED" ] || { echo "FAIL: restored version mismatch"; exit 1; }
echo "RESULT=R492_RESTORED CURRENT=$APP FAILED_NEWER=$FAILED LOG=$LOG" | tee -a "$LOG"
