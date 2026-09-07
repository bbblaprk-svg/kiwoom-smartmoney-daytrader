#!/usr/bin/env bash
set -euo pipefail
BASE=/opt/pulse-edge
SRC="$BASE/PULSE_EDGE_2_1_6_UI_PHOTO_LAYOUT_RESTORE_STABLE_CORE_SOURCE.tar.gz"
DOCKERFILE="$BASE/Dockerfile"
IMG="pulse-edge:2.1.6-ui-photo-layout-restore"
CANARY="pulse-edge-canary-2.1.6-ui"
PORT=18016
BUILD_DIR="/tmp/pulse-edge-build-2.1.6"
[ -f "$SRC" ] || { echo "SOURCE MISSING: $SRC"; exit 2; }
[ -f "$DOCKERFILE" ] || { echo "DOCKERFILE MISSING: $DOCKERFILE"; exit 2; }
rm -rf "$BUILD_DIR" && mkdir -p "$BUILD_DIR"
tar -xzf "$SRC" -C "$BUILD_DIR"
cp "$DOCKERFILE" "$BUILD_DIR/Dockerfile"
echo "[1/8] isolated build; production untouched"
sudo docker build --pull=false -t "$IMG" -f "$BUILD_DIR/Dockerfile" "$BUILD_DIR"
echo "[2/8] start only versioned canary"
sudo docker rm -f "$CANARY" >/dev/null 2>&1 || true
sudo docker run -d --name "$CANARY" --env-file "$BASE/.env" -p 127.0.0.1:${PORT}:8000 "$IMG" >/dev/null
sudo docker network connect kiwoom-net "$CANARY" >/dev/null 2>&1 || true
echo "[3/8] canary health"
OK=0
for i in $(seq 1 40); do
  if curl -fsS --max-time 3 http://127.0.0.1:${PORT}/health >/tmp/pulse216-health.json 2>/dev/null; then OK=1; break; fi
  sleep 1
done
[ "$OK" = 1 ] || { echo "CANARY START FAIL"; sudo docker logs --tail 100 "$CANARY"; exit 3; }
cat /tmp/pulse216-health.json; echo
echo "[4/8] UI contract"
PAGE=$(curl -fsS --max-time 5 http://127.0.0.1:${PORT}/)
JS=$(curl -fsS --max-time 5 http://127.0.0.1:${PORT}/assets/pulse.js)
printf '%s' "$PAGE" | grep -q 'UI 2.1.6 · PHOTO LAYOUT RESTORE'
printf '%s' "$PAGE" | grep -q 'runtimeCpu'
printf '%s' "$PAGE" | grep -q 'CANDIDATE HISTORY · 500 MAX · 20 VISIBLE'
printf '%s' "$PAGE" | grep -q 'MKT RS'
printf '%s' "$PAGE" | grep -q 'SECTOR RS'
printf '%s' "$JS" | grep -q 'slice(0,500)'
printf '%s' "$JS" | grep -q 'runtimeCpu'
echo "UI CONTRACT PASS"
echo "[5/8] production remains healthy"
curl -fsS --max-time 5 http://127.0.0.1:8000/health >/tmp/pulse216-prod-health.json
cat /tmp/pulse216-prod-health.json; echo
echo "[6/8] 10-minute dual health soak"
for i in $(seq 1 20); do
  curl -fsS --max-time 4 http://127.0.0.1:${PORT}/health >/dev/null || { echo "CANARY HEALTH FAIL @ $i"; exit 4; }
  curl -fsS --max-time 4 http://127.0.0.1:8000/health >/dev/null || { echo "PRODUCTION HEALTH FAIL @ $i"; exit 5; }
  sleep 30
done
echo "10-MIN SOAK PASS"
echo "[7/8] resources/status"
sudo docker stats --no-stream "$CANARY" || true
sudo docker ps --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}' | grep -E 'NAMES|pulse-edge'
echo "[8/8] NO CADDY SWITCH / NO PROD RENAME / NO PROD STOP"
echo "CANARY_READY=$CANARY"
echo "IMAGE=$IMG"
echo "CORE=2.1.3"
echo "UI=2.1.6"
echo "PORT=$PORT"
