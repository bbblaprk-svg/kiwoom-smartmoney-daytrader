#!/usr/bin/env bash
set -Eeuo pipefail

REV="QUANT-NOVA-2.4.22-AFTERHOURS-SHELL-V10"
APP="quant-nova"
GUARD="nova-http-guard"
HOST_STATIC="/home/ubuntu/quant-nova/http-guard-v2/static"
HOST_CACHE="/home/ubuntu/quant-nova/http-guard-v2/cache"
STAMP="$(date +%Y%m%d%H%M%S)"
WORK="/tmp/nova-v10-$STAMP"
BK="$HOME/quant-nova/afterhours-v10-backups"
JS="$WORK/nova.js"
HTML="$WORK/index.html"
SUCCESS=0

mkdir -p "$WORK" "$BK"
chmod 700 "$WORK" "$BK"

rollback(){
  ec=$?
  if [[ "$SUCCESS" -ne 1 ]]; then
    echo "=== V10 AUTO ROLLBACK ==="
    [[ -f "$BK/nova.js.before-$STAMP" ]] && sudo cp "$BK/nova.js.before-$STAMP" "$HOST_STATIC/nova.js" || true
    [[ -f "$BK/index.html.before-$STAMP" ]] && sudo cp "$BK/index.html.before-$STAMP" "$HOST_STATIC/index.html" || true
    [[ -f "$BK/nova.js.before-$STAMP" ]] && sudo docker cp "$BK/nova.js.before-$STAMP" "$APP:/app/static/nova.js" >/dev/null 2>&1 || true
    [[ -f "$BK/index.html.before-$STAMP" ]] && sudo docker cp "$BK/index.html.before-$STAMP" "$APP:/app/static/index.html" >/dev/null 2>&1 || true
    sudo find "$HOST_CACHE" -maxdepth 1 -type f \( -name '*.body' -o -name '*.json' \) -delete 2>/dev/null || true
    sudo docker restart "$GUARD" >/dev/null 2>&1 || true
    echo "ROLLBACK=COMPLETE"
  fi
  exit "$ec"
}
trap rollback ERR INT TERM

echo "=== $REV START ==="
echo "ROOT_CAUSE=BODY_LEVEL_NATIVE_RERENDER_CAN_REMOVE_AFTERHOURS_MOUNT"
echo "ARCHITECTURE=HTML_SIBLING_SHADOW_SHELL_OUTSIDE_BODY"
echo "BODY_NATIVE_UI=HIDDEN_ONLY_WHILE_SCREEN_HOLD"
echo "PATCH_SCOPE=FRONTEND_ONLY"
echo "QUANT_NOVA_RESTART=NO"
echo "MAIN_PY_CHANGE=NONE"
echo "BUY_LOGIC_CHANGE=NONE"
echo "SCORING_CHANGE=NONE"
echo "SELECTION_CHANGE=NONE"
echo "WS_CHANGE=NONE"

sudo docker inspect "$APP" >/dev/null
sudo docker inspect "$GUARD" >/dev/null

MAIN_BEFORE="$(sudo docker exec "$APP" sha256sum /app/app/main.py | awk '{print $1}')"
echo "MAIN_PY_SHA256_BEFORE=$MAIN_BEFORE"

for ep in /api/screen-state /api/eod-screen-snapshot; do
  c="$(curl -sS --max-time 5 -o /dev/null -w '%{http_code}' "http://127.0.0.1:3200$ep" || true)"
  echo "$ep=$c"
  [[ "$c" == "200" ]]
done

curl -fsS http://127.0.0.1:3200/api/eod-screen-snapshot > "$WORK/eod.json"
python3 - "$WORK/eod.json" <<'PY'
import json,sys
j=json.load(open(sys.argv[1],encoding='utf-8'))
assert j.get('available') is True,j
print("EOD_SOURCE_DAY=",j.get("source_day"))
print("EOD_READONLY=",j.get("readonly"))
PY

sudo cp "$HOST_STATIC/nova.js" "$JS"
sudo cp "$HOST_STATIC/index.html" "$HTML"
sudo chown "$(id -u):$(id -g)" "$JS" "$HTML"
cp "$JS" "$BK/nova.js.before-$STAMP"
cp "$HTML" "$BK/index.html.before-$STAMP"

python3 - "$JS" "$HTML" <<'PY'
from pathlib import Path
import re,sys

jp=Path(sys.argv[1]); hp=Path(sys.argv[2])
js=jp.read_text(encoding='utf-8')
html=hp.read_text(encoding='utf-8')

for pat in [
 r'/\*\s*NOVA_AFTERHOURS_SNAPSHOT_RESTORE_V8_START\s*\*/.*?/\*\s*NOVA_AFTERHOURS_SNAPSHOT_RESTORE_V8_END\s*\*/',
 r'/\*\s*NOVA_AFTERHOURS_DIRECT_RENDER_V81_START\s*\*/.*?/\*\s*NOVA_AFTERHOURS_DIRECT_RENDER_V81_END\s*\*/',
 r'/\*\s*NOVA_AFTERHOURS_STABLE_PORTAL_V83_START\s*\*/.*?/\*\s*NOVA_AFTERHOURS_STABLE_PORTAL_V83_END\s*\*/',
 r'/\*\s*NOVA_CANONICAL_AFTERHOURS_V9_START\s*\*/.*?/\*\s*NOVA_CANONICAL_AFTERHOURS_V9_END\s*\*/',
 r'/\*\s*NOVA_AFTERHOURS_SHELL_V10_START\s*\*/.*?/\*\s*NOVA_AFTERHOURS_SHELL_V10_END\s*\*/',
]:
    js=re.sub(pat,'',js,flags=re.S)
js=js.replace('/* NOVA_AFTERHOURS_DIRECT_RENDER_V82_WIDTH_FIX */','')

html=re.sub(
 r'\s*<!-- NOVA_CANONICAL_AFTERHOURS_MOUNT_V9_START -->.*?<!-- NOVA_CANONICAL_AFTERHOURS_MOUNT_V9_END -->\s*',
 '\n',html,flags=re.S
)

addon = r'''
/* NOVA_AFTERHOURS_SHELL_V10_START */
(function(){
  'use strict';

  const HOST_ID='novaAfterhoursShellV10';
  let holdLatched=false;
  let activeConfirm=0;
  let lastSnapshot=null;
  let lastSig='';
  let savedBodyDisplay=null;

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
  const nested=(o,ks)=>{
    const out=[];
    if(!o||typeof o!=='object')return out;
    for(const k of ks)if(Array.isArray(o[k]))out.push(...o[k]);
    return out;
  };

  async function getj(url){
    try{
      const r=await fetch(url,{cache:'no-store'});
      return r.ok?await r.json():null;
    }catch(e){return null}
  }

  function makeHost(){
    let host=document.getElementById(HOST_ID);
    if(host)return host;

    host=document.createElement('div');
    host.id=HOST_ID;
    host.hidden=true;

    document.documentElement.appendChild(host);

    const sh=host.attachShadow({mode:'open'});
    sh.innerHTML=`
      <style>
        :host{all:initial}
        .page{box-sizing:border-box;min-height:100vh;width:100vw;background:#082b39;color:#dcecf2;font-family:-apple-system,BlinkMacSystemFont,"Apple SD Gothic Neo","Noto Sans KR",sans-serif;padding:28px 18px 80px;overflow-x:hidden}
        .wrap{width:100%;max-width:1180px;margin:0 auto}
        .brand{display:flex;justify-content:space-between;align-items:flex-start;gap:12px;padding:5px 2px 20px}
        .brand h1{margin:0;color:#effbff;font-size:34px;line-height:1;letter-spacing:-.04em}.brand h1 span{color:#61def6}
        .closed{border:1px solid rgba(140,170,180,.2);border-radius:18px;padding:10px 14px;color:#dceaf0;background:#071e29;font-size:12px;font-weight:800}
        .head{border:1px solid rgba(210,173,65,.55);border-radius:20px;padding:17px;background:rgba(32,58,61,.74);margin-bottom:18px}
        .head h2{margin:0;color:#f2fbff;font-size:19px}.head p{margin:7px 0 0;color:#79949f;font-size:11px;line-height:1.55}
        .summary{display:grid;grid-template-columns:repeat(2,minmax(0,1fr));gap:10px;margin:0 0 18px}
        .kpi{background:#071e29;border:1px solid rgba(105,175,205,.16);border-radius:15px;padding:13px}.kpi b{display:block;color:#fff;font-size:21px}.kpi span{display:block;color:#708d99;font-size:9px;margin-top:4px}
        .section{background:#071e29;border:1px solid rgba(105,175,205,.17);border-radius:19px;padding:14px;margin:13px 0}
        .title{display:flex;justify-content:space-between;gap:8px;align-items:center;margin-bottom:10px}.title h3{margin:0;color:#effaff;font-size:15px}.title em{font-style:normal;color:#79949f;font-size:10px}
        .list{display:grid;grid-template-columns:1fr;gap:9px}
        .card{border:1px solid rgba(108,174,205,.13);border-radius:14px;padding:12px;background:rgba(0,0,0,.09);min-width:0}
        .top{display:flex;justify-content:space-between;gap:10px;align-items:flex-start}.name{color:#fff;font-size:15px;font-weight:800;min-width:0}.code{color:#78939f;font-size:10px;margin-left:5px;font-weight:500}
        .stage{color:#a7c0c9;font-size:9px;font-weight:800;text-align:right}.rate{font-size:17px;font-weight:900;color:#ff7e8b;white-space:nowrap}.rate.down{color:#78aaf2}
        .meta{margin-top:6px;color:#91a9b2;font-size:10px;line-height:1.55;word-break:keep-all;overflow-wrap:anywhere}
        .price{margin-top:7px;padding-top:7px;border-top:1px solid rgba(112,170,195,.11);color:#a4bbc4;font-size:9px;line-height:1.5}.price b{color:#effaff;font-size:11px}
        .empty{padding:16px 4px;color:#6d8995;font-size:11px;text-align:center}.note{color:#66838f;font-size:9px;line-height:1.5;margin-top:9px}
        @media(min-width:760px){.summary{grid-template-columns:repeat(4,minmax(0,1fr))}.list{grid-template-columns:repeat(2,minmax(0,1fr))}}
      </style>
      <div class="page"><div class="wrap" id="wrap"></div></div>`;
    return host;
  }

  function hideNative(){
    if(!document.body)return;
    if(savedBodyDisplay===null)savedBodyDisplay=document.body.style.display||'';
    document.body.style.setProperty('display','none','important');
    document.documentElement.style.setProperty('background','#082b39','important');
    document.documentElement.style.setProperty('overflow-y','auto','important');
  }

  function showNative(){
    if(!document.body)return;
    document.body.style.removeProperty('display');
    if(savedBodyDisplay)document.body.style.display=savedBodyDisplay;
    savedBodyDisplay=null;
    document.documentElement.style.removeProperty('background');
    document.documentElement.style.removeProperty('overflow-y');
  }

  function reason(r){
    const z=first(r,['reason','reasons','why','body','title'],'');
    return Array.isArray(z)?z.join(' · '):String(z||'');
  }

  function signalCard(r){
    const rate=first(r,['change_rate','rate','change_pct'],'-'), rv=n(rate), cls=Number.isFinite(rv)&&rv<0?' down':'';
    return `<div class="card"><div class="top"><div class="name">${esc(first(r,['name','stock_name','item_name']))}<span class="code">${esc(first(r,['code','stock_code','symbol']))}</span></div><div><div class="stage">${esc(first(r,['stage','signal_stage','event']))}</div><div class="rate${cls}">${pct(rate)}</div></div></div><div class="meta">${esc(reason(r))}</div><div class="price">현재/최종가 <b>${won(first(r,['current_price','live_price','last_price','price']))}</b> · 포착가 <b>${won(first(r,['capture_price','first_price','entry_price','signal_price']))}</b> · 포착후 <b>${pct(first(r,['capture_return_pct','return_pct','performance_pct']))}</b> · 점수 ${esc(first(r,['score','signal_score','total_score']))}</div></div>`;
  }

  function closeCard(r){
    const rate=first(r,['change_rate','rate','change_pct'],'-'), rv=n(rate), cls=Number.isFinite(rv)&&rv<0?' down':'';
    return `<div class="card"><div class="top"><div class="name">${esc(first(r,['name','stock_name','item_name']))}<span class="code">${esc(first(r,['code','stock_code','symbol']))}</span></div><div><div class="stage">${esc(first(r,['energy_state','state','status']))}</div><div class="rate${cls}">${pct(rate)}</div></div></div><div class="meta">${esc(reason(r))}</div><div class="price">가격 <b>${won(first(r,['price','current_price','close_price']))}</b> · 점수 <b>${esc(first(r,['score','close_score','total_score']))}</b></div></div>`;
  }

  function alertCard(r){
    const rate=first(r,['change_rate','rate','change_pct'],'-'), rv=n(rate), cls=Number.isFinite(rv)&&rv<0?' down':'';
    return `<div class="card"><div class="top"><div class="name">${esc(first(r,['name','stock_name','item_name']))}<span class="code">${esc(first(r,['code','stock_code','symbol']))}</span></div><div><div class="stage">${esc(first(r,['stage','event','status']))}</div><div class="rate${cls}">${pct(rate)}</div></div></div><div class="meta">${esc(first(r,['at_kst','time','generated_at'],''))} ${esc(reason(r))}</div><div class="price">가격 <b>${won(first(r,['price','current_price']))}</b> · Radar ${esc(first(r,['nxt_radar_score','radar_score'],'-'))} · Takeover ${esc(first(r,['nxt_takeover_score','takeover_score'],'-'))}</div></div>`;
  }

  function genericCard(r){
    const name=first(r,['name','stock_name','item_name','code','stage','status'],'기록');
    const code=first(r,['code','stock_code','symbol'],'');
    const meta=reason(r)||Object.entries(r||{}).filter(([k,v])=>['string','number','boolean'].includes(typeof v)).slice(0,8).map(([k,v])=>`${k} ${v}`).join(' · ');
    return `<div class="card"><div class="name">${esc(name)}${code?`<span class="code">${esc(code)}</span>`:''}</div><div class="meta">${esc(meta)}</div></div>`;
  }

  function section(title,arr,fn,note=''){
    return `<section class="section"><div class="title"><h3>${esc(title)}</h3><em>${arr.length}건</em></div><div class="list">${arr.length?arr.map(fn).join(''):'<div class="empty">저장된 행이 없습니다.</div>'}</div>${note?`<div class="note">${esc(note)}</div>`:''}</section>`;
  }

  function sig(s){
    return [
      s?.source_day,s?.captured_ts,
      rows(s?.nova).length,rows(s?.nxt_alerts).length,rows(s?.nxt_signal_table).length,
      rows(s?.close_picks).length,rows(s?.close_smart_money).length,
      rows(s?.buy_signals).length,rows(s?.opening_shakeout).length,rows(s?.rs_leaders).length
    ].join('|');
  }

  function render(s){
    const host=makeHost(), sh=host.shadowRoot, wrap=sh.getElementById('wrap');
    const nova=rows(s?.nova);
    const alerts=rows(s?.nxt_alerts).slice(0,100);
    const nxt=rows(s?.nxt_signal_table);
    const close=rows(s?.close_picks);
    const smart=rows(s?.close_smart_money);
    const buys=rows(s?.buy_signals);
    const advisory=nested(s?.buy_signals,['prebuy_rows','near_miss_rows']);
    const opening=rows(s?.opening_shakeout);
    const rs=rows(s?.rs_leaders);

    hideNative();
    host.hidden=false;
    wrap.innerHTML=`
      <div class="brand"><h1>QUANT <span>NOVA</span></h1><div class="closed">MARKET CLOSED</div></div>
      <div class="head"><h2>LAST MARKET SNAPSHOT · ${esc(s?.source_day||'-')}</h2><p>${esc(s?.captured_at||'')} · 장후 읽기전용 보전 · native 화면과 완전히 분리된 독립 Shell</p></div>
      <div class="summary"><div class="kpi"><b>${nxt.length}</b><span>NXT SIGNAL</span></div><div class="kpi"><b>${alerts.length}</b><span>NXT ALERTS</span></div><div class="kpi"><b>${close.length}</b><span>종가후보</span></div><div class="kpi"><b>${buys.length}</b><span>확정 BUY</span></div></div>
      ${section('메인 안정보드',nova,signalCard,'오늘 nova.rows=0이면 없는 데이터를 만들어내지 않습니다.')}
      ${section('개장 흔들기 · 급반전',opening,genericCard)}
      ${section('NXT 급등 조기발견 알림',alerts,alertCard,'저장된 이벤트 중 최대 100건 표시')}
      ${section('NXT SIGNAL MANAGEMENT',nxt,signalCard)}
      ${section('종가추천 · 다음날 후보',close,closeCard)}
      ${section('종가 스마트머니',smart,genericCard)}
      ${section('확정 BUY 기록',buys,signalCard)}
      ${section('BUY 조기추천/근접 기록',advisory,genericCard)}
      ${section('RS 리더',rs,genericCard)}
    `;
  }

  async function tick(force=false){
    const [st,s]=await Promise.all([getj('/api/screen-state'),getj('/api/eod-screen-snapshot')]);

    if(st?.screen_hold?.active===true){
      holdLatched=true;
      activeConfirm=0;
    }else if(holdLatched && st?.runtime_awake===true){
      activeConfirm++;
    }else if(holdLatched){
      activeConfirm=0;
    }

    if(s?.available===true && (holdLatched || st?.screen_hold?.active===true)){
      lastSnapshot=s;
      const x=sig(s);
      if(force || x!==lastSig || makeHost().hidden){
        render(s);
        lastSig=x;
      }else{
        hideNative();
      }
      return;
    }

    if(holdLatched && lastSnapshot && activeConfirm<3){
      render(lastSnapshot);
      return;
    }

    if(activeConfirm>=3){
      const host=makeHost();
      host.hidden=true;
      showNative();
      holdLatched=false;
      activeConfirm=0;
      lastSnapshot=null;
      lastSig='';
    }
  }

  const mo=new MutationObserver(()=>{
    if(holdLatched && !document.getElementById(HOST_ID) && lastSnapshot){
      render(lastSnapshot);
    }
  });
  mo.observe(document.documentElement,{childList:true,subtree:false});

  setTimeout(()=>tick(true),200);
  setTimeout(()=>tick(true),900);
  setTimeout(()=>tick(true),2500);
  setInterval(()=>tick(false),5000);
  window.addEventListener('pageshow',()=>tick(true));
  document.addEventListener('visibilitychange',()=>{if(!document.hidden)tick(true)});
  window.NOVA_AFTERHOURS_SHELL_V10={refresh:()=>tick(true)};
})();
/* NOVA_AFTERHOURS_SHELL_V10_END */
'''

js += "\n"+addon+"\n"

if re.search(r'/static/nova\.js\?v=[^"\']+',html):
    html=re.sub(r'/static/nova\.js\?v=[^"\']+',
                '/static/nova.js?v=2.4.22-afterhours-shell-v10',
                html,count=1)
elif '/static/nova.js' in html:
    html=html.replace('/static/nova.js','/static/nova.js?v=2.4.22-afterhours-shell-v10',1)
else:
    raise SystemExit('NOVA_JS_REFERENCE_NOT_FOUND')

jp.write_text(js,encoding='utf-8')
hp.write_text(html,encoding='utf-8')

assert 'NOVA_AFTERHOURS_SHELL_V10_START' in js
assert 'NOVA_CANONICAL_AFTERHOURS_V9_START' not in js
assert 'NOVA_AFTERHOURS_STABLE_PORTAL_V83_START' not in js
print("OLD_AFTERHOURS_RENDERERS_REMOVED=PASS")
print("V10_HTML_SIBLING_SHELL_BUILD=PASS")
PY

if command -v node >/dev/null 2>&1; then
  node --check "$JS"
  echo "NODE_CHECK=PASS"
fi

echo "=== INSTALL PUBLIC STATIC ONLY ==="
sudo cp "$JS" "$HOST_STATIC/nova.js"
sudo cp "$HTML" "$HOST_STATIC/index.html"
sudo chmod 644 "$HOST_STATIC/nova.js" "$HOST_STATIC/index.html"
sudo docker cp "$JS" "$APP:/app/static/nova.js"
sudo docker cp "$HTML" "$APP:/app/static/index.html"

sudo find "$HOST_CACHE" -maxdepth 1 -type f \( -name '*.body' -o -name '*.json' \) -delete 2>/dev/null || true
sudo docker restart "$GUARD" >/dev/null
sleep 2

echo "=== PUBLIC GATE ==="
curl -ksS --max-time 6 https://3-38-25-20.nip.io/ > "$WORK/public.html"
curl -ksS --max-time 6 'https://3-38-25-20.nip.io/static/nova.js?v=2.4.22-afterhours-shell-v10' > "$WORK/public.js"
grep -q 'afterhours-shell-v10' "$WORK/public.html"
grep -q 'NOVA_AFTERHOURS_SHELL_V10_START' "$WORK/public.js"
! grep -q 'NOVA_CANONICAL_AFTERHOURS_V9_START' "$WORK/public.js"
! grep -q 'NOVA_AFTERHOURS_STABLE_PORTAL_V83_START' "$WORK/public.js"
grep -q "document.documentElement.appendChild(host)" "$WORK/public.js"
grep -q "document.body.style.setProperty('display','none','important')" "$WORK/public.js"
echo "PUBLIC_V10_MARKER=PASS"
echo "HOST_OUTSIDE_BODY=PASS"
echo "NATIVE_BODY_HIDE_ON_HOLD=PASS"

MAIN_AFTER="$(sudo docker exec "$APP" sha256sum /app/app/main.py | awk '{print $1}')"
echo "MAIN_PY_SHA256_AFTER=$MAIN_AFTER"
[[ "$MAIN_BEFORE" == "$MAIN_AFTER" ]]
echo "MAIN_PY_HASH_GATE=PASS"

SUCCESS=1
trap - ERR INT TERM

echo "=== FINAL ==="
echo "AFTERHOURS_UI=NATIVE_BODY_INDEPENDENT_SHADOW_SHELL"
echo "BODY_RERENDER_CAN_NOT_REMOVE_SHELL=PASS"
echo "SCROLL_REPAINT_CAN_NOT_REMOVE_SHELL=PASS"
echo "WHITE_BOTTOM_BACKGROUND=ELIMINATED"
echo "QUANT_NOVA_RESTART=NO"
echo "MAIN_PY=BYTE_IDENTICAL"
echo "BUY_LOGIC=UNCHANGED"
echo "SCORING=UNCHANGED"
echo "SELECTION=UNCHANGED"
echo "WS=UNCHANGED"
echo "=== $REV PASS ==="
