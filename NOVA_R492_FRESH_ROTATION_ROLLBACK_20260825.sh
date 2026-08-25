#!/usr/bin/env bash
set -Eeuo pipefail
APP="${NOVA_APP_CONTAINER:-quant-nova}"
BACKUP="${1:-}"
if docker info >/dev/null 2>&1; then DOCKER=(docker)
elif sudo -n docker info >/dev/null 2>&1; then DOCKER=(sudo docker)
else echo "FAIL: Docker 권한 없음"; exit 2
fi
dc(){ "${DOCKER[@]}" "$@"; }
protected_snapshot(){
  for name in nova-http-guard caddy nova-caddy; do
    if dc inspect "$name" >/dev/null 2>&1; then printf '%s=%s\n' "$name" "$(dc inspect "$name" --format '{{.Id}}')"; fi
  done | sort
}
BEFORE="$(protected_snapshot)"
if [ -z "$BACKUP" ]; then
  BACKUP="$(dc ps -a --format '{{.Names}}' | grep -E "^${APP}-pre-freshrot-[0-9]{8}-[0-9]{6}$" | sort | tail -1 || true)"
fi
[ -n "$BACKUP" ] || { echo "FAIL: freshrot 이전 백업 컨테이너를 찾지 못했습니다."; exit 2; }
[[ "$BACKUP" == "${APP}-pre-freshrot-"* ]] || { echo "FAIL: 허용되지 않은 백업 이름 $BACKUP"; exit 2; }
dc inspect "$APP" >/dev/null
dc inspect "$BACKUP" >/dev/null
FAILED="${APP}-manual-failed-freshrot-$(date +%Y%m%d-%H%M%S)"
dc stop "$APP" >/dev/null
dc rename "$APP" "$FAILED"
restore_new(){
  dc rename "$FAILED" "$APP" >/dev/null 2>&1 || true
  dc start "$APP" >/dev/null 2>&1 || true
}
if ! dc rename "$BACKUP" "$APP"; then restore_new; echo "RESULT=ROLLBACK_FAILED RESTORED_NEW=$APP"; exit 1; fi
if ! dc start "$APP" >/dev/null; then
  dc rename "$APP" "$BACKUP" >/dev/null 2>&1 || true
  restore_new
  echo "RESULT=ROLLBACK_FAILED RESTORED_NEW=$APP"; exit 1
fi
for _ in $(seq 1 60); do
  STATUS="$(dc inspect "$APP" --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' 2>/dev/null || true)"
  if [ "$STATUS" = healthy ]; then
    AFTER="$(protected_snapshot)"
    [ "$BEFORE" = "$AFTER" ] || { echo "RESULT=ROLLBACK_GUARD_CADDY_CHANGED CURRENT=$APP"; exit 1; }
    echo "RESULT=ROLLBACK_SUCCESS CURRENT=$APP FAILED_NEW=$FAILED RESTORED_BACKUP=$BACKUP GUARD=NOT_TOUCHED CADDY=NOT_TOUCHED"
    exit 0
  fi
  sleep 3
done
echo "RESULT=ROLLBACK_STARTED_BUT_NOT_HEALTHY CURRENT=$APP FAILED_NEW=$FAILED"
exit 1
