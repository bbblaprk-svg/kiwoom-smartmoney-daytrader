#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

APP="${NOVA_APP_CONTAINER:-quant-nova}"
DOCKERFILE="QUANT_NOVA_R492_FEED_RECOVERY2_UISTABLE1.Dockerfile"
EXPECTED_SHA="b81dda5fd4ac6fa516aeed7d1810cf273aa4726e87761a98a3306442bfb6e9bc"
EXPECTED_VERSION="NOVA-3.3.5-R492-FEED-RECOVERY2-UISTABLE1"
IMAGE="quant-nova:r492-feed-recovery2-uistable1"
STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP="${APP}-pre-uistable1-${STAMP}"
WORK="$(mktemp -d /tmp/nova-uistable1.XXXXXX)"
ENVFILE="$WORK/runtime.env"
MOUNTFILE="$WORK/mounts.txt"
EMPTY="$WORK/empty"
mkdir -p "$EMPTY"
trap 'rm -rf "$WORK" 2>/dev/null || true' EXIT

if docker info >/dev/null 2>&1; then D=(docker)
elif sudo -n docker info >/dev/null 2>&1; then D=(sudo docker)
else echo "FAIL: Docker permission"; exit 2
fi
dc(){ "${D[@]}" "$@"; }

[[ -f "$DOCKERFILE" ]] || { echo "FAIL: $DOCKERFILE not found"; exit 2; }
ACTUAL="$(sha256sum "$DOCKERFILE" | awk '{print $1}')"
[[ "$ACTUAL" == "$EXPECTED_SHA" ]] || { echo "FAIL: Dockerfile SHA mismatch: $ACTUAL"; exit 2; }
dc inspect "$APP" >/dev/null 2>&1 || { echo "FAIL: current $APP container not found"; exit 2; }

echo "===== 1. CAPTURE RUNTIME CONTRACT ====="
dc inspect "$APP" --format '{{range .Config.Env}}{{println .}}{{end}}' > "$ENVFILE"
dc inspect "$APP" --format '{{range .Mounts}}{{printf "%s|%s|%t\n" .Source .Destination .RW}}{{end}}' > "$MOUNTFILE"
NETWORK="$(dc inspect "$APP" --format '{{.HostConfig.NetworkMode}}')"
RESTART="$(dc inspect "$APP" --format '{{.HostConfig.RestartPolicy.Name}}')"
[[ -n "$NETWORK" && "$NETWORK" != "default" ]] || NETWORK="kiwoom-net"
[[ -n "$RESTART" && "$RESTART" != "no" ]] || RESTART="unless-stopped"

echo "===== 2. CLEAN BUILD ====="
dc build --pull -f "$DOCKERFILE" -t "$IMAGE" "$EMPTY"
VER="$(dc image inspect "$IMAGE" --format '{{index .Config.Labels "org.opencontainers.image.version"}}')"
[[ "$VER" == "$EXPECTED_VERSION" ]] || { echo "FAIL: version=$VER"; exit 2; }
dc run --rm --entrypoint sh "$IMAGE" -lc '
  grep -q "prebuy:{holdMs:75000}" /app/static/stable-board.js &&
  grep -q "largecap_swing:{holdMs:120000}" /app/static/stable-board.js &&
  grep -q "energy_now:{holdMs:90000}" /app/static/stable-board.js &&
  grep -q "power_path:{holdMs:120000}" /app/static/stable-board.js &&
  grep -q "height:34px" /app/static/decision-panels.css
' || { echo "FAIL: UISTABLE1 contract missing"; exit 2; }

MOUNT_ARGS=()
while IFS='|' read -r SRC DST RW; do
  [[ -n "$SRC" ]] || continue
  if [[ "$RW" == "true" ]]; then MOUNT_ARGS+=( -v "$SRC:$DST" ); else MOUNT_ARGS+=( -v "$SRC:$DST:ro" ); fi
done < "$MOUNTFILE"

echo "===== 3. REPLACE APP CONTAINER ONLY ====="
dc stop "$APP" >/dev/null || true
dc rename "$APP" "$BACKUP"
dc create --name "$APP" --restart "$RESTART" --network "$NETWORK" -p 3200:8000 --env-file "$ENVFILE" "${MOUNT_ARGS[@]}" "$IMAGE" >/dev/null
dc start "$APP" >/dev/null

echo "===== 4. HEALTH ====="
for i in $(seq 1 48); do
  H="$(dc inspect "$APP" --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' 2>/dev/null || true)"
  echo "health=$H"
  [[ "$H" == "healthy" ]] && break
  sleep 5
done
[[ "$(dc inspect "$APP" --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}')" == "healthy" ]] || { dc logs --tail 200 "$APP"; exit 1; }

TOKEN="$(dc exec "$APP" sh -lc 'printf %s "${NOVA_UI_ACCESS_TOKEN:-}"' 2>/dev/null || true)"
AUTH=(); [[ -z "$TOKEN" ]] || AUTH=(-H "Authorization: Bearer $TOKEN")

check_supply(){
  FT="$(curl -fsS --max-time 8 "${AUTH[@]}" http://127.0.0.1:3200/api/feed-truth 2>/dev/null || true)"
  RH="$(curl -fsS --max-time 8 "${AUTH[@]}" http://127.0.0.1:3200/api/realtime-health 2>/dev/null || true)"
  FT="$FT" RH="$RH" python3 - <<'PY'
import json,os
try:f=json.loads(os.environ.get('FT') or '{}')
except Exception:f={}
try:r=json.loads(os.environ.get('RH') or '{}')
except Exception:r={}
sess=f.get('session') or {}
active=bool(sess.get('active'))
rest=f.get('rest') or {}; ws=f.get('ws') or {}; venues=f.get('venues') or {}; disc=r.get('discovery') or {}; cyc=disc.get('_cycle') or {}
sources=int(rest.get('discovery_sources_total') or 0); ok=int(rest.get('discovery_sources_ok') or 0); reg=int(ws.get('registered') or 0); seen=int(cyc.get('seen') or 0); hot=int(cyc.get('hot') or 0)
priced=sum(int((venues.get(v) or {}).get('priced_codes') or 0) for v in ('KRX','NXT'))
print(f'active={int(active)} sources={sources} ok={ok} seen={seen} hot={hot} registered={reg} priced={priced} status={f.get("status")}')
if not active: raise SystemExit(0)
if ok>=1 and seen>=20 and hot>=10 and reg>=10: raise SystemExit(0)
raise SystemExit(1)
PY
}

echo "===== 5. LIVE SUPPLY SELF-CHECK ====="
PASS=0
for phase in 1 2; do
  for i in $(seq 1 24); do
    if OUT="$(check_supply)"; then echo "$OUT"; PASS=1; break 2; else echo "$OUT"; sleep 5; fi
  done
  echo "===== SELF-HEAL RESTART ONCE ====="
  dc restart "$APP" >/dev/null
  sleep 15
done

if [[ "$PASS" != "1" ]]; then
  echo "===== LIVE SUPPLY NOT RECOVERED ====="
  curl -fsS --max-time 8 "${AUTH[@]}" http://127.0.0.1:3200/api/feed-truth || true
  echo
  dc logs --tail 250 "$APP" 2>&1 || true
  echo "RESULT=FAILED_LIVE_SUPPLY CURRENT=$APP BACKUP=$BACKUP"
  exit 1
fi

echo "===== 6. FINAL ====="
dc port "$APP"
echo "RESULT=SUCCESS CURRENT=$APP BACKUP=$BACKUP VERSION=$EXPECTED_VERSION"
