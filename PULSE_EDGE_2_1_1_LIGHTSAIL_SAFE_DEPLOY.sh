#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

# PULSE EDGE 2.1.1 PREOPEN LIVE — AWS Lightsail safe deployment
# STRICT ISOLATION: this script never discovers/reuses NOVA containers, images,
# volumes, databases or environment files. It operates only on explicit PULSE paths.

RELEASE="2.1.1-preopen-live-gate"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SOURCE_ARCHIVE="${SCRIPT_DIR}/PULSE_EDGE_2_1_1_PREOPEN_LIVE_SOURCE.tar.gz"
DOCKERFILE="${SCRIPT_DIR}/Dockerfile"
EXPECTED_SOURCE_SHA="7426d168b061b060302f4ca9db72a87276f474b467f74dea72f47bc2238d41f4"
EXPECTED_DOCKERFILE_SHA="080316345cef128302dd5f8482c275deb4d19f06f565c909eaa456aa043c65d2"

PULSE_BASE_DIR="${PULSE_BASE_DIR:-/opt/pulse-edge}"
PULSE_DATA_DIR="${PULSE_DATA_DIR:-${PULSE_BASE_DIR}/data}"
PULSE_ENV_FILE="${PULSE_ENV_FILE:-${PULSE_BASE_DIR}/.env}"
PULSE_CONTAINER="${PULSE_CONTAINER:-pulse-edge}"
PULSE_IMAGE="${PULSE_IMAGE:-pulse-edge:2.1.0-live-certification}"
PULSE_PORT="${PULSE_PORT:-8000}"
STAMP="$(date +%Y%m%d-%H%M%S)"
BUILD_DIR="${PULSE_BASE_DIR}/build/${STAMP}"
CANARY="pulse-edge-canary-${STAMP}"
PREVIOUS="pulse-edge-prev-${STAMP}"
OLD_EXISTS=0
OLD_RENAMED=0
NEW_STARTED=0
CANARY_STARTED=0

log(){ printf '[PULSE DEPLOY] %s\n' "$*"; }
die(){ printf '[PULSE DEPLOY][ABORT] %s\n' "$*" >&2; exit 1; }
contains_nova(){ printf '%s' "$1" | grep -qi 'nova'; }

cleanup_canary(){
  set +e
  if [ "$CANARY_STARTED" -eq 1 ] && [ "${DOCKER+x}" = x ]; then
    "${DOCKER[@]}" rm -f "$CANARY" >/dev/null 2>&1 || true
  fi
  rm -rf "${PULSE_BASE_DIR}/canary/${STAMP}" >/dev/null 2>&1 || true
}
trap cleanup_canary EXIT

# Absolute NOVA isolation gate.
for v in "$PULSE_BASE_DIR" "$PULSE_DATA_DIR" "$PULSE_ENV_FILE" "$PULSE_CONTAINER" "$PULSE_IMAGE"; do
  contains_nova "$v" && die "NOVA reference detected in PULSE deployment setting: $v"
done

case "$PULSE_PORT" in (*[!0-9]*|'') die "PULSE_PORT must be numeric";; esac
[ "$PULSE_PORT" -ge 1 ] && [ "$PULSE_PORT" -le 65535 ] || die "PULSE_PORT out of range"

for cmd in curl tar sha256sum awk grep mkdir rm cp df seq sleep; do
  command -v "$cmd" >/dev/null 2>&1 || die "required command missing: $cmd"
done

# Docker access: use current user first, then passwordless sudo if available.
if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
  DOCKER=(docker)
elif command -v sudo >/dev/null 2>&1 && sudo -n docker info >/dev/null 2>&1; then
  DOCKER=(sudo docker)
else
  die "Docker daemon is not accessible. Check Docker installation/permissions first."
fi

[ -f "$SOURCE_ARCHIVE" ] || die "missing source archive: $SOURCE_ARCHIVE"
[ -f "$DOCKERFILE" ] || die "missing Dockerfile: $DOCKERFILE"

ACTUAL_SOURCE_SHA="$(sha256sum "$SOURCE_ARCHIVE" | awk '{print $1}')"
ACTUAL_DOCKER_SHA="$(sha256sum "$DOCKERFILE" | awk '{print $1}')"
[ "$ACTUAL_SOURCE_SHA" = "$EXPECTED_SOURCE_SHA" ] || die "source SHA256 mismatch"
[ "$ACTUAL_DOCKER_SHA" = "$EXPECTED_DOCKERFILE_SHA" ] || die "Dockerfile SHA256 mismatch"
log "package SHA256 verified"

# Disk and memory guard before any existing PULSE container is touched.
mkdir -p "$PULSE_BASE_DIR" "$PULSE_DATA_DIR/pulse_edge" "$BUILD_DIR"
FREE_KB="$(df -Pk "$PULSE_BASE_DIR" | awk 'NR==2 {print $4}')"
[ "${FREE_KB:-0}" -ge 700000 ] || die "less than 700 MB free disk space; refusing deployment"
MEM_AVAIL_KB="$(awk '/MemAvailable:/ {print $2}' /proc/meminfo 2>/dev/null || echo 0)"
SWAP_FREE_KB="$(awk '/SwapFree:/ {print $2}' /proc/meminfo 2>/dev/null || echo 0)"
if [ "$((MEM_AVAIL_KB + SWAP_FREE_KB))" -lt 350000 ]; then
  die "available RAM+swap below 350 MB; refusing build to avoid Lightsail OOM"
fi

# Production env must be explicitly PULSE-owned. Never import environment from another container.
if [ ! -f "$PULSE_ENV_FILE" ]; then
  tar -xOf "$SOURCE_ARCHIVE" .env.example > "${PULSE_BASE_DIR}/.env.example" 2>/dev/null || true
  die "PULSE env file missing: $PULSE_ENV_FILE (template written to ${PULSE_BASE_DIR}/.env.example)"
fi

# Reject NOVA-named keys and NOVA paths/URLs in the PULSE env file without printing secrets.
if grep -Eiq '^[[:space:]]*[^#[:space:]]*NOVA[^=]*=' "$PULSE_ENV_FILE"; then
  die "NOVA-named environment key detected in PULSE env file"
fi
if grep -Eiq '^[[:space:]]*PULSE_[A-Z0-9_]*(PATH|DIR|DB|BASE|URL)[A-Z0-9_]*=.*nova' "$PULSE_ENV_FILE"; then
  die "NOVA path/URL detected in PULSE env file"
fi

# If live feed is explicitly enabled, Kiwoom credentials must be present before touching production.
if grep -Eq '^[[:space:]]*PULSE_FEED_ENABLED=[Tt][Rr][Uu][Ee][[:space:]]*$' "$PULSE_ENV_FILE"; then
  grep -Eq '^PULSE_KIWOOM_APPKEY=.+$' "$PULSE_ENV_FILE" || die "PULSE_KIWOOM_APPKEY is missing"
  grep -Eq '^PULSE_KIWOOM_SECRETKEY=.+$' "$PULSE_ENV_FILE" || die "PULSE_KIWOOM_SECRETKEY is missing"
fi

# Inspect ONLY the exact PULSE container name. No generic container discovery.
if "${DOCKER[@]}" container inspect "$PULSE_CONTAINER" >/dev/null 2>&1; then
  OLD_EXISTS=1
  OLD_IMAGE="$("${DOCKER[@]}" inspect -f '{{.Config.Image}}' "$PULSE_CONTAINER")"
  OLD_MOUNTS="$("${DOCKER[@]}" inspect -f '{{range .Mounts}}{{.Source}} -> {{.Destination}};{{end}}' "$PULSE_CONTAINER")"
  contains_nova "$OLD_IMAGE" && die "existing pulse-edge container points to a NOVA image; refusing connection"
  contains_nova "$OLD_MOUNTS" && die "existing pulse-edge container has a NOVA mount; refusing connection"
  OLD_DATA_SOURCE="$("${DOCKER[@]}" inspect -f '{{range .Mounts}}{{if eq .Destination "/app/data"}}{{.Source}}{{end}}{{end}}' "$PULSE_CONTAINER")"
  if [ -n "$OLD_DATA_SOURCE" ] && [ "$OLD_DATA_SOURCE" != "$PULSE_DATA_DIR" ]; then
    die "existing PULSE /app/data is $OLD_DATA_SOURCE, but configured PULSE_DATA_DIR is $PULSE_DATA_DIR. Set PULSE_DATA_DIR explicitly after verifying it is PULSE-only. Nothing changed."
  fi
fi

# Build context from the verified PULSE source archive.
tar -xzf "$SOURCE_ARCHIVE" -C "$BUILD_DIR"
cp "$DOCKERFILE" "$BUILD_DIR/Dockerfile"
[ -d "$BUILD_DIR/pulse_edge" ] || die "build context missing pulse_edge"
[ -f "$BUILD_DIR/requirements-runtime.txt" ] || die "build context missing requirements-runtime.txt"

# PULSE executable code must contain no NOVA references.
NOVA_SCAN="/tmp/pulse_nova_hits_$STAMP.txt"
if grep -Rni --exclude='*.pyc' --exclude='*.sqlite*' 'nova' "$BUILD_DIR/pulse_edge" >"$NOVA_SCAN" 2>/dev/null; then
  rm -f "$NOVA_SCAN"
  die "NOVA reference found inside PULSE runtime source"
fi
rm -f "$NOVA_SCAN"

log "building $PULSE_IMAGE (existing production is still untouched)"
"${DOCKER[@]}" build --tag "$PULSE_IMAGE" "$BUILD_DIR"

# Canary is completely isolated from production credentials and broker connections.
# It verifies only image startup + HTTP health using temporary PULSE-only data.
CANARY_DATA="${PULSE_BASE_DIR}/canary/${STAMP}/data"
mkdir -p "$CANARY_DATA/pulse_edge"
log "starting isolated canary (no env-file, broker/data acquisition disabled)"
"${DOCKER[@]}" run -d --name "$CANARY"   --label com.pulse-edge.project=pulse-edge   -e PULSE_ENV=canary   -e PULSE_FEED_ENABLED=false   -e PULSE_DISCOVERY_ENABLED=false   -e PULSE_INVESTOR_FLOW_ENABLED=false   -e PULSE_UNIVERSE_ENABLED=false   -e PULSE_BACKGROUND_COVERAGE_ENABLED=false   -e PULSE_SECTOR_ENABLED=false   -e PULSE_SMART_MONEY_ENABLED=false   -e PULSE_IGNITION_ENABLED=false   -e PULSE_SUPPLY_ABSORPTION_ENABLED=false   -e PULSE_DUAL_PERFORMANCE_ENABLED=false   -e PULSE_DUAL_DAILY_OUTCOMES_ENABLED=false   -e PULSE_TRANSITION_OPS_ENABLED=false   -e PULSE_NXT_NATIVE_ENABLED=false   -e PULSE_NXT_OPERATIONS_BOARD_ENABLED=false   -e PULSE_MISSED_OPPORTUNITY_ENABLED=false   -e PULSE_CURRENT_ENRICHMENT_ENABLED=false   -e PULSE_KRX_OPERATIONS_BOARD_ENABLED=false   -e PULSE_DAILY_REVIEW_ENABLED=false   -e PULSE_LIVE_SHADOW_VALIDATION_ENABLED=false   -e PULSE_LIVE_CERTIFICATION_ENABLED=false   -p 127.0.0.1::8000   -v "$CANARY_DATA:/app/data"   "$PULSE_IMAGE" >/dev/null
CANARY_STARTED=1
CANARY_PORT="$("${DOCKER[@]}" port "$CANARY" 8000/tcp | awk -F: 'NR==1 {print $NF}')"
[ -n "$CANARY_PORT" ] || die "could not determine canary port"

canary_ok=0
for _ in $(seq 1 30); do
  if curl -fsS --max-time 3 "http://127.0.0.1:${CANARY_PORT}/health" >/dev/null 2>&1; then canary_ok=1; break; fi
  sleep 1
done
if [ "$canary_ok" -ne 1 ]; then
  "${DOCKER[@]}" logs --tail 120 "$CANARY" || true
  die "canary /health failed; production was not touched"
fi
"${DOCKER[@]}" rm -f "$CANARY" >/dev/null
CANARY_STARTED=0
rm -rf "${PULSE_BASE_DIR}/canary/${STAMP}"
log "canary PASS"

rollback(){
  rc=$?
  set +e
  if [ "$NEW_STARTED" -eq 1 ]; then "${DOCKER[@]}" rm -f "$PULSE_CONTAINER" >/dev/null 2>&1; fi
  if [ "$OLD_RENAMED" -eq 1 ]; then
    "${DOCKER[@]}" rename "$PREVIOUS" "$PULSE_CONTAINER" >/dev/null 2>&1
    "${DOCKER[@]}" start "$PULSE_CONTAINER" >/dev/null 2>&1
    log "ROLLBACK: previous PULSE container restored"
  fi
  exit $rc
}
trap rollback ERR

# Only now touch the exact existing PULSE container.
if [ "$OLD_EXISTS" -eq 1 ]; then
  log "stopping current PULSE container only"
  "${DOCKER[@]}" stop --time 20 "$PULSE_CONTAINER" >/dev/null
  "${DOCKER[@]}" rename "$PULSE_CONTAINER" "$PREVIOUS"
  OLD_RENAMED=1
fi

log "starting new PULSE container"
"${DOCKER[@]}" run -d --name "$PULSE_CONTAINER"   --label com.pulse-edge.project=pulse-edge   --restart unless-stopped   --env-file "$PULSE_ENV_FILE"   -p "${PULSE_PORT}:8000"   -v "$PULSE_DATA_DIR:/app/data"   "$PULSE_IMAGE" >/dev/null
NEW_STARTED=1

# Keep the existing HTTPS reverse proxy path stable across PULSE upgrades.
# This connects only the new PULSE container to the explicit PULSE proxy network.
if [ -n "" ]; then
  if "" network inspect "" >/dev/null 2>&1; then
    "" network connect "" "" 2>/dev/null || true
    log "PULSE proxy network connected: "
  else
    log "proxy network not present; direct : health remains available"
  fi
fi

prod_ok=0
for _ in $(seq 1 45); do
  if curl -fsS --max-time 3 "http://127.0.0.1:${PULSE_PORT}/health" >/dev/null 2>&1; then prod_ok=1; break; fi
  sleep 1
done
if [ "$prod_ok" -ne 1 ]; then
  "${DOCKER[@]}" logs --tail 160 "$PULSE_CONTAINER" || true
  false
fi

# Health passed. Disable rollback trap and retain previous PULSE container stopped for manual rollback.
trap - ERR
NEW_STARTED=0
log "DEPLOY PASS: http://127.0.0.1:${PULSE_PORT}/health"
if [ "$OLD_RENAMED" -eq 1 ]; then
  log "previous PULSE container retained (stopped) as: $PREVIOUS"
fi
log "PULSE data path: $PULSE_DATA_DIR"
log "NOVA resources used: ZERO"
