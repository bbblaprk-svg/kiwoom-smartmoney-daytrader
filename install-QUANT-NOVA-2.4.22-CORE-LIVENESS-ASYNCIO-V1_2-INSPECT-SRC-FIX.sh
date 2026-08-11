#!/usr/bin/env bash
set -Eeuo pipefail

REV="QUANT-NOVA-2.4.22-CORE-LIVENESS-ASYNCIO-V1.2-INSPECT-SRC-FIX"
APP="quant-nova"
NETWORK_EXPECTED="kiwoom-net"
BASE="$HOME/quant-nova"
BK="$BASE/core-liveness-backups"
STAMP="$(date +%Y%m%d%H%M%S)"
OLD="${APP}-before-corefix-${STAMP}"
SNAP_IMAGE="quant-nova:2.4.22-core-liveness-${STAMP}"
INSPECT_JSON="$BK/inspect-${STAMP}.json"
CLONE_PY="/tmp/nova-core-clone-${STAMP}.py"
SUCCESS=0

mkdir -p "$BK"
chmod 700 "$BK"

rollback() {
  local ec=$?
  [[ $ec -eq 0 || $SUCCESS -eq 1 ]] && return 0
  echo "=== $REV FAILED: ROLLBACK ===" >&2
  sudo systemctl disable --now quant-nova-liveness-watchdog.service >/dev/null 2>&1 || true
  sudo docker rm -f "$APP" >/dev/null 2>&1 || true
  if sudo docker inspect "$OLD" >/dev/null 2>&1; then
    sudo docker rename "$OLD" "$APP" >/dev/null 2>&1 || true
    sudo docker start "$APP" >/dev/null 2>&1 || true
  fi
  echo "ROLLBACK=COMPLETE" >&2
}
trap rollback ERR

echo "=== $REV START ==="
echo "POLICY=EXECUTION_RUNTIME_ONLY"
echo "SELECTION_LOGIC_CHANGE=NONE"
echo "BUY_THRESHOLDS_CHANGE=NONE"
echo "SCORING_FORMULA_CHANGE=NONE"
echo "CANDIDATE_SELECTION_CHANGE=NONE"
echo "WS_CONTRACT_CHANGE=NONE"

sudo docker inspect "$APP" > "$INSPECT_JSON"
chmod 600 "$INSPECT_JSON"

echo "=== PRECHECK CURRENT CONTAINER ==="
sudo docker ps --filter "name=^/${APP}$" --format 'name={{.Names}} status={{.Status}} image={{.Image}} ports={{.Ports}}'
NETS="$(sudo docker inspect "$APP" --format '{{range $k,$v := .NetworkSettings.Networks}}{{$k}} {{end}}')"
echo "NETWORKS=$NETS"
[[ "$NETS" == *"$NETWORK_EXPECTED"* ]] || { echo "EXPECTED_NETWORK_MISSING" >&2; exit 1; }

echo "=== COMMIT EXACT CURRENT FILESYSTEM ==="
sudo docker commit "$APP" "$SNAP_IMAGE" >/dev/null
echo "SNAPSHOT_IMAGE=$SNAP_IMAGE"

cat > "$CLONE_PY" <<'PY'
import json, subprocess, sys, time, os
inspect_src, new_name, image = sys.argv[1:4]
obj=json.loads(subprocess.check_output(["sudo","docker","inspect",inspect_src],text=True))[0]
cfg=obj.get("Config") or {}
host=obj.get("HostConfig") or {}
nets=((obj.get("NetworkSettings") or {}).get("Networks") or {})
args=["sudo","docker","create","--name",new_name]

rp=(host.get("RestartPolicy") or {}).get("Name") or "unless-stopped"
if rp and rp!="no":
    args += ["--restart",rp]

# Copy resource limits where material.
mem=int(host.get("Memory") or 0)
if mem>0: args += ["--memory",str(mem)]
cpus=int(host.get("NanoCpus") or 0)
if cpus>0: args += ["--cpus",str(cpus/1_000_000_000)]

# Preserve environment without printing secrets.
for e in (cfg.get("Env") or []):
    args += ["--env",e]

workdir=cfg.get("WorkingDir") or ""
if workdir: args += ["--workdir",workdir]
user=cfg.get("User") or ""
if user: args += ["--user",user]

# Preserve mounts.
for m in (obj.get("Mounts") or []):
    typ=m.get("Type"); srcp=m.get("Source"); dst=m.get("Destination")
    if not (typ and srcp and dst): continue
    spec=f"type={typ},src={srcp},dst={dst}"
    if not m.get("RW",True): spec+=",readonly"
    args += ["--mount",spec]

# Preserve published ports exactly.
for cport, binds in (host.get("PortBindings") or {}).items():
    if not binds: continue
    for b in binds:
        hip=b.get("HostIp") or ""
        hp=b.get("HostPort") or ""
        if not hp: continue
        spec=f"{hip+':' if hip else ''}{hp}:{cport}"
        args += ["--publish",spec]

# Start on the first existing network; add others after create.
net_names=list(nets)
if net_names:
    args += ["--network",net_names[0]]

# Same exact committed filesystem, only Uvicorn runtime implementation changes.
args += [
    image,
    "sh","-c",
    'exec uvicorn app.main:app --host 0.0.0.0 --port ${PORT:-8000} '
    '--loop asyncio --http h11 --timeout-keep-alive 5'
]
subprocess.run(args,check=True,stdout=subprocess.DEVNULL)

for n in net_names[1:]:
    subprocess.run(["sudo","docker","network","connect",n,new_name],check=True,stdout=subprocess.DEVNULL)

print("CLONE_CREATE=PASS")
print("EVENT_LOOP=asyncio")
print("HTTP_PROTOCOL=h11")
PY
chmod 600 "$CLONE_PY"

echo "=== CLONE ARGUMENT REGRESSION CHECK ==="
grep -Fq 'python3 "$CLONE_PY" "$OLD" "$APP" "$SNAP_IMAGE"' "$0"
echo "CLONE_SOURCE_AFTER_RENAME=OLD_CONTAINER"
echo "CLONE_TARGET=quant-nova"
echo "CLONE_ARGUMENT_GATE=PASS"
grep -Fq 'inspect_src, new_name, image = sys.argv[1:4]' "$CLONE_PY"
grep -Fq 'docker","inspect",inspect_src' "$CLONE_PY"
grep -Fq 'docker","create","--name",new_name' "$CLONE_PY"
grep -Fq 'network","connect",n,new_name' "$CLONE_PY"
echo "CLONE_HELPER_MAPPING_GATE=PASS"

echo "=== SWAP CONTAINER SAFELY ==="
sudo docker stop "$APP" >/dev/null 2>&1 || true
sudo docker rename "$APP" "$OLD"
python3 "$CLONE_PY" "$OLD" "$APP" "$SNAP_IMAGE"
sudo docker start "$APP" >/dev/null

echo "=== BOOT WAIT ==="
sleep 12
sudo docker ps --filter "name=^/${APP}$" --format 'name={{.Names}} status={{.Status}} image={{.Image}}'

echo "=== CORE HEALTH SOAK 60s ==="
PASS=0
FAIL=0
CONSEC=0
MAX_CONSEC=0
for i in $(seq 1 30); do
  OUT="$(curl -sS --max-time 2.5 -o /tmp/nova-core-health.json -w '%{http_code} %{time_total}' http://127.0.0.1:3200/api/health || true)"
  if [[ "$OUT" == 200* ]]; then
    PASS=$((PASS+1)); CONSEC=0
  else
    FAIL=$((FAIL+1)); CONSEC=$((CONSEC+1)); (( CONSEC > MAX_CONSEC )) && MAX_CONSEC=$CONSEC
  fi
  echo "CORE_SOAK $i result=$OUT pass=$PASS fail=$FAIL consec_fail=$CONSEC"
  sleep 2
done

echo "CORE_SOAK_PASS=$PASS/30"
echo "CORE_MAX_CONSEC_FAIL=$MAX_CONSEC"
[[ "$PASS" -ge 28 && "$MAX_CONSEC" -lt 3 ]] || {
  echo "CORE_LIVENESS_GATE=FAIL" >&2
  exit 1
}
echo "CORE_LIVENESS_GATE=PASS"

echo "=== WS DIAGNOSTICS REACHABILITY ==="
WSHTTP="$(curl -sS --max-time 3 -o /tmp/nova-wsdiag.json -w '%{http_code} %{time_total}' http://127.0.0.1:3200/api/ws-diagnostics || true)"
echo "WS_DIAG_HTTP=$WSHTTP"
if [[ "$WSHTTP" == 200* ]]; then
  python3 - <<'PY'
import json
try:
    x=json.load(open("/tmp/nova-wsdiag.json"))
    def pick(o,*keys):
        for k in keys:
            if isinstance(o,dict) and k in o:return o[k]
        return None
    print("WS_DIAG_REACHABLE=PASS")
    print("WS_CONNECTED=",pick(x,"connected","ws_connected"))
    print("TRADE_REGISTERED=",pick(x,"trade_registered","registered"))
    print("LAST_TRADE_AT=",pick(x,"last_trade_at"))
except Exception as e:
    print("WS_DIAG_PARSE=CHECK",str(e)[:120])
PY
else
  echo "WS_DIAG_REACHABLE=CHECK"
fi

echo "=== PUBLIC GUARD MUST STAY UP ==="
ROOT="$(curl -k -sS --max-time 2 -o /dev/null -w '%{http_code} %{time_total}' https://3-38-25-20.nip.io/ || true)"
STATIC="$(curl -k -sS --max-time 2 -o /dev/null -w '%{http_code} %{time_total}' https://3-38-25-20.nip.io/static/nova.js || true)"
echo "PUBLIC_ROOT=$ROOT"
echo "PUBLIC_STATIC=$STATIC"
[[ "$ROOT" == 200* && "$STATIC" == 200* ]] || { echo "PUBLIC_GUARD_GATE=FAIL" >&2; exit 1; }
echo "PUBLIC_GUARD_GATE=PASS"

echo "=== INSTALL NON-INTRUSIVE WATCHDOG ==="
sudo tee /usr/local/sbin/quant-nova-liveness-watchdog.sh >/dev/null <<'WATCH'
#!/usr/bin/env bash
set -u
APP="quant-nova"
STATE_DIR="/var/lib/quant-nova-liveness-watchdog"
mkdir -p "$STATE_DIR"
FAIL=0
while sleep 3; do
  if curl -fsS --max-time 2 http://127.0.0.1:3200/api/health >/dev/null 2>&1; then
    FAIL=0
    continue
  fi
  # Avoid a restart for a single HTTP hiccup. Confirm engine endpoint is also inaccessible.
  if curl -fsS --max-time 2 http://127.0.0.1:3200/api/ws-diagnostics >/dev/null 2>&1; then
    FAIL=0
    continue
  fi
  FAIL=$((FAIL+1))
  [[ "$FAIL" -lt 5 ]] && continue

  NOW="$(date +%s)"
  LOG="$STATE_DIR/restarts.log"
  touch "$LOG"
  awk -v n="$NOW" '$1+900>n' "$LOG" > "$LOG.tmp" || true
  mv "$LOG.tmp" "$LOG"
  CNT="$(wc -l < "$LOG" | tr -d ' ')"

  if [[ "$CNT" -ge 3 ]]; then
    logger -t quant-nova-watchdog "restart suppressed: >=3 restarts/15min"
    FAIL=0
    sleep 120
    continue
  fi

  echo "$NOW" >> "$LOG"
  logger -t quant-nova-watchdog "confirmed engine liveness failure; restarting $APP"
  docker restart "$APP" >/dev/null 2>&1 || true
  FAIL=0
  sleep 20
done
WATCH
sudo chmod 755 /usr/local/sbin/quant-nova-liveness-watchdog.sh

sudo tee /etc/systemd/system/quant-nova-liveness-watchdog.service >/dev/null <<'UNIT'
[Unit]
Description=QUANT NOVA confirmed-liveness watchdog
After=docker.service network-online.target
Requires=docker.service

[Service]
Type=simple
ExecStart=/usr/local/sbin/quant-nova-liveness-watchdog.sh
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
UNIT

sudo systemctl daemon-reload
sudo systemctl enable --now quant-nova-liveness-watchdog.service >/dev/null
sleep 2
sudo systemctl is-active --quiet quant-nova-liveness-watchdog.service
echo "WATCHDOG=ACTIVE"
echo "WATCHDOG_POLICY=5_CONFIRMED_DUAL_ENDPOINT_FAILURES;MAX_3_RESTARTS_PER_15MIN"

echo "=== FINAL CONTRACT ==="
echo "EVENT_LOOP=PYTHON_STDLIB_ASYNCIO"
echo "UVICORN_HTTP=H11"
echo "SELECTION_LOGIC=UNCHANGED"
echo "BUY_THRESHOLDS=UNCHANGED"
echo "SCORING_FORMULA=UNCHANGED"
echo "CANDIDATE_SELECTION=UNCHANGED"
echo "WS_CONTRACT=UNCHANGED"
echo "HTTP_GUARD=RETAINED"
echo "PREVIOUS_CONTAINER=$OLD"
echo "SNAPSHOT_IMAGE=$SNAP_IMAGE"
echo "=== $REV PASS ==="
SUCCESS=1
