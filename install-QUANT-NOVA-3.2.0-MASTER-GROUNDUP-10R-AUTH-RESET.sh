#!/usr/bin/env bash
set -Eeuo pipefail

VERSION="3.2.0"
APP_VERSION="NOVA-3.2.0-MASTER-GROUNDUP-10"
IMAGE="ghcr.io/bbblaprk-svg/kiwoom-smartmoney-daytrader:nova-3.2.0-master-groundup-10"
SOURCE_SHA="22b801d4ff715801dc331a2525f928671c2c60d3b0f39fd9185e2b18ec6ac065"
APP="quant-nova"
GUARD="nova-http-guard"
STAMP="$(date +%Y%m%d%H%M%S)"
APP_BK="${APP}-backup-g10-${STAMP}"
GUARD_BK="${GUARD}-backup-g10-${STAMP}"
TMP="$(mktemp -d)"
ENVFILE="$TMP/runtime.env"
DATA_SNAPSHOT="$TMP/nova30.tar"
SUCCESS=0
APP_RENAMED=0
GUARD_RENAMED=0
NEW_APP=0
NEW_GUARD=0
DATA_DIR=""

say(){ printf '\n==> %s\n' "$*"; }
die(){ echo "ERROR: $*" >&2; exit 1; }

rollback(){
  local rc=$?
  trap - EXIT
  if [[ $SUCCESS -eq 1 ]]; then rm -rf "$TMP"; exit 0; fi
  echo "[AUTO-ROLLBACK] G10 deployment incomplete" >&2
  sudo docker rm -f "$GUARD" >/dev/null 2>&1 || true
  sudo docker rm -f "$APP" >/dev/null 2>&1 || true
  if [[ -n "$DATA_DIR" && -f "$DATA_SNAPSHOT" ]]; then
    sudo rm -rf "$DATA_DIR"/* "$DATA_DIR"/.[!.]* "$DATA_DIR"/..?* >/dev/null 2>&1 || true
    sudo tar -C "$DATA_DIR" -xpf "$DATA_SNAPSHOT" >/dev/null 2>&1 || true
  fi
  if [[ $APP_RENAMED -eq 1 ]] && sudo docker inspect "$APP_BK" >/dev/null 2>&1; then sudo docker rename "$APP_BK" "$APP" >/dev/null 2>&1 || true; sudo docker start "$APP" >/dev/null 2>&1 || true; fi
  if [[ $GUARD_RENAMED -eq 1 ]] && sudo docker inspect "$GUARD_BK" >/dev/null 2>&1; then sudo docker rename "$GUARD_BK" "$GUARD" >/dev/null 2>&1 || true; sudo docker start "$GUARD" >/dev/null 2>&1 || true; fi
  rm -rf "$TMP"
  exit "${rc:-1}"
}
trap rollback EXIT

[[ "${EUID:-$(id -u)}" -ne 0 ]] || die "ubuntu 사용자로 실행하세요"
for x in sudo python3 curl sha256sum tar free df grep awk stat; do command -v "$x" >/dev/null || die "$x 없음"; done
sudo docker version >/dev/null 2>&1 || die "Docker 접근 실패"
sudo docker inspect "$APP" >/dev/null 2>&1 || die "$APP 기존 컨테이너 없음"
sudo docker inspect "$GUARD" >/dev/null 2>&1 || die "$GUARD 기존 컨테이너 없음"

say "1/9 Read immutable baseline; do not patch live files"
sudo docker inspect "$APP" > "$TMP/app.json"
sudo docker inspect "$GUARD" > "$TMP/guard.json"
python3 - "$TMP/app.json" "$TMP/guard.json" "$ENVFILE" > "$TMP/discovery" <<'PY'
import json,sys
ap,gp,out=sys.argv[1:]
a=json.load(open(ap))[0];g=json.load(open(gp))[0]
skip={'PATH','HOSTNAME','HOME','PORT','NOVA_DATA_DIR','NOVA_LEGACY_DATA_DIR','NOVA_CANDIDATE_MODE','NOVA_OFFLINE','APP_ACCESS_TOKEN','NOVA_UI_ACCESS_TOKEN'}
rows=[]
for item in (a.get('Config') or {}).get('Env') or []:
    if '=' not in item: continue
    k=item.split('=',1)[0]
    if k in skip: continue
    if '\n' in item or '\r' in item: raise SystemExit('newline env:'+k)
    rows.append(item)
open(out,'w').write('\n'.join(rows)+'\n')
mounts=a.get('Mounts') or []
source=''
for m in mounts:
    if m.get('Destination')=='/app/data/nova30': source=m.get('Source') or ''
if not source:
    for m in mounts:
        if m.get('Destination')=='/app/data':
            base=m.get('Source') or '';source=(base.rstrip('/')+'/nova30') if base else ''
            break
aports=((a.get('HostConfig') or {}).get('PortBindings') or {}).get('8000/tcp') or []
gports=((g.get('HostConfig') or {}).get('PortBindings') or {}).get('8080/tcp') or []
anets=list(((a.get('NetworkSettings') or {}).get('Networks') or {}).keys())
gnets=list(((g.get('NetworkSettings') or {}).get('Networks') or {}).keys())
common=[n for n in gnets if n in anets]
if not common: raise SystemExit('app/guard common docker network not found')
print('DATA='+source)
print('APP_PORT='+((aports[0].get('HostPort') if aports else '') or ''))
print('GUARD_PORT='+((gports[0].get('HostPort') if gports else '') or ''))
print('NETWORK='+common[0])
print('APP_NETS='+','.join(anets))
print('GUARD_NETS='+','.join(gnets))
PY
chmod 600 "$ENVFILE"
DATA_DIR="$(sed -n 's/^DATA=//p' "$TMP/discovery")"
APP_HOST_PORT="$(sed -n 's/^APP_PORT=//p' "$TMP/discovery")"
GUARD_HOST_PORT="$(sed -n 's/^GUARD_PORT=//p' "$TMP/discovery")"
NETWORK="$(sed -n 's/^NETWORK=//p' "$TMP/discovery")"
APP_NETS="$(sed -n 's/^APP_NETS=//p' "$TMP/discovery")"
GUARD_NETS="$(sed -n 's/^GUARD_NETS=//p' "$TMP/discovery")"
[[ -n "$DATA_DIR" && -d "$DATA_DIR" ]] || die "active nova30 data mount not found: $DATA_DIR"
! grep -q '^APP_ACCESS_TOKEN=' "$ENVFILE" || die "legacy APP_ACCESS_TOKEN leaked into G10 env"
! grep -q '^NOVA_UI_ACCESS_TOKEN=' "$ENVFILE" || die "legacy NOVA_UI_ACCESS_TOKEN leaked into G10R env"
echo "BASELINE=PASS network=$NETWORK data=$DATA_DIR app_port=${APP_HOST_PORT:-none} guard_port=${GUARD_HOST_PORT:-none}"
echo "LEGACY_APP_ACCESS_TOKEN_DROPPED=PASS"
echo "LEGACY_NOVA_UI_ACCESS_TOKEN_DROPPED=PASS"

say "2/9 Pull prebuilt image while current service remains online"
AVAIL="$(free -m | awk '/Mem:/{print $7}')"; (( AVAIL >= 180 )) || die "available RAM ${AVAIL}MB too low"
if ! sudo docker pull "$IMAGE"; then
  [[ -n "${GHCR_USER:-}" && -n "${GHCR_TOKEN:-}" ]] || die "GHCR pull failed; private package requires GHCR_USER/GHCR_TOKEN"
  mkdir -p "$TMP/docker-auth"; printf '%s' "$GHCR_TOKEN" | sudo env DOCKER_CONFIG="$TMP/docker-auth" docker login ghcr.io -u "$GHCR_USER" --password-stdin >/dev/null
  sudo env DOCKER_CONFIG="$TMP/docker-auth" docker pull "$IMAGE"
fi
LABEL_VERSION="$(sudo docker image inspect -f '{{index .Config.Labels "org.opencontainers.image.version"}}' "$IMAGE")"
LABEL_SOURCE="$(sudo docker image inspect -f '{{index .Config.Labels "io.quantnova.source_zip_sha256"}}' "$IMAGE")"
LABEL_MODEL="$(sudo docker image inspect -f '{{index .Config.Labels "io.quantnova.deploy_model"}}' "$IMAGE")"
LABEL_AUTH="$(sudo docker image inspect -f '{{index .Config.Labels "io.quantnova.ui_auth_model"}}' "$IMAGE")"
LABEL_GUARD="$(sudo docker image inspect -f '{{index .Config.Labels "io.quantnova.http_guard_model"}}' "$IMAGE")"
[[ "$LABEL_VERSION" == "$APP_VERSION" ]] || die "image version mismatch: $LABEL_VERSION"
[[ "$LABEL_SOURCE" == "$SOURCE_SHA" ]] || die "source sha mismatch: $LABEL_SOURCE"
[[ "$LABEL_MODEL" == "GHCR_PULL_ONLY" ]] || die "deploy model mismatch"
[[ "$LABEL_AUTH" == "NOVA_UI_ACCESS_TOKEN_OPTIONAL" ]] || die "UI auth model mismatch"
[[ "$LABEL_GUARD" == "IMMUTABLE_IMAGE_V4_NO_CACHE" ]] || die "guard model mismatch"
sudo docker run --rm --entrypoint python "$IMAGE" /app/scripts/master_audit.py | grep -q 'MASTER_SPEC_AUDIT=PASS' || die "image master audit failed"
echo "IMAGE_IDENTITY=PASS"

say "3/9 Snapshot active NOVA30 state"
sudo tar -C "$DATA_DIR" -cpf "$DATA_SNAPSHOT" .
echo "DATA_SNAPSHOT=PASS bytes=$(stat -c%s "$DATA_SNAPSHOT")"

say "4/9 Atomic cutover: stop only at the boundary"
sudo docker stop -t 8 "$GUARD" >/dev/null || die "guard stop failed"
sudo docker stop -t 8 "$APP" >/dev/null || die "app stop failed"
sudo docker rename "$APP" "$APP_BK"; APP_RENAMED=1
sudo docker rename "$GUARD" "$GUARD_BK"; GUARD_RENAMED=1
UIDGID="$(id -u):$(id -g)"
APP_PORT_ARGS=(); [[ -n "$APP_HOST_PORT" ]] && APP_PORT_ARGS=(-p "${APP_HOST_PORT}:8000")
GUARD_PORT_ARGS=(); [[ -n "$GUARD_HOST_PORT" ]] && GUARD_PORT_ARGS=(-p "${GUARD_HOST_PORT}:8080")
sudo docker run -d --name "$APP" --network "$NETWORK" --restart unless-stopped \
  --read-only --tmpfs /tmp:rw,noexec,nosuid,size=32m --user "$UIDGID" \
  --env-file "$ENVFILE" -e NOVA_DATA_DIR=/app/data/nova30 -e NOVA_LEGACY_DATA_DIR=/app/data/nova30/legacy_bridge \
  -e NOVA_CANDIDATE_MODE=0 -e NOVA_OFFLINE=0 --memory=448m --memory-swap=448m --memory-reservation=300m \
  --pids-limit 256 --security-opt no-new-privileges --cap-drop ALL \
  "${APP_PORT_ARGS[@]}" -v "$DATA_DIR:/app/data/nova30" "$IMAGE" >/dev/null
NEW_APP=1
# Preserve additional app networks without changing primary name resolution.
IFS=',' read -ra NLIST <<< "$APP_NETS"; for n in "${NLIST[@]}"; do [[ -z "$n" || "$n" == "$NETWORK" ]] && continue; sudo docker network connect "$n" "$APP" >/dev/null 2>&1 || true; done

say "5/9 App readiness and UI-auth separation"
for _ in $(seq 1 120); do sudo docker exec "$APP" python -c "import json,urllib.request,sys;j=json.load(urllib.request.urlopen('http://127.0.0.1:8000/api/readyz',timeout=2));sys.exit(0 if j.get('ok') else 1)" >/dev/null 2>&1 && break; sleep .5; done
sudo docker exec "$APP" python -c "import json,urllib.request;j=json.load(urllib.request.urlopen('http://127.0.0.1:8000/api/readyz',timeout=2));assert j.get('ok') and j.get('version')=='$APP_VERSION',j;print('APP_READYZ=PASS',j)"
UI_TOKEN="$(sed -n 's/^NOVA_UI_ACCESS_TOKEN=//p' "$ENVFILE" | tail -1)"
if [[ -z "$UI_TOKEN" ]]; then
  sudo docker exec "$APP" python -c "import json,urllib.request;j=json.load(urllib.request.urlopen('http://127.0.0.1:8000/api/auth/check',timeout=2));assert j=={'ok':True,'auth_required':False},j;urllib.request.urlopen('http://127.0.0.1:8000/api/live-dashboard',timeout=2);print('UI_AUTH_DISABLED_DEFAULT=PASS')"
else
  sudo docker exec -i -e TEST_UI_TOKEN="$UI_TOKEN" "$APP" python - <<'PY'
import json,os,urllib.request
T=os.environ['TEST_UI_TOKEN'];u='http://127.0.0.1:8000/api/auth/check'
a=json.load(urllib.request.urlopen(u,timeout=2));assert a=={'ok':False,'auth_required':True},a
r=urllib.request.Request(u,headers={'X-App-Token':T});b=json.load(urllib.request.urlopen(r,timeout=2));assert b=={'ok':True,'auth_required':True},b
print('UI_AUTH_EXPLICIT=PASS')
PY
fi

say "6/9 Start immutable guard from the SAME image — no host-source overwrite"
sudo docker run -d --name "$GUARD" --network "$NETWORK" --restart unless-stopped \
  --read-only --tmpfs /tmp:rw,noexec,nosuid,size=32m --user "$UIDGID" --pids-limit 128 \
  --security-opt no-new-privileges --cap-drop ALL "${GUARD_PORT_ARGS[@]}" \
  --entrypoint python -e NOVA_UPSTREAM="http://${APP}:8000" -e GUARD_PORT=8080 -e NOVA_STATIC_DIR=/app/static \
  "$IMAGE" /app/ops/http_guard_v2.py >/dev/null
NEW_GUARD=1
IFS=',' read -ra GLIST <<< "$GUARD_NETS"; for n in "${GLIST[@]}"; do [[ -z "$n" || "$n" == "$NETWORK" ]] && continue; sudo docker network connect "$n" "$GUARD" >/dev/null 2>&1 || true; done
for _ in $(seq 1 100); do sudo docker exec "$GUARD" python -c "import urllib.request;urllib.request.urlopen('http://127.0.0.1:8080/_guard/health',timeout=2)" >/dev/null 2>&1 && break; sleep .3; done
sudo docker exec "$GUARD" python -c "import json,urllib.request;j=json.load(urllib.request.urlopen('http://127.0.0.1:8080/_guard/health',timeout=2));assert j.get('guard')=='NOVA_HTTP_CLEAN_V4' and j.get('api_cache_enabled') is False and j.get('static_cache_enabled') is False,j;print('GUARD_IMMUTABLE_NO_CACHE=PASS')"

say "7/9 End-to-end browser/API/WebSocket contract"
sudo docker exec -i -e TEST_UI_TOKEN="$UI_TOKEN" "$GUARD" python - <<'PY'
import json,os,urllib.error,urllib.request
T=os.getenv('TEST_UI_TOKEN','');B='http://127.0.0.1:8080'
def req(path):
    h={'Authorization':'Bearer '+T} if T else {}
    r=urllib.request.Request(B+path,headers=h)
    with urllib.request.urlopen(r,timeout=3) as x:return x.status,dict(x.headers),x.read()
s,h,b=req('/');text=b.decode();assert '3.2.0 MASTER GROUNDUP-10' in text,text[:500]
s,h,b=req('/static/nova.js?v=3200');js=b.decode();assert 'purgeLegacyFrontendState' in js and "localStorage.removeItem('nova_token')" in js
assert 'no-store' in h.get('Cache-Control',''),h
s,h,b=req('/api/auth/check');j=json.loads(b);assert j.get('auth_required')==bool(T),j
s,h,b=req('/api/live-dashboard');j=json.loads(b);assert j.get('version')=='NOVA-3.2.0-MASTER-GROUNDUP-10',j
print('HTTP_BROWSER_CONTRACT=PASS',{'auth_required':bool(T),'generation':j.get('generation')})
PY
sudo docker exec -i -e TEST_UI_TOKEN="$UI_TOKEN" "$APP" python - <<'PY'
import asyncio,json,os,urllib.parse,websockets
T=os.getenv('TEST_UI_TOKEN','');uri='ws://nova-http-guard:8080/ws/live'
if T:uri+='?token='+urllib.parse.quote(T,safe='')
async def main():
    async with websockets.connect(uri,open_timeout=5,close_timeout=2) as ws:
        j=json.loads(await asyncio.wait_for(ws.recv(),5));assert j.get('type') in ('snapshot','delta'),j;print('PUBLIC_WS_CONTRACT=PASS',j.get('generation'))
asyncio.run(main())
PY

say "8/9 Real feed gate when market session is active"
ACTIVE="$(sudo docker exec "$APP" python -c "from app.runtime.clock import sessions;print('1' if sessions()['active'] else '0')")"
if [[ "$ACTIVE" == 1 ]]; then
  OK=0
  for _ in $(seq 1 90); do
    if sudo docker exec -i -e TEST_UI_TOKEN="$UI_TOKEN" "$APP" python - <<'PY' >/dev/null 2>&1
import json,os,time,urllib.request
T=os.getenv('TEST_UI_TOKEN','');h={'Authorization':'Bearer '+T} if T else {}
r=urllib.request.Request('http://127.0.0.1:8000/api/realtime-health',headers=h)
j=json.load(urllib.request.urlopen(r,timeout=3));w=j.get('ws') or {}
assert j.get('feed_state') in ('LIVE','WARMING'),j.get('feed_state')
assert w.get('connected') and w.get('logged_in') and int(w.get('registered') or 0)>0,w
assert time.time()-float(w.get('last_message_at') or 0)<10,w
PY
    then OK=1;break;fi
    sleep 2
  done
  [[ $OK -eq 1 ]] || die "real Kiwoom feed did not become live"
  echo "REAL_FEED=PASS"
else
  echo "REAL_FEED=SKIP_MARKET_CLOSED"
fi

say "9/9 Final seal"
[[ "$(sudo docker inspect -f '{{.State.Running}}' "$APP")" == true ]] || die "app not running"
[[ "$(sudo docker inspect -f '{{.State.Running}}' "$GUARD")" == true ]] || die "guard not running"
[[ "$(sudo docker inspect -f '{{.RestartCount}}' "$APP")" == 0 ]] || die "app restarted during deployment"
[[ "$(sudo docker inspect -f '{{.RestartCount}}' "$GUARD")" == 0 ]] || die "guard restarted during deployment"
SUCCESS=1
trap - EXIT
rm -rf "$TMP"
echo
echo "===== QUANT NOVA 3.2.0 MASTER GROUNDUP 10 DEPLOY PASS ====="
echo "APP_IMAGE=$IMAGE"
echo "ROLLBACK_APP=$APP_BK"
echo "ROLLBACK_GUARD=$GUARD_BK"
echo "UI_AUTH=$([[ -n "$UI_TOKEN" ]] && echo EXPLICIT || echo DISABLED_DEFAULT)"
echo "NO_HOST_PATCHING=YES"
