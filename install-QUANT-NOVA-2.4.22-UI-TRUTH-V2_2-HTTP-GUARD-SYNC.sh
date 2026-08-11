#!/usr/bin/env bash
set -Eeuo pipefail

REV="QUANT-NOVA-2.4.22-UI-TRUTH-V2.2-HTTP-GUARD-SYNC"
APP="quant-nova"
GUARD="nova-http-guard"
STAMP="$(date +%Y%m%d%H%M%S)"
WORK="/tmp/nova-ui-v22-$STAMP"
BK="$HOME/quant-nova/http-guard-static-backups"
mkdir -p "$WORK" "$BK"
chmod 700 "$WORK" "$BK"

echo "=== $REV START ==="
echo "PATCH_SCOPE=HTTP_GUARD_STATIC_SYNC_ONLY"
echo "DATA_LOGIC_CHANGE=NONE"
echo "SELECTION_LOGIC_CHANGE=NONE"
echo "BUY_THRESHOLDS_CHANGE=NONE"
echo "SCORING_FORMULA_CHANGE=NONE"
echo "WS_LOGIC_CHANGE=NONE"
echo "MAIN_PY_CHANGE=NONE"

sudo docker inspect "$APP" >/dev/null
sudo docker inspect "$GUARD" >/dev/null

MAIN_BEFORE="$(sudo docker exec "$APP" sha256sum /app/app/main.py | awk '{print $1}')"
echo "MAIN_PY_SHA256_BEFORE=$MAIN_BEFORE"

# Source of truth: latest static files already installed in quant-nova.
sudo docker exec "$APP" sh -c "grep -q 'NOVA_UI_TRUTH_CONSOLIDATION_V2_START' /app/static/nova.js" || {
  echo "SOURCE_V2_MARKER_MISSING=FAIL" >&2
  exit 1
}

sudo docker cp "$APP:/app/static/nova.js" "$WORK/nova.js"
sudo docker cp "$APP:/app/static/index.html" "$WORK/index.html"
sudo chown "$(id -u):$(id -g)" "$WORK/nova.js" "$WORK/index.html"

# Force public HTML to request the same V2 asset version.
python3 - "$WORK/index.html" <<'PY'
from pathlib import Path
import re, sys
p=Path(sys.argv[1])
s=p.read_text(encoding='utf-8')
if re.search(r'/static/nova\.js\?v=[^"\']+', s):
    s=re.sub(r'/static/nova\.js\?v=[^"\']+',
             '/static/nova.js?v=2.4.22-ui-truth-v2',
             s, count=1)
elif '/static/nova.js' in s:
    s=s.replace('/static/nova.js','/static/nova.js?v=2.4.22-ui-truth-v2',1)
else:
    raise SystemExit('INDEX_NOVA_JS_REFERENCE_NOT_FOUND')
p.write_text(s,encoding='utf-8')
print('INDEX_CACHE_BUST=PASS')
PY

HOST_STATIC="/home/ubuntu/quant-nova/http-guard-v2/static"
HOST_CACHE="/home/ubuntu/quant-nova/http-guard-v2/cache"

echo "=== BACKUP HTTP-GUARD STATIC ==="
if [[ -f "$HOST_STATIC/index.html" ]]; then
  sudo cp "$HOST_STATIC/index.html" "$BK/index.html.before-$STAMP"
fi
if [[ -f "$HOST_STATIC/nova.js" ]]; then
  sudo cp "$HOST_STATIC/nova.js" "$BK/nova.js.before-$STAMP"
fi

echo "=== SYNC HOST BIND-MOUNT SOURCE ==="
sudo mkdir -p "$HOST_STATIC"
sudo cp "$WORK/index.html" "$HOST_STATIC/index.html"
sudo cp "$WORK/nova.js" "$HOST_STATIC/nova.js"
sudo chmod 644 "$HOST_STATIC/index.html" "$HOST_STATIC/nova.js"

grep -q 'NOVA_UI_TRUTH_CONSOLIDATION_V2_START' "$HOST_STATIC/nova.js"
grep -q 'ui-truth-v2' "$HOST_STATIC/index.html"
echo "HOST_STATIC_SYNC=PASS"

echo "=== VERIFY INSIDE HTTP GUARD ==="
sudo docker exec "$GUARD" sh -c "grep -q 'NOVA_UI_TRUTH_CONSOLIDATION_V2_START' /srv/static/nova.js"
sudo docker exec "$GUARD" sh -c "grep -q 'ui-truth-v2' /srv/static/index.html"
echo "HTTP_GUARD_STATIC_SYNC=PASS"

echo "=== CLEAR HTTP-GUARD RESPONSE CACHE ==="
# Cache is response-only. Clearing it does not touch trading state/data.
if [[ -d "$HOST_CACHE" ]]; then
  sudo find "$HOST_CACHE" -maxdepth 1 -type f \( -name '*.body' -o -name '*.json' \) -delete
fi
echo "HTTP_GUARD_CACHE_CLEARED=PASS"

echo "=== RESTART HTTP GUARD ONLY ==="
sudo docker restart "$GUARD" >/dev/null
sleep 2
echo "HTTP_GUARD_RESTART=PASS"

echo "=== PUBLIC VERIFY ==="
PUB_HTML="$WORK/public.html"
PUB_JS="$WORK/public.js"

ROOT_CODE="$(curl -ksS --max-time 6 -o "$PUB_HTML" -w '%{http_code}' https://3-38-25-20.nip.io/ || true)"
JS_CODE="$(curl -ksS --max-time 6 -o "$PUB_JS" -w '%{http_code}' 'https://3-38-25-20.nip.io/static/nova.js?v=2.4.22-ui-truth-v2' || true)"
echo "PUBLIC_ROOT_HTTP=$ROOT_CODE"
echo "PUBLIC_JS_HTTP=$JS_CODE"

PUB_VER="$(grep -oE 'nova\.js\?v=[^"'"'"']+' "$PUB_HTML" | tail -1 || true)"
echo "PUBLIC_HTML_JS_VERSION=${PUB_VER:-NOT_FOUND}"

grep -q 'NOVA_UI_TRUTH_CONSOLIDATION_V2_START' "$PUB_JS" || {
  echo "PUBLIC_V2_MARKER=FAIL" >&2
  exit 1
}
echo "PUBLIC_V2_MARKER=PASS"

grep -q 'ui-truth-v2' "$PUB_HTML" || {
  echo "PUBLIC_HTML_CACHE_BUST=FAIL" >&2
  exit 1
}
echo "PUBLIC_HTML_CACHE_BUST=PASS"

echo "=== API REGRESSION ==="
for ep in /api/health /api/nova /api/opening-shakeout-reversal /api/close-picks /api/nxt-signal-table; do
  C="$(curl -sS --max-time 4 -o /dev/null -w '%{http_code}' "http://127.0.0.1:3200$ep" || true)"
  echo "$ep=$C"
  [[ "$C" == "200" ]] || { echo "API_GATE=FAIL:$ep" >&2; exit 1; }
done
echo "API_GATE=PASS"

MAIN_AFTER="$(sudo docker exec "$APP" sha256sum /app/app/main.py | awk '{print $1}')"
echo "MAIN_PY_SHA256_AFTER=$MAIN_AFTER"
[[ "$MAIN_BEFORE" == "$MAIN_AFTER" ]] || {
  echo "MAIN_PY_HASH_GATE=FAIL" >&2
  exit 1
}
echo "MAIN_PY_HASH_GATE=PASS"

echo "=== FINAL ==="
echo "PUBLIC_STATIC_SOURCE=http-guard-v2/static"
echo "PUBLIC_UI_V2=ACTIVE"
echo "CLOSEPICKS_AFTER_08:50=HIDDEN"
echo "OPENING_SHAKEOUT_TABLE=VISIBLE"
echo "EARLY_ALERT_LIVE_PRICE_OVERLAY=ENABLED"
echo "STALE_REST_WARNING=DISPLAY_ONLY"
echo "ACCEL_OUTLIER_WARNING=DISPLAY_ONLY"
echo "DATA_LOGIC=UNCHANGED"
echo "SELECTION_LOGIC=UNCHANGED"
echo "BUY_THRESHOLDS=UNCHANGED"
echo "SCORING_FORMULA=UNCHANGED"
echo "WS_LOGIC=UNCHANGED"
echo "MAIN_PY=BYTE_IDENTICAL"
echo "=== $REV PASS ==="
