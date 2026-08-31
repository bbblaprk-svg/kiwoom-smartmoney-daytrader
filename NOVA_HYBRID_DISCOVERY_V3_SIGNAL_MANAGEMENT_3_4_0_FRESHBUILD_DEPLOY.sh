#!/usr/bin/env bash
set -Eeuo pipefail

DF_NAME="QUANT_NOVA_HYBRID_DISCOVERY_V3_SIGNAL_MANAGEMENT_3_4_0_FRESHBUILD.Dockerfile"
EXPECTED_SHA="470d56f5381032e3c58ddc2b999f593280edbe9ea3e65958e64e55de02ad6aab"
EXPECTED_VERSION="NOVA-HYBRID-DISCOVERY-V3-SIGNAL-MANAGEMENT-3.4.0-FRESHBUILD"
STAMP="$(date +%Y%m%d-%H%M%S)"
IMAGE="quant-nova:v3-signal340-freshbuild-${STAMP}"
BACKUP=""
CURRENT=""
CUTOVER=0

say(){ printf '\n%s\n' "$*"; }
exists(){ docker container inspect "$1" >/dev/null 2>&1; }
rollback(){
  set +e
  if [ "$CUTOVER" = 1 ] && [ -n "${CURRENT:-}" ] && [ -n "${BACKUP:-}" ] && exists "$BACKUP"; then
    exists "$CURRENT" && docker rm -f "$CURRENT" >/dev/null 2>&1 || true
    docker rename "$BACKUP" "$CURRENT" >/dev/null 2>&1 || true
    docker start "$CURRENT" >/dev/null 2>&1 || true
    echo "ROLLBACK=SUCCESS CURRENT=$CURRENT"
  fi
}
trap 'rc=$?; if [ "$rc" -ne 0 ]; then rollback; fi; exit "$rc"' ERR

say "===== NOVA V3 3.4.0 FRESHBUILD SAFE DEPLOY ====="
command -v docker >/dev/null 2>&1 || { echo "ERROR: docker not found"; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "ERROR: python3 not found"; exit 1; }
docker info >/dev/null 2>&1 || { echo "ERROR: docker daemon unavailable"; exit 1; }

say "[1/8] Dockerfile 검색"
DF="$(find /home/ubuntu "$HOME" /tmp -maxdepth 7 -type f -name "$DF_NAME" 2>/dev/null | head -1 || true)"
[ -n "$DF" ] || { echo "ERROR: $DF_NAME 파일을 찾지 못했습니다."; exit 2; }
echo "FOUND=$DF"

say "[2/8] SHA256 검증"
ACTUAL_SHA="$(sha256sum "$DF" | awk '{print $1}')"
echo "EXPECTED=$EXPECTED_SHA"
echo "ACTUAL  =$ACTUAL_SHA"
[ "$ACTUAL_SHA" = "$EXPECTED_SHA" ] || { echo "ERROR: Dockerfile SHA256 불일치. 기존 앱은 변경하지 않았습니다."; exit 3; }
echo "SHA256=PASS"

say "[3/8] 현재 NOVA 컨테이너 탐색"
for preferred in kiwoom-smartmoney quant-nova; do
  if exists "$preferred" && [ "$(docker inspect -f '{{.State.Running}}' "$preferred" 2>/dev/null || true)" = "true" ]; then
    CURRENT="$preferred"; break
  fi
done
if [ -z "$CURRENT" ]; then
  for c in $(docker ps --format '{{.Names}}'); do
    if docker exec "$c" python - <<'PY' >/dev/null 2>&1
import json,sys,urllib.request
try:
    j=json.load(urllib.request.urlopen('http://127.0.0.1:8000/api/livez',timeout=2))
    sys.exit(0 if j.get('ok') else 1)
except Exception:
    sys.exit(1)
PY
    then CURRENT="$c"; break; fi
  done
fi
[ -n "$CURRENT" ] || { docker ps; echo "ERROR: 실행 중 NOVA 컨테이너를 찾지 못했습니다."; exit 4; }
echo "CURRENT=$CURRENT"

say "[4/8] 현재 컨테이너 실행계약 저장"
INSPECT="$(mktemp /tmp/nova340-inspect.XXXXXX.json)"
docker inspect "$CURRENT" > "$INSPECT"
ARGS_FILE="$(mktemp /tmp/nova340-args.XXXXXX)"
python3 - "$INSPECT" "$ARGS_FILE" <<'PY'
import json,sys
src,out=sys.argv[1:]
j=json.load(open(src))[0]
c=j.get('Config') or {}; h=j.get('HostConfig') or {}
a=[]
for e in c.get('Env') or []: a += ['--env',e]
seen=set()
for b in h.get('Binds') or []:
    a += ['--volume',b]
    p=b.split(':')
    if len(p)>1: seen.add(p[1])
for m in j.get('Mounts') or []:
    dst=m.get('Destination') or ''
    if not dst or dst in seen: continue
    typ=m.get('Type') or 'volume'; srcv=m.get('Name') or m.get('Source') or ''
    spec=[f'type={typ}']
    if srcv: spec.append(f'source={srcv}')
    spec.append(f'target={dst}')
    if not m.get('RW',True): spec.append('readonly')
    a += ['--mount',','.join(spec)]
for dst,opt in (h.get('Tmpfs') or {}).items(): a += ['--tmpfs', dst + (':' + opt if opt else '')]
net=h.get('NetworkMode') or ''
if net and net not in ('default','bridge'): a += ['--network',net]
if net not in ('host','none'):
    for private,bs in (h.get('PortBindings') or {}).items():
        for b in bs or []:
            hp=(b.get('HostPort') or '').strip(); hi=(b.get('HostIp') or '').strip()
            if hp: a += ['--publish', (hi+':' if hi else '') + hp + ':' + private]
rp=h.get('RestartPolicy') or {}; rn=rp.get('Name') or ''
if rn:
    val=rn; n=int(rp.get('MaximumRetryCount') or 0)
    if rn=='on-failure' and n: val += ':'+str(n)
    a += ['--restart',val]
mem=int(h.get('Memory') or 0)
if mem>0: a += ['--memory',str(mem)]
nano=int(h.get('NanoCpus') or 0)
if nano>0: a += ['--cpus',str(nano/1_000_000_000)]
with open(out,'wb') as f:
    for x in a: f.write(str(x).encode()+b'\0')
PY
mapfile -d '' -t RUN_ARGS < "$ARGS_FILE"
rm -f "$ARGS_FILE"

say "[5/8] 신규 이미지 빌드 + Dockerfile 내 전체 회귀검증"
CTX="$(mktemp -d /tmp/nova340-build.XXXXXX)"
trap 'rm -rf "$CTX" "$INSPECT" >/dev/null 2>&1 || true' EXIT
DOCKER_BUILDKIT=1 docker build --no-cache -f "$DF" -t "$IMAGE" "$CTX"

IMG_VERSION="$(docker image inspect --format '{{index .Config.Labels "org.opencontainers.image.version"}}' "$IMAGE")"
MODE="$(docker image inspect --format '{{index .Config.Labels "io.quantnova.hybrid_discovery_v3"}}' "$IMAGE")"
SIG="$(docker image inspect --format '{{index .Config.Labels "io.quantnova.signal_management"}}' "$IMAGE")"
PN="$(docker image inspect --format '{{index .Config.Labels "io.quantnova.primary_next_ui"}}' "$IMAGE")"
[ "$IMG_VERSION" = "$EXPECTED_VERSION" ] || { echo "ERROR: image version mismatch: $IMG_VERSION"; exit 5; }
[ "$MODE" = "FULL_CUTOVER" ] || { echo "ERROR: V3 mode mismatch: $MODE"; exit 5; }
[ "$SIG" = "5_TRADING_DAYS_VIEW20_MAX1000" ] || { echo "ERROR: signal management contract mismatch: $SIG"; exit 5; }
[ "$PN" = "HIDDEN_VERIFY_ONLY" ] || { echo "ERROR: PRIMARY/NEXT contract mismatch: $PN"; exit 5; }
echo "IMAGE_CONTRACT=PASS"

say "[6/8] 기존 컨테이너 백업 후 신규 실행"
BACKUP="${CURRENT}-backup-v340-${STAMP}"
docker rename "$CURRENT" "$BACKUP"
docker stop "$BACKUP" >/dev/null
CUTOVER=1
if ! docker run -d --name "$CURRENT" "${RUN_ARGS[@]}" "$IMAGE" >/dev/null; then
  echo "ERROR: 신규 컨테이너 시작 실패"
  rollback
  exit 6
fi

say "[7/8] 신규 앱 HEALTH + VERSION + V3 검증"
OK=0
for _ in $(seq 1 60); do
  if docker exec "$CURRENT" python - "$EXPECTED_VERSION" <<'PY' >/dev/null 2>&1
import json,sys,urllib.request
ver=sys.argv[1]
def get(p): return json.load(urllib.request.urlopen('http://127.0.0.1:8000'+p,timeout=3))
try:
    live=get('/api/livez'); version=get('/api/version'); v3=get('/api/hybrid-discovery-v3'); pe=get('/api/precision-edge')
    assert live.get('ok')
    assert version.get('version')==ver
    assert v3.get('mode')=='FULL_CUTOVER' and v3.get('official_cutover') is True
    assert v3.get('broker_calls_added')==0 and v3.get('ws_types_added')==0
    assert isinstance(pe.get('ledger'),list)
    sys.exit(0)
except Exception:
    sys.exit(1)
PY
  then OK=1; break; fi
  sleep 2
done
if [ "$OK" != 1 ]; then
  echo "ERROR: 신규 앱 최종 검증 실패"
  docker logs --tail 180 "$CURRENT" || true
  rollback
  exit 7
fi
CUTOVER=0

say "[8/8] 배포 완료"
echo "RESULT=SUCCESS"
echo "VERSION=$EXPECTED_VERSION"
echo "CURRENT=$CURRENT"
echo "BACKUP=$BACKUP"
echo "IMAGE=$IMAGE"
echo "DOCKERFILE_SHA256=$ACTUAL_SHA"
docker ps --filter "name=^/${CURRENT}$" --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}'
