#!/usr/bin/env bash
set -Eeuo pipefail

REV="QUANT-NOVA-2.4.22-UI-TRUTH-CONSOLIDATION-V2"
APP="quant-nova"
STAMP="$(date +%Y%m%d%H%M%S)"
BASE="$HOME/quant-nova"
BK="$BASE/ui-truth-v2-backups"
WORK="/tmp/nova-ui-truth-v2-$STAMP"
OLD_JS="$BK/nova.js.before-$STAMP"
OLD_HTML="$BK/index.html.before-$STAMP"
NEW_JS="$WORK/nova.js"
NEW_HTML="$WORK/index.html"
SUCCESS=0

mkdir -p "$BK" "$WORK"
chmod 700 "$BK" "$WORK"

rollback() {
  local ec=$?
  if [[ "$SUCCESS" -ne 1 ]]; then
    echo "=== UI PATCH FAILED - RESTORE STATIC BACKUP ==="
    [[ -f "$OLD_JS" ]] && sudo docker cp "$OLD_JS" "$APP:/app/static/nova.js" >/dev/null 2>&1 || true
    [[ -f "$OLD_HTML" ]] && sudo docker cp "$OLD_HTML" "$APP:/app/static/index.html" >/dev/null 2>&1 || true
    echo "STATIC_ROLLBACK=COMPLETE"
  fi
  exit "$ec"
}
trap rollback ERR INT TERM

echo "=== $REV START ==="
echo "PATCH_SCOPE=FRONTEND_PRESENTATION_AND_DIAGNOSTICS_ONLY"
echo "DATA_LOGIC_CHANGE=NONE"
echo "SELECTION_LOGIC_CHANGE=NONE"
echo "BUY_THRESHOLDS_CHANGE=NONE"
echo "SCORING_FORMULA_CHANGE=NONE"
echo "CANDIDATE_SELECTION_CHANGE=NONE"
echo "PREMARKET_RERANK_LOGIC_CHANGE=NONE"
echo "WS_CONTRACT_CHANGE=NONE"
echo "RALLY_DNA_CHANGE=NONE"
echo "EXIT_DNA_CHANGE=NONE"
echo "SECTOR_ENGINE_CHANGE=NONE"
echo "RS_ENGINE_CHANGE=NONE"

sudo docker inspect "$APP" >/dev/null
MAIN_BEFORE="$(sudo docker exec "$APP" sha256sum /app/app/main.py | awk '{print $1}')"
echo "MAIN_PY_SHA256_BEFORE=$MAIN_BEFORE"

sudo docker cp "$APP:/app/static/nova.js" "$OLD_JS"
sudo docker cp "$APP:/app/static/index.html" "$OLD_HTML"
sudo cp "$OLD_JS" "$NEW_JS"
sudo cp "$OLD_HTML" "$NEW_HTML"
sudo chown "$(id -u):$(id -g)" "$NEW_JS" "$NEW_HTML"
chmod 600 "$NEW_JS" "$NEW_HTML"

python3 - "$NEW_JS" "$NEW_HTML" <<'PY'
from pathlib import Path
import re, sys

jp=Path(sys.argv[1]); hp=Path(sys.argv[2])
js=jp.read_text(encoding='utf-8')
html=hp.read_text(encoding='utf-8')

pat=re.compile(r'/\*\s*NOVA_UI_TRUTH_CONSOLIDATION_V2_START\s*\*/.*?/\*\s*NOVA_UI_TRUTH_CONSOLIDATION_V2_END\s*\*/', re.S)
js=pat.sub('', js)

addon = r'''
/* NOVA_UI_TRUTH_CONSOLIDATION_V2_START */
(function(){
  'use strict';
  const V='NOVA_UI_TRUTH_CONSOLIDATION_V2';

  const txt=(el)=>String(el?.textContent||'').replace(/\s+/g,' ').trim();
  const esc=(v)=>String(v??'').replace(/[&<>"']/g,m=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[m]));
  const codeOf=(s)=>{ const m=String(s||'').match(/(?:^|[^\d])(\d{6})(?:[^\d]|$)/); return m?m[1]:''; };
  const n=(v)=>{ if(v===null||v===undefined||v==='')return NaN; const x=Number(String(v).replace(/,/g,'')); return Number.isFinite(x)?x:NaN; };
  const money=(v)=>Number.isFinite(n(v))?Math.round(n(v)).toLocaleString('ko-KR'):'-';
  const pct=(v)=>Number.isFinite(n(v))?`${n(v)>=0?'+':''}${n(v).toFixed(2)}%`:'-';

  function kstMinutes(){
    try{
      const p=new Intl.DateTimeFormat('en-GB',{timeZone:'Asia/Seoul',hour:'2-digit',minute:'2-digit',hourCycle:'h23'}).formatToParts(new Date());
      return Number(p.find(x=>x.type==='hour')?.value||0)*60+Number(p.find(x=>x.type==='minute')?.value||0);
    }catch(e){
      const d=new Date(Date.now()+9*3600000);
      return d.getUTCHours()*60+d.getUTCMinutes();
    }
  }

  function sectionByHeading(needle){
    const hs=[...document.querySelectorAll('h1,h2,h3')];
    const h=hs.find(x=>txt(x).includes(needle));
    return h?.closest('section') || h?.parentElement?.closest('section') || h?.parentElement || null;
  }

  function applyClosePicksWindow(){
    const sec=document.querySelector('section.closepicks') || sectionByHeading('종가추천종목');
    if(!sec) return;
    const t=kstMinutes();
    const visible=(t>=19*60+30)||(t<8*60+50);
    sec.hidden=!visible;
    sec.dataset.novaUiWindow=visible?'VISIBLE':'HIDDEN_0850_1930';
  }

  function ensureOpeningTable(){
    let sec=document.getElementById('novaOpeningTruthV2');
    if(sec) return sec;
    sec=document.createElement('section');
    sec.id='novaOpeningTruthV2';
    sec.className='nova-truth-opening-v2';
    sec.innerHTML=`
      <div class="ntv2-head">
        <div>
          <div class="ntv2-kicker">OPENING SHAKEOUT · REVERSAL</div>
          <h2>개장 흔들기 · 급반전 BUY 후보 TOP10</h2>
          <p>09:00~09:30 SHAKEOUT · 09:10~10:00 REVERSAL · PRIOR_CLOSE / TODAY_NEW 경쟁. 10:00 이후에도 당일 성과확인용으로 유지합니다.</p>
        </div>
        <div class="ntv2-stats">
          <div><span>표시</span><b id="ntv2OpenCount">0</b></div>
          <div><span>BUY_READY</span><b id="ntv2OpenReady">0</b></div>
          <div><span>갱신</span><b id="ntv2OpenTime">-</b></div>
        </div>
      </div>
      <div id="ntv2OpenRows" class="ntv2-open-rows">
        <div class="ntv2-empty">개장 흔들기/급반전 데이터 대기 중입니다.</div>
      </div>`;
    const nxt=sectionByHeading('NXT 급등 조기발견 알림');
    if(nxt?.parentNode) nxt.parentNode.insertBefore(sec,nxt);
    else (document.querySelector('main')||document.body).appendChild(sec);
    return sec;
  }

  function listRows(j){
    if(Array.isArray(j?.rows)) return j.rows;
    if(j?.rows && typeof j.rows==='object') return Object.values(j.rows);
    if(Array.isArray(j?.board)){
      const by=(j.rows&&typeof j.rows==='object')?j.rows:{};
      return j.board.map(x=>typeof x==='string'?(by[x]||{code:x}):x).filter(Boolean);
    }
    return [];
  }
  const val=(r,...ks)=>{ for(const k of ks) if(r && r[k]!==undefined && r[k]!==null) return r[k]; return null; };
  function stageClass(s){
    s=String(s||'WATCH').toUpperCase();
    if(s.includes('BUY_READY'))return 'ready';
    if(s.includes('REVERSAL'))return 'reversal';
    if(s.includes('SELL_EXHAUST'))return 'exhaust';
    if(s.includes('FLUSH'))return 'flush';
    return 'watch';
  }
  function renderOpening(j){
    ensureOpeningTable();
    const rows=listRows(j).slice(0,10);
    const ready=rows.filter(r=>String(val(r,'stage','status','state')||'').toUpperCase().includes('BUY_READY')).length;
    document.getElementById('ntv2OpenCount').textContent=String(rows.length);
    document.getElementById('ntv2OpenReady').textContent=String(ready);
    document.getElementById('ntv2OpenTime').textContent=String(j?.generated_at||j?.updated_at||'-').slice(11,19)||'-';
    const box=document.getElementById('ntv2OpenRows');
    if(!rows.length){
      box.innerHTML='<div class="ntv2-empty">현재 표시할 개장 흔들기/급반전 후보가 없습니다. 조건 발생 기록은 이 영역에 유지됩니다.</div>';
      return;
    }
    box.innerHTML=rows.map((r,i)=>{
      const st=String(val(r,'stage','status','state')||'WATCH').toUpperCase();
      const origin=String(val(r,'origin','source_origin')||'TODAY_NEW').toUpperCase();
      const name=val(r,'name','stock_name')||val(r,'code','stock_code')||'-';
      const code=val(r,'code','stock_code')||'';
      const score=val(r,'reversal_score','opening_score','score');
      const drop=val(r,'max_drawdown_pct','flush_pct','drawdown_pct','drop_pct');
      const rec=val(r,'recovery_pct','low_recovery_pct','rebound_pct');
      const bp=val(r,'buy_pressure','aggressive_buy_ratio','bp');
      const a30=val(r,'accel_30s','trade_accel_30s','acceleration_30s');
      const vw=val(r,'micro_vwap_gap_pct','micro_vwap_pct','vwap_gap_pct');
      const px=val(r,'current_price','last_price','price');
      return `<div class="ntv2-open-row">
        <div class="ntv2-rank">${i+1}</div>
        <div>
          <div class="ntv2-name">${esc(name)} <span>${esc(code)}</span></div>
          <div><span class="ntv2-stage ${stageClass(st)}">${esc(st)}</span> <span class="ntv2-origin">${esc(origin)}</span></div>
        </div>
        <div class="ntv2-metric">낙폭 ${pct(drop)}<br>회복 ${pct(rec)}</div>
        <div class="ntv2-metric">공격매수 ${pct(bp)} · 30초 ${Number.isFinite(n(a30))?n(a30).toFixed(1)+'x':'-'}<br>Micro VWAP ${pct(vw)} · 현재가 ${money(px)}</div>
        <div class="ntv2-score">${Number.isFinite(n(score))?n(score).toFixed(1)+'점':'-'}</div>
      </div>`;
    }).join('');
  }
  async function loadOpening(){
    ensureOpeningTable();
    try{
      const r=await fetch('/api/opening-shakeout-reversal',{cache:'no-store'});
      if(!r.ok)throw new Error('HTTP '+r.status);
      renderOpening(await r.json());
    }catch(e){
      const b=document.getElementById('ntv2OpenRows');
      if(b)b.innerHTML='<div class="ntv2-empty">개장 흔들기 API 재연결 중입니다.</div>';
    }
  }

  const priceMap=new Map();
  function ingestObject(o,source,depth=0){
    if(!o || depth>7)return;
    if(Array.isArray(o)){ for(const x of o) ingestObject(x,source,depth+1); return; }
    if(typeof o!=='object')return;
    const code=String(o.code??o.stock_code??o.item_code??o.symbol??'').match(/\d{6}/)?.[0]||'';
    if(code){
      const candidates=[
        ['current_price',100],['live_price',100],['last_price',95],['cur_price',95],['now_price',95],
        ['price_now',95],['current',90]
      ];
      if(source!=='alerts') candidates.push(['price',70]);
      let best=null;
      for(const [k,prio] of candidates){
        const v=n(o[k]);
        if(Number.isFinite(v)&&v>0 && (!best || prio>best.prio)) best={price:v,prio};
      }
      const cr=n(o.current_change_rate??o.change_rate??o.change_pct??o.current_rate);
      if(best){
        const old=priceMap.get(code);
        if(!old || best.prio>=old.prio) priceMap.set(code,{price:best.price,change:Number.isFinite(cr)?cr:NaN,prio:best.prio,ts:Date.now()});
      }
    }
    for(const v of Object.values(o)) if(v && typeof v==='object') ingestObject(v,source,depth+1);
  }
  async function fetchJson(url,source){
    try{
      const r=await fetch(url,{cache:'no-store'});
      if(!r.ok)return;
      ingestObject(await r.json(),source,0);
    }catch(e){}
  }
  async function refreshPriceMap(){
    await Promise.all([
      fetchJson('/api/nova','nova'),
      fetchJson('/api/nxt-signal-table','signal'),
      fetchJson('/api/prebuy-recommendations','prebuy'),
      fetchJson('/api/buy-signals','buy')
    ]);
    decorateEarlyAlerts();
  }

  function alertCards(){
    const sec=sectionByHeading('NXT 급등 조기발견 알림');
    if(!sec)return [];
    const stageRe=/(EMERGENCY_IGNITION|PRE_IGNITION|BUY_READY|BUY_EARLY|IGNITION|FAST_JUMP|RECOVERY_)/;
    const all=[...sec.querySelectorAll('div,article,li')].filter(el=>{
      const s=txt(el);
      return s.length>25 && s.length<900 && stageRe.test(s) && /\d{6}/.test(s);
    });
    return all.filter(el=>![...el.children].some(ch=>{
      const s=txt(ch); return s.length>25 && s.length<900 && stageRe.test(s) && /\d{6}/.test(s);
    }));
  }
  function capturePriceFromText(s){
    const m=String(s||'').match(/[+-]?\d+(?:\.\d+)?%\s*([0-9][0-9,]{2,})/);
    return m?n(m[1]):NaN;
  }
  function decorateEarlyAlerts(){
    for(const card of alertCards()){
      const code=codeOf(txt(card));
      if(!code)continue;
      const live=priceMap.get(code);
      if(!live?.price)continue;
      let cap=n(card.dataset.novaCapturePrice);
      if(!Number.isFinite(cap)){
        cap=capturePriceFromText(txt(card));
        if(Number.isFinite(cap)) card.dataset.novaCapturePrice=String(cap);
      }
      let strip=card.querySelector(':scope > .nova-live-price-v2');
      if(!strip){
        strip=document.createElement('div');
        strip.className='nova-live-price-v2';
        card.appendChild(strip);
      }
      const perf=Number.isFinite(cap)&&cap>0?(live.price/cap-1)*100:NaN;
      strip.innerHTML=`<span>포착가 <b>${money(cap)}</b></span><span>현재가 <b>${money(live.price)}</b></span><span>포착후 <b class="${perf>=0?'up':'dn'}">${pct(perf)}</b></span><span class="nova-live-dot">LIVE</span>`;
    }
  }

  function markStaleRows(){
    const sec=sectionByHeading('NXT시장 신호관리테이블');
    if(!sec)return;
    for(const el of sec.querySelectorAll('tr,div')){
      const s=txt(el);
      if(s.length<20 || s.length>1600)continue;
      const m=s.match(/\bREST\s+(\d{4,})ms\b/i);
      if(!m)continue;
      const age=Number(m[1]);
      if(age<=60000)continue;
      if(el.querySelector(':scope > .nova-stale-v2'))continue;
      const b=document.createElement('div');
      b.className='nova-stale-v2';
      b.textContent=`STALE ${Math.round(age/1000)}초 · 기록 보존 / 신규 LIVE 근거로 오인 금지`;
      el.appendChild(b);
    }
  }

  function flagAccelerationOutliers(){
    const sec=document.querySelector('section.closepicks') || sectionByHeading('종가추천종목');
    if(!sec)return;
    for(const el of sec.querySelectorAll('div,li,tr')){
      const s=txt(el);
      if(s.length<20 || s.length>1400)continue;
      const vals=[...s.matchAll(/(\d+(?:\.\d+)?)x/g)].map(m=>Number(m[1])).filter(Number.isFinite);
      if(!vals.length || Math.max(...vals)<500)continue;
      if(el.querySelector(':scope > .nova-accel-audit-v2'))continue;
      const b=document.createElement('div');
      b.className='nova-accel-audit-v2';
      b.textContent=`⚠ BASELINE CHECK · 가속도 ${Math.max(...vals).toFixed(1)}x · 표시만 경고, 점수/순위는 변경하지 않음`;
      el.appendChild(b);
    }
  }

  function ensureStyle(){
    if(document.getElementById('novaUiTruthV2Style'))return;
    const st=document.createElement('style');
    st.id='novaUiTruthV2Style';
    st.textContent=`
      .nova-truth-opening-v2{margin:26px 0;padding:24px;border:1px solid rgba(92,207,226,.36);border-radius:19px;background:rgba(4,25,35,.64)}
      .ntv2-head{display:flex;gap:16px;justify-content:space-between;align-items:flex-start;flex-wrap:wrap}
      .ntv2-kicker{font-size:12px;letter-spacing:.17em;color:#80a8b5}.nova-truth-opening-v2 h2{margin:6px 0 8px;font-size:27px;color:#eef8fb}
      .nova-truth-opening-v2 p{margin:0;max-width:820px;line-height:1.55;color:#88a6b0}.ntv2-stats{display:flex;gap:9px;flex-wrap:wrap}
      .ntv2-stats>div{min-width:105px;padding:11px 13px;border:1px solid rgba(111,171,190,.22);border-radius:13px;background:rgba(3,17,25,.65)}
      .ntv2-stats span{display:block;font-size:11px;color:#7695a0}.ntv2-stats b{display:block;margin-top:4px;font-size:19px;color:#eef8fb}
      .ntv2-open-rows{display:grid;gap:9px;margin-top:17px}.ntv2-open-row{display:grid;grid-template-columns:42px minmax(170px,1.15fr) minmax(100px,.6fr) minmax(210px,1.2fr) 86px;gap:10px;align-items:center;padding:13px 14px;border:1px solid rgba(111,171,190,.2);border-radius:13px;background:rgba(4,18,26,.76)}
      .ntv2-rank{font-size:17px;font-weight:800;color:#dcecf1}.ntv2-name{font-size:17px;font-weight:800;color:#f1f8fa}.ntv2-name span,.ntv2-metric{font-size:11px;line-height:1.45;color:#87a2ac}
      .ntv2-stage{display:inline-block;margin-top:5px;padding:3px 7px;border-radius:999px;border:1px solid currentColor;font-size:10px;font-weight:900}.ntv2-stage.ready{color:#a7ff5e}.ntv2-stage.reversal{color:#62d9ff}.ntv2-stage.exhaust{color:#ffd36c}.ntv2-stage.flush{color:#ff8a92}.ntv2-stage.watch{color:#a8bbc2}
      .ntv2-origin{font-size:10px;color:#91aab4}.ntv2-score{text-align:right;font-size:18px;font-weight:900;color:#f0f8fa}.ntv2-empty{padding:24px;text-align:center;border:1px dashed rgba(111,171,190,.2);border-radius:13px;color:#7896a1}
      .nova-live-price-v2{display:flex;gap:12px;align-items:center;flex-wrap:wrap;margin-top:8px;padding-top:7px;border-top:1px solid rgba(107,166,185,.18);font-size:11px;color:#7897a2}
      .nova-live-price-v2 b{font-size:12px;color:#e7f3f6}.nova-live-price-v2 b.up{color:#ff818c}.nova-live-price-v2 b.dn{color:#78aef7}.nova-live-dot{margin-left:auto;color:#9cff70;font-weight:900}
      .nova-stale-v2{margin-top:5px;padding:4px 7px;border:1px solid rgba(255,176,72,.42);border-radius:8px;color:#ffc36d;background:rgba(90,48,0,.16);font-size:10px}
      .nova-accel-audit-v2{margin-top:5px;padding:4px 7px;border:1px solid rgba(255,176,72,.38);border-radius:8px;color:#ffc36d;background:rgba(90,48,0,.14);font-size:10px}
      @media(max-width:820px){.nova-truth-opening-v2{padding:16px}.nova-truth-opening-v2 h2{font-size:22px}.ntv2-open-row{grid-template-columns:34px 1fr 72px}.ntv2-metric{grid-column:2/4}.ntv2-score{grid-column:3;grid-row:1/3}}
    `;
    document.head.appendChild(st);
  }

  function maintain(){
    applyClosePicksWindow();
    ensureOpeningTable();
    decorateEarlyAlerts();
    markStaleRows();
    flagAccelerationOutliers();
  }

  function boot(){
    ensureStyle();
    maintain();
    loadOpening();
    refreshPriceMap();
    setInterval(loadOpening,20000);
    setInterval(refreshPriceMap,10000);
    setInterval(maintain,3000);
    document.addEventListener('visibilitychange',()=>{if(!document.hidden){maintain();loadOpening();refreshPriceMap();}});
  }
  if(document.readyState==='loading')document.addEventListener('DOMContentLoaded',boot,{once:true});
  else boot();
  window[V]={maintain,refreshPriceMap,loadOpening};
})();
/* NOVA_UI_TRUTH_CONSOLIDATION_V2_END */
'''
js += "\n"+addon+"\n"

if re.search(r'/static/nova\.js\?v=[^"\']+', html):
    html=re.sub(r'/static/nova\.js\?v=[^"\']+',
                '/static/nova.js?v=2.4.22-ui-truth-v2',
                html,count=1)
elif '/static/nova.js' in html:
    html=html.replace('/static/nova.js','/static/nova.js?v=2.4.22-ui-truth-v2',1)
else:
    raise SystemExit('NOVA_JS_SCRIPT_REFERENCE_NOT_FOUND')

for m in (
    'NOVA_UI_TRUTH_CONSOLIDATION_V2_START',
    'HIDDEN_0850_1930',
    '/api/opening-shakeout-reversal',
    "fetchJson('/api/nova','nova')",
    'BASELINE CHECK',
):
    if m not in js:
        raise SystemExit('PLUGIN_MARKER_MISSING:'+m)

jp.write_text(js,encoding='utf-8')
hp.write_text(html,encoding='utf-8')
print('UI_PLUGIN_BUILD=PASS')
print('BACKEND_CODE_EDIT=NONE')
print('TRADING_DATA_MUTATION=NONE')
PY

echo "=== JS SYNTAX CHECK ==="
if command -v node >/dev/null 2>&1; then
  node --check "$NEW_JS"
  echo "NODE_CHECK=PASS"
elif sudo docker exec "$APP" sh -c 'command -v node >/dev/null 2>&1'; then
  sudo docker cp "$NEW_JS" "$APP:/tmp/nova-ui-truth-v2.js"
  sudo docker exec "$APP" node --check /tmp/nova-ui-truth-v2.js
  sudo docker exec "$APP" rm -f /tmp/nova-ui-truth-v2.js
  echo "CONTAINER_NODE_CHECK=PASS"
else
  echo "NODE_CHECK=SKIP_NODE_NOT_INSTALLED"
fi

echo "=== INSTALL STATIC ONLY ==="
sudo docker cp "$NEW_JS" "$APP:/app/static/nova.js"
sudo docker cp "$NEW_HTML" "$APP:/app/static/index.html"

MAIN_AFTER="$(sudo docker exec "$APP" sha256sum /app/app/main.py | awk '{print $1}')"
echo "MAIN_PY_SHA256_AFTER=$MAIN_AFTER"
[[ "$MAIN_BEFORE" == "$MAIN_AFTER" ]] || { echo "MAIN_PY_HASH_GATE=FAIL" >&2; exit 1; }
echo "MAIN_PY_HASH_GATE=PASS"

echo "=== STATIC MARKER GATE ==="
sudo docker exec "$APP" sh -c "grep -q 'NOVA_UI_TRUTH_CONSOLIDATION_V2_START' /app/static/nova.js"
sudo docker exec "$APP" sh -c "grep -q 'ui-truth-v2' /app/static/index.html"
echo "STATIC_MARKER_GATE=PASS"

echo "=== READ-ONLY API REGRESSION ==="
for ep in /api/health /api/nova /api/nxt-signal-table /api/opening-shakeout-reversal /api/close-picks; do
  C="$(curl -sS --max-time 4 -o /dev/null -w '%{http_code}' "http://127.0.0.1:3200$ep" || true)"
  echo "$ep=$C"
  [[ "$C" == "200" ]] || { echo "API_REGRESSION_GATE=FAIL:$ep" >&2; exit 1; }
done
echo "API_REGRESSION_GATE=PASS"

echo "=== PUBLIC CHECK ==="
ROOT="$(curl -k -sS --max-time 5 -o /tmp/nova-ui-v2-root.html -w '%{http_code}' https://3-38-25-20.nip.io/ || true)"
JS="$(curl -k -sS --max-time 5 -o /tmp/nova-ui-v2-public.js -w '%{http_code}' 'https://3-38-25-20.nip.io/static/nova.js?v=2.4.22-ui-truth-v2' || true)"
echo "PUBLIC_ROOT_HTTP=$ROOT"
echo "PUBLIC_JS_HTTP=$JS"
if [[ "$JS" == "200" ]]; then
  grep -q 'NOVA_UI_TRUTH_CONSOLIDATION_V2_START' /tmp/nova-ui-v2-public.js && echo "PUBLIC_JS_MARKER=PASS" || echo "PUBLIC_JS_MARKER=STALE_CACHE"
fi

echo "=== CONTRACT ==="
echo "MORNING_SHAKEOUT_UI=09:00-09:30_SOURCE_UNCHANGED"
echo "MORNING_REVERSAL_UI=09:10-10:00_SOURCE_UNCHANGED"
echo "PRIOR_CLOSE_TODAY_NEW=DISPLAY_ONLY"
echo "OPENING_PAYLOAD_ROW_BUILDER=UNTOUCHED"
echo "REALTIME_TICK_HOOK=UNTOUCHED"
echo "RUNTIME_TASKS=UNTOUCHED"
echo "OPENING_API=READ_ONLY"
echo "CLOSEPICKS_UI_AFTER_08:50=HIDDEN"
echo "CLOSEPICKS_INTERNAL_STATE=PRESERVED"
echo "EARLY_ALERT_CAPTURE_PRICE=PRESERVED"
echo "EARLY_ALERT_CURRENT_PRICE=DISPLAY_OVERLAY"
echo "STALE_REST=DISPLAY_WARNING_ONLY"
echo "ACCEL_OUTLIER=DISPLAY_WARNING_ONLY_NO_CAP"
echo "SECTOR_RS=NO_LOGIC_CHANGE_DIAGNOSTIC_ONLY"
echo "BACKEND_MAIN_PY=BYTE_IDENTICAL"
echo "SELECTION_LOGIC=UNCHANGED"
echo "BUY_THRESHOLDS=UNCHANGED"
echo "SCORING_FORMULA=UNCHANGED"
echo "CANDIDATE_SELECTION=UNCHANGED"
echo "PREMARKET_RERANK_LOGIC=UNCHANGED"
echo "WS_CONTRACT=UNCHANGED"

SUCCESS=1
trap - ERR INT TERM
echo "=== $REV PASS ==="
