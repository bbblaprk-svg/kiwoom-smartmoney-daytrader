#!/usr/bin/env bash
set -euo pipefail
APP="${NOVA_APP_CONTAINER:-quant-nova}"
if docker info >/dev/null 2>&1; then D=(docker); elif sudo -n docker info >/dev/null 2>&1; then D=(sudo docker); else echo 'FAIL: Docker 권한 없음'; exit 2; fi
dc(){ "${D[@]}" "$@"; }
BACKUP="$(dc ps -a --format '{{.Names}}' | grep -E "^${APP}-pre-pricetruth-[0-9]{8}-[0-9]{6}$" | sort -r | head -n1 || true)"
[ -n "$BACKUP" ] || { echo 'FAIL: PRICE TRUTH 배포 전 백업 컨테이너를 찾지 못했습니다.'; exit 3; }
STAMP="$(date +%Y%m%d-%H%M%S)"
if dc inspect "$APP" >/dev/null 2>&1; then
  dc stop "$APP" >/dev/null 2>&1 || true
  dc rename "$APP" "${APP}-rollback-removed-${STAMP}" >/dev/null
fi
dc rename "$BACKUP" "$APP" >/dev/null
dc start "$APP" >/dev/null
for _ in $(seq 1 60); do
  S="$(dc inspect "$APP" --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' 2>/dev/null || true)"
  if [ "$S" = healthy ]; then echo "RESULT=ROLLED_BACK CURRENT=$APP"; exit 0; fi
  sleep 3
done
echo "FAIL: rollback container did not become healthy"; exit 4
