#!/usr/bin/env bash
set -Eeuo pipefail

NOVA_CONTAINER="${NOVA_CONTAINER:-quant-nova}"
GUARD_CONTAINER="${GUARD_CONTAINER:-nova-http-guard}"
PUBLIC_BASE="${PUBLIC_BASE:-https://3-38-25-20.nip.io}"
STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP_DIR="${HOME}/nova-g8-ui-repair-backup-${STAMP}"

log(){ printf '\n[%s] %s\n' "$(date '+%H:%M:%S')" "$*"; }
die(){ echo "ERROR: $*" >&2; exit 1; }

log "0. preflight"
sudo docker inspect "$NOVA_CONTAINER" >/dev/null 2>&1 || die "$NOVA_CONTAINER not found"
sudo docker inspect "$GUARD_CONTAINER" >/dev/null 2>&1 || die "$GUARD_CONTAINER not found"

NOVA_STATUS_BEFORE="$(sudo docker inspect "$NOVA_CONTAINER" --format '{{.State.Status}}')"
NOVA_RESTARTS_BEFORE="$(sudo docker inspect "$NOVA_CONTAINER" --format '{{.RestartCount}}')"
NOVA_IMAGE="$(sudo docker inspect "$NOVA_CONTAINER" --format '{{.Config.Image}}')"

echo "NOVA_STATUS_BEFORE=$NOVA_STATUS_BEFORE"
echo "NOVA_RESTARTS_BEFORE=$NOVA_RESTARTS_BEFORE"
echo "NOVA_IMAGE=$NOVA_IMAGE"
[ "$NOVA_STATUS_BEFORE" = "running" ] || die "quant-nova is not running"

log "1. locate active nova.js"
JS_PATH="$(
  sudo docker exec "$NOVA_CONTAINER" sh -c '
    for f in /app/static/nova.js /app/app/static/nova.js; do
      [ -f "$f" ] && { echo "$f"; exit 0; }
    done
    exit 1
  '
)" || die "nova.js not found"
echo "JS_PATH=$JS_PATH"

log "2. backup current static + guard source"
mkdir -p "$BACKUP_DIR"
sudo docker cp "${NOVA_CONTAINER}:${JS_PATH}" "$BACKUP_DIR/nova.js.before"
sudo docker cp "${GUARD_CONTAINER}:/srv/http_guard.py" "$BACKUP_DIR/http_guard.py.before" 2>/dev/null || true
sha256sum "$BACKUP_DIR/nova.js.before" || true

log "3. patch frontend auth bootstrap only"
sudo docker exec -i "$NOVA_CONTAINER" python - "$JS_PATH" <<'PY'
import sys, pathlib

path = pathlib.Path(sys.argv[1])
src = path.read_text(encoding="utf-8")
marker = "__NOVA_INLINE_AUTH_V2__"

if marker in src:
    print("frontend already patched")
    raise SystemExit(0)

start = src.find("async function auth()")
end = src.find("function connect()", start)
if start < 0 or end < 0:
    raise SystemExit("AUTH_FUNCTION_PATTERN_NOT_FOUND")

replacement = r'''/*__NOVA_INLINE_AUTH_V2__*/
async function __novaInlineToken(){
  return await new Promise((resolve)=>{
    const old=document.getElementById('__nova_auth_overlay');
    if(old) old.remove();
    const wrap=document.createElement('div');
    wrap.id='__nova_auth_overlay';
    wrap.style.cssText='position:fixed;inset:0;z-index:2147483647;background:rgba(5,10,20,.92);display:flex;align-items:center;justify-content:center;padding:24px;font-family:-apple-system,BlinkMacSystemFont,Segoe UI,sans-serif';
    const box=document.createElement('div');
    box.style.cssText='width:min(92vw,420px);background:#101827;border:1px solid #334155;border-radius:16px;padding:20px;color:#e5e7eb;box-shadow:0 24px 70px rgba(0,0,0,.45)';
    const title=document.createElement('div');
    title.textContent='QUANT NOVA 인증';
    title.style.cssText='font-weight:800;font-size:20px;margin-bottom:8px';
    const desc=document.createElement('div');
    desc.textContent='현재 G8.1 APP_ACCESS_TOKEN을 입력하세요. 토큰은 이 브라우저에만 저장됩니다.';
    desc.style.cssText='font-size:13px;line-height:1.5;color:#aeb8c8;margin-bottom:14px';
    const input=document.createElement('input');
    input.type='password';
    input.autocomplete='off';
    input.placeholder='APP_ACCESS_TOKEN';
    input.style.cssText='width:100%;box-sizing:border-box;font-size:16px;padding:12px 13px;border-radius:10px;border:1px solid #475569;background:#08111f;color:#fff;outline:none';
    const msg=document.createElement('div');
    msg.style.cssText='min-height:20px;margin-top:8px;font-size:12px;color:#fca5a5';
    const btn=document.createElement('button');
    btn.textContent='연결';
    btn.style.cssText='width:100%;margin-top:8px;padding:12px;border:0;border-radius:10px;background:#2563eb;color:white;font-size:16px;font-weight:700';
    const submit=()=>{
      const v=(input.value||'').trim();
      if(!v){ msg.textContent='토큰을 입력하세요.'; return; }
      btn.disabled=true;
      wrap.remove();
      resolve(v);
    };
    btn.onclick=submit;
    input.addEventListener('keydown',(e)=>{ if(e.key==='Enter') submit(); });
    box.append(title,desc,input,msg,btn);
    wrap.append(box);
    document.body.append(wrap);
    setTimeout(()=>input.focus(),50);
  });
}

async function auth(){
  try{
    token=localStorage.getItem('nova_token')||token||'';
    for(;;){
      if(!token){
        token=await __novaInlineToken();
        if(!token) return false;
        localStorage.setItem('nova_token',token);
      }
      let r;
      try{
        r=await fetch('/api/live-dashboard',{
          method:'GET',
          cache:'no-store',
          headers:{'Authorization':'Bearer '+token}
        });
      }catch(e){
        console.error('NOVA_NETWORK',e);
        return false;
      }
      if(r.ok){ return true; }
      if(r.status===401 || r.status===403){
        localStorage.removeItem('nova_token');
        token='';
        continue;
      }
      console.error('NOVA_SERVER_STATUS',r.status);
      return false;
    }
  }catch(e){
    console.error('NOVA_AUTH_BOOT',e);
    return false;
  }
}
'''

path.write_text(src[:start] + replacement + src[end:], encoding="utf-8")
print("frontend patched:", path)
PY

log "4. verify patch inside quant-nova"
sudo docker exec "$NOVA_CONTAINER" sh -c "grep -q '__NOVA_INLINE_AUTH_V2__' '$JS_PATH'"
sudo docker exec "$NOVA_CONTAINER" sha256sum "$JS_PATH"

log "5. restart HTTP guard ONLY"
sudo docker restart "$GUARD_CONTAINER" >/dev/null
for i in $(seq 1 30); do
  if sudo docker exec "$GUARD_CONTAINER" python -c \
    'import urllib.request; urllib.request.urlopen("http://127.0.0.1:8080/_guard/health",timeout=2)' \
    >/dev/null 2>&1; then
      echo "GUARD_READY=YES"
      break
  fi
  sleep 1
  [ "$i" -eq 30 ] && die "guard did not become ready"
done

log "6. public static verification"
curl -sk --max-time 8 "${PUBLIC_BASE}/static/nova.js" -o /tmp/nova-g8-ui-repair.js
grep -q '__NOVA_INLINE_AUTH_V2__' /tmp/nova-g8-ui-repair.js || die "public nova.js is not the patched version"
echo "PUBLIC_JS_PATCH=YES"
wc -c /tmp/nova-g8-ui-repair.js
sha256sum /tmp/nova-g8-ui-repair.js
rm -f /tmp/nova-g8-ui-repair.js

log "7. public API verification with current token (token not printed)"
TOKEN="$(
  sudo docker inspect "$NOVA_CONTAINER" \
    --format '{{range .Config.Env}}{{println .}}{{end}}' \
  | sed -n 's/^APP_ACCESS_TOKEN=//p' | head -1
)"
[ -n "$TOKEN" ] || die "APP_ACCESS_TOKEN missing"

FAIL=0
for API in \
  /api/live-dashboard \
  /api/prebuy-recommendations \
  /api/nxt-alerts \
  /api/nxt-signal-table
do
  CODE="$(curl -sk --max-time 8 \
    -H "Authorization: Bearer $TOKEN" \
    -o /tmp/nova-g8-ui-api \
    -w '%{http_code}' \
    "${PUBLIC_BASE}${API}" || true)"
  printf '%-34s HTTP %s\n' "$API" "$CODE"
  [ "$CODE" = "200" ] || FAIL=1
done
rm -f /tmp/nova-g8-ui-api
unset TOKEN

log "8. prove quant-nova engine was NOT restarted"
NOVA_STATUS_AFTER="$(sudo docker inspect "$NOVA_CONTAINER" --format '{{.State.Status}}')"
NOVA_RESTARTS_AFTER="$(sudo docker inspect "$NOVA_CONTAINER" --format '{{.RestartCount}}')"
echo "NOVA_STATUS_AFTER=$NOVA_STATUS_AFTER"
echo "NOVA_RESTARTS_AFTER=$NOVA_RESTARTS_AFTER"

[ "$NOVA_STATUS_AFTER" = "running" ] || die "quant-nova is not running after UI repair"
[ "$NOVA_RESTARTS_AFTER" = "$NOVA_RESTARTS_BEFORE" ] || die "quant-nova restart count changed unexpectedly"

log "RESULT"
if [ "$FAIL" -eq 0 ]; then
  echo "RESULT=PASS"
  echo "NEXT=Safari에서 기존 QUANT NOVA 탭을 모두 닫고 새 탭으로 ${PUBLIC_BASE} 접속"
  echo "EXPECTED=화면 내 'QUANT NOVA 인증' 패널 -> 토큰 입력 -> LIVE dashboard 표시"
else
  echo "RESULT=PARTIAL"
  echo "UI patch is active, but at least one public API is not HTTP 200."
  echo "Do NOT restart quant-nova."
fi

echo "BACKUP_DIR=$BACKUP_DIR"
