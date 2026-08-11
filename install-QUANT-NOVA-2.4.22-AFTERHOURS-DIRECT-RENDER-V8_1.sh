#!/usr/bin/env bash
set -Eeuo pipefail

REV="QUANT-NOVA-2.4.22-AFTERHOURS-DIRECT-RENDER-V8.1"
GUARD="nova-http-guard"
APP="quant-nova"
HOST_STATIC="/home/ubuntu/quant-nova/http-guard-v2/static"
HOST_CACHE="/home/ubuntu/quant-nova/http-guard-v2/cache"
STAMP="$(date +%Y%m%d%H%M%S)"
WORK="/tmp/nova-v81-$STAMP"
BK="$HOME/quant-nova/afterhours-v81-backups"

mkdir -p "$WORK" "$BK"
chmod 700 "$WORK" "$BK"

echo "=== $REV START ==="
echo "PATCH_SCOPE=PUBLIC_FRONTEND_DIRECT_SNAPSHOT_RENDER_ONLY"
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

js=re.sub(
    r'/\*\s*NOVA_AFTERHOURS_DIRECT_RENDER_V81_START\s*\*/.*?/\*\s*NOVA_AFTERHOURS_DIRECT_RENDER_V81_END\s*\*/',
    '', js, flags=re.S
)

addon=r'''
/* NOVA_AFTERHOURS_DIRECT_RENDER_V81_START */
(function(){
  'use strict';

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
      if(v!==undefined && v!==null && v!=='') return v;
    }
    return def;
  };

  async function getj(url){
    try{
      const r=await fetch(url,{cache:'no-store'});
      return r.ok ? await r.json() : null;
    }catch(e){ return null; }
  }

  function rowsOf(j){
    if(!j) return [];
    if(Array.isArray(j)) return j;
    for(const k of ['rows','items','signals','picks','data']){
      if(Array.isArray(j[k])) return j[k];
    }
    return [];
  }

  function ensureStyle(){
    if(document.getElementById('novaV81Style')) return;
    const st=document.createElement('style');
    st.id='novaV81Style';
    st.textContent=`
      #novaV81{margin:26px 20px 38px;padding:22px;border:1px solid rgba(105,220,245,.24);border-radius:26px;background:rgba(5,27,38,.88);box-shadow:0 18px 60px rgba(0,0,0,.18)}
      #novaV81 .v81-head{display:flex;gap:12px;align-items:flex-start;justify-content:space-between;margin-bottom:16px}
      #novaV81 h2{margin:0;font-size:18px;letter-spacing:.04em;color:#ecfaff}
      #novaV81 .v81-sub{font-size:12px;color:#7f9ca7;margin-top:5px;line-height:1.5}
      #novaV81 .v81-badge{white-space:nowrap;border:1px solid rgba(110,255,185,.35);color:#9cffc7;border-radius:999px;padding:6px 10px;font-size:11px;font-weight:800}
      #novaV81 .v81-grid{display:grid;grid-template-columns:1fr;gap:18px}
      #novaV81 .v81-box{border:1px solid rgba(130,180,200,.15);border-radius:18px;padding:14px;background:rgba(0,0,0,.12)}
      #novaV81 .v81-title{display:flex;justify-content:space-between;gap:10px;align-items:center;margin-bottom:10px;font-size:14px;font-weight:800;color:#dff7ff}
      #novaV81 .v81-count{font-size:11px;color:#7f9ca7;font-weight:600}
      #novaV81 .v81-table-wrap{overflow-x:auto;-webkit-overflow-scrolling:touch}
      #novaV81 table{width:100%;border-collapse:collapse;min-width:640px}
      #novaV81 th{font-size:10px;text-align:left;color:#6f8e9c;font-weight:700;padding:8px 7px;border-bottom:1px solid rgba(130,180,200,.15)}
      #novaV81 td{font-size:11px;color:#dcecf2;padding:10px 7px;border-bottom:1px solid rgba(130,180,200,.09);vertical-align:top}
      #novaV81 td.name{font-weight:800;color:#fff}
      #novaV81 td.up{color:#ff8b96} #novaV81 td.down{color:#78aef7}
      #novaV81 .empty{padding:18px 4px;color:#6f8e9c;font-size:12px}
      #novaV81 .note{margin-top:10px;color:#6f8e9c;font-size:10px;line-height:1.5}
      @media(min-width:900px){#novaV81 .v81-grid{grid-template-columns:1fr 1fr}}
    `;
    document.head.appendChild(st);
  }

  function rowSignal(r){
    const code=first(r,['code','stock_code','symbol'],'-');
    const name=first(r,['name','stock_name','item_name'],'-');
    const cur=first(r,['current_price','live_price','last_price','price'],'-');
    const ch=first(r,['change_rate','rate','change_pct'],'-');
    const stage=first(r,['stage','signal_stage','event'],'-');
    const score=first(r,['score','signal_score','total_score'],'-');
    const cap=first(r,['capture_price','first_price','entry_price','signal_price'],'-');
    const perf=first(r,['capture_return_pct','return_pct','performance_pct'],'-');
    const cls=Number.isFinite(num(ch))?(num(ch)>=0?'up':'down'):'';
    return `<tr><td>${esc(code)}</td><td class="name">${esc(name)}</td><td>${money(cur)}</td><td class="${cls}">${pct(ch)}</td><td>${esc(stage)}</td><td>${esc(score)}</td><td>${money(cap)}</td><td>${pct(perf)}</td></tr>`;
  }

  function rowClose(r){
    const code=first(r,['code','stock_code','symbol'],'-');
    const name=first(r,['name','stock_name','item_name'],'-');
    const price=first(r,['price','current_price','close_price'],'-');
    const ch=first(r,['change_rate','rate','change_pct'],'-');
    const score=first(r,['score','close_score','total_score'],'-');
    const energy=first(r,['energy_state','state','status'],'-');
    const reason=first(r,['reason','reasons','why'],'-');
    const cls=Number.isFinite(num(ch))?(num(ch)>=0?'up':'down'):'';
    const rr=Array.isArray(reason)?reason.join(' · '):reason;
    return `<tr><td>${esc(code)}</td><td class="name">${esc(name)}</td><td>${money(price)}</td><td class="${cls}">${pct(ch)}</td><td>${esc(score)}</td><td>${esc(energy)}</td><td>${esc(rr)}</td></tr>`;
  }

  function rowBuy(r){
    const code=first(r,['code','stock_code','symbol'],'-');
    const name=first(r,['name','stock_name','item_name'],'-');
    const price=first(r,['price','entry_price','signal_price'],'-');
    const stage=first(r,['stage','route','status'],'-');
    const score=first(r,['score','signal_score'],'-');
    const at=first(r,['at_kst','time','generated_at'],'-');
    return `<tr><td>${esc(code)}</td><td class="name">${esc(name)}</td><td>${money(price)}</td><td>${esc(stage)}</td><td>${esc(score)}</td><td>${esc(at)}</td></tr>`;
  }

  function panel(title,count,head,body,note=''){
    return `<section class="v81-box"><div class="v81-title"><span>${esc(title)}</span><span class="v81-count">${esc(count)}건</span></div><div class="v81-table-wrap"><table><thead>${head}</thead><tbody>${body}</tbody></table></div>${note?`<div class="note">${esc(note)}</div>`:''}</section>`;
  }

  function insertRoot(){
    let root=document.getElementById('novaV81');
    if(root) return root;
    root=document.createElement('section');
    root.id='novaV81';
    const main=document.querySelector('main')||document.body;

    const statusCandidates=[...main.querySelectorAll('div,section')].filter(el=>{
      const t=(el.textContent||'').replace(/\s+/g,' ').trim();
      return t.includes('시장 세션') && t.includes('키움 REST') && t.includes('WebSocket');
    });
    if(statusCandidates.length){
      const target=statusCandidates.sort((a,b)=>a.textContent.length-b.textContent.length)[0];
      target.insertAdjacentElement('afterend',root);
      return root;
    }

    const h=[...main.querySelectorAll('h1,h2,h3,div')].find(el=>{
      const t=(el.textContent||'').replace(/\s+/g,' ').trim();
      return t.includes('NXT 급등 조기발견 알림') || t.includes('PRIMARY BUY') || t.includes('급등 조기');
    });
    if(h) h.insertAdjacentElement('beforebegin',root);
    else main.appendChild(root);
    return root;
  }

  async function renderV81(){
    ensureStyle();
    const [st,ns,cp,bs]=await Promise.all([
      getj('/api/screen-state'),
      getj('/api/nxt-signal-table'),
      getj('/api/close-picks'),
      getj('/api/buy-signals')
    ]);
    const hold=!!st?.screen_hold?.active;
    const awake=!!st?.runtime_awake;
    if(!hold || awake){
      const old=document.getElementById('novaV81');
      if(old) old.remove();
      return;
    }

    const nr=rowsOf(ns), cr=rowsOf(cp), br=rowsOf(bs);
    const root=insertRoot();
    const day=st?.screen_hold?.snapshot_source_day||st?.display_day||'20260811';
    const at=st?.screen_hold?.snapshot_at||'장마감 보전';

    const nbody=nr.length?nr.map(rowSignal).join(''):`<tr><td colspan="8"><div class="empty">보전된 NXT 신호가 없습니다.</div></td></tr>`;
    const cbody=cr.length?cr.map(rowClose).join(''):`<tr><td colspan="7"><div class="empty">보전된 종가후보가 없습니다.</div></td></tr>`;
    const bbody=br.length?br.map(rowBuy).join(''):`<tr><td colspan="6"><div class="empty">보전된 확정 BUY가 없습니다.</div></td></tr>`;

    root.innerHTML=`
      <div class="v81-head">
        <div><h2>LAST MARKET SNAPSHOT · ${esc(day)}</h2><div class="v81-sub">${esc(at)} · 장후 읽기전용 복원 · 실제 저장된 API snapshot만 표시</div></div>
        <div class="v81-badge">SNAPSHOT RESTORED</div>
      </div>
      <div class="v81-grid">
        ${panel('NXT SIGNAL MANAGEMENT',nr.length,
          '<tr><th>코드</th><th>종목</th><th>현재/최종가</th><th>등락</th><th>단계</th><th>점수</th><th>포착가</th><th>포착후</th></tr>',
          nbody,'/api/nxt-signal-table 보전본')}
        ${panel('종가추천 · 다음날 후보',cr.length,
          '<tr><th>코드</th><th>종목</th><th>가격</th><th>등락</th><th>점수</th><th>상태</th><th>근거</th></tr>',
          cbody,'/api/close-picks 보전본')}
        ${panel('확정 BUY 기록',br.length,
          '<tr><th>코드</th><th>종목</th><th>가격</th><th>경로/상태</th><th>점수</th><th>시간</th></tr>',
          bbody,'/api/buy-signals 보전본')}
      </div>`;
  }

  setTimeout(renderV81,300);
  setTimeout(renderV81,1500);
  setTimeout(renderV81,4000);
  setInterval(renderV81,15000);
  window.addEventListener('pageshow',renderV81);
  document.addEventListener('visibilitychange',()=>{if(!document.hidden)renderV81()});
  window.NOVA_AFTERHOURS_DIRECT_RENDER_V81={render:renderV81};
})();
/* NOVA_AFTERHOURS_DIRECT_RENDER_V81_END */
'''
js += "\n"+addon+"\n"

if re.search(r'/static/nova\.js\?v=[^"\']+',html):
    html=re.sub(r'/static/nova\.js\?v=[^"\']+','/static/nova.js?v=2.4.22-afterhours-direct-v81',html,count=1)
elif '/static/nova.js' in html:
    html=html.replace('/static/nova.js','/static/nova.js?v=2.4.22-afterhours-direct-v81',1)
else:
    raise SystemExit('NOVA_JS_REFERENCE_NOT_FOUND')

jp.write_text(js,encoding='utf-8')
hp.write_text(html,encoding='utf-8')
print('V81_BUILD=PASS')
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

echo "=== API DATA GATE ==="
for ep in /api/screen-state /api/nxt-signal-table /api/close-picks /api/buy-signals; do
  C="$(curl -sS --max-time 5 -o /dev/null -w '%{http_code}' "http://127.0.0.1:3200$ep" || true)"
  echo "$ep=$C"
  [[ "$C" == "200" ]] || exit 1
done
curl -fsS http://127.0.0.1:3200/api/nxt-signal-table | python3 -c "import sys,json;j=json.load(sys.stdin);print('NXT_COUNT=',j.get('count'),'ROWS=',len(j.get('rows') or []))"
curl -fsS http://127.0.0.1:3200/api/close-picks | python3 -c "import sys,json;j=json.load(sys.stdin);print('CLOSE_COUNT=',j.get('count'),'ROWS=',len(j.get('rows') or []))"

echo "=== PUBLIC MARKER GATE ==="
curl -ksS --max-time 6 https://3-38-25-20.nip.io/ > "$WORK/public.html"
curl -ksS --max-time 6 'https://3-38-25-20.nip.io/static/nova.js?v=2.4.22-afterhours-direct-v81' > "$WORK/public.js"
grep -q 'afterhours-direct-v81' "$WORK/public.html"
grep -q 'NOVA_AFTERHOURS_DIRECT_RENDER_V81_START' "$WORK/public.js"
echo "PUBLIC_V81_MARKER=PASS"

MAIN_AFTER="$(sudo docker exec "$APP" sha256sum /app/app/main.py | awk '{print $1}')"
echo "MAIN_PY_SHA256_AFTER=$MAIN_AFTER"
[[ "$MAIN_BEFORE" == "$MAIN_AFTER" ]]
echo "MAIN_PY_HASH_GATE=PASS"

echo "=== FINAL ==="
echo "DIRECT_SNAPSHOT_RENDER=ACTIVE"
echo "NATIVE_RENDER_FUNCTION_SCOPE=NO_LONGER_REQUIRED"
echo "QUANT_NOVA_RESTART=NO"
echo "MAIN_PY=BYTE_IDENTICAL"
echo "BUY_LOGIC=UNCHANGED"
echo "SCORING=UNCHANGED"
echo "SELECTION=UNCHANGED"
echo "WS=UNCHANGED"
echo "=== $REV PASS ==="
