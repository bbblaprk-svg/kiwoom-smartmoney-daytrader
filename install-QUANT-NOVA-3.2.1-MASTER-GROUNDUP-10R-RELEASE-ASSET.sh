#!/usr/bin/env bash
set -Eeuo pipefail
APP_VERSION="NOVA-3.2.1-MASTER-GROUNDUP-10R"
IMAGE="ghcr.io/bbblaprk-svg/kiwoom-smartmoney-daytrader:nova-3.2.1-master-groundup-10r-live-bridge"
SOURCE_SHA="c46ef3d5a0aa6d4442c5c908daa6bf9457f7947fd26b8a5b4be871ecd2da7eaf"
RELEASE_TAG="nova-3.2.1-master-groundup-10r-live-bridge"
ASSET="quant-nova-3.2.1-master-groundup-10r-live-bridge-image.tar.gz"
RELEASE_BASE="https://github.com/bbblaprk-svg/kiwoom-smartmoney-daytrader/releases/download/${RELEASE_TAG}"
APP=quant-nova; GUARD=nova-http-guard; STAMP="$(date +%Y%m%d%H%M%S)"; APP_BK="${APP}-backup-g10r-${STAMP}"; GUARD_BK="${GUARD}-backup-g10r-${STAMP}"
TMP="$(mktemp -d)"; ENVFILE="$TMP/runtime.env"; DATA_SNAPSHOT="$TMP/nova30.tar"; SUCCESS=0; APP_RENAMED=0; GUARD_RENAMED=0; DATA_DIR=""
say(){ printf '\n==> %s\n' "$*"; }; die(){ echo "ERROR: $*" >&2; exit 1; }
rollback(){ local rc=$?; trap - EXIT; if [[ $SUCCESS -eq 1 ]]; then rm -rf "$TMP"; exit 0; fi; echo "[AUTO-ROLLBACK] G10R deployment incomplete" >&2; sudo docker rm -f "$GUARD" "$APP" >/dev/null 2>&1 || true; if [[ -n "$DATA_DIR" && -f "$DATA_SNAPSHOT" ]]; then sudo rm -rf "$DATA_DIR"/* "$DATA_DIR"/.[!.]* "$DATA_DIR"/..?* >/dev/null 2>&1 || true; sudo tar -C "$DATA_DIR" -xpf "$DATA_SNAPSHOT" >/dev/null 2>&1 || true; fi; if [[ $APP_RENAMED -eq 1 ]] && sudo docker inspect "$APP_BK" >/dev/null 2>&1; then sudo docker rename "$APP_BK" "$APP" >/dev/null 2>&1 || true; sudo docker start "$APP" >/dev/null 2>&1 || true; fi; if [[ $GUARD_RENAMED -eq 1 ]] && sudo docker inspect "$GUARD_BK" >/dev/null 2>&1; then sudo docker rename "$GUARD_BK" "$GUARD" >/dev/null 2>&1 || true; sudo docker start "$GUARD" >/dev/null 2>&1 || true; fi; rm -rf "$TMP"; exit "${rc:-1}"; }
trap rollback EXIT
[[ "${EUID:-$(id -u)}" -ne 0 ]] || die "ubuntu 사용자로 실행하세요"
for x in sudo python3 curl sha256sum tar gzip free df grep awk stat; do command -v "$x" >/dev/null || die "$x 없음"; done
sudo docker version >/dev/null 2>&1 || die "Docker 접근 실패"
sudo docker inspect "$APP" >/dev/null 2>&1 || die "$APP 기존 컨테이너 없음"
sudo docker inspect "$GUARD" >/dev/null 2>&1 || die "$GUARD 기존 컨테이너 없음"

say "1/10 Freeze baseline and recover exact runtime topology"
sudo docker inspect "$APP" > "$TMP/app.json"; sudo docker inspect "$GUARD" > "$TMP/guard.json"
python3 - "$TMP/app.json" "$TMP/guard.json" "$ENVFILE" > "$TMP/discovery" <<'PY'
import json,sys
a=json.load(open(sys.argv[1]))[0];g=json.load(open(sys.argv[2]))[0];out=sys.argv[3]
# Recovery build intentionally disables browser auth. Broker/secret variables remain untouched.
skip={'PATH','HOSTNAME','HOME','PORT','NOVA_DATA_DIR','NOVA_LEGACY_DATA_DIR','NOVA_CANDIDATE_MODE','NOVA_OFFLINE','APP_ACCESS_TOKEN','NOVA_UI_ACCESS_TOKEN'}
rows=[]
for item in (a.get('Config') or {}).get('Env') or []:
    if '=' not in item:continue
    k=item.split('=',1)[0]
    if k in skip:continue
    if '\n' in item or '\r' in item:raise SystemExit('newline env:'+k)
    rows.append(item)
open(out,'w').write('\n'.join(rows)+'\n')
mounts=a.get('Mounts') or [];source=''
for m in mounts:
    if m.get('Destination')=='/app/data/nova30':source=m.get('Source') or ''
if not source:
    for m in mounts:
        if m.get('Destination')=='/app/data':
            base=m.get('Source') or '';source=(base.rstrip('/')+'/nova30') if base else '';break
ap=((a.get('HostConfig') or {}).get('PortBindings') or {}).get('8000/tcp') or [];gp=((g.get('HostConfig') or {}).get('PortBindings') or {}).get('8080/tcp') or []
an=list(((a.get('NetworkSettings') or {}).get('Networks') or {}).keys());gn=list(((g.get('NetworkSettings') or {}).get('Networks') or {}).keys());common=[n for n in gn if n in an]
if not common:raise SystemExit('app/guard common docker network not found')
print('DATA='+source);print('APP_PORT='+((ap[0].get('HostPort') if ap else '') or ''));print('GUARD_PORT='+((gp[0].get('HostPort') if gp else '') or ''));print('NETWORK='+common[0]);print('APP_NETS='+','.join(an));print('GUARD_NETS='+','.join(gn))
PY
chmod 600 "$ENVFILE"; DATA_DIR="$(sed -n 's/^DATA=//p' "$TMP/discovery")"; APP_HOST_PORT="$(sed -n 's/^APP_PORT=//p' "$TMP/discovery")"; GUARD_HOST_PORT="$(sed -n 's/^GUARD_PORT=//p' "$TMP/discovery")"; NETWORK="$(sed -n 's/^NETWORK=//p' "$TMP/discovery")"; APP_NETS="$(sed -n 's/^APP_NETS=//p' "$TMP/discovery")"; GUARD_NETS="$(sed -n 's/^GUARD_NETS=//p' "$TMP/discovery")"
[[ -n "$DATA_DIR" && -d "$DATA_DIR" ]] || die "active nova30 data mount not found: $DATA_DIR"
echo "BASELINE=PASS network=$NETWORK data=$DATA_DIR"; echo "RECOVERY_UI_AUTH_DISABLED=YES"

say "2/10 Download immutable G10R image from public GitHub Release; GHCR not used"
AVAIL="$(free -m | awk '/Mem:/{print $7}')"; (( AVAIL >= 180 )) || die "available RAM ${AVAIL}MB too low"
ASSET_PATH="$TMP/$ASSET"; SUM_PATH="$TMP/$ASSET.sha256"
curl -fL --retry 4 --retry-delay 2 --connect-timeout 10 "$RELEASE_BASE/$ASSET" -o "$ASSET_PATH" || die "release image download failed"
curl -fL --retry 4 --retry-delay 2 --connect-timeout 10 "$RELEASE_BASE/$ASSET.sha256" -o "$SUM_PATH" || die "release checksum download failed"
EXPECTED="$(awk '{print $1}' "$SUM_PATH" | head -1)"; [[ "$EXPECTED" =~ ^[0-9a-fA-F]{64}$ ]] || die "invalid release checksum file"
ACTUAL="$(sha256sum "$ASSET_PATH" | awk '{print $1}')"; [[ "$ACTUAL" == "$EXPECTED" ]] || die "release image sha256 mismatch"
echo "RELEASE_ASSET_SHA256=PASS $ACTUAL"
gzip -dc "$ASSET_PATH" | sudo docker load >/dev/null || die "docker load failed"
sudo docker image inspect "$IMAGE" >/dev/null 2>&1 || die "loaded image tag missing: $IMAGE"
[[ "$(sudo docker image inspect -f '{{index .Config.Labels "org.opencontainers.image.version"}}' "$IMAGE")" == "$APP_VERSION" ]] || die "image version mismatch"
[[ "$(sudo docker image inspect -f '{{index .Config.Labels "io.quantnova.source_zip_sha256"}}' "$IMAGE")" == "$SOURCE_SHA" ]] || die "source sha mismatch"
[[ "$(sudo docker image inspect -f '{{index .Config.Labels "io.quantnova.http_guard_model"}}' "$IMAGE")" == "LIVE_BRIDGE_V1_SINGLE_SOURCE" ]] || die "guard model mismatch"
sudo docker run --rm --entrypoint python "$IMAGE" /app/scripts/master_audit.py | grep -q MASTER_SPEC_AUDIT=PASS || die "image audit failed"
echo "IMAGE_IDENTITY=PASS DELIVERY=PUBLIC_RELEASE_ASSET"

say "3/10 Snapshot persistent NOVA state"
sudo tar -C "$DATA_DIR" -cpf "$DATA_SNAPSHOT" .; echo "DATA_SNAPSHOT=PASS bytes=$(stat -c%s "$DATA_SNAPSHOT")"

say "4/10 Atomic app+guard cutover"
sudo docker stop -t 8 "$GUARD" >/dev/null; sudo docker stop -t 8 "$APP" >/dev/null; sudo docker rename "$APP" "$APP_BK"; APP_RENAMED=1; sudo docker rename "$GUARD" "$GUARD_BK"; GUARD_RENAMED=1
UIDGID="$(id -u):$(id -g)"; APP_PORT_ARGS=(); [[ -n "$APP_HOST_PORT" ]] && APP_PORT_ARGS=(-p "${APP_HOST_PORT}:8000"); GUARD_PORT_ARGS=(); [[ -n "$GUARD_HOST_PORT" ]] && GUARD_PORT_ARGS=(-p "${GUARD_HOST_PORT}:8080")
sudo docker run -d --name "$APP" --network "$NETWORK" --restart unless-stopped --read-only --tmpfs /tmp:rw,noexec,nosuid,size=32m --user "$UIDGID" --env-file "$ENVFILE" \
  -e NOVA_UI_ACCESS_TOKEN= -e NOVA_DATA_DIR=/app/data/nova30 -e NOVA_LEGACY_DATA_DIR=/app/data/nova30/legacy_bridge -e NOVA_CANDIDATE_MODE=0 -e NOVA_OFFLINE=0 \
  --memory=448m --memory-swap=448m --memory-reservation=300m --pids-limit 256 --security-opt no-new-privileges --cap-drop ALL "${APP_PORT_ARGS[@]}" -v "$DATA_DIR:/app/data/nova30" "$IMAGE" >/dev/null
IFS=',' read -ra NLIST <<< "$APP_NETS"; for n in "${NLIST[@]}"; do [[ -z "$n" || "$n" == "$NETWORK" ]] && continue; sudo docker network connect "$n" "$APP" >/dev/null 2>&1 || true; done

say "5/10 App ready + direct dashboard advancing"
for _ in $(seq 1 120); do sudo docker exec "$APP" python -c "import json,urllib.request,sys;j=json.load(urllib.request.urlopen('http://127.0.0.1:8000/api/readyz',timeout=2));sys.exit(0 if j.get('ok') else 1)" >/dev/null 2>&1 && break; sleep .5; done
sudo docker exec "$APP" python - <<'PY'
import json,time,urllib.request
B='http://127.0.0.1:8000';a=json.load(urllib.request.urlopen(B+'/api/auth/check',timeout=2));assert a=={'ok':True,'auth_required':False},a
g=[]
for _ in range(4):
    j=json.load(urllib.request.urlopen(B+'/api/live-dashboard',timeout=3));assert j['version']=='NOVA-3.2.1-MASTER-GROUNDUP-10R',j;assert time.time()-float(j['generated_at'])<3,j;assert (j.get('delivery') or {}).get('bridge')=='LIVE_BRIDGE_V1',j.get('delivery');g.append(int(j['generation']));time.sleep(.4)
assert g==sorted(g) and len(set(g))>=2,g
print('DIRECT_DASHBOARD_ADVANCE=PASS',g)
PY

say "6/10 Start single-source HTTP/WebSocket guard"
sudo docker run -d --name "$GUARD" --network "$NETWORK" --restart unless-stopped --read-only --tmpfs /tmp:rw,noexec,nosuid,size=32m --user "$UIDGID" --pids-limit 128 --security-opt no-new-privileges --cap-drop ALL "${GUARD_PORT_ARGS[@]}" --entrypoint python -e NOVA_UPSTREAM="http://${APP}:8000" -e GUARD_PORT=8080 "$IMAGE" /app/ops/http_guard_v2.py >/dev/null
IFS=',' read -ra GLIST <<< "$GUARD_NETS"; for n in "${GLIST[@]}"; do [[ -z "$n" || "$n" == "$NETWORK" ]] && continue; sudo docker network connect "$n" "$GUARD" >/dev/null 2>&1 || true; done
for _ in $(seq 1 100); do sudo docker exec "$GUARD" python -c "import urllib.request;urllib.request.urlopen('http://127.0.0.1:8080/_guard/health',timeout=2)" >/dev/null 2>&1 && break; sleep .3; done
sudo docker exec "$GUARD" python -c "import json,urllib.request;j=json.load(urllib.request.urlopen('http://127.0.0.1:8080/_guard/health',timeout=2));assert j.get('guard')=='NOVA_HTTP_LIVE_BRIDGE_V1' and j.get('static_proxy')=='UPSTREAM_SINGLE_SOURCE',j;print('SINGLE_SOURCE_GUARD=PASS')"

say "7/10 Prove DIRECT server output equals PUBLIC guard output"
sudo docker exec "$APP" python - <<'PY'
import json,time,urllib.request
D='http://127.0.0.1:8000';P='http://nova-http-guard:8080';prev=0
for i in range(6):
    a=json.load(urllib.request.urlopen(D+'/api/live-dashboard',timeout=3));p=json.load(urllib.request.urlopen(P+'/api/live-dashboard',timeout=3));b=json.load(urllib.request.urlopen(D+'/api/live-dashboard',timeout=3))
    assert a['version']==p['version']==b['version']=='NOVA-3.2.1-MASTER-GROUNDUP-10R'
    assert a['generation']<=p['generation']<=b['generation']+2,(a['generation'],p['generation'],b['generation'])
    assert p['generation']>prev,(prev,p['generation']);prev=p['generation'];assert time.time()-float(p['generated_at'])<3,p
    time.sleep(.35)
print('SERVER_TO_PUBLIC_REST_PARITY=PASS generation',prev)
PY
sudo docker exec "$APP" python - <<'PY'
import asyncio,json,time,websockets
async def main():
    gens=[]
    async with websockets.connect('ws://nova-http-guard:8080/ws/live',open_timeout=5,close_timeout=2) as ws:
        for _ in range(3):
            j=json.loads(await asyncio.wait_for(ws.recv(),4));assert j.get('type')=='snapshot',j;gens.append(int(j['generation']));assert time.time()-float(j['generated_at'])<3,j
    assert gens==sorted(gens) and len(set(gens))==3,gens;print('SERVER_TO_PUBLIC_WS_PARITY=PASS',gens)
asyncio.run(main())
PY

say "8/10 Prove public HTML/JS is the same live-bridge source"
sudo docker exec "$APP" python - <<'PY'
import urllib.request
B='http://nova-http-guard:8080'
with urllib.request.urlopen(B+'/',timeout=3) as r:html=r.read().decode();cc=r.headers.get('Cache-Control','')
assert '3.2.1 MASTER GROUNDUP-10R' in html and 'no-store' in cc,(html[:300],cc)
with urllib.request.urlopen(B+'/static/nova.js?v=3210',timeout=3) as r:js=r.read().decode();cc=r.headers.get('Cache-Control','')
assert 'NOVA_LIVE_BRIDGE_V1' in js and 'startWatchdog' in js and 'startPoll' in js and 'no-store' in cc
print('PUBLIC_UI_SOURCE=PASS')
PY

say "9/10 Real Kiwoom feed gate if session active"
ACTIVE="$(sudo docker exec "$APP" python -c "from app.runtime.clock import sessions;print('1' if sessions()['active'] else '0')")"
if [[ "$ACTIVE" == 1 ]]; then OK=0; for _ in $(seq 1 90); do if sudo docker exec "$APP" python - <<'PY' >/dev/null 2>&1
import json,time,urllib.request
j=json.load(urllib.request.urlopen('http://127.0.0.1:8000/api/realtime-health',timeout=3));w=j.get('ws') or {};assert j.get('feed_state') in ('LIVE','WARMING');assert w.get('connected') and w.get('logged_in') and int(w.get('registered') or 0)>0;assert time.time()-float(w.get('last_message_at') or 0)<10
PY
then OK=1; break; fi; sleep 2; done; [[ $OK -eq 1 ]] || die "real Kiwoom feed did not become live"; echo "REAL_FEED=PASS"; else echo "REAL_FEED=SKIP_MARKET_CLOSED"; fi

say "10/10 Final seal"
[[ "$(sudo docker inspect -f '{{.State.Running}}' "$APP")" == true ]] || die "app not running"; [[ "$(sudo docker inspect -f '{{.State.Running}}' "$GUARD")" == true ]] || die "guard not running"; [[ "$(sudo docker inspect -f '{{.RestartCount}}' "$APP")" == 0 ]] || die "app restarted"; [[ "$(sudo docker inspect -f '{{.RestartCount}}' "$GUARD")" == 0 ]] || die "guard restarted"
SUCCESS=1; trap - EXIT; rm -rf "$TMP"
echo; echo "===== QUANT NOVA 3.2.1 G10R LIVE BRIDGE PUBLIC-RELEASE DEPLOY PASS ====="; echo "APP_IMAGE=$IMAGE"; echo "IMAGE_DELIVERY=PUBLIC_GITHUB_RELEASE_ASSET"; echo "ROLLBACK_APP=$APP_BK"; echo "ROLLBACK_GUARD=$GUARD_BK"; echo "UI_AUTH=DISABLED_RECOVERY"; echo "DELIVERY=REST_1S_AUTHORITATIVE+WS_FULL_SNAPSHOT+READ_THROUGH_DISPLAY+SINGLE_SOURCE_GUARD"
