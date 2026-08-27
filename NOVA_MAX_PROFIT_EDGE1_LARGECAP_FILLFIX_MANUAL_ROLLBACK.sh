#!/usr/bin/env bash
set -Eeuo pipefail
APP="${NOVA_APP_CONTAINER:-quant-nova}"
BACKUP="${1:-}"
if docker info >/dev/null 2>&1; then D=(docker); elif sudo -n docker info >/dev/null 2>&1; then D=(sudo docker); else echo "FAIL: Docker 권한 없음"; exit 2; fi
dc(){ "${D[@]}" "$@"; }
if [[ -z "$BACKUP" ]]; then
  BACKUP="$(dc ps -a --format '{{.Names}}' | grep "^${APP}-pre-largecap-fillfix-" | sort | tail -1 || true)"
fi
[[ -n "$BACKUP" ]] || { echo "FAIL: largecap-fillfix 백업 컨테이너 없음"; exit 2; }
dc inspect "$BACKUP" >/dev/null 2>&1 || { echo "FAIL: 백업 없음: $BACKUP"; exit 2; }
FAILED="${APP}-failed-largecap-fillfix-$(date +%Y%m%d-%H%M%S)"
if dc inspect "$APP" >/dev/null 2>&1; then dc stop "$APP" >/dev/null 2>&1 || true; dc rename "$APP" "$FAILED"; fi
dc rename "$BACKUP" "$APP"
dc start "$APP"
echo "RESULT=ROLLBACK_SUCCESS"
echo "CURRENT=$APP"
echo "FAILED_CONTAINER=$FAILED"
