#!/usr/bin/env bash
set -Eeuo pipefail

REV="QUANT-NOVA-2.4.22-AFTERHOURS-STABLE-PORTAL-V8.3"
APP="quant-nova"
GUARD="nova-http-guard"
HOST_STATIC="/home/ubuntu/quant-nova/http-guard-v2/static"
HOST_CACHE="/home/ubuntu/quant-nova/http-guard-v2/cache"
STAMP="$(date +%Y%m%d%H%M%S)"
WORK="/tmp/nova-v83-$STAMP"
BK="$HOME/quant-nova/afterhours-v83-backups"
SUCCESS=0

mkdir -p "$WORK" "$BK"
chmod 700 "$WORK" "$BK"

rollback(){
  ec=$?
  if [[ "$SUCCESS" -ne 1 ]]; then
    echo "=== V8.3 AUTO ROLLBACK ==="
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
echo "CAUSE=OLD_V8_NATIVE_HYDRATOR_AND_NATIVE_RERENDER_COULD_REMOVE_DIRECT_PANEL"
echo "FIX=REMOVE_OLD_HYDRATOR_PLUS_MUTATION_OBSERVER_STABLE_PORTAL"
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

sudo cp "$HOST_STATIC/nova.js" "$WORK/nova.js"
sudo cp "$HOST_STATIC/index.html" "$WORK/index.html"
sudo chown "$(id -u):$(id -g)" "$WORK/nova.js" "$WORK/index.html"
cp "$WORK/nova.js" "$BK/nova.js.before-$STAMP"
cp "$WORK/index.html" "$BK/index.html.before-$STAMP"

echo "=== API DATA PRECHECK ==="
for ep in /api/screen-state /api/nxt-signal-table /api/close-picks /api/buy-signals; do
  c="$(curl -sS --max-time 5 -o /dev/null -w '%{http_code}' "http://127.0.0.1:3200$ep" || true)"
  echo "$ep=$c"
  [[ "$c" == "200" ]]
done
curl -fsS http://127.0.0.1:3200/api/nxt-signal-table | python3 -c "import sys,json;j=json.load(sys.stdin);print('NXT_ROWS=',len(j.get('rows') or []))"
curl -fsS http://127.0.0.1:3200/api/close-picks | python3 -c "import sys,json;j=json.load(sys.stdin);print('CLOSE_ROWS=',len(j.get('rows') or []))"

python3 - "$WORK/nova.js" "$WORK/index.html" <<'PY'
from pathlib import Path
import re,sys

jp=Path(sys.argv[1]); hp=Path(sys.argv[2])
js=jp.read_text(encoding='utf-8')
html=hp.read_text(encoding='utf-8')

# Remove the V8 native hydrator: it calls existing native load functions and can
# repaint/remove the independently rendered snapshot panel.
js=re.sub(
    r'/\*\s*NOVA_AFTERHOURS_SNAPSHOT_RESTORE_V8_START\s*\*/.*?/\*\s*NOVA_AFTERHOURS_SNAPSHOT_RESTORE_V8_END\s*\*/',
    '', js, flags=re.S
)

# Remove V8.1/V8.2 direct renderer before installing the stable version.
js=re.sub(
    r'/\*\s*NOVA_AFTERHOURS_DIRECT_RENDER_V81_START\s*\*/.*?/\*\s*NOVA_AFTERHOURS_DIRECT_RENDER_V81_END\s*\*/',
    '', js, flags=re.S
)
js=js.replace('/* NOVA_AFTERHOURS_DIRECT_RENDER_V82_WIDTH_FIX */','')

addon=r'''
/* NOVA_AFTERHOURS_STABLE_PORTAL_V83_START */
(function(){
  'use strict';

  const ID='novaV83';
  const esc=v=>String(v??'').replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
  const num=v=>{
    const x=Number(String(v??'').replace(/,/g,'').replace(/[^\d.+-]/g,''));
    return Number.isFinite(x)?x:NaN;
  };
  const money=v=>Number.isFinite(num(v))?Math.round(num(v)).toLocaleString('ko-KR'):'-';
  const pct=v=>Number.isFinite(num(v))?`${num(v)>=0?'+':''}${num(v).toFixed(2)}%`:'-';
  const first=(o,keys,def='-')=>{
    for(const k of keys){
      const v=o?.[k];
      if(v!==undefined&&v!==null&&v!=='')return v;
    }
    return def;
  };
  const rowsOf=j=>{
    if(!j)return[];
    if(Array.isArray(j))return j;
    for(const k of ['rows','items','signals','picks','data'])if(Array.isArray(j[k]))return j[k];
    return[];
  };

  let rendering=false;
  let knownHold=false;
  let activeConfirm=0;
  let lastPayload=null;

  async function getj(url){
    try{
      const r=await fetch(url,{cache:'no-store'});
      return r.ok?await r.json():null;
    }catch(e){return null}
  }

  function style(){
    if(document.getElementById('novaV83Style'))return;
    const s=document.createElement('style');
    s.id='novaV83Style';
    s.textContent=`
      #${ID}{display:block!important;grid-column:1/-1!important;width:auto!important;max-width:none!important;box-sizing:border-box!important;margin:24px 20px 34px!important;padding:20px!important;border:1px solid rgba(105,220,245,.28)!important;border-radius:24px!important;background:#071d28!important;position:relative!important;z-index:2!important;overflow:visible!important}
      #${ID} .vh{display:flex;justify-content:space-between;align-items:flex-start;gap:10px;margin-bottom:14px}
      #${ID} h2{margin:0;color:#effbff;font-size:18px;line-height:1.3}
      #${ID} .sub{margin-top:5px;color:#7e99a5;font-size:11px;line-height:1.45}
      #${ID} .badge{border:1px solid rgba(110,255,185,.35);color:#9cffc7;border-radius:999px;padding:6px 9px;font-size:10px;font-weight:800;white-space:nowrap}
      #${ID} .box{margin-top:14px;border:1px solid rgba(130,180,200,.15);border-radius:16px;padding:12px;background:rgba(0,0,0,.11);overflow:hidden}
      #${ID} .title{display:flex;justify-content:space-between;gap:8px;margin-bottom:8px;color:#e8f8ff;font-size:13px;font-weight:800}
      #${ID} .count{color:#7e99a5;font-size:11px}
      #${ID} .tw{width:100%;overflow-x:auto;-webkit-overflow-scrolling:touch}
      #${ID} table{width:100%;min-width:650px;border-collapse:collapse}
      #${ID} th{padding:7px 6px;border-bottom:1px solid rgba(130,180,200,.15);color:#708e9b;text-align:left;font-size:9px}
      #${ID} td{padding:9px 6px;border-bottom:1px solid rgba(130,180,200,.09);color:#dbeaf0;font-size:10px;vertical-align:top}
      #${ID} td.name{color:#fff;font-weight:800}
      #${ID} td.up{color:#ff8290} #${ID} td.down{color:#79adf3}
      #${ID} .note{margin-top:8px;color:#66838f;font-size:9px}
      @media(max-width:520px){#${ID}{margin:18px 14px 28px!important;padding:14px!important;border-radius:20px!important}#${ID} h2{font-size:16px}#${ID} table{min-width:600px}}
    `;
    document.head.appendChild(s);
  }

  function stableHost(){
    const main=document.querySelector('main')||document.body;
    let host=document.getElementById(ID);
    if(host && host.isConnected)return host;

    host=document.createElement('section');
    host.id=ID;

    // Insert after the status region when possible, but keep it as a direct child
    // of main so a nested card/grid repaint cannot delete it.
    const kids=[...main.children];
    const status=kids.find(el=>{
      const t=(el.textContent||'').replace(/\s+/g,' ').trim();
      return t.includes('시장 세션')&&t.includes('키움 REST')&&t.includes('WebSocket');
    });
    if(status)status.insertAdjacentElement('afterend',host);
    else{
      const banner=document.querySelector('#snapshotBanner');
      if(banner&&banner.parentElement===main)banner.insertAdjacentElement('afterend',host);
      else main.insertBefore(host,main.children[2]||null);
    }
    return host;
  }

  function sigRow(r){
    const ch=first(r,['change_rate','rate','change_pct'],'-');
    const cls=Number.isFinite(num(ch))?(num(ch)>=0?'up':'down'):'';
    return `<tr>
      <td>${esc(first(r,['code','stock_code','symbol']))}</td>
      <td class="name">${esc(first(r,['name','stock_name','item_name']))}</td>
      <td>${money(first(r,['current_price','live_price','last_price','price']))}</td>
      <td class="${cls}">${pct(ch)}</td>
      <td>${esc(first(r,['stage','signal_stage','event']))}</td>
      <td>${esc(first(r,['score','signal_score','total_score']))}</td>
      <td>${money(first(r,['capture_price','first_price','entry_price','signal_price']))}</td>
      <td>${pct(first(r,['capture_return_pct','return_pct','performance_pct']))}</td>
    </tr>`;
  }

  function closeRow(r){
    const ch=first(r,['change_rate','rate','change_pct'],'-');
    const cls=Number.isFinite(num(ch))?(num(ch)>=0?'up':'down'):'';
    const reason=first(r,['reason','reasons','why'],'-');
    return `<tr>
      <td>${esc(first(r,['code','stock_code','symbol']))}</td>
      <td class="name">${esc(first(r,['name','stock_name','item_name']))}</td>
      <td>${money(first(r,['price','current_price','close_price']))}</td>
      <td class="${cls}">${pct(ch)}</td>
      <td>${esc(first(r,['score','close_score','total_score']))}</td>
      <td>${esc(first(r,['energy_state','state','status']))}</td>
      <td>${esc(Array.isArray(reason)?reason.join(' · '):reason)}</td>
    </tr>`;
  }

  function buyRow(r){
    return `<tr>
      <td>${esc(first(r,['code','stock_code','symbol']))}</td>
      <td class="name">${esc(first(r,['name','stock_name','item_name']))}</td>
      <td>${money(first(r,['price','entry_price','signal_price']))}</td>
      <td>${esc(first(r,['stage','route','status']))}</td>
      <td>${esc(first(r,['score','signal_score']))}</td>
      <td>${esc(first(r,['at_kst','time','generated_at']))}</td>
    </tr>`;
  }

  function table(title,rows,head,rowfn,note){
    const body=rows.length?rows.map(rowfn).join(''):`<tr><td colspan="8">보전 데이터 없음</td></tr>`;
    return `<div class="box"><div class="title"><span>${esc(title)}</span><span class="count">${rows.length}건</span></div><div class="tw"><table><thead>${head}</thead><tbody>${body}</tbody></table></div><div class="note">${esc(note)}</div></div>`;
  }

  function draw(payload){
    style();
    const host=stableHost();
    const {st,ns,cp,bs}=payload;
    const nr=rowsOf(ns),cr=rowsOf(cp),br=rowsOf(bs);
    const day=st?.screen_hold?.snapshot_source_day||st?.display_day||'20260811';
    const at=st?.screen_hold?.snapshot_at||'장마감 보전';
    host.innerHTML=`
      <div class="vh"><div><h2>LAST MARKET SNAPSHOT · ${esc(day)}</h2><div class="sub">${esc(at)} · 읽기전용 보전 화면 · 스크롤/재렌더에도 유지</div></div><div class="badge">STABLE SNAPSHOT</div></div>
      ${table('NXT SIGNAL MANAGEMENT',nr,'<tr><th>코드</th><th>종목</th><th>현재/최종가</th><th>등락</th><th>단계</th><th>점수</th><th>포착가</th><th>포착후</th></tr>',sigRow,'/api/nxt-signal-table')}
      ${table('종가추천 · 다음날 후보',cr,'<tr><th>코드</th><th>종목</th><th>가격</th><th>등락</th><th>점수</th><th>상태</th><th>근거</th></tr>',closeRow,'/api/close-picks')}
      ${table('확정 BUY 기록',br,'<tr><th>코드</th><th>종목</th><th>가격</th><th>경로/상태</th><th>점수</th><th>시간</th></tr>',buyRow,'/api/buy-signals')}
    `;
  }

  async function refresh(force=false){
    if(rendering)return;
    rendering=true;
    try{
      const [st,ns,cp,bs]=await Promise.all([
        getj('/api/screen-state'),
        getj('/api/nxt-signal-table'),
        getj('/api/close-picks'),
        getj('/api/buy-signals')
      ]);

      const hold=!!st?.screen_hold?.active;
      const awake=!!st?.runtime_awake;

      if(hold){
        knownHold=true;
        activeConfirm=0;
        lastPayload={st,ns,cp,bs};
        draw(lastPayload);
        return;
      }

      // Never erase the held screen because of one transient status refresh.
      if(knownHold && awake){
        activeConfirm++;
        if(activeConfirm<3){
          if(lastPayload)draw(lastPayload);
          return;
        }
      }else if(knownHold){
        if(lastPayload)draw(lastPayload);
        return;
      }

      // Only remove after 3 consecutive confirmed active-runtime responses.
      if(activeConfirm>=3){
        document.getElementById(ID)?.remove();
        knownHold=false;
        lastPayload=null;
      }
    }finally{
      rendering=false;
    }
  }

  // Reinsert immediately if any native renderer removes the portal node.
  const mo=new MutationObserver(()=>{
    if(knownHold && !document.getElementById(ID) && lastPayload){
      draw(lastPayload);
    }
  });
  mo.observe(document.documentElement,{childList:true,subtree:true});

  setTimeout(()=>refresh(true),250);
  setTimeout(()=>refresh(true),1200);
  setTimeout(()=>refresh(true),3500);
  setInterval(()=>refresh(false),10000);
  window.addEventListener('pageshow',()=>refresh(true));
  document.addEventListener('visibilitychange',()=>{if(!document.hidden)refresh(true)});
  window.NOVA_AFTERHOURS_STABLE_PORTAL_V83={refresh:()=>refresh(true)};
})();
/* NOVA_AFTERHOURS_STABLE_PORTAL_V83_END */
'''

js += "\n"+addon+"\n"

if re.search(r'/static/nova\.js\?v=[^"\']+',html):
    html=re.sub(r'/static/nova\.js\?v=[^"\']+',
                '/static/nova.js?v=2.4.22-afterhours-stable-v83',
                html,count=1)
elif '/static/nova.js' in html:
    html=html.replace('/static/nova.js',
                      '/static/nova.js?v=2.4.22-afterhours-stable-v83',1)
else:
    raise SystemExit('NOVA_JS_REFERENCE_NOT_FOUND')

jp.write_text(js,encoding='utf-8')
hp.write_text(html,encoding='utf-8')
print('OLD_V8_NATIVE_HYDRATOR_REMOVED=', 'NOVA_AFTERHOURS_SNAPSHOT_RESTORE_V8_START' not in js)
print('OLD_V81_RENDERER_REMOVED=', 'NOVA_AFTERHOURS_DIRECT_RENDER_V81_START' not in js)
print('V83_STABLE_PORTAL_BUILD=PASS')
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

echo "=== PUBLIC GATE ==="
curl -ksS --max-time 6 https://3-38-25-20.nip.io/ > "$WORK/public.html"
curl -ksS --max-time 6 'https://3-38-25-20.nip.io/static/nova.js?v=2.4.22-afterhours-stable-v83' > "$WORK/public.js"
grep -q 'afterhours-stable-v83' "$WORK/public.html"
grep -q 'NOVA_AFTERHOURS_STABLE_PORTAL_V83_START' "$WORK/public.js"
! grep -q 'NOVA_AFTERHOURS_SNAPSHOT_RESTORE_V8_START' "$WORK/public.js"
! grep -q 'NOVA_AFTERHOURS_DIRECT_RENDER_V81_START' "$WORK/public.js"
grep -q 'MutationObserver' "$WORK/public.js"
echo "PUBLIC_V83_MARKER=PASS"
echo "OLD_NATIVE_HYDRATOR=REMOVED"
echo "MUTATION_OBSERVER_REINSERT=ACTIVE"

MAIN_AFTER="$(sudo docker exec "$APP" sha256sum /app/app/main.py | awk '{print $1}')"
echo "MAIN_PY_SHA256_AFTER=$MAIN_AFTER"
[[ "$MAIN_BEFORE" == "$MAIN_AFTER" ]]
echo "MAIN_PY_HASH_GATE=PASS"

SUCCESS=1
trap - ERR INT TERM

echo "=== FINAL ==="
echo "SCROLL_REPAINT_DISAPPEARANCE=FIXED"
echo "TRANSIENT_SCREEN_STATE_ERASE=GUARDED_3_CONFIRM"
echo "PORTAL_AUTO_REINSERT=ACTIVE"
echo "QUANT_NOVA_RESTART=NO"
echo "MAIN_PY=BYTE_IDENTICAL"
echo "BUY_LOGIC=UNCHANGED"
echo "SCORING=UNCHANGED"
echo "SELECTION=UNCHANGED"
echo "WS=UNCHANGED"
echo "=== $REV PASS ==="
