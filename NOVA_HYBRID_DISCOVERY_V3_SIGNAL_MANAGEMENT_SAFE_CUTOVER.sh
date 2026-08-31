#!/usr/bin/env bash
set -Eeuo pipefail

PRODUCT='NOVA HYBRID DISCOVERY V3 · SIGNAL MANAGEMENT 5D'
VERSION='NOVA-HYBRID-DISCOVERY-V3-SIGNAL-MANAGEMENT-3.3.1'
CURRENT_CONTAINER="${NOVA_CURRENT_CONTAINER:-quant-nova}"
DOCKERFILE_NAME='QUANT_NOVA_HYBRID_DISCOVERY_V3_SIGNAL_MANAGEMENT_3_3_1.Dockerfile'
EXPECTED_DOCKERFILE_SHA256='686994a483067f181a1c3a36d8706446cc97c9b13da7a517567c005971e7b61f'
MIN_FREE_MB="${NOVA_MIN_FREE_MB:-5120}"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
DOCKERFILE="${SCRIPT_DIR}/${DOCKERFILE_NAME}"
STAMP="$(date -u +%Y%m%d-%H%M%S)"
IMAGE_TAG="quant-nova:hybrid-v3-signal5d-${STAMP}"
BACKUP_CONTAINER="quant-nova-backup-hybrid-v3-signal5d-${STAMP}"
CANARY_CONTAINER="quant-nova-canary-hybrid-v3-signal5d-${STAMP}"
CUTOVER_STARTED=0
BUILD_CONTEXT=''

say(){ printf '%s\n' "$*"; }
exists(){ docker container inspect "$1" >/dev/null 2>&1; }
cleanup(){
  exists "${CANARY_CONTAINER}" && docker rm -f "${CANARY_CONTAINER}" >/dev/null 2>&1 || true
  [[ -n "${BUILD_CONTEXT}" && -d "${BUILD_CONTEXT}" ]] && rmdir "${BUILD_CONTEXT}" 2>/dev/null || true
}
rollback(){
  local cause="$1"; set +e
  say "AUTO_ROLLBACK_CAUSE=${cause}"
  exists "${CURRENT_CONTAINER}" && docker rm -f "${CURRENT_CONTAINER}" >/dev/null 2>&1 || true
  if exists "${BACKUP_CONTAINER}"; then docker rename "${BACKUP_CONTAINER}" "${CURRENT_CONTAINER}" >/dev/null && docker start "${CURRENT_CONTAINER}" >/dev/null; fi
  say "RESULT=ROLLED_BACK"
}
die(){ local m="$*"; say "ERROR: ${m}"; [[ "${CUTOVER_STARTED}" == 1 ]] && rollback "${m}"; cleanup; exit 1; }
on_error(){ local rc=$?; [[ "${CUTOVER_STARTED}" == 1 ]] && rollback "line=${BASH_LINENO[0]:-?} rc=${rc}"; cleanup; exit "$rc"; }
trap on_error ERR
trap cleanup EXIT

say "===== ${PRODUCT} SAFE CUTOVER ====="
[[ -f "${DOCKERFILE}" ]] || die "missing ${DOCKERFILE_NAME}"
command -v docker >/dev/null || die 'docker not found'
command -v python3 >/dev/null || die 'python3 not found'
docker info >/dev/null 2>&1 || die 'docker daemon unavailable'
exists "${CURRENT_CONTAINER}" || die "current container not found: ${CURRENT_CONTAINER}"
ACTUAL_SHA="$(sha256sum "${DOCKERFILE}" | awk '{print $1}')"
[[ "${ACTUAL_SHA}" == "${EXPECTED_DOCKERFILE_SHA256}" ]] || die "Dockerfile checksum mismatch ${ACTUAL_SHA}"
FREE_MB="$(df -Pm "${SCRIPT_DIR}" | awk 'NR==2{print $4}')"
(( FREE_MB >= MIN_FREE_MB )) || die "free disk ${FREE_MB}MB < ${MIN_FREE_MB}MB"

OLD_IMAGE="$(docker inspect --format '{{.Image}}' "${CURRENT_CONTAINER}")"
[[ "$(docker inspect --format '{{.State.Running}}' "${CURRENT_CONTAINER}")" == true ]] || die 'current container is not running'

mapfile -d '' -t PRESERVED_ARGS < <(docker inspect "${CURRENT_CONTAINER}" | python3 -c '
import json,sys
j=json.load(sys.stdin)[0]; c=j.get("Config") or {}; h=j.get("HostConfig") or {}; args=[]
for v in c.get("Env") or []: args += ["--env",v]
seen=set()
for v in h.get("Binds") or []:
    args += ["--volume",v]; parts=v.split(":");
    if len(parts)>1: seen.add(parts[1])
for m in j.get("Mounts") or []:
    target=m.get("Destination") or ""
    if not target or target in seen: continue
    typ=m.get("Type") or "volume"; src=m.get("Name") or m.get("Source") or ""; spec=[f"type={typ}"]
    if src: spec.append(f"source={src}")
    spec.append(f"target={target}")
    if not m.get("RW",True): spec.append("readonly")
    args += ["--mount",",".join(spec)]
for target,opts in (h.get("Tmpfs") or {}).items(): args += ["--tmpfs",target+(":"+opts if opts else "")]
for private,bindings in (h.get("PortBindings") or {}).items():
    for b in bindings or []:
        hp=(b.get("HostPort") or "").strip(); hi=(b.get("HostIp") or "").strip(); prefix=(hi+":" if hi else "")
        if hp: args += ["--publish",f"{prefix}{hp}:{private}"]
net=h.get("NetworkMode") or ""
if net and net not in ("default","bridge"): args += ["--network",net]
rp=h.get("RestartPolicy") or {}; name=rp.get("Name") or ""
if name:
    val=name
    if name=="on-failure" and int(rp.get("MaximumRetryCount") or 0)>0: val += ":"+str(rp["MaximumRetryCount"])
    args += ["--restart",val]
for x in args: sys.stdout.buffer.write(str(x).encode()+b"\0")
')

mapfile -d '' -t CANARY_ARGS < <(docker inspect "${CURRENT_CONTAINER}" | python3 -c '
import json,sys
j=json.load(sys.stdin)[0]; c=j.get("Config") or {}; h=j.get("HostConfig") or {}; args=[]
for v in c.get("Env") or []: args += ["--env",v]
seen=set()
for v in h.get("Binds") or []:
    args += ["--volume",v]; parts=v.split(":")
    if len(parts)>1: seen.add(parts[1])
for m in j.get("Mounts") or []:
    target=m.get("Destination") or ""
    if not target or target in seen: continue
    typ=m.get("Type") or "volume"; src=m.get("Name") or m.get("Source") or ""; spec=[f"type={typ}"]
    if src: spec.append(f"source={src}")
    spec.append(f"target={target}")
    if not m.get("RW",True): spec.append("readonly")
    args += ["--mount",",".join(spec)]
for target,opts in (h.get("Tmpfs") or {}).items(): args += ["--tmpfs",target+(":"+opts if opts else "")]
for x in args: sys.stdout.buffer.write(str(x).encode()+b"\0")
')

BUILD_CONTEXT="$(mktemp -d -t nova-v3-build.XXXXXX)"
say "BUILD_START old_image=${OLD_IMAGE}"
nice -n 10 env DOCKER_BUILDKIT=1 docker build --pull --no-cache -f "${DOCKERFILE}" -t "${IMAGE_TAG}" "${BUILD_CONTEXT}"
[[ "$(docker image inspect --format '{{index .Config.Labels "org.opencontainers.image.version"}}' "${IMAGE_TAG}")" == "${VERSION}" ]] || die 'version label mismatch'
[[ "$(docker image inspect --format '{{index .Config.Labels "io.quantnova.hybrid_discovery_v3"}}' "${IMAGE_TAG}")" == 'FULL_CUTOVER' ]] || die 'V3 full-cutover label mismatch'
[[ "$(docker image inspect --format '{{index .Config.Labels "io.quantnova.hybrid_v3_venue_isolation"}}' "${IMAGE_TAG}")" == 'KRX_NXT_INDEPENDENT_CROSS_COMPARE_ONLY' ]] || die 'venue isolation label mismatch'
[[ "$(docker image inspect --format '{{index .Config.Labels "io.quantnova.new_broker_calls"}}' "${IMAGE_TAG}")" == 0 ]] || die 'new broker call contract mismatch'
[[ "$(docker image inspect --format '{{index .Config.Labels "io.quantnova.signal_management"}}' "${IMAGE_TAG}")" == '5_TRADING_DAYS_VIEW20_MAX1000' ]] || die 'signal management label mismatch'
[[ "$(docker image inspect --format '{{index .Config.Labels "io.quantnova.primary_next_ui"}}' "${IMAGE_TAG}")" == 'HIDDEN_VERIFY_ONLY' ]] || die 'primary/next UI contract mismatch'

# Canary has no published host port and therefore cannot collide with production.
docker run -d --name "${CANARY_CONTAINER}" --memory 768m --cpus 0.85 "${CANARY_ARGS[@]}" --network bridge "${IMAGE_TAG}" >/dev/null
for _ in $(seq 1 30); do
  IP="$(docker inspect -f '{{range.NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "${CANARY_CONTAINER}")"
  if [[ -n "$IP" ]] && python3 - "$IP" <<'PY'
import json,sys,urllib.request
ip=sys.argv[1]
try:
    j=json.load(urllib.request.urlopen(f'http://{ip}:8000/api/livez',timeout=2));sys.exit(0 if j.get('ok') else 1)
except Exception:sys.exit(1)
PY
  then break; fi
  sleep 2
done
IP="$(docker inspect -f '{{range.NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "${CANARY_CONTAINER}")"
python3 - "$IP" "$VERSION" <<'PY' || exit 41
import json,sys,urllib.request
ip,version=sys.argv[1:]
def get(path): return json.load(urllib.request.urlopen(f'http://{ip}:8000{path}',timeout=4))
v=get('/api/version'); assert v.get('version')==version,v
h=get('/api/hybrid-discovery-v3'); assert h.get('ok') and h.get('mode')=='FULL_CUTOVER',h
assert h.get('official_cutover') is True
assert h.get('broker_calls_added')==0 and h.get('ws_types_added')==0
assert h.get('contracts',{}).get('venue_separation') is True
print('CANARY_HYBRID_V3_FULL=PASS')
PY

docker rm -f "${CANARY_CONTAINER}" >/dev/null
CUTOVER_STARTED=1
docker rename "${CURRENT_CONTAINER}" "${BACKUP_CONTAINER}"
docker stop "${BACKUP_CONTAINER}" >/dev/null
# Remove old published args conflicts are gone now; preserve production args exactly.
docker run -d --name "${CURRENT_CONTAINER}" --memory 768m --cpus 0.85 "${PRESERVED_ARGS[@]}" "${IMAGE_TAG}" >/dev/null
for _ in $(seq 1 35); do
  if docker exec "${CURRENT_CONTAINER}" python - <<'PY' >/dev/null 2>&1
import json,urllib.request,sys
try:
 j=json.load(urllib.request.urlopen('http://127.0.0.1:8000/api/livez',timeout=2));sys.exit(0 if j.get('ok') else 1)
except Exception:sys.exit(1)
PY
  then break; fi
  sleep 2
done

docker exec "${CURRENT_CONTAINER}" python - <<'PY' || die 'post-cutover V3 API validation failed'
import json,urllib.request
v=json.load(urllib.request.urlopen('http://127.0.0.1:8000/api/version',timeout=3))
h=json.load(urllib.request.urlopen('http://127.0.0.1:8000/api/hybrid-discovery-v3',timeout=3))
assert v.get('version')=='NOVA-HYBRID-DISCOVERY-V3-SIGNAL-MANAGEMENT-3.3.1',v
assert h.get('mode')=='FULL_CUTOVER' and h.get('official_cutover') is True,h
assert h.get('broker_calls_added')==0 and h.get('ws_types_added')==0,h
print('POST_CUTOVER_HYBRID_V3_FULL=PASS')
PY
CUTOVER_STARTED=0
say "RESULT=SUCCESS CURRENT=${CURRENT_CONTAINER} BACKUP=${BACKUP_CONTAINER} VERSION=${VERSION}"
