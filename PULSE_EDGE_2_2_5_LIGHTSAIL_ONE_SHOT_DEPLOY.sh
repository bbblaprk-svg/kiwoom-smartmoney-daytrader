#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

RELEASE="2.2.5-stable-core-history-early-buy"
EXPECTED_VERSION="2.2.5-stable-core-history-early-buy"
EXPECTED_PACKAGE_RELEASE="2.2.5_STABLE_CORE_HISTORY_EARLY_BUY"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SOURCE_ARCHIVE="${SCRIPT_DIR}/PULSE_EDGE_2_2_5_STABLE_CORE_HISTORY_EARLY_BUY_SOURCE.tar.gz"
DOCKERFILE="${SCRIPT_DIR}/Dockerfile"
EXPECTED_SOURCE_SHA="2f18bc0d97c4bbdaebec88d26a40a5b78b40aae61a771aab0fa6398bf1d35f31"
EXPECTED_DOCKERFILE_SHA="ea5a8b7cd0818cf46d6387aa4d898105acc9f4af2ea33a5550a7a474e09ada48"

PULSE_BASE_DIR="${PULSE_BASE_DIR:-/opt/pulse-edge}"
PULSE_DATA_DIR="${PULSE_DATA_DIR:-${PULSE_BASE_DIR}/data}"
PULSE_ENV_FILE="${PULSE_ENV_FILE:-${PULSE_BASE_DIR}/.env}"
PULSE_CONTAINER="${PULSE_CONTAINER:-pulse-edge}"
PULSE_IMAGE="${PULSE_IMAGE:-pulse-edge:2.2.5-stable-core-history-early-buy}"
PULSE_PORT="${PULSE_PORT:-8000}"
PULSE_PROXY_NETWORK="${PULSE_PROXY_NETWORK:-kiwoom-net}"
PULSE_CADDY_CONTAINER="${PULSE_CADDY_CONTAINER:-kiwoom-caddy}"
PULSE_CADDYFILE="${PULSE_CADDYFILE:-/home/ubuntu/kiwoom-caddy/Caddyfile}"
PULSE_PUBLIC_HOST="${PULSE_PUBLIC_HOST:-3-38-25-20.nip.io}"
PULSE_PUBLIC_HEALTH_URL="https://${PULSE_PUBLIC_HOST}/health"
STAMP="$(date +%Y%m%d-%H%M%S)"
BUILD_DIR="${PULSE_BASE_DIR}/build/${STAMP}"
CANARY="pulse-edge-canary-${STAMP}"
PREVIOUS="pulse-edge-prev-${STAMP}"
OLD_EXISTS=0; OLD_RENAMED=0; NEW_STARTED=0; CADDY_BACKUP=""
log(){ printf '[PULSE DEPLOY] %s\n' "$*"; }
die(){ printf '[PULSE DEPLOY][ABORT] %s\n' "$*" >&2; exit 1; }

for cmd in curl tar sha256sum awk grep mkdir rm cp df seq sleep python3 nohup; do command -v "$cmd" >/dev/null 2>&1 || die "required command missing: $cmd"; done
if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then DOCKER=(docker); elif command -v sudo >/dev/null 2>&1 && sudo -n docker info >/dev/null 2>&1; then DOCKER=(sudo docker); else die "Docker daemon is not accessible"; fi
[ -f "$SOURCE_ARCHIVE" ] || die "missing source archive"
[ -f "$DOCKERFILE" ] || die "missing Dockerfile"
[ -f "$PULSE_ENV_FILE" ] || die "missing PULSE env file"
[ "$(sha256sum "$SOURCE_ARCHIVE" | awk '{print $1}')" = "$EXPECTED_SOURCE_SHA" ] || die "source SHA256 mismatch"
[ "$(sha256sum "$DOCKERFILE" | awk '{print $1}')" = "$EXPECTED_DOCKERFILE_SHA" ] || die "Dockerfile SHA256 mismatch"
log "package SHA256 verified"

mkdir -p "$PULSE_BASE_DIR" "$PULSE_DATA_DIR/pulse_edge" "$BUILD_DIR"
"${DOCKER[@]}" network inspect "$PULSE_PROXY_NETWORK" >/dev/null 2>&1 || die "proxy network missing"
"${DOCKER[@]}" container inspect "$PULSE_CADDY_CONTAINER" >/dev/null 2>&1 || die "Caddy container missing"
[ -f "$PULSE_CADDYFILE" ] || die "Caddyfile missing"
if "${DOCKER[@]}" container inspect "$PULSE_CONTAINER" >/dev/null 2>&1; then OLD_EXISTS=1; fi

tar -xzf "$SOURCE_ARCHIVE" -C "$BUILD_DIR"; cp "$DOCKERFILE" "$BUILD_DIR/Dockerfile"
log "building $PULSE_IMAGE; current production untouched"
"${DOCKER[@]}" build --tag "$PULSE_IMAGE" "$BUILD_DIR"

CANARY_DATA="${PULSE_BASE_DIR}/canary/${STAMP}/data"; mkdir -p "$CANARY_DATA/pulse_edge"
"${DOCKER[@]}" run -d --name "$CANARY" --label com.pulse-edge.project=pulse-edge   -e PULSE_ENV=canary -e PULSE_FEED_ENABLED=false -e PULSE_DISCOVERY_ENABLED=false   -e PULSE_INVESTOR_FLOW_ENABLED=false -e PULSE_UNIVERSE_ENABLED=false   -e PULSE_BACKGROUND_COVERAGE_ENABLED=false -e PULSE_SECTOR_ENABLED=false   -e PULSE_SMART_MONEY_ENABLED=false -e PULSE_IGNITION_ENABLED=false   -e PULSE_SUPPLY_ABSORPTION_ENABLED=false -e PULSE_DUAL_PERFORMANCE_ENABLED=false   -e PULSE_TRANSITION_OPS_ENABLED=false -e PULSE_NXT_NATIVE_ENABLED=false   -e PULSE_NXT_OPERATIONS_BOARD_ENABLED=false -e PULSE_KRX_OPERATIONS_BOARD_ENABLED=false   -e PULSE_DAILY_REVIEW_ENABLED=false -e PULSE_LIVE_SHADOW_VALIDATION_ENABLED=false   -e PULSE_LIVE_CERTIFICATION_ENABLED=false -p 127.0.0.1::8000 -v "$CANARY_DATA:/app/data" "$PULSE_IMAGE" >/dev/null
CANARY_PORT="$("${DOCKER[@]}" port "$CANARY" 8000/tcp | awk -F: 'NR==1 {print $NF}')"
canary_ok=0; for _ in $(seq 1 30); do if curl -fsS --max-time 3 "http://127.0.0.1:${CANARY_PORT}/health" >/dev/null 2>&1; then canary_ok=1; break; fi; sleep 1; done
[ "$canary_ok" -eq 1 ] || { "${DOCKER[@]}" logs --tail 120 "$CANARY" || true; die "canary health failed"; }
"${DOCKER[@]}" rm -f "$CANARY" >/dev/null; rm -rf "${PULSE_BASE_DIR}/canary/${STAMP}"; log "canary PASS"

rollback(){ rc=$?; set +e; log "ROLLBACK starting"; "${DOCKER[@]}" rm -f "$PULSE_CONTAINER" >/dev/null 2>&1 || true; if [ "$OLD_RENAMED" -eq 1 ]; then "${DOCKER[@]}" rename "$PREVIOUS" "$PULSE_CONTAINER" >/dev/null 2>&1 || true; "${DOCKER[@]}" start "$PULSE_CONTAINER" >/dev/null 2>&1 || true; "${DOCKER[@]}" network connect "$PULSE_PROXY_NETWORK" "$PULSE_CONTAINER" >/dev/null 2>&1 || true; fi; if [ -n "$CADDY_BACKUP" ] && [ -f "$CADDY_BACKUP" ]; then cp "$CADDY_BACKUP" "$PULSE_CADDYFILE"; "${DOCKER[@]}" exec "$PULSE_CADDY_CONTAINER" caddy reload --config /etc/caddy/Caddyfile >/dev/null 2>&1 || true; fi; log "ROLLBACK complete"; exit $rc; }
trap rollback ERR

if [ "$OLD_EXISTS" -eq 1 ]; then log "retaining current PULSE as $PREVIOUS"; "${DOCKER[@]}" stop --time 20 "$PULSE_CONTAINER" >/dev/null; "${DOCKER[@]}" rename "$PULSE_CONTAINER" "$PREVIOUS"; OLD_RENAMED=1; fi
log "starting PULSE 2.2.5"
"${DOCKER[@]}" run -d --name "$PULSE_CONTAINER" --label com.pulse-edge.project=pulse-edge --label com.pulse-edge.release="$RELEASE" --restart unless-stopped --env-file "$PULSE_ENV_FILE" -p "${PULSE_PORT}:8000" -v "$PULSE_DATA_DIR:/app/data" "$PULSE_IMAGE" >/dev/null
NEW_STARTED=1
"${DOCKER[@]}" network connect "$PULSE_PROXY_NETWORK" "$PULSE_CONTAINER"; log "connected to $PULSE_PROXY_NETWORK"

prod_ok=0
for _ in $(seq 1 45); do
  if HEALTH_JSON="$(curl -fsS --max-time 3 "http://127.0.0.1:${PULSE_PORT}/health" 2>/dev/null)"; then
    export HEALTH_JSON EXPECTED_VERSION EXPECTED_PACKAGE_RELEASE
    if python3 - <<'PY'
import json,os
x=json.loads(os.environ['HEALTH_JSON'])
assert x.get('ok') is True
assert x.get('version') == os.environ['EXPECTED_VERSION']
assert x.get('package_release') == os.environ['EXPECTED_PACKAGE_RELEASE']
PY
    then prod_ok=1; break; fi
  fi
  sleep 1
done
[ "$prod_ok" -eq 1 ] || false
log "local health + version/package contract PASS"

CADDY_BACKUP="${PULSE_CADDYFILE}.pre-2.2.5-${STAMP}"; cp "$PULSE_CADDYFILE" "$CADDY_BACKUP"
cat > "$PULSE_CADDYFILE" <<CADDY
${PULSE_PUBLIC_HOST} {
    encode gzip zstd
    reverse_proxy ${PULSE_CONTAINER}:8000
}
CADDY
"${DOCKER[@]}" exec "$PULSE_CADDY_CONTAINER" caddy reload --config /etc/caddy/Caddyfile >/dev/null
"${DOCKER[@]}" exec "$PULSE_CADDY_CONTAINER" wget -T 5 -qO- "http://${PULSE_CONTAINER}:8000/health" >/dev/null
curl -fsS --max-time 8 "$PULSE_PUBLIC_HEALTH_URL" >/dev/null
log "Caddy + public HTTPS PASS"

# 60-second live responsiveness check. No heavy synthetic full-market work is added.
log "60-second live responsiveness check"
for _ in $(seq 1 12); do
  curl -fsS --max-time 3 "http://127.0.0.1:${PULSE_PORT}/health" >/dev/null
  curl -fsS --max-time 3 "http://127.0.0.1:${PULSE_PORT}/api/operator/krx-prebuy-top?limit=10" >/dev/null || true
  curl -fsS --max-time 3 "http://127.0.0.1:${PULSE_PORT}/api/history/candidates?limit=500" >/dev/null || true
  sleep 5
done
log "60-second responsiveness PASS"

trap - ERR
log "DEPLOY PASS"
log "IMAGE=$PULSE_IMAGE"
log "VERSION=$EXPECTED_VERSION"
log "PACKAGE_RELEASE=$EXPECTED_PACKAGE_RELEASE"
log "PUBLIC_URL=https://${PULSE_PUBLIC_HOST}"
if [ "$OLD_RENAMED" -eq 1 ]; then log "previous PULSE retained stopped as: $PREVIOUS"; fi

# 20-minute one-shot guard: if the new runtime becomes non-responsive three times
# consecutively, automatically restore the exact previous PULSE container.
if [ "$OLD_RENAMED" -eq 1 ]; then
  GUARD="${PULSE_BASE_DIR}/guard-2.2.5-${STAMP}.sh"
  cat > "$GUARD" <<'GUARD_EOF'
#!/usr/bin/env bash
set +e
PORT="__PORT__"
PULSE_CONTAINER="__PULSE_CONTAINER__"
PREVIOUS="__PREVIOUS__"
PULSE_PROXY_NETWORK="__PULSE_PROXY_NETWORK__"
PULSE_CADDY_CONTAINER="__PULSE_CADDY_CONTAINER__"
STAMP="__STAMP__"
PULSE_BASE_DIR="__PULSE_BASE_DIR__"
if docker info >/dev/null 2>&1; then D=(docker); else D=(sudo docker); fi
fails=0
for i in $(seq 1 60); do
  sleep 20
  if curl -fsS --max-time 4 "http://127.0.0.1:${PORT}/health" >/dev/null 2>&1; then fails=0; else fails=$((fails+1)); fi
  if [ "$fails" -ge 3 ]; then
    echo "[PULSE GUARD] 2.2.5 unresponsive; auto-rollback" >> "${PULSE_BASE_DIR}/guard-2.2.5.log"
    "${D[@]}" stop -t 3 "$PULSE_CONTAINER" >/dev/null 2>&1 || "${D[@]}" kill "$PULSE_CONTAINER" >/dev/null 2>&1 || true
    "${D[@]}" rename "$PULSE_CONTAINER" "pulse-edge-failed-2.2.5-${STAMP}" >/dev/null 2>&1 || true
    "${D[@]}" rename "$PREVIOUS" "$PULSE_CONTAINER" >/dev/null 2>&1 || true
    "${D[@]}" start "$PULSE_CONTAINER" >/dev/null 2>&1 || true
    "${D[@]}" network connect "$PULSE_PROXY_NETWORK" "$PULSE_CONTAINER" >/dev/null 2>&1 || true
    "${D[@]}" restart "$PULSE_CADDY_CONTAINER" >/dev/null 2>&1 || true
    exit 0
  fi
done
echo "[PULSE GUARD] 2.2.5 20-minute guard PASS" >> "${PULSE_BASE_DIR}/guard-2.2.5.log"
GUARD_EOF
  sed -i \
    -e "s|__PORT__|${PULSE_PORT}|g" \
    -e "s|__PULSE_CONTAINER__|${PULSE_CONTAINER}|g" \
    -e "s|__PREVIOUS__|${PREVIOUS}|g" \
    -e "s|__PULSE_PROXY_NETWORK__|${PULSE_PROXY_NETWORK}|g" \
    -e "s|__PULSE_CADDY_CONTAINER__|${PULSE_CADDY_CONTAINER}|g" \
    -e "s|__STAMP__|${STAMP}|g" \
    -e "s|__PULSE_BASE_DIR__|${PULSE_BASE_DIR}|g" "$GUARD"
  chmod +x "$GUARD"
  nohup "$GUARD" >/dev/null 2>&1 </dev/null &
  log "20-minute auto-rollback guard armed"
fi
