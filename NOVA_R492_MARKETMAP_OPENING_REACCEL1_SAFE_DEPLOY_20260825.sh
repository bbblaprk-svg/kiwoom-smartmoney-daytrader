#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

REPO="bbblaprk-svg/kiwoom-smartmoney-daytrader"
BRANCH="main"
APP="${NOVA_APP_CONTAINER:-quant-nova}"
REMOTE_DOCKERFILE="Dockerfile"
EXPECTED_DOCKERFILE_SHA="c44fa03d881162d60ebfc839e829df24bd71f6a0a234b9598410aa2ba3ab8f79"
EXPECTED_EMBEDDED_SOURCE_SHA="399cfb92e32fd827628da6486cd59e62780333d46084a77f812b29b61703bf0c"
EXPECTED_VERSION="NOVA-3.3.5-R492-MARKET-INDEX-VERIFY1"
EXPECTED_CLOSEBET_LABEL="KRX_CLOSE6__NXT_POOL15_EARLY1540_CLOSE1830_LOCK1957__REPEAT_CAP5_FRESH_LANES"
EXPECTED_PATCH_LABEL="CANONICAL_LISTING_AUTHORITATIVE__NXT_TENTATIVE_NO_OVERWRITE__OPENING_SHAKEOUT_RECLAIM_0900_0920"
PREREQ_UIFIX7="CLOSE_FROZEN_PERSIST_TRISTATE_SPARSE_IO_R2"
PREREQ_MIV1="NOVA-3.3.5-R492-MARKET-INDEX-VERIFY1"
BASELINE_R492="NOVA-3.3.5-R492-FRESH-ENERGY-PATH-SAFE"
IMAGE="quant-nova:3.3.5-r492-marketmap-opening-reaccel1-local"
STAMP="$(date +%Y%m%d-%H%M%S)"
PREV_BACKUP="${APP}-pre-mmor1-${STAMP}"
FAILED="${APP}-failed-mmor1-${STAMP}"
CANDIDATE="${APP}-candidate-mmor1-${STAMP}"
WORK="$(mktemp -d /tmp/nova-r492-mmor1.XXXXXX)"
DOCKERFILE="$WORK/Dockerfile"
ENVFILE="$WORK/current.env"
CAND_DATA="$WORK/candidate-data"
LOG="/tmp/nova-r492-mmor1-deploy-${STAMP}.log"
R492_BACKUP=""
OLD_WAS_RUNNING=0
OLD_STOPPED=0
OLD_RENAMED=0
NEW_STARTED=0
CAND_STARTED=0
PROTECTED_SNAPSHOT_READY=0
STATE_MUTATED=0
LOCKFILE="/tmp/nova-r492-mmor1-deploy.lock"
MAX_SWAP_MB="${NOVA_DEPLOY_MAX_SWAP_MB:-8}"

exec 9>"$LOCKFILE"
if ! flock -n 9; then
  echo "INFO: MARKET-MAP + OPENING RE-ACCEL1 deploy is already running. Do not start it twice."
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

image_label(){
  local name="$1" key="$2" iid
  iid="$(dc inspect "$name" --format '{{.Image}}' 2>/dev/null || true)"
  [ -n "$iid" ] || return 0
  dc image inspect "$iid" --format "{{index .Config.Labels \"$key\"}}" 2>/dev/null || true
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
      -H 'Cache-Control: no-cache' "$raw?ts=$(date +%s)" -o "$tmp"; then
    mv "$tmp" "$DOCKERFILE"
    return 0
  fi
  rc=$?
  rm -f "$tmp"
  echo "FAIL: Public GitHub에서 Dockerfile을 읽지 못했습니다. token은 요청하지 않습니다." | tee -a "$LOG"
  echo "FAIL: GitHub 루트 파일명 확인: $REMOTE_DOCKERFILE" | tee -a "$LOG"
  echo "RESULT=ABORTED_NO_CHANGE reason=PUBLIC_DOCKERFILE_FETCH_FAILED curl_rc=$rc" | tee -a "$LOG"
  return "$rc"
}

find_exact_r492_backup(){
  local cand iid ver running
  while IFS= read -r cand; do
    [ -n "$cand" ] || continue
    [ "$cand" = "$APP" ] && continue
    iid="$(dc inspect "$cand" --format '{{.Image}}' 2>/dev/null || true)"
    [ -n "$iid" ] || continue
    ver="$(dc image inspect "$iid" --format '{{index .Config.Labels "org.opencontainers.image.version"}}' 2>/dev/null || true)"
    [ "$ver" = "$BASELINE_R492" ] || continue
    running="$(dc inspect "$cand" --format '{{.State.Running}}' 2>/dev/null || true)"
    [ "$running" = "false" ] || continue
    printf '%s\n' "$cand"
    return 0
  done < <(dc ps -a --format '{{.Names}}' | sort -r || true)
  return 1
}

restore_exact_r492(){
  local curver restored
  if dc inspect "$APP" >/dev/null 2>&1; then
    curver="$(image_version "$APP")"
    if [ "$curver" = "$BASELINE_R492" ]; then
      dc start "$APP" >/dev/null 2>&1 || true
      wait_health "$APP"
      echo "R492_RESTORE=ALREADY_BASELINE version=$curver" | tee -a "$LOG"
      return 0
    fi
  fi
  [ -n "$R492_BACKUP" ] || { echo "CRITICAL: exact R492 backup reference is empty" | tee -a "$LOG"; return 1; }
  [ "$(image_version "$R492_BACKUP")" = "$BASELINE_R492" ] || {
    echo "CRITICAL: rollback source is no longer exact R492: $R492_BACKUP" | tee -a "$LOG"; return 1; }

  if [ "$CAND_STARTED" -eq 1 ] && dc inspect "$CANDIDATE" >/dev/null 2>&1; then
    dc rm -f "$CANDIDATE" >/dev/null 2>&1 || true
  fi

  if dc inspect "$APP" >/dev/null 2>&1; then
    curver="$(image_version "$APP")"
    dc stop -t 5 "$APP" >/dev/null 2>&1 || true
    if dc inspect "$FAILED" >/dev/null 2>&1; then dc rm -f "$FAILED" >/dev/null 2>&1 || true; fi
    dc rename "$APP" "$FAILED" >/dev/null
  fi

  dc stop -t 5 "$R492_BACKUP" >/dev/null 2>&1 || true
  dc rename "$R492_BACKUP" "$APP" >/dev/null
  R492_BACKUP="$APP"
  dc start "$APP" >/dev/null
  wait_health "$APP"
  restored="$(image_version "$APP")"
  [ "$restored" = "$BASELINE_R492" ] || {
    echo "CRITICAL: restored version $restored != $BASELINE_R492" | tee -a "$LOG"; return 1; }
  echo "R492_RESTORE=PASS source=verified_exact_baseline version=$restored" | tee -a "$LOG"
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
  restore_exact_r492 || true
  verify_protected || true
  echo "RESULT=ROLLED_BACK CURRENT=$APP RESTORED_VERSION=$(image_version "$APP") EXPECTED=$BASELINE_R492 LOG=$LOG" | tee -a "$LOG"
  cleanup
  exit "${rc:-1}"
}
trap rollback ERR INT TERM EXIT

say "1/9 FETCH MARKET-MAP + OPENING RE-ACCEL1 DOCKERFILE + SHA LOCK"
fetch_dockerfile
ACTUAL_SHA="$(sha256sum "$DOCKERFILE" | awk '{print $1}')"
echo "DOCKERFILE_SHA256=$ACTUAL_SHA" | tee -a "$LOG"
[ "$ACTUAL_SHA" = "$EXPECTED_DOCKERFILE_SHA" ] || { echo "FAIL: GitHub Dockerfile이 승인본과 다릅니다."; exit 1; }
grep -Fq "$EXPECTED_VERSION" "$DOCKERFILE"

say "1A/9 FULL EMBEDDED-SOURCE RESTORE/PREFLIGHT — CURRENT APP UNTOUCHED"
PYBIN="$(command -v python3 || command -v python || true)"
[ -n "$PYBIN" ] || { echo "FAIL: host python3/python is required for embedded-source preflight"; exit 1; }
"$PYBIN" - "$DOCKERFILE" "$EXPECTED_EMBEDDED_SOURCE_SHA" <<'PY' | tee -a "$LOG"
import base64,hashlib,io,pathlib,re,subprocess,sys,tarfile,tempfile
p=pathlib.Path(sys.argv[1]); expected_source=sys.argv[2]; text=p.read_text()
parts=re.findall(r"RUN printf '%s' '([^']*)' >> /tmp/nova-source\.tar\.gz\.b64",text)
if not parts: raise SystemExit('PREFLIGHT_FAIL: embedded payload not found')
raw=base64.b64decode(''.join(parts),validate=True); actual=hashlib.sha256(raw).hexdigest()
if actual!=expected_source: raise SystemExit(f'PREFLIGHT_FAIL: embedded source SHA {actual} != {expected_source}')
protected={
'app/signal/policy.py':'18cb96ef1afb9de48136d39c3e9b8216e62a94dccf0229aa027479783eb9151a',
'app/broker/kiwoom.py':'e10d936a2540a70d8a488e0460608a3c2a1a8bfaf95dc6206e706cce3afab0d1',
'app/broker/websocket.py':'50fefc5faa1457210af758636279bea0bc3926e505bc91317962a0d451e35602',
'app/service.py':'e325b7a76d6ddfa291b800ef97fb13e6b85fa9bb9ccb2365130ef2d5abf512c3',
'app/addons/energy_path.py':'cd403cda76cb9d515c9228bf310287ad639bed125075fa835a3607cac2e81595',
'static/nova.js':'8f0904af264a3a8eda2d874dda25ce8086fb66d1751b592a9be0d6069b5ee1f6',
'ops/http_guard_v2.py':'c07332eb6951c51b433f42059133dd22b5e28a0c137f07b9f177f814dbe1ec1b'}
with tempfile.TemporaryDirectory(prefix='nova-r492-mmor1-preflight-') as td:
    root=pathlib.Path(td)
    with tarfile.open(fileobj=io.BytesIO(raw),mode='r:gz') as tf:
        names=set()
        for m in tf.getmembers():
            name=m.name.replace('\\','/'); logical=name[2:] if name.startswith('./') else name
            if name.startswith('/') or '..' in name.split('/') or m.isdev() or m.issym() or m.islnk(): raise SystemExit('PREFLIGHT_FAIL: unsafe tar member '+m.name)
            names.add(logical)
        required={'app/main.py','app/addons/close_bet_center.py','app/addons/close_bet_rules.py','static/close-bet-center.js','static/close-bet-center.css','scripts/r492_close_bet_fresh_diversity_acceptance.py','R492_CLOSE_BET_FRESH_DIVERSITY_INVARIANTS.md','app/broker/listing_market.py','tests/test_r492_marketmap_opening_reaccel.py','scripts/r492_marketmap_opening_reaccel_acceptance.py','R492_MARKETMAP_OPENING_REACCEL_INVARIANTS.md','SOURCE_MANIFEST.sha256','requirements.txt'}
        missing=sorted(required-names)
        if missing: raise SystemExit('PREFLIGHT_FAIL: missing '+','.join(missing))
        tf.extractall(root)
    if subprocess.run(['sha256sum','-c','SOURCE_MANIFEST.sha256'],cwd=root,stdout=subprocess.DEVNULL,stderr=subprocess.STDOUT).returncode: raise SystemExit('PREFLIGHT_FAIL: SOURCE_MANIFEST mismatch')
    for rel,want in protected.items():
        got=hashlib.sha256((root/rel).read_bytes()).hexdigest()
        if got!=want: raise SystemExit(f'PREFLIGHT_FAIL: frozen core changed {rel}: {got}')
    idx=(root/'static/index.html').read_text(); main=idx[idx.index('<main>'):idx.index('</main>')+len('</main>')]
    if hashlib.sha256(main.encode()).hexdigest()!='f04ae99c607fbe0080d57ae869b4d9fe89b38b47f327bf12161ed4f3b76dad7c': raise SystemExit('PREFLIGHT_FAIL: protected <main> changed')
    cb=(root/'app/addons/close_bet_center.py').read_text(); rules=(root/'app/addons/close_bet_rules.py').read_text(); dom=(root/'app/domain.py').read_text(); dsp=(root/'app/runtime/display.py').read_text()
    if 'REST.post(' in cb or 'WebSocket' in cb or 'subscribe(' in cb: raise SystemExit('PREFLIGHT_FAIL: close-bet layer contains broker transport call')
    for token in ('NXT_POOL = 15','FINAL_MAX = 6','NXT_CLOSE_LOCK = 19 * 3600 + 57 * 60'):
        if token not in rules: raise SystemExit('PREFLIGHT_FAIL: missing rule '+token)
    if 'repeat_confidence_bonus' not in dom or 'reentry_bonus=0.0' not in dom: raise SystemExit('PREFLIGHT_FAIL: repeat cap missing')
    if 'pre_desired=self._compose_anchor_fresh' not in dsp or 'nxt_desired=self._compose_anchor_fresh' not in dsp: raise SystemExit('PREFLIGHT_FAIL: fresh lanes missing')
    lm=(root/'app/broker/listing_market.py').read_text(); disc=(root/'app/broker/discovery.py').read_text(); nxt=(root/'app/broker/nxt_after_edge.py').read_text(); reacc=(root/'app/addons/reaccel_verify.py').read_text()
    if 'AUTHORITATIVE' not in lm or 'TENTATIVE' not in lm or 'assign_listing_market' not in lm: raise SystemExit('PREFLIGHT_FAIL: canonical market writer missing')
    if 'authoritative=bool' not in disc or 'authoritative=False' not in nxt: raise SystemExit('PREFLIGHT_FAIL: listing confidence routing missing')
    offenders=[]
    for fp in (root/'app').rglob('*.py'):
        if fp.name=='listing_market.py': continue
        tx=fp.read_text()
        if "metrics['listing_market_name'] =" in tx or 'metrics["listing_market_name"] =' in tx: offenders.append(str(fp.relative_to(root)))
    if offenders: raise SystemExit('PREFLIGHT_FAIL: direct listing writes '+','.join(offenders))
    for token in ('09:00~09:20','GAP_SHAKEOUT_WAIT','GAP_SHAKEOUT_REACCEL','opening_gap_guard','opening_bonus = 8.0'):
        if token not in reacc: raise SystemExit('PREFLIGHT_FAIL: opening reaccel token '+token)
    if 'REST.post(' in reacc or 'WebSocket' in reacc or 'subscribe(' in reacc: raise SystemExit('PREFLIGHT_FAIL: reaccel added broker transport')
    subprocess.run([sys.executable,'-m','py_compile',str(root/'app/addons/close_bet_center.py'),str(root/'app/addons/close_bet_rules.py'),str(root/'app/broker/listing_market.py'),str(root/'app/broker/discovery.py'),str(root/'app/broker/nxt_after_edge.py'),str(root/'app/addons/reaccel_verify.py')],check=True)
print(f'PREFLIGHT_PAYLOAD=PASS chunks={len(parts)} gzip_bytes={len(raw)} gzip_sha256={actual} manifest=PASS protected_core=7 main_dom=UNCHANGED close_bet_pool=15 final_max=6 repeat_cap=5 marketmap=CANONICAL opening_reaccel=0900_0920 new_rest=0 new_ws=0')
PY

say "2/9 REQUIRE UIFIX7R2 LINEAGE + VERIFY EXACT R492 ROLLBACK SOURCE"
dc inspect "$APP" >/dev/null
CURRENT_VERSION="$(image_version "$APP")"
CURRENT_CLOSEBET="$(image_label "$APP" io.quantnova.r492_close_bet_fresh_diversity1)"
CURRENT_PATCH="$(image_label "$APP" io.quantnova.r492_marketmap_opening_reaccel1)"
CURRENT_UIFIX7="$(image_label "$APP" io.quantnova.r492_uifix7)"
echo "current_version=${CURRENT_VERSION:-UNKNOWN} uifix7=${CURRENT_UIFIX7:-NONE} closebet_fresh=${CURRENT_CLOSEBET:-NONE} marketmap_opening=${CURRENT_PATCH:-NONE}" | tee -a "$LOG"
if [ "$CURRENT_VERSION" = "$EXPECTED_VERSION" ] && [ "$CURRENT_PATCH" = "$EXPECTED_PATCH_LABEL" ]; then
  echo "INFO: MARKET-MAP + OPENING RE-ACCEL1 already deployed. Health/acceptance only." | tee -a "$LOG"
  wait_health "$APP"
  dc exec "$APP" env PYTHONPATH=/app python /app/scripts/r492_close_bet_fresh_diversity_acceptance.py | tee -a "$LOG"
  dc exec "$APP" env PYTHONPATH=/app python /app/scripts/r492_marketmap_opening_reaccel_acceptance.py | tee -a "$LOG"
  trap - ERR INT TERM EXIT
  cleanup
  echo "RESULT=ALREADY_DEPLOYED VERSION=$EXPECTED_VERSION PATCH=$EXPECTED_PATCH_LABEL CURRENT=$APP LOG=$LOG"
  exit 0
fi
[ "$CURRENT_VERSION" = "$PREREQ_MIV1" ] || { echo "FAIL: current version=$CURRENT_VERSION need=$PREREQ_MIV1; no change" | tee -a "$LOG"; exit 1; }
[ "$CURRENT_UIFIX7" = "$PREREQ_UIFIX7" ] || { echo "FAIL: current UIFIX7 lineage is not approved UIFIX7R2; no change" | tee -a "$LOG"; exit 1; }
wait_health "$APP"
dc exec "$APP" env PYTHONPATH=/app python /app/scripts/r492_market_index_verify_acceptance.py | tee -a "$LOG"
dc exec "$APP" env PYTHONPATH=/app python /app/scripts/r492_uifix7_acceptance.py | tee -a "$LOG"
R492_BACKUP="$(find_exact_r492_backup || true)"
[ -n "$R492_BACKUP" ] || {
  echo "FAIL: 실배포 실패 시 복귀할 정확한 R492 백업 컨테이너를 찾지 못했습니다. 아무것도 변경하지 않습니다." | tee -a "$LOG"; exit 1; }
[ "$(image_version "$R492_BACKUP")" = "$BASELINE_R492" ] || { echo "FAIL: R492 backup version mismatch" | tee -a "$LOG"; exit 1; }
echo "VERIFIED_R492_ROLLBACK_SOURCE=$R492_BACKUP VERSION=$(image_version "$R492_BACKUP")" | tee -a "$LOG"
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

say "3/9 RESOURCE PREFLIGHT; STOP CURRENT UIFIX7R2 ONLY FOR LOW-RAM BUILD"
FREE_KB="$(df -Pk /var/lib/docker 2>/dev/null | awk 'NR==2{print $4}')"; [ -n "$FREE_KB" ] || FREE_KB="$(df -Pk / | awk 'NR==2{print $4}')"
echo "pre_stop_free_kb=$FREE_KB" | tee -a "$LOG"
(( FREE_KB >= 1400000 )) || { echo "FAIL: Docker disk free ${FREE_KB}KB < 1.4GB; current UIFIX7R2 untouched"; exit 1; }
if [ "$OLD_WAS_RUNNING" -eq 1 ]; then dc stop -t 10 "$APP" >/dev/null; OLD_STOPPED=1; STATE_MUTATED=1; fi
AVAIL_MB="$(free -m | awk '/Mem:/{print $7}')"
echo "post_stop_available_mb=$AVAIL_MB" | tee -a "$LOG"
(( AVAIL_MB >= 350 )) || { echo "FAIL: available RAM ${AVAIL_MB}MB < 350MB; exact R492 auto-restore"; exit 1; }
DOCKER_BUILDKIT=1 dc build --pull --no-cache -f "$DOCKERFILE" -t "$IMAGE" "$WORK" | tee -a "$LOG"
[ "$(dc image inspect "$IMAGE" --format '{{index .Config.Labels "org.opencontainers.image.version"}}')" = "$EXPECTED_VERSION" ]
[ "$(dc image inspect "$IMAGE" --format '{{index .Config.Labels "io.quantnova.r492_uifix7"}}')" = "$PREREQ_UIFIX7" ]
[ "$(dc image inspect "$IMAGE" --format '{{index .Config.Labels "io.quantnova.r492_close_bet_fresh_diversity1"}}')" = "$EXPECTED_CLOSEBET_LABEL" ]
[ "$(dc image inspect "$IMAGE" --format '{{index .Config.Labels "io.quantnova.r492_marketmap_opening_reaccel1"}}')" = "$EXPECTED_PATCH_LABEL" ]
[ "$(dc image inspect "$IMAGE" --format '{{index .Config.Labels "io.quantnova.listing_market_policy"}}')" = "KRX_INTEGRATED_AUTHORITATIVE__NXT_TENTATIVE_FAIL_CLOSED" ]
[ "$(dc image inspect "$IMAGE" --format '{{index .Config.Labels "io.quantnova.opening_reaccel_policy"}}')" = "GAPUP1__FLUSH1__RECLAIM045_FLOW__VERIFY_ONLY" ]
[ "$(dc image inspect "$IMAGE" --format '{{index .Config.Labels "io.quantnova.close_bet_new_broker_rest_calls"}}')" = "0" ]
[ "$(dc image inspect "$IMAGE" --format '{{index .Config.Labels "io.quantnova.close_bet_new_ws_subscription_types"}}')" = "0" ]
[ "$(dc image inspect "$IMAGE" --format '{{index .Config.Labels "io.quantnova.close_bet_official_buy_effect"}}')" = "0" ]
[ "$(dc image inspect "$IMAGE" --format '{{index .Config.Labels "io.quantnova.close_bet_price_rise_primary"}}')" = "0" ]
[ "$(dc image inspect "$IMAGE" --format '{{index .Config.Labels "io.quantnova.repeat_rank_policy"}}')" = "FORMAL_REPEAT_CAP5_TOP10_REENTRY0" ]
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
dc exec "$CANDIDATE" env PYTHONPATH=/app python /app/scripts/r492_uifix7_acceptance.py | tee -a "$LOG"
dc exec "$CANDIDATE" env PYTHONPATH=/app python /app/scripts/r492_close_bet_fresh_diversity_acceptance.py | tee -a "$LOG"
dc exec "$CANDIDATE" env PYTHONPATH=/app python /app/scripts/r492_marketmap_opening_reaccel_acceptance.py | tee -a "$LOG"
dc exec "$CANDIDATE" env NOVA_OFFLINE=0 NOVA_CANDIDATE_MODE=0 NOVA_MARKET_INDEX_VERIFY_ENABLED=1 PYTHONPATH=/app python -m unittest tests.test_r49_signal_acceleration tests.test_r492_market_index_verify tests.test_r492_close_bet_fresh_diversity tests.test_r492_marketmap_opening_reaccel -q | tee -a "$LOG"
dc exec "$CANDIDATE" env NOVA_RUNTIME_SMOKE_MAX_SWAP_MB="$MAX_SWAP_MB" PYTHONPATH=/app python /app/scripts/runtime_smoke.py --clients 2 --ready-timeout 30 | tee -a "$LOG"
dc exec "$CANDIDATE" python - <<'PY' | tee -a "$LOG"
import json,os,urllib.request
t=(os.getenv('NOVA_UI_ACCESS_TOKEN') or os.getenv('APP_ACCESS_TOKEN') or '').strip(); h={'X-App-Token':t,'Authorization':'Bearer '+t} if t else {}
def get(p):
  with urllib.request.urlopen(urllib.request.Request('http://127.0.0.1:8000'+p,headers=h),timeout=6) as r:return json.load(r)
cb=get('/api/close-bet-center'); c=cb.get('contracts') or {}; ra=get('/api/re-accel'); rc=ra.get('contracts') or {}
assert cb.get('mode')=='VERIFY_DISPLAY_ONLY',cb
assert rc.get('opening_shakeout_pattern')=='09:00~09:20 GAP_UP -> FLUSH -> FLOW_RECLAIM -> SECOND_ENTRY',rc
assert rc.get('opening_shakeout_new_broker_calls')==0 and rc.get('official_entry_v18_changed') is False,rc
assert len(cb.get('krx') or [])<=6 and len(cb.get('nxt') or [])<=15,cb
assert cb.get('final_max')==6 and cb.get('nxt_pool_cap')==15,cb
assert c.get('official_buy_logic_changed') is False and c.get('entry_v18_changed') is False,c
assert c.get('new_broker_rest_calls')==0 and c.get('new_ws_subscription_types')==0,c
assert c.get('price_rise_is_primary_rank') is False,c
print(json.dumps({'candidate_close_bet_center':'PASS','marketmap_opening_reaccel':'PASS','krx_mode':cb.get('krx_mode'),'nxt_mode':cb.get('nxt_mode'),'pool':len(cb.get('nxt') or []),'final':cb.get('nxt_final_count')},ensure_ascii=False))
PY
dc rm -f "$CANDIDATE" >/dev/null
CAND_STARTED=0

say "5/9 ATOMIC CUTOVER — UIFIX7R2 BACKUP + EXACT R492 BACKUP PRESERVED"
# Current UIFIX7R2 is already stopped from build.
[ "$(image_version "$APP")" = "$PREREQ_MIV1" ] || { echo "FAIL: pre-cutover app version changed"; exit 1; }
[ "$(image_label "$APP" io.quantnova.r492_uifix7)" = "$PREREQ_UIFIX7" ] || { echo "FAIL: pre-cutover UIFIX7 lineage changed"; exit 1; }
dc rename "$APP" "$PREV_BACKUP"; OLD_RENAMED=1; STATE_MUTATED=1
[ "$(image_version "$PREV_BACKUP")" = "$PREREQ_MIV1" ] || { echo "FAIL: UIFIX7R2 backup version mismatch"; exit 1; }
[ "$(image_label "$PREV_BACKUP" io.quantnova.r492_uifix7)" = "$PREREQ_UIFIX7" ] || { echo "FAIL: UIFIX7R2 backup label mismatch"; exit 1; }
[ "$(dc inspect "$PREV_BACKUP" --format '{{.State.Running}}')" = "false" ] || { echo "FAIL: UIFIX7R2 backup unexpectedly running"; exit 1; }
[ "$(image_version "$R492_BACKUP")" = "$BASELINE_R492" ] || { echo "FAIL: exact R492 rollback source changed"; exit 1; }
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

say "6/9 ACTIVE GATES — MARKET MAP + OPENING RE-ACCEL + CLOSE BET + R492 CORE PROTECTED"
dc exec "$APP" env PYTHONPATH=/app python /app/scripts/max_profit_acceptance.py | tee -a "$LOG"
dc exec "$APP" env PYTHONPATH=/app python /app/scripts/market_rotation_acceptance.py | tee -a "$LOG"
dc exec "$APP" env PYTHONPATH=/app python /app/scripts/r42_fresh_scout_acceptance.py | tee -a "$LOG"
dc exec "$APP" env PYTHONPATH=/app python /app/scripts/r492_safe_extension_acceptance.py | tee -a "$LOG"
dc exec "$APP" env PYTHONPATH=/app python /app/scripts/r492_market_index_verify_acceptance.py | tee -a "$LOG"
dc exec "$APP" env PYTHONPATH=/app python /app/scripts/r492_uifix7_acceptance.py | tee -a "$LOG"
dc exec "$APP" env PYTHONPATH=/app python /app/scripts/r492_close_bet_fresh_diversity_acceptance.py | tee -a "$LOG"
dc exec "$APP" env PYTHONPATH=/app python /app/scripts/r492_marketmap_opening_reaccel_acceptance.py | tee -a "$LOG"
dc exec "$APP" env NOVA_RUNTIME_SMOKE_MAX_SWAP_MB="$MAX_SWAP_MB" PYTHONPATH=/app python /app/scripts/runtime_smoke.py --clients 2 --ready-timeout 30 | tee -a "$LOG"
dc exec "$APP" python - "$EXPECTED_VERSION" "$MAX_SWAP_MB" <<'PY' | tee -a "$LOG"
import json,os,sys,urllib.request
expected=sys.argv[1]; max_swap=float(sys.argv[2])
t=(os.getenv('NOVA_UI_ACCESS_TOKEN') or os.getenv('APP_ACCESS_TOKEN') or '').strip(); h={'X-App-Token':t,'Authorization':'Bearer '+t} if t else {}
def get(p):
  with urllib.request.urlopen(urllib.request.Request('http://127.0.0.1:8000'+p,headers=h),timeout=8) as r:return json.load(r)
live=get('/api/livez'); ready=get('/api/readyz'); health=get('/api/realtime-health'); panels=get('/api/decision-panels'); mi=get('/api/market-index-verify'); cb=get('/api/close-bet-center'); ra=get('/api/re-accel')
assert live.get('ok') and live.get('version')==expected,live
assert ready.get('ok') is True,ready
pc=panels.get('contracts') or {}; assert panels.get('ok') is True,panels
assert pc.get('official_buy_logic_changed') is False,pc
assert pc.get('r492_new_broker_rest_calls')==0 and pc.get('r492_new_ws_subscription_types')==0,pc
assert len(panels.get('preignition') or [])<=20 and len(panels.get('energy') or [])<=10 and len(panels.get('path') or [])<=10,panels
mc=mi.get('contracts') or {}
assert mi.get('ok') is True and mi.get('mode')=='VERIFY_DISPLAY_ONLY',mi
assert mc.get('rank_or_score_adjustment_applied') is False and mc.get('display_only') is True,mc
assert mc.get('new_ws_subscription_types')==0 and mc.get('broker_rest_calls_per_refresh_max')==2,mc
cc=cb.get('contracts') or {}
assert cb.get('ok') is True and cb.get('mode')=='VERIFY_DISPLAY_ONLY',cb
assert len(cb.get('krx') or [])<=6 and len(cb.get('nxt') or [])<=15,cb
assert cc.get('official_buy_logic_changed') is False and cc.get('entry_v18_changed') is False,cc
assert cc.get('new_broker_rest_calls')==0 and cc.get('new_ws_subscription_types')==0,cc
assert cc.get('price_rise_is_primary_rank') is False,cc
assert cb.get('final_max')==6 and cb.get('nxt_pool_cap')==15 and int(cb.get('nxt_final_count') or 0)<=6,cb
rc=ra.get('contracts') or {}; assert rc.get('opening_shakeout_pattern')=='09:00~09:20 GAP_UP -> FLUSH -> FLOW_RECLAIM -> SECOND_ENTRY',rc
assert rc.get('opening_shakeout_new_broker_calls')==0 and rc.get('official_entry_v18_changed') is False and rc.get('official_buy_changed') is False,rc
swap=float((health.get('memory') or {}).get('swap_mb') or 0); assert swap<=max_swap,{'memory':health.get('memory'),'max_swap_mb':max_swap}
print(json.dumps({'ok':True,'version':expected,'baseline_r492_frozen':True,'market_index_verify':True,'close_bet_center':True,'marketmap_opening_reaccel':True,'krx_mode':cb.get('krx_mode'),'nxt_mode':cb.get('nxt_mode'),'krx_rows':len(cb.get('krx') or []),'nxt_pool':len(cb.get('nxt') or []),'nxt_final':cb.get('nxt_final_count'),'close_bet_new_rest':0,'close_bet_new_ws':0,'rank_effect':0,'buy_effect':0,'load_mode':health.get('load_mode'),'swap_mb':swap,'max_swap_mb':max_swap},ensure_ascii=False))
PY
verify_protected

say "7/9 10-MIN LOAD OBSERVATION — 3 BAD SAMPLES => EXACT R492 RESTORE"
OBSERVE_SEC="${NOVA_MMOR1_OBSERVE_SEC:-600}"
BAD_STREAK=0; START_OBS="$(date +%s)"
while (( $(date +%s) - START_OBS < OBSERVE_SEC )); do
  ELAPSED=$(( $(date +%s) - START_OBS ))
  if OBS_LINE="$(dc exec "$APP" env NOVA_RUNTIME_SMOKE_MAX_SWAP_MB="$MAX_SWAP_MB" python - <<'PY' 2>&1
import json,os,urllib.request
t=(os.getenv('NOVA_UI_ACCESS_TOKEN') or os.getenv('APP_ACCESS_TOKEN') or '').strip(); h={'X-App-Token':t,'Authorization':'Bearer '+t} if t else {}
def get(p):
  with urllib.request.urlopen(urllib.request.Request('http://127.0.0.1:8000'+p,headers=h),timeout=5) as r:return json.load(r)
x=get('/api/realtime-health'); mi=get('/api/market-index-verify'); cb=get('/api/close-bet-center')
m=x.get('memory') or {}; load=str(x.get('load_mode') or ''); max_swap=float(os.getenv('NOVA_RUNTIME_SMOKE_MAX_SWAP_MB','8') or 8)
swap=float(m.get('swap_mb') or 0); lag=float(x.get('event_loop_lag_p95_ms') or 0); qage=float(x.get('trade_queue_oldest_age_ms') or 0); q=int(x.get('trade_queue_depth') or 0)
mc=mi.get('contracts') or {}; cc=cb.get('contracts') or {}
assert mc.get('rank_or_score_adjustment_applied') is False
assert cc.get('official_buy_logic_changed') is False and cc.get('entry_v18_changed') is False and cc.get('new_broker_rest_calls')==0 and cc.get('new_ws_subscription_types')==0 and cc.get('price_rise_is_primary_rank') is False
assert len(cb.get('krx') or [])<=6 and len(cb.get('nxt') or [])<=15 and int(cb.get('nxt_final_count') or 0)<=6
print(json.dumps({'load':load,'swap':swap,'lag_p95':lag,'queue_age_ms':qage,'queue':q,'index_status':mi.get('status'),'krx_mode':cb.get('krx_mode'),'nxt_mode':cb.get('nxt_mode'),'krx_rows':len(cb.get('krx') or []),'nxt_pool':len(cb.get('nxt') or []),'nxt_final':cb.get('nxt_final_count')},ensure_ascii=False))
assert swap<=max_swap
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
echo "UIFIX7R2_BACKUP=$PREV_BACKUP VERSION=$(image_version "$PREV_BACKUP")" | tee -a "$LOG"
echo "R492_HARD_ROLLBACK_SOURCE=$R492_BACKUP VERSION=$(image_version "$R492_BACKUP")" | tee -a "$LOG"

say "9/9 SUCCESS"
trap - ERR INT TERM EXIT
cleanup
echo "RESULT=SUCCESS VERSION=$EXPECTED_VERSION PATCH=$EXPECTED_PATCH_LABEL CURRENT=$APP UIFIX7R2_BACKUP=$PREV_BACKUP R492_ROLLBACK=$R492_BACKUP" | tee -a "$LOG"
echo "CONTRACT=R492_CORE_FROZEN MARKETMAP=CANONICAL OPENING_REACCEL=0900_0920_VERIFY CLOSE_BET=KRX_NXT_VERIFY_DISPLAY_ONLY RANK_EFFECT=0 BUY_EFFECT=0 NEW_REST=0 NEW_WS=0 SWAP_GUARD_MB=$MAX_SWAP_MB" | tee -a "$LOG"
echo "LOG=$LOG"
