#!/usr/bin/env bash
set -Eeuo pipefail
umask 077
APP="${NOVA_APP_CONTAINER:-quant-nova}"
EXPECTED_VERSION="NOVA-3.3.5-R492-MARKET-INDEX-VERIFY1"
EXPECTED_UIFIX_LABEL="FULL_EDGE_REACCEL_ALERTS_CLOSED_LOOP_VERIFY"
STAMP="$(date +%Y%m%d-%H%M%S)"
FAILED="${APP}-failed-uifix6-full-edge-manual-${STAMP}"
LOG="/tmp/nova-r492-miv1-uifix6-full-edge-rollback-${STAMP}.log"

if docker info >/dev/null 2>&1; then DOCKER=(docker)
elif sudo -n docker info >/dev/null 2>&1; then DOCKER=(sudo docker)
else echo "FAIL: Docker 권한을 확인할 수 없습니다."; exit 2
fi
dc(){ "${DOCKER[@]}" "$@"; }
image_id(){ dc inspect "$1" --format '{{.Image}}' 2>/dev/null || true; }
image_version(){ local iid; iid="$(image_id "$1")"; [ -n "$iid" ] || return 0; dc image inspect "$iid" --format '{{index .Config.Labels "org.opencontainers.image.version"}}' 2>/dev/null || true; }
image_uifix(){ local iid out; iid="$(image_id "$1")"; [ -n "$iid" ] || return 0; out="$(dc image inspect "$iid" --format '{{index .Config.Labels "io.quantnova.r492_uifix6"}}' 2>/dev/null || true)"; [ "$out" = "<no value>" ] && out=""; printf '%s' "$out"; }
wait_health(){ local n="$1" i s; for i in $(seq 1 72); do s="$(dc inspect "$n" --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' 2>/dev/null || true)"; [ "$s" = healthy ] && return 0; sleep 5; done; return 1; }

CURRENT_VERSION="$(image_version "$APP")"
CURRENT_FIX="$(image_uifix "$APP")"
if [ "$CURRENT_VERSION" = "$EXPECTED_VERSION" ] && [ "$CURRENT_FIX" != "$EXPECTED_UIFIX_LABEL" ]; then
  echo "RESULT=ALREADY_PRE_UIFIX6_MIV1 CURRENT=$APP VERSION=$CURRENT_VERSION"
  exit 0
fi
[ "$CURRENT_VERSION" = "$EXPECTED_VERSION" ] || { echo "FAIL: current version $CURRENT_VERSION is not MIV1; no change."; exit 1; }
[ "$CURRENT_FIX" = "$EXPECTED_UIFIX_LABEL" ] || { echo "FAIL: current app is not UIFIX6; no change."; exit 1; }

BACKUP=""
while IFS= read -r cand; do
  [ -n "$cand" ] || continue
  if [ "$(image_version "$cand")" = "$EXPECTED_VERSION" ] && [ "$(image_uifix "$cand")" != "$EXPECTED_UIFIX_LABEL" ]; then BACKUP="$cand"; break; fi
done < <(dc ps -a --format '{{.Names}}' | grep -E "^${APP}-pre-uifix6-[0-9]{8}-[0-9]{6}$" | sort -r || true)
[ -n "$BACKUP" ] || { echo "FAIL: exact pre-UIFIX6 MIV1 backup not found; current app unchanged."; exit 1; }
BACKUP_IMAGE_ID="$(image_id "$BACKUP")"
echo "ROLLBACK_SOURCE=$BACKUP IMAGE_ID=$BACKUP_IMAGE_ID VERSION=$(image_version "$BACKUP")" | tee -a "$LOG"

if dc inspect "$APP" >/dev/null 2>&1; then
  dc stop -t 10 "$APP" >/dev/null 2>&1 || true
  dc rename "$APP" "$FAILED"
fi
dc rename "$BACKUP" "$APP"
dc start "$APP" >/dev/null
if ! wait_health "$APP"; then
  echo "CRITICAL: pre-UIFIX6 exact image health failed. Restored container kept for inspection; failed UIFIX6 preserved as $FAILED" | tee -a "$LOG"
  exit 1
fi
RESTORED_VERSION="$(image_version "$APP")"
RESTORED_FIX="$(image_uifix "$APP")"
[ "$RESTORED_VERSION" = "$EXPECTED_VERSION" ] || { echo "CRITICAL: restored version mismatch" | tee -a "$LOG"; exit 1; }
[ "$RESTORED_FIX" != "$EXPECTED_UIFIX_LABEL" ] || { echo "CRITICAL: rollback target still UIFIX6" | tee -a "$LOG"; exit 1; }
[ "$(image_id "$APP")" = "$BACKUP_IMAGE_ID" ] || { echo "CRITICAL: rollback image id mismatch" | tee -a "$LOG"; exit 1; }

dc exec "$APP" python - "$EXPECTED_VERSION" <<'PY' | tee -a "$LOG"
import json,os,sys,urllib.request
expected=sys.argv[1]
t=(os.getenv('NOVA_UI_ACCESS_TOKEN') or os.getenv('APP_ACCESS_TOKEN') or '').strip(); h={'X-App-Token':t,'Authorization':'Bearer '+t} if t else {}
with urllib.request.urlopen(urllib.request.Request('http://127.0.0.1:8000/api/livez',headers=h),timeout=8) as r:j=json.load(r)
assert j.get('ok') and j.get('version')==expected,j
print(json.dumps({'ok':True,'restored_version':expected,'target':'PRE_UIFIX6_EXACT_IMAGE'},ensure_ascii=False))
PY

echo "RESULT=SUCCESS RESTORED=$APP VERSION=$RESTORED_VERSION FAILED_UIFIX6=$FAILED LOG=$LOG" | tee -a "$LOG"
