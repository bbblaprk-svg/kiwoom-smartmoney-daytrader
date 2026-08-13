#!/usr/bin/env bash
set -Eeuo pipefail

VERSION="3.1.3"
REV="MASTER-GROUNDUP-9C-PULL-ONLY"
APP_VERSION="NOVA-3.1.3-MASTER-GROUNDUP-9C"
IMAGE="ghcr.io/bbblaprk-svg/kiwoom-smartmoney-daytrader:nova-3.1.3-master-groundup-9c"
EXPECTED_SOURCE_ZIP_SHA256="1406da01428344ff05860bcb3261531da9a7e210c099b6b038d65a8a4c2b9a08"
APP_DIR="${NOVA_APP_DIR:-$HOME/quant-nova}"
CONTAINER="quant-nova"
STAMP="$(date +%Y%m%d%H%M%S)"
TMP="$(mktemp -d)"
RUNTIME_ENV="$TMP/runtime.env"
BASE_DATA="$TMP/base-data"
CAND_DATA="$TMP/candidate-data"
NOVA30_DIR="$APP_DIR/data-nova30"
FAILED_DATA="$APP_DIR/data-nova30-failed-$STAMP"
DEPLOY_DIR="$APP_DIR/deployments/nova3130-master-groundup9c-$STAMP"
BACKUP="quant-nova-backup-master-groundup9c-$STAMP"
CANDIDATE="quant-nova-candidate-master-groundup9c-$STAMP"
GUARD_STATIC="$APP_DIR/http-guard-v2/static"
GUARD_CACHE="$APP_DIR/http-guard-v2/cache"
GUARD_BK="$DEPLOY_DIR/http-guard-before"
GUARD_SOURCE_BK="$DEPLOY_DIR/http-guard-source-before.py"
GUARD_HOST_SOURCE=""

OLD_EXISTS=0
OLD_WAS_RUNNING=0
OLD_STOPPED_BY_INSTALL=0
OLD_RENAMED=0
NEW_STARTED=0
ACTIVE_DATA_MUTATED=0
NOVA30_PREEXIST=0
GUARD_BACKUP_READY=0
GUARD_SOURCE_BACKUP_READY=0
GUARD_SOURCE_MUTATED=0
SUCCESS=0
REAL_FEED_RESULT="NOT_RUN"
IMAGE_DIGEST=""
DATA_DIR=""
HOST_PORT="${NOVA_HOST_PORT:-}"
NETWORK=""

say(){ printf '\n==> %s\n' "$*"; }
die(){ echo "ERROR: $*" >&2; exit 1; }

rollback(){
  local ec=$?
  trap - EXIT
  if [[ $SUCCESS -eq 1 ]]; then rm -rf "$TMP"; exit 0; fi
  echo "[AUTO-ROLLBACK] G9C 미완료 — 새 컨테이너 제거 및 기존 immutable 상태 복원" >&2
  sudo docker rm -f "$CANDIDATE" >/dev/null 2>&1 || true
  if [[ $OLD_RENAMED -eq 1 ]] && sudo docker inspect "$CONTAINER" >/dev/null 2>&1; then
    timeout 15 sudo docker stop -t 5 "$CONTAINER" >/dev/null 2>&1 || sudo docker kill "$CONTAINER" >/dev/null 2>&1 || true
    sudo docker rm -f "$CONTAINER" >/dev/null 2>&1 || true
  elif [[ $NEW_STARTED -eq 1 ]] && sudo docker inspect "$CONTAINER" >/dev/null 2>&1; then
    timeout 15 sudo docker stop -t 5 "$CONTAINER" >/dev/null 2>&1 || sudo docker kill "$CONTAINER" >/dev/null 2>&1 || true
    sudo docker rm -f "$CONTAINER" >/dev/null 2>&1 || true
  fi
  if [[ $ACTIVE_DATA_MUTATED -eq 1 && -d "$BASE_DATA/nova30" ]]; then
    if [[ -e "$NOVA30_DIR" ]]; then
      sudo rm -rf "$FAILED_DATA" >/dev/null 2>&1 || true
      sudo mv "$NOVA30_DIR" "$FAILED_DATA" >/dev/null 2>&1 || true
    fi
    sudo mkdir -p "$NOVA30_DIR" >/dev/null 2>&1 || true
    sudo chown "$(id -u):$(id -g)" "$NOVA30_DIR" >/dev/null 2>&1 || true
    cp -a "$BASE_DATA/nova30"/. "$NOVA30_DIR"/ >/dev/null 2>&1 || true
    echo "[AUTO-ROLLBACK] G9C NOVA30 state restored; failed attempt preserved at $FAILED_DATA" >&2
  fi
  if [[ $OLD_RENAMED -eq 1 ]] && sudo docker inspect "$BACKUP" >/dev/null 2>&1; then
    sudo docker rename "$BACKUP" "$CONTAINER" >/dev/null 2>&1 || true
  fi
  if [[ $OLD_WAS_RUNNING -eq 1 ]]; then
    sudo docker start "$CONTAINER" >/dev/null 2>&1 || true
  fi
  if [[ $GUARD_SOURCE_BACKUP_READY -eq 1 && $GUARD_SOURCE_MUTATED -eq 1 && -n "$GUARD_HOST_SOURCE" && -f "$GUARD_SOURCE_BK" ]]; then
    sudo sh -c "cat '$GUARD_SOURCE_BK' > '$GUARD_HOST_SOURCE'" >/dev/null 2>&1 || true
    sudo python3 -m py_compile "$GUARD_HOST_SOURCE" >/dev/null 2>&1 || true
  fi
  if [[ $GUARD_BACKUP_READY -eq 1 && -d "$GUARD_BK" && -d "$GUARD_STATIC" ]]; then
    for f in index.html nova.js nova.css manifest.webmanifest sw.js; do
      sudo rm -f "$GUARD_STATIC/$f" "$GUARD_STATIC/.$f.nova30.tmp" >/dev/null 2>&1 || true
    done
    sudo cp -a "$GUARD_BK"/. "$GUARD_STATIC"/ >/dev/null 2>&1 || true
    sudo rm -f "$GUARD_CACHE"/* >/dev/null 2>&1 || true
  fi
  if [[ $GUARD_SOURCE_BACKUP_READY -eq 1 || $GUARD_BACKUP_READY -eq 1 ]]; then
    sudo docker restart nova-http-guard >/dev/null 2>&1 || true
  fi
  rm -rf "$TMP"
  exit "${ec:-1}"
}
trap rollback EXIT

[[ "${EUID:-$(id -u)}" -ne 0 ]] || die "root로 실행하지 마십시오. ubuntu 사용자에서 실행하세요."
for x in sudo python3 sha256sum curl timeout free df du tar find awk grep; do command -v "$x" >/dev/null || die "$x 없음"; done
sudo docker version >/dev/null 2>&1 || die "Docker 접근 실패"

say "1/14 Immutable rollback baseline + host discovery"
if sudo docker inspect "$CONTAINER" >/dev/null 2>&1; then OLD_EXISTS=1; fi
[[ $OLD_EXISTS -eq 1 ]] || die "기존 quant-nova 컨테이너 없음 — rollback 기준선이 필요합니다."
OLD_STATUS="$(sudo docker inspect -f '{{.State.Status}}' "$CONTAINER")"
[[ "$OLD_STATUS" == "running" || "$OLD_STATUS" == "exited" || "$OLD_STATUS" == "created" ]] || die "기존 quant-nova 상태를 안전하게 처리할 수 없음: $OLD_STATUS"
[[ "$OLD_STATUS" == "running" ]] && OLD_WAS_RUNNING=1 || true
OLD_IMAGE_ID="$(sudo docker inspect -f '{{.Image}}' "$CONTAINER")"
sudo docker inspect "$CONTAINER" > "$TMP/old-container.json"
python3 - "$TMP/old-container.json" "$RUNTIME_ENV" <<'PY'
import json,sys
src,out=sys.argv[1:]
j=json.load(open(src))[0]
skip={'PATH','HOSTNAME','HOME','PORT','NOVA_DATA_DIR','NOVA_LEGACY_DATA_DIR','NOVA_CANDIDATE_MODE','NOVA_OFFLINE','PYTHONPATH'}
rows=[]
for item in (j.get('Config') or {}).get('Env') or []:
    if '=' not in item: continue
    k=item.split('=',1)[0]
    if k in skip: continue
    if '\n' in item or '\r' in item: raise SystemExit('newline in container env: '+k)
    rows.append(item)
open(out,'w').write('\n'.join(rows)+'\n')
mounts=j.get('Mounts') or []
data=next((m.get('Source') for m in mounts if m.get('Destination')=='/app/data'), '')
ports=((j.get('HostConfig') or {}).get('PortBindings') or {}).get('8000/tcp') or []
host_port=(ports[0].get('HostPort') if ports else '') or ''
nets=list(((j.get('NetworkSettings') or {}).get('Networks') or {}).keys())
print('DATA_DIR='+data)
print('HOST_PORT='+host_port)
print('NETWORK='+(nets[0] if nets else ''))
PY
chmod 600 "$RUNTIME_ENV"
DISCOVERY="$(python3 - "$TMP/old-container.json" <<'PY'
import json,sys
j=json.load(open(sys.argv[1]))[0]
mounts=j.get('Mounts') or []
data=next((m.get('Source') for m in mounts if m.get('Destination')=='/app/data'), '')
ports=((j.get('HostConfig') or {}).get('PortBindings') or {}).get('8000/tcp') or []
host_port=(ports[0].get('HostPort') if ports else '') or ''
nets=list(((j.get('NetworkSettings') or {}).get('Networks') or {}).keys())
print(data);print(host_port);print(nets[0] if nets else '')
PY
)"
DATA_DIR="$(sed -n '1p' <<<"$DISCOVERY")"
[[ -n "$HOST_PORT" ]] || HOST_PORT="$(sed -n '2p' <<<"$DISCOVERY")"
[[ -n "$HOST_PORT" ]] || HOST_PORT=3200
NETWORK="$(sed -n '3p' <<<"$DISCOVERY")"
[[ -n "$DATA_DIR" ]] || DATA_DIR="$APP_DIR/data"
[[ -d "$DATA_DIR" ]] || die "기존 /app/data host mount를 찾을 수 없음: $DATA_DIR"
mkdir -p "$APP_DIR/deployments"
echo "OLD_STATUS=$OLD_STATUS OLD_IMAGE_ID=$OLD_IMAGE_ID HOST_PORT=$HOST_PORT NETWORK=${NETWORK:-default} DATA_DIR=$DATA_DIR"

say "2/14 Freeze old active and recover host headroom"
if [[ "$OLD_STATUS" == "running" ]]; then
  timeout 20 sudo docker stop -t 8 "$CONTAINER" >/dev/null 2>&1 || sudo docker kill "$CONTAINER" >/dev/null 2>&1 || die "기존 active 정지 실패"
  OLD_STOPPED_BY_INSTALL=1
fi
[[ "$(sudo docker inspect -f '{{.State.Running}}' "$CONTAINER")" == "false" ]] || die "기존 active가 아직 실행 중"
for _ in $(seq 1 40); do AVAIL_MB="$(free -m | awk '/Mem:/{print $7}')"; (( AVAIL_MB >= 400 )) && break; sleep 1; done
(( AVAIL_MB >= 400 )) || die "available RAM ${AVAIL_MB}MB < 400MB — pull/candidate 시작 금지"
FREE_KB="$(df -Pk "$APP_DIR" | awk 'NR==2{print $4}')"
(( FREE_KB >= 1800000 )) || die "디스크 여유 ${FREE_KB}KB < 1.8GB"
echo "HOST_HEADROOM=PASS available=${AVAIL_MB}MB free_disk=${FREE_KB}KB"

say "3/14 Permission-safe NOVA30 snapshot"
mkdir -p "$BASE_DATA/nova30" "$CAND_DATA/nova30"
SOURCE_NOVA30=""
if [[ -d "$NOVA30_DIR" ]]; then SOURCE_NOVA30="$NOVA30_DIR"; NOVA30_PREEXIST=1
elif sudo test -d "$DATA_DIR/nova30"; then SOURCE_NOVA30="$DATA_DIR/nova30"; fi
if [[ -n "$SOURCE_NOVA30" ]]; then
  BAD_LINK="$(sudo find "$SOURCE_NOVA30" -xdev -type l -print -quit 2>/dev/null || true)"
  [[ -z "$BAD_LINK" ]] || die "NOVA30 state symlink 금지: $BAD_LINK"
  BAD_SPECIAL="$(sudo find "$SOURCE_NOVA30" -xdev \( -type b -o -type c -o -type p -o -type s \) -print -quit 2>/dev/null || true)"
  [[ -z "$BAD_SPECIAL" ]] || die "NOVA30 state 특수파일 금지: $BAD_SPECIAL"
  sudo tar --one-file-system -C "$SOURCE_NOVA30" -cf - . | tar --no-same-owner -C "$BASE_DATA/nova30" -xf -
fi
rm -rf "$BASE_DATA/nova30/legacy_bridge"
mkdir -p "$BASE_DATA/nova30/legacy_bridge"
if sudo test -f "$DATA_DIR/nxt_next_day_close_picks.json"; then
  sudo cat "$DATA_DIR/nxt_next_day_close_picks.json" > "$BASE_DATA/nova30/legacy_bridge/nxt_next_day_close_picks.json"
  chmod 600 "$BASE_DATA/nova30/legacy_bridge/nxt_next_day_close_picks.json"
fi
cp -a "$BASE_DATA/nova30"/. "$CAND_DATA/nova30"/
touch "$CAND_DATA/nova30/.write_probe" && rm -f "$CAND_DATA/nova30/.write_probe"
echo "DATA_SNAPSHOT=PASS size=$(du -sh "$BASE_DATA/nova30" | awk '{print $1}') legacy_root_secrets=EXCLUDED"

say "4/14 Pull prebuilt GHCR image — server-side image construction forbidden"
pull_ok=0
if sudo docker pull "$IMAGE"; then pull_ok=1; fi
if [[ $pull_ok -ne 1 ]]; then
  GH_USER="${GHCR_USER:-${GHCR_USERNAME:-}}"
  GH_TOKEN_VALUE="${GHCR_TOKEN:-${GHCR_PAT:-}}"
  if [[ -z "$GH_USER" || -z "$GH_TOKEN_VALUE" ]] && [[ -f "$APP_DIR/.env" ]]; then
    mapfile -t GH < <(python3 - "$APP_DIR/.env" <<'PY'
import sys
vals={}
for raw in open(sys.argv[1],errors='ignore'):
    raw=raw.strip()
    if not raw or raw.startswith('#') or '=' not in raw: continue
    k,v=raw.split('=',1); vals[k.strip()]=v.strip().strip('"').strip("'")
print(vals.get('GHCR_USER') or vals.get('GHCR_USERNAME') or '')
print(vals.get('GHCR_TOKEN') or vals.get('GHCR_PAT') or '')
PY
)
    [[ -n "$GH_USER" ]] || GH_USER="${GH[0]:-}"
    [[ -n "$GH_TOKEN_VALUE" ]] || GH_TOKEN_VALUE="${GH[1]:-}"
  fi
  [[ -n "$GH_USER" && -n "$GH_TOKEN_VALUE" ]] || die "GHCR pull 실패. Package를 Public으로 바꾸거나 GHCR_USER + read:packages GHCR_TOKEN을 제공하십시오."
  mkdir -p "$TMP/docker-auth"
  printf '%s' "$GH_TOKEN_VALUE" | sudo env DOCKER_CONFIG="$TMP/docker-auth" docker login ghcr.io -u "$GH_USER" --password-stdin >/dev/null
  sudo env DOCKER_CONFIG="$TMP/docker-auth" docker pull "$IMAGE" || die "authenticated GHCR pull 실패"
fi
IMAGE_ID="$(sudo docker image inspect -f '{{.Id}}' "$IMAGE")"
LABEL_VERSION="$(sudo docker image inspect -f '{{index .Config.Labels "org.opencontainers.image.version"}}' "$IMAGE")"
LABEL_SOURCE="$(sudo docker image inspect -f '{{index .Config.Labels "io.quantnova.source_zip_sha256"}}' "$IMAGE")"
LABEL_MODEL="$(sudo docker image inspect -f '{{index .Config.Labels "io.quantnova.deploy_model"}}' "$IMAGE")"
IMAGE_ARCH="$(sudo docker image inspect -f '{{.Architecture}}' "$IMAGE")"
[[ "$LABEL_VERSION" == "$APP_VERSION" ]] || die "image version label mismatch: $LABEL_VERSION"
[[ "$LABEL_SOURCE" == "$EXPECTED_SOURCE_ZIP_SHA256" ]] || die "image source SHA label mismatch: $LABEL_SOURCE"
[[ "$LABEL_MODEL" == "GHCR_PULL_ONLY" ]] || die "image deploy model mismatch: $LABEL_MODEL"
[[ "$IMAGE_ARCH" == "amd64" ]] || die "image architecture mismatch: $IMAGE_ARCH"
IMAGE_DIGEST="$(sudo docker image inspect -f '{{join .RepoDigests "\n"}}' "$IMAGE" | grep '^ghcr.io/bbblaprk-svg/kiwoom-smartmoney-daytrader@sha256:' | head -1 || true)"
[[ -n "$IMAGE_DIGEST" ]] || die "pulled image RepoDigest 없음"
echo "IMAGE_IDENTITY=PASS image_id=$IMAGE_ID digest=$IMAGE_DIGEST"
AVAIL_MB="$(free -m | awk '/Mem:/{print $7}')"
(( AVAIL_MB >= 350 )) || die "image pull 후 available RAM ${AVAIL_MB}MB < 350MB — candidate 시작 금지"
echo "POST_PULL_MEMORY=PASS available=${AVAIL_MB}MB"

NET_ARGS=()
if [[ -n "$NETWORK" ]] && sudo docker network inspect "$NETWORK" >/dev/null 2>&1; then NET_ARGS=(--network "$NETWORK"); fi
UIDGID="$(id -u):$(id -g)"
COMMON=(--read-only --tmpfs /tmp:rw,noexec,nosuid,size=32m --user "$UIDGID" --env-file "$RUNTIME_ENV" -e NOVA_DATA_DIR=/app/data/nova30 -e NOVA_LEGACY_DATA_DIR=/app/data/nova30/legacy_bridge --pids-limit 256 --security-opt no-new-privileges --cap-drop ALL --log-driver json-file --log-opt max-size=10m --log-opt max-file=3)

say "5/14 Isolated no-network candidate"
sudo docker rm -f "$CANDIDATE" >/dev/null 2>&1 || true
sudo docker run -d --name "$CANDIDATE" --network none "${COMMON[@]}" --memory=384m --memory-swap=384m --memory-reservation=256m -e NOVA_CANDIDATE_MODE=1 -e NOVA_OFFLINE=0 -v "$CAND_DATA/nova30:/app/data/nova30" "$IMAGE" >/dev/null
for _ in $(seq 1 120); do
  sudo docker exec "$CANDIDATE" python -c "import json,urllib.request,sys;j=json.load(urllib.request.urlopen('http://127.0.0.1:8000/api/readyz',timeout=2));sys.exit(0 if j.get('ok') else 1)" >/dev/null 2>&1 && break
  sleep .5
done
sudo docker exec "$CANDIDATE" python -c "import json,urllib.request;j=json.load(urllib.request.urlopen('http://127.0.0.1:8000/api/readyz',timeout=2));assert j.get('ok') and j.get('version')=='NOVA-3.1.3-MASTER-GROUNDUP-9B',j;print('CANDIDATE_READYZ=PASS',j)"
sudo docker exec "$CANDIDATE" env PYTHONPATH=/app python /app/scripts/runtime_smoke.py --clients 10 --ready-timeout 10
sudo docker exec "$CANDIDATE" env PYTHONPATH=/app python /app/scripts/master_audit.py
CMEM="$(sudo docker inspect -f '{{.HostConfig.Memory}} {{.HostConfig.MemorySwap}}' "$CANDIDATE")"
[[ "$(awk '{print $1}' <<<"$CMEM")" == "$(awk '{print $2}' <<<"$CMEM")" ]] || die "candidate swap disabled contract 실패: $CMEM"

say "6/14 Candidate 45-second health/memory soak"
sudo docker exec -i "$CANDIDATE" python - <<'PY'
import json,os,time,urllib.request
T=os.getenv('APP_ACCESS_TOKEN','').strip();H={'X-App-Token':T} if T else {}
rss=[]
for i in range(15):
    req=urllib.request.Request('http://127.0.0.1:8000/api/realtime-health',headers=H)
    with urllib.request.urlopen(req,timeout=3) as r:j=json.load(r)
    m=j.get('memory') or {};t=j.get('telemetry') or {};w=j.get('journal') or {}
    assert j.get('ok'),j
    assert float(m.get('swap_mb') or 0)==0,m
    assert float(m.get('rss_mb') or 0)<300,m
    for k in ('db_init_fail','important_enqueue_fail','wal_hard_stall_exit','event_hard_stall_exit'):
        assert int(w.get(k) or 0)==0,(k,w.get(k))
    for k in ('dropped_signal_tick_count','signal_price_mismatch_count','wrong_venue_price_count','signal_without_live_snapshot_count','dispatch_handler_error_count'):
        assert int(t.get(k) or 0)==0,(k,t.get(k))
    rss.append(float(m.get('rss_mb') or 0));time.sleep(3)
print('CANDIDATE_SOAK=PASS',{'rss_start':rss[0],'rss_end':rss[-1],'rss_max':max(rss)})
PY
[[ "$(sudo docker inspect -f '{{.State.OOMKilled}}' "$CANDIDATE")" == "false" ]] || die "candidate OOMKilled"
[[ "$(sudo docker inspect -f '{{.RestartCount}}' "$CANDIDATE")" == "0" ]] || die "candidate restarted"
sudo docker rm -f "$CANDIDATE" >/dev/null
AVAIL_MB="$(free -m | awk '/Mem:/{print $7}')"
(( AVAIL_MB >= 350 )) || die "candidate 제거 후 available RAM ${AVAIL_MB}MB < 350MB"

say "7/14 Atomic cutover — old container preserved"
if [[ ! -d "$NOVA30_DIR" ]]; then
  sudo mkdir -p "$NOVA30_DIR"
  sudo chown "$UIDGID" "$NOVA30_DIR"
  cp -a "$BASE_DATA/nova30"/. "$NOVA30_DIR"/
fi
sudo chown -R "$UIDGID" "$NOVA30_DIR"
mkdir -p "$NOVA30_DIR/legacy_bridge"
rm -f "$NOVA30_DIR/legacy_bridge/nxt_next_day_close_picks.json"
if sudo test -f "$DATA_DIR/nxt_next_day_close_picks.json"; then
  sudo cat "$DATA_DIR/nxt_next_day_close_picks.json" > "$NOVA30_DIR/legacy_bridge/nxt_next_day_close_picks.json"
  chmod 600 "$NOVA30_DIR/legacy_bridge/nxt_next_day_close_picks.json"
fi
touch "$NOVA30_DIR/.write_probe" && rm -f "$NOVA30_DIR/.write_probe" || die "NOVA30 state 쓰기 실패"
sudo docker rename "$CONTAINER" "$BACKUP"
OLD_RENAMED=1
sudo docker run -d --name "$CONTAINER" "${NET_ARGS[@]}" "${COMMON[@]}" --restart unless-stopped --memory=448m --memory-swap=448m --memory-reservation=320m -e NOVA_CANDIDATE_MODE=0 -e NOVA_OFFLINE=0 -p "${HOST_PORT}:8000" -v "$NOVA30_DIR:/app/data/nova30" "$IMAGE" >/dev/null
NEW_STARTED=1
ACTIVE_DATA_MUTATED=1

say "8/14 Active liveness/readiness + no-swap gate"
for _ in $(seq 1 140); do
  curl -fsS --max-time 2 "http://127.0.0.1:${HOST_PORT}/api/livez" >/dev/null 2>&1 && break
  sleep .5
done
curl -fsS --max-time 3 "http://127.0.0.1:${HOST_PORT}/api/livez" | python3 -c 'import json,sys;j=json.load(sys.stdin);assert j.get("ok") and j.get("version")=="NOVA-3.1.3-MASTER-GROUNDUP-9B",j;print("ACTIVE_LIVEZ=PASS",j)'
for _ in $(seq 1 100); do
  sudo docker exec "$CONTAINER" python -c "import json,urllib.request,sys;j=json.load(urllib.request.urlopen('http://127.0.0.1:8000/api/readyz',timeout=2));sys.exit(0 if j.get('ok') else 1)" >/dev/null 2>&1 && break
  sleep .5
done
sudo docker exec "$CONTAINER" python -c "import json,urllib.request;j=json.load(urllib.request.urlopen('http://127.0.0.1:8000/api/readyz',timeout=2));assert j.get('ok') and j.get('version')=='NOVA-3.1.3-MASTER-GROUNDUP-9B',j;print('ACTIVE_READYZ=PASS',j)"
AMEM="$(sudo docker inspect -f '{{.HostConfig.Memory}} {{.HostConfig.MemorySwap}}' "$CONTAINER")"
[[ "$(awk '{print $1}' <<<"$AMEM")" == "$(awk '{print $2}' <<<"$AMEM")" ]] || die "active swap disabled contract 실패: $AMEM"

say "9/14 Active UI WebSocket + image-runtime audit"
sudo docker exec "$CONTAINER" env PYTHONPATH=/app python /app/scripts/runtime_smoke.py --clients 10 --ready-timeout 10
sudo docker exec "$CONTAINER" env PYTHONPATH=/app python /app/scripts/image_contract.py /app
curl -fsS --max-time 3 "http://127.0.0.1:${HOST_PORT}/" >/dev/null
echo "ACTIVE_RUNTIME_CONTRACT=PASS"

say "10/14 Real Kiwoom feed gate when session is active"
MARKET_ACTIVE="$(sudo docker exec "$CONTAINER" python -c "from app.runtime.clock import sessions;print('1' if sessions()['active'] else '0')")"
if [[ "$MARKET_ACTIVE" == "1" ]]; then
  OK=0
  for _ in $(seq 1 120); do
    SESSION_NOW="$(sudo docker exec "$CONTAINER" python -c "from app.runtime.clock import sessions;print('1' if sessions()['active'] else '0')")"
    if [[ "$SESSION_NOW" != "1" ]]; then OK=2; break; fi
    if sudo docker exec -i "$CONTAINER" python - <<'PY' >/dev/null 2>&1
import json,os,time,urllib.request
T=os.getenv('APP_ACCESS_TOKEN','').strip();H={'X-App-Token':T} if T else {}
with urllib.request.urlopen(urllib.request.Request('http://127.0.0.1:8000/api/realtime-health',headers=H),timeout=3) as r:j=json.load(r)
w=j.get('ws') or {};m=j.get('memory') or {};t=j.get('telemetry') or {}
assert j.get('feed_state')=='LIVE',j.get('feed_state')
assert w.get('connected') and w.get('logged_in') and int(w.get('registered') or 0)>0,w
assert time.time()-float(w.get('last_message_at') or 0)<8,w
assert float(w.get('last_trade_at') or 0)>0 and time.time()-float(w.get('last_trade_at') or 0)<30,w
assert float(m.get('swap_mb') or 0)==0,m
for k in ('dropped_signal_tick_count','dispatch_handler_error_count','pinned_ws_overflow'):
    assert int(t.get(k) or 0)==0,(k,t.get(k))
assert int(j.get('trade_errors') or 0)==0,j.get('trade_errors')
assert int(j.get('coalesce_errors') or 0)==0,j.get('coalesce_errors')
PY
    then OK=1; break; fi
    sleep 2
  done
  if [[ $OK -eq 1 ]]; then REAL_FEED_RESULT="PASS"
  elif [[ $OK -eq 2 ]]; then REAL_FEED_RESULT="SKIP_SESSION_ENDED_DURING_GATE"
  else die "실장중 Kiwoom WS/Feed LIVE gate 실패"; fi
else
  REAL_FEED_RESULT="SKIP_MARKET_CLOSED"
fi
echo "REAL_FEED_GATE=$REAL_FEED_RESULT"

if [[ "$REAL_FEED_RESULT" == "PASS" ]]; then
  sudo docker exec -i "$CONTAINER" python - <<'PYDISPLAY'
import json,os,urllib.request
t=os.getenv('APP_ACCESS_TOKEN','').strip();h={'Authorization':'Bearer '+t} if t else {}
req=urllib.request.Request('http://127.0.0.1:8000/api/live-dashboard',headers=h)
with urllib.request.urlopen(req,timeout=3) as r:j=json.load(r)
boards=j.get('boards') or {}
checked=0
for board,rows in boards.items():
    for row in rows or []:
        if row.get('price') is None: continue
        assert row.get('display_price_source')=='LIVE_TRADE_TICK',(board,row)
        assert not row.get('display_stale'),(board,row)
        age=float(row.get('display_age_ms') or 0)
        assert age <= 9000,(board,age,row)
        checked += 1
assert checked>0,boards
print('LIVE_DISPLAY_TRUTH_GATE=PASS rows=',checked)
PYDISPLAY
else
  echo "LIVE_DISPLAY_TRUTH_GATE=SKIP($REAL_FEED_RESULT)"
fi

say "11/14 Five-minute active memory/event-loop/WAL gate"
sudo docker exec -i "$CONTAINER" python - <<'PY'
import json,os,time,urllib.request,statistics
T=os.getenv('APP_ACCESS_TOKEN','').strip();H={'X-App-Token':T} if T else {}
def get():
    with urllib.request.urlopen(urllib.request.Request('http://127.0.0.1:8000/api/realtime-health',headers=H),timeout=3) as r:return json.load(r)
rss=[]
for i in range(60):
    j=get();m=j.get('memory') or {};t=j.get('telemetry') or {};w=j.get('journal') or {}
    assert j.get('ok'),j
    assert float(m.get('swap_mb') or 0)==0,m
    assert float(m.get('rss_mb') or 0)<400,m
    assert float(j.get('event_loop_lag_p95_ms') or 0)<300,j.get('event_loop_lag_p95_ms')
    assert float(j.get('trade_queue_oldest_age_ms') or 0)<1000,j.get('trade_queue_oldest_age_ms')
    for k in ('dropped_signal_tick_count','signal_price_mismatch_count','wrong_venue_price_count','signal_without_live_snapshot_count','dispatch_handler_error_count','pinned_ws_overflow'):
        assert int(t.get(k) or 0)==0,(k,t.get(k))
    assert int(j.get('trade_errors') or 0)==0,j.get('trade_errors')
    assert int(j.get('coalesce_errors') or 0)==0,j.get('coalesce_errors')
    for k in ('db_init_fail','important_enqueue_fail','wal_hard_stall_exit','event_hard_stall_exit'):
        assert int(w.get(k) or 0)==0,(k,w.get(k))
    rss.append(float(m.get('rss_mb') or 0));time.sleep(5)
first=statistics.mean(rss[:12]);last=statistics.mean(rss[-12:])
assert last-first<80,(first,last,max(rss))
print('ACTIVE_5MIN_SOAK=PASS',{'rss_first60_avg':round(first,1),'rss_last60_avg':round(last,1),'rss_max':max(rss)})
PY
[[ "$(sudo docker inspect -f '{{.State.OOMKilled}}' "$CONTAINER")" == "false" ]] || die "active OOMKilled"
[[ "$(sudo docker inspect -f '{{.RestartCount}}' "$CONTAINER")" == "0" ]] || die "active restarted during gate"
AVAIL_MB="$(free -m | awk '/Mem:/{print $7}')"
(( AVAIL_MB >= 150 )) || die "active soak 후 host available RAM ${AVAIL_MB}MB < 150MB"
echo "HOST_MEMORY_GATE=PASS available=${AVAIL_MB}MB"

say "12/14 Clean HTTP boundary + static UI atomic sync"
if [[ -d "$GUARD_STATIC" ]] && sudo docker inspect nova-http-guard >/dev/null 2>&1; then
  mkdir -p "$GUARD_BK" "$TMP/g9c-static"
  sudo cp -a "$GUARD_STATIC"/. "$GUARD_BK"/
  GUARD_BACKUP_READY=1

  GUARD_HOST_SOURCE="$(sudo docker inspect nova-http-guard --format '{{range .Mounts}}{{if eq .Destination "/srv/http_guard.py"}}{{.Source}}{{end}}{{end}}')"
  [[ -n "$GUARD_HOST_SOURCE" && -f "$GUARD_HOST_SOURCE" ]] || die "nova-http-guard host source를 찾지 못함"
  sudo cat "$GUARD_HOST_SOURCE" > "$GUARD_SOURCE_BK"
  chmod 600 "$GUARD_SOURCE_BK"
  GUARD_SOURCE_BACKUP_READY=1

  sudo docker cp "$CONTAINER:/app/ops/http_guard_v2.py" "$TMP/http_guard_v2.clean.py"
  python3 -m py_compile "$TMP/http_guard_v2.clean.py"
  CLEAN_GUARD_SHA="$(sha256sum "$TMP/http_guard_v2.clean.py" | awk '{print $1}')"
  [[ "$CLEAN_GUARD_SHA" == "ec8461bb95639b1510154d6cae7519fe84d6b27922399888883482e15240cc8a" ]] || die "clean guard SHA mismatch: $CLEAN_GUARD_SHA"
  ! grep -Eq '__NOVA_G8_R3__|NOVA_R6|NOVA_R7|__NOVA_INLINE_AUTH_V3__|__NOVA_ALWAYS_ON_POLL_R7__' "$TMP/http_guard_v2.clean.py" || die "debug guard lineage 발견"

  for f in index.html nova.js nova.css manifest.webmanifest sw.js; do
    sudo docker cp "$CONTAINER:/app/static/$f" "$TMP/g9c-static/$f"
  done
  grep -Fq "h['X-App-Token']=token" "$TMP/g9c-static/nova.js" || die "G9C source-level X-App-Token UI 없음"
  grep -Fq "h['Authorization']='Bearer '+token" "$TMP/g9c-static/nova.js" || die "G9C source-level Authorization UI 없음"
  grep -Fq "startLivePoll" "$TMP/g9c-static/nova.js" || die "G9C permanent UI poll 없음"
  ! grep -Eq '__NOVA_INLINE_AUTH_V3__|__NOVA_ALWAYS_ON_POLL_R7__|NOVA_R6|NOVA_R7' "$TMP/g9c-static/nova.js" || die "debug JS lineage 발견"

  sudo sh -c "cat '$TMP/http_guard_v2.clean.py' > '$GUARD_HOST_SOURCE'"
  GUARD_SOURCE_MUTATED=1
  sudo python3 -m py_compile "$GUARD_HOST_SOURCE"
  for f in index.html nova.js nova.css manifest.webmanifest sw.js; do
    sudo cp "$TMP/g9c-static/$f" "$GUARD_STATIC/.$f.nova312.tmp"
    sudo chmod 644 "$GUARD_STATIC/.$f.nova312.tmp"
    sudo mv "$GUARD_STATIC/.$f.nova312.tmp" "$GUARD_STATIC/$f"
  done
  sudo rm -f "$GUARD_CACHE"/* >/dev/null 2>&1 || true
  sudo docker restart nova-http-guard >/dev/null
  for _ in $(seq 1 40); do
    H="$(sudo docker inspect nova-http-guard --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}running{{end}}' 2>/dev/null || true)"
    [[ "$H" == "healthy" || "$H" == "running" ]] && sleep 1 && break
    sleep .5
  done
  sudo docker exec nova-http-guard python - <<'PYGUARD'
import json,urllib.request
with urllib.request.urlopen('http://127.0.0.1:8080/_guard/health',timeout=2) as r:j=json.load(r)
assert j.get('ok') and j.get('selection_logic_modified') is False,j
assert j.get('candidate_selection_modified') is False,j
assert j.get('buy_thresholds_modified') is False,j
assert j.get('scoring_formula_modified') is False,j
assert j.get('ws_subscriptions_modified') is False,j
print('CLEAN_HTTP_GUARD=PASS')
PYGUARD
  PUBLIC_JS="$TMP/public-nova.js"
  curl -ksS --max-time 5 "https://3-38-25-20.nip.io/static/nova.js?g9c=$STAMP" -o "$PUBLIC_JS"
  grep -Fq "h['X-App-Token']=token" "$PUBLIC_JS" || die "public JS X-App-Token contract 실패"
  grep -Fq "h['Authorization']='Bearer '+token" "$PUBLIC_JS" || die "public JS Authorization contract 실패"
  grep -Fq "startLivePoll" "$PUBLIC_JS" || die "public JS live poll contract 실패"
  grep -Fq "async function authCheck()" "$PUBLIC_JS" || die "public JS authCheck contract 실패"
  grep -Fq "rejected:true" "$PUBLIC_JS" || die "public JS stale-token recovery contract 실패"
  grep -Fq "promptAuth" "$PUBLIC_JS" || die "public JS reauth contract 실패"
  ! grep -Eq '__NOVA_INLINE_AUTH_V3__|__NOVA_ALWAYS_ON_POLL_R7__|NOVA_R6|NOVA_R7' "$PUBLIC_JS" || die "public JS debug patch residue"

  # Prove auth bootstrap is never cached/poisoned by the guard.
  AUTH_TOKEN="$(sudo docker exec "$CONTAINER" sh -c 'printf %s "$APP_ACCESS_TOKEN"' 2>/dev/null || true)"
  A0="$TMP/auth0.json"; A1="$TMP/auth1.json"; A2="$TMP/auth2.json"
  curl -ksS --max-time 5 "https://3-38-25-20.nip.io/api/auth/check?g9c0=$STAMP" -o "$A0"
  if [[ -n "$AUTH_TOKEN" ]]; then
    A3="$TMP/auth3.json"; A4="$TMP/auth4.json"
    curl -ksS --max-time 5 -H "X-App-Token: $AUTH_TOKEN" "https://3-38-25-20.nip.io/api/auth/check?g9c1=$STAMP" -o "$A1"
    curl -ksS --max-time 5 "https://3-38-25-20.nip.io/api/auth/check?g9c2=$STAMP" -o "$A2"
    curl -ksS --max-time 5 -H "Authorization: Bearer $AUTH_TOKEN" "https://3-38-25-20.nip.io/api/auth/check?g9c3=$STAMP" -o "$A3"
    curl -ksS --max-time 5 "https://3-38-25-20.nip.io/api/auth/check?g9c4=$STAMP" -o "$A4"
    python3 - "$A0" "$A1" "$A2" "$A3" "$A4" <<'PYAUTH'
import json,sys
a0,a1,a2,a3,a4=[json.load(open(x,encoding='utf-8')) for x in sys.argv[1:]]
assert a0.get('auth_required') is True and a0.get('ok') is False,a0
assert a1.get('auth_required') is True and a1.get('ok') is True,a1
assert a2.get('auth_required') is True and a2.get('ok') is False,a2
assert a3.get('auth_required') is True and a3.get('ok') is True,a3
assert a4.get('auth_required') is True and a4.get('ok') is False,a4
print('PUBLIC_BROWSER_AUTH_DUAL_HEADER_NO_CACHE=PASS')
PYAUTH
  else
    python3 - "$A0" <<'PYAUTH'
import json,sys
a=json.load(open(sys.argv[1],encoding='utf-8'))
assert a.get('auth_required') is False and a.get('ok') is True,a
print('PUBLIC_AUTH_NOT_REQUIRED=PASS')
PYAUTH
  fi
  unset AUTH_TOKEN

  # Prove the clean guard really tunnels /ws/live; polling is fallback, not the only live path.
  sudo docker exec -i "$CONTAINER" python - <<'PYWS'
import asyncio,json,os,urllib.parse,websockets
async def main():
    t=os.getenv('APP_ACCESS_TOKEN','').strip()
    uri='ws://nova-http-guard:8080/ws/live'+(('?token='+urllib.parse.quote(t)) if t else '')
    async with websockets.connect(uri,open_timeout=5,close_timeout=2) as ws:
        raw=await asyncio.wait_for(ws.recv(),5)
        j=json.loads(raw)
        assert j.get('type') in ('snapshot','delta'),j
        print('HTTP_GUARD_WS_TUNNEL=PASS',j.get('type'),j.get('generation'))
asyncio.run(main())
PYWS
  echo "HTTP_GUARD_CLEAN_REBUILD=PASS"
  echo "HTTP_GUARD_STATIC_SYNC=PASS"
else
  echo "HTTP_GUARD_CLEAN_REBUILD=SKIP(no guard container/static dir)"
fi
for helper in nova-http-guard kiwoom-caddy; do
  if sudo docker inspect "$helper" >/dev/null 2>&1; then
    [[ "$(sudo docker inspect -f '{{.State.Running}}' "$helper")" == "true" ]] || die "$helper not running"
    echo "$helper=RUNNING"
  fi
done

say "13/14 Deployment seal"
mkdir -p "$DEPLOY_DIR"
cat > "$DEPLOY_DIR/DEPLOYMENT_OK.txt" <<SEAL
status=PASS
version=$APP_VERSION
revision=$REV
image=$IMAGE
image_id=$IMAGE_ID
image_digest=$IMAGE_DIGEST
source_zip_sha256=$EXPECTED_SOURCE_ZIP_SHA256
deploy_model=GHCR_PULL_ONLY
lightsail_image_build=NO
lightsail_pip_install=NO
lightsail_python_compile=NO
lightsail_unittest=NO
previous_container=$BACKUP
previous_image_id=$OLD_IMAGE_ID
previous_state=$OLD_STATUS
in_container_source_patch=NO
docker_commit=NO
legacy_root_secret_copy=NO
nova30_runtime_data_isolated=YES
candidate_ready=PASS
candidate_runtime_smoke_10_clients=PASS
candidate_no_swap=PASS
active_ready=PASS
active_runtime_smoke_10_clients=PASS
active_no_swap=PASS
real_feed_gate=$REAL_FEED_RESULT
active_5min_soak=PASS
live_display_truth_gate=$REAL_FEED_RESULT
http_guard_clean_source_restored=$GUARD_SOURCE_MUTATED
host_available_mb_after_soak=$AVAIL_MB
completed_at=$(date -Is)
SEAL

say "14/14 Final status"
sudo docker ps --filter "name=^/${CONTAINER}$" --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}'
sudo docker exec -i "$CONTAINER" python - <<'PY'
import json,os,urllib.request
T=os.getenv('APP_ACCESS_TOKEN','').strip();H={'X-App-Token':T} if T else {}
with urllib.request.urlopen(urllib.request.Request('http://127.0.0.1:8000/api/realtime-health',headers=H),timeout=3) as r:j=json.load(r)
print(json.dumps({'version':j.get('version'),'feed_state':j.get('feed_state'),'memory':j.get('memory'),'load_mode':j.get('load_mode'),'ws':j.get('ws'),'journal':j.get('journal')},ensure_ascii=False))
PY
SUCCESS=1
rm -rf "$TMP"
trap - EXIT
echo "=== QUANT NOVA 3.1.3 MASTER GROUND-UP 9C PULL-ONLY DEPLOY PASS ==="
echo "IMAGE_DIGEST=$IMAGE_DIGEST"
echo "ROLLBACK_CONTAINER_PRESERVED=$BACKUP"
