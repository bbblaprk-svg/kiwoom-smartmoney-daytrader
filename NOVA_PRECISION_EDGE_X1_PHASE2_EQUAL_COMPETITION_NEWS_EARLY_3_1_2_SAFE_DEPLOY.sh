#!/usr/bin/env bash
# NOVA PRECISION EDGE X1 PHASE2 · EQUAL COMPETITION + NEWS EARLY · 3.1.1
# Safe build/canary/cutover with automatic rollback. No runtime source patching.
set -Eeuo pipefail

PRODUCT='NOVA PRECISION EDGE X1 PHASE2 · EQUAL COMPETITION + NEWS EARLY · 3.1.1'
VERSION='NOVA-PRECISION-EDGE-X1-PHASE2-EQUAL-COMPETITION-NEWS-EARLY-3.1.2'
CURRENT_CONTAINER="${NOVA_CURRENT_CONTAINER:-quant-nova}"
DOCKERFILE_NAME='NOVA_PRECISION_EDGE_X1_PHASE2_EQUAL_COMPETITION_NEWS_EARLY_3_1_2.Dockerfile'
EXPECTED_DOCKERFILE_SHA256='c14902e30740e68706e224aad8376c23b23cbfe234db54368fe889f863800ce3'
MIN_FREE_MB="${NOVA_MIN_FREE_MB:-3072}"
CONTAINER_MEMORY="${NOVA_CONTAINER_MEMORY:-768m}"
CONTAINER_CPUS="${NOVA_CONTAINER_CPUS:-0.85}"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
DOCKERFILE="${SCRIPT_DIR}/${DOCKERFILE_NAME}"
STAMP="$(date -u +%Y%m%d-%H%M%S)"
IMAGE_TAG="quant-nova:equal-news-3-1-2-${STAMP}"
BACKUP_CONTAINER="quant-nova-backup-before-equal-news-3-1-2-${STAMP}"
CANARY_CONTAINER="quant-nova-canary-equal-news-3-1-2-${STAMP}"
BUILD_CONTEXT=''
CUTOVER_STARTED=0

say(){ printf '%s\n' "$*"; }
exists(){ docker container inspect "$1" >/dev/null 2>&1; }

cleanup(){
  set +e
  if exists "${CANARY_CONTAINER}"; then docker rm --force "${CANARY_CONTAINER}" >/dev/null 2>&1 || true; fi
  if [[ -n "${BUILD_CONTEXT}" && -d "${BUILD_CONTEXT}" ]]; then rm -rf "${BUILD_CONTEXT}" >/dev/null 2>&1 || true; fi
  set -e
}

rollback(){
  local cause="${1:-unknown}"
  set +e
  say "AUTO_ROLLBACK_CAUSE=${cause}"
  if exists "${CURRENT_CONTAINER}"; then docker rm --force "${CURRENT_CONTAINER}" >/dev/null 2>&1 || true; fi
  if exists "${BACKUP_CONTAINER}"; then
    docker rename "${BACKUP_CONTAINER}" "${CURRENT_CONTAINER}" >/dev/null 2>&1 || true
    for net in "${OLD_NETWORKS[@]:-}"; do
      [[ -n "$net" ]] && docker network connect "$net" "${CURRENT_CONTAINER}" >/dev/null 2>&1 || true
    done
    docker start "${CURRENT_CONTAINER}" >/dev/null 2>&1 || true
    for _ in $(seq 1 36); do
      h="$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "${CURRENT_CONTAINER}" 2>/dev/null || true)"
      [[ "${h}" == 'healthy' || "${h}" == 'running' ]] && break
      sleep 5
    done
  fi
  say "RESULT=ROLLED_BACK CURRENT=${CURRENT_CONTAINER} BACKUP_SOURCE=${BACKUP_CONTAINER}"
  set -e
}

fail(){
  local msg="$*"
  say "ERROR=${msg}"
  if [[ "${CUTOVER_STARTED}" == 1 ]]; then
    rollback "${msg}"
    CUTOVER_STARTED=0
  fi
  cleanup
  exit 1
}

on_error(){
  local rc=$?
  local line="${BASH_LINENO[0]:-unknown}"
  if [[ "${CUTOVER_STARTED}" == 1 ]]; then rollback "line=${line} rc=${rc}"; CUTOVER_STARTED=0; fi
  cleanup
  exit "${rc}"
}
trap on_error ERR
trap cleanup EXIT

say "===== ${PRODUCT} SAFE DEPLOY ====="
say "===== 1/8 PREFLIGHT ====="
[[ -f "${DOCKERFILE}" ]] || fail "Dockerfile missing: ${DOCKERFILE}"
command -v docker >/dev/null 2>&1 || fail 'docker command not found'
command -v python3 >/dev/null 2>&1 || fail 'python3 command not found'
command -v sha256sum >/dev/null 2>&1 || fail 'sha256sum command not found'
docker info >/dev/null 2>&1 || fail 'docker daemon unavailable or permission denied'
exists "${CURRENT_CONTAINER}" || fail "current container not found: ${CURRENT_CONTAINER}"
[[ "$(docker inspect --format '{{.State.Running}}' "${CURRENT_CONTAINER}")" == 'true' ]] || fail 'current quant-nova is not running'

ACTUAL_SHA="$(sha256sum "${DOCKERFILE}" | awk '{print $1}')"
[[ "${ACTUAL_SHA}" == "${EXPECTED_DOCKERFILE_SHA256}" ]] || fail "Dockerfile checksum mismatch: ${ACTUAL_SHA}"
FREE_MB="$(df -Pm "${SCRIPT_DIR}" | awk 'NR==2{print $4}')"
[[ "${FREE_MB}" =~ ^[0-9]+$ ]] || fail 'cannot determine free disk'
(( FREE_MB >= MIN_FREE_MB )) || fail "free disk ${FREE_MB}MB < required ${MIN_FREE_MB}MB"
OLD_IMAGE="$(docker inspect --format '{{.Image}}' "${CURRENT_CONTAINER}")"
OLD_VERSION="$(docker exec "${CURRENT_CONTAINER}" python -c 'from app.config import SETTINGS; print(SETTINGS.version)' 2>/dev/null || true)"
mapfile -t OLD_NETWORKS < <(docker inspect --format '{{range $k,$v := .NetworkSettings.Networks}}{{println $k}}{{end}}' "${CURRENT_CONTAINER}" | sed '/^$/d')
[[ ${#OLD_NETWORKS[@]} -gt 0 ]] || fail 'cannot determine current Docker networks'

# A persistent mount must cover NOVA_DATA_DIR so signal ledgers/frozen close survive image replacement.
DATA_MOUNT="$(docker inspect "${CURRENT_CONTAINER}" | python3 -c '
import json,sys
j=json.load(sys.stdin)[0]; target="/app/data/nova30"
for m in j.get("Mounts") or []:
    d=(m.get("Destination") or "").rstrip("/")
    if d and (target==d or target.startswith(d+"/")):
        print(d); break
')"
[[ -n "${DATA_MOUNT}" ]] || fail 'persistent mount covering /app/data/nova30 not found; no cutover performed'

# Rebuild docker run arguments from the live container: env, volumes, tmpfs, host port, network, restart policy, caps.
mapfile -d '' -t PRESERVED_ARGS < <(
  docker inspect "${CURRENT_CONTAINER}" | python3 -c '
import json,sys
j=json.load(sys.stdin)[0]; c=j.get("Config") or {}; h=j.get("HostConfig") or {}
args=[]
for v in c.get("Env") or []: args += ["--env",v]
bind_targets=set()
for v in h.get("Binds") or []:
    args += ["--volume",v]
    p=v.split(":")
    if len(p)>1: bind_targets.add(p[1])
for m in j.get("Mounts") or []:
    target=m.get("Destination") or ""
    if not target or target in bind_targets: continue
    typ=m.get("Type") or "volume"; source=m.get("Name") or m.get("Source") or ""
    spec=[f"type={typ}"]
    if source: spec.append(f"source={source}")
    spec.append(f"target={target}")
    if not m.get("RW",True): spec.append("readonly")
    args += ["--mount",",".join(spec)]
for target,opts in (h.get("Tmpfs") or {}).items(): args += ["--tmpfs", target + ((":"+opts) if opts else "")]
for private,bindings in (h.get("PortBindings") or {}).items():
    for b in bindings or []:
        host=(b.get("HostIp") or "").strip(); port=(b.get("HostPort") or "").strip()
        prefix=(f"[{host}]:" if ":" in host else f"{host}:") if host else ""
        args += ["--publish",f"{prefix}{port}:{private}"]
network=h.get("NetworkMode") or ""
if network and network not in ("default","bridge"): args += ["--network",network]
rp=h.get("RestartPolicy") or {}; name=rp.get("Name") or ""
if name:
    val=name
    if name=="on-failure" and int(rp.get("MaximumRetryCount") or 0)>0: val += ":"+str(rp["MaximumRetryCount"])
    args += ["--restart",val]
if h.get("ReadonlyRootfs"): args.append("--read-only")
for x in h.get("CapAdd") or []: args += ["--cap-add",x]
for x in h.get("CapDrop") or []: args += ["--cap-drop",x]
for x in args: sys.stdout.buffer.write(str(x).encode()+b"\0")
'
)
say "PREFLIGHT=PASS CURRENT_VERSION=${OLD_VERSION} FREE_MB=${FREE_MB} DATA_MOUNT=${DATA_MOUNT}"

say "===== 2/8 BUILD NEW IMAGE ====="
BUILD_CONTEXT="$(mktemp -d -t nova-equal-news-312-build.XXXXXX)"
if command -v ionice >/dev/null 2>&1; then
  ionice -c 2 -n 7 nice -n 10 env DOCKER_BUILDKIT=1 docker build --no-cache --file "${DOCKERFILE}" --tag "${IMAGE_TAG}" "${BUILD_CONTEXT}"
else
  nice -n 10 env DOCKER_BUILDKIT=1 docker build --no-cache --file "${DOCKERFILE}" --tag "${IMAGE_TAG}" "${BUILD_CONTEXT}"
fi
say "BUILD=PASS IMAGE=${IMAGE_TAG}"

say "===== 3/8 IMAGE CONTRACT ====="
label(){ docker image inspect --format "{{index .Config.Labels \"$1\"}}" "${IMAGE_TAG}"; }
[[ "$(label org.opencontainers.image.version)" == "${VERSION}" ]] || fail 'image version label mismatch'
[[ "$(label io.quantnova.package_model)" == 'SINGLE_DOCKERFILE_EMBEDDED_SOURCE' ]] || fail 'package model mismatch'
[[ "$(label io.quantnova.rank_delivery)" == 'EQUAL_CURRENT_EVIDENCE_FIXED10_30S_COMMIT_LIVE_ROW_VALUES' ]] || fail 'equal competition rank contract mismatch'
[[ "$(label io.quantnova.fresh_rotation)" == 'RETIRED_NO_TENURE_BIAS' ]] || fail 'tenure-bias retirement contract mismatch'
[[ "$(label io.quantnova.news_early_ignition)" == 'ISOLATED_NEWS_BRIDGE_PLUS_EXISTING_KIWOOM_DISPLAY_VERIFY_ONLY' ]] || fail 'news early isolation mismatch'
[[ "$(label io.quantnova.news_early_table)" == 'ONE_FIXED10_WATCH_READY_BUY_OVERHEAT' ]] || fail 'news early fixed10 contract mismatch'
[[ "$(label io.quantnova.news_early_rs)" == 'LISTING_INDEX_RS_ACCEL_10M' ]] || fail 'RS acceleration contract mismatch'
[[ "$(label io.quantnova.news_early_turnover)" == 'SAME_TIME_RATIO_10M_ACCEL_ABS' ]] || fail 'turnover acceleration contract mismatch'
[[ "$(label io.quantnova.news_early_signal_ledger)" == 'SQLITE_SIGNAL_PRICE_TIME' ]] || fail 'signal ledger contract mismatch'
[[ "$(label io.quantnova.data_source)" == 'EXISTING_KIWOOM_API_ONLY_NO_NEW_REST_OR_WS_TYPE' ]] || fail 'broker data-source contract mismatch'
[[ "$(label io.quantnova.strategy_scope)" == 'DECISION_SUPPORT_NO_AUTOMATIC_ORDER' ]] || fail 'automatic-order safety contract mismatch'
[[ "$(label io.quantnova.live_session_shell)" == 'ACTIVE_SESSION_NEVER_REPLACED_BY_PRIOR_CLOSE' ]] || fail 'live-session shell contract mismatch'
[[ "$(label io.quantnova.nxt_time_gate)" == 'HARD_1540_2000' ]] || fail 'NXT time gate mismatch'
[[ "$(label io.quantnova.signal_occurrence)" == 'DAY_VENUE_CODE_MEANINGFUL_STAGE_TRANSITIONS' ]] || fail 'signal occurrence contract mismatch'
[[ "$(label io.quantnova.chart_score_formula)" == 'LS_1925_H3F24_FROZEN_THRESHOLDS_AND_RANK_WEIGHTS' ]] || fail 'existing chart formula changed'
say 'IMAGE_CONTRACT=PASS'

say "===== 4/8 OFFLINE CANARY ====="
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
  [[ "${CANARY_HEALTH}" == 'unhealthy' || "${CANARY_HEALTH}" == 'exited' || "${CANARY_HEALTH}" == 'dead' ]] && fail "canary failed: ${CANARY_HEALTH}"
  sleep 5
done
[[ "${CANARY_HEALTH}" == 'healthy' ]] || fail "canary health timeout: ${CANARY_HEALTH}"

docker exec -i "${CANARY_CONTAINER}" python - <<'PY'
import json, urllib.request

def get(path):
    return json.load(urllib.request.urlopen('http://127.0.0.1:8000'+path, timeout=8))

def post(path,payload):
    req=urllib.request.Request('http://127.0.0.1:8000'+path,
        data=json.dumps(payload).encode(),headers={'Content-Type':'application/json'},method='POST')
    return json.load(urllib.request.urlopen(req,timeout=8))

live=get('/api/livez')
edge=get('/api/precision-edge')
news=get('/api/news-early-ignition')
html=urllib.request.urlopen('http://127.0.0.1:8000/',timeout=8).read().decode('utf-8','replace')
assert live.get('ok'), live
assert edge.get('ok'), edge
assert edge.get('version')=='NOVA-PRECISION-EDGE-X1-PHASE2-EQUAL-COMPETITION-NEWS-EARLY-3.1.2', edge.get('version')
c=edge.get('contracts') or {}
assert c.get('fixed_rows_each')==10, c
assert c.get('membership_commit_sec')==30, c
assert c.get('membership_policy')=='EQUAL_CURRENT_EVIDENCE_NO_CORE_FRESH_ANCHOR_PRIVILEGE', c
assert c.get('row_values_live_continuous') is True, c
assert c.get('min_dwell_sec')==0 and c.get('move_score_gap')==0, c
assert c.get('new_broker_rest_calls')==0 and c.get('new_ws_subscription_types')==0, c
assert c.get('automatic_order') is False, c
nc=news.get('contracts') or {}
assert news.get('ok') and nc.get('table_rows')==10, news
assert nc.get('official_pre_buy_changed') is False and nc.get('official_entry_buy_changed') is False, nc
assert nc.get('broker_rest_changed') is False and nc.get('broker_ws_changed') is False, nc
assert nc.get('automatic_order') is False and nc.get('signal_price_recorded') is True, nc
assert 'NEWS EARLY-IGNITION · MONEY + RS ACCEL TOP10' in html
assert 'news_early_rows' in html
assert '19:55 신규진입 잠금' in html
assert '지금 볼 순서' in html
p=post('/api/news-early-ignition/event',{
    'code':'005930','headline':'CANARY NEWS EARLY IGNITION CHECK','source':'CANARY',
    'relevance':92
})
assert p.get('ok') and p.get('count')==1, p
print('CANARY_API_CONTRACT=PASS')
PY

docker rm --force "${CANARY_CONTAINER}" >/dev/null
say 'CANARY=PASS'

say "===== 5/8 CUTOVER PREP ====="
# Persist the current API snapshot into the already-mounted data directory before stopping.
# Failure to capture is non-fatal because the persistent store itself is not replaced.
HANDOFF_RESULT="$(docker exec -i "${CURRENT_CONTAINER}" python - <<'PY' 2>/dev/null || true
import json, os, tempfile, time, urllib.request
root=os.getenv('NOVA_DATA_DIR','/app/data/nova30'); os.makedirs(root,exist_ok=True)
token=os.getenv('NOVA_UI_ACCESS_TOKEN','')

def get(path):
    req=urllib.request.Request('http://127.0.0.1:8000'+path)
    if token: req.add_header('Authorization','Bearer '+token)
    return json.load(urllib.request.urlopen(req,timeout=7))

def atomic(name,obj):
    path=os.path.join(root,name); fd,tmp=tempfile.mkstemp(prefix='.cutover.',dir=root)
    try:
        with os.fdopen(fd,'w',encoding='utf-8') as f:
            json.dump(obj,f,ensure_ascii=False,separators=(',',':')); f.flush(); os.fsync(f.fileno())
        os.replace(tmp,path)
    finally:
        if os.path.exists(tmp): os.unlink(tmp)
try:
    edge=get('/api/precision-edge')
    edge['close_preserve']={'frozen':True,'mode':'SAFE_CUTOVER_HANDOFF','source_snapshot_at':time.time(),
       'server_authoritative':True,'lookahead_reselection':False,
       'preserve_until':'NEXT_TRADING_SESSION_FRESH_HANDOFF'}
    atomic('precision_edge_cutover_handoff.json',edge)
    print('OFFICIAL_HANDOFF=SAVED',end=' ')
except Exception as exc:
    print('OFFICIAL_HANDOFF=SKIPPED_'+type(exc).__name__,end=' ')
try:
    news=get('/api/news-early-ignition')
    atomic('news_early_cutover_snapshot.json',news)
    print('NEWS_SNAPSHOT=SAVED')
except Exception as exc:
    print('NEWS_SNAPSHOT=SKIPPED_'+type(exc).__name__)
PY
)"
say "CUTOVER_PREP=PASS ${HANDOFF_RESULT}"

say "===== 6/8 ATOMIC CONTAINER CUTOVER ====="
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

# Preserve every user-defined network from the old live container. This is critical
# for the Caddy -> quant-nova Docker DNS path (kiwoom-net).
for net in "${OLD_NETWORKS[@]}"; do
  case "$net" in bridge|default|host|none|'') continue ;; esac
  docker network connect "$net" "${CURRENT_CONTAINER}" >/dev/null 2>&1 || true
done

HEALTH=''
for _ in $(seq 1 48); do
  HEALTH="$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "${CURRENT_CONTAINER}")"
  [[ "${HEALTH}" == 'healthy' ]] && break
  [[ "${HEALTH}" == 'unhealthy' || "${HEALTH}" == 'exited' || "${HEALTH}" == 'dead' ]] && fail "new container failed: ${HEALTH}"
  sleep 5
done
[[ "${HEALTH}" == 'healthy' ]] || fail "new container health timeout: ${HEALTH}"
say 'CONTAINER_CUTOVER=PASS'

say "===== 7/8 LIVE RUNTIME CONTRACT ====="
docker exec -i "${CURRENT_CONTAINER}" python - <<'PY'
import json, os, urllib.request

def get(path):
    req=urllib.request.Request('http://127.0.0.1:8000'+path)
    token=os.getenv('NOVA_UI_ACCESS_TOKEN','')
    if token: req.add_header('Authorization','Bearer '+token)
    return json.load(urllib.request.urlopen(req,timeout=8))

live=get('/api/livez'); edge=get('/api/precision-edge'); news=get('/api/news-early-ignition')
assert live.get('ok'), live
assert edge.get('ok'), edge
assert edge.get('version')=='NOVA-PRECISION-EDGE-X1-PHASE2-EQUAL-COMPETITION-NEWS-EARLY-3.1.2', edge.get('version')
c=edge.get('contracts') or {}
assert c.get('fixed_table_ids')==['preignition','prebuy','nxt','pullback'], c
assert c.get('fixed_rows_each')==10 and c.get('membership_commit_sec')==30, c
assert c.get('membership_policy')=='EQUAL_CURRENT_EVIDENCE_NO_CORE_FRESH_ANCHOR_PRIVILEGE', c
assert c.get('row_values_live_continuous') is True, c
assert c.get('min_dwell_sec')==0 and c.get('move_score_gap')==0 and c.get('move_confirmations')==1, c
assert c.get('new_broker_rest_calls')==0 and c.get('new_ws_subscription_types')==0, c
assert c.get('automatic_order') is False, c
nc=news.get('contracts') or {}
assert news.get('ok') and nc.get('table_rows')==10, news
assert nc.get('watch')=='NEWS && (TURNOVER_RATIO>=1.50 OR RS_ACCEL_10M>=+1.00p)', nc
assert 'TURNOVER_RATIO>=1.50' in nc.get('ready','') and 'EXEC>=120' in nc.get('ready',''), nc
assert '30s x2' in nc.get('buy','') and 'TURNOVER>=100eok' in nc.get('buy',''), nc
assert nc.get('signal_price_recorded') is True, nc
assert nc.get('official_pre_buy_changed') is False and nc.get('official_entry_buy_changed') is False, nc
assert nc.get('broker_rest_changed') is False and nc.get('broker_ws_changed') is False, nc
assert nc.get('automatic_order') is False, nc
print('LIVE_API_CONTRACT=PASS PHASE='+str(edge.get('phase'))+' NEWS_STATUS='+str(news.get('status')))
PY

# Verify the public host port inherited from the old container still reaches the new app.
python3 - <<'PY'
import json,urllib.request
j=json.load(urllib.request.urlopen('http://127.0.0.1:3200/api/livez',timeout=8))
assert j.get('ok'),j
print('HOST_PORT_3200=PASS')
PY

# The public reverse proxy must resolve the newly cut-over container on every Caddy network.
if exists kiwoom-caddy; then
  mapfile -t CADDY_NETWORKS < <(docker inspect --format '{{range $k,$v := .NetworkSettings.Networks}}{{println $k}}{{end}}' kiwoom-caddy | sed '/^$/d')
  for net in "${CADDY_NETWORKS[@]}"; do
    case "$net" in bridge|default|host|none|'') continue ;; esac
    docker inspect --format '{{json .NetworkSettings.Networks}}' "${CURRENT_CONTAINER}" | grep -q "\"${net}\"" || fail "new container missing Caddy network: ${net}"
  done
  docker exec kiwoom-caddy getent hosts "${CURRENT_CONTAINER}" >/dev/null 2>&1 || fail 'Caddy cannot resolve quant-nova after cutover'
  say 'CADDY_DNS_NETWORK=PASS'
fi

# During a live trading phase, do not call deployment successful until realtime feed is decision-ready.
ACTIVE_PHASE="$(docker exec -i "${CURRENT_CONTAINER}" python - <<'PY'
import json,os,urllib.request
req=urllib.request.Request('http://127.0.0.1:8000/api/precision-edge')
token=os.getenv('NOVA_UI_ACCESS_TOKEN','')
if token:req.add_header('Authorization','Bearer '+token)
j=json.load(urllib.request.urlopen(req,timeout=8)); print(j.get('phase') or '')
PY
)"
case "${ACTIVE_PHASE}" in
  'MORNING A+ SCOUT'|'MORNING PRIMARY'|'MORNING RE-ACCEL ONLY'|'NXT OBSERVE'|'NXT BASELINE'|'NXT READY'|'NXT ENTRY'|'NXT A+ ONLY')
    FEED_READY=0
    for _ in $(seq 1 36); do
      if docker exec -i "${CURRENT_CONTAINER}" python - <<'PY' >/dev/null 2>&1
import json,os,sys,urllib.request
req=urllib.request.Request('http://127.0.0.1:8000/api/precision-edge')
token=os.getenv('NOVA_UI_ACCESS_TOKEN','')
if token:req.add_header('Authorization','Bearer '+token)
j=json.load(urllib.request.urlopen(req,timeout=8))
sys.exit(0 if (j.get('feed') or {}).get('decision_ready') else 1)
PY
      then FEED_READY=1; break; fi
      sleep 5
    done
    [[ "${FEED_READY}" == 1 ]] || fail "active-session realtime feed not decision-ready: ${ACTIVE_PHASE}"
    ;;
esac
say 'LIVE_RUNTIME=PASS'

say "===== 8/8 SUCCESS ====="
CUTOVER_STARTED=0
trap - ERR
say "RESULT=SUCCESS"
say "VERSION=${VERSION}"
say "CURRENT=${CURRENT_CONTAINER}"
say "IMAGE=${IMAGE_TAG}"
say "BACKUP=${BACKUP_CONTAINER}"
say "OLD_VERSION=${OLD_VERSION}"
say "TABLE=NEWS_EARLY_IGNITION_FIXED10"
say "MEMBERSHIP=EQUAL_COMPETITION_30S_NO_CORE_FRESH_ANCHOR_PRIVILEGE"
say "ROW_VALUES=LIVE_CONTINUOUS"
say "NEWS_SIGNAL_PRICE=SQLITE_RECORDED"
say "OFFICIAL_PRE_BUY=UNCHANGED"
say "BROKER_REST_WS=UNCHANGED"
say "AUTO_ROLLBACK=ENABLED"
say "BACKUP_RETAINED=YES"
say "ACTIVE_SESSION_FROZEN_SHELL=FIXED"
say "NXT_TIME_GATE=1540_2000"
say "SIGNAL_OCCURRENCE=MEANINGFUL_TRANSITIONS"
say "CADDY_NETWORK_INHERIT=ENABLED"
