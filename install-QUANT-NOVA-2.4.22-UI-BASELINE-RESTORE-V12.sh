#!/usr/bin/env bash
set -Eeuo pipefail

REV="QUANT-NOVA-2.4.22-UI-BASELINE-RESTORE-V12"
APP="quant-nova"
GUARD="nova-http-guard"
HOST_STATIC="/home/ubuntu/quant-nova/http-guard-v2/static"
HOST_CACHE="/home/ubuntu/quant-nova/http-guard-v2/cache"
STAMP="$(date +%Y%m%d%H%M%S)"
WORK="/tmp/nova-ui-v12-$STAMP"
BK="$HOME/quant-nova/ui-v12-backups"
SUCCESS=0

mkdir -p "$WORK" "$BK"
chmod 700 "$WORK" "$BK"

fail(){ echo "=== $REV FAIL: $* ===" >&2; exit 1; }

rollback(){
  ec=$?
  if [[ "$SUCCESS" -ne 1 ]]; then
    echo "=== V12 AUTO ROLLBACK ==="
    if [[ -d "$WORK/host-static-before" ]]; then
      sudo rm -rf "$HOST_STATIC"
      sudo mkdir -p "$HOST_STATIC"
      sudo cp -a "$WORK/host-static-before/." "$HOST_STATIC/"
    fi
    if [[ -d "$WORK/app-static-before" ]]; then
      sudo docker exec "$APP" sh -c 'rm -rf /app/static/*'
      sudo docker cp "$WORK/app-static-before/." "$APP:/app/static/" >/dev/null 2>&1 || true
    fi
    sudo find "$HOST_CACHE" -maxdepth 1 -type f \( -name '*.body' -o -name '*.json' \) -delete >/dev/null 2>&1 || true
    sudo docker restart "$GUARD" >/dev/null 2>&1 || true
    echo "ROLLBACK=COMPLETE"
  fi
  exit "$ec"
}
trap rollback ERR INT TERM

echo "=== $REV START ==="
echo "GOAL=RESTORE_PRE_AFTERHOURS_PATCH_NATIVE_UI"
echo "METHOD=EXTRACT_STATIC_ONLY_FROM_KNOWN_GOOD_PRE_V8_IMAGE"
echo "AFTERHOURS_OVERLAY=NONE"
echo "PWA_OVERLAY=NONE"
echo "MAIN_PY_CHANGE=NONE"
echo "BUY_LOGIC_CHANGE=NONE"
echo "SCORING_CHANGE=NONE"
echo "SELECTION_CHANGE=NONE"
echo "WS_CHANGE=NONE"

sudo docker inspect "$APP" >/dev/null || fail "quant-nova missing"
sudo docker inspect "$GUARD" >/dev/null || fail "nova-http-guard missing"

MAIN_BEFORE="$(sudo docker exec "$APP" sha256sum /app/app/main.py | awk '{print $1}')"
echo "MAIN_PY_SHA256_BEFORE=$MAIN_BEFORE"

echo "=== LOCATE KNOWN-GOOD SNAPSHOT ==="
IMAGE="$(sudo docker images --format '{{.Repository}}:{{.Tag}}' | grep '^quant-nova:2\.4\.22-pipeline-recovery-v7-' | sort | tail -1 || true)"
if [[ -z "$IMAGE" ]]; then
  IMAGE="$(sudo docker images --format '{{.Repository}}:{{.Tag}}' | grep '^quant-nova:2\.4\.22-morning-flow-state-init-hotfix-v2\.1-' | sort | tail -1 || true)"
fi
[[ -n "$IMAGE" ]] || fail "no pre-V8 known-good snapshot image found"
echo "SOURCE_IMAGE=$IMAGE"

echo "=== BACKUP CURRENT STATIC ==="
mkdir -p "$WORK/host-static-before" "$WORK/app-static-before"
sudo cp -a "$HOST_STATIC/." "$WORK/host-static-before/"
sudo chown -R "$(id -u):$(id -g)" "$WORK/host-static-before"
sudo docker cp "$APP:/app/static/." "$WORK/app-static-before/"
sudo chown -R "$(id -u):$(id -g)" "$WORK/app-static-before"
tar -C "$WORK" -czf "$BK/current-static-before-v12-$STAMP.tar.gz" host-static-before app-static-before
echo "CURRENT_STATIC_BACKUP=$BK/current-static-before-v12-$STAMP.tar.gz"

echo "=== EXTRACT BASELINE STATIC ==="
CID="$(sudo docker create "$IMAGE")"
trap 'sudo docker rm -f "$CID" >/dev/null 2>&1 || true; rollback' ERR INT TERM
mkdir -p "$WORK/baseline-static"
sudo docker cp "$CID:/app/static/." "$WORK/baseline-static/"
sudo docker rm "$CID" >/dev/null
trap rollback ERR INT TERM
sudo chown -R "$(id -u):$(id -g)" "$WORK/baseline-static"

[[ -s "$WORK/baseline-static/index.html" ]] || fail "baseline index.html missing"
[[ -s "$WORK/baseline-static/nova.js" ]] || fail "baseline nova.js missing"

echo "=== VERIFY BASELINE IS PRE-PATCH ==="
python3 - "$WORK/baseline-static/index.html" "$WORK/baseline-static/nova.js" <<'PY'
import sys
html=open(sys.argv[1],encoding='utf-8').read()
js=open(sys.argv[2],encoding='utf-8').read()
bad=[
 'NOVA_AFTERHOURS_SNAPSHOT_RESTORE_V8_START',
 'NOVA_AFTERHOURS_DIRECT_RENDER_V81_START',
 'NOVA_AFTERHOURS_STABLE_PORTAL_V83_START',
 'NOVA_CANONICAL_AFTERHOURS_V9_START',
 'NOVA_AFTERHOURS_SHELL_V10_START',
 'NOVA_PWA_STANDALONE_V11_START',
 'NOVA_V111_ROOT_GUARD',
]
found=[x for x in bad if x in html or x in js]
assert not found,found
print("PRE_PATCH_MARKER_GATE=PASS")
PY

echo "=== ADD CACHE-BUST ONLY ==="
python3 - "$WORK/baseline-static/index.html" "$WORK/baseline-static/nova.js" <<'PY'
from pathlib import Path
import re,sys
hp=Path(sys.argv[1]); jp=Path(sys.argv[2])
html=hp.read_text(encoding='utf-8')
js=jp.read_text(encoding='utf-8')

# Cache-bust only. No layout/render logic added.
if re.search(r'/static/nova\.js\?v=[^"\']+',html):
    html=re.sub(r'/static/nova\.js\?v=[^"\']+',
                '/static/nova.js?v=2.4.22-ui-baseline-v12',
                html,count=1)
elif '/static/nova.js' in html:
    html=html.replace('/static/nova.js','/static/nova.js?v=2.4.22-ui-baseline-v12',1)

html=html.replace('</head>','<!-- NOVA_UI_BASELINE_RESTORE_V12 -->\n</head>',1)
hp.write_text(html,encoding='utf-8')
jp.write_text(js,encoding='utf-8')
print("CACHE_BUST_ONLY=PASS")
PY

echo "=== RESET SERVICE WORKER CACHE SAFELY ==="
if [[ -s "$WORK/baseline-static/sw.js" ]]; then
cat >> "$WORK/baseline-static/sw.js" <<'EOF'

/* NOVA_UI_BASELINE_RESTORE_V12_SW_RESET */
self.addEventListener('install', function(event) {
  try { self.skipWaiting(); } catch (e) {}
});
self.addEventListener('activate', function(event) {
  event.waitUntil((async function() {
    try {
      const keys = await caches.keys();
      await Promise.all(keys.map(function(k){ return caches.delete(k); }));
    } catch (e) {}
    try { await self.clients.claim(); } catch (e) {}
  })());
});
EOF
fi

# Restore the old manifest start URL if a manifest exists.
for mf in manifest.webmanifest manifest.json; do
  if [[ -s "$WORK/baseline-static/$mf" ]]; then
    python3 - "$WORK/baseline-static/$mf" <<'PY'
import json,sys
p=sys.argv[1]
try:
    j=json.load(open(p,encoding='utf-8'))
    j['start_url']='/'
    j['scope']='/'
    with open(p,'w',encoding='utf-8') as f:
        json.dump(j,f,ensure_ascii=False,indent=2)
    print("MANIFEST_BASELINE_START_URL=PASS",p)
except Exception as e:
    print("MANIFEST_SKIP",p,e)
PY
  fi
done

if command -v node >/dev/null 2>&1; then
  node --check "$WORK/baseline-static/nova.js"
  [[ ! -s "$WORK/baseline-static/sw.js" ]] || node --check "$WORK/baseline-static/sw.js"
  echo "NODE_CHECKS=PASS"
fi

echo "=== INSTALL BASELINE STATIC ==="
sudo rm -rf "$HOST_STATIC"
sudo mkdir -p "$HOST_STATIC"
sudo cp -a "$WORK/baseline-static/." "$HOST_STATIC/"

sudo docker exec "$APP" sh -c 'rm -rf /app/static/*'
sudo docker cp "$WORK/baseline-static/." "$APP:/app/static/"

sudo find "$HOST_CACHE" -maxdepth 1 -type f \( -name '*.body' -o -name '*.json' \) -delete 2>/dev/null || true
sudo docker restart "$GUARD" >/dev/null
sleep 2

echo "=== PUBLIC GATE ==="
curl -ksS --max-time 6 https://3-38-25-20.nip.io/ > "$WORK/public.html"
curl -ksS --max-time 6 'https://3-38-25-20.nip.io/static/nova.js?v=2.4.22-ui-baseline-v12' > "$WORK/public.js"

grep -q 'NOVA_UI_BASELINE_RESTORE_V12' "$WORK/public.html"
! grep -q 'NOVA_AFTERHOURS_SHELL_V10_START' "$WORK/public.js"
! grep -q 'NOVA_PWA_STANDALONE_V11_START' "$WORK/public.html"
! grep -q 'NOVA_V111_ROOT_GUARD' "$WORK/public.html"
echo "PUBLIC_BASELINE_HTML=PASS"
echo "PUBLIC_OLD_OVERLAYS=ABSENT"

for ep in /api/health /api/screen-state /api/nova /api/nxt-signal-table /api/close-picks /api/buy-signals; do
  c="$(curl -sS --max-time 5 -o /dev/null -w '%{http_code}' "http://127.0.0.1:3200$ep" || true)"
  echo "$ep=$c"
  [[ "$c" == "200" ]] || fail "$ep failed"
done

MAIN_AFTER="$(sudo docker exec "$APP" sha256sum /app/app/main.py | awk '{print $1}')"
echo "MAIN_PY_SHA256_AFTER=$MAIN_AFTER"
[[ "$MAIN_BEFORE" == "$MAIN_AFTER" ]] || fail "main.py changed"
echo "MAIN_PY_HASH_GATE=PASS"

SUCCESS=1
trap - ERR INT TERM

echo "=== FINAL ==="
echo "UI_SOURCE=$IMAGE"
echo "UI_STATE=PRE_V8_NATIVE_BASELINE_RESTORED"
echo "V8_V9_V10_V11_V11_1_OVERLAYS=REMOVED"
echo "PWA_START_URL=/"
echo "CLIENT_CACHE_RESET=SW_ACTIVATE"
echo "QUANT_NOVA_RESTART=NO"
echo "MAIN_PY=BYTE_IDENTICAL"
echo "BUY_LOGIC=UNCHANGED"
echo "SCORING=UNCHANGED"
echo "SELECTION=UNCHANGED"
echo "WS=UNCHANGED"
echo "=== $REV PASS ==="
