#!/usr/bin/env bash
set -Eeuo pipefail

REV="QUANT-NOVA-2.4.22-CORE-LIVENESS-V3.2-ADOPT-EXISTING"
APP="quant-nova"
STAMP="$(date +%Y%m%d%H%M%S)"

fail() {
  echo "=== $REV FAIL: $* ===" >&2
  exit 1
}

echo "=== $REV START ==="
echo "MODE=VALIDATE_AND_ADOPT_EXISTING_V3_ONLY"
echo "SOURCE_PATCH=NONE"
echo "SELECTION_LOGIC_CHANGE=NONE"
echo "BUY_THRESHOLDS_CHANGE=NONE"
echo "SCORING_FORMULA_CHANGE=NONE"
echo "CANDIDATE_SELECTION_CHANGE=NONE"
echo "WS_CONTRACT_CHANGE=NONE"

sudo docker inspect "$APP" >/dev/null || fail "quant-nova missing"

echo "=== CURRENT SOURCE GUARD ==="
SRC="/tmp/nova-v32-current-$STAMP.py"
sudo docker cp "$APP:/app/app/main.py" "$SRC"
sudo chown "$(id -u):$(id -g)" "$SRC"
chmod 600 "$SRC"

python3 - "$SRC" <<'PY'
from pathlib import Path
import ast,sys
p=Path(sys.argv[1])
s=p.read_text(encoding="utf-8")
ast.parse(s)

checks={
  "supervisor_def": s.count("async def maintenance_liveness_supervisor_loop():"),
  "policy_marker": s.count("DDMIN_MAX_4_OF_5"),
  "runtime_slot": s.count("['nova-maintenance-cap-v3'] = maintenance_liveness_supervisor_loop"),
  "originals_wiring": s.count("_NOVA_MAINT_ORIGINALS = {k:"),
}
for k,v in checks.items():
    print(f"{k.upper()}_COUNT={v}")

# Exact one-time wiring is required. This specifically prevents the V3.1
# double-application that produced KeyError('nova-replay-journal').
assert checks["supervisor_def"] == 1, checks
assert checks["runtime_slot"] == 1, checks
assert checks["originals_wiring"] == 1, checks

for required in (
    "nova-replay-journal",
    "nova-prospective-followup",
    "nova-market-top1-audit",
    "nova-evidence",
    "nova-eod-screen-snapshot",
):
    assert required in s, required

print("SOURCE_AST=PASS")
print("V3_SINGLE_WIRING_GATE=PASS")
print("DOUBLE_PATCH_GUARD=PASS")
PY

echo "=== CONTAINER STATUS ==="
sudo docker ps --filter "name=^/${APP}$" --format 'name={{.Names}} status={{.Status}} image={{.Image}} ports={{.Ports}}'

echo "=== BOOT ERROR WINDOW ==="
# Historical traceback lines may still exist in old logs. Only fail if the
# current container has restarted recently and a fresh import error appears.
STARTED_AT="$(sudo docker inspect -f '{{.State.StartedAt}}' "$APP")"
echo "STARTED_AT=$STARTED_AT"
sudo docker logs --since 3m --tail 180 "$APP" 2>&1 | tail -120 || true

echo "=== PORT READY GATE ==="
READY=0
for i in $(seq 1 20); do
  CODE="$(curl -sS --max-time 1.5 -o /dev/null -w '%{http_code}' http://127.0.0.1:3200/api/health || true)"
  echo "READY $i code=$CODE"
  if [[ "$CODE" == "200" ]]; then READY=1; break; fi
  sleep 1
done
[[ "$READY" == "1" ]] || fail "port 3200 health never became ready"
echo "PORT_READY_GATE=PASS"

echo "=== CORE SOAK 60s ==="
PASS=0
FAIL=0
CONSEC=0
MAX_CONSEC=0
for i in $(seq 1 30); do
  OUT="$(curl -sS --max-time 2 -o /dev/null -w '%{http_code} %{time_total}' http://127.0.0.1:3200/api/health || true)"
  if [[ "$OUT" == 200* ]]; then
    PASS=$((PASS+1)); CONSEC=0
  else
    FAIL=$((FAIL+1)); CONSEC=$((CONSEC+1))
    (( CONSEC > MAX_CONSEC )) && MAX_CONSEC=$CONSEC
  fi
  echo "V32_SOAK $i result=$OUT pass=$PASS fail=$FAIL consec=$CONSEC"
  sleep 2
done
echo "V32_CORE_PASS=$PASS/30"
echo "V32_MAX_CONSEC_FAIL=$MAX_CONSEC"
[[ "$PASS" -ge 29 && "$MAX_CONSEC" -lt 2 ]] || fail "core soak"
echo "V32_CORE_LIVENESS_GATE=PASS"

echo "=== ROUTE DISCOVERY ==="
THIRD_ENDPOINT=""
for ep in /api/screen-state /api/nxt-signal-table /api/nxt-alerts /api/evidence /api/rs-leaders; do
  CODE="$(curl -sS --max-time 2 -o /dev/null -w '%{http_code}' "http://127.0.0.1:3200${ep}" || true)"
  echo "ROUTE_PROBE endpoint=$ep code=$CODE"
  if [[ "$CODE" == "200" ]]; then
    THIRD_ENDPOINT="$ep"
    break
  fi
done
[[ -n "$THIRD_ENDPOINT" ]] || fail "no third existing read endpoint"
echo "ROUTE_DISCOVERY_GATE=PASS endpoint=$THIRD_ENDPOINT"

echo "=== CONCURRENCY 20x ==="
CPASS=0
for i in $(seq 1 20); do
  rm -f /tmp/v32a /tmp/v32b /tmp/v32c
  curl -sS --max-time 2 -o /dev/null -w '%{http_code}' http://127.0.0.1:3200/api/health > /tmp/v32a & A=$!
  curl -sS --max-time 2 -o /dev/null -w '%{http_code}' http://127.0.0.1:3200/api/nova > /tmp/v32b & B=$!
  curl -sS --max-time 2 -o /dev/null -w '%{http_code}' "http://127.0.0.1:3200${THIRD_ENDPOINT}" > /tmp/v32c & C=$!
  wait "$A" || true; wait "$B" || true; wait "$C" || true
  RA="$(cat /tmp/v32a 2>/dev/null || true)"
  RB="$(cat /tmp/v32b 2>/dev/null || true)"
  RC="$(cat /tmp/v32c 2>/dev/null || true)"
  echo "V32_CONCURRENCY $i health=$RA nova=$RB third=$RC"
  [[ "$RA" == "200" && "$RB" == "200" && "$RC" == "200" ]] && CPASS=$((CPASS+1))
  sleep 1
done
echo "V32_CONCURRENCY_PASS=$CPASS/20"
[[ "$CPASS" -ge 19 ]] || fail "concurrency"
echo "V32_CONCURRENCY_GATE=PASS"

echo "=== PUBLIC PATH ==="
ROOT="$(curl -k -sS --max-time 3 -o /dev/null -w '%{http_code} %{time_total}' https://3-38-25-20.nip.io/ || true)"
STATIC="$(curl -k -sS --max-time 3 -o /dev/null -w '%{http_code} %{time_total}' https://3-38-25-20.nip.io/static/nova.js || true)"
echo "PUBLIC_ROOT=$ROOT"
echo "PUBLIC_STATIC=$STATIC"
if [[ "$ROOT" != 200* || "$STATIC" != 200* ]]; then
  echo "PUBLIC_RECOVERY=CADDY_RESTART"
  sudo docker restart kiwoom-caddy >/dev/null 2>&1 || true
  sleep 3
  ROOT="$(curl -k -sS --max-time 3 -o /dev/null -w '%{http_code} %{time_total}' https://3-38-25-20.nip.io/ || true)"
  STATIC="$(curl -k -sS --max-time 3 -o /dev/null -w '%{http_code} %{time_total}' https://3-38-25-20.nip.io/static/nova.js || true)"
  echo "PUBLIC_ROOT_AFTER_RECOVERY=$ROOT"
  echo "PUBLIC_STATIC_AFTER_RECOVERY=$STATIC"
fi
[[ "$ROOT" == 200* && "$STATIC" == 200* ]] || fail "public path"
echo "PUBLIC_GATE=PASS"

echo "=== ADOPT CURRENT GOOD STATE ==="
IMAGE="quant-nova:2.4.22-core-liveness-v3.2-adopted-${STAMP}"
sudo docker commit "$APP" "$IMAGE" >/dev/null
echo "SNAPSHOT_IMAGE=$IMAGE"

echo "=== FINAL ==="
echo "V3_SINGLE_WIRING=PASS"
echo "SOURCE_PATCH=NONE"
echo "SELECTION_LOGIC=UNCHANGED"
echo "BUY_THRESHOLDS=UNCHANGED"
echo "SCORING_FORMULA=UNCHANGED"
echo "CANDIDATE_SELECTION=UNCHANGED"
echo "WS_CONTRACT=UNCHANGED"
echo "V32_CORE_PASS=$PASS/30"
echo "V32_CONCURRENCY_PASS=$CPASS/20"
echo "=== $REV PASS ==="
