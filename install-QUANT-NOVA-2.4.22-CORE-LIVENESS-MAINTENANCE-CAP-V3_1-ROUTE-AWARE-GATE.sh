#!/usr/bin/env bash
set -Eeuo pipefail
REV="QUANT-NOVA-2.4.22-CORE-LIVENESS-MAINTENANCE-CAP-V3.1-ROUTE-AWARE-GATE"
APP="quant-nova"
BASE="$HOME/quant-nova"
BK="$BASE/core-liveness-v3-backups"
STAMP="$(date +%Y%m%d%H%M%S)"
WORK="/tmp/nova-core-v3-$STAMP"
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
echo "EVIDENCE=DDMIN_MINIMAL_FAILING_SET_5_TASKS"
echo "POLICY=MAX_4_OF_5_MAINTENANCE_TASKS_ACTIVE"
echo "SELECTION_LOGIC_CHANGE=NONE"
echo "BUY_THRESHOLDS_CHANGE=NONE"
echo "SCORING_FORMULA_CHANGE=NONE"
echo "CANDIDATE_SELECTION_CHANGE=NONE"
echo "WS_CONTRACT_CHANGE=NONE"

sudo docker inspect "$APP" >/dev/null
sudo docker cp "$APP:/app/app/main.py" "$OLD_MAIN"
sudo cp "$OLD_MAIN" "$NEW_MAIN"
sudo chown "$(id -u):$(id -g)" "$NEW_MAIN"
chmod 600 "$NEW_MAIN"
OLD_SHA="$(sudo sha256sum "$OLD_MAIN" | awk '{print $1}')"
echo "ORIGINAL_MAIN_SHA256=$OLD_SHA"

cat > "$PATCHER" <<'PY'
from __future__ import annotations
from pathlib import Path
import ast, hashlib, sys

p=Path(sys.argv[1])
s=p.read_text(encoding="utf-8")
tree=ast.parse(s)
lines=s.splitlines(True)

TARGETS=[
    "nova-replay-journal",
    "nova-prospective-followup",
    "nova-market-top1-audit",
    "nova-evidence",
    "nova-eod-screen-snapshot",
]
PROTECTED=["calc","score_codes","ranked","update_sector_context","evaluate_nxt_radar_alerts"]

def fn_text(src,tree,name):
    ls=src.splitlines()
    for n in ast.walk(tree):
        if isinstance(n,(ast.FunctionDef,ast.AsyncFunctionDef)) and n.name==name:
            return "\n".join(ls[n.lineno-1:n.end_lineno])
    raise SystemExit("PROTECTED_FUNCTION_NOT_FOUND:"+name)

before_hash={n:hashlib.sha256(fn_text(s,tree,n).encode()).hexdigest() for n in PROTECTED}

factory_var=None
factory_node=None
mapping=None
for node in ast.walk(tree):
    if not isinstance(node,(ast.Assign,ast.AnnAssign)) or not isinstance(node.value,ast.Dict):
        continue
    m={}
    for k,v in zip(node.value.keys,node.value.values):
        if isinstance(k,ast.Constant) and isinstance(k.value,str):
            m[k.value]=ast.get_source_segment(s,v)
    if all(t in m for t in TARGETS):
        if isinstance(node,ast.Assign) and len(node.targets)==1 and isinstance(node.targets[0],ast.Name):
            factory_var=node.targets[0].id
        elif isinstance(node,ast.AnnAssign) and isinstance(node.target,ast.Name):
            factory_var=node.target.id
        else:
            continue
        factory_node=node
        mapping=m
        break
if not factory_var:
    raise SystemExit("RUNTIME_FACTORY_WITH_5_TARGETS_NOT_FOUND")

print("RUNTIME_FACTORY_VAR="+factory_var)
for t in TARGETS:
    print("TARGET_MAP",t,"=>",mapping[t])

supervisor = r'''
_NOVA_MAINT_ORIGINALS = {}
_NOVA_MAINT_RUNNING = {}

async def maintenance_liveness_supervisor_loop():
    # DDMIN proved all five together fail while every tested four-of-five set survives.
    target_names = (
        'nova-replay-journal',
        'nova-prospective-followup',
        'nova-market-top1-audit',
        'nova-evidence',
        'nova-eod-screen-snapshot',
    )

    async def _stop(name):
        task=_NOVA_MAINT_RUNNING.pop(name,None)
        if task is None:
            return
        task.cancel()
        try:
            await task
        except asyncio.CancelledError:
            pass
        except Exception as e:
            STATE.rest_status.setdefault('_maintenance_cap_v3',{})['stop_error_'+name]=str(e)[:160]

    async def _start(name):
        if name in _NOVA_MAINT_RUNNING:
            return
        fn=_NOVA_MAINT_ORIGINALS.get(name)
        if fn is None:
            raise RuntimeError('MAINT_FUNCTION_MISSING:'+name)
        _NOVA_MAINT_RUNNING[name]=asyncio.create_task(fn(),name=name+'-capped-v3')

    while True:
        try:
            now=now_kst()
            mins=now.hour*60+now.minute
            eod_window=(19*60+50) <= mins <= (20*60+10)

            if eod_window:
                desired={
                    'nova-prospective-followup',
                    'nova-market-top1-audit',
                    'nova-evidence',
                    'nova-eod-screen-snapshot',
                }
                mode='EOD_SWAP_REPLAY_FOR_SNAPSHOT'
            else:
                desired={
                    'nova-replay-journal',
                    'nova-prospective-followup',
                    'nova-market-top1-audit',
                    'nova-evidence',
                }
                mode='DAYTIME_4_OF_5_EOD_PAUSED'

            for name in list(_NOVA_MAINT_RUNNING):
                if name not in desired:
                    await _stop(name)
                    await asyncio.sleep(0)

            for name in target_names:
                if name in desired and name not in _NOVA_MAINT_RUNNING:
                    await _start(name)
                    await asyncio.sleep(0.35)

            st=STATE.rest_status.setdefault('_maintenance_cap_v3',{})
            st.update({
                'policy':'DDMIN_MAX_4_OF_5',
                'mode':mode,
                'active':sorted(_NOVA_MAINT_RUNNING),
                'active_count':len(_NOVA_MAINT_RUNNING),
                'paused':sorted(set(target_names)-set(_NOVA_MAINT_RUNNING)),
                'updated_at':time.time(),
            })
            if len(_NOVA_MAINT_RUNNING)>4:
                raise RuntimeError('MAINTENANCE_CAP_BREACH')
            await asyncio.sleep(5.0)
        except asyncio.CancelledError:
            for name in list(_NOVA_MAINT_RUNNING):
                await _stop(name)
            raise
        except Exception as e:
            STATE.rest_status.setdefault('_maintenance_cap_v3',{})['last_error']=str(e)[:160]
            await asyncio.sleep(1.0)
'''

insert_before=factory_node.lineno-1
s="".join(lines[:insert_before])+supervisor+"".join(lines[insert_before:])

tree2=ast.parse(s)
factory_node2=None
for node in ast.walk(tree2):
    if not isinstance(node,(ast.Assign,ast.AnnAssign)) or not isinstance(node.value,ast.Dict):
        continue
    keys=[k.value for k in node.value.keys if isinstance(k,ast.Constant) and isinstance(k.value,str)]
    if all(t in keys for t in TARGETS):
        if isinstance(node,ast.Assign) and len(node.targets)==1 and isinstance(node.targets[0],ast.Name) and node.targets[0].id==factory_var:
            factory_node2=node; break
        if isinstance(node,ast.AnnAssign) and isinstance(node.target,ast.Name) and node.target.id==factory_var:
            factory_node2=node; break
if not factory_node2:
    raise SystemExit("RUNTIME_FACTORY_LOST_AFTER_SUPERVISOR_INSERT")

lines2=s.splitlines(True)
after_line=factory_node2.end_lineno
post = (
    "\n# CORE LIVENESS V3 maintenance cap wiring\n"
    f"_NOVA_MAINT_ORIGINALS = {{k:{factory_var}[k] for k in {TARGETS!r}}}\n"
    f"{factory_var} = {{k:v for k,v in {factory_var}.items() if k not in {TARGETS!r}}}\n"
    f"{factory_var}['nova-maintenance-cap-v3'] = maintenance_liveness_supervisor_loop\n"
)
s="".join(lines2[:after_line])+post+"".join(lines2[after_line:])

tree3=ast.parse(s)
for name,h in before_hash.items():
    if hashlib.sha256(fn_text(s,tree3,name).encode()).hexdigest()!=h:
        raise SystemExit("PROTECTED_FUNCTION_CHANGED:"+name)

for marker in ("DDMIN_MAX_4_OF_5","nova-maintenance-cap-v3","EOD_SWAP_REPLAY_FOR_SNAPSHOT","DAYTIME_4_OF_5_EOD_PAUSED"):
    if marker not in s:
        raise SystemExit("PATCH_MARKER_MISSING:"+marker)

p.write_text(s,encoding="utf-8")
compile(s,str(p),"exec")
print("PATCH=PASS")
print("PROTECTED_TRADING_FUNCTION_HASH_GATE=PASS")
print("TARGET_TASK_BODIES=UNCHANGED")
print("MAINTENANCE_POLICY=MAX_4_OF_5")
PY

echo "=== APPLY SOURCE PATCH ==="
python3 "$PATCHER" "$NEW_MAIN"
python3 -m py_compile "$NEW_MAIN"
echo "PYTHON_COMPILE=PASS"

echo "=== INSTALL PATCHED MAIN.PY ==="
sudo docker cp "$NEW_MAIN" "$APP:/app/app/main.py"
sudo docker restart "$APP" >/dev/null
sleep 12

echo "=== BOOT FATAL CHECK ==="
LOG="$(sudo docker logs --since 2m --tail 250 "$APP" 2>&1 || true)"
echo "$LOG" | tail -120
if echo "$LOG" | grep -E 'SyntaxError|IndentationError|ImportError|NameError:.*maintenance_liveness' >/dev/null; then
  echo "BOOT_FATAL_GATE=FAIL" >&2
  exit 1
fi
echo "BOOT_FATAL_GATE=PASS"

echo "=== CORE HEALTH SOAK 90s ==="
PASS=0; FAIL=0; CONSEC=0; MAX_CONSEC=0
for i in $(seq 1 45); do
  OUT="$(curl -sS --max-time 2 -o /tmp/v3-health.json -w '%{http_code} %{time_total}' http://127.0.0.1:3200/api/health || true)"
  if [[ "$OUT" == 200* ]]; then PASS=$((PASS+1)); CONSEC=0
  else FAIL=$((FAIL+1)); CONSEC=$((CONSEC+1)); (( CONSEC > MAX_CONSEC )) && MAX_CONSEC=$CONSEC
  fi
  echo "V3_SOAK $i result=$OUT pass=$PASS fail=$FAIL consec=$CONSEC"
  sleep 2
done
echo "V3_CORE_PASS=$PASS/45"
echo "V3_MAX_CONSEC_FAIL=$MAX_CONSEC"
[[ "$PASS" -ge 42 && "$MAX_CONSEC" -lt 3 ]] || { echo "V3_CORE_LIVENESS_GATE=FAIL" >&2; exit 1; }
echo "V3_CORE_LIVENESS_GATE=PASS"

echo "=== ROUTE-AWARE CONCURRENCY TEST 20x ==="
# Current 2.4.22 builds do not universally expose /api/ws-diagnostics.
# Discover a real third read endpoint before using it as a liveness gate.
THIRD_ENDPOINT=""
for ep in /api/ws-diagnostics /api/screen-state /api/nxt-signal-table /api/nxt-alerts; do
  CODE="$(curl -sS --max-time 2 -o /dev/null -w '%{http_code}' "http://127.0.0.1:3200${ep}" || true)"
  echo "ROUTE_PROBE endpoint=${ep} code=${CODE}"
  if [[ "$CODE" == "200" ]]; then
    THIRD_ENDPOINT="$ep"
    break
  fi
done

[[ -n "$THIRD_ENDPOINT" ]] || {
  echo "ROUTE_DISCOVERY_GATE=FAIL no_existing_third_read_endpoint" >&2
  exit 1
}
echo "ROUTE_DISCOVERY_GATE=PASS third_endpoint=$THIRD_ENDPOINT"

CPASS=0
for i in $(seq 1 20); do
  rm -f /tmp/v3a /tmp/v3b /tmp/v3c
  curl -sS --max-time 2 -o /dev/null -w '%{http_code}' http://127.0.0.1:3200/api/health > /tmp/v3a & A=$!
  curl -sS --max-time 2 -o /dev/null -w '%{http_code}' http://127.0.0.1:3200/api/nova > /tmp/v3b & B=$!
  curl -sS --max-time 2 -o /dev/null -w '%{http_code}' "http://127.0.0.1:3200${THIRD_ENDPOINT}" > /tmp/v3c & C=$!
  wait "$A" || true; wait "$B" || true; wait "$C" || true
  RA="$(cat /tmp/v3a 2>/dev/null || true)"
  RB="$(cat /tmp/v3b 2>/dev/null || true)"
  RC="$(cat /tmp/v3c 2>/dev/null || true)"
  echo "V3_CONCURRENCY $i health=$RA nova=$RB third=$RC endpoint=$THIRD_ENDPOINT"
  [[ "$RA" == 200 && "$RB" == 200 && "$RC" == 200 ]] && CPASS=$((CPASS+1))
  sleep 1
done
echo "V3_CONCURRENCY_PASS=$CPASS/20"
[[ "$CPASS" -ge 18 ]] || { echo "V3_CONCURRENCY_GATE=FAIL" >&2; exit 1; }
echo "V3_CONCURRENCY_GATE=PASS"

echo "=== PUBLIC PATH CHECK (NON-FATAL TO CORE) ==="
PROOT="$(curl -k -sS --max-time 2 -o /dev/null -w '%{http_code} %{time_total}' https://3-38-25-20.nip.io/ || true)"
PSTATIC="$(curl -k -sS --max-time 2 -o /dev/null -w '%{http_code} %{time_total}' https://3-38-25-20.nip.io/static/nova.js || true)"
echo "PUBLIC_ROOT_INITIAL=$PROOT"
echo "PUBLIC_STATIC_INITIAL=$PSTATIC"
if [[ "$PROOT" != 200* || "$PSTATIC" != 200* ]]; then
  echo "PUBLIC_PATH_RECOVERY=CADDY_RESTART"
  sudo docker restart kiwoom-caddy >/dev/null 2>&1 || true
  sleep 3
  PROOT="$(curl -k -sS --max-time 3 -o /dev/null -w '%{http_code} %{time_total}' https://3-38-25-20.nip.io/ || true)"
  PSTATIC="$(curl -k -sS --max-time 3 -o /dev/null -w '%{http_code} %{time_total}' https://3-38-25-20.nip.io/static/nova.js || true)"
  echo "PUBLIC_ROOT_AFTER_RECOVERY=$PROOT"
  echo "PUBLIC_STATIC_AFTER_RECOVERY=$PSTATIC"
fi

echo "=== PERSIST SNAPSHOT ==="
IMAGE="quant-nova:2.4.22-core-liveness-maint-cap-v3-${STAMP}"
sudo docker commit "$APP" "$IMAGE" >/dev/null
echo "SNAPSHOT_IMAGE=$IMAGE"

echo "=== FINAL CONTRACT ==="
echo "DDMIN_EVIDENCE=5_TASK_INTERACTION"
echo "MAX_MAINTENANCE_CONCURRENCY=4"
echo "TARGET_TASK_BODIES=UNCHANGED"
echo "SELECTION_LOGIC=UNCHANGED"
echo "BUY_THRESHOLDS=UNCHANGED"
echo "SCORING_FORMULA=UNCHANGED"
echo "CANDIDATE_SELECTION=UNCHANGED"
echo "WS_CONTRACT=UNCHANGED"
echo "V3_CORE_PASS=$PASS/45"
echo "V3_CONCURRENCY_PASS=$CPASS/20"
echo "CONCURRENCY_GATE=ROUTE_AWARE_EXISTING_READ_ENDPOINT"
echo "=== $REV PASS ==="
SUCCESS=1
