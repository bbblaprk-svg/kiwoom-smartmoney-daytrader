#!/usr/bin/env bash
set -euo pipefail
umask 077

APP="${NOVA_APP_CONTAINER:-quant-nova}"
EXPECTED_VERSION="NOVA-3.3.5-R492-MAX-PROFIT-EDGE1-FRESH1"
DEFAULT_DOCKERFILE="./QUANT_NOVA_R492_MAX_PROFIT_EDGE1.Dockerfile"
if [[ $# -ge 1 ]]; then
  DOCKERFILE="$1"
elif [[ -n "${NOVA_DOCKERFILE:-}" ]]; then
  DOCKERFILE="$NOVA_DOCKERFILE"
else
  DOCKERFILE="$DEFAULT_DOCKERFILE"
  if [[ ! -f "$DOCKERFILE" ]]; then
    mapfile -d '' -t NUMBERED_DOCKERFILES < <(
      find . -maxdepth 1 -type f -name 'QUANT_NOVA_R492_MAX_PROFIT_EDGE1*.Dockerfile' -print0
    )
    if [[ "${#NUMBERED_DOCKERFILES[@]}" -eq 1 ]]; then
      DOCKERFILE="${NUMBERED_DOCKERFILES[0]}"
    elif [[ "${#NUMBERED_DOCKERFILES[@]}" -gt 1 ]]; then
      printf 'FAIL: Dockerfile 후보가 여러 개입니다. 첫 번째 인자로 사용할 파일을 지정하세요.\n' >&2
      printf '  %s\n' "${NUMBERED_DOCKERFILES[@]}" >&2
      exit 2
    fi
  fi
fi
IMAGE="${2:-${NOVA_NEW_IMAGE:-quant-nova:max-profit-edge1}}"
STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP="${APP}-pre-max-profit-edge1-${STAMP}"
FAILED="${APP}-failed-max-profit-edge1-${STAMP}"
WORK="$(mktemp -d /tmp/nova-max-profit-edge1.XXXXXX)"
ENVFILE="${WORK}/current.env"
LOG="/tmp/nova-max-profit-edge1-${STAMP}.log"
OLD_EXISTS=0
OLD_RENAMED=0
NEW_STARTED=0
ROLLBACK_DONE=0

if docker info >/dev/null 2>&1; then DOCKER=(docker)
elif sudo -n docker info >/dev/null 2>&1; then DOCKER=(sudo docker)
else echo "FAIL: Docker 실행 권한을 확인할 수 없습니다."; exit 2
fi
dc(){ "${DOCKER[@]}" "$@"; }
say(){ printf '\n===== %s =====\n' "$*" | tee -a "$LOG"; }
cleanup(){
  if [[ -d "$WORK" && "$WORK" == /tmp/nova-max-profit-edge1.* ]]; then
    find "$WORK" -type f -delete 2>/dev/null || true
    rmdir "$WORK" 2>/dev/null || true
  fi
}
protected_snapshot(){
  for name in nova-http-guard caddy nova-caddy; do
    if dc inspect "$name" >/dev/null 2>&1; then
      printf '%s=%s\n' "$name" "$(dc inspect "$name" --format '{{.Id}}')"
    fi
  done | sort
}
wait_health(){
  local name="$1" status
  for _ in $(seq 1 48); do
    status="$(dc inspect "$name" --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' 2>/dev/null || true)"
    [[ "$status" == healthy ]] && return 0
    sleep 5
  done
  return 1
}
verify_protected(){
  [[ "$(protected_snapshot)" == "$(cat "$WORK/protected.before")" ]]
}
internal_gate(){
  dc exec "$APP" python - "$EXPECTED_VERSION" <<'PY'
import json,os,sys,urllib.request
expected=sys.argv[1]
token=os.getenv('NOVA_UI_ACCESS_TOKEN','').strip()
headers={'X-App-Token':token,'Authorization':'Bearer '+token} if token else {}
def get(path):
    req=urllib.request.Request('http://127.0.0.1:8000'+path,headers=headers)
    with urllib.request.urlopen(req,timeout=10) as response:
        return json.load(response)
live=get('/api/livez'); ready=get('/api/readyz'); dash=get('/api/live-dashboard')
panels=get('/api/decision-panels'); nxt=get('/api/nxt-after-edge'); health=get('/api/realtime-health')
assert live.get('ok') and live.get('version')==expected,live
assert ready.get('ok') is True,ready
assert dash.get('version')==expected and int(dash.get('board_slots') or 0)==10,dash
assert int((dash.get('delivery') or {}).get('rank_commit_sec') or 0)==30,dash.get('delivery')
core=panels.get('core6_contract') or {}
assert core.get('table_ids')==['preignition_accel','prebuy','nxt_early','largecap_swing','energy_now','power_path'],core
assert core.get('fixed_table_count')==6 and core.get('fixed_rows_each')==10,core
assert core.get('duplicate_symbol_count')==0,core
contract=panels.get('contracts') or {}
assert contract.get('official_buy_logic_changed') is False,contract
assert contract.get('new_broker_rest_calls')==0 and contract.get('new_ws_subscriptions')==0,contract
assert contract.get('fresh_rotation')=='DISPLAY ONLY; 10m soft exposure; max 10pt fatigue; 3m board re-entry cooldown; urgent/re-acceleration protected',contract
assert contract.get('fresh_episode_rearm')=='DISPLAY ONLY; requires re-entry through >=2 broker rank sources after the original 3m episode',contract
nxt_contract=nxt.get('contracts') or {}
assert nxt_contract.get('close_bet_window_kst')=='19:30-19:58',nxt_contract
assert nxt_contract.get('close_bet_new_entry_lock_kst')=='19:58-20:00',nxt_contract
assert nxt_contract.get('close_bet_max_allocation_pct')==20,nxt_contract
assert nxt_contract.get('close_bet_order_submission') is False,nxt_contract
telemetry=health.get('telemetry') or {}
assert int(telemetry.get('signal_price_mismatch_count') or 0)==0,telemetry
assert int(telemetry.get('wrong_venue_price_count') or 0)==0,telemetry
print(json.dumps({'ok':True,'version':expected,'tables':6,'rows':10,'rank_commit_sec':30,
                  'nxt_close':'19:30-19:58','automatic_order':False},ensure_ascii=False))
PY
}
rollback(){
  local rc=$?
  trap - ERR INT TERM
  if [[ "$ROLLBACK_DONE" -eq 1 ]]; then exit "${rc:-1}"; fi
  ROLLBACK_DONE=1
  say "AUTO ROLLBACK"
  if [[ "$NEW_STARTED" -eq 1 ]] && dc inspect "$APP" >/dev/null 2>&1; then
    dc logs --tail 300 "$APP" >>"$LOG" 2>&1 || true
    dc stop "$APP" >/dev/null 2>&1 || true
    dc rename "$APP" "$FAILED" >/dev/null 2>&1 || true
  fi
  if [[ "$OLD_RENAMED" -eq 1 ]] && dc inspect "$BACKUP" >/dev/null 2>&1; then
    dc rename "$BACKUP" "$APP" >/dev/null
    dc start "$APP" >/dev/null
    wait_health "$APP" || true
  fi
  verify_protected || true
  cleanup
  echo "RESULT=ROLLED_BACK CURRENT=${APP} FAILED=${FAILED} LOG=${LOG}" | tee -a "$LOG"
  exit "${rc:-1}"
}
trap rollback ERR INT TERM

[[ -f "$DOCKERFILE" ]] || { echo "FAIL: Dockerfile 없음: $DOCKERFILE"; exit 2; }
DOCKERFILE="$(cd "$(dirname "$DOCKERFILE")" && pwd)/$(basename "$DOCKERFILE")"
protected_snapshot >"$WORK/protected.before"

say "1. BUILD AND VERIFY IMAGE"
dc build --pull -f "$DOCKERFILE" -t "$IMAGE" "$(dirname "$DOCKERFILE")" 2>&1 | tee -a "$LOG"
LABEL_VERSION="$(dc image inspect "$IMAGE" --format '{{index .Config.Labels "org.opencontainers.image.version"}}')"
[[ "$LABEL_VERSION" == "$EXPECTED_VERSION" ]]

if dc inspect "$APP" >/dev/null 2>&1; then
  OLD_EXISTS=1
  say "2. CAPTURE CURRENT RUNTIME CONTRACT"
  dc inspect "$APP" --format '{{range .Config.Env}}{{println .}}{{end}}' >"$ENVFILE"
  chmod 600 "$ENVFILE"
  mapfile -t NETWORKS < <(dc inspect "$APP" --format '{{range $name, $_ := .NetworkSettings.Networks}}{{println $name}}{{end}}')
  [[ "${#NETWORKS[@]}" -gt 0 ]]
  RESTART="$(dc inspect "$APP" --format '{{.HostConfig.RestartPolicy.Name}}')"
  [[ -n "$RESTART" && "$RESTART" != no ]] || RESTART=unless-stopped
  RESOURCE_ARGS=()
  MEMORY="$(dc inspect "$APP" --format '{{.HostConfig.Memory}}')"
  MEMORY_SWAP="$(dc inspect "$APP" --format '{{.HostConfig.MemorySwap}}')"
  CPU_PERIOD="$(dc inspect "$APP" --format '{{.HostConfig.CpuPeriod}}')"
  CPU_QUOTA="$(dc inspect "$APP" --format '{{.HostConfig.CpuQuota}}')"
  PIDS_LIMIT="$(dc inspect "$APP" --format '{{.HostConfig.PidsLimit}}')"
  [[ "$MEMORY" =~ ^[0-9]+$ && "$MEMORY" -gt 0 ]] && RESOURCE_ARGS+=( --memory "${MEMORY}b" )
  if [[ "$MEMORY_SWAP" == -1 ]]; then
    RESOURCE_ARGS+=( --memory-swap -1 )
  elif [[ "$MEMORY_SWAP" =~ ^[0-9]+$ && "$MEMORY_SWAP" -gt 0 ]]; then
    RESOURCE_ARGS+=( --memory-swap "${MEMORY_SWAP}b" )
  fi
  [[ "$CPU_PERIOD" =~ ^[0-9]+$ && "$CPU_PERIOD" -gt 0 ]] && RESOURCE_ARGS+=( --cpu-period "$CPU_PERIOD" )
  [[ "$CPU_QUOTA" =~ ^-?[0-9]+$ && "$CPU_QUOTA" -gt 0 ]] && RESOURCE_ARGS+=( --cpu-quota "$CPU_QUOTA" )
  [[ "$PIDS_LIMIT" =~ ^-?[0-9]+$ && "$PIDS_LIMIT" -gt 0 ]] && RESOURCE_ARGS+=( --pids-limit "$PIDS_LIMIT" )
  LOG_ARGS=()
  LOG_DRIVER="$(dc inspect "$APP" --format '{{.HostConfig.LogConfig.Type}}')"
  [[ -n "$LOG_DRIVER" ]] && LOG_ARGS+=( --log-driver "$LOG_DRIVER" )
  while IFS='=' read -r KEY VALUE; do
    [[ -n "$KEY" ]] && LOG_ARGS+=( --log-opt "${KEY}=${VALUE}" )
  done < <(dc inspect "$APP" --format '{{range $key, $value := .HostConfig.LogConfig.Config}}{{println $key "=" $value}}{{end}}')
  MOUNT_ARGS=()
  while IFS='|' read -r TYPE SOURCE DEST RW NAME; do
    TYPE="$(xargs <<<"$TYPE")"; SOURCE="$(xargs <<<"$SOURCE")"; DEST="$(xargs <<<"$DEST")"
    RW="$(xargs <<<"$RW")"; NAME="$(xargs <<<"$NAME")"; [[ -z "$TYPE" ]] && continue
    MODE=""; [[ "$RW" == true ]] || MODE=":ro"
    if [[ "$DEST" == /app/* && "$DEST" != /app/data && "$DEST" != /app/data/* ]]; then
      echo "FAIL: 앱 소스를 덮어쓰는 마운트 감지: $DEST"; exit 1
    fi
    [[ "$TYPE" == bind ]] && MOUNT_ARGS+=( -v "${SOURCE}:${DEST}${MODE}" )
    [[ "$TYPE" == volume ]] && MOUNT_ARGS+=( -v "${NAME}:${DEST}${MODE}" )
  done < <(dc inspect "$APP" --format '{{range .Mounts}}{{println .Type "|" .Source "|" .Destination "|" .RW "|" .Name}}{{end}}')
  PORT_ARGS=()
  while IFS='|' read -r HOSTIP HOSTPORT CONTAINERPORT; do
    HOSTIP="$(xargs <<<"$HOSTIP")"; HOSTPORT="$(xargs <<<"$HOSTPORT")"; CONTAINERPORT="$(xargs <<<"$CONTAINERPORT")"
    [[ -z "$HOSTPORT" ]] && continue
    [[ -n "$HOSTIP" && "$HOSTIP" != 0.0.0.0 ]] && PORT_ARGS+=( -p "${HOSTIP}:${HOSTPORT}:${CONTAINERPORT}" ) || PORT_ARGS+=( -p "${HOSTPORT}:${CONTAINERPORT}" )
  done < <(dc inspect "$APP" --format '{{range $port, $bindings := .NetworkSettings.Ports}}{{range $bindings}}{{println .HostIp "|" .HostPort "|" $port}}{{end}}{{end}}')

  say "3. CUTOVER QUANT-NOVA ONLY"
  dc stop "$APP" >/dev/null
  dc rename "$APP" "$BACKUP"
  OLD_RENAMED=1
  dc run -d --name "$APP" --restart "$RESTART" --network "${NETWORKS[0]}" --env-file "$ENVFILE" \
    "${RESOURCE_ARGS[@]}" "${LOG_ARGS[@]}" "${MOUNT_ARGS[@]}" "${PORT_ARGS[@]}" "$IMAGE" >/dev/null
  NEW_STARTED=1
  for network in "${NETWORKS[@]:1}"; do dc network connect "$network" "$APP" >/dev/null; done
else
  say "2. GREENFIELD START"
  ENV_ARGS=(); [[ -n "${NOVA_ENV_FILE:-}" ]] && ENV_ARGS=( --env-file "$NOVA_ENV_FILE" )
  dc volume create "${APP}-data" >/dev/null
  dc run -d --name "$APP" --restart unless-stopped -p "${NOVA_PORT:-8000}:8000" \
    "${ENV_ARGS[@]}" -v "${APP}-data:/app/data" "$IMAGE" >/dev/null
  NEW_STARTED=1
fi

say "4. HEALTH AND APPLICATION CONTRACT"
wait_health "$APP"
dc exec "$APP" python /app/scripts/max_profit_edge1_acceptance.py | tee -a "$LOG"
internal_gate | tee -a "$LOG"
verify_protected

say "5. SUCCESS"
trap - ERR INT TERM
cleanup
echo "RESULT=SUCCESS VERSION=${EXPECTED_VERSION} CURRENT=${APP} ROLLBACK_CONTAINER=${BACKUP}" | tee -a "$LOG"
echo "KIWOOM_CORE=UNCHANGED GUARD_CADDY=NOT_TOUCHED AUTO_ORDER=OFF LOG=${LOG}" | tee -a "$LOG"
