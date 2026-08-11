#!/usr/bin/env bash
set -Eeuo pipefail

REV="QUANT-NOVA-2.4.22-AFTERHOURS-CANONICAL-V9"
APP="quant-nova"
GUARD="nova-http-guard"
HOST_STATIC="/home/ubuntu/quant-nova/http-guard-v2/static"
HOST_CACHE="/home/ubuntu/quant-nova/http-guard-v2/cache"
STAMP="$(date +%Y%m%d%H%M%S)"
WORK="/tmp/nova-v9-$STAMP"
BK="$HOME/quant-nova/afterhours-v9-backups"
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
    echo "=== V9 AUTO ROLLBACK ==="
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
echo "DESIGN=ONE_CANONICAL_EOD_SNAPSHOT_API_PLUS_PERMANENT_BODY_MOUNT"
echo "OLD_V8_OVERLAYS=REMOVE"
echo "PATCH_SCOPE=AFTERHOURS_PRESENTATION_AND_READONLY_SNAPSHOT_API"
echo "BUY_LOGIC_CHANGE=NONE"
echo "SCORING_CHANGE=NONE"
echo "SELECTION_CHANGE=NONE"
echo "RANK_SPECS_CHANGE=NONE"
echo "WS_CHANGE=NONE"
echo "V7_V8_BACKEND_FIXES=PRESERVED"

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
echo "MAIN_PY_SHA256_BEFORE=$MAIN_BEFORE"

echo "=== BUILD READONLY SNAPSHOT API ==="
python3 - "$DST" <<'PY'
from pathlib import Path
import ast, hashlib, re, sys

p=Path(sys.argv[1])
s=p.read_text(encoding='utf-8')
ast.parse(s)

def fhashes(text):
    out={}
    for n in ast.walk(ast.parse(text)):
        if isinstance(n,(ast.FunctionDef,ast.AsyncFunctionDef)):
            h=hashlib.sha256(ast.dump(n,include_attributes=False).encode()).hexdigest()
            out.setdefault(n.name,[]).append(h)
    for k in out: out[k].sort()
    return out

before=fhashes(s)

s=re.sub(
    r'\n# NOVA_CANONICAL_EOD_API_V9_START\n.*?# NOVA_CANONICAL_EOD_API_V9_END\n',
    '\n', s, flags=re.S
)

route = r'''
# NOVA_CANONICAL_EOD_API_V9_START
@app.get('/api/eod-screen-snapshot')
def api_eod_screen_snapshot_v9():
    # Read-only display transport. No scoring, selection, BUY or WS effect.
    import json as _json
    import os as _os
    _p='/app/data/eod_screen_snapshot.json'
    try:
        if not _os.path.exists(_p):
            return {'ok':False,'available':False,'error':'snapshot_missing'}
        with open(_p,'r',encoding='utf-8') as _f:
            _j=_json.load(_f)
        if not isinstance(_j,dict):
            return {'ok':False,'available':False,'error':'snapshot_invalid'}
        _j=dict(_j)
        _j['ok']=True
        _j['available']=True
        _j['readonly']=True
        _j['display_policy']='CANONICAL_EOD_SNAPSHOT_V9_READ_ONLY'
        return _j
    except Exception as _e:
        return {'ok':False,'available':False,'error':str(_e)[:180]}
# NOVA_CANONICAL_EOD_API_V9_END
'''
s=s.rstrip()+"\n"+route+"\n"
ast.parse(s)

after=fhashes(s)
bad=[]
for name,h in before.items():
    if after.get(name)!=h:
        bad.append(name)
if bad:
    raise SystemExit("EXISTING_FUNCTION_CHANGED:"+",".join(sorted(bad)))

for token in (
    "'trade_type':'0B'",
    "'program_type':'0u'",
    "'orderbook_type':'0D'",
    "trde_upper_tp",
    "amt_qty_tp",
    "EOD_NONEMPTY_SECTION_PRESERVE_V8",
):
    if token not in s:
        raise SystemExit("PROTECTED_TOKEN_MISSING:"+token)
if 'ka90004' in s:
    raise SystemExit("KA90004_FORBIDDEN")

p.write_text(s,encoding='utf-8')
print("EXISTING_FUNCTION_AST_GATE=PASS")
print("READONLY_EOD_ROUTE_ADDED=PASS")
print("V7_V8_RUNTIME_FIXES_PRESENT=PASS")
PY

python3 -m py_compile "$DST"
echo "MAIN_COMPILE=PASS"

echo "=== BUILD CANONICAL FRONTEND ==="
python3 - "$JS" "$HTML" <<'PY'
from pathlib import Path
import re,sys

jp=Path(sys.argv[1]); hp=Path(sys.argv[2])
js=jp.read_text(encoding='utf-8')
html=hp.read_text(encoding='utf-8')

patterns=[
 r'/\*\s*NOVA_AFTERHOURS_SNAPSHOT_RESTORE_V8_START\s*\*/.*?/\*\s*NOVA_AFTERHOURS_SNAPSHOT_RESTORE_V8_END\s*\*/',
 r'/\*\s*NOVA_AFTERHOURS_DIRECT_RENDER_V81_START\s*\*/.*?/\*\s*NOVA_AFTERHOURS_DIRECT_RENDER_V81_END\s*\*/',
 r'/\*\s*NOVA_AFTERHOURS_STABLE_PORTAL_V83_START\s*\*/.*?/\*\s*NOVA_AFTERHOURS_STABLE_PORTAL_V83_END\s*\*/',
 r'/\*\s*NOVA_CANONICAL_AFTERHOURS_V9_START\s*\*/.*?/\*\s*NOVA_CANONICAL_AFTERHOURS_V9_END\s*\*/',
]
for pat in patterns:
    js=re.sub(pat,'',js,flags=re.S)
js=js.replace('/* NOVA_AFTERHOURS_DIRECT_RENDER_V82_WIDTH_FIX */','')

html=re.sub(
    r'\s*<!-- NOVA_CANONICAL_AFTERHOURS_MOUNT_V9_START -->.*?<!-- NOVA_CANONICAL_AFTERHOURS_MOUNT_V9_END -->\s*',
    '\n', html, flags=re.S
)
mount = '''
<!-- NOVA_CANONICAL_AFTERHOURS_MOUNT_V9_START -->
<section id="novaCanonicalAfterhoursV9" hidden aria-live="polite"></section>
<!-- NOVA_CANONICAL_AFTERHOURS_MOUNT_V9_END -->
'''
if '</body>' not in html:
    raise SystemExit('BODY_END_NOT_FOUND')
html=html.replace('</body>',mount+'\n</body>',1)

addon = r'''
/* NOVA_CANONICAL_AFTERHOURS_V9_START */
(function(){
  'use strict';

  const ROOT_ID='novaCanonicalAfterhoursV9';
  const STYLE_ID='novaCanonicalAfterhoursV9Style';
  let holdLatched=false;
  let activeConfirm=0;
  let lastSignature='';
  let lastSnapshot=null;

  const esc=v=>String(v??'').replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
  const n=v=>{
    const x=Number(String(v??'').replace(/,/g,'').replace(/[^\d.+-]/g,''));
    return Number.isFinite(x)?x:NaN;
  };
  const won=v=>Number.isFinite(n(v))?Math.round(n(v)).toLocaleString('ko-KR'):'-';
  const pct=v=>Number.isFinite(n(v))?`${n(v)>=0?'+':''}${n(v).toFixed(2)}%`:'-';
  const first=(o,ks,d='-')=>{
    for(const k of ks){
      const v=o?.[k];
      if(v!==undefined&&v!==null&&v!=='')return v;
    }
    return d;
  };
  const rows=(o,keys=['rows','items','signals','picks','alerts','events','data'])=>{
    if(Array.isArray(o))return o;
    if(!o||typeof o!=='object')return[];
    for(const k of keys)if(Array.isArray(o[k]))return o[k];
    return[];
  };
  const countRows=o=>rows(o).length;

  async function getj(url){
    try{
      const r=await fetch(url,{cache:'no-store'});
      if(!r.ok)return null;
      return await r.json();
    }catch(e){return null}
  }

  function ensureRoot(){
    let root=document.getElementById(ROOT_ID);
    if(root)return root;
    root=document.createElement('section');
    root.id=ROOT_ID;
    root.hidden=true;
    document.body.appendChild(root);
    return root;
  }

  function ensureStyle(){
    if(document.getElementById(STYLE_ID))return;
    const s=document.createElement('style');
    s.id=STYLE_ID;
    s.textContent=`
      html.nova-v9-hold,html.nova-v9-hold body{background:#082b39!important;min-height:100%!important}
      #${ROOT_ID}[hidden]{display:none!important}
      #${ROOT_ID}{display:block!important;position:relative!important;z-index:20!important;width:100%!important;max-width:none!important;box-sizing:border-box!important;background:#082b39!important;color:#dcecf2!important;padding:24px 18px 70px!important;margin:0!important;overflow:visible!important}
      #${ROOT_ID} .v9-wrap{width:100%!important;max-width:1180px!important;margin:0 auto!important}
      #${ROOT_ID} .v9-head{border:1px solid rgba(210,173,65,.58);border-radius:22px;padding:17px 18px;background:rgba(30,57,61,.72);margin-bottom:20px}
      #${ROOT_ID} .v9-head h2{margin:0;color:#f2fbff;font-size:21px;line-height:1.25}
      #${ROOT_ID} .v9-head p{margin:7px 0 0;color:#7f99a4;font-size:12px;line-height:1.55}
      #${ROOT_ID} .v9-summary{display:grid;grid-template-columns:repeat(2,minmax(0,1fr));gap:10px;margin-bottom:20px}
      #${ROOT_ID} .v9-kpi{background:#071e29;border:1px solid rgba(105,175,205,.17);border-radius:16px;padding:13px}
      #${ROOT_ID} .v9-kpi b{display:block;color:#fff;font-size:20px}
      #${ROOT_ID} .v9-kpi span{display:block;color:#708d99;font-size:10px;margin-top:4px}
      #${ROOT_ID} .v9-section{background:#071e29;border:1px solid rgba(105,175,205,.18);border-radius:20px;padding:15px;margin:14px 0}
      #${ROOT_ID} .v9-title{display:flex;justify-content:space-between;gap:10px;align-items:center;margin-bottom:12px}
      #${ROOT_ID} .v9-title h3{margin:0;color:#effaff;font-size:15px}
      #${ROOT_ID} .v9-title em{font-style:normal;color:#7c99a5;font-size:11px}
      #${ROOT_ID} .v9-list{display:grid;grid-template-columns:1fr;gap:10px}
      #${ROOT_ID} .v9-card{border:1px solid rgba(108,174,205,.14);border-radius:15px;padding:12px;background:rgba(0,0,0,.09);min-width:0}
      #${ROOT_ID} .v9-card-top{display:flex;justify-content:space-between;gap:10px;align-items:flex-start}
      #${ROOT_ID} .v9-name{color:#fff;font-size:15px;font-weight:800;min-width:0}
      #${ROOT_ID} .v9-code{color:#78939f;font-size:10px;margin-left:5px;font-weight:500}
      #${ROOT_ID} .v9-stage{color:#a9c3cc;font-size:10px;font-weight:800;text-align:right}
      #${ROOT_ID} .v9-rate{font-size:18px;font-weight:900;color:#ff7e8b;white-space:nowrap}
      #${ROOT_ID} .v9-rate.down{color:#78aaf2}
      #${ROOT_ID} .v9-meta{margin-top:7px;color:#91a9b2;font-size:11px;line-height:1.55;word-break:keep-all;overflow-wrap:anywhere}
      #${ROOT_ID} .v9-price{margin-top:8px;padding-top:8px;border-top:1px solid rgba(112,170,195,.12);color:#a6bdc6;font-size:10px;line-height:1.5}
      #${ROOT_ID} .v9-price b{color:#effaff;font-size:12px}
      #${ROOT_ID} .v9-empty{padding:18px 6px;color:#6d8995;font-size:12px;text-align:center}
      #${ROOT_ID} .v9-warn{border-color:rgba(210,173,65,.42)}
      #${ROOT_ID} .v9-note{color:#688692;font-size:10px;line-height:1.5;margin-top:10px}
      @media(min-width:760px){#${ROOT_ID} .v9-summary{grid-template-columns:repeat(4,minmax(0,1fr))}#${ROOT_ID} .v9-list{grid-template-columns:repeat(2,minmax(0,1fr))}}
    `;
    document.head.appendChild(s);
  }

  function reasonText(r){
    const z=first(r,['reason','reasons','why','body','title'],'');
    return Array.isArray(z)?z.join(' · '):String(z||'');
  }

  function signalCard(r){
    const rate=first(r,['change_rate','rate','change_pct'],'-');
    const rv=n(rate);
    const cls=Number.isFinite(rv)&&rv<0?' down':'';
    const cur=first(r,['current_price','live_price','last_price','price'],'-');
    const cap=first(r,['capture_price','first_price','entry_price','signal_price'],'-');
    const perf=first(r,['capture_return_pct','return_pct','performance_pct'],'-');
    return `<div class="v9-card">
      <div class="v9-card-top"><div class="v9-name">${esc(first(r,['name','stock_name','item_name']))}<span class="v9-code">${esc(first(r,['code','stock_code','symbol']))}</span></div><div><div class="v9-stage">${esc(first(r,['stage','signal_stage','event']))}</div><div class="v9-rate${cls}">${pct(rate)}</div></div></div>
      <div class="v9-meta">${esc(reasonText(r))}</div>
      <div class="v9-price">현재/최종가 <b>${won(cur)}</b> · 포착가 <b>${won(cap)}</b> · 포착후 <b>${pct(perf)}</b> · 점수 ${esc(first(r,['score','signal_score','total_score']))}</div>
    </div>`;
  }

  function closeCard(r){
    const rate=first(r,['change_rate','rate','change_pct'],'-');
    const rv=n(rate);
    const cls=Number.isFinite(rv)&&rv<0?' down':'';
    return `<div class="v9-card v9-warn">
      <div class="v9-card-top"><div class="v9-name">${esc(first(r,['name','stock_name','item_name']))}<span class="v9-code">${esc(first(r,['code','stock_code','symbol']))}</span></div><div><div class="v9-stage">${esc(first(r,['energy_state','state','status']))}</div><div class="v9-rate${cls}">${pct(rate)}</div></div></div>
      <div class="v9-meta">${esc(reasonText(r))}</div>
      <div class="v9-price">가격 <b>${won(first(r,['price','current_price','close_price']))}</b> · 점수 <b>${esc(first(r,['score','close_score','total_score']))}</b></div>
    </div>`;
  }

  function alertCard(r){
    const rate=first(r,['change_rate','rate','change_pct'],'-');
    const rv=n(rate);
    const cls=Number.isFinite(rv)&&rv<0?' down':'';
    return `<div class="v9-card">
      <div class="v9-card-top"><div class="v9-name">${esc(first(r,['name','stock_name','item_name']))}<span class="v9-code">${esc(first(r,['code','stock_code','symbol']))}</span></div><div><div class="v9-stage">${esc(first(r,['stage','event','status']))}</div><div class="v9-rate${cls}">${pct(rate)}</div></div></div>
      <div class="v9-meta">${esc(first(r,['at_kst','time','generated_at'],''))} ${esc(reasonText(r))}</div>
      <div class="v9-price">가격 <b>${won(first(r,['price','current_price']))}</b> · Radar ${esc(first(r,['nxt_radar_score','radar_score'],'-'))} · Takeover ${esc(first(r,['nxt_takeover_score','takeover_score'],'-'))}</div>
    </div>`;
  }

  function genericCard(r){
    const name=first(r,['name','stock_name','item_name','code','stage','status'],'기록');
    const code=first(r,['code','stock_code','symbol'],'');
    const meta=reasonText(r)||Object.entries(r||{}).filter(([k,v])=>['string','number','boolean'].includes(typeof v)).slice(0,8).map(([k,v])=>`${k} ${v}`).join(' · ');
    return `<div class="v9-card"><div class="v9-name">${esc(name)}${code?`<span class="v9-code">${esc(code)}</span>`:''}</div><div class="v9-meta">${esc(meta)}</div></div>`;
  }

  function section(title,arr,cardFn,note=''){
    const body=arr.length?arr.map(cardFn).join(''):`<div class="v9-empty">저장된 행이 없습니다.</div>`;
    return `<section class="v9-section"><div class="v9-title"><h3>${esc(title)}</h3><em>${arr.length}건</em></div><div class="v9-list">${body}</div>${note?`<div class="v9-note">${esc(note)}</div>`:''}</section>`;
  }

  function nestedRows(o,keys){
    const out=[];
    if(!o||typeof o!=='object')return out;
    for(const k of keys){
      const v=o[k];
      if(Array.isArray(v))out.push(...v);
    }
    return out;
  }

  function signature(s){
    return [
      s?.source_day,s?.captured_ts,
      countRows(s?.nova),countRows(s?.nxt_alerts),countRows(s?.nxt_signal_table),
      countRows(s?.close_picks),countRows(s?.close_smart_money),countRows(s?.rs_leaders),
      rows(s?.buy_signals).length,nestedRows(s?.buy_signals,['prebuy_rows','near_miss_rows']).length,
      countRows(s?.opening_shakeout)
    ].join('|');
  }

  function render(s){
    ensureStyle();
    const root=ensureRoot();

    const nova=rows(s?.nova);
    const alerts=rows(s?.nxt_alerts).slice(0,100);
    const sig=rows(s?.nxt_signal_table);
    const close=rows(s?.close_picks);
    const smart=rows(s?.close_smart_money);
    const rs=rows(s?.rs_leaders);
    const opening=rows(s?.opening_shakeout);
    const buys=rows(s?.buy_signals);
    const advisory=nestedRows(s?.buy_signals,['prebuy_rows','near_miss_rows']);

    document.documentElement.classList.add('nova-v9-hold');
    root.hidden=false;
    root.innerHTML=`
      <div class="v9-wrap">
        <div class="v9-head"><h2>LAST MARKET SNAPSHOT · ${esc(s?.source_day||'-')}</h2><p>${esc(s?.captured_at||'')} · 장후 읽기전용 보전 · 모든 표시값은 저장된 EOD snapshot 원본에서만 읽습니다.</p></div>
        <div class="v9-summary">
          <div class="v9-kpi"><b>${sig.length}</b><span>NXT SIGNAL MANAGEMENT</span></div>
          <div class="v9-kpi"><b>${alerts.length}</b><span>NXT 조기알림 보전</span></div>
          <div class="v9-kpi"><b>${close.length}</b><span>다음날 종가후보</span></div>
          <div class="v9-kpi"><b>${buys.length}</b><span>확정 BUY 기록</span></div>
        </div>
        ${section('메인 안정보드',nova,signalCard,'오늘 저장본의 nova.rows가 0이면 임의 복원하지 않습니다. V8부터 향후 빈 snapshot 덮어쓰기는 차단됩니다.')}
        ${section('개장 흔들기 · 급반전',opening,genericCard)}
        ${section('NXT 급등 조기발견 알림',alerts,alertCard,'최대 100건의 저장된 장중 이벤트를 표시합니다.')}
        ${section('NXT SIGNAL MANAGEMENT',sig,signalCard)}
        ${section('종가추천 · 다음날 후보',close,closeCard)}
        ${section('종가 스마트머니',smart,genericCard)}
        ${section('확정 BUY 기록',buys,signalCard)}
        ${section('BUY 조기추천/근접 기록',advisory,genericCard)}
        ${section('RS 리더',rs,genericCard)}
      </div>`;
  }

  async function tick(force=false){
    const [st,snap]=await Promise.all([
      getj('/api/screen-state'),
      getj('/api/eod-screen-snapshot')
    ]);

    if(st?.screen_hold?.active===true){
      holdLatched=true;
      activeConfirm=0;
    }else if(holdLatched && st?.runtime_awake===true){
      activeConfirm++;
    }else if(holdLatched){
      activeConfirm=0;
    }

    if(snap?.available===true && (holdLatched || st?.screen_hold?.active===true)){
      lastSnapshot=snap;
      const sig=signature(snap);
      if(force || sig!==lastSignature || ensureRoot().hidden){
        render(snap);
        lastSignature=sig;
      }
      return;
    }

    if(holdLatched && lastSnapshot && activeConfirm<3){
      if(ensureRoot().hidden)render(lastSnapshot);
      return;
    }

    if(activeConfirm>=3){
      const root=ensureRoot();
      root.hidden=true;
      root.innerHTML='';
      document.documentElement.classList.remove('nova-v9-hold');
      holdLatched=false;
      lastSnapshot=null;
      lastSignature='';
    }
  }

  const mo=new MutationObserver(()=>{
    if(!document.getElementById(ROOT_ID)){
      const r=document.createElement('section');
      r.id=ROOT_ID;
      r.hidden=true;
      document.body.appendChild(r);
      if(holdLatched&&lastSnapshot)render(lastSnapshot);
    }
  });
  mo.observe(document.documentElement,{childList:true,subtree:false});

  setTimeout(()=>tick(true),250);
  setTimeout(()=>tick(true),1200);
  setTimeout(()=>tick(true),3500);
  setInterval(()=>tick(false),20000);
  window.addEventListener('pageshow',()=>tick(true));
  document.addEventListener('visibilitychange',()=>{if(!document.hidden)tick(true)});
  window.NOVA_CANONICAL_AFTERHOURS_V9={refresh:()=>tick(true)};
})();
/* NOVA_CANONICAL_AFTERHOURS_V9_END */
'''

js += "\n"+addon+"\n"

if re.search(r'/static/nova\.js\?v=[^"\']+',html):
    html=re.sub(r'/static/nova\.js\?v=[^"\']+',
                '/static/nova.js?v=2.4.22-afterhours-canonical-v9',
                html,count=1)
elif '/static/nova.js' in html:
    html=html.replace('/static/nova.js',
                      '/static/nova.js?v=2.4.22-afterhours-canonical-v9',1)
else:
    raise SystemExit('NOVA_JS_REFERENCE_NOT_FOUND')

jp.write_text(js,encoding='utf-8')
hp.write_text(html,encoding='utf-8')

assert html.count('id="novaCanonicalAfterhoursV9"')==1
assert 'NOVA_AFTERHOURS_STABLE_PORTAL_V83_START' not in js
assert 'NOVA_AFTERHOURS_DIRECT_RENDER_V81_START' not in js
assert 'NOVA_AFTERHOURS_SNAPSHOT_RESTORE_V8_START' not in js
print("OLD_AFTERHOURS_OVERLAYS_REMOVED=PASS")
print("PERMANENT_BODY_MOUNT=PASS")
print("CANONICAL_V9_BUILD=PASS")
PY

if command -v node >/dev/null 2>&1; then
  node --check "$JS"
  echo "NODE_CHECK=PASS"
fi

echo "=== INSTALL BACKEND READONLY ROUTE ==="
sudo docker cp "$DST" "$APP:/app/app/main.py"
sudo docker restart "$APP" >/dev/null

READY=0
for i in $(seq 1 40); do
  c="$(curl -sS --max-time 2 -o /dev/null -w '%{http_code}' http://127.0.0.1:3200/api/health || true)"
  echo "APP_READY[$i]=$c"
  if [[ "$c" == "200" ]]; then READY=1; break; fi
  sleep 1
done
[[ "$READY" == 1 ]] || fail "quant-nova did not recover"

echo "=== CANONICAL SNAPSHOT API GATE ==="
for ep in /api/health /api/screen-state /api/eod-screen-snapshot /api/nxt-signal-table /api/close-picks /api/buy-signals; do
  c="$(curl -sS --max-time 5 -o /dev/null -w '%{http_code}' "http://127.0.0.1:3200$ep" || true)"
  echo "$ep=$c"
  [[ "$c" == "200" ]] || fail "$ep failed"
done

curl -fsS http://127.0.0.1:3200/api/eod-screen-snapshot > "$WORK/eod.json"
python3 - "$WORK/eod.json" <<'PY'
import json,sys
j=json.load(open(sys.argv[1],encoding='utf-8'))
assert j.get('available') is True,j
def rows(o):
    if isinstance(o,list):return o
    if not isinstance(o,dict):return []
    for k in ('rows','items','signals','picks','alerts','events','data'):
        if isinstance(o.get(k),list):return o[k]
    return []
print("EOD_SOURCE_DAY=",j.get('source_day'))
for k in ('nova','nxt_alerts','nxt_signal_table','close_picks','close_smart_money','opening_shakeout','rs_leaders'):
    print(k.upper()+"_ROWS=",len(rows(j.get(k))))
b=j.get('buy_signals') or {}
print("BUY_ROWS=",len(rows(b)),"PREBUY_ROWS=",len(b.get('prebuy_rows') or []),"NEAR_MISS_ROWS=",len(b.get('near_miss_rows') or []))
PY

echo "=== INSTALL CANONICAL PUBLIC STATIC ==="
sudo cp "$JS" "$HOST_STATIC/nova.js"
sudo cp "$HTML" "$HOST_STATIC/index.html"
sudo chmod 644 "$HOST_STATIC/nova.js" "$HOST_STATIC/index.html"
sudo docker cp "$JS" "$APP:/app/static/nova.js"
sudo docker cp "$HTML" "$APP:/app/static/index.html"
sudo find "$HOST_CACHE" -maxdepth 1 -type f \( -name '*.body' -o -name '*.json' \) -delete 2>/dev/null || true
sudo docker restart "$GUARD" >/dev/null
sleep 2

echo "=== PUBLIC STRUCTURAL GATE ==="
curl -ksS --max-time 6 https://3-38-25-20.nip.io/ > "$WORK/public.html"
curl -ksS --max-time 6 'https://3-38-25-20.nip.io/static/nova.js?v=2.4.22-afterhours-canonical-v9' > "$WORK/public.js"
curl -ksS --max-time 6 https://3-38-25-20.nip.io/api/eod-screen-snapshot > "$WORK/public-eod.json"

grep -q 'afterhours-canonical-v9' "$WORK/public.html"
grep -q 'id="novaCanonicalAfterhoursV9"' "$WORK/public.html"
grep -q 'NOVA_CANONICAL_AFTERHOURS_V9_START' "$WORK/public.js"
! grep -q 'NOVA_AFTERHOURS_STABLE_PORTAL_V83_START' "$WORK/public.js"
! grep -q 'NOVA_AFTERHOURS_DIRECT_RENDER_V81_START' "$WORK/public.js"

python3 - "$WORK/public-eod.json" <<'PY'
import json,sys
j=json.load(open(sys.argv[1],encoding='utf-8'))
assert j.get('available') is True,j
print("PUBLIC_EOD_API=PASS source_day=",j.get('source_day'))
PY
echo "PUBLIC_PERMANENT_MOUNT=PASS"
echo "PUBLIC_CANONICAL_JS=PASS"
echo "OLD_V8X_PUBLIC_OVERLAYS=REMOVED"

echo "=== PROTECTED SOURCE GATE ==="
python3 - "$SRC" "$DST" <<'PY'
import ast,hashlib,sys
a=open(sys.argv[1],encoding='utf-8').read()
b=open(sys.argv[2],encoding='utf-8').read()
def h(s):
    d={}
    for n in ast.walk(ast.parse(s)):
        if isinstance(n,(ast.FunctionDef,ast.AsyncFunctionDef)):
            x=hashlib.sha256(ast.dump(n,include_attributes=False).encode()).hexdigest()
            d.setdefault(n.name,[]).append(x)
    for k in d:d[k].sort()
    return d
ha,hb=h(a),h(b)
bad=[k for k,v in ha.items() if hb.get(k)!=v]
assert not bad,bad
print("ALL_EXISTING_FUNCTIONS_AST_IDENTICAL=PASS")
for tok in ("'trade_type':'0B'","'program_type':'0u'","'orderbook_type':'0D'","trde_upper_tp","amt_qty_tp","EOD_NONEMPTY_SECTION_PRESERVE_V8"):
    assert tok in b,tok
assert 'ka90004' not in b
print("BUY_SCORING_SELECTION_WS_CONTRACT_GUARD=PASS")
PY

echo "=== CORE LIVENESS 10/10 ==="
PASSN=0
for i in $(seq 1 10); do
  out="$(curl -sS --max-time 2 -o /dev/null -w '%{http_code} %{time_total}' http://127.0.0.1:3200/api/health || true)"
  echo "$i $out"
  [[ "$out" == 200* ]] && PASSN=$((PASSN+1))
  sleep 1
done
[[ "$PASSN" == 10 ]] || fail "liveness failed"
echo "CORE_LIVENESS_GATE=PASS 10/10"

TAG="quant-nova:2.4.22-afterhours-canonical-v9-$STAMP"
sudo docker commit "$APP" "$TAG" >/dev/null
echo "SNAPSHOT_IMAGE=$TAG"

SUCCESS=1
trap - ERR INT TERM

echo "=== FINAL ==="
echo "ARCHITECTURE=PERMANENT_BODY_MOUNT_PLUS_SINGLE_READONLY_EOD_API"
echo "OLD_V8_V81_V82_V83_OVERLAYS=REMOVED"
echo "SCROLL_REPAINT_DEPENDENCY=REMOVED"
echo "NATIVE_RENDER_FUNCTION_DEPENDENCY=REMOVED"
echo "WHITE_BOTTOM_BACKGROUND=ELIMINATED_DURING_SCREEN_HOLD"
echo "ALL_SNAPSHOT_SECTIONS=CANONICAL_RENDER_PATH"
echo "V8_NONEMPTY_SNAPSHOT_PROTECTION=PRESERVED"
echo "V7_KA90003_MAINTENANCE_REPLAY_FIXES=PRESERVED"
echo "BUY_LOGIC=UNCHANGED"
echo "SCORING=UNCHANGED"
echo "SELECTION=UNCHANGED"
echo "RANK_SPECS=UNCHANGED"
echo "WS_CONTRACT=0B/0u/0D_UNCHANGED"
echo "=== $REV PASS ==="
