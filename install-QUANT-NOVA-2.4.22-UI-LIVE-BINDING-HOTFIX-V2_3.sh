#!/usr/bin/env bash
set -Eeuo pipefail

REV="QUANT-NOVA-2.4.22-UI-LIVE-BINDING-HOTFIX-V2.3"
APP="quant-nova"
GUARD="nova-http-guard"
STAMP="$(date +%Y%m%d%H%M%S)"
WORK="/tmp/nova-ui-v23-$STAMP"
BK="$HOME/quant-nova/ui-v23-backups"
HOST_STATIC="/home/ubuntu/quant-nova/http-guard-v2/static"
HOST_CACHE="/home/ubuntu/quant-nova/http-guard-v2/cache"

mkdir -p "$WORK" "$BK"
chmod 700 "$WORK" "$BK"

echo "=== $REV START ==="
echo "PATCH_SCOPE=FRONTEND_BINDING_ONLY"
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

sudo cp "$HOST_STATIC/nova.js" "$WORK/nova.js"
sudo cp "$HOST_STATIC/index.html" "$WORK/index.html"
sudo chown "$(id -u):$(id -g)" "$WORK/nova.js" "$WORK/index.html"
cp "$WORK/nova.js" "$BK/nova.js.before-$STAMP"
cp "$WORK/index.html" "$BK/index.html.before-$STAMP"

# Remove older copy of this exact V2.3 plugin if re-run.
python3 - "$WORK/nova.js" <<'PY'
from pathlib import Path
import re,sys
p=Path(sys.argv[1]); s=p.read_text(encoding='utf-8')
s=re.sub(r'/\*\s*NOVA_UI_LIVE_BINDING_HOTFIX_V23_START\s*\*/.*?/\*\s*NOVA_UI_LIVE_BINDING_HOTFIX_V23_END\s*\*/','',s,flags=re.S)
p.write_text(s,encoding='utf-8')
PY

cat >> "$WORK/nova.js" <<'JS'
/* NOVA_UI_LIVE_BINDING_HOTFIX_V23_START */
(function(){
  'use strict';

  const norm=s=>String(s||'').replace(/\s+/g,' ').trim();
  const num=v=>{
    if(v===null||v===undefined||v==='') return NaN;
    const x=Number(String(v).replace(/,/g,'').replace(/[^\d.+-]/g,''));
    return Number.isFinite(x)?x:NaN;
  };
  const money=v=>Number.isFinite(num(v))?Math.round(num(v)).toLocaleString('ko-KR'):'-';
  const pct=v=>Number.isFinite(num(v))?`${num(v)>=0?'+':''}${num(v).toFixed(2)}%`:'-';
  const codeFrom=s=>(String(s||'').match(/(?:^|[^\d])(\d{6})(?:[^\d]|$)/)||[])[1]||'';

  function kstMinutes(){
    try{
      const p=new Intl.DateTimeFormat('en-GB',{timeZone:'Asia/Seoul',hour:'2-digit',minute:'2-digit',hourCycle:'h23'}).formatToParts(new Date());
      return Number(p.find(x=>x.type==='hour')?.value||0)*60+Number(p.find(x=>x.type==='minute')?.value||0);
    }catch(e){
      const d=new Date(Date.now()+9*3600000);
      return d.getUTCHours()*60+d.getUTCMinutes();
    }
  }

  function headingNode(text){
    return [...document.querySelectorAll('h1,h2,h3,h4,div,p')].find(el=>{
      const t=norm(el.textContent);
      return t===text || (t.includes(text) && t.length<120);
    }) || null;
  }

  function sectionAroundHeading(text){
    const h=headingNode(text);
    if(!h) return null;
    let best=h.parentElement;
    let el=h;
    for(let i=0;i<8 && el && el!==document.body;i++,el=el.parentElement){
      const t=norm(el.textContent);
      if(!t.includes(text)) continue;
      best=el;
      if(el.tagName==='SECTION' || /section|panel|module|close|pick/i.test(String(el.className||''))) return el;
    }
    return best;
  }

  function enforceClosePicksWindow(){
    const sec=sectionAroundHeading('종가추천종목 · 다음날 프리마켓 후보') ||
              sectionAroundHeading('종가추천종목');
    if(!sec) return;
    const t=kstMinutes();
    const show=(t>=19*60+30)||(t<8*60+50);
    if(show){
      if(sec.dataset.novaV23Hidden==='1'){
        sec.style.removeProperty('display');
        sec.removeAttribute('aria-hidden');
        delete sec.dataset.novaV23Hidden;
      }
    }else{
      sec.style.setProperty('display','none','important');
      sec.setAttribute('aria-hidden','true');
      sec.dataset.novaV23Hidden='1';
    }
  }

  const liveMap=new Map();

  function pickPrice(o){
    for(const k of ['current_price','live_price','last_price','cur_price','now_price','price_now']){
      const v=num(o?.[k]);
      if(Number.isFinite(v)&&v>0) return v;
    }
    const p=num(o?.price);
    return Number.isFinite(p)&&p>0?p:NaN;
  }

  function ingest(o,depth=0){
    if(!o || depth>8) return;
    if(Array.isArray(o)){ for(const x of o) ingest(x,depth+1); return; }
    if(typeof o!=='object') return;
    const code=String(o.code??o.stock_code??o.item_code??o.symbol??'').match(/\d{6}/)?.[0]||'';
    if(code){
      const p=pickPrice(o);
      if(Number.isFinite(p)) liveMap.set(code,{price:p,ts:Date.now()});
    }
    for(const v of Object.values(o)) if(v && typeof v==='object') ingest(v,depth+1);
  }

  async function getJson(url){
    try{
      const r=await fetch(url,{cache:'no-store'});
      if(r.ok) ingest(await r.json(),0);
    }catch(e){}
  }

  async function refreshLiveMap(){
    await Promise.all([
      getJson('/api/nova'),
      getJson('/api/nxt-signal-table'),
      getJson('/api/opening-shakeout-reversal')
    ]);
    applyEarlyAlertLivePrices();
  }

  function earlyAlertRoot(){
    return sectionAroundHeading('NXT 급등 조기발견 알림');
  }

  function candidateAlertCards(){
    const root=earlyAlertRoot();
    if(!root) return [];
    const stage=/(SECOND_WAVE_(?:READY|BUY|BASE)|EMERGENCY_IGNITION|PRE_IGNITION|BUY_READY|BUY_EARLY|IGNITION|RECOVERY_(?:EARLY|READY|BUY)|FAST_JUMP)/;
    const nodes=[...root.querySelectorAll('article,li,tr,div')].filter(el=>{
      const t=norm(el.textContent);
      return t.length>=25 && t.length<=900 && stage.test(t) && /\d{6}/.test(t);
    });
    return nodes.filter(el=>![...el.children].some(ch=>{
      const t=norm(ch.textContent);
      return t.length>=25 && t.length<=900 && stage.test(t) && /\d{6}/.test(t);
    }));
  }

  function inferCapturePrice(t){
    const m=String(t||'').match(/[+-]?\d+(?:\.\d+)?%\s*([0-9][0-9,]{2,})/);
    return m?num(m[1]):NaN;
  }

  function applyEarlyAlertLivePrices(){
    for(const card of candidateAlertCards()){
      const text=norm(card.textContent);
      const code=codeFrom(text);
      if(!code) continue;
      const live=liveMap.get(code);
      if(!live || !Number.isFinite(live.price)) continue;

      let cap=num(card.dataset.novaV23Capture);
      if(!Number.isFinite(cap)){
        cap=inferCapturePrice(text);
        if(Number.isFinite(cap)) card.dataset.novaV23Capture=String(cap);
      }

      let box=card.querySelector(':scope > .nova-v23-live');
      if(!box){
        box=document.createElement('div');
        box.className='nova-v23-live';
        card.appendChild(box);
      }
      const perf=Number.isFinite(cap)&&cap>0 ? (live.price/cap-1)*100 : NaN;
      box.innerHTML=
        `<span>포착가 <b>${money(cap)}</b></span>`+
        `<span>현재가 <b>${money(live.price)}</b></span>`+
        `<span>포착후 <b class="${perf>=0?'up':'down'}">${pct(perf)}</b></span>`+
        `<span class="live">LIVE</span>`;
    }
  }

  function ensureStyle(){
    if(document.getElementById('novaV23Style')) return;
    const s=document.createElement('style');
    s.id='novaV23Style';
    s.textContent=`
      .nova-v23-live{display:flex;gap:12px;align-items:center;flex-wrap:wrap;margin-top:8px;padding-top:7px;border-top:1px solid rgba(120,170,190,.18);font-size:11px;color:#7f9ca7}
      .nova-v23-live b{font-size:12px;color:#eef7f9}
      .nova-v23-live b.up{color:#ff7e89}.nova-v23-live b.down{color:#78aef7}
      .nova-v23-live .live{margin-left:auto;color:#9cff70;font-weight:900;letter-spacing:.05em}
    `;
    document.head.appendChild(s);
  }

  function boot(){
    ensureStyle();
    enforceClosePicksWindow();
    refreshLiveMap();

    setInterval(enforceClosePicksWindow,5000);
    setInterval(refreshLiveMap,5000);

    const mo=new MutationObserver(()=>{
      enforceClosePicksWindow();
      applyEarlyAlertLivePrices();
    });
    mo.observe(document.body,{subtree:true,childList:true});

    document.addEventListener('visibilitychange',()=>{
      if(!document.hidden){
        enforceClosePicksWindow();
        refreshLiveMap();
      }
    });
  }

  if(document.readyState==='loading') document.addEventListener('DOMContentLoaded',boot,{once:true});
  else boot();

  window.NOVA_UI_LIVE_BINDING_HOTFIX_V23={
    enforceClosePicksWindow,
    refreshLiveMap,
    applyEarlyAlertLivePrices
  };
})();
/* NOVA_UI_LIVE_BINDING_HOTFIX_V23_END */
JS

python3 - "$WORK/index.html" <<'PY'
from pathlib import Path
import re,sys
p=Path(sys.argv[1]); s=p.read_text(encoding='utf-8')
if re.search(r'/static/nova\.js\?v=[^"\']+',s):
    s=re.sub(r'/static/nova\.js\?v=[^"\']+','/static/nova.js?v=2.4.22-ui-live-binding-v23',s,count=1)
elif '/static/nova.js' in s:
    s=s.replace('/static/nova.js','/static/nova.js?v=2.4.22-ui-live-binding-v23',1)
else:
    raise SystemExit('NOVA_JS_REFERENCE_NOT_FOUND')
p.write_text(s,encoding='utf-8')
print('INDEX_CACHE_BUST=PASS')
PY

echo "=== JS SYNTAX ==="
if command -v node >/dev/null 2>&1; then
  node --check "$WORK/nova.js"
  echo "NODE_CHECK=PASS"
else
  echo "NODE_CHECK=SKIP"
fi

echo "=== INSTALL PUBLIC STATIC ==="
sudo cp "$WORK/nova.js" "$HOST_STATIC/nova.js"
sudo cp "$WORK/index.html" "$HOST_STATIC/index.html"
sudo chmod 644 "$HOST_STATIC/nova.js" "$HOST_STATIC/index.html"

sudo docker exec "$GUARD" sh -c "grep -q 'NOVA_UI_LIVE_BINDING_HOTFIX_V23_START' /srv/static/nova.js"
sudo docker exec "$GUARD" sh -c "grep -q 'ui-live-binding-v23' /srv/static/index.html"
echo "HTTP_GUARD_STATIC=PASS"

echo "=== KEEP APP STATIC IN SYNC ==="
sudo docker cp "$WORK/nova.js" "$APP:/app/static/nova.js"
sudo docker cp "$WORK/index.html" "$APP:/app/static/index.html"
echo "QUANT_NOVA_STATIC=PASS"

echo "=== CLEAR RESPONSE CACHE ==="
sudo find "$HOST_CACHE" -maxdepth 1 -type f \( -name '*.body' -o -name '*.json' \) -delete 2>/dev/null || true
echo "HTTP_GUARD_CACHE=EMPTY"

echo "=== RESTART HTTP GUARD ONLY ==="
sudo docker restart "$GUARD" >/dev/null
sleep 2
echo "HTTP_GUARD_RESTART=PASS"

echo "=== PUBLIC VERIFY ==="
PUB_HTML="$WORK/public.html"
PUB_JS="$WORK/public.js"
RH="$(curl -ksS --max-time 6 -o "$PUB_HTML" -w '%{http_code}' https://3-38-25-20.nip.io/ || true)"
RJ="$(curl -ksS --max-time 6 -o "$PUB_JS" -w '%{http_code}' 'https://3-38-25-20.nip.io/static/nova.js?v=2.4.22-ui-live-binding-v23' || true)"
echo "PUBLIC_ROOT_HTTP=$RH"
echo "PUBLIC_JS_HTTP=$RJ"
grep -q 'ui-live-binding-v23' "$PUB_HTML"
grep -q 'NOVA_UI_LIVE_BINDING_HOTFIX_V23_START' "$PUB_JS"
echo "PUBLIC_V23_MARKER=PASS"

echo "=== API CHECK ==="
for ep in /api/health /api/nova /api/nxt-signal-table /api/opening-shakeout-reversal /api/close-picks; do
  C="$(curl -sS --max-time 4 -o /dev/null -w '%{http_code}' "http://127.0.0.1:3200$ep" || true)"
  echo "$ep=$C"
  [[ "$C" == "200" ]] || { echo "API_GATE=FAIL:$ep" >&2; exit 1; }
done
echo "API_GATE=PASS"

MAIN_AFTER="$(sudo docker exec "$APP" sha256sum /app/app/main.py | awk '{print $1}')"
echo "MAIN_PY_SHA256_AFTER=$MAIN_AFTER"
[[ "$MAIN_BEFORE" == "$MAIN_AFTER" ]]
echo "MAIN_PY_HASH_GATE=PASS"

echo "=== FINAL ==="
echo "CLOSEPICKS_08:50_TO_19:29=FORCE_HIDDEN_UI_ONLY"
echo "EARLY_ALERT_CAPTURE_PRICE=PRESERVED"
echo "EARLY_ALERT_CURRENT_PRICE=5S_REFRESH_FROM_EXISTING_APIS"
echo "EARLY_ALERT_PERFORMANCE=DISPLAY_ONLY"
echo "MUTATION_OBSERVER=ENABLED"
echo "DATA_LOGIC=UNCHANGED"
echo "SELECTION_LOGIC=UNCHANGED"
echo "BUY_THRESHOLDS=UNCHANGED"
echo "SCORING_FORMULA=UNCHANGED"
echo "WS_LOGIC=UNCHANGED"
echo "MAIN_PY=BYTE_IDENTICAL"
echo "=== $REV PASS ==="
