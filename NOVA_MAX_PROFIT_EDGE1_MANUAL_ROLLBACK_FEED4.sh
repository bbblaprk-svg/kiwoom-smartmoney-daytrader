#!/usr/bin/env bash
set -Eeuo pipefail

APP="${NOVA_APP_CONTAINER:-quant-nova}"
BACKUP="${1:-}"
if [[ -z "$BACKUP" ]]; then
  echo "사용법: $0 <SAFE_CUTOVER가 출력한 ROLLBACK_CONTAINER>"
  exit 2
fi
[[ "$BACKUP" == "${APP}-pre-max-profit-edge1-"* ]] || { echo "FAIL: 허용되지 않은 백업 이름"; exit 2; }
if docker info >/dev/null 2>&1; then DOCKER=(docker)
elif sudo -n docker info >/dev/null 2>&1; then DOCKER=(sudo docker)
else echo "FAIL: Docker 실행 권한이 없습니다."; exit 2
fi
dc(){ "${DOCKER[@]}" "$@"; }
dc inspect "$APP" >/dev/null
dc inspect "$BACKUP" >/dev/null
FAILED="${APP}-manual-failed-$(date +%Y%m%d-%H%M%S)"

dc stop "$APP" >/dev/null
dc rename "$APP" "$FAILED"
if ! dc rename "$BACKUP" "$APP"; then
  dc rename "$FAILED" "$APP" >/dev/null 2>&1 || true
  dc start "$APP" >/dev/null 2>&1 || true
  echo "RESULT=ROLLBACK_FAILED RESTORED_NEW=${APP}"
  exit 1
fi
if ! dc start "$APP" >/dev/null; then
  dc rename "$APP" "$BACKUP" >/dev/null 2>&1 || true
  dc rename "$FAILED" "$APP" >/dev/null 2>&1 || true
  dc start "$APP" >/dev/null 2>&1 || true
  echo "RESULT=ROLLBACK_FAILED RESTORED_NEW=${APP}"
  exit 1
fi
for _ in $(seq 1 48); do
  STATUS="$(dc inspect "$APP" --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' 2>/dev/null || true)"
  if [[ "$STATUS" == healthy ]]; then
    echo "RESULT=ROLLBACK_SUCCESS CURRENT=${APP} FAILED_NEW=${FAILED}"
    exit 0
  fi
  sleep 5
done
dc logs --tail 200 "$APP" 2>&1 || true
dc stop "$APP" >/dev/null 2>&1 || true
if dc rename "$APP" "$BACKUP" >/dev/null 2>&1 && dc rename "$FAILED" "$APP" >/dev/null 2>&1; then
  if dc start "$APP" >/dev/null 2>&1; then
    echo "RESULT=ROLLBACK_REJECTED_OLD_UNHEALTHY RESTORED_NEW=${APP} OLD_BACKUP=${BACKUP}"
    exit 1
  fi
  dc rename "$APP" "$FAILED" >/dev/null 2>&1 || true
  dc rename "$BACKUP" "$APP" >/dev/null 2>&1 || true
  dc start "$APP" >/dev/null 2>&1 || true
fi
echo "RESULT=ROLLBACK_STARTED_BUT_NOT_HEALTHY CURRENT=${APP} FAILED_NEW=${FAILED}"
exit 1
