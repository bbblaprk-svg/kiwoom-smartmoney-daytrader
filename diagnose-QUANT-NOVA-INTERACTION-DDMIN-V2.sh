#!/usr/bin/env bash
set -Eeuo pipefail

REV="QUANT-NOVA-INTERACTION-DDMIN-DIAG-V2"
APP="quant-nova"
BASE="$HOME/quant-nova"
DIAG_DIR="$BASE/diagnostics"
STAMP="$(date +%Y%m%d%H%M%S)"
ORIG="$DIAG_DIR/main.py.ddmin-before-$STAMP"
CTRL="/tmp/nova-ddmin-$STAMP.py"
REPORT="$DIAG_DIR/runtime-interaction-ddmin-$STAMP.json"
SUCCESS=0

mkdir -p "$DIAG_DIR"
chmod 700 "$DIAG_DIR"

restore_exact() {
  if [[ -s "$ORIG" ]]; then
    sudo docker cp "$ORIG" "$APP:/app/app/main.py" >/dev/null 2>&1 || true
    sudo docker restart "$APP" >/dev/null 2>&1 || true
    sleep 7
  fi
}
trap '[[ $SUCCESS -eq 1 ]] || restore_exact' EXIT

echo "=== $REV START ==="
echo "MODE=DIAGNOSTIC_ONLY"
echo "SELECTION_LOGIC_CHANGE=NONE"
echo "BUY_THRESHOLDS_CHANGE=NONE"
echo "SCORING_FORMULA_CHANGE=NONE"
echo "CANDIDATE_SELECTION_CHANGE=NONE"
echo "WS_CONTRACT_CHANGE=NONE"

sudo docker cp "$APP:/app/app/main.py" "$ORIG"
sudo chown "$(id -u):$(id -g)" "$ORIG"
chmod 600 "$ORIG"

ORIG_SHA="$(sha256sum "$ORIG" | awk '{print $1}')"
echo "ORIGINAL_SHA256=$ORIG_SHA"

cat > "$CTRL" <<'PY'
from __future__ import annotations
import ast, hashlib, itertools, json, os, subprocess, sys, time, traceback
from pathlib import Path

APP="quant-nova"
ORIG=Path(sys.argv[1])
REPORT=Path(sys.argv[2])
WORK=REPORT.parent/(REPORT.stem+".work")
WORK.mkdir(parents=True,exist_ok=True)

GROUP=[
    "nova-replay-journal",
    "nova-prospective-followup",
    "nova-market-top1-audit",
    "nova-evidence",
    "nova-archive",
    "nova-eod-screen-snapshot",
]

STARTUP_WAIT=float(os.getenv("NOVA_DDMIN_STARTUP_WAIT","6"))
PROBES=int(os.getenv("NOVA_DDMIN_PROBES","3"))
TIMEOUT=float(os.getenv("NOVA_DDMIN_TIMEOUT","1.3"))
MAX_TRIALS=int(os.getenv("NOVA_DDMIN_MAX_TRIALS","20"))

src=ORIG.read_text(encoding="utf-8")
orig_sha=hashlib.sha256(src.encode()).hexdigest()
tree=ast.parse(src)
lines=src.splitlines(True)

def find_factory():
    for node in ast.walk(tree):
        if isinstance(node,(ast.Assign,ast.AnnAssign)) and isinstance(node.value,ast.Dict):
            keys=[k.value for k in node.value.keys if isinstance(k,ast.Constant) and isinstance(k.value,str)]
            if "nova-dirty-scoring" not in keys:
                continue
            if isinstance(node,ast.Assign) and len(node.targets)==1 and isinstance(node.targets[0],ast.Name):
                return node.targets[0].id,node,keys
            if isinstance(node,ast.AnnAssign) and isinstance(node.target,ast.Name):
                return node.target.id,node,keys
    raise SystemExit("RUNTIME_FACTORY_DICT_NOT_FOUND")

var,node,all_tasks=find_factory()
missing=[x for x in GROUP if x not in all_tasks]
if missing:
    raise SystemExit("INTERACTION_TASKS_MISSING:"+",".join(missing))
insert_after=node.end_lineno

def build(enabled:set[str],tag:str)->Path:
    out=WORK/f"main.{tag}.py"
    keep=sorted(enabled)
    injection=(
        f"\n# {tag}: diagnostic-only task filter\n"
        f"{var}={{k:v for k,v in {var}.items() if k in {keep!r}}}\n"
        f"STATE.rest_status.setdefault('_runtime_ddmin',{{}}).update("
        f"{{'tag':{tag!r},'enabled':{keep!r}}})\n"
    )
    new="".join(lines[:insert_after])+injection+"".join(lines[insert_after:])
    compile(new,str(out),"exec")
    out.write_text(new,encoding="utf-8")
    return out

def run(cmd,check=False):
    return subprocess.run(cmd,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,check=check)

trial=0
records=[]

def probe():
    passed=0; vals=[]
    for _ in range(PROBES):
        p=run(["curl","-sS","--max-time",str(TIMEOUT),"-o","/dev/null","-w","%{http_code} %{time_total}",
               "http://127.0.0.1:3200/api/health"])
        out=(p.stdout or "").strip()
        ok=out.startswith("200 ")
        passed+=int(ok); vals.append(out or "NO_OUTPUT")
        time.sleep(.6)
    return {"ok":passed>=2,"pass":passed,"probes":PROBES,"results":vals}

def trial_set(enabled:set[str],label:str):
    global trial
    trial+=1
    if trial>MAX_TRIALS:
        raise RuntimeError("MAX_TRIALS_REACHED")
    p=build(enabled,f"trial{trial:02d}-{label}")
    run(["sudo","docker","cp",str(p),f"{APP}:/app/app/main.py"],check=True)
    run(["sudo","docker","restart",APP],check=True)
    time.sleep(STARTUP_WAIT)
    r=probe()
    records.append({"trial":trial,"label":label,"enabled":sorted(enabled),"health":r})
    print(f"TRIAL {trial:02d} {label} enabled={len(enabled)} pass={r['pass']}/{r['probes']} ok={r['ok']}",flush=True)
    return r["ok"]

status="UNKNOWN"
minimal=[]
try:
    if not trial_set(set(),"CONTROL_ALL_DISABLED"):
        status="CONTROL_FAILED"
    elif trial_set(set(GROUP),"REPRO_FULL6"):
        status="FULL6_DID_NOT_REPRODUCE"
    else:
        current=list(GROUP)
        # Adaptive 1-at-a-time elimination. If removing one task still fails,
        # that task is not necessary and we reduce the failing set.
        while len(current)>1:
            reduced=False
            for drop in list(current):
                candidate=[x for x in current if x!=drop]
                healthy=trial_set(set(candidate),f"DROP_{drop}")
                if not healthy:
                    print("REDUCE_FAILING_SET: drop",drop,flush=True)
                    current=candidate
                    reduced=True
                    break
            if not reduced:
                break
        minimal=current
        if len(minimal)==1:
            status="SINGLE_CULPRIT_IDENTIFIED"
        elif len(minimal)==len(GROUP):
            status="ALL6_REQUIRED_OR_LOAD_THRESHOLD"
        else:
            status="MINIMAL_INTERACTION_SET_IDENTIFIED"
except Exception as e:
    status="DIAGNOSTIC_ABORTED"
    records.append({"error":repr(e),"traceback":traceback.format_exc()})
finally:
    # Exact source restoration; health is reported separately from restoration identity.
    run(["sudo","docker","cp",str(ORIG),f"{APP}:/app/app/main.py"])
    run(["sudo","docker","restart",APP])
    time.sleep(7)
    restored_bytes=run(["sudo","docker","exec",APP,"sha256sum","/app/app/main.py"]).stdout.strip().split()
    restored_sha=restored_bytes[0] if restored_bytes else ""
    restored_identity=(restored_sha==orig_sha)
    restored_health=probe()

report={
    "revision":"QUANT-NOVA-INTERACTION-DDMIN-DIAG-V2",
    "status":status,
    "original_sha256":orig_sha,
    "source_restored_exact":restored_identity,
    "restored_sha256":restored_sha,
    "restored_health":restored_health,
    "interaction_group":GROUP,
    "minimal_failing_set":minimal,
    "trial_count":trial,
    "records":records,
    "selection_logic_changed":False,
    "buy_thresholds_changed":False,
    "scoring_formula_changed":False,
    "candidate_selection_changed":False,
    "ws_contract_changed":False,
}
REPORT.write_text(json.dumps(report,ensure_ascii=False,indent=2),encoding="utf-8")

print("=== DDMIN RESULT ===",flush=True)
print("STATUS="+status,flush=True)
print("MINIMAL_FAILING_SET="+(",".join(minimal) if minimal else "NONE"),flush=True)
print("TRIAL_COUNT="+str(trial),flush=True)
print("SOURCE_RESTORED_EXACT="+str(restored_identity),flush=True)
print("RESTORED_HEALTH="+str(restored_health["ok"]),flush=True)
print("REPORT="+str(REPORT),flush=True)
PY

chmod 700 "$CTRL"
python3 -m py_compile "$CTRL"
echo "CONTROLLER_COMPILE=PASS"

python3 "$CTRL" "$ORIG" "$REPORT"

echo "=== VERIFY SOURCE IDENTITY FROM SHELL ==="
LIVE_SHA="$(sudo docker exec "$APP" sha256sum /app/app/main.py | awk '{print $1}')"
echo "LIVE_MAIN_SHA256=$LIVE_SHA"
echo "ORIGINAL_MAIN_SHA256=$ORIG_SHA"
[[ "$LIVE_SHA" == "$ORIG_SHA" ]]
echo "SOURCE_RESTORE_HASH_GATE=PASS"

echo "=== REPORT SUMMARY ==="
python3 - "$REPORT" <<'PY'
import json,sys
x=json.load(open(sys.argv[1]))
print("STATUS="+x["status"])
print("MINIMAL_FAILING_SET="+(",".join(x["minimal_failing_set"]) if x["minimal_failing_set"] else "NONE"))
print("SOURCE_RESTORED_EXACT="+str(x["source_restored_exact"]))
print("RESTORED_HEALTH="+str(x["restored_health"]["ok"]))
print("TRIAL_COUNT="+str(x["trial_count"]))
PY

echo "=== PUBLIC GUARD CHECK ==="
curl -k -sS --max-time 2 -o /dev/null -w 'PUBLIC_ROOT=%{http_code} %{time_total}\n' https://3-38-25-20.nip.io/ || true
curl -k -sS --max-time 2 -o /dev/null -w 'PUBLIC_STATIC=%{http_code} %{time_total}\n' https://3-38-25-20.nip.io/static/nova.js || true

echo "=== FINAL CONTRACT ==="
echo "SELECTION_LOGIC=UNCHANGED"
echo "BUY_THRESHOLDS=UNCHANGED"
echo "SCORING_FORMULA=UNCHANGED"
echo "CANDIDATE_SELECTION=UNCHANGED"
echo "WS_CONTRACT=UNCHANGED"
echo "REPORT_PATH=$REPORT"
echo "=== $REV COMPLETE ==="
SUCCESS=1
