#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

REPO="bbblaprk-svg/kiwoom-smartmoney-daytrader"
BRANCH="main"
APP="${NOVA_APP_CONTAINER:-quant-nova}"
REMOTE_DOCKERFILE="Dockerfile"
EXPECTED_DOCKERFILE_SHA="956e572fdae0b943111b1ff447dcad6e397af484b3f0794f272e9c950438df0a"
EXPECTED_EMBEDDED_SOURCE_SHA="61c35437f2afc3ddc6cc2dd6a55557d92c32ebe5fd4cfc1e8b0aebba587064b9"
EXPECTED_VERSION="NOVA-3.3.5-R492-MARKET-INDEX-VERIFY1"
EXPECTED_UIFIX_LABEL="FULL_EDGE_REACCEL_ALERTS_CLOSED_LOOP_VERIFY"
BASELINE_VERSION="NOVA-3.3.5-R492-MARKET-INDEX-VERIFY1"
IMAGE="quant-nova:3.3.5-r492-miv1-uifix6-full-edge-local"
STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP="${APP}-pre-uifix6-${STAMP}"
CANDIDATE="${APP}-candidate-uifix6-${STAMP}"
WORK="$(mktemp -d /tmp/nova-r492-miv1-uifix6-full-edge.XXXXXX)"
DOCKERFILE="$WORK/Dockerfile"
ENVFILE="$WORK/current.env"
CAND_DATA="$WORK/candidate-data"
LOG="/tmp/nova-r492-miv1-uifix6-full-edge-deploy-${STAMP}.log"
LOCKFILE="/tmp/nova-r492-miv1-uifix6-full-edge-deploy.lock"
OLD_WAS_RUNNING=0
OLD_STOPPED=0
OLD_RENAMED=0
NEW_STARTED=0
CAND_STARTED=0
STATE_MUTATED=0
PROTECTED_SNAPSHOT_READY=0
BASELINE_IMAGE_ID=""

exec 9>"$LOCKFILE"
if ! flock -n 9; then
  echo "INFO: R492 MIV1 UIFIX6 FULL EDGE deploy is already running. Do not start it twice."
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

image_id(){ dc inspect "$1" --format '{{.Image}}' 2>/dev/null || true; }
image_version(){
  local iid
  iid="$(image_id "$1")"; [ -n "$iid" ] || return 0
  dc image inspect "$iid" --format '{{index .Config.Labels "org.opencontainers.image.version"}}' 2>/dev/null || true
}
image_uifix(){
  local iid out
  iid="$(image_id "$1")"; [ -n "$iid" ] || return 0
  out="$(dc image inspect "$iid" --format '{{index .Config.Labels "io.quantnova.r492_uifix6"}}' 2>/dev/null || true)"
  [ "$out" = "<no value>" ] && out=""
  printf '%s' "$out"
}

protected_snapshot(){
  local name
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
  echo "FAIL: Public GitHub에서 Dockerfile을 읽지 못했습니다." | tee -a "$LOG"
  echo "FAIL: GitHub 루트 파일명은 정확히 Dockerfile 이어야 합니다." | tee -a "$LOG"
  echo "RESULT=ABORTED_NO_CHANGE reason=PUBLIC_DOCKERFILE_FETCH_FAILED curl_rc=$rc" | tee -a "$LOG"
  return "$rc"
}

restore_miv1(){
  local restored_ver restored_fix
  if [ "$CAND_STARTED" -eq 1 ] && dc inspect "$CANDIDATE" >/dev/null 2>&1; then
    dc rm -f "$CANDIDATE" >/dev/null 2>&1 || true
  fi
  if [ "$NEW_STARTED" -eq 1 ] && dc inspect "$APP" >/dev/null 2>&1; then
    dc logs --tail 250 "$APP" >>"$LOG" 2>&1 || true
    dc rm -f "$APP" >/dev/null 2>&1 || true
  fi
  if [ "$OLD_RENAMED" -eq 1 ] && dc inspect "$BACKUP" >/dev/null 2>&1; then
    if [ -n "$BASELINE_IMAGE_ID" ] && [ "$(image_id "$BACKUP")" != "$BASELINE_IMAGE_ID" ]; then
      echo "CRITICAL: exact MIV1 backup image id changed; refusing a non-exact rollback." | tee -a "$LOG"
      return 1
    fi
    dc rename "$BACKUP" "$APP" >/dev/null 2>&1 || true
    if [ "$OLD_WAS_RUNNING" -eq 1 ]; then
      dc start "$APP" >/dev/null 2>&1 || true
      wait_health "$APP" || true
    fi
  elif [ "$OLD_STOPPED" -eq 1 ] && dc inspect "$APP" >/dev/null 2>&1; then
    if [ "$OLD_WAS_RUNNING" -eq 1 ]; then
      dc start "$APP" >/dev/null 2>&1 || true
      wait_health "$APP" || true
    fi
  fi
  restored_ver="$(image_version "$APP")"
  restored_fix="$(image_uifix "$APP")"
  [ "$restored_ver" = "$BASELINE_VERSION" ] || {
    echo "CRITICAL: rollback version $restored_ver != $BASELINE_VERSION" | tee -a "$LOG"; return 1; }
  [ "$restored_fix" != "$EXPECTED_UIFIX_LABEL" ] || {
    echo "CRITICAL: rollback target still carries UIFIX6 label." | tee -a "$LOG"; return 1; }
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
  say "AUTO ROLLBACK -> EXACT PRE-UIFIX6 RUNNING IMAGE"
  restore_miv1 || true
  verify_protected || true
  echo "RESULT=ROLLED_BACK CURRENT=$APP VERSION=$(image_version "$APP") UIFIX=$(image_uifix "$APP") LOG=$LOG" | tee -a "$LOG"
  cleanup
  exit "${rc:-1}"
}
trap rollback ERR INT TERM EXIT

say "1/9 FETCH UIFIX6 DOCKERFILE + SHA LOCK"
fetch_dockerfile
ACTUAL_SHA="$(sha256sum "$DOCKERFILE" | awk '{print $1}')"
echo "DOCKERFILE_SHA256=$ACTUAL_SHA" | tee -a "$LOG"
[ "$ACTUAL_SHA" = "$EXPECTED_DOCKERFILE_SHA" ] || { echo "FAIL: GitHub Dockerfile이 승인 UIFIX6과 다릅니다."; exit 1; }
grep -Fq "io.quantnova.r492_uifix6=\"$EXPECTED_UIFIX_LABEL\"" "$DOCKERFILE"
grep -Fq "$EXPECTED_VERSION" "$DOCKERFILE"

say "1A/9 FULL EMBEDDED-SOURCE RESTORE/PREFLIGHT — ACTIVE MIV1 UNTOUCHED"
PYBIN="$(command -v python3 || command -v python || true)"
[ -n "$PYBIN" ] || { echo "FAIL: host python3/python is required"; exit 1; }
"$PYBIN" - "$DOCKERFILE" "$EXPECTED_EMBEDDED_SOURCE_SHA" <<'PY' | tee -a "$LOG"
import base64,hashlib,io,pathlib,re,subprocess,sys,tarfile,tempfile
p=pathlib.Path(sys.argv[1]); expected_source=sys.argv[2]
text=p.read_text()
parts=re.findall(r"RUN printf '%s' '([^']*)' >> /tmp/nova-source\.tar\.gz\.b64",text)
if not parts: raise SystemExit('PREFLIGHT_FAIL: embedded payload not found')
raw=base64.b64decode(''.join(parts),validate=True)
actual=hashlib.sha256(raw).hexdigest()
if actual!=expected_source: raise SystemExit(f'PREFLIGHT_FAIL: embedded source SHA {actual} != {expected_source}')
if raw[:2]!=b'\x1f\x8b': raise SystemExit('PREFLIGHT_FAIL: payload is not gzip')
frozen={
'app/signal/policy.py':'18cb96ef1afb9de48136d39c3e9b8216e62a94dccf0229aa027479783eb9151a',
'app/broker/kiwoom.py':'e10d936a2540a70d8a488e0460608a3c2a1a8bfaf95dc6206e706cce3afab0d1',
'app/broker/websocket.py':'50fefc5faa1457210af758636279bea0bc3926e505bc91317962a0d451e35602',
'app/service.py':'e325b7a76d6ddfa291b800ef97fb13e6b85fa9bb9ccb2365130ef2d5abf512c3',
'app/addons/energy_path.py':'cd403cda76cb9d515c9228bf310287ad639bed125075fa835a3607cac2e81595',
'static/nova.js':'8f0904af264a3a8eda2d874dda25ce8086fb66d1751b592a9be0d6069b5ee1f6',
'ops/http_guard_v2.py':'c07332eb6951c51b433f42059133dd22b5e28a0c137f07b9f177f814dbe1ec1b',
}
designated={
'app/api/app.py':'3190986146e6844a34d473b9e884f198708af9ef9499f966e352538dd639d243',
'app/addons/reaccel_verify.py':'91f70240d18025ae9d4ba563e858431cb98663a295eb7f8cf4256f6d78773c2d',
'app/addons/edge_alerts.py':'e9414bea43b053791da81e566506ebb0268d329a3280f763289d129b8fbfdf1c',
'app/storage/edge_outcomes.py':'7093ec6b5c9d171d2b77c3f7e4ce3b830272054bb5ed8ef754d63b5f2cb0f046',
'static/index.html':'92ecd21180bbcf936854e1c0e62bc9022ce56b9b4da7f5416d6eb9ba1999af4d',
'static/re-accel.js':'51b61cafc7af100c2e25483ec49349b1ee842ef47d813e874d2d2c8a9010d0f2',
'static/edge-alert-center.js':'6885892e4f81e30b5f5aa4e2ff5352bcac08f2147c8c211ba3de6b17368e3a96',
'static/edge-performance.js':'1f1308a87d8cf6ff08f8353272890dbf6419d6664e533a59b0dd5bd8148f9c15',
'static/nxt-after-edge.js':'220bc3ae73cdf0ad226a8f0669ffa81ae77c065da89bec83f7f02bdb019deb4d',
'scripts/r492_uifix6_acceptance.py':'f59956fffcb1e95b54f99184b991cfacd9e28f8a78a4250d1dc85c060625c6dc',
'R492_UIFIX6_INVARIANTS.md':'5cc569c05288a896542f3751fc8b78f81e27de3da32a7d666791e28c113a242f',
}
required=set(frozen)|set(designated)|{'SOURCE_MANIFEST.sha256','requirements.txt','app/runtime/feed_truth.py','app/broker/nxt_after_edge.py','app/broker/market_index_verify.py','app/addons/pre_display_stability.py','static/feed-truth.js','scripts/r492_uifix3_acceptance.py','scripts/r492_uifix4_acceptance.py','scripts/r492_uifix5_acceptance.py'}
with tempfile.TemporaryDirectory(prefix='nova-r492-uifix6-preflight-') as td:
    root=pathlib.Path(td)
    with tarfile.open(fileobj=io.BytesIO(raw),mode='r:gz') as tf:
        names=set()
        for m in tf.getmembers():
            name=m.name.replace('\\','/')
            if name.startswith('/') or '..' in name.split('/') or m.isdev() or m.issym() or m.islnk(): raise SystemExit('PREFLIGHT_FAIL: unsafe tar member '+m.name)
            names.add(name)
        missing=sorted(required-names)
        if missing: raise SystemExit('PREFLIGHT_FAIL: missing '+','.join(missing))
        tf.extractall(root)
    cp=subprocess.run(['sha256sum','-c','SOURCE_MANIFEST.sha256'],cwd=root,stdout=subprocess.DEVNULL,stderr=subprocess.STDOUT)
    if cp.returncode: raise SystemExit('PREFLIGHT_FAIL: SOURCE_MANIFEST mismatch')
    for rel,want in frozen.items():
        got=hashlib.sha256((root/rel).read_bytes()).hexdigest()
        if got!=want: raise SystemExit(f'PREFLIGHT_FAIL: frozen core changed {rel}: {got}')
    for rel,want in designated.items():
        got=hashlib.sha256((root/rel).read_bytes()).hexdigest()
        if got!=want: raise SystemExit(f'PREFLIGHT_FAIL: UIFIX6 file mismatch {rel}: {got}')
    idx=(root/'static/index.html').read_text(); lo=idx.lower().find('<main'); hi=idx.lower().find('</main>',lo)
    if lo<0 or hi<0: raise SystemExit('PREFLIGHT_FAIL: <main> not found')
    hi+=len('</main>'); main_sha=hashlib.sha256(idx[lo:hi].encode()).hexdigest()
    if main_sha!='f04ae99c607fbe0080d57ae869b4d9fe89b38b47f327bf12161ed4f3b76dad7c': raise SystemExit('PREFLIGHT_FAIL: frozen <main> DOM changed '+main_sha)
    reacc=(root/'app/addons/reaccel_verify.py').read_text(); alerts=(root/'app/addons/edge_alerts.py').read_text(); perf=(root/'app/storage/edge_outcomes.py').read_text(); api=(root/'app/api/app.py').read_text()
    if 'REST.post(' in reacc or 'websockets.connect(' in reacc: raise SystemExit('PREFLIGHT_FAIL: RE-ACCEL direct broker call')
    if 'REST.post(' in alerts or 'websockets.connect(' in alerts: raise SystemExit('PREFLIGHT_FAIL: alert hub direct broker call')
    if 'REST.post(' in perf or 'websockets.connect(' in perf: raise SystemExit('PREFLIGHT_FAIL: performance ledger direct broker call')
    for ep in ("@app.get('/api/re-accel')","@app.get('/api/edge-alerts')","@app.get('/api/edge-performance')","@app.get('/api/feed-truth')","@app.get('/api/nxt-after-edge')"):
        if ep not in api: raise SystemExit('PREFLIGHT_FAIL: endpoint missing '+ep)
    for rel in ('app/api/app.py','app/addons/reaccel_verify.py','app/addons/edge_alerts.py','app/storage/edge_outcomes.py','scripts/r492_uifix6_acceptance.py'):
        cp=subprocess.run([sys.executable,'-m','py_compile',rel],cwd=root,stdout=subprocess.DEVNULL,stderr=subprocess.STDOUT)
        if cp.returncode: raise SystemExit('PREFLIGHT_FAIL: py_compile '+rel)
print(f'PREFLIGHT_UIFIX6=PASS chunks={len(parts)} gzip_bytes={len(raw)} gzip_sha256={actual} manifest=PASS frozen_core=7 designated_uifix6=11 main_dom=UNCHANGED reaccel=1 alerts=1 outcomes=1 broker_rest_add=0 ws_type_add=0')
PY

say "2/9 REQUIRE CURRENT MIV1 + SNAPSHOT RUNTIME"
dc inspect "$APP" >/dev/null
CURRENT_VERSION="$(image_version "$APP")"
CURRENT_UIFIX="$(image_uifix "$APP")"
echo "current_version=${CURRENT_VERSION:-UNKNOWN} current_uifix=${CURRENT_UIFIX:-NONE}" | tee -a "$LOG"
if [ "$CURRENT_VERSION" = "$EXPECTED_VERSION" ] && [ "$CURRENT_UIFIX" = "$EXPECTED_UIFIX_LABEL" ]; then
  echo "INFO: UIFIX6 is already deployed. Running health/acceptance only." | tee -a "$LOG"
  wait_health "$APP"
  dc exec "$APP" env PYTHONPATH=/app python /app/scripts/r492_uifix6_acceptance.py | tee -a "$LOG"
  dc exec "$APP" python - <<'PY' | tee -a "$LOG"
from pathlib import Path
html=Path('/app/static/index.html').read_text(); api=Path('/app/app/api/app.py').read_text()
assert 're-accel.js' in html and 'edge-alert-center.js' in html and 'edge-performance.js' in html
for ep in ("@app.get('/api/re-accel')","@app.get('/api/edge-alerts')","@app.get('/api/edge-performance')"): assert ep in api
print('UIFIX6_RUNTIME_STATIC=PASS reaccel=1 unified_alerts=1 performance=1')
PY
  trap - ERR INT TERM EXIT
  cleanup
  echo "RESULT=ALREADY_DEPLOYED VERSION=$EXPECTED_VERSION UIFIX=$EXPECTED_UIFIX_LABEL CURRENT=$APP LOG=$LOG"
  exit 0
fi
[ "$CURRENT_VERSION" = "$BASELINE_VERSION" ] || {
  echo "FAIL: 현재 앱이 승인 MIV1이 아닙니다: $CURRENT_VERSION. 아무것도 변경하지 않습니다." | tee -a "$LOG"; exit 1; }
[ "$CURRENT_UIFIX" != "$EXPECTED_UIFIX_LABEL" ] || { echo "FAIL: UIFIX6 상태 판별 충돌"; exit 1; }
BASELINE_IMAGE_ID="$(image_id "$APP")"
[ -n "$BASELINE_IMAGE_ID" ] || { echo "FAIL: current MIV1 image id missing"; exit 1; }
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
  if [ "$TYPE" = bind ]; then MOUNT_ARGS+=( -v "${SOURCE}:${DEST}${MODE}" )
  elif [ "$TYPE" = volume ]; then MOUNT_ARGS+=( -v "${NAME}:${DEST}${MODE}" ); fi
done < <(dc inspect "$APP" --format '{{range .Mounts}}{{println .Type "|" .Source "|" .Destination "|" .RW "|" .Name}}{{end}}')
PORT_ARGS=()
while IFS='|' read -r HOSTIP HOSTPORT CONTAINERPORT; do
  HOSTIP="$(xargs <<<"$HOSTIP")"; HOSTPORT="$(xargs <<<"$HOSTPORT")"; CONTAINERPORT="$(xargs <<<"$CONTAINERPORT")"
  [ -z "$HOSTPORT" ] && continue
  if [ -n "$HOSTIP" ] && [ "$HOSTIP" != "0.0.0.0" ]; then PORT_ARGS+=( -p "${HOSTIP}:${HOSTPORT}:${CONTAINERPORT}" ); else PORT_ARGS+=( -p "${HOSTPORT}:${CONTAINERPORT}" ); fi
done < <(dc inspect "$APP" --format '{{range $port, $bindings := .NetworkSettings.Ports}}{{range $bindings}}{{println .HostIp "|" .HostPort "|" $port}}{{end}}{{end}}')

echo "baseline_image_id=$BASELINE_IMAGE_ID network_mode=$NETWORK_MODE primary_network=$PRIMARY_NETWORK" | tee -a "$LOG"

say "3/9 RESOURCE PREFLIGHT; STOP CURRENT MIV1 ONLY FOR LOW-RAM BUILD"
FREE_KB="$(df -Pk /var/lib/docker 2>/dev/null | awk 'NR==2{print $4}')"; [ -n "$FREE_KB" ] || FREE_KB="$(df -Pk / | awk 'NR==2{print $4}')"
echo "pre_stop_free_kb=$FREE_KB" | tee -a "$LOG"
(( FREE_KB >= 1400000 )) || { echo "FAIL: Docker disk free ${FREE_KB}KB < 1.4GB; current MIV1 untouched"; exit 1; }
if [ "$OLD_WAS_RUNNING" -eq 1 ]; then dc stop -t 10 "$APP" >/dev/null; OLD_STOPPED=1; STATE_MUTATED=1; fi
AVAIL_MB="$(free -m | awk '/Mem:/{print $7}')"
echo "post_stop_available_mb=$AVAIL_MB" | tee -a "$LOG"
(( AVAIL_MB >= 350 )) || { echo "FAIL: available RAM ${AVAIL_MB}MB < 350MB; auto-restore current MIV1"; exit 1; }
DOCKER_BUILDKIT=1 dc build --pull --no-cache -f "$DOCKERFILE" -t "$IMAGE" "$WORK" | tee -a "$LOG"
[ "$(dc image inspect "$IMAGE" --format '{{index .Config.Labels "org.opencontainers.image.version"}}')" = "$EXPECTED_VERSION" ]
[ "$(dc image inspect "$IMAGE" --format '{{index .Config.Labels "io.quantnova.r492_uifix6"}}')" = "$EXPECTED_UIFIX_LABEL" ]
[ "$(dc image inspect "$IMAGE" --format '{{index .Config.Labels "io.quantnova.reaccel"}}')" = "DISPLAY_VERIFY_ONLY_NO_ENTRY_V18_MUTATION" ]
[ "$(dc image inspect "$IMAGE" --format '{{index .Config.Labels "io.quantnova.feed_truth_rank_effect"}}')" = "0" ]
[ "$(dc image inspect "$IMAGE" --format '{{index .Config.Labels "io.quantnova.feed_truth_buy_effect"}}')" = "0" ]
[ "$(dc image inspect "$IMAGE" --format '{{index .Config.Labels "io.quantnova.r492_new_broker_rest_calls"}}')" = "0" ]
[ "$(dc image inspect "$IMAGE" --format '{{index .Config.Labels "io.quantnova.r492_new_ws_subscription_types"}}')" = "0" ]
[ "$(dc image inspect "$IMAGE" --format '{{index .Config.Labels "io.quantnova.market_index_rs_verify"}}')" = "LISTING_MARKET_MATCHED_DISPLAY_ONLY_NO_RANK_BUY" ]
[ "$(dc image inspect "$IMAGE" --format '{{index .Config.Labels "io.quantnova.main_dom_sha256"}}')" = "f04ae99c607fbe0080d57ae869b4d9fe89b38b47f327bf12161ed4f3b76dad7c" ]

say "4/9 ISOLATED CANDIDATE — NO BROKER / NO PRODUCTION DATA"
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
dc exec "$CANDIDATE" env PYTHONPATH=/app python /app/scripts/r492_safe_extension_acceptance.py | tee -a "$LOG"
dc exec "$CANDIDATE" env PYTHONPATH=/app python /app/scripts/r492_market_index_verify_acceptance.py | tee -a "$LOG"
dc exec "$CANDIDATE" env PYTHONPATH=/app python /app/scripts/r492_uifix3_acceptance.py | tee -a "$LOG"
dc exec "$CANDIDATE" env PYTHONPATH=/app python /app/scripts/r492_uifix4_acceptance.py | tee -a "$LOG"
dc exec "$CANDIDATE" env PYTHONPATH=/app python /app/scripts/r492_uifix5_acceptance.py | tee -a "$LOG"
dc exec "$CANDIDATE" env PYTHONPATH=/app python /app/scripts/r492_uifix6_acceptance.py | tee -a "$LOG"
dc exec "$CANDIDATE" env PYTHONPATH=/app python -m unittest discover -s tests -p 'test_*.py' -q | tee -a "$LOG"
dc exec "$CANDIDATE" env PYTHONPATH=/app python /app/scripts/runtime_smoke.py --clients 2 --ready-timeout 30 | tee -a "$LOG"
dc exec "$CANDIDATE" python - <<'PY' | tee -a "$LOG"
from pathlib import Path
html=Path('/app/static/index.html').read_text(); css=Path('/app/static/nova.css').read_text(); api=Path('/app/app/api/app.py').read_text()
assert 're-accel.js' in html and 'edge-alert-center.js' in html and 'edge-performance.js' in html
assert 'R492 UIFIX6' in css
for ep in ("@app.get('/api/re-accel')","@app.get('/api/edge-alerts')","@app.get('/api/edge-performance')","@app.get('/api/feed-truth')","@app.get('/api/nxt-after-edge')"): assert ep in api
reacc=Path('/app/app/addons/reaccel_verify.py').read_text(); alerts=Path('/app/app/addons/edge_alerts.py').read_text(); perf=Path('/app/app/storage/edge_outcomes.py').read_text()
assert ('DISPLAY/VERIFY' in reacc or 'Display/verify' in reacc) and 'REST.post(' not in reacc and 'websockets.connect(' not in reacc
assert 'REST.post(' not in alerts and 'websockets.connect(' not in alerts
assert "('10M',day,at+600)" in perf and "('30M',day,at+1800)" in perf and "advance_trading_day(day,n)" in perf
print('UIFIX6_CANDIDATE=PASS reaccel=1 second_wave=1 unified_alerts=1 performance_closed_loop=1 feed_truth=1 nxt_after_edge=1 no_new_broker_transport=1')
PY
dc rm -f "$CANDIDATE" >/dev/null
CAND_STARTED=0

say "5/9 ATOMIC CUTOVER — EXACT CURRENT MIV1 BACKUP KEPT STOPPED"
if [ "$(dc inspect "$APP" --format '{{.State.Running}}')" = "true" ]; then dc stop -t 5 "$APP" >/dev/null; OLD_STOPPED=1; fi
dc rename "$APP" "$BACKUP"; OLD_RENAMED=1; STATE_MUTATED=1
[ "$(image_id "$BACKUP")" = "$BASELINE_IMAGE_ID" ] || { echo "FAIL: backup image is not exact pre-UIFIX6 image"; exit 1; }
[ "$(image_version "$BACKUP")" = "$BASELINE_VERSION" ] || { echo "FAIL: backup version is not current MIV1"; exit 1; }
[ "$(image_uifix "$BACKUP")" != "$EXPECTED_UIFIX_LABEL" ] || { echo "FAIL: backup unexpectedly already UIFIX6"; exit 1; }
[ "$(dc inspect "$BACKUP" --format '{{.State.Running}}')" = "false" ] || { echo "FAIL: MIV1 backup unexpectedly running"; exit 1; }
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
[ "$(image_uifix "$APP")" = "$EXPECTED_UIFIX_LABEL" ]

say "6/9 ACTIVE GATES — R492/MIV1 FROZEN + UIFIX DISPLAY/MANAGEMENT ONLY"
dc exec "$APP" env PYTHONPATH=/app python /app/scripts/max_profit_acceptance.py | tee -a "$LOG"
dc exec "$APP" env PYTHONPATH=/app python /app/scripts/market_rotation_acceptance.py | tee -a "$LOG"
dc exec "$APP" env PYTHONPATH=/app python /app/scripts/r492_safe_extension_acceptance.py | tee -a "$LOG"
dc exec "$APP" env PYTHONPATH=/app python /app/scripts/r492_market_index_verify_acceptance.py | tee -a "$LOG"
dc exec "$APP" env PYTHONPATH=/app python /app/scripts/r492_uifix3_acceptance.py | tee -a "$LOG"
dc exec "$APP" env PYTHONPATH=/app python /app/scripts/r492_uifix4_acceptance.py | tee -a "$LOG"
dc exec "$APP" env PYTHONPATH=/app python /app/scripts/r492_uifix5_acceptance.py | tee -a "$LOG"
dc exec "$APP" env PYTHONPATH=/app python /app/scripts/r492_uifix6_acceptance.py | tee -a "$LOG"
dc exec "$APP" env PYTHONPATH=/app python /app/scripts/runtime_smoke.py --clients 2 --ready-timeout 30 | tee -a "$LOG"
dc exec "$APP" python - "$EXPECTED_VERSION" <<'PY' | tee -a "$LOG"
import json,os,sys,urllib.request
expected=sys.argv[1]
t=(os.getenv('NOVA_UI_ACCESS_TOKEN') or os.getenv('APP_ACCESS_TOKEN') or '').strip(); h={'X-App-Token':t,'Authorization':'Bearer '+t} if t else {}
def get(p):
  with urllib.request.urlopen(urllib.request.Request('http://127.0.0.1:8000'+p,headers=h),timeout=8) as r:return json.load(r)
live=get('/api/livez'); ready=get('/api/readyz'); ft=get('/api/feed-truth'); ae=get('/api/nxt-after-edge'); ra=get('/api/re-accel'); al=get('/api/edge-alerts'); pf=get('/api/edge-performance')
assert live.get('ok') and live.get('version')==expected,live
assert ready.get('ok') is True,ready
fc=ft.get('contracts') or {}; assert fc.get('official_rank_effect')==0 and fc.get('official_buy_effect')==0 and fc.get('new_broker_rest_calls')==0 and fc.get('new_ws_subscription_types')==0,fc
ac=ae.get('contracts') or {}; assert ac.get('official_buy_logic_changed') is False and ac.get('new_ws_subscription_types')==0 and ac.get('ws_item_ceiling_increase')==0,ac
rc=ra.get('contracts') or {}; assert rc.get('mode')=='VERIFY_DISPLAY_ONLY' and rc.get('official_entry_v18_changed') is False and rc.get('official_buy_changed') is False and rc.get('official_pre_rank_changed') is False,rc
assert rc.get('new_broker_rest_calls')==0 and rc.get('new_ws_types')==0 and rc.get('ws_capacity_increase')==0 and rc.get('listing_market_rs_only') is True,rc
alc=al.get('contracts') or {}; assert alc.get('broker_calls')==0 and alc.get('ws_types')==0 and alc.get('order_effect')==0 and alc.get('client_master_default') is False,alc
pc=pf.get('contracts') or {}; assert pc.get('verify_only') is True and pc.get('broker_rest_calls')==0 and pc.get('ws_types')==0 and pc.get('official_rank_effect')==0 and pc.get('official_buy_effect')==0,pc
assert pc.get('horizons')==['10M','30M','CLOSE','1D','3D','5D'],pc
print(json.dumps({'ok':True,'version':expected,'feed_truth':True,'nxt_after_edge':True,'reaccel_verify':True,'unified_alerts':True,'performance_closed_loop':True,'official_rank_effect':0,'official_buy_effect':0,'new_broker_rest':0,'new_ws_type':0},ensure_ascii=False))
PY
verify_protected

say "7/9 10-MIN LOAD OBSERVATION — 3 BAD SAMPLES => IMMEDIATE EXACT PRE-UIFIX6 RESTORE"
OBSERVE_SEC="${NOVA_UIFIX6_OBSERVE_SEC:-600}"
BAD_STREAK=0; START_OBS="$(date +%s)"
while (( $(date +%s) - START_OBS < OBSERVE_SEC )); do
  ELAPSED=$(( $(date +%s) - START_OBS ))
  if OBS_LINE="$(dc exec "$APP" python - <<'PY' 2>&1
import json,os,urllib.request
t=(os.getenv('NOVA_UI_ACCESS_TOKEN') or os.getenv('APP_ACCESS_TOKEN') or '').strip(); h={'X-App-Token':t,'Authorization':'Bearer '+t} if t else {}
def get(p):
  with urllib.request.urlopen(urllib.request.Request('http://127.0.0.1:8000'+p,headers=h),timeout=5) as r:return json.load(r)
x=get('/api/realtime-health'); mi=get('/api/market-index-verify'); ae=get('/api/nxt-after-edge'); ft=get('/api/feed-truth'); m=x.get('memory') or {}; load=str(x.get('load_mode') or '')
swap=float(m.get('swap_mb') or 0); lag=float(x.get('event_loop_lag_p95_ms') or 0); qage=float(x.get('trade_queue_oldest_age_ms') or 0); q=int(x.get('trade_queue_depth') or 0)
c=mi.get('contracts') or {}; assert c.get('rank_or_score_adjustment_applied') is False and c.get('relative_formula_applied') is False
ac=ae.get('contracts') or {}; assert ac.get('official_buy_logic_changed') is False and ac.get('new_ws_subscription_types')==0 and ac.get('ws_item_ceiling_increase')==0 and ac.get('additional_rest_calls_per_after_cycle_max')==8
fc=ft.get('contracts') or {}; assert fc.get('official_score_effect')==0 and fc.get('official_rank_effect')==0 and fc.get('official_buy_effect')==0 and fc.get('new_broker_rest_calls')==0 and fc.get('new_ws_subscription_types')==0
print(json.dumps({'load':load,'swap':swap,'lag_p95':lag,'queue_age_ms':qage,'queue':q,'index_status':mi.get('status'),'after_edge_status':ae.get('status'),'feed_truth':ft.get('overall'),'feed_decision':ft.get('decision')},ensure_ascii=False))
assert swap==0; assert lag<=250; assert qage<=750; assert load!='CRITICAL'
PY
)"; then
    BAD_STREAK=0; echo "OBSERVE ${ELAPSED}/${OBSERVE_SEC}s · ${OBS_LINE}" | tee -a "$LOG"
  else
    BAD_STREAK=$((BAD_STREAK+1)); echo "WARN ${ELAPSED}/${OBSERVE_SEC}s · bad_streak=$BAD_STREAK · ${OBS_LINE}" | tee -a "$LOG"
  fi
  if (( BAD_STREAK >= 3 )); then echo "FAIL: sustained load/lag failure -> automatic exact pre-UIFIX6 MIV1 rollback" | tee -a "$LOG"; false; fi
  sleep 10
done
verify_protected

say "8/9 FINAL STATUS"
dc ps --filter "name=^/${APP}$" --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}' | tee -a "$LOG"
echo "ACTIVE_VERSION=$(image_version "$APP") UIFIX=$(image_uifix "$APP")" | tee -a "$LOG"
echo "MIV1_BACKUP=$BACKUP IMAGE_ID=$(image_id "$BACKUP") VERSION=$(image_version "$BACKUP") UIFIX=$(image_uifix "$BACKUP")" | tee -a "$LOG"

say "9/9 SUCCESS"
trap - ERR INT TERM EXIT
cleanup
echo "RESULT=SUCCESS VERSION=$EXPECTED_VERSION UIFIX=$EXPECTED_UIFIX_LABEL CURRENT=$APP ROLLBACK_CONTAINER=$BACKUP" | tee -a "$LOG"
echo "CONTRACT=R492_CORE_FROZEN MIV1_PRESERVED=1 PRE_STABLE60=1 DWELL120=1 GAP5X2=1 NXT_BURST_VERIFY=1 NXT_AFTER_EDGE_VERIFY=1 FEED_TRUTH_MONITOR=1 REACCEL_VERIFY=1 SECOND_ENTRY_VERIFY=1 UNIFIED_ALERTS_MASTER_OFF=1 PERFORMANCE_10M_30M_CLOSE_1D_3D_5D=1 MFE_MAE_LEADTIME=1 ENERGY_FIXED10=1 PATH_FIXED10=1 SIGNAL_HISTORY_TOP30=1 LISTING_MARKET_RS=1 NEW_BROKER_REST=0 NEW_WS_TYPE=0 RANK_EFFECT=0 BUY_EFFECT=0" | tee -a "$LOG"
echo "LOG=$LOG"
