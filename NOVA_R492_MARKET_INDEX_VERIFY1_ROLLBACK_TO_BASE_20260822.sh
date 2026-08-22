#!/usr/bin/env bash
set -Eeuo pipefail
umask 077
APP="${NOVA_APP_CONTAINER:-quant-nova}"
EXPECTED_R492_VERSION="NOVA-3.3.5-R492-FRESH-ENERGY-PATH-SAFE"
VERIFY1_VERSION="NOVA-3.3.5-R492-MARKET-INDEX-VERIFY1"
STAMP="$(date +%Y%m%d-%H%M%S)"
FAILED="${APP}-failed-miv1-manual-${STAMP}"
LOG="/tmp/nova-r492-miv1-rollback-${STAMP}.log"

if docker info >/dev/null 2>&1; then DOCKER=(docker)
elif sudo -n docker info >/dev/null 2>&1; then DOCKER=(sudo docker)
else echo "FAIL: Docker 권한을 확인할 수 없습니다."; exit 2
fi
dc(){ "${DOCKER[@]}" "$@"; }
image_version(){ local n="$1" iid; iid="$(dc inspect "$n" --format '{{.Image}}' 2>/dev/null || true)"; [ -n "$iid" ] || return 0; dc image inspect "$iid" --format '{{index .Config.Labels "org.opencontainers.image.version"}}' 2>/dev/null || true; }
wait_health(){ local n="$1" i s; for i in $(seq 1 72); do s="$(dc inspect "$n" --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' 2>/dev/null || true)"; [ "$s" = healthy ] && return 0; sleep 5; done; return 1; }

CURRENT="$(image_version "$APP")"
if [ "$CURRENT" = "$EXPECTED_R492_VERSION" ]; then
  echo "RESULT=ALREADY_R492 CURRENT=$APP VERSION=$CURRENT"
  exit 0
fi
if [ -n "$CURRENT" ] && [ "$CURRENT" != "$VERIFY1_VERSION" ]; then
  echo "FAIL: 현재 버전 $CURRENT 은 VERIFY1이 아니므로 자동 변경하지 않습니다."
  exit 1
fi

BACKUP=""
while IFS= read -r cand; do
  [ -n "$cand" ] || continue
  if [ "$(image_version "$cand")" = "$EXPECTED_R492_VERSION" ]; then BACKUP="$cand"; break; fi
done < <(dc ps -a --format '{{.Names}}' | grep -E "^${APP}-pre-miv1-[0-9]{8}-[0-9]{6}$" | sort -r || true)
[ -n "$BACKUP" ] || { echo "FAIL: 승인 R492 pre-miv1 백업을 찾지 못했습니다. 현재 앱은 변경하지 않습니다."; exit 1; }

echo "ROLLBACK_SOURCE=$BACKUP EXPECTED=$EXPECTED_R492_VERSION" | tee -a "$LOG"
if dc inspect "$APP" >/dev/null 2>&1; then
  dc stop -t 10 "$APP" >/dev/null 2>&1 || true
  dc rename "$APP" "$FAILED"
fi
dc rename "$BACKUP" "$APP"
dc start "$APP" >/dev/null
if ! wait_health "$APP"; then
  echo "CRITICAL: R492 health check failed. R492 container kept for inspection; failed VERIFY1 preserved as $FAILED" | tee -a "$LOG"
  exit 1
fi
RESTORED="$(image_version "$APP")"
[ "$RESTORED" = "$EXPECTED_R492_VERSION" ] || { echo "CRITICAL: restored version $RESTORED != $EXPECTED_R492_VERSION" | tee -a "$LOG"; exit 1; }

dc exec "$APP" python - "$EXPECTED_R492_VERSION" <<'PY' | tee -a "$LOG"
import json,os,sys,urllib.request
expected=sys.argv[1]
t=(os.getenv('NOVA_UI_ACCESS_TOKEN') or os.getenv('APP_ACCESS_TOKEN') or '').strip(); h={'X-App-Token':t,'Authorization':'Bearer '+t} if t else {}
with urllib.request.urlopen(urllib.request.Request('http://127.0.0.1:8000/api/livez',headers=h),timeout=8) as r:j=json.load(r)
assert j.get('ok') and j.get('version')==expected,j
print(json.dumps({'ok':True,'restored_version':expected},ensure_ascii=False))
PY

echo "RESULT=SUCCESS RESTORED=$APP VERSION=$RESTORED FAILED_VERIFY1=$FAILED LOG=$LOG" | tee -a "$LOG"
