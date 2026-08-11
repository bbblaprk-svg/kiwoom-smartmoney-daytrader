#!/usr/bin/env bash
set -Eeuo pipefail

REV="QUANT-NOVA-2.4.22-PWA-STANDALONE-STABLE-V11"
APP="quant-nova"
GUARD="nova-http-guard"
HOST_STATIC="/home/ubuntu/quant-nova/http-guard-v2/static"
HOST_CACHE="/home/ubuntu/quant-nova/http-guard-v2/cache"
STAMP="$(date +%Y%m%d%H%M%S)"
WORK="/tmp/nova-v11-$STAMP"
BK="$HOME/quant-nova/pwa-v11-backups"
SUCCESS=0

mkdir -p "$WORK" "$BK"
chmod 700 "$WORK" "$BK"

fail(){ echo "=== $REV FAIL: $* ===" >&2; exit 1; }

rollback(){
  ec=$?
  if [[ "$SUCCESS" -ne 1 ]]; then
    echo "=== V11 AUTO ROLLBACK ==="
    for f in index.html sw.js manifest.json manifest.webmanifest; do
      if [[ -f "$BK/$f.before-$STAMP" ]]; then
        sudo cp "$BK/$f.before-$STAMP" "$HOST_STATIC/$f" >/dev/null 2>&1 || true
        sudo docker cp "$BK/$f.before-$STAMP" "$APP:/app/static/$f" >/dev/null 2>&1 || true
      fi
    done
    sudo find "$HOST_CACHE" -maxdepth 1 -type f \( -name '*.body' -o -name '*.json' \) -delete >/dev/null 2>&1 || true
    sudo docker restart "$GUARD" >/dev/null 2>&1 || true
    echo "ROLLBACK=COMPLETE"
  fi
  exit "$ec"
}
trap rollback ERR INT TERM

echo "=== $REV START ==="
echo "ROOT_CAUSE=PWA_STANDALONE_SEPARATE_STORAGE_CACHE_AND_RESUME_VIEWPORT"
echo "ARCHITECTURE=VALID_BODY_FIXED_OVERLAY_PLUS_LOCAL_SNAPSHOT_LATCH"
echo "SERVICE_WORKER=FORCE_ACTIVATE_CLEAR_OLD_CACHES"
echo "MANIFEST_START_URL=VERSIONED"
echo "PATCH_SCOPE=PUBLIC_PWA_PRESENTATION_ONLY"
echo "QUANT_NOVA_RESTART=NO"
echo "MAIN_PY_CHANGE=NONE"
echo "BUY_LOGIC_CHANGE=NONE"
echo "SCORING_CHANGE=NONE"
echo "SELECTION_CHANGE=NONE"
echo "WS_CHANGE=NONE"

sudo docker inspect "$APP" >/dev/null || fail "quant-nova missing"
sudo docker inspect "$GUARD" >/dev/null || fail "nova-http-guard missing"

MAIN_BEFORE="$(sudo docker exec "$APP" sha256sum /app/app/main.py | awk '{print $1}')"
echo "MAIN_PY_SHA256_BEFORE=$MAIN_BEFORE"

for ep in /api/screen-state /api/eod-screen-snapshot; do
  c="$(curl -sS --max-time 5 -o /dev/null -w '%{http_code}' "http://127.0.0.1:3200$ep" || true)"
  echo "$ep=$c"
  [[ "$c" == "200" ]] || fail "$ep unavailable"
done

sudo cp "$HOST_STATIC/index.html" "$WORK/index.html"
sudo cp "$HOST_STATIC/sw.js" "$WORK/sw.js"
sudo chown "$(id -u):$(id -g)" "$WORK/index.html" "$WORK/sw.js"

MANIFEST="$(python3 - "$WORK/index.html" <<'PY'
import re,sys
s=open(sys.argv[1],encoding='utf-8').read()
m=re.search(r'<link[^>]+rel=["\']manifest["\'][^>]+href=["\']([^"\']+)',s,re.I)
if not m:
    m=re.search(r'<link[^>]+href=["\']([^"\']+)["\'][^>]+rel=["\']manifest["\']',s,re.I)
x=(m.group(1) if m else '').split('?')[0].lstrip('/')
if x.startswith('static/'): x=x[7:]
print(x if x else 'manifest.json')
PY
)"
if [[ ! -f "$HOST_STATIC/$MANIFEST" ]]; then
  if [[ -f "$HOST_STATIC/manifest.webmanifest" ]]; then MANIFEST="manifest.webmanifest"
  elif [[ -f "$HOST_STATIC/manifest.json" ]]; then MANIFEST="manifest.json"
  else fail "manifest not found"
  fi
fi
echo "MANIFEST_FILE=$MANIFEST"

sudo cp "$HOST_STATIC/$MANIFEST" "$WORK/$MANIFEST"
sudo chown "$(id -u):$(id -g)" "$WORK/$MANIFEST"

cp "$WORK/index.html" "$BK/index.html.before-$STAMP"
cp "$WORK/sw.js" "$BK/sw.js.before-$STAMP"
cp "$WORK/$MANIFEST" "$BK/$MANIFEST.before-$STAMP"

echo "=== BUILD PWA V11 ==="
python3 - "$WORK/index.html" "$WORK/sw.js" "$WORK/$MANIFEST" "$MANIFEST" <<'PY'
from pathlib import Path
import json,re,sys

ip=Path(sys.argv[1]); swp=Path(sys.argv[2]); mp=Path(sys.argv[3]); manifest_name=sys.argv[4]
html=ip.read_text(encoding='utf-8')
sw=swp.read_text(encoding='utf-8')

html=re.sub(
    r'\s*<!-- NOVA_PWA_STANDALONE_V11_START -->.*?<!-- NOVA_PWA_STANDALONE_V11_END -->\s*',
    '\n', html, flags=re.S
)

def ensure_meta(name, content):
    global html
    pat=rf'<meta[^>]+name=["\']{re.escape(name)}["\'][^>]*>'
    repl=f'<meta name="{name}" content="{content}">'
    if re.search(pat,html,re.I):
        html=re.sub(pat,repl,html,count=1,flags=re.I)
    else:
        html=html.replace('</head>',repl+'\n</head>',1)

ensure_meta('viewport','width=device-width, initial-scale=1, viewport-fit=cover')
ensure_meta('apple-mobile-web-app-capable','yes')
ensure_meta('apple-mobile-web-app-status-bar-style','black-translucent')
ensure_meta('apple-mobile-web-app-title','QUANT NOVA')

if re.search(r'<link[^>]+rel=["\']manifest["\']',html,re.I):
    html=re.sub(
        r'(<link[^>]+rel=["\']manifest["\'][^>]+href=["\'])([^"\']+)(["\'])',
        lambda m:m.group(1)+m.group(2).split('?')[0]+'?v=2.4.22-pwa-v11'+m.group(3),
        html,count=1,flags=re.I
    )
else:
    html=html.replace('</head>',f'<link rel="manifest" href="/{manifest_name}?v=2.4.22-pwa-v11">\n</head>',1)

bootstrap = r'''
<!-- NOVA_PWA_STANDALONE_V11_START -->
<div id="novaPwaV11" hidden></div>
<script>
(function(){
  'use strict';
  const ROOT='novaPwaV11', STORE='NOVA_EOD_V11_SNAPSHOT', HOLD='NOVA_EOD_V11_HOLD';
  let last=null, hold=false, activeConfirm=0, busy=false;

  const standalone=()=>window.matchMedia('(display-mode: standalone)').matches || window.navigator.standalone===true;
  const esc=v=>String(v??'').replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
  const num=v=>{const x=Number(String(v??'').replace(/,/g,'').replace(/[^\d.+-]/g,''));return Number.isFinite(x)?x:NaN};
  const won=v=>Number.isFinite(num(v))?Math.round(num(v)).toLocaleString('ko-KR'):'-';
  const pct=v=>Number.isFinite(num(v))?`${num(v)>=0?'+':''}${num(v).toFixed(2)}%`:'-';
  const first=(o,ks,d='-')=>{for(const k of ks){const v=o?.[k];if(v!==undefined&&v!==null&&v!=='')return v}return d};
  const rows=(o,ks=['rows','items','signals','picks','alerts','events','data'])=>{if(Array.isArray(o))return o;if(!o||typeof o!=='object')return[];for(const k of ks)if(Array.isArray(o[k]))return o[k];return[]};
  const nested=(o,ks)=>{const a=[];if(!o||typeof o!=='object')return a;for(const k of ks)if(Array.isArray(o[k]))a.push(...o[k]);return a};

  async function getj(u){
    try{const r=await fetch(u,{cache:'no-store'});return r.ok?await r.json():null}catch(e){return null}
  }

  function ensureRoot(){
    let r=document.getElementById(ROOT);
    if(!r){r=document.createElement('div');r.id=ROOT;document.body.insertBefore(r,document.body.firstChild)}
    return r;
  }

  function reason(r){
    const z=first(r,['reason','reasons','why','body','title'],'');
    return Array.isArray(z)?z.join(' · '):String(z||'');
  }

  function card(r,type='signal'){
    const rate=first(r,['change_rate','rate','change_pct'],'-'), rv=num(rate), cls=Number.isFinite(rv)&&rv<0?' down':'';
    const name=first(r,['name','stock_name','item_name','code','stage','status'],'기록');
    const code=first(r,['code','stock_code','symbol'],'');
    const stage=first(r,type==='close'?['energy_state','state','status']:['stage','signal_stage','event','status'],'-');
    const price=first(r,type==='close'?['price','current_price','close_price']:['current_price','live_price','last_price','price'],'-');
    const meta=reason(r)||Object.entries(r||{}).filter(([k,v])=>['string','number','boolean'].includes(typeof v)).slice(0,8).map(([k,v])=>`${k} ${v}`).join(' · ');
    return `<div class="v11-card"><div class="v11-top"><div class="v11-name">${esc(name)}${code?`<span>${esc(code)}</span>`:''}</div><div><b>${esc(stage)}</b><strong class="${cls}">${pct(rate)}</strong></div></div><div class="v11-meta">${esc(meta)}</div><div class="v11-price">가격 <em>${won(price)}</em> · 점수 ${esc(first(r,['score','signal_score','close_score','total_score']))}</div></div>`;
  }

  function section(title,a,type='signal',note=''){
    return `<section class="v11-sec"><header><h3>${esc(title)}</h3><small>${a.length}건</small></header><div class="v11-list">${a.length?a.map(x=>card(x,type)).join(''):'<div class="v11-empty">저장된 행이 없습니다.</div>'}</div>${note?`<p class="v11-note">${esc(note)}</p>`:''}</section>`;
  }

  function render(s){
    if(!s)return;
    last=s;
    try{localStorage.setItem(STORE,JSON.stringify(s));localStorage.setItem(HOLD,'1')}catch(e){}
    const root=ensureRoot();
    const nova=rows(s.nova), alerts=rows(s.nxt_alerts).slice(0,100), nxt=rows(s.nxt_signal_table), close=rows(s.close_picks),
          smart=rows(s.close_smart_money), buys=rows(s.buy_signals), opening=rows(s.opening_shakeout), rs=rows(s.rs_leaders),
          adv=nested(s.buy_signals,['prebuy_rows','near_miss_rows']);

    root.hidden=false;
    root.innerHTML=`
      <style>
        html.v11-hold,html.v11-hold body{margin:0!important;min-height:100%!important;background:#082b39!important;overflow:hidden!important}
        html.v11-hold body>*:not(#${ROOT}){visibility:hidden!important;pointer-events:none!important}
        #${ROOT}{visibility:visible!important;display:block!important;position:fixed!important;inset:0!important;z-index:2147483647!important;background:#082b39!important;color:#dcecf2!important;overflow-y:auto!important;overflow-x:hidden!important;-webkit-overflow-scrolling:touch!important;overscroll-behavior-y:contain!important;box-sizing:border-box!important;padding:calc(env(safe-area-inset-top) + 18px) max(16px,env(safe-area-inset-right)) calc(env(safe-area-inset-bottom) + 72px) max(16px,env(safe-area-inset-left))!important;height:100dvh!important;min-height:100dvh!important}
        #${ROOT} .v11-wrap{max-width:1180px;margin:0 auto;width:100%}
        #${ROOT} .v11-brand{display:flex;justify-content:space-between;align-items:flex-start;gap:12px;padding:6px 2px 20px}
        #${ROOT} .v11-brand h1{margin:0;color:#effbff;font-size:34px;letter-spacing:-.04em}#${ROOT} .v11-brand h1 span{color:#61def6}
        #${ROOT} .v11-closed{border:1px solid rgba(130,170,185,.22);border-radius:16px;padding:9px 12px;background:#071e29;color:#dceaf0;font-size:11px;font-weight:800}
        #${ROOT} .v11-head{border:1px solid rgba(210,173,65,.55);border-radius:20px;padding:16px;background:rgba(32,58,61,.74);margin-bottom:16px}
        #${ROOT} .v11-head h2{margin:0;color:#f2fbff;font-size:18px}#${ROOT} .v11-head p{margin:7px 0 0;color:#79949f;font-size:10px;line-height:1.5}
        #${ROOT} .v11-kpis{display:grid;grid-template-columns:repeat(2,minmax(0,1fr));gap:9px;margin-bottom:16px}
        #${ROOT} .v11-kpi{background:#071e29;border:1px solid rgba(105,175,205,.16);border-radius:14px;padding:12px}#${ROOT} .v11-kpi b{display:block;color:#fff;font-size:20px}#${ROOT} .v11-kpi span{display:block;color:#708d99;font-size:9px;margin-top:3px}
        #${ROOT} .v11-sec{background:#071e29;border:1px solid rgba(105,175,205,.17);border-radius:18px;padding:13px;margin:12px 0}#${ROOT} .v11-sec header{display:flex;justify-content:space-between;align-items:center;gap:8px;margin-bottom:9px}#${ROOT} .v11-sec h3{margin:0;color:#effaff;font-size:14px}#${ROOT} .v11-sec small{color:#79949f;font-size:10px}
        #${ROOT} .v11-list{display:grid;grid-template-columns:1fr;gap:8px}.v11-card{border:1px solid rgba(108,174,205,.13);border-radius:13px;padding:11px;background:rgba(0,0,0,.09)}.v11-top{display:flex;justify-content:space-between;gap:10px}.v11-name{color:#fff;font-size:14px;font-weight:800}.v11-name span{color:#78939f;font-size:9px;margin-left:5px;font-weight:500}.v11-top b{display:block;color:#a7c0c9;font-size:9px;text-align:right}.v11-top strong{display:block;color:#ff7e8b;font-size:16px;text-align:right}.v11-top strong.down{color:#78aaf2}.v11-meta{margin-top:6px;color:#91a9b2;font-size:10px;line-height:1.5;overflow-wrap:anywhere}.v11-price{margin-top:7px;padding-top:7px;border-top:1px solid rgba(112,170,195,.11);color:#a4bbc4;font-size:9px}.v11-price em{font-style:normal;color:#effaff;font-weight:800}.v11-empty{padding:15px 4px;color:#6d8995;font-size:11px;text-align:center}.v11-note{color:#66838f;font-size:9px;line-height:1.45}
        @media(min-width:760px){#${ROOT} .v11-kpis{grid-template-columns:repeat(4,minmax(0,1fr))}#${ROOT} .v11-list{grid-template-columns:repeat(2,minmax(0,1fr))}}
      </style>
      <div class="v11-wrap">
        <div class="v11-brand"><h1>QUANT <span>NOVA</span></h1><div class="v11-closed">MARKET CLOSED</div></div>
        <div class="v11-head"><h2>LAST MARKET SNAPSHOT · ${esc(s.source_day||'-')}</h2><p>${esc(s.captured_at||'')} · Home Screen/PWA 복귀에도 유지되는 읽기전용 snapshot</p></div>
        <div class="v11-kpis"><div class="v11-kpi"><b>${nxt.length}</b><span>NXT SIGNAL</span></div><div class="v11-kpi"><b>${alerts.length}</b><span>NXT ALERTS</span></div><div class="v11-kpi"><b>${close.length}</b><span>종가후보</span></div><div class="v11-kpi"><b>${buys.length}</b><span>확정 BUY</span></div></div>
        ${section('메인 안정보드',nova,'signal','오늘 저장본이 0건이면 임의 생성하지 않습니다.')}
        ${section('개장 흔들기 · 급반전',opening,'generic')}
        ${section('NXT 급등 조기발견 알림',alerts,'signal','저장된 이벤트 최대 100건')}
        ${section('NXT SIGNAL MANAGEMENT',nxt,'signal')}
        ${section('종가추천 · 다음날 후보',close,'close')}
        ${section('종가 스마트머니',smart,'generic')}
        ${section('확정 BUY 기록',buys,'signal')}
        ${section('BUY 조기추천/근접 기록',adv,'generic')}
        ${section('RS 리더',rs,'generic')}
      </div>`;
    document.documentElement.classList.add('v11-hold');
  }

  function hide(){
    const r=ensureRoot();r.hidden=true;r.innerHTML='';
    document.documentElement.classList.remove('v11-hold');
    hold=false;activeConfirm=0;last=null;
    try{localStorage.removeItem(HOLD)}catch(e){}
  }

  function restoreLocal(){
    try{
      const raw=localStorage.getItem(STORE), h=localStorage.getItem(HOLD)==='1';
      if(h&&raw){const s=JSON.parse(raw);hold=true;render(s);return true}
    }catch(e){}
    return false;
  }

  async function refresh(){
    if(busy)return;busy=true;
    try{
      const [st,s]=await Promise.all([getj('/api/screen-state'),getj('/api/eod-screen-snapshot')]);
      if(st?.screen_hold?.active===true){
        hold=true;activeConfirm=0;
        if(s?.available===true)render(s); else if(last)render(last);
        return;
      }
      if(hold&&st?.runtime_awake===true){
        activeConfirm++;
        if(activeConfirm>=3){hide();return}
      }else if(hold){
        activeConfirm=0;
      }
      if(hold){
        if(s?.available===true)render(s); else if(last)render(last);
      }
    }finally{busy=false}
  }

  if(standalone())restoreLocal();
  setTimeout(refresh,100);
  setTimeout(refresh,700);
  setTimeout(refresh,2200);
  setInterval(refresh,5000);

  const revive=()=>{
    if(hold&&last)render(last); else if(standalone())restoreLocal();
    refresh();
  };
  window.addEventListener('pageshow',revive);
  window.addEventListener('focus',revive);
  window.addEventListener('orientationchange',()=>setTimeout(revive,100));
  document.addEventListener('visibilitychange',()=>{if(!document.hidden)revive()});
  if(window.visualViewport){
    window.visualViewport.addEventListener('resize',()=>{const r=document.getElementById(ROOT);if(r&&!r.hidden)r.style.height='100dvh'});
  }

  if('serviceWorker' in navigator){
    window.addEventListener('load',async()=>{
      try{
        const reg=await navigator.serviceWorker.register('/sw.js?v=2.4.22-pwa-v11',{scope:'/',updateViaCache:'none'});
        await reg.update();
      }catch(e){}
    });
  }

  window.NOVA_PWA_V11={refresh:revive};
})();
</script>
<!-- NOVA_PWA_STANDALONE_V11_END -->
'''

m=re.search(r'<body[^>]*>',html,re.I)
if not m: raise SystemExit('BODY_TAG_NOT_FOUND')
html=html[:m.end()]+'\n'+bootstrap+'\n'+html[m.end():]

data=json.loads(mp.read_text(encoding='utf-8'))
data['display']='standalone'
data['start_url']='/?pwa=2.4.22-v11'
data['scope']='/'
mp.write_text(json.dumps(data,ensure_ascii=False,indent=2),encoding='utf-8')

sw=re.sub(
    r'\n?/\*\s*NOVA_PWA_SW_V11_START\s*\*/.*?/\*\s*NOVA_PWA_SW_V11_END\s*\*/\n?',
    '\n',sw,flags=re.S
)
sw += r'''
/* NOVA_PWA_SW_V11_START */
self.addEventListener('install', event => {
  self.skipWaiting();
});
self.addEventListener('activate', event => {
  event.waitUntil((async () => {
    try {
      const keys = await caches.keys();
      await Promise.all(keys.map(k => caches.delete(k)));
    } catch (e) {}
    await self.clients.claim();
  })());
});
/* NOVA_PWA_SW_V11_END */
'''
swp.write_text(sw,encoding='utf-8')
ip.write_text(html,encoding='utf-8')

print('INDEX_INLINE_PWA_BOOTSTRAP=PASS')
print('MANIFEST_VERSIONED_START_URL=PASS')
print('SW_V11_INSTALL_ACTIVATE=PASS')
PY

if command -v node >/dev/null 2>&1; then
  node --check "$WORK/sw.js"
  python3 - "$WORK/index.html" "$WORK/inline-v11.js" <<'PY'
import re,sys
s=open(sys.argv[1],encoding='utf-8').read()
m=re.search(r'<!-- NOVA_PWA_STANDALONE_V11_START -->.*?<script>(.*?)</script>.*?<!-- NOVA_PWA_STANDALONE_V11_END -->',s,re.S)
assert m
open(sys.argv[2],'w',encoding='utf-8').write(m.group(1))
PY
  node --check "$WORK/inline-v11.js"
  echo "NODE_CHECKS=PASS"
fi

echo "=== INSTALL PUBLIC PWA STATIC ==="
sudo cp "$WORK/index.html" "$HOST_STATIC/index.html"
sudo cp "$WORK/sw.js" "$HOST_STATIC/sw.js"
sudo cp "$WORK/$MANIFEST" "$HOST_STATIC/$MANIFEST"
sudo chmod 644 "$HOST_STATIC/index.html" "$HOST_STATIC/sw.js" "$HOST_STATIC/$MANIFEST"

sudo docker cp "$WORK/index.html" "$APP:/app/static/index.html"
sudo docker cp "$WORK/sw.js" "$APP:/app/static/sw.js"
sudo docker cp "$WORK/$MANIFEST" "$APP:/app/static/$MANIFEST"

sudo find "$HOST_CACHE" -maxdepth 1 -type f \( -name '*.body' -o -name '*.json' \) -delete 2>/dev/null || true
sudo docker restart "$GUARD" >/dev/null
sleep 2

echo "=== PUBLIC PWA GATE ==="
curl -ksS --max-time 6 https://3-38-25-20.nip.io/ > "$WORK/public.html"
curl -ksS --max-time 6 'https://3-38-25-20.nip.io/sw.js?v=2.4.22-pwa-v11' > "$WORK/public-sw.js"
curl -ksS --max-time 6 "https://3-38-25-20.nip.io/$MANIFEST?v=2.4.22-pwa-v11" > "$WORK/public-manifest"

grep -q 'NOVA_PWA_STANDALONE_V11_START' "$WORK/public.html"
grep -q 'viewport-fit=cover' "$WORK/public.html"
grep -q 'NOVA_PWA_SW_V11_START' "$WORK/public-sw.js"
python3 - "$WORK/public-manifest" <<'PY'
import json,sys
j=json.load(open(sys.argv[1],encoding='utf-8'))
assert j.get('display')=='standalone',j
assert j.get('start_url')=='/?pwa=2.4.22-v11',j
assert j.get('scope')=='/',j
print('PUBLIC_MANIFEST_V11=PASS')
PY
echo "PUBLIC_INDEX_V11=PASS"
echo "PUBLIC_SW_V11=PASS"

MAIN_AFTER="$(sudo docker exec "$APP" sha256sum /app/app/main.py | awk '{print $1}')"
echo "MAIN_PY_SHA256_AFTER=$MAIN_AFTER"
[[ "$MAIN_BEFORE" == "$MAIN_AFTER" ]] || fail "main.py changed"
echo "MAIN_PY_HASH_GATE=PASS"

SUCCESS=1
trap - ERR INT TERM

echo "=== FINAL ==="
echo "PWA_STANDALONE_FIXED_OVERLAY=ACTIVE"
echo "PWA_LOCAL_SNAPSHOT_LATCH=ACTIVE"
echo "PAGESHOW_VISIBILITY_FOCUS_RESTORE=ACTIVE"
echo "DYNAMIC_VIEWPORT_100DVH_SAFE_AREA=ACTIVE"
echo "SERVICE_WORKER_OLD_CACHES=CLEARED_ON_ACTIVATE"
echo "SERVICE_WORKER_EXISTING_PUSH_CODE=PRESERVED"
echo "MANIFEST_START_URL=/?pwa=2.4.22-v11"
echo "QUANT_NOVA_RESTART=NO"
echo "MAIN_PY=BYTE_IDENTICAL"
echo "BUY_LOGIC=UNCHANGED"
echo "SCORING=UNCHANGED"
echo "SELECTION=UNCHANGED"
echo "WS=UNCHANGED"
echo "=== $REV PASS ==="
