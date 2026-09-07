#!/usr/bin/env bash
set -euo pipefail
BASE=/opt/pulse-edge
SRC="$BASE/PULSE_EDGE_CORE_2_1_3_DATA_PATH_2_1_7_SOURCE.tar.gz"
DF="$BASE/Dockerfile"
BUILD=/tmp/pulse-edge-data-path-217-build
IMG=pulse-edge:core-2.1.3-data-path-2.1.7
NEW=pulse-edge-canary-data-path-2.1.7
NET=kiwoom-net
PUB=https://3-38-25-20.nip.io
PORT=18017

rm -rf "$BUILD" && mkdir -p "$BUILD"
tar -xzf "$SRC" -C "$BUILD"
cp "$DF" "$BUILD/Dockerfile"

echo '[1/8] isolated build; no existing container changed'
docker build -t "$IMG" "$BUILD"

echo '[2/8] start versioned canary only'
docker rm -f "$NEW" >/dev/null 2>&1 || true
docker run -d --name "$NEW" --restart unless-stopped --env-file "$BASE/.env" -v "$BASE/data:/app/data" -p 127.0.0.1:${PORT}:8000 "$IMG" >/dev/null
docker network connect "$NET" "$NEW" >/dev/null 2>&1 || true

for i in $(seq 1 30); do
  if curl -fsS --max-time 3 http://127.0.0.1:${PORT}/health >/tmp/217-health.json 2>/dev/null; then break; fi
  sleep 1
done
curl -fsS --max-time 5 http://127.0.0.1:${PORT}/health >/dev/null
echo '[3/8] direct health PASS'

curl -fsS --max-time 5 http://127.0.0.1:${PORT}/ >/tmp/217-page.html
grep -q 'DATA PATH 2.1.7' /tmp/217-page.html
curl -fsS --max-time 5 'http://127.0.0.1:'${PORT}'/api/history/candidates?limit=500' >/tmp/217-history.json
python3 - <<'PY'
import json
x=json.load(open('/tmp/217-history.json'))
assert x.get('storage') == 'memory_ring_500'
assert x.get('feeds_current_ranking') is False
PY
echo '[4/8] UI + candidate-history contract PASS'

echo '[5/8] 10-minute live canary soak'
for i in $(seq 1 40); do
  curl -fsS --max-time 4 http://127.0.0.1:${PORT}/health >/dev/null
  curl -fsS --max-time 5 http://127.0.0.1:${PORT}/api/operator/krx-discovery-top?limit=10 >/dev/null
  curl -fsS --max-time 5 http://127.0.0.1:${PORT}/api/operator/krx-prebuy-top?limit=10 >/dev/null
  curl -fsS --max-time 5 http://127.0.0.1:${PORT}/api/history/candidates?limit=500 >/dev/null
  H=$(docker inspect "$NEW" --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}')
  [ "$H" = healthy ] || { echo "CANARY_HEALTH=$H"; exit 1; }
  sleep 15
done
echo '[6/8] 10-minute responsiveness PASS'

# Switch network alias only after soak. No rename/image overwrite/Caddyfile edit.
for c in $(docker ps --format '{{.Names}}' | grep '^pulse-edge-canary-' || true); do
  [ "$c" = "$NEW" ] && continue
  if docker inspect "$c" --format '{{json .NetworkSettings.Networks}}' | grep -q '"kiwoom-net"'; then
    docker network disconnect "$NET" "$c" >/dev/null 2>&1 || true
    docker network connect "$NET" "$c" >/dev/null 2>&1 || true
  fi
done
docker network disconnect "$NET" "$NEW" >/dev/null 2>&1 || true
docker network connect --alias pulse-edge "$NET" "$NEW"
docker restart kiwoom-caddy >/dev/null
sleep 4

echo '[7/8] public cutover verification'
for i in 1 2 3 4 5; do
  CODE=$(curl -k -sS --max-time 8 -o /tmp/217-public -w '%{http_code}' "$PUB/" || true)
  [ "$CODE" = 200 ] && break
  sleep 2
done
[ "${CODE:-000}" = 200 ] || { echo "PUBLIC_HTTP=${CODE:-000}"; exit 1; }

# 2-minute post-cutover check
for i in $(seq 1 8); do
  curl -k -fsS --max-time 8 "$PUB/health" >/dev/null
  curl -k -fsS --max-time 8 "$PUB/api/history/candidates?limit=500" >/dev/null
  sleep 15
done

echo '[8/8] OPEN_OK + 2-minute post-cutover PASS'
echo 'CORE=2.1.3'
echo 'PATCH=DATA-PATH-2.1.7'
echo "CONTAINER=$NEW"
echo 'NO RENAME / NO IMAGE OVERWRITE / NO CADDYFILE EDIT'
