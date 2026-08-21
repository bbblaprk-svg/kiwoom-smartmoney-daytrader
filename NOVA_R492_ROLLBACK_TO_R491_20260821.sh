#!/usr/bin/env bash
set -Eeuo pipefail
umask 077
APP="${NOVA_APP_CONTAINER:-quant-nova}"
EXPECTED_R491_VERSION="NOVA-3.3.4-MARKET-WIDE-ROTATION-VERIFY"
STAMP="$(date +%Y%m%d-%H%M%S)"
FAILED="${APP}-failed-r492-manual-${STAMP}"
LOG="/tmp/nova-r492-manual-rollback-${STAMP}.log"
if docker info >/dev/null 2>&1; then DOCKER=(docker)
elif sudo -n docker info >/dev/null 2>&1; then DOCKER=(sudo docker)
else echo "FAIL: Docker 권한을 확인할 수 없습니다."; exit 2
fi
dc(){ "${DOCKER[@]}" "$@"; }
wait_health(){
  local name="$1" i status
  for i in $(seq 1 72); do
    status="$(dc inspect "$name" --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' 2>/dev/null || true)"
    [ "$status" = "healthy" ] && return 0
    sleep 5
  done
  return 1
}
BACKUP=""
while IFS= read -r cand; do
  [ -n "$cand" ] || continue
  iid="$(dc inspect "$cand" --format '{{.Image}}' 2>/dev/null || true)"
  ver="$(dc image inspect "$iid" --format '{{index .Config.Labels "org.opencontainers.image.version"}}' 2>/dev/null || true)"
  if [ "$ver" = "$EXPECTED_R491_VERSION" ]; then BACKUP="$cand"; break; fi
done < <(dc ps -a --format '{{.Names}}' | grep -E "^${APP}-pre-r492-[0-9]{8}-[0-9]{6}$" | sort -r)
[ -n "$BACKUP" ] || { echo "FAIL: 보존 컨테이너 중 승인 R491($EXPECTED_R491_VERSION)을 찾지 못했습니다."; exit 1; }
echo "ROLLBACK_SOURCE=$BACKUP EXPECTED_VERSION=$EXPECTED_R491_VERSION" | tee -a "$LOG"
if dc inspect "$APP" >/dev/null 2>&1; then
  dc stop -t 10 "$APP" >/dev/null 2>&1 || true
  dc rename "$APP" "$FAILED"
fi
dc rename "$BACKUP" "$APP"
dc start "$APP" >/dev/null
wait_health "$APP" || {
  echo "FAIL: 복구한 R491 health check 실패. R492 실패 컨테이너는 $FAILED 로 보존됨." | tee -a "$LOG"
  exit 1
}
dc exec "$APP" python - "$EXPECTED_R491_VERSION" <<'PY' | tee -a "$LOG"
import json,os,sys,urllib.request
expected=sys.argv[1]
token=(os.getenv('NOVA_UI_ACCESS_TOKEN') or os.getenv('APP_ACCESS_TOKEN') or '').strip()
h={'X-App-Token':token,'Authorization':'Bearer '+token} if token else {}
req=urllib.request.Request('http://127.0.0.1:8000/api/livez',headers=h)
with urllib.request.urlopen(req,timeout=5) as r:j=json.load(r)
assert j.get('ok'),j
assert j.get('version')==expected,(expected,j)
print(json.dumps({'ok':True,'restored_version':j.get('version'),'feed_state':j.get('feed_state')},ensure_ascii=False))
PY
echo "RESULT=R491_RESTORED CURRENT=$APP FAILED_R492=$FAILED LOG=$LOG" | tee -a "$LOG"
