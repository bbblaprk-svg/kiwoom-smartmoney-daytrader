#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

RELEASE="2.2.3-safe-async-early-buy"
EXPECTED_VERSION="2.2.3-safe-async-early-buy"
EXPECTED_PACKAGE_RELEASE="2.2.3_SAFE_ASYNC_EARLY_BUY"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SOURCE_ARCHIVE="${SCRIPT_DIR}/PULSE_EDGE_2_2_3_SAFE_ASYNC_EARLY_BUY_SOURCE.tar.gz"
DOCKERFILE="${SCRIPT_DIR}/Dockerfile"
EXPECTED_SOURCE_SHA="0b0baa69f5a2770e61231e173a351b707553a6972eb00b3cfbe57c06de63007e"
EXPECTED_DOCKERFILE_SHA="1accacaf6ccc19ac659d173b5caa66cf38583e8b714154fc10fdc744a6e39bf2"

PULSE_BASE_DIR="${PULSE_BASE_DIR:-/opt/pulse-edge}"
PULSE_DATA_DIR="${PULSE_DATA_DIR:-${PULSE_BASE_DIR}/data}"
PULSE_ENV_FILE="${PULSE_ENV_FILE:-${PULSE_BASE_DIR}/.env}"
PULSE_CONTAINER="${PULSE_CONTAINER:-pulse-edge}"
PULSE_IMAGE="${PULSE_IMAGE:-pulse-edge:2.2.3-safe-async-early-buy}"
PULSE_PORT="${PULSE_PORT:-8000}"
PULSE_PROXY_NETWORK="${PULSE_PROXY_NETWORK:-kiwoom-net}"
PULSE_CADDY_CONTAINER="${PULSE_CADDY_CONTAINER:-kiwoom-caddy}"
PULSE_CADDYFILE="${PULSE_CADDYFILE:-/home/ubuntu/kiwoom-caddy/Caddyfile}"
PULSE_PUBLIC_HOST="${PULSE_PUBLIC_HOST:-3-38-25-20.nip.io}"
PULSE_PUBLIC_HEALTH_URL="${PULSE_PUBLIC_HEALTH_URL:-https://${PULSE_PUBLIC_HOST}/health}"

STAMP="$(date +%Y%m%d-%H%M%S)"
BUILD_DIR="${PULSE_BASE_DIR}/build/${STAMP}"
CANARY="pulse-edge-canary-${STAMP}"
PREVIOUS="pulse-edge-prev-${STAMP}"
OLD_EXISTS=0; OLD_RENAMED=0; NEW_STARTED=0; CANARY_STARTED=0; CADDY_BACKUP=""

log(){ printf '[PULSE DEPLOY] %s\n' "$*"; }
die(){ printf '[PULSE DEPLOY][ABORT] %s\n' "$*" >&2; exit 1; }
cleanup_canary(){ set +e; if [ "$CANARY_STARTED" -eq 1 ] && [ "${DOCKER+x}" = x ]; then "${DOCKER[@]}" rm -f "$CANARY" >/dev/null 2>&1 || true; fi; rm -rf "${PULSE_BASE_DIR}/canary/${STAMP}" >/dev/null 2>&1 || true; }
trap cleanup_canary EXIT

for cmd in curl tar sha256sum awk grep mkdir rm cp df seq sleep python3; do command -v "$cmd" >/dev/null 2>&1 || die "required command missing: $cmd"; done
if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then DOCKER=(docker); elif command -v sudo >/dev/null 2>&1 && sudo -n docker info >/dev/null 2>&1; then DOCKER=(sudo docker); else die "Docker daemon is not accessible"; fi

[ -f "$SOURCE_ARCHIVE" ] || die "missing source archive: $SOURCE_ARCHIVE"
[ -f "$DOCKERFILE" ] || die "missing Dockerfile: $DOCKERFILE"
[ -f "$PULSE_ENV_FILE" ] || die "missing PULSE env file: $PULSE_ENV_FILE"
[ "$(sha256sum "$SOURCE_ARCHIVE" | awk '{print $1}')" = "$EXPECTED_SOURCE_SHA" ] || die "source SHA256 mismatch"
[ "$(sha256sum "$DOCKERFILE" | awk '{print $1}')" = "$EXPECTED_DOCKERFILE_SHA" ] || die "Dockerfile SHA256 mismatch"
log "package SHA256 verified"

mkdir -p "$PULSE_BASE_DIR" "$PULSE_DATA_DIR/pulse_edge" "$BUILD_DIR"
FREE_KB="$(df -Pk "$PULSE_BASE_DIR" | awk 'NR==2 {print $4}')"; [ "${FREE_KB:-0}" -ge 700000 ] || die "less than 700 MB free disk space"
MEM_AVAIL_KB="$(awk '/MemAvailable:/ {print $2}' /proc/meminfo 2>/dev/null || echo 0)"; SWAP_FREE_KB="$(awk '/SwapFree:/ {print $2}' /proc/meminfo 2>/dev/null || echo 0)"; [ "$((MEM_AVAIL_KB + SWAP_FREE_KB))" -ge 350000 ] || die "available RAM+swap below 350 MB"

if grep -Eq '^[[:space:]]*PULSE_FEED_ENABLED=[Tt][Rr][Uu][Ee][[:space:]]*$' "$PULSE_ENV_FILE"; then grep -Eq '^PULSE_KIWOOM_APPKEY=.+$' "$PULSE_ENV_FILE" || die "PULSE_KIWOOM_APPKEY missing"; grep -Eq '^PULSE_KIWOOM_SECRETKEY=.+$' "$PULSE_ENV_FILE" || die "PULSE_KIWOOM_SECRETKEY missing"; fi

"${DOCKER[@]}" network inspect "$PULSE_PROXY_NETWORK" >/dev/null 2>&1 || die "proxy network missing: $PULSE_PROXY_NETWORK"
"${DOCKER[@]}" container inspect "$PULSE_CADDY_CONTAINER" >/dev/null 2>&1 || die "Caddy container missing: $PULSE_CADDY_CONTAINER"
[ -f "$PULSE_CADDYFILE" ] || die "Caddyfile missing: $PULSE_CADDYFILE"

if "${DOCKER[@]}" container inspect "$PULSE_CONTAINER" >/dev/null 2>&1; then OLD_EXISTS=1; OLD_DATA_SOURCE="$("${DOCKER[@]}" inspect -f '{{range .Mounts}}{{if eq .Destination "/app/data"}}{{.Source}}{{end}}{{end}}' "$PULSE_CONTAINER")"; if [ -n "$OLD_DATA_SOURCE" ] && [ "$OLD_DATA_SOURCE" != "$PULSE_DATA_DIR" ]; then die "existing PULSE /app/data differs: $OLD_DATA_SOURCE"; fi; fi

tar -xzf "$SOURCE_ARCHIVE" -C "$BUILD_DIR"; cp "$DOCKERFILE" "$BUILD_DIR/Dockerfile"; [ -d "$BUILD_DIR/pulse_edge" ] || die "build context missing pulse_edge"; [ -f "$BUILD_DIR/requirements-runtime.txt" ] || die "build context missing requirements-runtime.txt"
log "building $PULSE_IMAGE; current production untouched"
"${DOCKER[@]}" build --tag "$PULSE_IMAGE" "$BUILD_DIR"

CANARY_DATA="${PULSE_BASE_DIR}/canary/${STAMP}/data"; mkdir -p "$CANARY_DATA/pulse_edge"
"${DOCKER[@]}" run -d --name "$CANARY" --label com.pulse-edge.project=pulse-edge -e PULSE_ENV=canary -e PULSE_FEED_ENABLED=false -e PULSE_DISCOVERY_ENABLED=false -e PULSE_INVESTOR_FLOW_ENABLED=false -e PULSE_UNIVERSE_ENABLED=false -e PULSE_BACKGROUND_COVERAGE_ENABLED=false -e PULSE_SECTOR_ENABLED=false -e PULSE_SMART_MONEY_ENABLED=false -e PULSE_IGNITION_ENABLED=false -e PULSE_SUPPLY_ABSORPTION_ENABLED=false -e PULSE_DUAL_PERFORMANCE_ENABLED=false -e PULSE_DUAL_DAILY_OUTCOMES_ENABLED=false -e PULSE_TRANSITION_OPS_ENABLED=false -e PULSE_NXT_NATIVE_ENABLED=false -e PULSE_NXT_OPERATIONS_BOARD_ENABLED=false -e PULSE_MISSED_OPPORTUNITY_ENABLED=false -e PULSE_CURRENT_ENRICHMENT_ENABLED=false -e PULSE_KRX_OPERATIONS_BOARD_ENABLED=false -e PULSE_DAILY_REVIEW_ENABLED=false -e PULSE_LIVE_SHADOW_VALIDATION_ENABLED=false -e PULSE_LIVE_CERTIFICATION_ENABLED=false -p 127.0.0.1::8000 -v "$CANARY_DATA:/app/data" "$PULSE_IMAGE" >/dev/null
CANARY_STARTED=1; CANARY_PORT="$("${DOCKER[@]}" port "$CANARY" 8000/tcp | awk -F: 'NR==1 {print $NF}')"; [ -n "$CANARY_PORT" ] || die "could not determine canary port"
canary_ok=0; for _ in $(seq 1 30); do if curl -fsS --max-time 3 "http://127.0.0.1:${CANARY_PORT}/health" >/dev/null 2>&1; then canary_ok=1; break; fi; sleep 1; done
[ "$canary_ok" -eq 1 ] || { "${DOCKER[@]}" logs --tail 120 "$CANARY" || true; die "canary health failed"; }
"${DOCKER[@]}" rm -f "$CANARY" >/dev/null; CANARY_STARTED=0; rm -rf "${PULSE_BASE_DIR}/canary/${STAMP}"; log "canary PASS"

rollback(){ rc=$?; set +e; if [ "$NEW_STARTED" -eq 1 ]; then "${DOCKER[@]}" rm -f "$PULSE_CONTAINER" >/dev/null 2>&1 || true; fi; if [ "$OLD_RENAMED" -eq 1 ]; then "${DOCKER[@]}" rename "$PREVIOUS" "$PULSE_CONTAINER" >/dev/null 2>&1 || true; "${DOCKER[@]}" start "$PULSE_CONTAINER" >/dev/null 2>&1 || true; "${DOCKER[@]}" network connect "$PULSE_PROXY_NETWORK" "$PULSE_CONTAINER" >/dev/null 2>&1 || true; fi; if [ -n "$CADDY_BACKUP" ] && [ -f "$CADDY_BACKUP" ]; then cp "$CADDY_BACKUP" "$PULSE_CADDYFILE" >/dev/null 2>&1 || true; "${DOCKER[@]}" exec "$PULSE_CADDY_CONTAINER" caddy reload --config /etc/caddy/Caddyfile >/dev/null 2>&1 || true; fi; log "ROLLBACK completed"; exit "$rc"; }
trap rollback ERR

if [ "$OLD_EXISTS" -eq 1 ]; then log "stopping current PULSE container only"; "${DOCKER[@]}" stop --time 20 "$PULSE_CONTAINER" >/dev/null; "${DOCKER[@]}" rename "$PULSE_CONTAINER" "$PREVIOUS"; OLD_RENAMED=1; fi

log "starting PULSE 2.2.3"
"${DOCKER[@]}" run -d --name "$PULSE_CONTAINER" --label com.pulse-edge.project=pulse-edge --label com.pulse-edge.release="$RELEASE" --restart unless-stopped --env-file "$PULSE_ENV_FILE" -p "${PULSE_PORT}:8000" -v "$PULSE_DATA_DIR:/app/data" "$PULSE_IMAGE" >/dev/null
NEW_STARTED=1
"${DOCKER[@]}" network connect "$PULSE_PROXY_NETWORK" "$PULSE_CONTAINER"; log "connected $PULSE_CONTAINER to $PULSE_PROXY_NETWORK"

prod_ok=0
for _ in $(seq 1 45); do
  if HEALTH_JSON="$(curl -fsS --max-time 3 "http://127.0.0.1:${PULSE_PORT}/health" 2>/dev/null)"; then
    export HEALTH_JSON EXPECTED_VERSION EXPECTED_PACKAGE_RELEASE
    if python3 - <<'PY'
import json, os
x=json.loads(os.environ['HEALTH_JSON'])
assert x.get('ok') is True
assert x.get('project') == 'PULSE EDGE'
assert x.get('version') == os.environ['EXPECTED_VERSION']
assert x.get('package_release') == os.environ['EXPECTED_PACKAGE_RELEASE']
PY
    then prod_ok=1; break; fi
  fi
  sleep 1
done
[ "$prod_ok" -eq 1 ] || { "${DOCKER[@]}" logs --tail 160 "$PULSE_CONTAINER" || true; false; }
log "local health + version/package contract PASS"

CADDY_BACKUP="${PULSE_CADDYFILE}.pre-2.2.3-${STAMP}"; cp "$PULSE_CADDYFILE" "$CADDY_BACKUP"
cat > "$PULSE_CADDYFILE" <<EOF
${PULSE_PUBLIC_HOST} {
    encode gzip zstd
    reverse_proxy ${PULSE_CONTAINER}:8000
}
EOF
"${DOCKER[@]}" exec "$PULSE_CADDY_CONTAINER" caddy reload --config /etc/caddy/Caddyfile >/dev/null; log "Caddy reload PASS"
"${DOCKER[@]}" exec "$PULSE_CADDY_CONTAINER" wget -qO- "http://${PULSE_CONTAINER}:8000/health" >/dev/null; log "Caddy -> PULSE internal health PASS"

public_ok=0; for _ in $(seq 1 20); do if curl -fsS --max-time 8 "$PULSE_PUBLIC_HEALTH_URL" >/dev/null 2>&1; then public_ok=1; break; fi; sleep 1; done
[ "$public_ok" -eq 1 ] || { log "public HTTPS health failed: $PULSE_PUBLIC_HEALTH_URL"; false; }
log "public HTTPS health PASS: $PULSE_PUBLIC_HEALTH_URL"

# Short live-process soak: health must stay responsive while UI/API are exercised.
log "60-second responsiveness soak"
for _ in $(seq 1 12); do
  curl -fsS --max-time 3 "http://127.0.0.1:${PULSE_PORT}/health" >/dev/null || false
  curl -fsS --max-time 3 "http://127.0.0.1:${PULSE_PORT}/api/operator/krx-prebuy-top?limit=10" >/dev/null || true
  curl -fsS --max-time 3 "http://127.0.0.1:${PULSE_PORT}/api/history/candidates?limit=10" >/dev/null || true
  sleep 5
done
log "60-second responsiveness soak PASS"

trap - ERR; NEW_STARTED=0
log "DEPLOY PASS"
log "IMAGE=$PULSE_IMAGE"
log "VERSION=$EXPECTED_VERSION"
log "PACKAGE_RELEASE=$EXPECTED_PACKAGE_RELEASE"
log "PULSE_DATA=$PULSE_DATA_DIR"
log "PROXY_NETWORK=$PULSE_PROXY_NETWORK"
log "PUBLIC_URL=https://${PULSE_PUBLIC_HOST}"
if [ "$OLD_RENAMED" -eq 1 ]; then log "previous PULSE retained stopped as: $PREVIOUS"; fi
