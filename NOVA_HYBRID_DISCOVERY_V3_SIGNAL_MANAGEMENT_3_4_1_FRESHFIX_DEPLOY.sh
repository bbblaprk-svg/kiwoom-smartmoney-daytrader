#!/usr/bin/env bash
set -Eeuo pipefail

DF_NAME="QUANT_NOVA_HYBRID_DISCOVERY_V3_SIGNAL_MANAGEMENT_3_4_1_FRESHFIX.Dockerfile"
EXPECTED_SHA="2d9018cb14cae6d986bb438b55a92fbb142a836907dde9f659c78a77a1e1229b"
EXPECTED_VERSION="NOVA-HYBRID-DISCOVERY-V3-SIGNAL-MANAGEMENT-3.4.1-FRESHFIX"
STAMP="$(date +%Y%m%d-%H%M%S)"
IMAGE="quant-nova:v3-signal341-freshfix-${STAMP}"
BACKUP=""
CURRENT=""
CANARY=""
CUTOVER=0
INSPECT=""
CTX=""

say(){ printf '\n%s\n' "$*"; }
exists(){ docker container inspect "$1" >/dev/null 2>&1; }
cleanup(){
  set +e
  [ -n "${CANARY:-}" ] && exists "$CANARY" && docker rm -f "$CANARY" >/dev/null 2>&1 || true
  [ -n "${CTX:-}" ] && [ -d "$CTX" ] && rm -rf "$CTX" || true
  [ -n "${INSPECT:-}" ] && [ -f "$INSPECT" ] && rm -f "$INSPECT" || true
}
rollback(){
  set +e
  if [ "$CUTOVER" = 1 ] && [ -n "${CURRENT:-}" ] && [ -n "${BACKUP:-}" ] && exists "$BACKUP"; then
    exists "$CURRENT" && docker rm -f "$CURRENT" >/dev/null 2>&1 || true
    docker rename "$BACKUP" "$CURRENT" >/dev/null 2>&1 || true
    docker start "$CURRENT" >/dev/null 2>&1 || true
    echo "ROLLBACK=SUCCESS CURRENT=$CURRENT"
  fi
}
on_exit(){
  rc=$?
  if [ "$rc" -ne 0 ]; then rollback; fi
  cleanup
  exit "$rc"
}
trap on_exit EXIT

probe(){
  local container="$1"
  docker exec "$container" python - "$EXPECTED_VERSION" <<'PY' >/dev/null 2>&1
import json,os,sys,urllib.request
version=sys.argv[1]
def get(path):
    headers={}
    token=os.getenv('NOVA_UI_ACCESS_TOKEN','').strip()
    if token: headers['Authorization']='Bearer '+token
    request=urllib.request.Request('http://127.0.0.1:8000'+path,headers=headers)
    return json.load(urllib.request.urlopen(request,timeout=3))
try:
    live=get('/api/livez')
    current=get('/api/version')
    v3=get('/api/hybrid-discovery-v3')
    precision=get('/api/precision-edge')
    assert live.get('ok')
    assert current.get('version') == version
    assert v3.get('mode') == 'FULL_CUTOVER' and v3.get('official_cutover') is True
    assert v3.get('broker_calls_added') == 0 and v3.get('ws_types_added') == 0
    contracts=precision.get('contracts') or {}
    assert contracts.get('fresh_lifetime_starts_on_membership') is True
    assert contracts.get('fresh_episode_rearm_enabled') is True
    assert isinstance(precision.get('ledger'),list)
except Exception:
    sys.exit(1)
PY
}

wait_probe(){
  local container="$1" ok=0
  for _ in $(seq 1 60); do
    if probe "$container"; then ok=1; break; fi
    sleep 2
  done
  [ "$ok" = 1 ]
}

say "===== NOVA V3 3.4.1 FRESHFIX PRE-CUTOVER CANARY DEPLOY ====="
command -v docker >/dev/null 2>&1 || { echo "ERROR: docker not found"; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "ERROR: python3 not found"; exit 1; }
docker info >/dev/null 2>&1 || { echo "ERROR: docker daemon unavailable"; exit 1; }

say "[1/10] Dockerfile 검색"
DF="$(find /home/ubuntu "$HOME" /tmp -maxdepth 7 -type f -name "$DF_NAME" 2>/dev/null | head -1 || true)"
[ -n "$DF" ] || { echo "ERROR: $DF_NAME 파일을 찾지 못했습니다."; exit 2; }
echo "FOUND=$DF"

say "[2/10] SHA256 검증"
ACTUAL_SHA="$(sha256sum "$DF" | awk '{print $1}')"
echo "EXPECTED=$EXPECTED_SHA"
echo "ACTUAL  =$ACTUAL_SHA"
[ "$ACTUAL_SHA" = "$EXPECTED_SHA" ] || { echo "ERROR: Dockerfile SHA256 불일치. 기존 앱은 변경하지 않았습니다."; exit 3; }
echo "SHA256=PASS"

say "[3/10] 현재 NOVA 컨테이너 탐색"
for preferred in kiwoom-smartmoney quant-nova; do
  if exists "$preferred" && [ "$(docker inspect -f '{{.State.Running}}' "$preferred" 2>/dev/null || true)" = "true" ]; then
    CURRENT="$preferred"; break
  fi
done
if [ -z "$CURRENT" ]; then
  for container in $(docker ps --format '{{.Names}}'); do
    if docker exec "$container" python - <<'PY' >/dev/null 2>&1
import json,sys,urllib.request
try:
    sys.exit(0 if json.load(urllib.request.urlopen('http://127.0.0.1:8000/api/livez',timeout=2)).get('ok') else 1)
except Exception:
    sys.exit(1)
PY
    then CURRENT="$container"; break; fi
  done
fi
[ -n "$CURRENT" ] || { docker ps; echo "ERROR: 실행 중 NOVA 컨테이너를 찾지 못했습니다."; exit 4; }
echo "CURRENT=$CURRENT"

say "[4/10] 현재 컨테이너 실행계약 저장"
INSPECT="$(mktemp /tmp/nova341-inspect.XXXXXX.json)"
docker inspect "$CURRENT" > "$INSPECT"
ARGS_FILE="$(mktemp /tmp/nova341-args.XXXXXX)"
CANARY_ARGS_FILE="$(mktemp /tmp/nova341-canary-args.XXXXXX)"
python3 - "$INSPECT" "$ARGS_FILE" "$CANARY_ARGS_FILE" <<'PY'
import json,sys
src,prod_out,canary_out=sys.argv[1:]
j=json.load(open(src))[0]
c=j.get('Config') or {}; h=j.get('HostConfig') or {}
prod=[]; canary=[]
for env in c.get('Env') or []:
    prod += ['--env',env]
    if not env.startswith(('NOVA_DATA_DIR=','NOVA_LEGACY_DATA_DIR=','NOVA_OFFLINE=','NOVA_CANDIDATE_MODE=')):
        canary += ['--env',env]
seen=set()
for bind in h.get('Binds') or []:
    prod += ['--volume',bind]
    parts=bind.split(':')
    if len(parts)>1: seen.add(parts[1])
for mount in j.get('Mounts') or []:
    dst=mount.get('Destination') or ''
    if not dst or dst in seen: continue
    kind=mount.get('Type') or 'volume'; source=mount.get('Name') or mount.get('Source') or ''
    spec=[f'type={kind}']
    if source: spec.append(f'source={source}')
    spec.append(f'target={dst}')
    if not mount.get('RW',True): spec.append('readonly')
    prod += ['--mount',','.join(spec)]
for dst,opt in (h.get('Tmpfs') or {}).items(): prod += ['--tmpfs', dst + (':' + opt if opt else '')]
net=h.get('NetworkMode') or ''
if net and net not in ('default','bridge'): prod += ['--network',net]
if net not in ('host','none'):
    for private,bindings in (h.get('PortBindings') or {}).items():
        for binding in bindings or []:
            hp=(binding.get('HostPort') or '').strip(); hi=(binding.get('HostIp') or '').strip()
            if hp: prod += ['--publish',(hi+':' if hi else '')+hp+':'+private]
restart=h.get('RestartPolicy') or {}; name=restart.get('Name') or ''
if name:
    value=name; maximum=int(restart.get('MaximumRetryCount') or 0)
    if name=='on-failure' and maximum: value += ':'+str(maximum)
    prod += ['--restart',value]
memory=int(h.get('Memory') or 0)
if memory>0: prod += ['--memory',str(memory)]; canary += ['--memory',str(memory)]
nano=int(h.get('NanoCpus') or 0)
if nano>0:
    cpus=str(nano/1_000_000_000); prod += ['--cpus',cpus]; canary += ['--cpus',cpus]
canary += ['--network','none','--restart','no','--env','NOVA_DATA_DIR=/tmp/nova-canary-data','--env','NOVA_LEGACY_DATA_DIR=/tmp/nova-canary-legacy','--env','NOVA_OFFLINE=1','--env','NOVA_CANDIDATE_MODE=1']
for path,args in ((prod_out,prod),(canary_out,canary)):
    with open(path,'wb') as stream:
        for item in args: stream.write(str(item).encode()+b'\0')
PY
mapfile -d '' -t RUN_ARGS < "$ARGS_FILE"
mapfile -d '' -t CANARY_ARGS < "$CANARY_ARGS_FILE"
rm -f "$ARGS_FILE" "$CANARY_ARGS_FILE"

say "[5/10] 신규 이미지 빌드 + 전체 회귀검증"
CTX="$(mktemp -d /tmp/nova341-build.XXXXXX)"
DOCKER_BUILDKIT=1 docker build --no-cache -f "$DF" -t "$IMAGE" "$CTX"
IMG_VERSION="$(docker image inspect --format '{{index .Config.Labels "org.opencontainers.image.version"}}' "$IMAGE")"
MODE="$(docker image inspect --format '{{index .Config.Labels "io.quantnova.hybrid_discovery_v3"}}' "$IMAGE")"
DEPLOY_MODEL="$(docker image inspect --format '{{index .Config.Labels "io.quantnova.deploy_model"}}' "$IMAGE")"
[ "$IMG_VERSION" = "$EXPECTED_VERSION" ] || { echo "ERROR: image version mismatch: $IMG_VERSION"; exit 5; }
[ "$MODE" = "FULL_CUTOVER" ] || { echo "ERROR: V3 mode mismatch: $MODE"; exit 5; }
[ "$DEPLOY_MODEL" = "PRECUTOVER_CANARY_LIGHTSAIL_SAFE_CUTOVER" ] || { echo "ERROR: canary contract mismatch: $DEPLOY_MODEL"; exit 5; }
echo "IMAGE_CONTRACT=PASS"

say "[6/10] 격리 canary 시작 — 기존 컨테이너 계속 실행"
CANARY="${CURRENT}-canary-v341-${STAMP}"
docker run -d --name "$CANARY" "${CANARY_ARGS[@]}" "$IMAGE" >/dev/null
if ! wait_probe "$CANARY"; then
  echo "ERROR: 사전 canary 검증 실패. 기존 앱은 변경하지 않았습니다."
  docker logs --tail 180 "$CANARY" || true
  exit 6
fi
echo "PRECUTOVER_CANARY=PASS CURRENT_STILL_RUNNING=$CURRENT"
docker rm -f "$CANARY" >/dev/null
CANARY=""

say "[7/10] 기존 컨테이너 백업"
BACKUP="${CURRENT}-backup-v341-${STAMP}"
docker rename "$CURRENT" "$BACKUP"
docker stop "$BACKUP" >/dev/null
CUTOVER=1

say "[8/10] 검증된 이미지로 신규 실행"
if ! docker run -d --name "$CURRENT" "${RUN_ARGS[@]}" "$IMAGE" >/dev/null; then
  echo "ERROR: 신규 컨테이너 시작 실패"
  exit 7
fi

say "[9/10] 최종 HEALTH + VERSION + V3 + FRESH 계약 검증"
if ! wait_probe "$CURRENT"; then
  echo "ERROR: 신규 앱 최종 검증 실패"
  docker logs --tail 180 "$CURRENT" || true
  exit 8
fi
CUTOVER=0

say "[10/10] 배포 완료"
echo "RESULT=SUCCESS"
echo "VERSION=$EXPECTED_VERSION"
echo "CURRENT=$CURRENT"
echo "BACKUP=$BACKUP"
echo "IMAGE=$IMAGE"
echo "DOCKERFILE_SHA256=$ACTUAL_SHA"
docker ps --filter "name=^/${CURRENT}$" --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}'
