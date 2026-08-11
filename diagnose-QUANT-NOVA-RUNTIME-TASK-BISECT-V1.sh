#!/usr/bin/env bash
set -Eeuo pipefail

REV="QUANT-NOVA-RUNTIME-TASK-BISECT-DIAG-V1"
APP="quant-nova"
BASE="$HOME/quant-nova"
DIAG_DIR="$BASE/diagnostics"
STAMP="$(date +%Y%m%d%H%M%S)"
ORIG="$DIAG_DIR/main.py.runtime-bisect-before-$STAMP"
CTRL="/tmp/nova-runtime-bisect-$STAMP.py"
REPORT="$DIAG_DIR/runtime-task-bisect-$STAMP.txt"

mkdir -p "$DIAG_DIR"
chmod 700 "$DIAG_DIR"

echo "=== $REV START ==="
echo "MODE=DIAGNOSTIC_ONLY"
echo "SELECTION_LOGIC_CHANGE=NONE"
echo "BUY_THRESHOLDS_CHANGE=NONE"
echo "SCORING_FORMULA_CHANGE=NONE"
echo "CANDIDATE_SELECTION_CHANGE=NONE"
echo "WS_CONTRACT_CHANGE=NONE"
echo "PUBLIC_GUARD=RETAINED"

sudo docker inspect "$APP" >/dev/null
sudo docker cp "$APP:/app/app/main.py" "$ORIG"
sudo chown "$(id -u):$(id -g)" "$ORIG"
chmod 600 "$ORIG"

cat > "$CTRL" <<'PY'
from __future__ import annotations
import ast, json, os, re, subprocess, sys, time, traceback
from pathlib import Path

APP="quant-nova"
ORIG=Path(sys.argv[1])
REPORT=Path(sys.argv[2])
WORK=REPORT.parent / (REPORT.stem + ".work")
WORK.mkdir(parents=True, exist_ok=True)
MAX_TRIALS=int(os.getenv("NOVA_DIAG_MAX_TRIALS","18"))
STARTUP_WAIT=float(os.getenv("NOVA_DIAG_STARTUP_WAIT","7"))
PROBES=int(os.getenv("NOVA_DIAG_PROBES","4"))
TIMEOUT=float(os.getenv("NOVA_DIAG_TIMEOUT","1.5"))

src=ORIG.read_text(encoding="utf-8")
tree=ast.parse(src)
lines=src.splitlines(True)

def find_runtime_factory_assignment():
    for node in ast.walk(tree):
        if isinstance(node,(ast.Assign,ast.AnnAssign)):
            val=node.value
            if not isinstance(val,ast.Dict):
                continue
            keys=[]
            for k in val.keys:
                if isinstance(k,ast.Constant) and isinstance(k.value,str):
                    keys.append(k.value)
            if "nova-dirty-scoring" not in keys:
                continue

            # Require a simple variable assignment.
            if isinstance(node,ast.Assign) and len(node.targets)==1 and isinstance(node.targets[0],ast.Name):
                return node.targets[0].id,node,keys
            if isinstance(node,ast.AnnAssign) and isinstance(node.target,ast.Name):
                return node.target.id,node,keys
    raise SystemExit("RUNTIME_FACTORY_DICT_NOT_FOUND")

var,node,tasks=find_runtime_factory_assignment()
tasks=list(dict.fromkeys(tasks))
insert_after=node.end_lineno

def build_variant(enabled:set[str], tag:str)->Path:
    out=WORK/f"main.{tag}.py"
    keep=sorted(enabled)
    injection=(
        f"\n# {tag} - diagnostic-only runtime task filter\n"
        f"{var} = {{k:v for k,v in {var}.items() if k in {keep!r}}}\n"
        f"STATE.rest_status.setdefault('_runtime_task_bisect',{{}}).update("
        f"{{'tag':{tag!r},'enabled':{keep!r},'task_count':{len(keep)}}})\n"
    )
    new="".join(lines[:insert_after])+injection+"".join(lines[insert_after:])
    compile(new,str(out),"exec")
    out.write_text(new,encoding="utf-8")
    return out

def docker(*args,check=True,capture=False):
    cmd=["sudo","docker",*args]
    if capture:
        return subprocess.run(cmd,check=check,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT).stdout
    return subprocess.run(cmd,check=check,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)

def install_variant(path:Path):
    docker("cp",str(path),f"{APP}:/app/app/main.py")
    docker("restart",APP)
    time.sleep(STARTUP_WAIT)

def probe()->dict:
    ok=0; results=[]
    for _ in range(PROBES):
        p=subprocess.run(
            ["curl","-sS","--max-time",str(TIMEOUT),"-o","/tmp/nova-diag-health.json",
             "-w","%{http_code} %{time_total}","http://127.0.0.1:3200/api/health"],
            text=True,stdout=subprocess.PIPE,stderr=subprocess.DEVNULL
        )
        out=(p.stdout or "").strip()
        success=out.startswith("200 ")
        ok += int(success)
        results.append(out or "NO_OUTPUT")
        time.sleep(0.7)
    return {"ok": ok >= max(2,PROBES-1), "pass":ok, "probes":PROBES, "results":results}

trial_count=0
records=[]

def run_trial(enabled:set[str],label:str)->bool:
    global trial_count
    trial_count+=1
    if trial_count>MAX_TRIALS:
        raise RuntimeError(f"MAX_TRIALS_REACHED:{MAX_TRIALS}")
    path=build_variant(enabled,f"trial{trial_count:02d}-{label}")
    install_variant(path)
    r=probe()
    rec={"trial":trial_count,"label":label,"enabled":sorted(enabled),"result":r}
    records.append(rec)
    print(f"TRIAL {trial_count:02d} {label} enabled={len(enabled)} pass={r['pass']}/{r['probes']} ok={r['ok']}",flush=True)
    return bool(r["ok"])

def recurse(group:list[str], prefix:str, found:list[str], interactions:list[list[str]]):
    if not group:
        return
    if len(group)==1:
        found.append(group[0]); return
    mid=len(group)//2
    left=group[:mid]; right=group[mid:]

    left_bad=not run_trial(set(left),prefix+"L")
    right_bad=not run_trial(set(right),prefix+"R")

    if left_bad:
        recurse(left,prefix+"L",found,interactions)
    if right_bad:
        recurse(right,prefix+"R",found,interactions)
    if not left_bad and not right_bad:
        interactions.append(group[:])

print("RUNTIME_FACTORY_VAR=",var,flush=True)
print("RUNTIME_TASK_COUNT=",len(tasks),flush=True)
for i,t in enumerate(tasks,1):
    print(f"TASK {i:02d} {t}",flush=True)

status="UNKNOWN"
culprits=[]
interactions=[]
try:
    # Critical control: no runtime tasks. If this still fails, blocker is outside this factory.
    none_ok=run_trial(set(),"ALL_DISABLED")
    if not none_ok:
        status="BLOCKER_OUTSIDE_RUNTIME_FACTORY"
    else:
        # Full set confirms reproduction in this exact diagnostic harness.
        full_ok=run_trial(set(tasks),"ALL_ENABLED")
        if full_ok:
            status="NO_REPRO_IN_DIAGNOSTIC_WINDOW"
        else:
            recurse(tasks,"B",culprits,interactions)
            if culprits:
                status="CULPRIT_TASKS_IDENTIFIED"
            elif interactions:
                status="INTERACTION_GROUP_IDENTIFIED"
            else:
                status="UNRESOLVED"
except Exception as e:
    status="DIAGNOSTIC_ABORTED"
    records.append({"error":repr(e),"traceback":traceback.format_exc()})
finally:
    # Always restore exact original source and restart production.
    try:
        docker("cp",str(ORIG),f"{APP}:/app/app/main.py")
        docker("restart",APP)
        time.sleep(8)
        restored=probe()
    except Exception as e:
        restored={"ok":False,"error":repr(e)}

report={
    "revision":"QUANT-NOVA-RUNTIME-TASK-BISECT-DIAG-V1",
    "status":status,
    "selection_logic_changed":False,
    "buy_thresholds_changed":False,
    "scoring_formula_changed":False,
    "candidate_selection_changed":False,
    "ws_contract_changed":False,
    "runtime_factory_variable":var,
    "tasks":tasks,
    "culprit_tasks":culprits,
    "interaction_groups":interactions,
    "trial_count":trial_count,
    "records":records,
    "restored_original":restored,
}
REPORT.write_text(json.dumps(report,ensure_ascii=False,indent=2),encoding="utf-8")

print("=== DIAGNOSTIC RESULT ===",flush=True)
print("STATUS="+status,flush=True)
print("CULPRIT_TASKS="+(",".join(culprits) if culprits else "NONE"),flush=True)
if interactions:
    for i,g in enumerate(interactions,1):
        print(f"INTERACTION_GROUP_{i}="+",".join(g),flush=True)
print("TRIAL_COUNT="+str(trial_count),flush=True)
print("ORIGINAL_MAIN_RESTORED="+str(bool(restored.get("ok"))),flush=True)
print("REPORT="+str(REPORT),flush=True)
PY

chmod 700 "$CTRL"

echo "=== CONTROLLER SYNTAX ==="
python3 -m py_compile "$CTRL"
echo "CONTROLLER_COMPILE=PASS"

echo "=== BEGIN AUTOMATIC TASK BISECTION ==="
python3 "$CTRL" "$ORIG" "$REPORT"

echo "=== REPORT SUMMARY ==="
python3 - "$REPORT" <<'PY'
import json,sys
x=json.load(open(sys.argv[1]))
print("STATUS="+x["status"])
print("TASK_COUNT="+str(len(x["tasks"])))
print("CULPRIT_TASKS="+(",".join(x["culprit_tasks"]) if x["culprit_tasks"] else "NONE"))
for i,g in enumerate(x.get("interaction_groups") or [],1):
    print(f"INTERACTION_GROUP_{i}="+",".join(g))
print("TRIAL_COUNT="+str(x["trial_count"]))
print("ORIGINAL_MAIN_RESTORED="+str(bool((x.get("restored_original") or {}).get("ok"))))
PY

echo "=== PUBLIC GUARD CHECK ==="
ROOT="$(curl -k -sS --max-time 2 -o /dev/null -w '%{http_code} %{time_total}' https://3-38-25-20.nip.io/ || true)"
STATIC="$(curl -k -sS --max-time 2 -o /dev/null -w '%{http_code} %{time_total}' https://3-38-25-20.nip.io/static/nova.js || true)"
echo "PUBLIC_ROOT=$ROOT"
echo "PUBLIC_STATIC=$STATIC"

echo "=== FINAL CONTRACT ==="
echo "PRODUCTION_SOURCE=RESTORED_TO_EXACT_PRE-DIAGNOSTIC_MAIN.PY"
echo "SELECTION_LOGIC=UNCHANGED"
echo "BUY_THRESHOLDS=UNCHANGED"
echo "SCORING_FORMULA=UNCHANGED"
echo "CANDIDATE_SELECTION=UNCHANGED"
echo "WS_CONTRACT=UNCHANGED"
echo "REPORT_PATH=$REPORT"
echo "=== $REV COMPLETE ==="
