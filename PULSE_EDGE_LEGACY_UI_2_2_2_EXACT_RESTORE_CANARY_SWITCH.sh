#!/usr/bin/env bash
set -euo pipefail
BASE=/opt/pulse-edge
SRC="$BASE/PULSE_EDGE_CORE_2_1_3_LEGACY_UI_2_2_2_EXACT_RESTORE_SOURCE.tar.gz"
DF="$BASE/Dockerfile"
BUILD=/tmp/pulse-edge-legacy-ui-222-build
IMG=pulse-edge:core-2.1.3-legacy-ui-2.2.2
NEW=pulse-edge-canary-legacy-ui-2.2.2
OLD=pulse-edge-canary-2.1.6-ui
NET=kiwoom-net
PUB=https://3-38-25-20.nip.io
rm -rf "$BUILD" && mkdir -p "$BUILD"
tar -xzf "$SRC" -C "$BUILD"
cp "$DF" "$BUILD/Dockerfile"
echo '[1/7] build isolated; no existing container changed'
docker build -t "$IMG" "$BUILD"
echo '[2/7] start versioned canary'
docker rm -f "$NEW" >/dev/null 2>&1 || true
docker run -d --name "$NEW" --restart unless-stopped --env-file "$BASE/.env" -v "$BASE/data:/app/data" -p 127.0.0.1:18022:8000 "$IMG" >/dev/null
docker network connect "$NET" "$NEW" >/dev/null 2>&1 || true
for i in $(seq 1 30); do
  if curl -fsS --max-time 3 http://127.0.0.1:18022/health >/tmp/legacy222-health.json 2>/dev/null; then break; fi
  sleep 1
done
curl -fsS --max-time 5 http://127.0.0.1:18022/health >/dev/null
echo '[3/7] direct canary health PASS'
# static page + assets direct
curl -fsS --max-time 5 http://127.0.0.1:18022/ >/tmp/legacy222-page.html
curl -fsS --max-time 5 http://127.0.0.1:18022/assets/pulse.js >/dev/null
curl -fsS --max-time 5 http://127.0.0.1:18022/assets/pulse.css >/dev/null
grep -q 'LEGACY UI RESTORE' /tmp/legacy222-page.html
echo '[4/7] exact legacy UI contract PASS'
# record current pulse-edge alias holder(s), then switch alias only
ROLLBACK_TARGET=""
if docker ps --format '{{.Names}}' | grep -qx "$OLD"; then ROLLBACK_TARGET="$OLD"; fi
# remove pulse-edge alias from all connected pulse-edge canaries by reconnecting without alias
for c in $(docker ps --format '{{.Names}}' | grep '^pulse-edge-canary-' || true); do
  [ "$c" = "$NEW" ] && continue
  if docker inspect "$c" --format '{{json .NetworkSettings.Networks}}' | grep -q '"kiwoom-net"'; then
    docker network disconnect "$NET" "$c" >/dev/null 2>&1 || true
    docker network connect "$NET" "$c" >/dev/null 2>&1 || true
  fi
done
docker network disconnect "$NET" "$NEW" >/dev/null 2>&1 || true
docker network connect --alias pulse-edge "$NET" "$NEW"
echo '[5/7] switched only network alias pulse-edge -> legacy UI 2.2.2'
# restart caddy to flush DNS/upstream state, no Caddyfile edit
docker restart kiwoom-caddy >/dev/null
sleep 4
CODE=$(curl -k -sS --max-time 8 -o /tmp/legacy222-public.html -w '%{http_code}' "$PUB/" || true)
if [ "$CODE" != 200 ]; then
  echo "PUBLIC FAIL HTTP=$CODE; rolling alias back"
  docker network disconnect "$NET" "$NEW" >/dev/null 2>&1 || true
  docker network connect "$NET" "$NEW" >/dev/null 2>&1 || true
  if [ -n "$ROLLBACK_TARGET" ]; then
    docker network disconnect "$NET" "$ROLLBACK_TARGET" >/dev/null 2>&1 || true
    docker network connect --alias pulse-edge "$NET" "$ROLLBACK_TARGET"
  fi
  docker restart kiwoom-caddy >/dev/null || true
  exit 1
fi
grep -q 'LEGACY UI RESTORE' /tmp/legacy222-public.html
echo '[6/7] public page PASS'
# quick 2-minute health stability check, bounded
for i in $(seq 1 12); do
  curl -fsS --max-time 4 http://127.0.0.1:18022/health >/dev/null || { echo 'CANARY HEALTH FAIL'; exit 1; }
  sleep 10
done
echo '[7/7] 2-minute stability PASS'
echo 'OPEN_OK'
echo 'CORE=2.1.3'
echo 'UI=LEGACY-2.2.2-EXACT-RESTORE'
echo "CONTAINER=$NEW"
echo 'NO RENAME / NO IMAGE OVERWRITE / NO CADDYFILE EDIT'
