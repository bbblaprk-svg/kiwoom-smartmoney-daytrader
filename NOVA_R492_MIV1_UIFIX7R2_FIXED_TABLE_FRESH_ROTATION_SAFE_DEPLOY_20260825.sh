#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

REPO="bbblaprk-svg/kiwoom-smartmoney-daytrader"
BRANCH="main"
APP="${NOVA_APP_CONTAINER:-quant-nova}"
REMOTE_DOCKERFILE="Dockerfile"
EXPECTED_DOCKERFILE_SHA="2b90bb85302f704a763d1381541bdaedc8bec4727e8323a4c8aae741ec7bc1aa"
EXPECTED_SOURCE_SHA="7dab89fb2f6b1f55e13eceb89b0a701458f26dcee9a92ce428faae42d2a95010"
EXPECTED_VERSION="NOVA-3.3.5-R492-MARKET-INDEX-VERIFY1"
EXPECTED_UIFIX7="CLOSE_FROZEN_PERSIST_TRISTATE_SPARSE_IO_R2"
EXPECTED_PATCH="CORE2000_FRESH1000_1999_CAP2_FIXED20_VERIFY1"
EXPECTED_DIVERSITY="FIXED_TABLES_FRESH_ROTATION_V1"
BASE_SOURCE_SHA="0d2f300af673c7187ae51b3ec9acc0e13e1dfaa6211d7b76a4f721130df632fc"
BASE_INDEX_SHA="8f98c58541c507253096abebd63b14774f7a186bf14782840d0acb83e7de61dc"
IMAGE="quant-nova:3.3.5-r492-miv1-fixed20-fresh-rotation-v1"
STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP="${APP}-pre-diversity-${STAMP}"
FAILED="${APP}-failed-diversity-${STAMP}"
CANDIDATE="${APP}-diversity-candidate-${STAMP}"
WORK="$(mktemp -d /tmp/nova-diversity-deploy.XXXXXX)"
DOCKERFILE="$WORK/Dockerfile"
ENVFILE="$WORK/current.env"
CAND_DATA="$WORK/candidate-data"
LOG="/tmp/nova-diversity-deploy-${STAMP}.log"

if docker info >/dev/null 2>&1; then DOCKER=(docker)
elif sudo -n docker info >/dev/null 2>&1; then DOCKER=(sudo docker)
else echo "FAIL: Docker 권한을 확인할 수 없습니다."; exit 2
fi
dc(){ "${DOCKER[@]}" "$@"; }
say(){ printf '\n===== %s =====\n' "$*" | tee -a "$LOG"; }
cleanup(){ rm -rf -- "$WORK" 2>/dev/null || true; }
image_id(){ dc inspect "$1" --format '{{.Image}}' 2>/dev/null || true; }
image_label(){ local iid; iid="$(image_id "$1")"; [ -n "$iid" ] || return 0; dc image inspect "$iid" --format "{{index .Config.Labels \"$2\"}}" 2>/dev/null | sed 's/^<no value>$//' || true; }
image_version(){ image_label "$1" org.opencontainers.image.version; }
wait_health(){ local n="$1" i s; for i in $(seq 1 72); do s="$(dc inspect "$n" --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' 2>/dev/null || true)"; echo "health[$n]=$s" | tee -a "$LOG"; [ "$s" = healthy ] && return 0; sleep 5; done; return 1; }
protected_snapshot(){ for n in nova-http-guard caddy nova-caddy kiwoom-caddy; do if dc inspect "$n" >/dev/null 2>&1; then printf '%s=%s\n' "$n" "$(dc inspect "$n" --format '{{.Id}}')"; fi; done | sort; }
verify_protected(){ [ -f "$WORK/protected.before" ] || return 0; [ "$(cat "$WORK/protected.before")" = "$(protected_snapshot)" ] || { echo "FAIL: Guard/Caddy 컨테이너가 변경됐습니다." | tee -a "$LOG"; return 1; }; }

STATE_MUTATED=0
OLD_WAS_RUNNING=0
OLD_STOPPED=0
OLD_RENAMED=0
NEW_STARTED=0
CAND_STARTED=0
BASELINE_IMAGE_ID=""

rollback(){
  local rc="${1:-1}" restored_ver restored_fix restored_src
  trap - ERR INT TERM
  say "AUTO ROLLBACK -> CURRENT FIXED20 BASELINE"
  if [ "$CAND_STARTED" -eq 1 ] && dc inspect "$CANDIDATE" >/dev/null 2>&1; then dc rm -f "$CANDIDATE" >/dev/null 2>&1 || true; fi
  if [ "$NEW_STARTED" -eq 1 ] && dc inspect "$APP" >/dev/null 2>&1; then
    dc logs --tail 200 "$APP" >>"$LOG" 2>&1 || true
    dc stop -t 5 "$APP" >/dev/null 2>&1 || true
    if dc inspect "$FAILED" >/dev/null 2>&1; then dc rm -f "$FAILED" >/dev/null 2>&1 || true; fi
    dc rename "$APP" "$FAILED" >/dev/null 2>&1 || true
  fi
  if [ "$OLD_RENAMED" -eq 1 ] && dc inspect "$BACKUP" >/dev/null 2>&1; then
    if [ -n "$BASELINE_IMAGE_ID" ] && [ "$(image_id "$BACKUP")" != "$BASELINE_IMAGE_ID" ]; then
      echo "CRITICAL: fixed20 baseline image id changed; refusing non-exact rollback." | tee -a "$LOG"
      cleanup; exit "$rc"
    fi
    dc rename "$BACKUP" "$APP" >/dev/null 2>&1 || true
  fi
  if dc inspect "$APP" >/dev/null 2>&1; then
    if [ "$OLD_WAS_RUNNING" -eq 1 ]; then dc start "$APP" >/dev/null 2>&1 || true; wait_health "$APP" || true; fi
    restored_ver="$(image_version "$APP")"; restored_fix="$(image_label "$APP" io.quantnova.r492_uifix7)"; restored_src="$(image_label "$APP" io.quantnova.embedded_source_sha256)"
    echo "ROLLBACK_RESULT version=${restored_ver:-UNKNOWN} uifix7=${restored_fix:-UNKNOWN} source=${restored_src:-UNKNOWN}" | tee -a "$LOG"
  else
    echo "CRITICAL: rollback target $APP not present" | tee -a "$LOG"
  fi
  verify_protected || true
  cleanup
  echo "RESULT=ROLLED_BACK CURRENT=$APP LOG=$LOG" | tee -a "$LOG"
  exit "$rc"
}
trap 'rollback $?' ERR
trap 'rollback 130' INT
trap 'rollback 143' TERM

fetch_dockerfile(){
  local raw tmp
  raw="https://raw.githubusercontent.com/${REPO}/${BRANCH}/${REMOTE_DOCKERFILE}?ts=$(date +%s)"
  tmp="${DOCKERFILE}.download"
  echo "PUBLIC_FETCH_URL=$raw" | tee -a "$LOG"
  curl -fL --retry 2 --retry-delay 2 --connect-timeout 10 --max-time 60 -H 'Cache-Control: no-cache' "$raw" -o "$tmp"
  mv "$tmp" "$DOCKERFILE"
}

preflight_embedded(){
  local py
  py="$(command -v python3 || command -v python || true)"; [ -n "$py" ] || { echo "FAIL: host python3/python required"; return 1; }
  "$py" - "$DOCKERFILE" "$EXPECTED_SOURCE_SHA" <<'PY' | tee -a "$LOG"
import base64,hashlib,io,pathlib,re,subprocess,sys,tarfile,tempfile
p=pathlib.Path(sys.argv[1]);expected=sys.argv[2];text=p.read_text()
parts=re.findall(r"RUN printf '%s' '([^']*)' >> /tmp/nova-source\.tar\.gz\.b64",text)
assert parts,'embedded payload missing'
raw=base64.b64decode(''.join(parts),validate=True);actual=hashlib.sha256(raw).hexdigest();assert actual==expected,(actual,expected)
with tempfile.TemporaryDirectory(prefix='nova-diversity-preflight-') as td:
    root=pathlib.Path(td)
    with tarfile.open(fileobj=io.BytesIO(raw),mode='r:gz') as tf:
        members=tf.getmembers();names=set()
        for m in members:
            n=m.name.replace('\\','/'); logical=n[2:] if n.startswith('./') else n
            assert not n.startswith('/') and '..' not in n.split('/') and not (m.isdev() or m.issym() or m.islnk()),m.name
            assert logical not in names,logical;names.add(logical)
        tf.extractall(root)
    required={'app/addons/large_mid_pre.py','app/addons/diversity_fresh_rotation.py','static/large-mid-pre.js','tests/test_r492_large_mid_pre_fixed.py','tests/test_r492_diversity_fresh_rotation.py','scripts/r492_large_mid_pre_fixed_acceptance.py','scripts/r492_diversity_fresh_rotation_acceptance.py','R492_LARGE_MID_PRE_FIXED_INVARIANTS.md','R492_DIVERSITY_FRESH_ROTATION_INVARIANTS.md','SOURCE_MANIFEST.sha256'}
    assert required<=names,sorted(required-names)
    cp=subprocess.run(['sha256sum','-c','SOURCE_MANIFEST.sha256'],cwd=root,stdout=subprocess.DEVNULL,stderr=subprocess.STDOUT);assert cp.returncode==0,'manifest mismatch'
    protected={
      'app/signal/policy.py':'18cb96ef1afb9de48136d39c3e9b8216e62a94dccf0229aa027479783eb9151a',
      'app/broker/kiwoom.py':'e10d936a2540a70d8a488e0460608a3c2a1a8bfaf95dc6206e706cce3afab0d1',
      'app/broker/websocket.py':'50fefc5faa1457210af758636279bea0bc3926e505bc91317962a0d451e35602',
      'app/broker/discovery.py':'2b12de4c44af1242287c5b9883c2ffc4e646522d13a0dfa0a243c3e4c024fa59',
      'app/service.py':'e325b7a76d6ddfa291b800ef97fb13e6b85fa9bb9ccb2365130ef2d5abf512c3',
      'app/addons/energy_path.py':'cd403cda76cb9d515c9228bf310287ad639bed125075fa835a3607cac2e81595',
      'app/runtime/state.py':'28e835a781ed4a0a00bf4ab1fb1f2dcfb6c3c23ed77750c492788a168c80451b',
      'static/nova.js':'8f0904af264a3a8eda2d874dda25ce8086fb66d1751b592a9be0d6069b5ee1f6',
      'ops/http_guard_v2.py':'c07332eb6951c51b433f42059133dd22b5e28a0c137f07b9f177f814dbe1ec1b'}
    for rel,want in protected.items():assert hashlib.sha256((root/rel).read_bytes()).hexdigest()==want,rel
    html=(root/'static/index.html').read_text();js=(root/'static/large-mid-pre.js').read_text();panels=(root/'static/decision-panels.js').read_text()
    assert len(re.findall(r'id="lm_pre_row_\d+"',html))==20
    assert "fill('preignition_accel',j.preignition,preRow,true,!j.market_active,20)" in panels
    for bad in ('insertAdjacentElement','insertAdjacentHTML','.innerHTML'):assert bad not in js,bad
    subprocess.run([sys.executable,'-m','py_compile',str(root/'app/addons/large_mid_pre.py'),str(root/'app/addons/diversity_fresh_rotation.py'),str(root/'scripts/r492_large_mid_pre_fixed_acceptance.py'),str(root/'scripts/r492_diversity_fresh_rotation_acceptance.py')],check=True)
print(f'PREFLIGHT=PASS chunks={len(parts)} gzip_bytes={len(raw)} source_sha={actual} fixed_tables=1 ui_static=1 soft_pin_scheduler=1 fresh_rotation=1 protected_core=9 new_ws=0 rest_max=2')
PY
}

runtime_gate(){
  local name="$1"
  dc exec "$name" python - <<'PY' | tee -a "$LOG"
import json,os,urllib.request
T=(os.getenv('NOVA_UI_ACCESS_TOKEN') or os.getenv('APP_ACCESS_TOKEN') or '').strip()
H={'X-App-Token':T,'Authorization':'Bearer '+T} if T else {}
def get(path):
    with urllib.request.urlopen(urllib.request.Request('http://127.0.0.1:8000'+path,headers=H),timeout=6) as r:return json.load(r)
live=get('/api/livez'); lm=get('/api/large-mid-pre'); health=get('/api/realtime-health')
assert live.get('ok'),live
c=lm.get('contracts') or {}
assert lm.get('mode')=='VERIFY_DISPLAY_ONLY',lm
assert c.get('fixed_slots')==20 and c.get('primary_slots')==10 and c.get('shadow_slots')==10,c
assert c.get('core_cap_min_eok')==2000 and c.get('fresh_cap_min_eok')==1000 and c.get('fresh_cap_max_eok')==1999,c
assert c.get('fresh_slot_cap')==2,c
assert c.get('official_buy_logic_changed') is False and c.get('official_pre_membership_changed') is False,c
assert c.get('new_ws_subscription_types')==0 and c.get('ws_item_ceiling_increase')==0,c
assert c.get('additional_rest_calls_per_refresh_max')==2,c
assert c.get('candidate_supply_expanded_verify_only') is True,c
assert c.get('fixed_table_geometry_changed') is False,c
m=health.get('memory') or {};swap=float(m.get('swap_mb') or 0);lag=float(health.get('event_loop_lag_p95_ms') or 0);qage=float(health.get('trade_queue_oldest_age_ms') or 0)
# Real-runtime guard only; no synthetic CPU p95 and no swap==0 requirement.
assert swap<=32.0,m
assert lag<=500.0,(lag,health.get('load_mode'))
assert qage<=2000.0,(qage,health.get('load_mode'))
print(json.dumps({'RUNTIME_GATE':'PASS','version':live.get('version'),'fixed20':c.get('fixed_slots'),'rows':len(lm.get('rows') or []),'swap_mb':swap,'lag_p95_ms':lag,'queue_age_ms':qage,'load':health.get('load_mode')},ensure_ascii=False))
PY
}

say "1/8 FETCH FIXED-TABLE FRESH-ROTATION DOCKERFILE + SHA LOCK"
fetch_dockerfile
ACTUAL_SHA="$(sha256sum "$DOCKERFILE" | awk '{print $1}')"
echo "DOCKERFILE_SHA256=$ACTUAL_SHA" | tee -a "$LOG"
[ "$ACTUAL_SHA" = "$EXPECTED_DOCKERFILE_SHA" ] || { echo "FAIL: GitHub Dockerfile SHA mismatch" | tee -a "$LOG"; false; }
grep -Fq "$EXPECTED_PATCH" "$DOCKERFILE"
preflight_embedded

say "2/8 VERIFY CURRENT FIXED20 BASELINE OR ALREADY DEPLOYED"
dc inspect "$APP" >/dev/null
CURRENT_VERSION="$(image_version "$APP")"
CURRENT_UIFIX7="$(image_label "$APP" io.quantnova.r492_uifix7)"
CURRENT_PATCH="$(image_label "$APP" io.quantnova.large_mid_pre_fixed)"
CURRENT_DIVERSITY="$(image_label "$APP" io.quantnova.diversity_patch)"
CURRENT_SOURCE="$(image_label "$APP" io.quantnova.embedded_source_sha256)"
echo "current_version=${CURRENT_VERSION:-UNKNOWN} uifix7=${CURRENT_UIFIX7:-NONE} patch=${CURRENT_PATCH:-NONE} diversity=${CURRENT_DIVERSITY:-NONE} source=${CURRENT_SOURCE:-NONE}" | tee -a "$LOG"
if [ "$CURRENT_VERSION" = "$EXPECTED_VERSION" ] && [ "$CURRENT_UIFIX7" = "$EXPECTED_UIFIX7" ] && [ "$CURRENT_PATCH" = "$EXPECTED_PATCH" ] && [ "$CURRENT_DIVERSITY" = "$EXPECTED_DIVERSITY" ] && [ "$CURRENT_SOURCE" = "$EXPECTED_SOURCE_SHA" ]; then
  wait_health "$APP"; runtime_gate "$APP"
  trap - ERR INT TERM; cleanup
  echo "RESULT=ALREADY_DEPLOYED VERSION=$EXPECTED_VERSION PATCH=$EXPECTED_PATCH DIVERSITY=$EXPECTED_DIVERSITY CURRENT=$APP LOG=$LOG"
  exit 0
fi
[ "$CURRENT_VERSION" = "$EXPECTED_VERSION" ] || { echo "FAIL: current version is not MIV1" | tee -a "$LOG"; false; }
[ "$CURRENT_UIFIX7" = "$EXPECTED_UIFIX7" ] || { echo "FAIL: current UIFIX7 is not exact R2" | tee -a "$LOG"; false; }
[ "$CURRENT_PATCH" = "$EXPECTED_PATCH" ] || { echo "FAIL: current app is not exact FIXED20 baseline" | tee -a "$LOG"; false; }
[ -z "$CURRENT_DIVERSITY" ] || { echo "FAIL: current app already has an unrecognized diversity patch" | tee -a "$LOG"; false; }
[ "$CURRENT_SOURCE" = "$BASE_SOURCE_SHA" ] || { echo "FAIL: current embedded source is not exact FIXED20 baseline" | tee -a "$LOG"; false; }
CURRENT_INDEX_SHA="$(dc exec "$APP" sha256sum /app/static/index.html | awk '{print $1}')"
[ "$CURRENT_INDEX_SHA" = "$BASE_INDEX_SHA" ] || { echo "FAIL: current FIXED20 index.html mismatch" | tee -a "$LOG"; false; }
BASELINE_IMAGE_ID="$(image_id "$APP")"
[ "$(dc inspect "$APP" --format '{{.State.Running}}')" = true ] && OLD_WAS_RUNNING=1 || true
dc inspect "$APP" --format '{{range .Config.Env}}{{println .}}{{end}}' > "$ENVFILE"
protected_snapshot > "$WORK/protected.before"

NETWORK_MODE="$(dc inspect "$APP" --format '{{.HostConfig.NetworkMode}}' | xargs)"
mapfile -t NETWORKS < <(dc inspect "$APP" --format '{{range $name, $_ := .NetworkSettings.Networks}}{{println $name}}{{end}}' | awk 'NF' | sort -u)
case "$NETWORK_MODE" in host|none|container:*) PRIMARY_NETWORK="$NETWORK_MODE" ;; default|"") if [ "${#NETWORKS[@]}" -gt 0 ]; then PRIMARY_NETWORK="${NETWORKS[0]}"; else PRIMARY_NETWORK=bridge; fi ;; *) if [ "${#NETWORKS[@]}" -gt 0 ]; then PRIMARY_NETWORK="${NETWORKS[0]}"; else PRIMARY_NETWORK="$NETWORK_MODE"; fi ;; esac
RESTART="$(dc inspect "$APP" --format '{{.HostConfig.RestartPolicy.Name}}')"; [ -n "$RESTART" ] || RESTART=unless-stopped
USER_SPEC="$(dc inspect "$APP" --format '{{.Config.User}}')"
READONLY="$(dc inspect "$APP" --format '{{.HostConfig.ReadonlyRootfs}}')"
MEMORY="$(dc inspect "$APP" --format '{{.HostConfig.Memory}}')"
MEMSWAP="$(dc inspect "$APP" --format '{{.HostConfig.MemorySwap}}')"
MEMRES="$(dc inspect "$APP" --format '{{.HostConfig.MemoryReservation}}')"
PIDSLIMIT="$(dc inspect "$APP" --format '{{.HostConfig.PidsLimit}}')"
MOUNT_ARGS=()
while IFS='|' read -r TYPE SOURCE DEST RW NAME; do
  TYPE="$(xargs <<<"$TYPE")";SOURCE="$(xargs <<<"$SOURCE")";DEST="$(xargs <<<"$DEST")";RW="$(xargs <<<"$RW")";NAME="$(xargs <<<"$NAME")"
  [ -n "$TYPE" ] || continue
  if [[ "$DEST" == /app/* && "$DEST" != /app/data && "$DEST" != /app/data/* ]]; then echo "FAIL: app source override mount: $DEST"; false; fi
  MODE=""; [ "$RW" = true ] || MODE=":ro"
  if [ "$TYPE" = bind ]; then MOUNT_ARGS+=( -v "${SOURCE}:${DEST}${MODE}" ); elif [ "$TYPE" = volume ]; then MOUNT_ARGS+=( -v "${NAME}:${DEST}${MODE}" ); fi
done < <(dc inspect "$APP" --format '{{range .Mounts}}{{println .Type "|" .Source "|" .Destination "|" .RW "|" .Name}}{{end}}')
PORT_ARGS=()
while IFS='|' read -r HOSTIP HOSTPORT CONTAINERPORT; do
  HOSTIP="$(xargs <<<"$HOSTIP")";HOSTPORT="$(xargs <<<"$HOSTPORT")";CONTAINERPORT="$(xargs <<<"$CONTAINERPORT")"
  [ -n "$HOSTPORT" ] || continue
  if [ -n "$HOSTIP" ] && [ "$HOSTIP" != 0.0.0.0 ]; then PORT_ARGS+=( -p "${HOSTIP}:${HOSTPORT}:${CONTAINERPORT}" ); else PORT_ARGS+=( -p "${HOSTPORT}:${CONTAINERPORT}" ); fi
done < <(dc inspect "$APP" --format '{{range $port, $bindings := .NetworkSettings.Ports}}{{range $bindings}}{{println .HostIp "|" .HostPort "|" $port}}{{end}}{{end}}')
echo "runtime_snapshot=PASS network=$PRIMARY_NETWORK restart=$RESTART mounts=${#MOUNT_ARGS[@]} ports=${#PORT_ARGS[@]}" | tee -a "$LOG"

say "3/8 LOW-RAM BUILD — CURRENT PHOTO BASELINE PRESERVED"
FREE_KB="$(df -Pk /var/lib/docker 2>/dev/null | awk 'NR==2{print $4}')"; [ -n "$FREE_KB" ] || FREE_KB="$(df -Pk / | awk 'NR==2{print $4}')"
(( FREE_KB >= 1400000 )) || { echo "FAIL: Docker disk free ${FREE_KB}KB < 1.4GB"; false; }
if [ "$OLD_WAS_RUNNING" -eq 1 ]; then dc stop -t 10 "$APP" >/dev/null; OLD_STOPPED=1; STATE_MUTATED=1; fi
AVAIL_MB="$(free -m | awk '/Mem:/{print $7}')";echo "available_mb_after_stop=$AVAIL_MB" | tee -a "$LOG"
(( AVAIL_MB >= 350 )) || { echo "FAIL: available RAM ${AVAIL_MB}MB < 350MB"; false; }
DOCKER_BUILDKIT=1 dc build --pull --no-cache -f "$DOCKERFILE" -t "$IMAGE" "$WORK" | tee -a "$LOG"
[ "$(dc image inspect "$IMAGE" --format '{{index .Config.Labels "org.opencontainers.image.version"}}')" = "$EXPECTED_VERSION" ]
[ "$(dc image inspect "$IMAGE" --format '{{index .Config.Labels "io.quantnova.r492_uifix7"}}')" = "$EXPECTED_UIFIX7" ]
[ "$(dc image inspect "$IMAGE" --format '{{index .Config.Labels "io.quantnova.large_mid_pre_fixed"}}')" = "$EXPECTED_PATCH" ]
[ "$(dc image inspect "$IMAGE" --format '{{index .Config.Labels "io.quantnova.diversity_patch"}}')" = "$EXPECTED_DIVERSITY" ]
[ "$(dc image inspect "$IMAGE" --format '{{index .Config.Labels "io.quantnova.embedded_source_sha256"}}')" = "$EXPECTED_SOURCE_SHA" ]
[ "$(dc image inspect "$IMAGE" --format '{{index .Config.Labels "io.quantnova.large_mid_pre_ws"}}')" = "NEW_TYPES0_CEILING0" ]

say "4/8 ISOLATED CANDIDATE — NO BROKER NETWORK"
mkdir -p "$CAND_DATA/nova30"
dc rm -f "$CANDIDATE" >/dev/null 2>&1 || true
CAND_ARGS=(run -d --name "$CANDIDATE" --network none --memory 384m --memory-swap 384m --pids-limit 256 --read-only --tmpfs /tmp:rw,noexec,nosuid,size=48m --env-file "$ENVFILE" -e NOVA_CANDIDATE_MODE=1 -e NOVA_LARGE_MID_PRE_ENABLED=1 -e NOVA_MARKET_INDEX_VERIFY_ENABLED=0 -e NOVA_DATA_DIR=/app/data/nova30 -e NOVA_LEGACY_DATA_DIR=/app/data/nova30 -v "$CAND_DATA/nova30:/app/data/nova30")
[ -n "$USER_SPEC" ] && CAND_ARGS+=(--user "$USER_SPEC")
CAND_ARGS+=("$IMAGE")
dc "${CAND_ARGS[@]}" >/dev/null;CAND_STARTED=1
wait_health "$CANDIDATE"
dc exec "$CANDIDATE" env PYTHONPATH=/app python /app/scripts/r492_uifix7_acceptance.py | tee -a "$LOG"
dc exec "$CANDIDATE" env PYTHONPATH=/app python /app/scripts/r492_large_mid_pre_fixed_acceptance.py | tee -a "$LOG"
dc exec "$CANDIDATE" env PYTHONPATH=/app python /app/scripts/r492_diversity_fresh_rotation_acceptance.py | tee -a "$LOG"
runtime_gate "$CANDIDATE"
dc rm -f "$CANDIDATE" >/dev/null;CAND_STARTED=0

say "5/8 ATOMIC CUTOVER — KEEP EXACT FIXED20 BACKUP"
[ "$(image_id "$APP")" = "$BASELINE_IMAGE_ID" ] || { echo "FAIL: baseline image changed before cutover"; false; }
dc rename "$APP" "$BACKUP";OLD_RENAMED=1;STATE_MUTATED=1
[ "$(image_version "$BACKUP")" = "$EXPECTED_VERSION" ]
[ "$(image_label "$BACKUP" io.quantnova.r492_uifix7)" = "$EXPECTED_UIFIX7" ]
[ "$(image_label "$BACKUP" io.quantnova.embedded_source_sha256)" = "$BASE_SOURCE_SHA" ]
[ -z "$(image_label "$BACKUP" io.quantnova.diversity_patch)" ]
RUN_ARGS=(run -d --name "$APP" --restart "$RESTART" --network "$PRIMARY_NETWORK" --env-file "$ENVFILE")
RUN_ARGS+=("${MOUNT_ARGS[@]}")
case "$PRIMARY_NETWORK" in host|none|container:*) ;; *) RUN_ARGS+=("${PORT_ARGS[@]}") ;; esac
[ -n "$USER_SPEC" ] && RUN_ARGS+=(--user "$USER_SPEC")
[ "$READONLY" = true ] && RUN_ARGS+=(--read-only --tmpfs /tmp:rw,noexec,nosuid,size=48m)
(( MEMORY > 0 )) && RUN_ARGS+=(--memory "$MEMORY")
(( MEMSWAP > 0 )) && RUN_ARGS+=(--memory-swap "$MEMSWAP")
(( MEMRES > 0 )) && RUN_ARGS+=(--memory-reservation "$MEMRES")
[[ "$PIDSLIMIT" =~ ^[0-9]+$ ]] && (( PIDSLIMIT > 0 )) && RUN_ARGS+=(--pids-limit "$PIDSLIMIT")
RUN_ARGS+=("$IMAGE")
dc "${RUN_ARGS[@]}" >/dev/null;NEW_STARTED=1
case "$PRIMARY_NETWORK" in host|none|container:*) ;; *) for net in "${NETWORKS[@]}"; do [ -n "$net" ] || continue; [ "$net" = "$PRIMARY_NETWORK" ] && continue; dc network connect "$net" "$APP" >/dev/null; done ;; esac

say "6/8 ACTIVE HEALTH + FIXED20 CONTRACT"
wait_health "$APP"
[ "$(image_version "$APP")" = "$EXPECTED_VERSION" ]
[ "$(image_label "$APP" io.quantnova.large_mid_pre_fixed)" = "$EXPECTED_PATCH" ]
[ "$(image_label "$APP" io.quantnova.diversity_patch)" = "$EXPECTED_DIVERSITY" ]
runtime_gate "$APP"

say "7/8 REAL RUNTIME STABILITY — 3 SAMPLES"
for n in 1 2 3; do sleep 5; runtime_gate "$APP"; done
verify_protected

say "8/8 SUCCESS"
trap - ERR INT TERM
cleanup
printf 'RESULT=DEPLOYED CURRENT=%s VERSION=%s PATCH=%s DIVERSITY=%s BACKUP=%s LOG=%s\n' "$APP" "$EXPECTED_VERSION" "$EXPECTED_PATCH" "$EXPECTED_DIVERSITY" "$BACKUP" "$LOG"
