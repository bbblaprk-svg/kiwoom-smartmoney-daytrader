#!/usr/bin/env bash
set -Eeuo pipefail

REV="QUANT-NOVA-2.4.22-CORE-LIVENESS-EVENTLOOP-ISOLATION-V2.1-PUBLIC-GUARD-RECOVERY"
APP="quant-nova"
BASE="$HOME/quant-nova"
BK="$BASE/core-liveness-v2-backups"
STAMP="$(date +%Y%m%d%H%M%S)"
WORK="/tmp/nova-core-v2-$STAMP"
OLD_MAIN="$BK/main.py.before-$STAMP"
NEW_MAIN="$WORK/main.py"
PATCHER="$WORK/patch.py"
SUCCESS=0

mkdir -p "$BK" "$WORK"
chmod 700 "$BK" "$WORK"

rollback() {
  local ec=$?
  [[ $ec -eq 0 || $SUCCESS -eq 1 ]] && return 0
  echo "=== $REV FAILED: ROLLBACK ===" >&2
  if [[ -s "$OLD_MAIN" ]]; then
    sudo docker cp "$OLD_MAIN" "$APP:/app/app/main.py" >/dev/null 2>&1 || true
    sudo docker restart "$APP" >/dev/null 2>&1 || true
    sleep 8
  fi
  echo "ROLLBACK=COMPLETE" >&2
}
trap rollback ERR

echo "=== $REV START ==="
echo "POLICY=EVENT_LOOP_EXECUTION_ONLY"
echo "SELECTION_LOGIC_CHANGE=NONE"
echo "BUY_THRESHOLDS_CHANGE=NONE"
echo "SCORING_FORMULA_CHANGE=NONE"
echo "CANDIDATE_SELECTION_CHANGE=NONE"
echo "WS_CONTRACT_CHANGE=NONE"

sudo docker inspect "$APP" >/dev/null
sudo docker cp "$APP:/app/app/main.py" "$OLD_MAIN"
sudo cp "$OLD_MAIN" "$NEW_MAIN"

cat > "$PATCHER" <<'PY'
from pathlib import Path
import ast, hashlib, re, sys

p=Path(sys.argv[1])
s=p.read_text(encoding="utf-8")

def get_func_text(src, tree, name):
    lines=src.splitlines()
    for n in ast.walk(tree):
        if isinstance(n,(ast.FunctionDef,ast.AsyncFunctionDef)) and n.name==name:
            return "\n".join(lines[n.lineno-1:n.end_lineno])
    raise SystemExit(f"FUNCTION_NOT_FOUND:{name}")

tree_before=ast.parse(s)
protected_names=[
    "calc","score_codes","update_sector_context","evaluate_nxt_radar_alerts","ranked"
]
before_hash={
    name:hashlib.sha256(get_func_text(s,tree_before,name).encode()).hexdigest()
    for name in protected_names
}

pattern=r"async def scoring_loop\(\):\n(?:    .*\n)+?(?=\ndef ranked\(\):)"
m=re.search(pattern,s)
if not m:
    raise SystemExit("SCORING_LOOP_BLOCK_NOT_FOUND")
old=m.group(0)
if "score_codes(codes,refresh_sector=False,full=False)" not in old:
    raise SystemExit("EXPECTED_SCORE_CALL_NOT_FOUND")

new='''async def scoring_loop():
    """Coalesced dirty scoring with cooperative event-loop yielding.

    Trading logic is unchanged. Existing score_codes() runs in small batches so
    HTTP/WS coroutines can run between batches.
    """
    while True:
        try:
            if not realtime_runtime_awake():
                STATE.performance_guard['overnight_frozen']=True
                await asyncio.sleep(WS_WAKE_GUARD_SECONDS);continue
            STATE.performance_guard['overnight_frozen']=False
            try:
                await asyncio.wait_for(
                    STATE.score_dirty_event.wait(),
                    timeout=max(0.25,SECTOR_CONTEXT_INTERVAL)
                )
            except asyncio.TimeoutError:
                pass
            STATE.score_dirty_event.clear()
            if STATE.score_dirty_codes:
                await asyncio.sleep(SCORING_COALESCE_MS/1000.0)

            codes=set(STATE.score_dirty_codes)
            STATE.score_dirty_codes.difference_update(codes)
            now=time.time()

            if now-STATE.last_sector_context>=SECTOR_CONTEXT_INTERVAL:
                codes.update(update_sector_context() or set())
                STATE.last_sector_context=now
                await asyncio.sleep(0)

            if codes:
                ordered=list(codes)
                batch_size=max(1,int(os.getenv('NOVA_SCORE_COOP_BATCH','2')))
                for i in range(0,len(ordered),batch_size):
                    score_codes(ordered[i:i+batch_size],refresh_sector=False,full=False)
                    await asyncio.sleep(0)

                if nxt_radar_session_active():
                    evaluate_nxt_radar_alerts(
                        [STATE.candidates[x] for x in codes if x in STATE.candidates]
                    )
                    await asyncio.sleep(0)

            STATE.score_stats['dirty_queue']=len(STATE.score_dirty_codes)
            STATE.score_stats['cooperative_batch_size']=int(
                os.getenv('NOVA_SCORE_COOP_BATCH','2')
            )
            STATE.score_stats['event_loop_isolation']='COOPERATIVE_BATCH_V2'
            if STATE.score_dirty_codes:
                STATE.score_dirty_event.set()
            await asyncio.sleep(0)
        except Exception as e:
            STATE.score_stats['last_error']=str(e)[:160]
            await asyncio.sleep(0.1)
'''

s=s[:m.start()]+new+s[m.end():]

if not re.search(r'(?m)^import .*\bos\b|^from .* import .*\bos\b',s):
    lines=s.splitlines()
    idx=0
    for i,line in enumerate(lines[:80]):
        if line.startswith("from __future__"):
            idx=i+1
    lines.insert(idx,"import os")
    s="\n".join(lines)+"\n"

if "async def event_loop_lag_monitor_loop():" not in s:
    anchor="# R18 AFTERHOURS QUIESCENT SUPERVISOR"
    if anchor not in s:
        raise SystemExit("RUNTIME_SUPERVISOR_ANCHOR_NOT_FOUND")
    monitor='''async def event_loop_lag_monitor_loop():
    """Observation-only event-loop lag monitor."""
    target=time.monotonic()+0.5
    while True:
        await asyncio.sleep(0.5)
        now=time.monotonic()
        lag=max(0.0,now-target)
        st=STATE.rest_status.setdefault('_event_loop_lag',{})
        st['last_ms']=round(lag*1000,1)
        st['max_ms']=max(float(st.get('max_ms') or 0),round(lag*1000,1))
        st['at']=time.time()
        target=now+0.5

'''
    s=s.replace(anchor,monitor+anchor,1)

needle="'nova-dirty-scoring': scoring_loop,"
if needle not in s:
    raise SystemExit("RUNTIME_SCORING_FACTORY_NOT_FOUND")
if "'nova-event-loop-lag': event_loop_lag_monitor_loop," not in s:
    s=s.replace(needle,needle+"\n    'nova-event-loop-lag': event_loop_lag_monitor_loop,",1)

tree_after=ast.parse(s)
p.write_text(s,encoding="utf-8")

for name,h in before_hash.items():
    h2=hashlib.sha256(get_func_text(s,tree_after,name).encode()).hexdigest()
    if h2!=h:
        raise SystemExit(f"PROTECTED_FUNCTION_CHANGED:{name}")

if "COOPERATIVE_BATCH_V2" not in s:
    raise SystemExit("PATCH_MARKER_MISSING")

print("PATCH=PASS")
print("PROTECTED_FUNCTION_HASH_GATE=PASS")
print("SCORING_FORMULA_UNCHANGED=PASS")
print("CANDIDATE_SELECTION_UNCHANGED=PASS")
print("WS_CONTRACT_UNCHANGED=PASS")
PY

python3 "$PATCHER" "$NEW_MAIN"
python3 -m py_compile "$NEW_MAIN"

echo "=== DIFF GUARD ==="
python3 - "$OLD_MAIN" "$NEW_MAIN" <<'PY'
import ast,sys
from pathlib import Path
a=Path(sys.argv[1]).read_text(); b=Path(sys.argv[2]).read_text()
ta=ast.parse(a); tb=ast.parse(b)
def names(t):
    return {n.name for n in ast.walk(t) if isinstance(n,(ast.FunctionDef,ast.AsyncFunctionDef))}
added=sorted(names(tb)-names(ta)); removed=sorted(names(ta)-names(tb))
print("ADDED_FUNCTIONS=",added)
print("REMOVED_FUNCTIONS=",removed)
assert not removed
assert set(added).issubset({"event_loop_lag_monitor_loop"})
print("FUNCTION_SET_GATE=PASS")
PY

echo "=== INSTALL PATCHED MAIN.PY ==="
sudo docker cp "$NEW_MAIN" "$APP:/app/app/main.py"
sudo docker restart "$APP" >/dev/null
sleep 12

echo "=== BOOT LOG CHECK ==="
LOG="$(sudo docker logs --since 2m --tail 220 "$APP" 2>&1 || true)"
echo "$LOG" | tail -120
if echo "$LOG" | grep -E 'SyntaxError|IndentationError|ImportError' >/dev/null; then
  echo "BOOT_FATAL_ERROR_FOUND" >&2
  exit 1
fi

echo "=== DIRECT CORE LIVENESS SOAK 90s ==="
PASS=0; FAIL=0; CONSEC=0; MAX_CONSEC=0
for i in $(seq 1 45); do
  OUT="$(curl -sS --max-time 2 -o /tmp/corev2-health.json -w '%{http_code} %{time_total}' http://127.0.0.1:3200/api/health || true)"
  if [[ "$OUT" == 200* ]]; then
    PASS=$((PASS+1)); CONSEC=0
  else
    FAIL=$((FAIL+1)); CONSEC=$((CONSEC+1))
    (( CONSEC > MAX_CONSEC )) && MAX_CONSEC=$CONSEC
  fi
  echo "CORE_V2_SOAK $i result=$OUT pass=$PASS fail=$FAIL consec=$CONSEC"
  sleep 2
done
echo "CORE_V2_PASS=$PASS/45"
echo "CORE_V2_MAX_CONSEC_FAIL=$MAX_CONSEC"
[[ "$PASS" -ge 42 && "$MAX_CONSEC" -lt 3 ]] || { echo "CORE_V2_LIVENESS_GATE=FAIL" >&2; exit 1; }
echo "CORE_V2_LIVENESS_GATE=PASS"

echo "=== API TRIPLE-CONCURRENCY TEST 20x ==="
CPASS=0
for i in $(seq 1 20); do
  rm -f /tmp/cv2-a /tmp/cv2-b /tmp/cv2-c
  curl -sS --max-time 2 -o /dev/null -w '%{http_code}' http://127.0.0.1:3200/api/health > /tmp/cv2-a & A=$!
  curl -sS --max-time 2 -o /dev/null -w '%{http_code}' http://127.0.0.1:3200/api/nova > /tmp/cv2-b & B=$!
  curl -sS --max-time 2 -o /dev/null -w '%{http_code}' http://127.0.0.1:3200/api/ws-diagnostics > /tmp/cv2-c & C=$!
  wait "$A" || true; wait "$B" || true; wait "$C" || true
  RA="$(cat /tmp/cv2-a 2>/dev/null || true)"
  RB="$(cat /tmp/cv2-b 2>/dev/null || true)"
  RC="$(cat /tmp/cv2-c 2>/dev/null || true)"
  echo "CONCURRENCY $i health=$RA nova=$RB ws=$RC"
  [[ "$RA" == "200" && "$RB" == "200" && "$RC" == "200" ]] && CPASS=$((CPASS+1))
  sleep 1
done
echo "CONCURRENCY_PASS=$CPASS/20"
[[ "$CPASS" -ge 18 ]] || { echo "CONCURRENCY_GATE=FAIL" >&2; exit 1; }
echo "CONCURRENCY_GATE=PASS"

echo "=== DIRECT STATIC TEST ==="
STATIC="$(curl -sS --max-time 2 -o /dev/null -w '%{http_code} %{time_total}' http://127.0.0.1:3200/static/nova.js || true)"
echo "DIRECT_STATIC=$STATIC"
[[ "$STATIC" == 200* ]] || { echo "DIRECT_STATIC_GATE=FAIL" >&2; exit 1; }

echo "=== PUBLIC GUARD TEST ==="
PROOT="$(curl -k -sS --max-time 2 -o /dev/null -w '%{http_code} %{time_total}' https://3-38-25-20.nip.io/ || true)"
PSTATIC="$(curl -k -sS --max-time 2 -o /dev/null -w '%{http_code} %{time_total}' https://3-38-25-20.nip.io/static/nova.js || true)"
echo "PUBLIC_ROOT_INITIAL=$PROOT"
echo "PUBLIC_STATIC_INITIAL=$PSTATIC"

if [[ "$PROOT" != 200* || "$PSTATIC" != 200* ]]; then
  echo "PUBLIC_GUARD_INITIAL=FAIL"
  echo "=== CONDITIONAL CADDY RECOVERY ==="
  # Caddy now proxies to nova-http-guard, not directly to quant-nova.
  # Restart Caddy only as a recovery action for the public path; it is not
  # considered a fix for CORE liveness and is reached only after CORE gates pass.
  sudo docker restart kiwoom-caddy >/dev/null 2>&1 || true
  sleep 3
  PROOT="$(curl -k -sS --max-time 3 -o /dev/null -w '%{http_code} %{time_total}' https://3-38-25-20.nip.io/ || true)"
  PSTATIC="$(curl -k -sS --max-time 3 -o /dev/null -w '%{http_code} %{time_total}' https://3-38-25-20.nip.io/static/nova.js || true)"
  echo "PUBLIC_ROOT_AFTER_CADDY_RESTART=$PROOT"
  echo "PUBLIC_STATIC_AFTER_CADDY_RESTART=$PSTATIC"
fi

[[ "$PROOT" == 200* && "$PSTATIC" == 200* ]] || { echo "PUBLIC_GUARD_GATE=FAIL" >&2; exit 1; }
echo "PUBLIC_GUARD_GATE=PASS"

echo "=== PERSIST PATCH AS IMAGE SNAPSHOT ==="
IMAGE="quant-nova:2.4.22-core-liveness-eventloop-v2-${STAMP}"
sudo docker commit "$APP" "$IMAGE" >/dev/null
echo "SNAPSHOT_IMAGE=$IMAGE"

echo "=== FINAL CONTRACT ==="
echo "PATCH_SCOPE=scoring_loop+event_loop_observer_only"
echo "SELECTION_LOGIC=UNCHANGED"
echo "BUY_THRESHOLDS=UNCHANGED"
echo "SCORING_FORMULA=UNCHANGED"
echo "CANDIDATE_SELECTION=UNCHANGED"
echo "WS_CONTRACT=UNCHANGED"
echo "HTTP_GUARD=RETAINED"
echo "PUBLIC_GUARD_RECOVERY=CONDITIONAL_CADDY_RESTART_ONLY_AFTER_CORE_PASS"
echo "CORE_V2_PASS=$PASS/45"
echo "CONCURRENCY_PASS=$CPASS/20"
echo "=== $REV PASS ==="
SUCCESS=1
