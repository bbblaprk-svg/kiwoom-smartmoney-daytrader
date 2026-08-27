#!/usr/bin/env bash
set -Eeuo pipefail
umask 077
APP="${NOVA_APP_CONTAINER:-quant-nova}"
DOCKERFILE="${1:-./QUANT_NOVA_R492_MAX_PROFIT_EDGE1_LARGECAP_FILLFIX.Dockerfile}"
IMAGE="${2:-quant-nova:max-profit-edge1-largecap-fillfix}"
EXPECTED_SHA="682da7091ddeb175f2654fd240f703d00a878f63cfc409a98a05a7f5da3bb7c2"
STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP="${APP}-pre-largecap-fillfix-${STAMP}"
ENVFILE="$(mktemp)"
cleanup() { rm -f "$ENVFILE"; }
trap cleanup EXIT

if docker info >/dev/null 2>&1; then D=(docker); elif sudo -n docker info >/dev/null 2>&1; then D=(sudo docker); else echo "FAIL: Docker 권한 없음"; exit 2; fi
dc() { "${D[@]}" "$@"; }

[[ -f "$DOCKERFILE" ]] || { echo "FAIL: Dockerfile 없음: $DOCKERFILE"; exit 2; }
ACTUAL_SHA="$(sha256sum "$DOCKERFILE" | awk '{print $1}')"
[[ "$ACTUAL_SHA" == "$EXPECTED_SHA" ]] || { echo "FAIL: Dockerfile SHA 불일치"; echo "EXPECTED=$EXPECTED_SHA"; echo "ACTUAL=$ACTUAL_SHA"; exit 2; }
dc inspect "$APP" >/dev/null 2>&1 || { echo "FAIL: 현재 $APP 컨테이너가 없음. 환경승계 없는 신규기동은 금지."; exit 2; }

# Current runtime contract: env + network only. Existing data mounts are inherited from backup.
dc inspect "$APP" --format '{{range .Config.Env}}{{println .}}{{end}}' > "$ENVFILE"
mapfile -t NETWORKS < <(dc inspect "$APP" --format '{{range $k,$v := .NetworkSettings.Networks}}{{println $k}}{{end}}' | sed '/^[[:space:]]*$/d')
[[ "${#NETWORKS[@]}" -gt 0 ]] || { echo "FAIL: 현재 NOVA 네트워크를 찾지 못함"; exit 2; }
PRIMARY_NETWORK="${NETWORKS[0]}"

echo "===== 1. BUILD ====="
dc build -f "$DOCKERFILE" -t "$IMAGE" .

echo "===== 2. BACKUP CURRENT ====="
dc stop "$APP"
dc rename "$APP" "$BACKUP"

rollback() {
  echo "===== AUTO ROLLBACK ====="
  dc rm -f "$APP" >/dev/null 2>&1 || true
  dc rename "$BACKUP" "$APP" >/dev/null 2>&1 || true
  dc start "$APP" >/dev/null 2>&1 || true
}

STARTED=0
if dc run -d --name "$APP" --restart unless-stopped --network "$PRIMARY_NETWORK" --env-file "$ENVFILE" --volumes-from "$BACKUP" -p 3200:8000 "$IMAGE"; then
  STARTED=1
else
  rollback
  exit 1
fi

for net in "${NETWORKS[@]:1}"; do dc network connect "$net" "$APP" >/dev/null 2>&1 || true; done

echo "===== 3. HEALTH ====="
OK=0
for _ in $(seq 1 18); do
  if curl -fsS --max-time 3 http://127.0.0.1:3200/api/livez >/tmp/nova_fillfix_health.json 2>/dev/null; then OK=1; break; fi
  sleep 5
done
if [[ "$OK" != 1 ]]; then
  dc logs --tail 120 "$APP" || true
  rollback
  exit 1
fi
cat /tmp/nova_fillfix_health.json; echo

echo "===== 4. NETWORK / STATUS ====="
dc inspect "$APP" --format '{{range $k,$v := .NetworkSettings.Networks}}{{println $k}}{{end}}'
dc ps --filter "name=^/${APP}$" --format "table {{.Names}}\t{{.Status}}\t{{.Image}}\t{{.Ports}}"

echo "======================================"
echo "RESULT=SUCCESS"
echo "CURRENT=$APP"
echo "IMAGE=$IMAGE"
echo "ROLLBACK_CONTAINER=$BACKUP"
echo "FIX=LARGECAP_DATA_WAIT_SLOT_RETENTION_ONLY"
echo "======================================"
