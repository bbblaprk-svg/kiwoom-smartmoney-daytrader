#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

REPO="bbblaprk-svg/kiwoom-smartmoney-daytrader"
BRANCH="main"
APP="${NOVA_APP_CONTAINER:-quant-nova}"
REMOTE_DOCKERFILE="Dockerfile"
EXPECTED_DOCKERFILE_SHA="246deb1bd45854af17ab5c7ed80652bebabb576270ee1ac5b47866401a49ea45"
EXPECTED_EMBEDDED_SOURCE_SHA="1aafb56ee8ad2d2b5997c7dfee6738f6709b6995bcfc0e5219f446706400aca2"
EXPECTED_VERSION="NOVA-3.3.5-R492-MARKET-INDEX-VERIFY1"
BASELINE_R492="NOVA-3.3.5-R492-FRESH-ENERGY-PATH-SAFE"
IMAGE="quant-nova:3.3.5-r492-market-index-verify1-local"
STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP="${APP}-pre-miv1-${STAMP}"
CANDIDATE="${APP}-candidate-miv1-${STAMP}"
WORK="$(mktemp -d /tmp/nova-r492-miv1.XXXXXX)"
DOCKERFILE="$WORK/Dockerfile"
ENVFILE="$WORK/current.env"
CAND_DATA="$WORK/candidate-data"
LOG="/tmp/nova-r492-miv1-deploy-${STAMP}.log"
OLD_WAS_RUNNING=0
OLD_STOPPED=0
OLD_RENAMED=0
NEW_STARTED=0
CAND_STARTED=0
PROTECTED_SNAPSHOT_READY=0
STATE_MUTATED=0
LOCKFILE="/tmp/nova-r492-miv1-deploy.lock"

exec 9>"$LOCKFILE"
if ! flock -n 9; then
  echo "INFO: MARKET-INDEX VERIFY1 deploy is already running. Do not start it twice."
  exit 0
fi

if docker info >/dev/null 2>&1; then DOCKER=(docker)
elif sudo -n docker info >/dev/null 2>&1; then DOCKER=(sudo docker)
else echo "FAIL: Docker 권한을 확인할 수 없습니다."; exit 2
fi

dc(){ "${DOCKER[@]}" "$@"; }
say(){ printf '\n===== %s =====\n' "$*" | tee -a "$LOG"; }
cleanup(){ rm -rf -- "$WORK" 2>/dev/null || true; }

wait_health(){
  local name="$1" i status
  for i in $(seq 1 72); do
    status="$(dc inspect "$name" --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' 2>/dev/null || true)"
    [ "$status" = "healthy" ] && return 0
    sleep 5
  done
  return 1
}

image_version(){
  local name="$1" iid
  iid="$(dc inspect "$name" --format '{{.Image}}' 2>/dev/null || true)"
  [ -n "$iid" ] || return 0
  dc image inspect "$iid" --format '{{index .Config.Labels "org.opencontainers.image.version"}}' 2>/dev/null || true
}

recover_previous_if_needed(){
  local status latest cand ver iid
  if dc inspect "$APP" >/dev/null 2>&1; then
    status="$(dc inspect "$APP" --format '{{.State.Status}}' 2>/dev/null || true)"
    if [ "$status" != "running" ]; then
      echo "INFO: existing $APP is $status; starting it before validation" | tee -a "$LOG"
      dc start "$APP" >/dev/null 2>&1 || true
      wait_health "$APP" || true
    fi
    return 0
  fi
  latest=""
  while IFS= read -r cand; do
    [ -n "$cand" ] || continue
    iid="$(dc inspect "$cand" --format '{{.Image}}' 2>/dev/null || true)"
    ver="$(dc image inspect "$iid" --format '{{index .Config.Labels "org.opencontainers.image.version"}}' 2>/dev/null || true)"
    if [ "$ver" = "$BASELINE_R492" ]; then latest="$cand"; break; fi
  done < <(dc ps -a --format '{{.Names}}' | grep -E "^${APP}-pre-(miv1|r493)-[0-9]{8}-[0-9]{6}$" | sort -r || true)
  if [ -n "$latest" ]; then
    echo "INFO: restoring approved R492 backup $latest -> $APP" | tee -a "$LOG"
    dc rename "$latest" "$APP"
    dc start "$APP" >/dev/null
    wait_health "$APP"
  fi
}

protected_snapshot(){
  for name in nova-http-guard caddy nova-caddy kiwoom-caddy; do
    if dc inspect "$name" >/dev/null 2>&1; then
      printf '%s=%s\n' "$name" "$(dc inspect "$name" --format '{{.Id}}')"
    fi
  done | sort
}

verify_protected(){
  [ "$PROTECTED_SNAPSHOT_READY" -eq 1 ] || return 0
  [ -f "$WORK/protected.before" ] || return 0
  [ "$(cat "$WORK/protected.before")" = "$(protected_snapshot)" ] || {
    echo "FAIL: Guard/Caddy 컨테이너가 변경됐습니다." | tee -a "$LOG"; return 1; }
}

fetch_dockerfile(){
  local raw tmp rc
  raw="https://raw.githubusercontent.com/${REPO}/${BRANCH}/${REMOTE_DOCKERFILE}"
  tmp="${DOCKERFILE}.download"
  rm -f "$tmp"
  echo "PUBLIC_FETCH_URL=$raw" | tee -a "$LOG"
  if curl -fL --retry 2 --retry-delay 2 --connect-timeout 10 --max-time 45 \
      -H 'Cache-Control: no-cache' \
      "$raw?ts=$(date +%s)" -o "$tmp"; then
    mv "$tmp" "$DOCKERFILE"
    return 0
  fi
  rc=$?
  rm -f "$tmp"
  echo "FAIL: Public GitHub에서 Dockerfile을 읽지 못했습니다. 인증/token은 요청하지 않습니다." | tee -a "$LOG"
  echo "FAIL: GitHub 루트에 정확한 파일명이 있는지 확인: $REMOTE_DOCKERFILE" | tee -a "$LOG"
  echo "FAIL: URL=$raw" | tee -a "$LOG"
  echo "RESULT=ABORTED_NO_CHANGE reason=PUBLIC_DOCKERFILE_FETCH_FAILED curl_rc=$rc" | tee -a "$LOG"
  return "$rc"
}

restore_r492(){
  local restored=""
  if [ "$CAND_STARTED" -eq 1 ] && dc inspect "$CANDIDATE" >/dev/null 2>&1; then
    dc rm -f "$CANDIDATE" >/dev/null 2>&1 || true
  fi
  if [ "$NEW_STARTED" -eq 1 ] && dc inspect "$APP" >/dev/null 2>&1; then
    dc logs --tail 250 "$APP" >>"$LOG" 2>&1 || true
    dc rm -f "$APP" >/dev/null 2>&1 || true
  fi
  if [ "$OLD_RENAMED" -eq 1 ] && dc inspect "$BACKUP" >/dev/null 2>&1; then
    dc rename "$BACKUP" "$APP" >/dev/null 2>&1 || true
    [ "$OLD_WAS_RUNNING" -eq 1 ] && dc start "$APP" >/dev/null 2>&1 || true
    [ "$OLD_WAS_RUNNING" -eq 1 ] && wait_health "$APP" || true
    restored="$(image_version "$APP")"
  elif [ "$OLD_STOPPED" -eq 1 ] && dc inspect "$APP" >/dev/null 2>&1; then
    [ "$OLD_WAS_RUNNING" -eq 1 ] && dc start "$APP" >/dev/null 2>&1 || true
    [ "$OLD_WAS_RUNNING" -eq 1 ] && wait_health "$APP" || true
    restored="$(image_version "$APP")"
  fi
  if [ -n "$restored" ] && [ "$restored" != "$BASELINE_R492" ]; then
    echo "CRITICAL: rollback target version is $restored, expected $BASELINE_R492" | tee -a "$LOG"
    return 1
  fi
  return 0
}

rollback(){
  local rc=$?
  trap - ERR INT TERM EXIT
  if [ "$STATE_MUTATED" -eq 0 ]; then
    cleanup
    echo "RESULT=ABORTED_NO_CHANGE CURRENT=$APP LOG=$LOG" | tee -a "$LOG"
    exit "${rc:-1}"
  fi
  say "AUTO ROLLBACK -> EXACT R492 BASELINE"
  restore_r492 || true
  verify_protected || true
  echo "RESULT=ROLLED_BACK CURRENT=$APP RESTORED_VERSION=$(image_version "$APP") EXPECTED=$BASELINE_R492 LOG=$LOG" | tee -a "$LOG"
  cleanup
  exit "${rc:-1}"
}
trap rollback ERR INT TERM EXIT

recover_previous_if_needed

say "1/9 FETCH MARKET-INDEX VERIFY1 DOCKERFILE + SHA LOCK"
fetch_dockerfile
ACTUAL_SHA="$(sha256sum "$DOCKERFILE" | awk '{print $1}')"
echo "DOCKERFILE_SHA256=$ACTUAL_SHA" | tee -a "$LOG"
[ "$ACTUAL_SHA" = "$EXPECTED_DOCKERFILE_SHA" ] || { echo "FAIL: GitHub Dockerfile이 승인본과 다릅니다."; exit 1; }
grep -Fq "$EXPECTED_VERSION" "$DOCKERFILE"

say "1A/9 FULL EMBEDDED-SOURCE RESTORE/PREFLIGHT — CURRENT R492 UNTOUCHED"
PYBIN="$(command -v python3 || command -v python || true)"
[ -n "$PYBIN" ] || { echo "FAIL: host python3/python is required for embedded-source preflight"; exit 1; }
"$PYBIN" - "$DOCKERFILE" "$EXPECTED_EMBEDDED_SOURCE_SHA" <<'PY' | tee -a "$LOG"
import base64,hashlib,io,pathlib,re,subprocess,sys,tarfile,tempfile
p=pathlib.Path(sys.argv[1]); expected_source=sys.argv[2]
text=p.read_text()
parts=re.findall(r"RUN printf '%s' '([^']*)' >> /tmp/nova-source\.tar\.gz\.b64",text)
if not parts: raise SystemExit('PREFLIGHT_FAIL: embedded payload not found')
payload=''.join(parts)
try: raw=base64.b64decode(payload,validate=True)
except Exception as e: raise SystemExit(f'PREFLIGHT_FAIL: base64 decode: {e}')
actual=hashlib.sha256(raw).hexdigest()
if actual!=expected_source: raise SystemExit(f'PREFLIGHT_FAIL: embedded source SHA {actual} != {expected_source}')
if raw[:2]!=b'\x1f\x8b': raise SystemExit('PREFLIGHT_FAIL: payload is not gzip')
protected={
'app/signal/policy.py':'18cb96ef1afb9de48136d39c3e9b8216e62a94dccf0229aa027479783eb9151a',
'app/broker/kiwoom.py':'e10d936a2540a70d8a488e0460608a3c2a1a8bfaf95dc6206e706cce3afab0d1',
'app/broker/websocket.py':'50fefc5faa1457210af758636279bea0bc3926e505bc91317962a0d451e35602',
'app/broker/discovery.py':'7035a5b5c90a23324c44d80eb3c0c278f75c5d73d8fed2a01cc367a03c35cb86',
'app/service.py':'e325b7a76d6ddfa291b800ef97fb13e6b85fa9bb9ccb2365130ef2d5abf512c3',
'app/addons/decision_panels.py':'d84397029e758e672c85f1ff58085f3672fbe1a814e6d680513662ab36392fb3',
'app/addons/energy_path.py':'cd403cda76cb9d515c9228bf310287ad639bed125075fa835a3607cac2e81595',
'static/decision-panels.js':'e85f5a45ae8cff1c8ebcdff2a8088515bd731785859880d333e13d700a8ba522',
'static/nova.js':'4563a71f3cb1cecccfc178f944ddf4edcb6b62656693bbdecf05c619e293f16c',
'ops/http_guard_v2.py':'c07332eb6951c51b433f42059133dd22b5e28a0c137f07b9f177f814dbe1ec1b',
}
with tempfile.TemporaryDirectory(prefix='nova-r492-miv1-preflight-') as td:
    root=pathlib.Path(td)
    try:
        with tarfile.open(fileobj=io.BytesIO(raw),mode='r:gz') as tf:
            members=tf.getmembers(); names=set()
            for m in members:
                name=m.name.replace('\\','/')
                logical=name[2:] if name.startswith('./') else name
                if name.startswith('/') or '..' in name.split('/') or m.isdev() or m.issym() or m.islnk():
                    raise SystemExit('PREFLIGHT_FAIL: unsafe tar member '+m.name)
                names.add(logical)
            required={'app/main.py','app/broker/market_index_verify.py','scripts/r492_market_index_verify_acceptance.py','SOURCE_MANIFEST.sha256','requirements.txt'}
            missing=sorted(required-names)
            if missing: raise SystemExit('PREFLIGHT_FAIL: missing '+','.join(missing))
            tf.extractall(root)
    except SystemExit: raise
    except Exception as e: raise SystemExit(f'PREFLIGHT_FAIL: tar/gzip integrity: {e}')
    cp=subprocess.run(['sha256sum','-c','SOURCE_MANIFEST.sha256'],cwd=root,stdout=subprocess.DEVNULL,stderr=subprocess.STDOUT)
    if cp.returncode: raise SystemExit('PREFLIGHT_FAIL: SOURCE_MANIFEST mismatch')
    for rel,want in protected.items():
        got=hashlib.sha256((root/rel).read_bytes()).hexdigest()
        if got!=want: raise SystemExit(f'PREFLIGHT_FAIL: frozen baseline changed {rel}: {got}')
    idx=(root/'static/index.html').read_text()
    lo=idx.lower().find('<main'); hi=idx.lower().find('</main>',lo)
    if lo<0 or hi<0: raise SystemExit('PREFLIGHT_FAIL: <main> not found')
    hi += len('</main>')
    main_sha=hashlib.sha256(idx[lo:hi].encode()).hexdigest()
    if main_sha!='f04ae99c607fbe0080d57ae869b4d9fe89b38b47f327bf12161ed4f3b76dad7c':
        raise SystemExit('PREFLIGHT_FAIL: baseline main DOM changed '+main_sha)
    for rel in ('app/broker/market_index_verify.py','app/api/app.py','app/config.py','scripts/r492_market_index_verify_acceptance.py'):
        cp=subprocess.run([sys.executable,'-m','py_compile',rel],cwd=root,stdout=subprocess.DEVNULL,stderr=subprocess.STDOUT)
        if cp.returncode: raise SystemExit('PREFLIGHT_FAIL: py_compile '+rel)
    mod=(root/'app/broker/market_index_verify.py').read_text()
    for needle in ("API_ID = 'ka20001'","API_PATH = '/api/dostk/sect'","('KOSPI', {'mrkt_tp': '0', 'inds_cd': '001'})","('KOSDAQ', {'mrkt_tp': '1', 'inds_cd': '101'})"):
        if needle not in mod: raise SystemExit('PREFLIGHT_FAIL: market-index verify contract missing '+needle)
print(f'PREFLIGHT_PAYLOAD=PASS chunks={len(parts)} gzip_bytes={len(raw)} gzip_sha256={actual} manifest=PASS protected_core=10 main_dom=UNCHANGED py_compile=PASS')
PY

say "2/9 REQUIRE EXACT R492 BASELINE + SNAPSHOT RUNTIME"
dc inspect "$APP" >/dev/null
CURRENT_VERSION="$(image_version "$APP")"
echo "current_version=${CURRENT_VERSION:-UNKNOWN}" | tee -a "$LOG"
if [ "$CURRENT_VERSION" = "$EXPECTED_VERSION" ]; then
  echo "INFO: VERIFY1 is already deployed. Running health/acceptance only." | tee -a "$LOG"
  wait_health "$APP"
  dc exec "$APP" env PYTHONPATH=/app python /app/scripts/r492_market_index_verify_acceptance.py | tee -a "$LOG"
  dc exec "$APP" python - "$EXPECTED_VERSION" <<'PY' | tee -a "$LOG"
import json,os,sys,urllib.request
expected=sys.argv[1]
t=(os.getenv('NOVA_UI_ACCESS_TOKEN') or os.getenv('APP_ACCESS_TOKEN') or '').strip(); h={'X-App-Token':t,'Authorization':'Bearer '+t} if t else {}
def get(p):
  with urllib.request.urlopen(urllib.request.Request('http://127.0.0.1:8000'+p,headers=h),timeout=6) as r:return json.load(r)
live=get('/api/livez'); mi=get('/api/market-index-verify'); c=mi.get('contracts') or {}
assert live.get('ok') and live.get('version')==expected,live
assert mi.get('mode')=='VERIFY_DISPLAY_ONLY',mi
assert c.get('display_only') is True and c.get('rank_or_score_adjustment_applied') is False,c
assert c.get('official_buy_logic_changed') is False and c.get('pre_buy_nxt_largecap_energy_path_logic_changed') is False,c
assert c.get('new_ws_subscription_types')==0 and c.get('broker_rest_calls_per_refresh_max')==2,c
assert c.get('relative_formula_applied') is False,c
print(json.dumps({'ok':True,'status':'ALREADY_DEPLOYED','version':expected,'market_index_verify':mi},ensure_ascii=False))
PY
  trap - ERR INT TERM EXIT
  cleanup
  echo "RESULT=ALREADY_DEPLOYED VERSION=$EXPECTED_VERSION CURRENT=$APP LOG=$LOG"
  exit 0
fi
[ "$CURRENT_VERSION" = "$BASELINE_R492" ] || {
  echo "FAIL: 현재 앱은 승인 R492 기준본이 아닙니다: $CURRENT_VERSION. 아무것도 변경하지 않습니다." | tee -a "$LOG"; exit 1; }
[ "$(dc inspect "$APP" --format '{{.State.Running}}')" = "true" ] && OLD_WAS_RUNNING=1 || true
dc inspect "$APP" --format '{{range .Config.Env}}{{println .}}{{end}}' > "$ENVFILE"
protected_snapshot > "$WORK/protected.before"
PROTECTED_SNAPSHOT_READY=1
NETWORK_MODE="$(dc inspect "$APP" --format '{{.HostConfig.NetworkMode}}' | xargs)"
mapfile -t NETWORKS < <(dc inspect "$APP" --format '{{range $name, $_ := .NetworkSettings.Networks}}{{println $name}}{{end}}' | awk 'NF' | sort -u)
case "$NETWORK_MODE" in
  host|none|container:*) PRIMARY_NETWORK="$NETWORK_MODE" ;;
  default|"") if [ "${#NETWORKS[@]}" -gt 0 ]; then PRIMARY_NETWORK="${NETWORKS[0]}"; else PRIMARY_NETWORK="bridge"; fi ;;
  *) if [ "${#NETWORKS[@]}" -gt 0 ]; then PRIMARY_NETWORK="${NETWORKS[0]}"; else PRIMARY_NETWORK="$NETWORK_MODE"; fi ;;
esac
[ -n "$PRIMARY_NETWORK" ] || { echo "FAIL: unable to resolve Docker network mode"; exit 1; }
RESTART="$(dc inspect "$APP" --format '{{.HostConfig.RestartPolicy.Name}}')"; [ -n "$RESTART" ] || RESTART=unless-stopped
USER_SPEC="$(dc inspect "$APP" --format '{{.Config.User}}')"
READONLY="$(dc inspect "$APP" --format '{{.HostConfig.ReadonlyRootfs}}')"
MEMORY="$(dc inspect "$APP" --format '{{.HostConfig.Memory}}')"
MEMSWAP="$(dc inspect "$APP" --format '{{.HostConfig.MemorySwap}}')"
MEMRES="$(dc inspect "$APP" --format '{{.HostConfig.MemoryReservation}}')"
PIDSLIMIT="$(dc inspect "$APP" --format '{{.HostConfig.PidsLimit}}')"
MOUNT_ARGS=()
while IFS='|' read -r TYPE SOURCE DEST RW NAME; do
  TYPE="$(xargs <<<"$TYPE")"; SOURCE="$(xargs <<<"$SOURCE")"; DEST="$(xargs <<<"$DEST")"; RW="$(xargs <<<"$RW")"; NAME="$(xargs <<<"$NAME")"
  [ -z "$TYPE" ] && continue
  if [[ "$DEST" == /app/* && "$DEST" != /app/data && "$DEST" != /app/data/* ]]; then echo "FAIL: app source override mount: $DEST"; exit 1; fi
  MODE=""; [ "$RW" = true ] || MODE=":ro"
  if [ "$TYPE" = bind ]; then MOUNT_ARGS+=( -v "${SOURCE}:${DEST}${MODE}" );
  elif [ "$TYPE" = volume ]; then MOUNT_ARGS+=( -v "${NAME}:${DEST}${MODE}" ); fi
done < <(dc inspect "$APP" --format '{{range .Mounts}}{{println .Type "|" .Source "|" .Destination "|" .RW "|" .Name}}{{end}}')
PORT_ARGS=()
while IFS='|' read -r HOSTIP HOSTPORT CONTAINERPORT; do
  HOSTIP="$(xargs <<<"$HOSTIP")"; HOSTPORT="$(xargs <<<"$HOSTPORT")"; CONTAINERPORT="$(xargs <<<"$CONTAINERPORT")"
  [ -z "$HOSTPORT" ] && continue
  if [ -n "$HOSTIP" ] && [ "$HOSTIP" != "0.0.0.0" ]; then PORT_ARGS+=( -p "${HOSTIP}:${HOSTPORT}:${CONTAINERPORT}" ); else PORT_ARGS+=( -p "${HOSTPORT}:${CONTAINERPORT}" ); fi
done < <(dc inspect "$APP" --format '{{range $port, $bindings := .NetworkSettings.Ports}}{{range $bindings}}{{println .HostIp "|" .HostPort "|" $port}}{{end}}{{end}}')

echo "network_mode=$NETWORK_MODE primary_network=$PRIMARY_NETWORK attached_networks=${NETWORKS[*]:-none}" | tee -a "$LOG"

say "3/9 RESOURCE PREFLIGHT; STOP R492 ONLY FOR LOW-RAM BUILD"
FREE_KB="$(df -Pk /var/lib/docker 2>/dev/null | awk 'NR==2{print $4}')"; [ -n "$FREE_KB" ] || FREE_KB="$(df -Pk / | awk 'NR==2{print $4}')"
echo "pre_stop_free_kb=$FREE_KB" | tee -a "$LOG"
(( FREE_KB >= 1400000 )) || { echo "FAIL: Docker disk free ${FREE_KB}KB < 1.4GB; R492 untouched"; exit 1; }
if [ "$OLD_WAS_RUNNING" -eq 1 ]; then dc stop -t 10 "$APP" >/dev/null; OLD_STOPPED=1; STATE_MUTATED=1; fi
AVAIL_MB="$(free -m | awk '/Mem:/{print $7}')"
echo "post_stop_available_mb=$AVAIL_MB" | tee -a "$LOG"
(( AVAIL_MB >= 350 )) || { echo "FAIL: available RAM ${AVAIL_MB}MB < 350MB; auto-restore R492"; exit 1; }
DOCKER_BUILDKIT=1 dc build --pull --no-cache -f "$DOCKERFILE" -t "$IMAGE" "$WORK" | tee -a "$LOG"
[ "$(dc image inspect "$IMAGE" --format '{{index .Config.Labels "org.opencontainers.image.version"}}')" = "$EXPECTED_VERSION" ]
[ "$(dc image inspect "$IMAGE" --format '{{index .Config.Labels "io.quantnova.ui_patch"}}')" = "R492_FRESH_ENERGY_PATH_SAFE" ]
[ "$(dc image inspect "$IMAGE" --format '{{index .Config.Labels "io.quantnova.market_index_verify"}}')" = "KA20001_DISPLAY_ONLY" ]
[ "$(dc image inspect "$IMAGE" --format '{{index .Config.Labels "io.quantnova.market_index_verify_rank_effect"}}')" = "0" ]
[ "$(dc image inspect "$IMAGE" --format '{{index .Config.Labels "io.quantnova.market_index_verify_buy_effect"}}')" = "0" ]
[ "$(dc image inspect "$IMAGE" --format '{{index .Config.Labels "io.quantnova.market_index_verify_ws_additions"}}')" = "0" ]
[ "$(dc image inspect "$IMAGE" --format '{{index .Config.Labels "io.quantnova.r492_new_broker_rest_calls"}}')" = "0" ]
[ "$(dc image inspect "$IMAGE" --format '{{index .Config.Labels "io.quantnova.r492_new_ws_subscription_types"}}')" = "0" ]
[ "$(dc image inspect "$IMAGE" --format '{{index .Config.Labels "io.quantnova.main_dom_sha256"}}')" = "f04ae99c607fbe0080d57ae869b4d9fe89b38b47f327bf12161ed4f3b76dad7c" ]

say "4/9 ISOLATED CANDIDATE — NO BROKER/NO PRODUCTION DATA"
mkdir -p "$CAND_DATA/nova30"
dc rm -f "$CANDIDATE" >/dev/null 2>&1 || true
CAND_ARGS=(run -d --name "$CANDIDATE" --network none --memory 384m --memory-swap 384m --pids-limit 256 --read-only --tmpfs /tmp:rw,noexec,nosuid,size=32m --env-file "$ENVFILE" -e NOVA_CANDIDATE_MODE=1 -e NOVA_MARKET_INDEX_VERIFY_ENABLED=0 -e NOVA_DATA_DIR=/app/data/nova30 -e NOVA_LEGACY_DATA_DIR=/app/data/nova30 -v "$CAND_DATA/nova30:/app/data/nova30")
[ -n "$USER_SPEC" ] && CAND_ARGS+=(--user "$USER_SPEC")
CAND_ARGS+=("$IMAGE")
dc "${CAND_ARGS[@]}" >/dev/null
CAND_STARTED=1
wait_health "$CANDIDATE"
dc exec "$CANDIDATE" env PYTHONPATH=/app python /app/scripts/max_profit_acceptance.py | tee -a "$LOG"
dc exec "$CANDIDATE" env PYTHONPATH=/app python /app/scripts/market_rotation_acceptance.py | tee -a "$LOG"
dc exec "$CANDIDATE" env PYTHONPATH=/app python /app/scripts/r42_fresh_scout_acceptance.py | tee -a "$LOG"
dc exec "$CANDIDATE" env PYTHONPATH=/app python /app/scripts/r492_safe_extension_acceptance.py | tee -a "$LOG"
dc exec "$CANDIDATE" env PYTHONPATH=/app python /app/scripts/r492_market_index_verify_acceptance.py | tee -a "$LOG"
dc exec "$CANDIDATE" env PYTHONPATH=/app python -m unittest tests.test_r49_signal_acceleration tests.test_r492_market_index_verify -q | tee -a "$LOG"
dc exec "$CANDIDATE" env PYTHONPATH=/app python /app/scripts/runtime_smoke.py --clients 2 --ready-timeout 30 | tee -a "$LOG"
dc rm -f "$CANDIDATE" >/dev/null
CAND_STARTED=0

say "5/9 ATOMIC CUTOVER — EXACT R492 BACKUP KEPT STOPPED"
if [ "$(dc inspect "$APP" --format '{{.State.Running}}')" = "true" ]; then dc stop -t 5 "$APP" >/dev/null; OLD_STOPPED=1; fi
dc rename "$APP" "$BACKUP"; OLD_RENAMED=1; STATE_MUTATED=1
[ "$(image_version "$BACKUP")" = "$BASELINE_R492" ] || { echo "FAIL: backup is not exact R492"; exit 1; }
[ "$(dc inspect "$BACKUP" --format '{{.State.Running}}')" = "false" ] || { echo "FAIL: R492 backup unexpectedly running"; exit 1; }
RUN_ARGS=(run -d --name "$APP" --restart "$RESTART" --network "$PRIMARY_NETWORK" --env-file "$ENVFILE")
RUN_ARGS+=("${MOUNT_ARGS[@]}")
case "$PRIMARY_NETWORK" in host|none|container:*) ;; *) RUN_ARGS+=("${PORT_ARGS[@]}") ;; esac
[ -n "$USER_SPEC" ] && RUN_ARGS+=(--user "$USER_SPEC")
[ "$READONLY" = true ] && RUN_ARGS+=(--read-only --tmpfs /tmp:rw,noexec,nosuid,size=32m)
(( MEMORY > 0 )) && RUN_ARGS+=(--memory "$MEMORY")
(( MEMSWAP > 0 )) && RUN_ARGS+=(--memory-swap "$MEMSWAP")
(( MEMRES > 0 )) && RUN_ARGS+=(--memory-reservation "$MEMRES")
[[ "$PIDSLIMIT" =~ ^[0-9]+$ ]] && (( PIDSLIMIT > 0 )) && RUN_ARGS+=(--pids-limit "$PIDSLIMIT")
RUN_ARGS+=("$IMAGE")
dc "${RUN_ARGS[@]}" >/dev/null; NEW_STARTED=1
case "$PRIMARY_NETWORK" in host|none|container:*) ;; *) for net in "${NETWORKS[@]}"; do [ -n "$net" ] || continue; [ "$net" = "$PRIMARY_NETWORK" ] && continue; dc network connect "$net" "$APP" >/dev/null; done ;; esac
wait_health "$APP"

say "6/9 ACTIVE GATES — R492 FROZEN + VERIFY/DISPLAY ONLY"
dc exec "$APP" env PYTHONPATH=/app python /app/scripts/max_profit_acceptance.py | tee -a "$LOG"
dc exec "$APP" env PYTHONPATH=/app python /app/scripts/market_rotation_acceptance.py | tee -a "$LOG"
dc exec "$APP" env PYTHONPATH=/app python /app/scripts/r42_fresh_scout_acceptance.py | tee -a "$LOG"
dc exec "$APP" env PYTHONPATH=/app python /app/scripts/r492_safe_extension_acceptance.py | tee -a "$LOG"
dc exec "$APP" env PYTHONPATH=/app python /app/scripts/r492_market_index_verify_acceptance.py | tee -a "$LOG"
dc exec "$APP" env PYTHONPATH=/app python /app/scripts/runtime_smoke.py --clients 2 --ready-timeout 30 | tee -a "$LOG"
dc exec "$APP" python - "$EXPECTED_VERSION" <<'PY' | tee -a "$LOG"
import json,os,sys,urllib.request
expected=sys.argv[1]
t=(os.getenv('NOVA_UI_ACCESS_TOKEN') or os.getenv('APP_ACCESS_TOKEN') or '').strip(); h={'X-App-Token':t,'Authorization':'Bearer '+t} if t else {}
def get(p):
  with urllib.request.urlopen(urllib.request.Request('http://127.0.0.1:8000'+p,headers=h),timeout=8) as r:return json.load(r)
live=get('/api/livez'); ready=get('/api/readyz'); lab=get('/api/max-profit-lab'); health=get('/api/realtime-health'); panels=get('/api/decision-panels'); mi=get('/api/market-index-verify')
assert live.get('ok') and live.get('version')==expected,live
assert ready.get('ok') is True,ready
assert lab.get('mode')=='VERIFY_ONLY',lab
lc=lab.get('contracts') or {}; assert lc.get('official_buy_logic_changed') is False,lc
pc=panels.get('contracts') or {}; assert panels.get('ok') is True,panels
assert pc.get('official_buy_logic_changed') is False,pc
assert pc.get('r492_new_broker_rest_calls')==0 and pc.get('r492_new_ws_subscription_types')==0,pc
assert len(panels.get('preignition') or [])<=20 and len(panels.get('energy') or [])<=10 and len(panels.get('path') or [])<=10,panels
c=mi.get('contracts') or {}
assert mi.get('ok') is True and mi.get('mode')=='VERIFY_DISPLAY_ONLY',mi
assert c.get('baseline')=='NOVA-3.3.5-R492-FRESH-ENERGY-PATH-SAFE',c
assert c.get('official_buy_logic_changed') is False and c.get('pre_buy_nxt_largecap_energy_path_logic_changed') is False,c
assert c.get('rank_or_score_adjustment_applied') is False and c.get('display_only') is True,c
assert c.get('new_ws_subscription_types')==0 and c.get('broker_rest_calls_per_refresh_max')==2,c
assert c.get('high_load_and_critical_pause') is True and c.get('relative_formula_applied') is False,c
swap=float((health.get('memory') or {}).get('swap_mb') or 0); assert swap==0,health.get('memory')
print(json.dumps({'ok':True,'version':expected,'baseline_r492_frozen':True,'display_only':True,'rank_effect':0,'buy_effect':0,'new_ws':0,'index_rest_max_per_refresh':2,'market_index_status':mi.get('status'),'load_mode':health.get('load_mode'),'swap_mb':swap},ensure_ascii=False))
PY
verify_protected

say "7/9 10-MIN LOAD OBSERVATION — 3 BAD SAMPLES => IMMEDIATE R492 RESTORE"
OBSERVE_SEC="${NOVA_MIV1_OBSERVE_SEC:-600}"
BAD_STREAK=0; START_OBS="$(date +%s)"
while (( $(date +%s) - START_OBS < OBSERVE_SEC )); do
  ELAPSED=$(( $(date +%s) - START_OBS ))
  if OBS_LINE="$(dc exec "$APP" python - <<'PY' 2>&1
import json,os,urllib.request
t=(os.getenv('NOVA_UI_ACCESS_TOKEN') or os.getenv('APP_ACCESS_TOKEN') or '').strip(); h={'X-App-Token':t,'Authorization':'Bearer '+t} if t else {}
def get(p):
  with urllib.request.urlopen(urllib.request.Request('http://127.0.0.1:8000'+p,headers=h),timeout=5) as r:return json.load(r)
x=get('/api/realtime-health'); mi=get('/api/market-index-verify')
m=x.get('memory') or {}; load=str(x.get('load_mode') or '')
swap=float(m.get('swap_mb') or 0); lag=float(x.get('event_loop_lag_p95_ms') or 0); qage=float(x.get('trade_queue_oldest_age_ms') or 0); q=int(x.get('trade_queue_depth') or 0)
c=mi.get('contracts') or {}; assert c.get('rank_or_score_adjustment_applied') is False and c.get('relative_formula_applied') is False
print(json.dumps({'load':load,'swap':swap,'lag_p95':lag,'queue_age_ms':qage,'queue':q,'index_status':mi.get('status'),'index_fresh':mi.get('fresh'),'index_calls_total':mi.get('rest_calls_total')},ensure_ascii=False))
assert swap==0
assert lag<=250
assert qage<=750
assert load!='CRITICAL'
PY
)"; then
    BAD_STREAK=0; echo "OBSERVE ${ELAPSED}/${OBSERVE_SEC}s · ${OBS_LINE}" | tee -a "$LOG"
  else
    BAD_STREAK=$((BAD_STREAK+1)); echo "WARN ${ELAPSED}/${OBSERVE_SEC}s · bad_streak=$BAD_STREAK · ${OBS_LINE}" | tee -a "$LOG"
  fi
  if (( BAD_STREAK >= 3 )); then echo "FAIL: sustained load/lag failure -> automatic exact R492 rollback" | tee -a "$LOG"; false; fi
  sleep 10
done
verify_protected

say "8/9 FINAL STATUS"
dc ps --filter "name=^/${APP}$" --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}' | tee -a "$LOG"
echo "ACTIVE_VERSION=$(image_version "$APP")" | tee -a "$LOG"
echo "R492_BACKUP=$BACKUP VERSION=$(image_version "$BACKUP")" | tee -a "$LOG"

say "9/9 SUCCESS"
trap - ERR INT TERM EXIT
cleanup
echo "RESULT=SUCCESS VERSION=$EXPECTED_VERSION CURRENT=$APP ROLLBACK_CONTAINER=$BACKUP" | tee -a "$LOG"
echo "CONTRACT=R492_CORE_FROZEN MARKET_INDEX=VERIFY_DISPLAY_ONLY RANK_EFFECT=0 BUY_EFFECT=0 NEW_WS=0 INDEX_REST_MAX_PER_REFRESH=2" | tee -a "$LOG"
echo "LOG=$LOG"
