#!/usr/bin/env bash
# Revision: PHASE2-RESYNC-FAIRNESS-FIX1
set -Eeuo pipefail

PRODUCT='NOVA PRECISION EDGE X1 PHASE2'
VERSION='NOVA-PRECISION-EDGE-X1-PHASE2-2.0.1'
CURRENT_CONTAINER="${NOVA_CURRENT_CONTAINER:-quant-nova}"
DOCKERFILE_NAME='QUANT_NOVA_PRECISION_EDGE_X1_PHASE2.Dockerfile'
EXPECTED_DOCKERFILE_SHA256='ec2e0b1b2cfa1205d2ab11b2d95d54042c163e80f15dddac6910610154c159f2'
MIN_FREE_MB="${NOVA_MIN_FREE_MB:-5120}"
CONTAINER_MEMORY="${NOVA_CONTAINER_MEMORY:-768m}"
CONTAINER_CPUS="${NOVA_CONTAINER_CPUS:-0.85}"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
DOCKERFILE="${SCRIPT_DIR}/${DOCKERFILE_NAME}"
STAMP="$(date -u +%Y%m%d-%H%M%S)"
IMAGE_TAG="quant-nova:precision-edge-x1-phase2-${STAMP}"
BACKUP_CONTAINER="quant-nova-backup-precision-edge-x1-phase2-${STAMP}"
CANARY_CONTAINER="quant-nova-canary-precision-edge-x1-phase2-${STAMP}"
BUILD_CONTEXT=''
CUTOVER_STARTED=0

say(){ printf '%s\n' "$*"; }
die(){
  say "ERROR: $*"
  if [[ "${CUTOVER_STARTED}" == 1 ]]; then rollback 'explicit validation failure';CUTOVER_STARTED=0; fi
  cleanup
  exit 1
}
exists(){ docker container inspect "$1" >/dev/null 2>&1; }

cleanup(){
  if exists "${CANARY_CONTAINER}"; then
    docker rm --force "${CANARY_CONTAINER}" >/dev/null 2>&1 || true
  fi
  if [[ -n "${BUILD_CONTEXT}" && -d "${BUILD_CONTEXT}" ]]; then
    rmdir "${BUILD_CONTEXT}" 2>/dev/null || true
  fi
}

rollback(){
  local cause="$1"
  set +e
  say "AUTO_ROLLBACK_CAUSE=${cause}"
  if exists "${CURRENT_CONTAINER}"; then
    docker rm --force "${CURRENT_CONTAINER}" >/dev/null 2>&1 || true
  fi
  if exists "${BACKUP_CONTAINER}"; then
    docker rename "${BACKUP_CONTAINER}" "${CURRENT_CONTAINER}" >/dev/null &&
      docker start "${CURRENT_CONTAINER}" >/dev/null
  fi
  say "RESULT=ROLLED_BACK CURRENT=${CURRENT_CONTAINER} BACKUP_SOURCE=${BACKUP_CONTAINER}"
}

on_error(){
  local rc=$?
  local line="${BASH_LINENO[0]:-unknown}"
  if [[ "${CUTOVER_STARTED}" == 1 ]]; then rollback "line=${line} rc=${rc}"; fi
  cleanup
  exit "${rc}"
}
trap on_error ERR
trap cleanup EXIT

say "===== ${PRODUCT} SAFE CUTOVER ====="
[[ -f "${DOCKERFILE}" ]] || die "missing exact file: ${DOCKERFILE}"
command -v docker >/dev/null || die 'docker command not found'
command -v python3 >/dev/null || die 'python3 command not found'
command -v sha256sum >/dev/null || die 'sha256sum command not found'
docker info >/dev/null 2>&1 || die 'docker permission denied or daemon unavailable'
exists "${CURRENT_CONTAINER}" || die "current container not found: ${CURRENT_CONTAINER}"

ACTUAL_SHA="$(sha256sum "${DOCKERFILE}" | awk '{print $1}')"
[[ "${ACTUAL_SHA}" == "${EXPECTED_DOCKERFILE_SHA256}" ]] ||
  die "Dockerfile checksum mismatch: ${ACTUAL_SHA}"
FREE_MB="$(df -Pm "${SCRIPT_DIR}" | awk 'NR==2{print $4}')"
[[ "${FREE_MB}" =~ ^[0-9]+$ ]] || die 'could not determine free disk'
(( FREE_MB >= MIN_FREE_MB )) ||
  die "free disk ${FREE_MB}MB is below required ${MIN_FREE_MB}MB; no change made"

OLD_IMAGE="$(docker inspect --format '{{.Image}}' "${CURRENT_CONTAINER}")"
OLD_RUNNING="$(docker inspect --format '{{.State.Running}}' "${CURRENT_CONTAINER}")"
[[ "${OLD_RUNNING}" == 'true' ]] || die "current container is not running: ${CURRENT_CONTAINER}"
mapfile -d '' -t PRESERVED_ARGS < <(
  docker inspect "${CURRENT_CONTAINER}" | python3 -c '
import json,sys
j=json.load(sys.stdin)[0]; c=j.get("Config") or {}; h=j.get("HostConfig") or {}
args=[]
for value in c.get("Env") or []: args += ["--env",value]
bind_targets=set()
for value in h.get("Binds") or []:
    args += ["--volume",value]
    parts=value.split(":")
    if len(parts)>1: bind_targets.add(parts[1])
for m in j.get("Mounts") or []:
    target=m.get("Destination") or ""
    if not target or target in bind_targets: continue
    typ=m.get("Type") or "volume"; source=m.get("Name") or m.get("Source") or ""
    spec=[f"type={typ}"]
    if source: spec.append(f"source={source}")
    spec.append(f"target={target}")
    if not m.get("RW",True): spec.append("readonly")
    args += ["--mount",",".join(spec)]
for target,opts in (h.get("Tmpfs") or {}).items(): args += ["--tmpfs",target+(":"+opts if opts else "")]
for private,bindings in (h.get("PortBindings") or {}).items():
    for b in bindings or []:
        host=(b.get("HostIp") or "").strip(); port=(b.get("HostPort") or "").strip()
        prefix=(f"[{host}]:" if ":" in host else f"{host}:") if host else ""
        args += ["--publish",f"{prefix}{port}:{private}"]
network=h.get("NetworkMode") or ""
if network and network not in ("default","bridge"): args += ["--network",network]
rp=h.get("RestartPolicy") or {}; name=rp.get("Name") or ""
if name:
    value=name
    if name=="on-failure" and int(rp.get("MaximumRetryCount") or 0)>0: value+=":"+str(rp["MaximumRetryCount"])
    args += ["--restart",value]
if h.get("ReadonlyRootfs"): args.append("--read-only")
for cap in h.get("CapAdd") or []: args += ["--cap-add",cap]
for cap in h.get("CapDrop") or []: args += ["--cap-drop",cap]
for value in args: sys.stdout.buffer.write(str(value).encode()+b"\0")
'
)

BUILD_CONTEXT="$(mktemp -d -t nova-precision-x1-phase2-build.XXXXXX)"
say "PREFLIGHT=PASS FREE_MB=${FREE_MB} OLD_IMAGE=${OLD_IMAGE}"
if command -v ionice >/dev/null; then
  ionice -c 2 -n 7 nice -n 10 env DOCKER_BUILDKIT=1 \
    docker build --pull --no-cache --file "${DOCKERFILE}" --tag "${IMAGE_TAG}" "${BUILD_CONTEXT}"
else
  nice -n 10 env DOCKER_BUILDKIT=1 \
    docker build --pull --no-cache --file "${DOCKERFILE}" --tag "${IMAGE_TAG}" "${BUILD_CONTEXT}"
fi
[[ "$(docker image inspect --format '{{index .Config.Labels "org.opencontainers.image.version"}}' "${IMAGE_TAG}")" == "${VERSION}" ]] ||
  die 'built image version label mismatch'
[[ "$(docker image inspect --format '{{index .Config.Labels "io.quantnova.resync_fairness"}}' "${IMAGE_TAG}")" == 'MISSING_BASELINE_ONLY_LEAST_RECENT_ATTEMPT_BATCH12' ]] ||
  die 'built image resync fairness contract mismatch'
[[ "$(docker image inspect --format '{{index .Config.Labels "io.quantnova.partial_recovery_gate"}}' "${IMAGE_TAG}")" == 'READY_LANES_ALLOWED_WAITING_LANES_BLOCKED' ]] ||
  die 'built image partial recovery gate mismatch'

docker run --detach --name "${CANARY_CONTAINER}" \
  --memory 512m --memory-swap 512m --cpus 0.50 --pids-limit 192 \
  --log-driver local --log-opt max-size=10m --log-opt max-file=3 \
  --env NOVA_OFFLINE=1 \
  --env NOVA_PRECISION_EDGE_X1_ENABLED=1 \
  --env NOVA_PHASE2_CONFLUENCE_BONUS_ENABLED=0 \
  --env NOVA_WS_ORDERBOOK_CAP=4 \
  "${IMAGE_TAG}" >/dev/null
CANARY_HEALTH=''
for _ in $(seq 1 48); do
  CANARY_HEALTH="$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "${CANARY_CONTAINER}")"
  [[ "${CANARY_HEALTH}" == 'healthy' ]] && break
  [[ "${CANARY_HEALTH}" == 'unhealthy' || "${CANARY_HEALTH}" == 'exited' || "${CANARY_HEALTH}" == 'dead' ]] && false
  sleep 5
done
[[ "${CANARY_HEALTH}" == 'healthy' ]] || die "canary health timeout: ${CANARY_HEALTH}"
docker exec "${CANARY_CONTAINER}" python -c '
import json,urllib.request
live=json.load(urllib.request.urlopen("http://127.0.0.1:8000/api/livez",timeout=4))
edge=json.load(urllib.request.urlopen("http://127.0.0.1:8000/api/precision-edge",timeout=6))
assert live.get("ok") and edge.get("ok"), (live,edge)
assert edge.get("version")=="NOVA-PRECISION-EDGE-X1-PHASE2-2.0.1",edge
assert (edge.get("contracts") or {}).get("fixed_table_count")==4,edge
assert (edge.get("phase2") or {}).get("confluence_mode")=="DISPLAY_VERIFY_ONLY",edge
print("PHASE2_OFFLINE_CANARY=PASS")
'
docker rm --force "${CANARY_CONTAINER}" >/dev/null

CUTOVER_STARTED=1
docker stop --time 35 "${CURRENT_CONTAINER}" >/dev/null
docker rename "${CURRENT_CONTAINER}" "${BACKUP_CONTAINER}"
docker run --detach \
  --name "${CURRENT_CONTAINER}" \
  --memory "${CONTAINER_MEMORY}" --memory-swap "${CONTAINER_MEMORY}" \
  --cpus "${CONTAINER_CPUS}" --pids-limit 256 \
  --log-driver local --log-opt max-size=10m --log-opt max-file=3 \
  "${PRESERVED_ARGS[@]}" \
  --env NOVA_PRECISION_EDGE_X1_ENABLED=1 \
  --env NOVA_PHASE2_CONFLUENCE_BONUS_ENABLED=0 \
  --env NOVA_WS_ORDERBOOK_CAP=4 \
  "${IMAGE_TAG}" >/dev/null

HEALTH=''
for _ in $(seq 1 48); do
  HEALTH="$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "${CURRENT_CONTAINER}")"
  [[ "${HEALTH}" == 'healthy' ]] && break
  [[ "${HEALTH}" == 'unhealthy' || "${HEALTH}" == 'exited' || "${HEALTH}" == 'dead' ]] && false
  sleep 5
done
[[ "${HEALTH}" == 'healthy' ]] || die "health timeout: ${HEALTH}"

docker exec "${CURRENT_CONTAINER}" python -c '
import json,os,urllib.request
token=os.getenv("NOVA_UI_ACCESS_TOKEN","")
req=urllib.request.Request("http://127.0.0.1:8000/api/precision-edge")
if token:req.add_header("Authorization","Bearer "+token)
j=json.load(urllib.request.urlopen(req,timeout=6)); c=j.get("contracts") or {}
assert j.get("ok") and j.get("version")=="NOVA-PRECISION-EDGE-X1-PHASE2-2.0.1",j
assert c.get("fixed_table_ids")==["preignition","prebuy","nxt","pullback"],c
assert c.get("one_symbol_one_stage") and c.get("new_broker_rest_calls")==0,c
assert c.get("new_ws_subscription_types")==0 and not c.get("automatic_order"),c
assert c.get("nxt_new_entry_lock_kst")=="19:55",c
assert c.get("nxt_baseline_kst")=="15:40-18:30",c
assert c.get("max_realtime_analysis_symbols")==80 and c.get("focus_orderbook_symbols")==4,c
p=j.get("phase2") or {};assert p.get("enabled") and p.get("confluence_mode")=="DISPLAY_VERIFY_ONLY",p
assert not p.get("probability_display_enabled"),p
print("PRECISION_API_CONTRACT=PASS PHASE="+str(j.get("phase")))
'

ACTIVE_PHASE="$(docker exec "${CURRENT_CONTAINER}" python -c '
import json,os,urllib.request
token=os.getenv("NOVA_UI_ACCESS_TOKEN","")
req=urllib.request.Request("http://127.0.0.1:8000/api/precision-edge")
if token:req.add_header("Authorization","Bearer "+token)
j=json.load(urllib.request.urlopen(req,timeout=6));print(j.get("phase") or "")
')"
if [[ "${ACTIVE_PHASE}" == 'MORNING A+ SCOUT' || "${ACTIVE_PHASE}" == 'MORNING PRIMARY' ||
      "${ACTIVE_PHASE}" == 'MORNING RE-ACCEL ONLY' || "${ACTIVE_PHASE}" == 'NXT OBSERVE' ||
      "${ACTIVE_PHASE}" == 'NXT BASELINE' ||
      "${ACTIVE_PHASE}" == 'NXT READY' || "${ACTIVE_PHASE}" == 'NXT ENTRY' ||
      "${ACTIVE_PHASE}" == 'NXT A+ ONLY' ]]; then
  FEED_READY=0
  for _ in $(seq 1 36); do
    if docker exec "${CURRENT_CONTAINER}" python -c '
import json,os,sys,urllib.request
token=os.getenv("NOVA_UI_ACCESS_TOKEN","")
req=urllib.request.Request("http://127.0.0.1:8000/api/precision-edge")
if token:req.add_header("Authorization","Bearer "+token)
j=json.load(urllib.request.urlopen(req,timeout=6))
sys.exit(0 if (j.get("feed") or {}).get("decision_ready") else 1)
'; then FEED_READY=1; break; fi
    sleep 5
  done
  [[ "${FEED_READY}" == 1 ]] || die "active-session realtime feed did not become decision-ready: ${ACTIVE_PHASE}"
fi

CUTOVER_STARTED=0
trap - ERR
while IFS= read -r old_tag; do
  [[ -n "${old_tag}" && "${old_tag}" != "${IMAGE_TAG}" ]] || continue
  if [[ -z "$(docker ps -a --filter "ancestor=${old_tag}" --format '{{.ID}}')" ]]; then
    docker image rm "${old_tag}" >/dev/null 2>&1 || true
  fi
done < <(docker images 'quant-nova' --format '{{.Repository}}:{{.Tag}}' | awk '/^quant-nova:precision-edge-x1-phase2-[0-9]{8}-[0-9]{6}$/')
say "RESULT=DEPLOYED CURRENT=${CURRENT_CONTAINER} IMAGE=${IMAGE_TAG}"
say "BACKUP=${BACKUP_CONTAINER} OLD_IMAGE=${OLD_IMAGE}"
say "LIMITS=MEMORY:${CONTAINER_MEMORY} CPU:${CONTAINER_CPUS} LOG:10m_x_3"
say "MANUAL_ROLLBACK=./NOVA_PRECISION_EDGE_X1_PHASE2_MANUAL_ROLLBACK.sh ${BACKUP_CONTAINER}"
