#!/usr/bin/env bash
set -Eeuo pipefail

REV="QUANT-NOVA-2.4.22-AFTERHOURS-DIRECT-RENDER-V8.2-WIDTH-FIX"
GUARD="nova-http-guard"
APP="quant-nova"
HOST_STATIC="/home/ubuntu/quant-nova/http-guard-v2/static"
HOST_CACHE="/home/ubuntu/quant-nova/http-guard-v2/cache"
STAMP="$(date +%Y%m%d%H%M%S)"
WORK="/tmp/nova-v82-$STAMP"
BK="$HOME/quant-nova/afterhours-v82-backups"

mkdir -p "$WORK" "$BK"
chmod 700 "$WORK" "$BK"

echo "=== $REV START ==="
echo "PATCH_SCOPE=PUBLIC_FRONTEND_LAYOUT_ONLY"
echo "CAUSE=DIRECT_SNAPSHOT_PANEL_INSERTED_AS_GRID_CHILD_ONE_COLUMN"
echo "QUANT_NOVA_RESTART=NO"
echo "MAIN_PY_CHANGE=NONE"
echo "BUY_LOGIC_CHANGE=NONE"
echo "SCORING_CHANGE=NONE"
echo "SELECTION_CHANGE=NONE"
echo "WS_CHANGE=NONE"

sudo docker inspect "$GUARD" >/dev/null
sudo docker inspect "$APP" >/dev/null

MAIN_BEFORE="$(sudo docker exec "$APP" sha256sum /app/app/main.py | awk '{print $1}')"
echo "MAIN_PY_SHA256_BEFORE=$MAIN_BEFORE"

sudo cp "$HOST_STATIC/nova.js" "$WORK/nova.js"
sudo cp "$HOST_STATIC/index.html" "$WORK/index.html"
sudo chown "$(id -u):$(id -g)" "$WORK/nova.js" "$WORK/index.html"
cp "$WORK/nova.js" "$BK/nova.js.before-$STAMP"
cp "$WORK/index.html" "$BK/index.html.before-$STAMP"

python3 - "$WORK/nova.js" "$WORK/index.html" <<'PY'
from pathlib import Path
import re,sys

jp=Path(sys.argv[1]); hp=Path(sys.argv[2])
js=jp.read_text(encoding='utf-8')
html=hp.read_text(encoding='utf-8')

if 'NOVA_AFTERHOURS_DIRECT_RENDER_V81_START' not in js:
    raise SystemExit('V81_MARKER_NOT_FOUND')

old_css="#novaV81{margin:26px 20px 38px;padding:22px;"
new_css="#novaV81{grid-column:1 / -1 !important;width:calc(100% - 40px) !important;max-width:none !important;justify-self:stretch !important;box-sizing:border-box;margin:26px 20px 38px;padding:22px;"
if old_css in js:
    js=js.replace(old_css,new_css,1)
elif 'grid-column:1 / -1 !important' not in js:
    raise SystemExit('V81_CSS_ANCHOR_NOT_FOUND')

pat=r"function insertRoot\(\)\{.*?return root;\n  \}"
m=re.search(pat,js,flags=re.S)
if not m:
    raise SystemExit('INSERT_ROOT_FUNCTION_NOT_FOUND')

new = r"""function insertRoot(){
    let root=document.getElementById('novaV81');
    if(root) return root;
    root=document.createElement('section');
    root.id='novaV81';

    const main=document.querySelector('main')||document.body;

    const directChildren=[...main.children];
    let statusBlock=directChildren.find(el=>{
      const t=(el.textContent||'').replace(/\s+/g,' ').trim();
      return t.includes('시장 세션') && t.includes('키움 REST') && t.includes('WebSocket');
    });

    if(statusBlock){
      statusBlock.insertAdjacentElement('afterend',root);
    }else{
      const banner=document.querySelector('#snapshotBanner');
      if(banner && banner.parentElement===main){
        banner.insertAdjacentElement('afterend',root);
      }else{
        main.insertBefore(root,main.firstElementChild?main.firstElementChild.nextSibling:null);
      }
    }

    root.style.gridColumn='1 / -1';
    root.style.width='calc(100% - 40px)';
    root.style.maxWidth='none';
    root.style.justifySelf='stretch';
    root.style.boxSizing='border-box';
    return root;
  }"""

js=js[:m.start()]+new+js[m.end():]

if re.search(r'/static/nova\.js\?v=[^"\']+',html):
    html=re.sub(r'/static/nova\.js\?v=[^"\']+',
                '/static/nova.js?v=2.4.22-afterhours-direct-v82-width',
                html,count=1)
elif '/static/nova.js' in html:
    html=html.replace('/static/nova.js',
                      '/static/nova.js?v=2.4.22-afterhours-direct-v82-width',1)
else:
    raise SystemExit('NOVA_JS_REFERENCE_NOT_FOUND')

js += "\n/* NOVA_AFTERHOURS_DIRECT_RENDER_V82_WIDTH_FIX */\n"

jp.write_text(js,encoding='utf-8')
hp.write_text(html,encoding='utf-8')
print('V82_LAYOUT_BUILD=PASS')
PY

if command -v node >/dev/null 2>&1; then
  node --check "$WORK/nova.js"
  echo "NODE_CHECK=PASS"
fi

echo "=== INSTALL PUBLIC STATIC ONLY ==="
sudo cp "$WORK/nova.js" "$HOST_STATIC/nova.js"
sudo cp "$WORK/index.html" "$HOST_STATIC/index.html"
sudo chmod 644 "$HOST_STATIC/nova.js" "$HOST_STATIC/index.html"
sudo docker cp "$WORK/nova.js" "$APP:/app/static/nova.js"
sudo docker cp "$WORK/index.html" "$APP:/app/static/index.html"

sudo find "$HOST_CACHE" -maxdepth 1 -type f \( -name '*.body' -o -name '*.json' \) -delete 2>/dev/null || true
sudo docker restart "$GUARD" >/dev/null
sleep 2

echo "=== PUBLIC MARKER GATE ==="
curl -ksS --max-time 6 https://3-38-25-20.nip.io/ > "$WORK/public.html"
curl -ksS --max-time 6 'https://3-38-25-20.nip.io/static/nova.js?v=2.4.22-afterhours-direct-v82-width' > "$WORK/public.js"
grep -q 'afterhours-direct-v82-width' "$WORK/public.html"
grep -q 'NOVA_AFTERHOURS_DIRECT_RENDER_V82_WIDTH_FIX' "$WORK/public.js"
grep -q "gridColumn='1 / -1'" "$WORK/public.js"
echo "PUBLIC_V82_MARKER=PASS"
echo "FULL_WIDTH_GRID_SPAN=PASS"

MAIN_AFTER="$(sudo docker exec "$APP" sha256sum /app/app/main.py | awk '{print $1}')"
echo "MAIN_PY_SHA256_AFTER=$MAIN_AFTER"
[[ "$MAIN_BEFORE" == "$MAIN_AFTER" ]]
echo "MAIN_PY_HASH_GATE=PASS"

echo "=== FINAL ==="
echo "AFTERHOURS_PANEL_WIDTH=FULL"
echo "GRID_COLUMN=1_TO_END"
echo "QUANT_NOVA_RESTART=NO"
echo "MAIN_PY=BYTE_IDENTICAL"
echo "BUY_LOGIC=UNCHANGED"
echo "SCORING=UNCHANGED"
echo "SELECTION=UNCHANGED"
echo "WS=UNCHANGED"
echo "=== $REV PASS ==="
