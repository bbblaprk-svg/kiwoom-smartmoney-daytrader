#!/usr/bin/env bash
set -Eeuo pipefail
# PULSE EDGE 2.1.11.9 R3 — scout-funnel + CPU-safe deployment; Docker-network canary, no host-port/userland-proxy dependency. Run with bash, never source this file.
# Upload Dockerfile, this script and the matching SOURCE archive into one folder.
# Default installation: /opt/pulse-edge. No NOVA containers/data are imported.
umask 077
BASE="${PULSE_DEPLOY_BASE:-/opt/pulse-edge}"
ENV_FILE="${PULSE_DEPLOY_ENV_FILE:-$BASE/.env}"
DATA_DIR="$BASE/data"
NET="${PULSE_DEPLOY_NETWORK:-kiwoom-net}"
CADDY="${PULSE_DEPLOY_CADDY:-kiwoom-caddy}"
PUB="${PULSE_DEPLOY_PUBLIC_URL:-https://3-38-25-20.nip.io}"
RELEASE=2.1.11.9_SCOUT_FUNNEL_CPU_SAFE
EXPECTED_DF_SHA=43dab24161d8baff3a6cdbc911b92c045a2fd2ac9737cab0ba26fa08f126ffe0
EXPECTED_SRC_SHA=675d336d466d9b06934bd439639827e3784c972314669cf4c8c570018c8ff434
SRC_NAME=PULSE_EDGE_CORE_2_1_3_RUNTIME_2_1_11_9_SCOUT_FUNNEL_CPU_SAFE_R3_SOURCE.tar.gz
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
SELF="$SCRIPT_DIR/$(basename -- "${BASH_SOURCE[0]}")"
RUN_DIR=""
OLD=""
LIVE=""
CANARY=""
OLD_WAS_RUNNING=false
OLD_RESTART=no
OLD_MAX_RETRY=0
CUTOVER_STARTED=0
SNAPSHOT_READY=0
MODE="${1:-deploy}"

log(){ printf '%s\n' "$*"; }
die(){ log "ERROR: $*" >&2; exit 1; }
need(){ command -v "$1" >/dev/null 2>&1 || die "missing command: $1"; }
for c in docker curl python3 sha256sum flock awk df cp; do need "$c"; done
[ "$EUID" -eq 0 ] || die 'run with sudo bash (writes /opt and Docker state)'
[[ "$BASE" = /* && "$BASE" != / ]] || die 'BASE must be an absolute application directory'
mkdir -p "$BASE"
exec 9>"$BASE/.deploy.lock"
flock -n 9 || die 'another PULSE deployment or rollback is running'
docker info >/dev/null 2>&1 || die 'Docker daemon is unavailable'

json_path(){
  python3 - "$1" "$2" <<'PY'
import json,sys
v=json.load(open(sys.argv[1]))
for key in sys.argv[2].split('.'):
    v=v.get(key) if isinstance(v,dict) else None
if isinstance(v,bool): print(str(v).lower())
elif v is not None: print(v)
PY
}

running(){ [ "$(docker inspect -f '{{.State.Running}}' "$1" 2>/dev/null)" = true ]; }
exists(){ docker inspect "$1" >/dev/null 2>&1; }
stop_verified(){
  local c="$1"
  exists "$c" || return 0
  docker update --restart=no "$c" >/dev/null || return 1
  if running "$c"; then
    docker stop -t 30 "$c" >/dev/null || docker kill "$c" >/dev/null || return 1
  fi
  ! running "$c"
}

detach(){
  exists "$1" || return 0
  if docker inspect "$1" --format '{{json .NetworkSettings.Networks}}' |
    python3 -c 'import json,sys;sys.exit(0 if sys.argv[1] in json.load(sys.stdin) else 1)' "$NET"; then
    docker network disconnect "$NET" "$1" >/dev/null || return 1
  fi
}

alias_holders(){
  local c
  while IFS= read -r c; do
    [ -n "$c" ] || continue
    if docker inspect "$c" --format '{{json .NetworkSettings.Networks}}' |
      python3 -c 'import json,sys; d=json.load(sys.stdin);sys.exit(0 if "pulse-edge" in ((d.get(sys.argv[1]) or {}).get("Aliases") or []) else 1)' "$NET"; then
      log "$c"
    fi
  done < <(docker ps -a --format '{{.Names}}')
}

feed_on(){
  docker inspect "$1" --format '{{range .Config.Env}}{{println .}}{{end}}' |
    awk -F= '$1=="PULSE_FEED_ENABLED"{v=tolower($2);gsub(/["\047 \r]/,"",v);found=1} END{exit (found && (v=="false" || v=="0" || v=="no" || v=="off"))?1:0}'
}

pulse_containers(){
  # Names and ownership label refer only to PULSE; never select legacy projects.
  docker ps --format '{{.Names}} {{.Label "io.pulse-edge.project"}}' |
    awk '$1 ~ /^pulse-edge($|-)/ || $2=="PULSE_EDGE" {print $1}'
}

sole_feed(){
  local c; local -a on=()
  while IFS= read -r c; do
    [ -n "$c" ] || continue
    if feed_on "$c"; then on+=("$c"); fi
  done < <(pulse_containers)
  [ "${#on[@]}" -eq 1 ] && [ "${on[0]}" = "$LIVE" ]
}

save_state(){
  {
    printf 'BASE=%q\nDATA_DIR=%q\nNET=%q\nCADDY=%q\nPUB=%q\n' "$BASE" "$DATA_DIR" "$NET" "$CADDY" "$PUB"
    printf 'RUN_DIR=%q\nOLD=%q\nLIVE=%q\nCANARY=%q\n' "$RUN_DIR" "$OLD" "$LIVE" "$CANARY"
    printf 'OLD_WAS_RUNNING=%q\nOLD_RESTART=%q\nOLD_MAX_RETRY=%q\nSNAPSHOT_READY=%q\n' "$OLD_WAS_RUNNING" "$OLD_RESTART" "$OLD_MAX_RETRY" "$SNAPSHOT_READY"
  } >"$RUN_DIR/state.env.tmp"
  mv "$RUN_DIR/state.env.tmp" "$RUN_DIR/state.env"
}

public_check(){
  local i
  for i in $(seq 1 30); do
    if curl -fsS --connect-timeout 3 --max-time 8 "$PUB/health" >"$RUN_DIR/public-health.json" &&
       [ "$(json_path "$RUN_DIR/public-health.json" project)" = 'PULSE EDGE' ] &&
       curl -fsS --max-time 8 "$PUB/" >/dev/null &&
       curl -fsS --max-time 8 "$PUB/api/presentation/current-decision" >/dev/null; then return 0; fi
    sleep 2
  done
  return 1
}

restore_old_network(){
  local -a args=(network connect)
  local alias
  detach "$OLD" || return 1
  while IFS= read -r alias; do [ -z "$alias" ] || args+=(--alias "$alias"); done <"$RUN_DIR/old-aliases.txt"
  docker "${args[@]}" "$NET" "$OLD" >/dev/null
}

rollback(){
  log 'ROLLBACK_BEGIN'
  # Never start the old Feed if the new process could still hold OAuth/WS.
  if [ -n "$LIVE" ]; then stop_verified "$LIVE" || { log 'ROLLBACK_BLOCKED: new Feed could not be stopped'; return 1; }; detach "$LIVE" || return 1; fi
  if [ -n "$CANARY" ]; then stop_verified "$CANARY" || return 1; fi
  if [ "$SNAPSHOT_READY" -eq 1 ] && [ ! -e "$RUN_DIR/data-restored" ]; then
    python3 "$RUN_DIR/source/deploy/data_check.py" restore-in-place "$DATA_DIR" "$RUN_DIR/data.before" "$RUN_DIR/data.failed.$(date +%s)-$$" || return 1
    touch "$RUN_DIR/data-restored"
  fi
  if [ -n "$OLD" ]; then
    restore_old_network || return 1
    local policy="$OLD_RESTART"
    if [ "$policy" = on-failure ] && [ "$OLD_MAX_RETRY" -gt 0 ]; then policy="on-failure:$OLD_MAX_RETRY"; fi
    docker update --restart="$policy" "$OLD" >/dev/null || return 1
    if [ "$OLD_WAS_RUNNING" = true ]; then
      docker start "$OLD" >/dev/null || return 1
      if public_check; then log 'ROLLBACK_HTTP_PASS'; else log 'ROLLBACK_STATE_RESTORED_BUT_HTTP_UNHEALTHY'; return 1; fi
    else log 'ROLLBACK_RESTORED_PREVIOUS_STOPPED_STATE'; fi
  else log 'ROLLBACK_RESTORED_NO_PREVIOUS_APP'; fi
  touch "$RUN_DIR/rolled-back"
  log 'ROLLBACK_END'
}

cleanup(){
  local rc=$?
  trap - EXIT ERR INT TERM
  set +e
  if [ "$rc" -ne 0 ] && [ "$CUTOVER_STARTED" -eq 1 ]; then
    rollback || log "ROLLBACK_INCOMPLETE: inspect $RUN_DIR/deploy.log"
  fi
  if [ -n "$CANARY" ]; then stop_verified "$CANARY" || log 'CANARY_STOP_FAILED'; fi
  if [ "$rc" -ne 0 ] && [ -n "$RUN_DIR" ]; then
    log "DEPLOY_FAILED exit=$rc log=$RUN_DIR/deploy.log"
  fi
  exit "$rc"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'rc=$?; log "FAILED line=$LINENO exit=$rc" >&2' ERR

if [ "$MODE" = --rollback ]; then
  STATE_DIR="${2:-}"
  [[ "$STATE_DIR" = "$BASE"/deployments/* ]] || die 'rollback path must belong to this PULSE installation'
  [ -f "$STATE_DIR/state.env" ] || die 'rollback state missing'
  # State was written with printf %q under root-owned 0700 deployment directory.
  [ "$(stat -c %u "$STATE_DIR/state.env")" = 0 ] || die 'rollback state must be root-owned'
  # shellcheck source=/dev/null
  source "$STATE_DIR/state.env"
  [ ! -f "$RUN_DIR/rolled-back" ] || die 'this deployment was already rolled back'
  mapfile -t holders < <(alias_holders)
  for c in "${holders[@]}"; do [ "$c" = "$LIVE" ] || [ "$c" = "$OLD" ] || die 'a newer deployment owns the route'; done
  exec > >(tee -a "$RUN_DIR/deploy.log") 2>&1
  rollback || die 'rollback did not fully recover; see log'
  exit 0
fi
[ "$MODE" = deploy ] || [ "$MODE" = --preflight ] || die 'usage: bash SCRIPT [--preflight | --rollback /opt/pulse-edge/deployments/RUN]'

RUN_ID="$(date +%Y%m%d-%H%M%S)-$$"
RUN_DIR="$BASE/deployments/$RUN_ID"
mkdir -p "$RUN_DIR/build" "$RUN_DIR/source"
exec > >(tee -a "$RUN_DIR/deploy.log") 2>&1
log "PULSE EDGE $RELEASE | $MODE | $RUN_ID"
log '[1/12] Locate exact uploaded bytes and validate archive before touching the live app'
python3 - "$SCRIPT_DIR" "$PWD" "$BASE" "$RUN_DIR" "$EXPECTED_DF_SHA" "$EXPECTED_SRC_SHA" "$SRC_NAME" <<'PY'
import hashlib,pathlib,shutil,sys,tarfile
roots=list(dict.fromkeys(pathlib.Path(x).resolve() for x in sys.argv[1:4]))
run=pathlib.Path(sys.argv[4])
for label,expected,pattern,dest in [('Dockerfile',sys.argv[5],'Dockerfile*','Dockerfile'),('SOURCE',sys.argv[6],'PULSE_EDGE*SOURCE*.gz',sys.argv[7])]:
    found=[]
    for root in roots:
        for p in sorted(root.glob(pattern)):
            if p.is_file() and hashlib.sha256(p.read_bytes()).hexdigest()==expected:
                found.append(p)
    if not found: raise SystemExit(f'{label}: matching 2.1.11.9 file missing or modified; put all 3 files together')
    shutil.copyfile(found[0],run/'build'/dest)
    print(f'{label}_SHA_PASS file={found[0].name}')
with tarfile.open(run/'build'/sys.argv[7],'r:gz') as t:
    members=t.getmembers(); names=set(); total=0
    for m in members:
        p=pathlib.PurePosixPath(m.name)
        if p.is_absolute() or '..' in p.parts or not(m.isfile() or m.isdir()) or str(p) in names:
            raise SystemExit(f'unsafe/duplicate archive member: {m.name}')
        names.add(str(p)); total+=m.size
    if total>50*1024*1024 or len(members)>5000: raise SystemExit('archive size limit')
    for f in ['requirements-runtime.txt','pulse_edge/main.py','pulse_edge/web/pulse.js','pulse_edge/web/pulse.css','deploy/prepare_env.py','deploy/verify.py','deploy/burst_test.py','deploy/offline_tests.py','deploy/soak_check.py','deploy/UNCHANGED_SHA256.json','deploy/data_check.py']:
        if f not in names: raise SystemExit('archive missing '+f)
    # Paths/types were validated above, including on older host Python versions.
    if hasattr(tarfile,'data_filter'): t.extractall(run/'source',filter='data')
    else: t.extractall(run/'source')
    print(f'ARCHIVE_PASS members={len(members)} bytes={total}')
PY
# Only these two public build inputs reach Docker; .env is never sent as context.
printf '*\n!Dockerfile\n!%s\n' "$SRC_NAME" >"$RUN_DIR/build/.dockerignore"
python3 -m compileall -q "$RUN_DIR/source/pulse_edge" "$RUN_DIR/source/deploy"
if command -v node >/dev/null 2>&1; then node --check "$RUN_DIR/source/pulse_edge/web/pulse.js"; fi

log '[2/12] Explicit PULSE installation, Caddy network, disk and memory'
[ -s "$ENV_FILE" ] || die "missing $ENV_FILE; supply the PULSE environment file"
[ -d "$DATA_DIR" ] || mkdir -p "$DATA_DIR/pulse_edge"
python3 - "$BASE" "$DATA_DIR" "$RUN_DIR" <<'PY'
import os,pathlib,shutil,sys
base,data,run=map(pathlib.Path,sys.argv[1:])
if data.is_symlink() or data.resolve().parent!=base.resolve(): raise SystemExit('data must be the dedicated PULSE directory')
size=0
for root,dirs,files in os.walk(data):
    for name in dirs+files:
        p=pathlib.Path(root)/name
        if p.is_symlink(): raise SystemExit('data snapshot does not permit links: '+str(p))
    size+=sum((pathlib.Path(root)/name).stat().st_size for name in files)
if shutil.disk_usage(run).free < 1024**3 + 2*size: raise SystemExit('disk space below build + snapshot + restore reserve')
p=run/'data-size.txt';p.write_text(str(size))
mem={l.split(':')[0]:int(l.split()[1]) for l in open('/proc/meminfo') if ':' in l}
avail=mem.get('MemAvailable',0);swap=mem.get('SwapFree',0)
if avail<131072 or avail+swap<786432: raise SystemExit('insufficient memory headroom (128MiB RAM and 768MiB RAM+swap required)')
print(f'RESOURCE_PASS mem_available_kb={avail} swap_free_kb={swap} data_bytes={size}')
PY
running "$CADDY" || die "Caddy is not running: $CADDY"
docker network inspect "$NET" >/dev/null || die "missing network $NET"
docker inspect "$CADDY" --format '{{json .NetworkSettings.Networks}}' |
  python3 -c 'import json,sys;sys.exit(0 if sys.argv[1] in json.load(sys.stdin) else 1)' "$NET" || die 'Caddy is not on the PULSE network'
docker exec "$CADDY" caddy validate --config /etc/caddy/Caddyfile >/dev/null || die 'invalid Caddy configuration'
docker exec "$CADDY" caddy adapt --config /etc/caddy/Caddyfile >"$RUN_DIR/caddy.json"
python3 - "$RUN_DIR/caddy.json" <<'PY'
import json,sys
j=json.load(open(sys.argv[1]))
def find(v):
    if isinstance(v,dict):
        if v.get('handler')=='reverse_proxy' and any(x.get('dial')=='pulse-edge:8000' for x in v.get('upstreams',[])): return True
        return any(find(x) for x in v.values())
    if isinstance(v,list): return any(find(x) for x in v)
    return False
if not find(j): raise SystemExit('Caddy target pulse-edge:8000 not found')
PY
[[ "$PUB" = https://* ]] || die 'public URL must use HTTPS'
mapfile -t holders < <(alias_holders)
[ "${#holders[@]}" -le 1 ] || die "multiple pulse-edge alias owners: ${holders[*]}"
if [ "${#holders[@]}" -eq 1 ]; then
  OLD="${holders[0]}"
  [[ "$OLD" = pulse-edge || "$OLD" = pulse-edge-* ]] || die 'route owner is not an explicit PULSE container'
  docker inspect "$OLD" >"$RUN_DIR/old-inspect.json"
  python3 - "$RUN_DIR/old-inspect.json" "$NET" "$DATA_DIR" "$RUN_DIR" <<'PY'
import json,pathlib,sys
c=json.load(open(sys.argv[1]))[0];net,data,run=sys.argv[2:]
mounts=[m for m in c.get('Mounts',[]) if m.get('Destination')=='/app/data']
if len(mounts)!=1 or pathlib.Path(mounts[0]['Source']).resolve()!=pathlib.Path(data).resolve():
    raise SystemExit('old PULSE /app/data is not the explicit installation data; refusing to guess another volume')
network=c['NetworkSettings']['Networks'][net]
# Static network assignments require deliberate handling; do not silently discard them.
if any((network.get('IPAMConfig') or {}).get(k) for k in ['IPv4Address','IPv6Address']):
    raise SystemExit('old container uses a static network IP; automatic detach would not preserve its contract')
pathlib.Path(run,'old-aliases.txt').write_text('\n'.join(network.get('Aliases') or ['pulse-edge'])+'\n')
PY
  OLD_WAS_RUNNING="$(docker inspect -f '{{.State.Running}}' "$OLD")"
  OLD_RESTART="$(docker inspect -f '{{.HostConfig.RestartPolicy.Name}}' "$OLD")"
  OLD_MAX_RETRY="$(docker inspect -f '{{.HostConfig.RestartPolicy.MaximumRetryCount}}' "$OLD")"
  log "PREVIOUS=$OLD running=$OLD_WAS_RUNNING"
  # A broken baseline is recorded, not used as an impossible prerequisite for repair.
  if curl -fsS --max-time 8 "$PUB/health" >"$RUN_DIR/baseline-health.json" &&
     curl -fsS --max-time 8 "$PUB/" >/dev/null &&
     curl -fsS --max-time 8 "$PUB/api/presentation/current-decision" >/dev/null; then
    log 'BASELINE_HTTP_PASS'
  else log 'BASELINE_ALREADY_UNHEALTHY: previous container/data will still be preserved'; fi
else log 'NO_PREVIOUS_ALIAS: installing at the explicit PULSE path'; fi

log '[3/12] Build archive-aware image and run offline semantics/config checks'
IMG="pulse-edge:runtime-2.1.11.9-$RUN_ID"
CANARY="pulse-edge-canary-runtime-2.1.11.9-$RUN_ID"
LIVE="pulse-edge-live-runtime-2.1.11.9-$RUN_ID"
save_state
cp "$SELF" "$RUN_DIR/deploy.sh"
docker build -t "$IMG" "$RUN_DIR/build"
docker run --rm --network none -e PULSE_FEED_ENABLED=false --entrypoint python "$IMG" -m deploy.burst_test
docker run --rm --network none -e PULSE_FEED_ENABLED=false --entrypoint python "$IMG" -m deploy.offline_tests
# Normalize quotes/export/CRLF once. The raw credential file is never printed.
docker run --rm --network none -e PULSE_FEED_ENABLED=false \
  --mount "type=bind,src=$ENV_FILE,dst=/run/pulse.env,readonly" \
  --entrypoint python "$IMG" -m deploy.prepare_env /run/pulse.env >"$RUN_DIR/runtime.env"
[ -s "$RUN_DIR/runtime.env" ] || die 'runtime environment normalization failed'
EFF_MAX="$(awk -F= '$1=="PULSE_WS_DYNAMIC_MAX_ITEMS"{print $2}' "$RUN_DIR/runtime.env")"
docker run --rm --network none -e PULSE_FEED_ENABLED=false \
  --mount "type=bind,src=$DATA_DIR,dst=/app/data" --entrypoint python "$IMG" -c \
  'from pathlib import Path; import tempfile; p=Path("/app/data/pulse_edge"); p.mkdir(parents=True,exist_ok=True); f=tempfile.TemporaryFile(dir=p); f.write(b"volume-check"); f.flush(); f.close(); print("VOLUME_WRITE_PASS")'
if [ "$MODE" = --preflight ]; then log "PREFLIGHT_PASS (build/config only; live data not certified) log=$RUN_DIR/deploy.log"; exit 0; fi

log '[4/12] Stop duplicate PULSE Feeds with proof; preserve previous app'
while IFS= read -r c; do
  [ -n "$c" ] || continue
  [ "$c" = "$OLD" ] && continue
  log "STOP_DUPLICATE_PULSE=$c"
  stop_verified "$c" || die "could not stop duplicate PULSE: $c"
done < <(pulse_containers)

log '[5/12] Feed-OFF canary on Docker network; no host port/userland proxy'
# Canary joins the existing Docker bridge with NO host port mapping and NO pulse-edge alias.
# This removes the userland-proxy/ephemeral-port failure mode while keeping Caddy isolated from canary.
docker run -d --name "$CANARY" --restart=no \
  --network "$NET" \
  --label io.pulse-edge.project=PULSE_EDGE --label io.pulse-edge.role=canary \
  --env-file "$RUN_DIR/runtime.env" -e PULSE_FEED_ENABLED=false \
  --mount "type=bind,src=$DATA_DIR,dst=/app/data,readonly" \
  "$IMG" >/dev/null
CANARY_IP="$(docker inspect -f "{{with index .NetworkSettings.Networks \"$NET\"}}{{.IPAddress}}{{end}}" "$CANARY")"
[ -n "$CANARY_IP" ] || die 'canary has no Docker-network IP'
CANARY_URL="http://$CANARY_IP:8000"
wait_local(){
  local c="$1" url="$2" feed="$3" i
  for i in $(seq 1 90); do
    running "$c" || { log "$c stopped during startup"; return 1; }
    if curl -fsS --max-time 3 "$url/health" >"$RUN_DIR/ready.json" 2>/dev/null; then
      [ "$(json_path "$RUN_DIR/ready.json" runtime_safety_release)" = "$RELEASE" ] &&
      [ "$(json_path "$RUN_DIR/ready.json" feed_enabled)" = "$feed" ] && return 0
    fi
    sleep 1
  done
  return 1
}
wait_local "$CANARY" "$CANARY_URL" false || die 'canary not ready (inspect docker logs)'
python3 "$RUN_DIR/source/deploy/verify.py" "$CANARY_URL" false

log '[6/12] Two-minute Feed-OFF responsiveness check'
for i in $(seq 1 24); do
  curl -fsS --max-time 4 "$CANARY_URL/health" >/dev/null
  curl -fsS --max-time 5 "$CANARY_URL/" >/dev/null
  if [ $((i % 6)) -eq 0 ]; then log "CANARY_CHECK=$i/24"; fi
  sleep 5
done
# Release its RAM before starting the production process.
stop_verified "$CANARY" || die 'could not stop canary'

log '[7/12] Recheck route; stop old Feed; take a consistent data snapshot'
mapfile -t holders < <(alias_holders)
if [ -n "$OLD" ]; then
  [ "${#holders[@]}" -eq 1 ] && [ "${holders[0]}" = "$OLD" ] || die 'route changed during validation'
else [ "${#holders[@]}" -eq 0 ] || die 'another app acquired the route'; fi
# Recheck singleton before crossing the point requiring rollback.
while IFS= read -r c; do
  [ "$c" = "$OLD" ] || die "unexpected PULSE process appeared: $c"
done < <(pulse_containers)
CUTOVER_STARTED=1
if [ -n "$OLD" ]; then stop_verified "$OLD" || die 'old Feed would not stop'; detach "$OLD" || die 'old alias detach failed'; fi
cp -a "$DATA_DIR" "$RUN_DIR/data.before"
python3 "$RUN_DIR/source/deploy/data_check.py" snapshot "$DATA_DIR" "$RUN_DIR/data.before"
SNAPSHOT_READY=1
save_state

log '[8/12] Start new Feed-ON, then verify Docker DNS and exact public version'
docker run -d --name "$LIVE" --restart=unless-stopped \
  --label io.pulse-edge.project=PULSE_EDGE --label io.pulse-edge.role=live \
  --env-file "$RUN_DIR/runtime.env" -e PULSE_FEED_ENABLED=true \
  --mount "type=bind,src=$DATA_DIR,dst=/app/data" \
  --network "$NET" --network-alias pulse-edge "$IMG" >/dev/null
LIVE_IP="$(docker inspect -f "{{with index .NetworkSettings.Networks \"$NET\"}}{{.IPAddress}}{{end}}" "$LIVE")"
[ -n "$LIVE_IP" ] || die 'live container has no Docker-network IP'
LIVE_URL="http://$LIVE_IP:8000"
wait_local "$LIVE" "$LIVE_URL" true || die 'new live not ready (inspect docker logs)'
sole_feed || die 'Feed-ON singleton failed'
mapfile -t holders < <(alias_holders)
[ "${#holders[@]}" -eq 1 ] && [ "${holders[0]}" = "$LIVE" ] || die 'live alias mismatch'
docker exec "$CADDY" wget -q -T 8 -O - http://pulse-edge:8000/health >"$RUN_DIR/caddy-health.json"
[ "$(json_path "$RUN_DIR/caddy-health.json" runtime_safety_release)" = "$RELEASE" ] || die 'Caddy network points at the wrong release'
public_check || die 'public HTTPS health/page/API did not recover'
python3 "$RUN_DIR/source/deploy/verify.py" "$LIVE_URL" true
python3 "$RUN_DIR/source/deploy/verify.py" "$PUB" true

log '[9/12] Two-minute warmup (public health stays observable)'
for i in $(seq 1 4); do
  curl -fsS --max-time 8 "$PUB/health" >/dev/null
  log "WARMUP=$i/4"
  sleep 30
done

log '[10/12] Ten-minute live responsiveness, CPU/memory/feed validation'
BAD_STREAK=0
for i in $(seq 1 20); do
  BAD=0
  for entry in 'health:health' 'session:api/session' 'truth:api/feed-truth' 'runtime:api/runtime-truth'; do
    name="${entry%%:*}"; endpoint="${entry#*:}"
    curl -fsS --max-time 6 "$LIVE_URL/$endpoint" >"$RUN_DIR/$name.json" || BAD=1
  done
  curl -fsS --max-time 8 "$PUB/" >/dev/null || BAD=1
  curl -fsS --max-time 8 "$PUB/api/presentation/current-decision" >/dev/null || BAD=1
  curl -fsS --max-time 8 "$LIVE_URL/api/smart-money/top?limit=10" >/dev/null || BAD=1
  docker stats --no-stream --format '{{.CPUPerc}} {{.MemPerc}}' "$LIVE" >"$RUN_DIR/stats.txt" || BAD=1
  docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}missing{{end}}' "$LIVE" >"$RUN_DIR/docker-health.txt" || BAD=1
  python3 "$RUN_DIR/source/deploy/soak_check.py" "$RUN_DIR" "$EFF_MAX" "$i" || BAD=1
  sole_feed || BAD=1
  if [ "$BAD" -eq 1 ]; then BAD_STREAK=$((BAD_STREAK+1)); else BAD_STREAK=0; fi
  log "LIVE_CHECK=$i/20 bad=$BAD streak=$BAD_STREAK"
  [ "$BAD_STREAK" -lt 3 ] || die 'three consecutive live checks failed'
  sleep 30
done
[ "$BAD_STREAK" -eq 0 ] || die 'last live check failed; refusing a false success'

log '[11/12] Final route and public contract'
python3 "$RUN_DIR/source/deploy/verify.py" "$PUB" true
sole_feed || die 'final singleton mismatch'
mapfile -t holders < <(alias_holders)
[ "${#holders[@]}" -eq 1 ] && [ "${holders[0]}" = "$LIVE" ] || die 'final alias mismatch'
CUTOVER_STARTED=0
touch "$RUN_DIR/deploy-passed"
log '[12/12] DEPLOY_PASS'
log "ACTIVE=$LIVE"
log "PUBLIC=$PUB"
log "LOG=$RUN_DIR/deploy.log"
log "ROLLBACK: sudo bash $RUN_DIR/deploy.sh --rollback $RUN_DIR"
log 'Market-feed verification is reported separately in each LIVE_METRICS line; CLOSED is not live-data certification.'
