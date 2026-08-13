#!/usr/bin/env bash
set -Eeuo pipefail

APP_VERSION="NOVA-3.2.2-MASTER-GROUNDUP-10R3"
IMAGE="ghcr.io/bbblaprk-svg/kiwoom-smartmoney-daytrader:nova-3.2.2-master-groundup-10r3-close-truth"
SOURCE_SHA="28feea60b49a37c1f2e9128636027dd4899c1018ab4a2d0b71bc45fbfe8df073"
RELEASE_TAG="nova-3.2.2-master-groundup-10r3-close-truth"
ASSET="quant-nova-3.2.2-master-groundup-10r3-close-truth-image.tar.gz"
RELEASE_BASE="https://github.com/bbblaprk-svg/kiwoom-smartmoney-daytrader/releases/download/${RELEASE_TAG}"

APP="quant-nova"
GUARD="nova-http-guard"
STAMP="$(date +%Y%m%d%H%M%S)"
APP_BK="${APP}-backup-g10r3-${STAMP}"
GUARD_BK="${GUARD}-backup-g10r3-${STAMP}"
TMP="$(mktemp -d)"
ENVFILE="$TMP/runtime.env"
DATA_SNAPSHOT="$TMP/nova30.tar"

SUCCESS=0
NEW_APP=0
NEW_GUARD=0
APP_RENAMED=0
GUARD_RENAMED=0
BASE_GUARD_PRESENT=0
DATA_DIR=""

say(){ printf '\n==> %s\n' "$*"; }
die(){ echo "ERROR: $*" >&2; exit 1; }
exists(){ sudo docker inspect "$1" >/dev/null 2>&1; }

latest_backup(){
  local prefix="$1" n created
  while IFS= read -r n; do
    [[ -n "$n" ]] || continue
    created="$(sudo docker inspect -f '{{.Created}}' "$n" 2>/dev/null || true)"
    [[ -n "$created" ]] && printf '%s\t%s\n' "$created" "$n"
  done < <(sudo docker ps -a --format '{{.Names}}' | grep -E "^${prefix}" || true) \
    | sort | tail -1 | cut -f2-
}

rollback(){
  local rc=$?
  trap - EXIT
  if [[ $SUCCESS -eq 1 ]]; then
    rm -rf "$TMP"
    exit 0
  fi
  echo "[AUTO-ROLLBACK] G10R3 deployment incomplete" >&2

  # IMPORTANT: only remove containers created by THIS run.
  if [[ $NEW_GUARD -eq 1 ]]; then sudo docker rm -f "$GUARD" >/dev/null 2>&1 || true; fi
  if [[ $NEW_APP -eq 1 ]]; then sudo docker rm -f "$APP" >/dev/null 2>&1 || true; fi

  if [[ -n "$DATA_DIR" && -f "$DATA_SNAPSHOT" ]]; then
    sudo rm -rf "$DATA_DIR"/* "$DATA_DIR"/.[!.]* "$DATA_DIR"/..?* >/dev/null 2>&1 || true
    sudo tar -C "$DATA_DIR" -xpf "$DATA_SNAPSHOT" >/dev/null 2>&1 || true
  fi

  if [[ $APP_RENAMED -eq 1 ]] && exists "$APP_BK"; then
    sudo docker rename "$APP_BK" "$APP" >/dev/null 2>&1 || true
    sudo docker start "$APP" >/dev/null 2>&1 || true
  fi
  if [[ $GUARD_RENAMED -eq 1 ]] && exists "$GUARD_BK"; then
    sudo docker rename "$GUARD_BK" "$GUARD" >/dev/null 2>&1 || true
    sudo docker start "$GUARD" >/dev/null 2>&1 || true
  fi

  rm -rf "$TMP"
  exit "${rc:-1}"
}
trap rollback EXIT

[[ "${EUID:-$(id -u)}" -ne 0 ]] || die "run as ubuntu user, not root"
for x in sudo python3 curl sha256sum tar gzip free df grep awk stat sort cut; do command -v "$x" >/dev/null || die "$x missing"; done
sudo docker version >/dev/null 2>&1 || die "Docker unavailable"

say "0/11 Recover canonical runtime if a previous bad rollback removed it"
if ! exists "$APP"; then
  APP_CAND="$(latest_backup 'quant-nova-backup-')"
  [[ -n "$APP_CAND" ]] || die "quant-nova is missing and no quant-nova-backup-* container exists"
  echo "RECOVER_APP_FROM=$APP_CAND"
  sudo docker rename "$APP_CAND" "$APP"
  sudo docker start "$APP" >/dev/null 2>&1 || true
fi

if ! exists "$GUARD"; then
  GUARD_CAND="$(latest_backup 'nova-http-guard-backup-')"
  if [[ -n "$GUARD_CAND" ]]; then
    echo "RECOVER_GUARD_FROM=$GUARD_CAND"
    sudo docker rename "$GUARD_CAND" "$GUARD"
    sudo docker start "$GUARD" >/dev/null 2>&1 || true
  else
    echo "RECOVER_GUARD_FROM=NONE (new guard will be created at cutover)"
  fi
fi
exists "$APP" || die "canonical app recovery failed"
echo "CANONICAL_APP_RECOVERY=PASS"

say "1/11 Read recovered baseline topology; never patch live files"
sudo docker inspect "$APP" > "$TMP/app.json"
if exists "$GUARD"; then
  BASE_GUARD_PRESENT=1
  sudo docker inspect "$GUARD" > "$TMP/guard.json"
else
  printf '[]\n' > "$TMP/guard.json"
fi

python3 - "$TMP/app.json" "$TMP/guard.json" "$ENVFILE" > "$TMP/discovery" <<'PY'
import json,sys
apath,gpath,out=sys.argv[1:]
a=json.load(open(apath))[0]
gl=json.load(open(gpath)); g=gl[0] if gl else None
skip={'PATH','HOSTNAME','HOME','PORT','NOVA_DATA_DIR','NOVA_LEGACY_DATA_DIR','NOVA_CANDIDATE_MODE','NOVA_OFFLINE','APP_ACCESS_TOKEN','NOVA_UI_ACCESS_TOKEN'}
rows=[]
for item in (a.get('Config') or {}).get('Env') or []:
    if '=' not in item: continue
    k=item.split('=',1)[0]
    if k in skip: continue
    if '\n' in item or '\r' in item: raise SystemExit('newline env:'+k)
    rows.append(item)
open(out,'w').write('\n'.join(rows)+'\n')

mounts=a.get('Mounts') or []; source=''
for m in mounts:
    if m.get('Destination')=='/app/data/nova30': source=m.get('Source') or ''
if not source:
    for m in mounts:
        if m.get('Destination')=='/app/data':
            base=m.get('Source') or ''; source=(base.rstrip('/')+'/nova30') if base else ''; break

aports=((a.get('HostConfig') or {}).get('PortBindings') or {}).get('8000/tcp') or []
anets=list(((a.get('NetworkSettings') or {}).get('Networks') or {}).keys())
if not anets: raise SystemExit('app has no docker network')

gports=[]; gnets=[]
if g:
    gports=((g.get('HostConfig') or {}).get('PortBindings') or {}).get('8080/tcp') or []
    gnets=list(((g.get('NetworkSettings') or {}).get('Networks') or {}).keys())

common=[n for n in gnets if n in anets]
if common:
    network=common[0]
elif 'kiwoom-net' in anets:
    network='kiwoom-net'
else:
    nonbridge=[n for n in anets if n not in ('bridge','host','none')]
    network=(nonbridge or anets)[0]

print('DATA='+source)
print('APP_PORT='+((aports[0].get('HostPort') if aports else '') or ''))
print('GUARD_PORT='+((gports[0].get('HostPort') if gports else '') or ''))
print('NETWORK='+network)
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
sudo docker network inspect "$NETWORK" >/dev/null 2>&1 || die "required docker network missing: $NETWORK"
! grep -q '^APP_ACCESS_TOKEN=' "$ENVFILE" || die "APP_ACCESS_TOKEN leaked"
! grep -q '^NOVA_UI_ACCESS_TOKEN=' "$ENVFILE" || die "NOVA_UI_ACCESS_TOKEN leaked"
echo "BASELINE=PASS network=$NETWORK data=$DATA_DIR app_port=${APP_HOST_PORT:-none} guard_port=${GUARD_HOST_PORT:-none}"
echo "RECOVERY_UI_AUTH_DISABLED=YES"

say "2/11 Verify public release asset exists BEFORE touching containers"
AVAIL="$(free -m | awk '/Mem:/{print $7}')"; (( AVAIL >= 180 )) || die "available RAM ${AVAIL}MB too low"
ASSET_PATH="$TMP/$ASSET"; SUM_PATH="$TMP/$ASSET.sha256"
curl -fL --retry 4 --retry-delay 2 --connect-timeout 10 "$RELEASE_BASE/$ASSET.sha256" -o "$SUM_PATH" || die "public release checksum asset unavailable"
EXPECTED="$(awk '{print $1}' "$SUM_PATH" | head -1)"
[[ "$EXPECTED" =~ ^[0-9a-fA-F]{64}$ ]] || die "invalid release checksum file"
curl -fL --retry 4 --retry-delay 2 --connect-timeout 10 "$RELEASE_BASE/$ASSET" -o "$ASSET_PATH" || die "public release image asset unavailable"
ACTUAL="$(sha256sum "$ASSET_PATH" | awk '{print $1}')"
[[ "$ACTUAL" == "$EXPECTED" ]] || die "release image sha256 mismatch"
echo "PUBLIC_RELEASE_ASSET=PASS sha256=$ACTUAL bytes=$(stat -c%s "$ASSET_PATH")"

say "3/11 Load and validate immutable image while recovered service stays online"
gzip -dc "$ASSET_PATH" | sudo docker load >/dev/null || die "docker load failed"
sudo docker image inspect "$IMAGE" >/dev/null 2>&1 || die "loaded image tag missing: $IMAGE"
[[ "$(sudo docker image inspect -f '{{index .Config.Labels "org.opencontainers.image.version"}}' "$IMAGE")" == "$APP_VERSION" ]] || die "image version mismatch"
[[ "$(sudo docker image inspect -f '{{index .Config.Labels "io.quantnova.source_zip_sha256"}}' "$IMAGE")" == "$SOURCE_SHA" ]] || die "source sha mismatch"
[[ "$(sudo docker image inspect -f '{{index .Config.Labels "io.quantnova.http_guard_model"}}' "$IMAGE")" == "LIVE_BRIDGE_V1_SINGLE_SOURCE" ]] || die "guard model mismatch"
sudo docker run --rm --entrypoint python "$IMAGE" /app/scripts/master_audit.py | grep -q MASTER_SPEC_AUDIT=PASS || die "image audit failed"
echo "IMAGE_IDENTITY=PASS DELIVERY=PUBLIC_RELEASE_ASSET"

say "4/11 Snapshot persistent NOVA state"
sudo tar -C "$DATA_DIR" -cpf "$DATA_SNAPSHOT" .
echo "DATA_SNAPSHOT=PASS bytes=$(stat -c%s "$DATA_SNAPSHOT")"

say "5/11 Atomic cutover with rollback flags armed only AFTER rename"
if exists "$GUARD"; then
  sudo docker stop -t 8 "$GUARD" >/dev/null || true
fi
sudo docker stop -t 8 "$APP" >/dev/null || die "app stop failed"
sudo docker rename "$APP" "$APP_BK"; APP_RENAMED=1
if exists "$GUARD"; then sudo docker rename "$GUARD" "$GUARD_BK"; GUARD_RENAMED=1; fi

UIDGID="$(id -u):$(id -g)"
APP_PORT_ARGS=(); [[ -n "$APP_HOST_PORT" ]] && APP_PORT_ARGS=(-p "${APP_HOST_PORT}:8000")
GUARD_PORT_ARGS=(); [[ -n "$GUARD_HOST_PORT" ]] && GUARD_PORT_ARGS=(-p "${GUARD_HOST_PORT}:8080")

sudo docker run -d --name "$APP" --network "$NETWORK" --restart unless-stopped --read-only \
  --tmpfs /tmp:rw,noexec,nosuid,size=32m --user "$UIDGID" --env-file "$ENVFILE" \
  -e NOVA_UI_ACCESS_TOKEN= -e NOVA_DATA_DIR=/app/data/nova30 -e NOVA_LEGACY_DATA_DIR=/app/data/nova30/legacy_bridge \
  -e NOVA_CANDIDATE_MODE=0 -e NOVA_OFFLINE=0 --memory=448m --memory-swap=448m --memory-reservation=300m \
  --pids-limit 256 --security-opt no-new-privileges --cap-drop ALL "${APP_PORT_ARGS[@]}" \
  -v "$DATA_DIR:/app/data/nova30" "$IMAGE" >/dev/null
NEW_APP=1
IFS=',' read -ra NLIST <<< "$APP_NETS"; for n in "${NLIST[@]}"; do [[ -z "$n" || "$n" == "$NETWORK" ]] && continue; sudo docker network connect "$n" "$APP" >/dev/null 2>&1 || true; done

say "6/11 App ready + direct dashboard must advance"
READY=0
for _ in $(seq 1 120); do
  if sudo docker exec "$APP" python -c "import json,urllib.request,sys;j=json.load(urllib.request.urlopen('http://127.0.0.1:8000/api/readyz',timeout=2));sys.exit(0 if j.get('ok') else 1)" >/dev/null 2>&1; then READY=1; break; fi
  sleep .5
done
[[ $READY -eq 1 ]] || die "new app never became ready"
sudo docker exec "$APP" python - <<'PY'
import json,time,urllib.request
B='http://127.0.0.1:8000'
a=json.load(urllib.request.urlopen(B+'/api/auth/check',timeout=2)); assert a=={'ok':True,'auth_required':False},a
g=[]
for _ in range(4):
    j=json.load(urllib.request.urlopen(B+'/api/live-dashboard',timeout=3))
    assert j['version']=='NOVA-3.2.2-MASTER-GROUNDUP-10R3',j.get('version')
    assert time.time()-float(j['generated_at'])<3,j.get('generated_at')
    assert (j.get('delivery') or {}).get('bridge')=='LIVE_BRIDGE_V1',j.get('delivery')
    g.append(int(j['generation'])); time.sleep(.4)
assert g==sorted(g) and len(set(g))>=2,g
print('DIRECT_DASHBOARD_ADVANCE=PASS',g)
PY

say "7/11 Start single-source HTTP/WebSocket guard"
sudo docker run -d --name "$GUARD" --network "$NETWORK" --restart unless-stopped --read-only \
  --tmpfs /tmp:rw,noexec,nosuid,size=32m --user "$UIDGID" --pids-limit 128 \
  --security-opt no-new-privileges --cap-drop ALL "${GUARD_PORT_ARGS[@]}" \
  --entrypoint python -e NOVA_UPSTREAM="http://${APP}:8000" -e GUARD_PORT=8080 \
  "$IMAGE" /app/ops/http_guard_v2.py >/dev/null
NEW_GUARD=1

# Reattach the guard to every previously known guard network; if guard was missing,
# app networks are the safest recovery fallback.
ATTACH_NETS="$GUARD_NETS"; [[ -n "$ATTACH_NETS" ]] || ATTACH_NETS="$APP_NETS"
IFS=',' read -ra GLIST <<< "$ATTACH_NETS"; for n in "${GLIST[@]}"; do [[ -z "$n" || "$n" == "$NETWORK" ]] && continue; sudo docker network connect "$n" "$GUARD" >/dev/null 2>&1 || true; done

GREADY=0
for _ in $(seq 1 100); do
  if sudo docker exec "$GUARD" python -c "import urllib.request;urllib.request.urlopen('http://127.0.0.1:8080/_guard/health',timeout=2)" >/dev/null 2>&1; then GREADY=1; break; fi
  sleep .3
done
[[ $GREADY -eq 1 ]] || die "new guard never became ready"
sudo docker exec "$GUARD" python -c "import json,urllib.request;j=json.load(urllib.request.urlopen('http://127.0.0.1:8080/_guard/health',timeout=2));assert j.get('guard')=='NOVA_HTTP_LIVE_BRIDGE_V1' and j.get('static_proxy')=='UPSTREAM_SINGLE_SOURCE',j;print('SINGLE_SOURCE_GUARD=PASS')"

say "8/11 Prove server output equals public REST and WebSocket"
sudo docker exec "$APP" python - <<'PY'
import json,time,urllib.request
D='http://127.0.0.1:8000'; P='http://nova-http-guard:8080'; prev=0
for _ in range(6):
    a=json.load(urllib.request.urlopen(D+'/api/live-dashboard',timeout=3))
    p=json.load(urllib.request.urlopen(P+'/api/live-dashboard',timeout=3))
    b=json.load(urllib.request.urlopen(D+'/api/live-dashboard',timeout=3))
    assert a['version']==p['version']==b['version']=='NOVA-3.2.2-MASTER-GROUNDUP-10R3'
    assert a['generation']<=p['generation']<=b['generation']+2,(a['generation'],p['generation'],b['generation'])
    assert p['generation']>prev,(prev,p['generation']); prev=p['generation']
    assert time.time()-float(p['generated_at'])<3,p['generated_at']
    time.sleep(.35)
print('SERVER_TO_PUBLIC_REST_PARITY=PASS generation',prev)
PY
sudo docker exec "$APP" python - <<'PY'
import asyncio,json,time,websockets
async def main():
    gens=[]
    async with websockets.connect('ws://nova-http-guard:8080/ws/live',open_timeout=5,close_timeout=2) as ws:
        for _ in range(3):
            j=json.loads(await asyncio.wait_for(ws.recv(),4)); assert j.get('type')=='snapshot',j
            gens.append(int(j['generation'])); assert time.time()-float(j['generated_at'])<3
    assert gens==sorted(gens) and len(set(gens))==3,gens
    print('SERVER_TO_PUBLIC_WS_PARITY=PASS',gens)
asyncio.run(main())
PY

say "9/11 Prove public HTML/JS is live-bridge source and auth is disabled"
sudo docker exec "$APP" python - <<'PY'
import json,urllib.request
B='http://nova-http-guard:8080'
a=json.load(urllib.request.urlopen(B+'/api/auth/check',timeout=3)); assert a=={'ok':True,'auth_required':False},a
with urllib.request.urlopen(B+'/',timeout=3) as r: html=r.read().decode(); cc=r.headers.get('Cache-Control','')
assert '3.2.2 MASTER GROUNDUP-10R3' in html and 'no-store' in cc,(html[:300],cc)
with urllib.request.urlopen(B+'/static/nova.js?v=3220',timeout=3) as r: js=r.read().decode(); cc=r.headers.get('Cache-Control','')
assert 'NOVA_LIVE_BRIDGE_V1' in js and 'startWatchdog' in js and 'startPoll' in js and 'no-store' in cc
print('PUBLIC_UI_SOURCE=PASS AUTH_DISABLED=PASS')
PY

say "10/11 Real Kiwoom gate if market session active"
ACTIVE="$(sudo docker exec "$APP" python -c "from app.runtime.clock import sessions;print('1' if sessions()['active'] else '0')")"
if [[ "$ACTIVE" == 1 ]]; then
  OK=0
  for _ in $(seq 1 90); do
    if sudo docker exec "$APP" python - <<'PY' >/dev/null 2>&1
import json,time,urllib.request
j=json.load(urllib.request.urlopen('http://127.0.0.1:8000/api/realtime-health',timeout=3)); w=j.get('ws') or {}
assert j.get('feed_state') in ('LIVE','WARMING')
assert w.get('connected') and w.get('logged_in') and int(w.get('registered') or 0)>0
assert time.time()-float(w.get('last_message_at') or 0)<10
PY
    then OK=1; break; fi
    sleep 2
  done
  [[ $OK -eq 1 ]] || die "real Kiwoom feed did not become live"
  echo "REAL_FEED=PASS"
else
  echo "REAL_FEED=SKIP_MARKET_CLOSED"
  KST_SEC="$(sudo docker exec "$APP" python -c "from app.runtime.clock import sec_of_day;print(sec_of_day())")"
  if (( KST_SEC >= 20*3600 || KST_SEC < 7*3600+30*60 )); then
    sudo docker exec "$APP" python - <<'PY'
import json,urllib.request
j=json.load(urllib.request.urlopen('http://127.0.0.1:8000/api/live-dashboard',timeout=3))
assert j.get('phase')=='PRIOR_CLOSE_FROZEN',j.get('phase')
d=j.get('delivery') or {};assert d.get('display_mode')=='SESSION_CLOSE_FROZEN',d
boards=j.get('boards') or {};rows=[r for v in boards.values() for r in (v or []) if isinstance(r,dict)]
priced=[r for r in rows if (r.get('price') or r.get('reference_price'))]
tracked=boards.get('nxt_management') or []
if tracked: assert any((r.get('price') or r.get('reference_price')) for r in tracked),tracked
if int(j.get('candidate_count') or 0)>0 and rows: assert priced,(j.get('candidate_count'),rows[:5])
print('FROZEN_CLOSE_DISPLAY=PASS','phase='+j['phase'],'priced_rows='+str(len(priced)),'tracked='+str(len(tracked)))
PY
  else
    echo "FROZEN_CLOSE_DISPLAY=SKIP_NON_OVERNIGHT_GAP"
  fi
fi

say "11/11 Final seal"
[[ "$(sudo docker inspect -f '{{.State.Running}}' "$APP")" == true ]] || die "app not running"
[[ "$(sudo docker inspect -f '{{.State.Running}}' "$GUARD")" == true ]] || die "guard not running"
[[ "$(sudo docker inspect -f '{{.RestartCount}}' "$APP")" == 0 ]] || die "app restarted"
[[ "$(sudo docker inspect -f '{{.RestartCount}}' "$GUARD")" == 0 ]] || die "guard restarted"
SUCCESS=1
trap - EXIT
rm -rf "$TMP"
echo
echo "===== QUANT NOVA 3.2.2 G10R3 CLOSE-TRUTH DEPLOY PASS ====="
echo "APP_IMAGE=$IMAGE"
echo "IMAGE_DELIVERY=PUBLIC_GITHUB_RELEASE_ASSET"
echo "ROLLBACK_APP=$APP_BK"
echo "ROLLBACK_GUARD=${GUARD_BK:-none}"
echo "UI_AUTH=DISABLED_RECOVERY"
echo "ROLLBACK_MODEL=FLAG_GUARDED_NO_PRECUTOVER_DELETE"
echo "DISPLAY_CLOSE_TRUTH=20:00-07:30_FROZEN"
echo "DELIVERY=REST_1S+WS_SNAPSHOT+SINGLE_SOURCE_GUARD"
