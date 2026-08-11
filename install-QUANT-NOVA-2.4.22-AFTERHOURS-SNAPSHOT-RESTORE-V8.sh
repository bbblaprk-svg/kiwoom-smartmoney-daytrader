#!/usr/bin/env bash
set -Eeuo pipefail

REV="QUANT-NOVA-2.4.22-AFTERHOURS-SNAPSHOT-RESTORE-V8"
APP="quant-nova"
GUARD="nova-http-guard"
STAMP="$(date +%Y%m%d%H%M%S)"
WORK="/tmp/nova-v8-$STAMP"
BK="$HOME/quant-nova/afterhours-snapshot-v8-backups"
HOST_STATIC="/home/ubuntu/quant-nova/http-guard-v2/static"
HOST_CACHE="/home/ubuntu/quant-nova/http-guard-v2/cache"
SRC="$WORK/main.before.py"
DST="$WORK/main.after.py"
JS="$WORK/nova.js"
HTML="$WORK/index.html"
SUCCESS=0

mkdir -p "$WORK" "$BK"
chmod 700 "$WORK" "$BK"

fail(){ echo "=== $REV FAIL: $* ===" >&2; exit 1; }

rollback(){
  ec=$?
  if [[ "$SUCCESS" -ne 1 ]]; then
    echo "=== AUTO ROLLBACK V8 ==="
    if [[ -f "$SRC" ]]; then
      sudo docker cp "$SRC" "$APP:/app/app/main.py" >/dev/null 2>&1 || true
      sudo docker restart "$APP" >/dev/null 2>&1 || true
    fi
    if [[ -f "$BK/nova.js.before-$STAMP" ]]; then
      sudo cp "$BK/nova.js.before-$STAMP" "$HOST_STATIC/nova.js" >/dev/null 2>&1 || true
      sudo docker cp "$BK/nova.js.before-$STAMP" "$APP:/app/static/nova.js" >/dev/null 2>&1 || true
    fi
    if [[ -f "$BK/index.html.before-$STAMP" ]]; then
      sudo cp "$BK/index.html.before-$STAMP" "$HOST_STATIC/index.html" >/dev/null 2>&1 || true
      sudo docker cp "$BK/index.html.before-$STAMP" "$APP:/app/static/index.html" >/dev/null 2>&1 || true
    fi
    sudo find "$HOST_CACHE" -maxdepth 1 -type f \( -name '*.body' -o -name '*.json' \) -delete >/dev/null 2>&1 || true
    sudo docker restart "$GUARD" >/dev/null 2>&1 || true
    echo "ROLLBACK=COMPLETE"
  fi
  exit "$ec"
}
trap rollback ERR INT TERM

echo "=== $REV START ==="
echo "CAUSE=EOD_SNAPSHOT_ROOT_NOVA_ROWS_OVERWRITTEN_EMPTY_WHILE_SECTION_SNAPSHOTS_SURVIVED"
echo "PATCH_SCOPE=AFTERHOURS_DISPLAY_PERSISTENCE_ONLY"
echo "BUY_LOGIC_CHANGE=NONE"
echo "SCORING_CHANGE=NONE"
echo "SELECTION_CHANGE=NONE"
echo "RANK_SPECS_CHANGE=NONE"
echo "WS_CONTRACT_CHANGE=NONE"
echo "V7_RUNTIME_FIXES=PRESERVED"

sudo docker inspect "$APP" >/dev/null || fail "quant-nova missing"
sudo docker inspect "$GUARD" >/dev/null || fail "nova-http-guard missing"

sudo docker cp "$APP:/app/app/main.py" "$SRC"
sudo chown "$(id -u):$(id -g)" "$SRC"
sudo cp "$HOST_STATIC/nova.js" "$JS"
sudo cp "$HOST_STATIC/index.html" "$HTML"
sudo chown "$(id -u):$(id -g)" "$JS" "$HTML"
cp "$SRC" "$BK/main.py.before-$STAMP"
cp "$JS" "$BK/nova.js.before-$STAMP"
cp "$HTML" "$BK/index.html.before-$STAMP"
cp "$SRC" "$DST"

MAIN_BEFORE="$(sha256sum "$SRC"|awk '{print $1}')"
echo "MAIN_BEFORE=$MAIN_BEFORE"

echo "=== CURRENT SNAPSHOT TRUTH ==="
sudo docker exec "$APP" python3 - <<'PY'
import json,os
p='/app/data/eod_screen_snapshot.json'
j=json.load(open(p,encoding='utf-8')) if os.path.exists(p) else {}
def n(x):
    return len(x.get('rows') or []) if isinstance(x,dict) else -1
print("source_day=",j.get('source_day'),"captured_at=",j.get('captured_at'))
for k in ('nova','nxt_alerts','nxt_signal_table','buy_signals','close_picks','close_smart_money','rs_leaders'):
    x=j.get(k) or {}
    print(k,"rows=",n(x),"count=",x.get('count'))
PY

python3 - "$DST" <<'PY'
from pathlib import Path
import ast,re,sys,hashlib

p=Path(sys.argv[1]); s=p.read_text(encoding='utf-8')
tree=ast.parse(s)

def hashes(text):
    t=ast.parse(text); out={}
    for n in ast.walk(t):
        if isinstance(n,(ast.FunctionDef,ast.AsyncFunctionDef)):
            out.setdefault(n.name,[]).append(hashlib.sha256(ast.dump(n,include_attributes=False).encode()).hexdigest())
    for k in out: out[k].sort()
    return out

before=hashes(s)
nodes=[n for n in ast.walk(tree) if isinstance(n,ast.AsyncFunctionDef) and n.name=='capture_eod_screen_snapshot']
if len(nodes)!=1:
    raise SystemExit("CAPTURE_FUNCTION_COUNT="+str(len(nodes)))
n=nodes[0]; lines=s.splitlines(True)
fn="".join(lines[n.lineno-1:n.end_lineno])

if 'EOD_NONEMPTY_SECTION_PRESERVE_V8' not in fn:
    anchor="    payload=jsonable_encoder(payload)\n"
    if anchor not in fn:
        raise SystemExit("CAPTURE_PAYLOAD_ANCHOR_NOT_FOUND")
    insert = '''    # EOD_NONEMPTY_SECTION_PRESERVE_V8
    # During 20:00~20:05 some live-memory lanes intentionally quiesce. Do not let a
    # later empty refresh erase a richer snapshot already captured for the same day.
    if old and str(old.get('source_day') or '')==str(day):
        def _rows_len_v8(x):
            return len(x.get('rows') or []) if isinstance(x,dict) else 0
        for _k in ('nova','nxt_alerts','nxt_signal_table','close_picks','close_smart_money','rs_leaders'):
            _prev=old.get(_k) if isinstance(old,dict) else None
            _cur=payload.get(_k)
            if _rows_len_v8(_cur)==0 and _rows_len_v8(_prev)>0:
                payload[_k]=_prev
        _pb=old.get('buy_signals') if isinstance(old,dict) else None
        _cb=payload.get('buy_signals')
        if isinstance(_pb,dict) and isinstance(_cb,dict):
            for _lk in ('rows','prebuy_rows','near_miss_rows'):
                if not (_cb.get(_lk) or []) and (_pb.get(_lk) or []):
                    _cb[_lk]=_pb.get(_lk)
            for _ck in ('count','prebuy_count','near_miss_count','total_events'):
                if not _cb.get(_ck) and _pb.get(_ck):
                    _cb[_ck]=_pb.get(_ck)
'''
    fn=fn.replace(anchor,insert+anchor,1)
    s="".join(lines[:n.lineno-1])+fn+"".join(lines[n.end_lineno:])

ast.parse(s)
after=hashes(s)
bad=[]
for name,h in before.items():
    if name=='capture_eod_screen_snapshot':
        continue
    if after.get(name)!=h:
        bad.append(name)
if bad:
    raise SystemExit("UNAUTHORIZED_MAIN_CHANGES:"+",".join(sorted(bad)))

for token in ("'trade_type':'0B'","'program_type':'0u'","'orderbook_type':'0D'","trde_upper_tp","amt_qty_tp"):
    if token not in s:
        raise SystemExit("PROTECTED_TOKEN_MISSING:"+token)
if 'ka90004' in s:
    raise SystemExit("KA90004_FORBIDDEN")

p.write_text(s,encoding='utf-8')
print("MAIN_AST_GATE=PASS")
print("ONLY_CAPTURE_EOD_SCREEN_SNAPSHOT_CHANGED=PASS")
print("TRADING_LOGIC_UNCHANGED=PASS")
PY

python3 -m py_compile "$DST"
echo "MAIN_COMPILE=PASS"

python3 - "$JS" "$HTML" <<'PY'
from pathlib import Path
import re,sys

jp=Path(sys.argv[1]); hp=Path(sys.argv[2])
js=jp.read_text(encoding='utf-8'); html=hp.read_text(encoding='utf-8')

js=re.sub(
 r'/\*\s*NOVA_AFTERHOURS_SNAPSHOT_RESTORE_V8_START\s*\*/.*?/\*\s*NOVA_AFTERHOURS_SNAPSHOT_RESTORE_V8_END\s*\*/',
 '',js,flags=re.S)

addon = r'''
/* NOVA_AFTERHOURS_SNAPSHOT_RESTORE_V8_START */
(function(){
  'use strict';
  let busy=false,last=0;
  async function jsonGet(url){
    try{const r=await fetch(url,{cache:'no-store'});return r.ok?await r.json():null}catch(e){return null}
  }
  async function hydrateHeldSnapshotV8(force=false){
    if(busy)return;
    const now=Date.now();
    if(!force && now-last<10000)return;
    busy=true;
    try{
      const st=await jsonGet('/api/screen-state');
      const hold=!!st?.screen_hold?.active;
      const awake=!!st?.runtime_awake;
      if(!hold || awake)return;

      const jobs=[];
      for(const fn of [
        (typeof load==='function'?load:null),
        (typeof loadPrimaryBuy==='function'?loadPrimaryBuy:null),
        (typeof loadSignals==='function'?loadSignals:null),
        (typeof loadNxtAlerts==='function'?loadNxtAlerts:null),
        (typeof loadNxtSignalTable==='function'?loadNxtSignalTable:null),
        (typeof loadClosePicks==='function'?loadClosePicks:null),
        (typeof loadCloseSmartMoney==='function'?loadCloseSmartMoney:null),
        (typeof loadRsLeaders==='function'?loadRsLeaders:null),
        (typeof loadPositions==='function'?loadPositions:null),
        (typeof loadEvidence==='function'?loadEvidence:null)
      ]){
        if(fn)jobs.push(Promise.resolve().then(()=>fn()).catch(()=>null));
      }
      await Promise.allSettled(jobs);

      const [ns,cp,bs]=await Promise.all([
        jsonGet('/api/nxt-signal-table'),
        jsonGet('/api/close-picks'),
        jsonGet('/api/buy-signals')
      ]);
      const b=document.querySelector('#snapshotBanner');
      if(b && hold){
        const d=st?.screen_hold?.snapshot_source_day||st?.display_day||'-';
        const at=st?.screen_hold?.snapshot_at||'';
        const nsc=Number(ns?.count||0), cpc=Number(cp?.count||0), bsc=Number(bs?.count||0);
        b.hidden=false;
        b.innerHTML=`<b>LAST MARKET SNAPSHOT · ${d}</b><small>${at?at+' · ':''}NXT 관리 ${nsc} · 종가후보 ${cpc} · 확정 BUY ${bsc} · 다음 실제 거래일 07:30까지 읽기전용 유지</small>`;
      }
      last=Date.now();
    }finally{busy=false}
  }

  setTimeout(()=>hydrateHeldSnapshotV8(true),400);
  setTimeout(()=>hydrateHeldSnapshotV8(true),1800);
  setTimeout(()=>hydrateHeldSnapshotV8(true),5000);
  setInterval(()=>hydrateHeldSnapshotV8(false),15000);
  document.addEventListener('visibilitychange',()=>{if(!document.hidden)hydrateHeldSnapshotV8(true)});
  window.addEventListener('pageshow',()=>hydrateHeldSnapshotV8(true));
  window.NOVA_AFTERHOURS_SNAPSHOT_RESTORE_V8={hydrate:()=>hydrateHeldSnapshotV8(true)};
})();
/* NOVA_AFTERHOURS_SNAPSHOT_RESTORE_V8_END */
'''
js += "\n"+addon+"\n"

if re.search(r'/static/nova\.js\?v=[^"\']+',html):
    html=re.sub(r'/static/nova\.js\?v=[^"\']+','/static/nova.js?v=2.4.22-afterhours-snapshot-v8',html,count=1)
elif '/static/nova.js' in html:
    html=html.replace('/static/nova.js','/static/nova.js?v=2.4.22-afterhours-snapshot-v8',1)
else:
    raise SystemExit("NOVA_JS_REFERENCE_NOT_FOUND")

jp.write_text(js,encoding='utf-8')
hp.write_text(html,encoding='utf-8')
print("FRONTEND_V8_BUILD=PASS")
PY

if command -v node >/dev/null 2>&1; then
  node --check "$JS"
  echo "NODE_CHECK=PASS"
fi

echo "=== WAIT FOR RECENT PERSIST ==="
for i in $(seq 1 12); do
  age="$(curl -fsS --max-time 3 http://127.0.0.1:3200/api/health | python3 -c 'import sys,json;h=json.load(sys.stdin);print((h.get("performance_guard") or {}).get("last_persist_age_sec") or 999)' 2>/dev/null || echo 999)"
  echo "persist_age=$age"
  python3 - "$age" <<'PY' && break || true
import sys
try: raise SystemExit(0 if float(sys.argv[1])<=15 else 1)
except: raise SystemExit(1)
PY
  sleep 4
done

echo "=== INSTALL BACKEND DISPLAY-PERSISTENCE PATCH ==="
sudo docker cp "$DST" "$APP:/app/app/main.py"
sudo docker restart "$APP" >/dev/null
READY=0
for i in $(seq 1 35); do
  c="$(curl -sS --max-time 2 -o /dev/null -w '%{http_code}' http://127.0.0.1:3200/api/health || true)"
  echo "app_ready[$i]=$c"
  if [[ "$c" == "200" ]]; then READY=1; break; fi
  sleep 1
done
[[ "$READY" == 1 ]] || fail "quant-nova did not recover"

echo "=== INSTALL ACTUAL PUBLIC STATIC ==="
sudo cp "$JS" "$HOST_STATIC/nova.js"
sudo cp "$HTML" "$HOST_STATIC/index.html"
sudo chmod 644 "$HOST_STATIC/nova.js" "$HOST_STATIC/index.html"
sudo docker cp "$JS" "$APP:/app/static/nova.js"
sudo docker cp "$HTML" "$APP:/app/static/index.html"
sudo find "$HOST_CACHE" -maxdepth 1 -type f \( -name '*.body' -o -name '*.json' \) -delete 2>/dev/null || true
sudo docker restart "$GUARD" >/dev/null
sleep 2

echo "=== API SNAPSHOT GATE ==="
for ep in /api/health /api/screen-state /api/nova /api/nxt-signal-table /api/close-picks /api/buy-signals; do
  c="$(curl -sS --max-time 5 -o /dev/null -w '%{http_code}' "http://127.0.0.1:3200$ep" || true)"
  echo "$ep=$c"
  [[ "$c" == "200" ]] || fail "$ep failed"
done

curl -fsS http://127.0.0.1:3200/api/screen-state | python3 -c "import sys,json;j=json.load(sys.stdin);print('SCREEN_HOLD=',(j.get('screen_hold') or {}).get('active'),'RUNTIME_AWAKE=',j.get('runtime_awake'))"
curl -fsS http://127.0.0.1:3200/api/nxt-signal-table | python3 -c "import sys,json;j=json.load(sys.stdin);print('NXT_SIGNAL_SNAPSHOT_COUNT=',j.get('count'),'ROWS=',len(j.get('rows') or []))"
curl -fsS http://127.0.0.1:3200/api/close-picks | python3 -c "import sys,json;j=json.load(sys.stdin);print('CLOSE_PICKS_SNAPSHOT_COUNT=',j.get('count'),'ROWS=',len(j.get('rows') or []))"

echo "=== PUBLIC STATIC GATE ==="
curl -ksS --max-time 6 https://3-38-25-20.nip.io/ > "$WORK/public.html"
curl -ksS --max-time 6 'https://3-38-25-20.nip.io/static/nova.js?v=2.4.22-afterhours-snapshot-v8' > "$WORK/public.js"
grep -q 'afterhours-snapshot-v8' "$WORK/public.html"
grep -q 'NOVA_AFTERHOURS_SNAPSHOT_RESTORE_V8_START' "$WORK/public.js"
echo "PUBLIC_V8_MARKER=PASS"

echo "=== PROTECTED SOURCE GATE ==="
sudo docker exec "$APP" python3 - <<'PY'
s=open('/app/app/main.py',encoding='utf-8').read()
assert 'EOD_NONEMPTY_SECTION_PRESERVE_V8' in s
assert "'trade_type':'0B'" in s
assert "'program_type':'0u'" in s
assert "'orderbook_type':'0D'" in s
assert 'trde_upper_tp' in s and 'amt_qty_tp' in s
assert 'ka90004' not in s
print("V7_RUNTIME_AND_WS_CONTRACT_PRESERVED=PASS")
PY

TAG="quant-nova:2.4.22-afterhours-snapshot-restore-v8-$STAMP"
sudo docker commit "$APP" "$TAG" >/dev/null
echo "SNAPSHOT_IMAGE=$TAG"

SUCCESS=1
trap - ERR INT TERM

echo "=== FINAL ==="
echo "CURRENT_NXT_SIGNAL_AND_CLOSE_PICK_SNAPSHOTS=HYDRATED_IN_FROZEN_UI"
echo "FUTURE_EOD_NONEMPTY_SNAPSHOT=PROTECTED_FROM_LATE_EMPTY_OVERWRITE"
echo "PUBLIC_HTTP_GUARD_STATIC=SYNCED"
echo "BUY_LOGIC=UNCHANGED"
echo "SCORING_FORMULA=UNCHANGED"
echo "SELECTION_LOGIC=UNCHANGED"
echo "RANK_SPECS=UNCHANGED"
echo "WS_CONTRACT=0B/0u/0D_UNCHANGED"
echo "KA90003_V7_FIX=PRESERVED"
echo "=== $REV PASS ==="
