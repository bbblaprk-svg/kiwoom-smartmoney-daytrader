#!/usr/bin/env bash
# Revision: PHASE2-CHART-FIX9-CLOSE1-3_0_1
set -Eeuo pipefail

PRODUCT='NOVA PRECISION EDGE X1 PHASE2 · CHART FIX9 CLOSE1'
VERSION='NOVA-PRECISION-EDGE-X1-PHASE2-CHART-FIX9-CLOSE1-3.0.1'
CURRENT_CONTAINER="${NOVA_CURRENT_CONTAINER:-quant-nova}"
DOCKERFILE_NAME='QUANT_NOVA_PRECISION_EDGE_X1_PHASE2_CHART_FIX9_CLOSE1.Dockerfile'
EXPECTED_DOCKERFILE_SHA256='9a9037ce724d976da71ba25b19a70e7c4d6df0dab472f523d9b226b23ac89ace'
MIN_FREE_MB="${NOVA_MIN_FREE_MB:-5120}"
CONTAINER_MEMORY="${NOVA_CONTAINER_MEMORY:-768m}"
CONTAINER_CPUS="${NOVA_CONTAINER_CPUS:-0.85}"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
DOCKERFILE="${SCRIPT_DIR}/${DOCKERFILE_NAME}"
STAMP="$(date -u +%Y%m%d-%H%M%S)"
IMAGE_TAG="quant-nova:precision-edge-x1-phase2-chart-fix9-close1-${STAMP}"
BACKUP_CONTAINER="quant-nova-backup-precision-edge-x1-phase2-chart-fix9-close1-${STAMP}"
CANARY_CONTAINER="quant-nova-canary-precision-edge-x1-phase2-chart-fix9-close1-${STAMP}"
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
DATA_MOUNT="$(docker inspect "${CURRENT_CONTAINER}" | python3 -c '
import json,sys
j=json.load(sys.stdin)[0]; target="/app/data/nova30"
for mount in j.get("Mounts") or []:
    destination=(mount.get("Destination") or "").rstrip("/")
    if destination and (target==destination or target.startswith(destination+"/")):
        print(destination);break
')"
[[ -n "${DATA_MOUNT}" ]] || die 'persistent mount covering /app/data/nova30 is required for restart/cutover close preservation'
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

BUILD_CONTEXT="$(mktemp -d -t nova-precision-x1-phase2-chart-fix9-close1-build.XXXXXX)"
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
[[ "$(docker image inspect --format '{{index .Config.Labels "io.quantnova.rank_delivery"}}' "${IMAGE_TAG}")" == 'CORE6_30S_CONFIRM2_FRESH4_10S_EVIDENCE2' ]] ||
  die 'built image CORE6/FRESH4 contract mismatch'
[[ "$(docker image inspect --format '{{index .Config.Labels "io.quantnova.ofi_mode"}}' "${IMAGE_TAG}")" == 'SNAPSHOT_PROXY_EVENT_ONLY_WITH_COMPLETE_SEQUENCE' ]] ||
  die 'built image OFI truth-label contract mismatch'
[[ "$(docker image inspect --format '{{index .Config.Labels "io.quantnova.action_now_rank"}}' "${IMAGE_TAG}")" == 'GRADE_THEN_COST_AWARE_REWARD_RISK_NOT_PROBABILITY' ]] ||
  die 'built image execution-value contract mismatch'
[[ "$(docker image inspect --format '{{index .Config.Labels "io.quantnova.ui_stability"}}' "${IMAGE_TAG}")" == 'OFFICIAL4_FIXED10_PLUS_CHART4_FIXED_10_5_10_10_TEXT_PATCH_ONLY' ]] ||
  die 'built image fixed 8-table UI contract mismatch'
[[ "$(docker image inspect --format '{{index .Config.Labels "io.quantnova.chart_score_formula"}}' "${IMAGE_TAG}")" == 'LS_1925_H3F24_FROZEN_THRESHOLDS_AND_RANK_WEIGHTS' ]] ||
  die 'built image chart score freeze contract mismatch'
[[ "$(docker image inspect --format '{{index .Config.Labels "io.quantnova.chart_close_restore"}}' "${IMAGE_TAG}")" == 'SERVER_PRIMARY10_NEXT10_UNIQUE20_BROWSER_RESTORE_REJECTED' ]] ||
  die 'built image strict close restore contract mismatch'
[[ "$(docker image inspect --format '{{index .Config.Labels "io.quantnova.chart_close_preserve"}}' "${IMAGE_TAG}")" == 'UNTIL_NEXT_TRADING_SESSION_FRESH_HANDOFF' ]] ||
  die 'built image after-hours preserve contract mismatch'
[[ "$(docker image inspect --format '{{index .Config.Labels "io.quantnova.official_close_preserve"}}' "${IMAGE_TAG}")" == 'OFF_WINDOW_RESTART_CUTOVER_UNTIL_FRESH_HANDOFF' ]] ||
  die 'built image official-board close preserve contract mismatch'
[[ "$(docker image inspect --format '{{index .Config.Labels "io.quantnova.market_index_close_preserve"}}' "${IMAGE_TAG}")" == 'SERVER_ATOMIC_SNAPSHOT_UNTIL_NEXT_FRESH_REFRESH' ]] ||
  die 'built image market-index close preserve contract mismatch'
[[ "$(docker image inspect --format '{{index .Config.Labels "io.quantnova.chart_close_bet_data_gate"}}' "${IMAGE_TAG}")" == 'TRADE_ORDERBOOK_PROGRAM_ALL_FRESH_COVERAGE100' ]] ||
  die 'built image close-bet data gate mismatch'
[[ "$(docker image inspect --format '{{index .Config.Labels "io.quantnova.chart_tranches"}}' "${IMAGE_TAG}")" == 'MANUAL_CONFIRMED_30_40_30_NO_SKIP' ]] ||
  die 'built image tranche state contract mismatch'

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
index=json.load(urllib.request.urlopen("http://127.0.0.1:8000/api/market-index-verify",timeout=6))
assert live.get("ok") and edge.get("ok") and index.get("ok"), (live,edge,index)
assert edge.get("version")=="NOVA-PRECISION-EDGE-X1-PHASE2-CHART-FIX9-CLOSE1-3.0.1",edge
assert edge.get("phase2_version")=="NOVA-PRECISION-EDGE-X1-PHASE2-2.1.0",edge
c=edge.get("contracts") or {}
assert c.get("fixed_table_count")==4 and c.get("fixed_rows_each")==10,c
assert c.get("pre_core_slots")==6 and c.get("pre_fresh_slots")==4,c
assert c.get("fresh_membership_commit_sec")==10,c
assert c.get("independent_source_family_gate")==2,c
assert c.get("event_ofi_claim_requires_complete_sequence"),c
assert c.get("action_now_uses_execution_value"),c
assert c.get("capture_rate_denominator")=="eligible discovered rank-universe; 60s sampled; no raw ticks",c
assert (edge.get("phase2") or {}).get("confluence_mode")=="DISPLAY_VERIFY_ONLY",edge
assert c.get("total_fixed_table_count")==8,c
assert c.get("additional_fixed_rows")=={"chart_nxt_early":10,"chart_nxt_close_bet":5,"chart_primary":10,"chart_next":10},c
chart=edge.get("chart_edge") or {};cc=chart.get("contracts") or {};layout=cc.get("layout") or {}
assert chart.get("version")=="NOVA-CHART-EDGE-LS1925-FIX9-1.0.0",chart
assert layout=={"nxtEarlyBuy":10,"nxtCloseBet":5,"primary":10,"next":10},layout
assert cc.get("scoreFormula")=="LS_1925_H3F24_FROZEN",cc
assert cc.get("thresholdsChanged") is False and cc.get("rankWeightsChanged") is False,cc
close=edge.get("close_preserve") or {}
assert close.get("server_authoritative") and close.get("lookahead_reselection") is False,close
assert (index.get("contracts") or {}).get("server_close_persisted"),index
print("PHASE2_CHART_FIX9_CLOSE1_OFFLINE_CANARY=PASS")
'
docker rm --force "${CANARY_CONTAINER}" >/dev/null

HANDOFF_RESULT="$(docker exec "${CURRENT_CONTAINER}" python -c '
import json,os,tempfile,time,urllib.request

def request(path):
    req=urllib.request.Request("http://127.0.0.1:8000"+path)
    token=os.getenv("NOVA_UI_ACCESS_TOKEN","")
    if token:req.add_header("Authorization","Bearer "+token)
    return json.load(urllib.request.urlopen(req,timeout=8))

def atomic(path,payload):
    os.makedirs(os.path.dirname(path),exist_ok=True)
    fd,tmp=tempfile.mkstemp(prefix=".cutover.",dir=os.path.dirname(path))
    try:
        with os.fdopen(fd,"w",encoding="utf-8") as stream:
            json.dump(payload,stream,ensure_ascii=False,separators=(",",":"));stream.flush();os.fsync(stream.fileno())
        os.replace(tmp,path)
    finally:
        if os.path.exists(tmp):os.unlink(tmp)

root=os.getenv("NOVA_DATA_DIR","/app/data/nova30")
edge=request("/api/precision-edge");boards=edge.get("boards") or {}
order=("prebuy","nxt","pullback","preignition")
rows={name:[row for row in (boards.get(name) or []) if isinstance(row,dict) and row.get("code")] for name in order}
codes=[str(row["code"]) for name in order for row in rows[name]]
assert codes and len(codes)==len(set(codes)) and all(len(rows[name])<=10 for name in order),(len(codes),rows.keys())
edge["close_preserve"]={"frozen":True,"mode":"SAFE_CUTOVER_HANDOFF","source_snapshot_at":float(edge.get("generated_at") or time.time()),"server_authoritative":True,"lookahead_reselection":False,"preserve_until":"NEXT_TRADING_SESSION_FRESH_HANDOFF"}
atomic(os.path.join(root,"precision_edge_cutover_handoff.json"),edge)
index_state="SKIPPED_NO_COMPLETE_MARKET"
try:
    index=request("/api/market-index-verify");markets=index.get("markets") or {}
    if all(float((markets.get(name) or {}).get("index") or 0)>0 for name in ("KOSPI","KOSDAQ")):
        atomic(os.path.join(root,"market_index_close.json"),{"version":1,"saved_at":time.time(),"last_success_at":index.get("last_success_at"),"markets":markets,"history":index.get("history") or [],"contracts":{"display_only":True,"rank_or_score_adjustment_applied":False,"preserve_until":"NEXT_TRADING_SESSION_FRESH_HANDOFF"}})
        index_state="SAVED"
except Exception as exc:
    index_state="SKIPPED_"+type(exc).__name__
print("OFFICIAL_ROWS="+str(len(codes))+" MARKET_INDEX="+index_state)
')"
say "CUTOVER_HANDOFF=PASS DATA_MOUNT=${DATA_MOUNT} ${HANDOFF_RESULT}"

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
assert j.get("ok") and j.get("version")=="NOVA-PRECISION-EDGE-X1-PHASE2-CHART-FIX9-CLOSE1-3.0.1",j
assert j.get("phase2_version")=="NOVA-PRECISION-EDGE-X1-PHASE2-2.1.0",j
assert c.get("fixed_table_ids")==["preignition","prebuy","nxt","pullback"],c
assert c.get("one_symbol_one_stage") and c.get("new_broker_rest_calls")==0,c
assert c.get("new_ws_subscription_types")==0 and not c.get("automatic_order"),c
assert c.get("nxt_new_entry_lock_kst")=="19:55",c
assert c.get("nxt_baseline_kst")=="15:40-18:30",c
assert c.get("max_realtime_analysis_symbols")==80 and c.get("focus_orderbook_symbols")==4,c
assert c.get("pre_core_slots")==6 and c.get("pre_fresh_slots")==4,c
assert c.get("fresh_membership_commit_sec")==10 and c.get("fresh_min_independent_evidence_families")==2,c
assert c.get("independent_source_family_gate")==2 and c.get("entry_requires_flow_or_price_structure"),c
assert c.get("event_ofi_claim_requires_complete_sequence") and c.get("liquidity_profiles_fixed_no_intraday_learning"),c
assert c.get("action_now_uses_execution_value") and c.get("sector_breadth_uses_full_existing_rank_union"),c
assert c.get("capture_rate_denominator")=="eligible discovered rank-universe; 60s sampled; no raw ticks",c
p=j.get("phase2") or {};assert p.get("enabled") and p.get("confluence_mode")=="DISPLAY_VERIFY_ONLY",p
assert not p.get("probability_display_enabled"),p
assert p.get("ofi_contract")=="SNAPSHOT OFI PROXY unless complete event sequence is explicitly proven",p
assert p.get("action_rank_contract")=="grade then fixed cost-aware reward/risk proxy; never probability",p
assert c.get("total_fixed_table_count")==8,c
assert c.get("additional_fixed_table_ids")==["chart_nxt_early","chart_nxt_close_bet","chart_primary","chart_next"],c
chart=j.get("chart_edge") or {};cc=chart.get("contracts") or {};layout=cc.get("layout") or {}
assert layout=={"nxtEarlyBuy":10,"nxtCloseBet":5,"primary":10,"next":10},layout
assert cc.get("scoreFormula")=="LS_1925_H3F24_FROZEN" and not cc.get("automaticOrder"),cc
assert (chart.get("closeMeta") or {}).get("browserRestoreAccepted") is False,chart
close=j.get("close_preserve") or {}
assert close.get("server_authoritative") and close.get("lookahead_reselection") is False,close
assert close.get("mode") in ("SESSION_CLOSE_FROZEN","CLOSE_HANDOFF_PENDING","LIVE_FRESH_HANDOFF","LEGACY_CLOSE_MIGRATED"),close
print("PRECISION_CHART_FIX9_CLOSE1_API_CONTRACT=PASS PHASE="+str(j.get("phase")))
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
done < <(docker images 'quant-nova' --format '{{.Repository}}:{{.Tag}}' | awk '/^quant-nova:precision-edge-x1-phase2-chart-fix9-close1-[0-9]{8}-[0-9]{6}$/')
say "RESULT=DEPLOYED CURRENT=${CURRENT_CONTAINER} IMAGE=${IMAGE_TAG}"
say "BACKUP=${BACKUP_CONTAINER} OLD_IMAGE=${OLD_IMAGE}"
say "LIMITS=MEMORY:${CONTAINER_MEMORY} CPU:${CONTAINER_CPUS} LOG:10m_x_3"
say "MANUAL_ROLLBACK=./NOVA_PRECISION_EDGE_X1_PHASE2_CHART_FIX9_CLOSE1_MANUAL_ROLLBACK.sh ${BACKUP_CONTAINER}"
