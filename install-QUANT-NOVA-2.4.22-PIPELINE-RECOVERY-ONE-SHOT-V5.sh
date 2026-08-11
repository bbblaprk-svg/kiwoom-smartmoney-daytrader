#!/usr/bin/env bash
set -Eeuo pipefail

REV="QUANT-NOVA-2.4.22-PIPELINE-RECOVERY-ONE-SHOT-V5"
APP="quant-nova"
STAMP="$(date +%Y%m%d%H%M%S)"
WORK="/tmp/nova-v5-$STAMP"
BK="$HOME/quant-nova/pipeline-recovery-v5-backups"
SRC="$WORK/main.before.py"
DST="$WORK/main.after.py"
PRE="$WORK/health.before.json"
POST="$WORK/health.after.json"
PROBE="$WORK/ka90003-probe.json"
REPORT="$WORK/patch-report.json"
SUCCESS=0

mkdir -p "$WORK" "$BK"
chmod 700 "$WORK" "$BK"

fail(){ echo "=== $REV FAIL: $* ===" >&2; exit 1; }

rollback(){
  ec=$?
  if [[ "$SUCCESS" -ne 1 && -f "$SRC" ]]; then
    echo "=== AUTO ROLLBACK ==="
    sudo docker cp "$SRC" "$APP:/app/app/main.py" >/dev/null 2>&1 || true
    sudo docker restart "$APP" >/dev/null 2>&1 || true
    for i in $(seq 1 30); do
      c="$(curl -sS --max-time 2 -o /dev/null -w '%{http_code}' http://127.0.0.1:3200/api/health || true)"
      [[ "$c" == "200" ]] && break
      sleep 1
    done
    echo "ROLLBACK=COMPLETE"
  fi
  exit "$ec"
}
trap rollback ERR INT TERM

echo "=== $REV START ==="
echo "PATCH_SCOPE=RUNTIME_PIPELINE_INFRA_ONLY"
echo "BUY_LOGIC=UNCHANGED"
echo "SCORING_FORMULA=UNCHANGED"
echo "SELECTION_LOGIC=UNCHANGED"
echo "RANK_SPECS=UNCHANGED"
echo "WS_TARGETS=UNCHANGED"
echo "WS_CONTRACT=UNCHANGED"
echo "RALLY_DNA_RULES=UNCHANGED"
echo "EXIT_DNA_RULES=UNCHANGED"
echo "OPENING_FLOW=UNCHANGED"

sudo docker inspect "$APP" >/dev/null || fail "quant-nova missing"
curl -fsS --max-time 6 http://127.0.0.1:3200/api/health > "$PRE" || fail "pre-health unavailable"
sudo docker cp "$APP:/app/app/main.py" "$SRC"
sudo chown "$(id -u):$(id -g)" "$SRC"
cp "$SRC" "$DST"
cp "$SRC" "$BK/main.py.before-$STAMP"

echo "=== PRE-STATE ==="
python3 - "$PRE" <<'PY'
import json,sys
h=json.load(open(sys.argv[1],encoding='utf-8'))
r=h.get('rest') or {}; ws=h.get('ws') or {}
print("feed", (h.get('feed') or {}).get('state'))
print("ws_connected",ws.get('connected'),"types",ws.get('trade_type'),ws.get('program_type'),ws.get('orderbook_type'))
print("maintenance_error",(r.get('_maintenance_cap_v3') or {}).get('last_error'))
print("discovery",r.get('_discovery_cycle'))
print("fast",r.get('_nxt_fast_cycle'))
print("replay",h.get('replay'))
print("rs_error",(h.get('relative_strength_shadow') or {}).get('last_error'))
print("archive",h.get('archive'))
PY

# ------------------------------------------------------------------
# 1. Safe live probe for ka90003. We do NOT guess a TR switch.
#    We test only the missing required field reported by Kiwoom.
# ------------------------------------------------------------------
echo "=== KA90003 SAFE PROBE ==="
sudo docker exec -i "$APP" python3 - <<'PY' > "$PROBE"
import os, json, datetime, httpx
app=os.getenv("KIWOOM_APP_KEY","").strip()
sec=(os.getenv("KIWOOM_SECRET_KEY") or os.getenv("KIWOOM_APP_SECRET") or "").strip()
out={"ok":False,"chosen":None,"attempts":[]}
if not app or not sec:
    out["error"]="missing app credentials"
    print(json.dumps(out,ensure_ascii=False)); raise SystemExit
try:
    with httpx.Client(timeout=8.0) as c:
        t=c.post("https://api.kiwoom.com/oauth2/token",
                 json={"grant_type":"client_credentials","appkey":app,"secretkey":sec})
        tj=t.json()
        tok=tj.get("token")
        if not tok:
            out["error"]="token:"+str(tj.get("return_msg") or t.text)[:160]
            print(json.dumps(out,ensure_ascii=False)); raise SystemExit
        headers={"authorization":"Bearer "+tok,"api-id":"ka90003","Content-Type":"application/json;charset=UTF-8"}
        day=datetime.datetime.now(datetime.timezone(datetime.timedelta(hours=9))).strftime("%Y%m%d")
        base={"dt":day,"mrkt_tp":"P00101","stex_tp":"1"}
        for val in ("1","2","3"):
            body=dict(base); body["trde_upper_tp"]=val
            try:
                r=c.post("https://api.kiwoom.com/api/dostk/stkinfo",headers=headers,json=body)
                j=r.json()
            except Exception as e:
                out["attempts"].append({"value":val,"error":str(e)[:160]}); continue
            rec={"value":val,"http":r.status_code,"return_code":j.get("return_code"),"return_msg":str(j.get("return_msg") or "")[:180]}
            out["attempts"].append(rec)
            if r.status_code==200 and int(j.get("return_code",999))==0:
                out["ok"]=True; out["chosen"]=val
                rows=j.get("stk_prm_trde_prst")
                out["rows"]=len(rows) if isinstance(rows,list) else 0
                break
except Exception as e:
    out["error"]=str(e)[:180]
print(json.dumps(out,ensure_ascii=False))
PY
cat "$PROBE"

# ------------------------------------------------------------------
# 2. Patch current source only, with function-level AST protection.
# ------------------------------------------------------------------
echo "=== BUILD PATCH ==="
python3 - "$DST" "$PROBE" "$REPORT" <<'PY'
from pathlib import Path
import ast, hashlib, json, re, sys

path=Path(sys.argv[1]); probe=json.load(open(sys.argv[2],encoding='utf-8'))
report_path=Path(sys.argv[3])
src=path.read_text(encoding='utf-8')
ast.parse(src)

ALLOW={
    'maintenance_liveness_supervisor_loop',
    'rs_market_shadow_loop',
    'kiwoom_post',
    '_reset_rest_client_v5',
    '_refresh_program_rest_cache',
    'ws_loop',
}

def fhashes(text):
    t=ast.parse(text); d={}
    for n in ast.walk(t):
        if isinstance(n,(ast.FunctionDef,ast.AsyncFunctionDef)):
            h=hashlib.sha256(ast.dump(n,include_attributes=False).encode()).hexdigest()
            d.setdefault(n.name,[]).append(h)
    for k in d:d[k].sort()
    return d

def fn_node(text,name):
    t=ast.parse(text)
    nodes=[n for n in ast.walk(t) if isinstance(n,(ast.FunctionDef,ast.AsyncFunctionDef)) and n.name==name]
    if len(nodes)!=1:
        raise SystemExit(f"FUNCTION_COUNT_{name}={len(nodes)}")
    return nodes[0]

def fn_text(text,name):
    n=fn_node(text,name); lines=text.splitlines(True)
    return n,"".join(lines[n.lineno-1:n.end_lineno]),lines

def replace_fn(text,name,new):
    n,old,lines=fn_text(text,name)
    return "".join(lines[:n.lineno-1])+new+"".join(lines[n.end_lineno:])

before=fhashes(src)
rep={}

# A) maintenance cap: now_kst() is a string; kst_seconds() is numeric.
if 'maintenance_liveness_supervisor_loop' in before:
    n,fn,_=fn_text(src,'maintenance_liveness_supervisor_loop')
    old=fn
    fn2=re.sub(
        r'(?m)^(\s*)now\s*=\s*now_kst\(\)\s*\n\1mins\s*=\s*now\.hour\s*\*\s*60\s*\+\s*now\.minute\s*$',
        lambda m:m.group(1)+"mins=kst_seconds()//60",
        fn,count=1)
    if fn2==fn and "kst_seconds()//60" not in fn:
        raise SystemExit("MAINTENANCE_PATTERN_NOT_FOUND")
    fn=fn2
    # Clear stale error after successful supervisor iteration.
    if "st.pop('last_error',None)" not in fn:
        anchor=re.search(r'(?m)^(\s*)st\[[\'"]active_count[\'"]\]\s*=\s*len\(_NOVA_MAINT_RUNNING\)',fn)
        if anchor:
            indent=anchor.group(1); end=fn.find("\n",anchor.end())
            fn=fn[:end+1]+indent+"st.pop('last_error',None)\n"+fn[end+1:]
    src=replace_fn(src,'maintenance_liveness_supervisor_loop',fn)
    rep["maintenance"]="FIXED"
else:
    raise SystemExit("MAINTENANCE_FUNCTION_MISSING")

# B) RS shadow only: undefined runtime_awake -> existing realtime_runtime_awake.
if 'rs_market_shadow_loop' in before:
    n,fn,_=fn_text(src,'rs_market_shadow_loop')
    if re.search(r'(?<!realtime_)runtime_awake\(\)',fn):
        fn=re.sub(r'(?<!realtime_)runtime_awake\(\)','realtime_runtime_awake()',fn)
        rep["rs"]="FIXED"
    elif 'realtime_runtime_awake()' in fn:
        rep["rs"]="ALREADY_FIXED"
    else:
        raise SystemExit("RS_RUNTIME_PATTERN_MISSING")
    src=replace_fn(src,'rs_market_shadow_loop',fn)

# C) REST transport recovery. No body/rank/priority changes.
if 'async def _reset_rest_client_v5()' not in src:
    n,fn,lines=fn_text(src,'kiwoom_post')
    helper="""async def _reset_rest_client_v5():\n    global _REST_CLIENT\n    old=None\n    async with _REST_CLIENT_LOCK:\n        old=_REST_CLIENT\n        _REST_CLIENT=None\n    if old is not None:\n        try:await old.aclose()\n        except Exception:pass\n\n"""
    src="".join(lines[:n.lineno-1])+helper+"".join(lines[n.lineno-1:])
n,fn,_=fn_text(src,'kiwoom_post')
if 'await _reset_rest_client_v5()' not in fn:
    fn=fn.replace(
        "except Exception:\n            STATE.rest_status['_pipeline']=",
        "except Exception as e:\n            await _reset_rest_client_v5()\n            STATE.rest_status['_pipeline']=",
        1)
    fn=fn.replace("'last_error':True}", "'last_error':True,'last_error_detail':str(e)[:180]}",1)
src=replace_fn(src,'kiwoom_post',fn)
rep["rest_transport"]="RESET_ON_EXCEPTION"

# D) ka90003: keep ka90003. Add only a value that the live official endpoint accepted.
if '_refresh_program_rest_cache' in before:
    n,fn,_=fn_text(src,'_refresh_program_rest_cache')
    if "'ka90004'" in fn or '"ka90004"' in fn:
        raise SystemExit("UNSAFE_KA90004_PRESENT_ABORT")
    if "trde_upper_tp" not in fn:
        if not probe.get("ok") or not probe.get("chosen"):
            raise SystemExit("KA90003_PROBE_NOT_CONFIRMED")
        val=str(probe["chosen"])
        # Patch the exact existing request body; do not change dt/mrkt/stex.
        old="{'dt':today_kst(),'mrkt_tp':mrkt,'stex_tp':stex}"
        new="{'dt':today_kst(),'mrkt_tp':mrkt,'stex_tp':stex,'trde_upper_tp':'"+val+"'}"
        if old not in fn:
            raise SystemExit("KA90003_BODY_PATTERN_NOT_FOUND")
        fn=fn.replace(old,new,1)
        rep["ka90003"]="ADDED_VALIDATED_trde_upper_tp="+val
    else:
        rep["ka90003"]="ALREADY_HAS_trde_upper_tp"
    src=replace_fn(src,'_refresh_program_rest_cache',fn)
else:
    raise SystemExit("PROGRAM_CACHE_FUNCTION_MISSING")

# E) WS quota: preserve target construction + fixed 0B/0u/0D.
#    On quota rejection, do not tear down a healthy socket and immediately re-register.
#    Cool down only that registry kind and re-diff later.
n,fn,_=fn_text(src,'ws_loop')
if "WS_QUOTA_COOLDOWN_V5" not in fn:
    old="""                            msg=str(m.get('return_msg') or f"{kind} registry failed")[:180]\n                            if '허용된 요청 건수를 초과' in msg or '요청 건수' in msg:\n                                STATE.ws_status.update({'quota_error':msg,'quota_error_at':time.time(),'quota_guard':'SESSION_AWARE_HARD_CAP','subscription_budget':WS_REG_ITEM_BUDGET})\n                            raise RuntimeError(msg)"""
    new="""                            msg=str(m.get('return_msg') or f"{kind} registry failed")[:180]\n                            if '허용된 요청 건수를 초과' in msg or '요청 건수' in msg:\n                                # WS_QUOTA_COOLDOWN_V5: keep the healthy socket and successful registrations.\n                                # Target sets and 0B/0u/0D contract remain unchanged; retry the diff later.\n                                blocked_until[kind]=time.time()+60\n                                STATE.ws_status.update({'quota_error':msg,'quota_error_at':time.time(),'quota_guard':'SESSION_AWARE_HARD_CAP_COOLDOWN_V5','subscription_budget':WS_REG_ITEM_BUDGET,'quota_cooldown_kind':kind,'quota_cooldown_until':blocked_until[kind]})\n                                continue\n                            raise RuntimeError(msg)"""
    if old not in fn:
        # If current source has evolved, do not make a guessed WS rewrite.
        rep["ws_quota"]="CURRENT_SHAPE_NOT_PATCHED"
    else:
        fn=fn.replace(old,new,1)
        rep["ws_quota"]="COOLDOWN_NO_RECONNECT"
        src=replace_fn(src,'ws_loop',fn)
else:
    rep["ws_quota"]="ALREADY_FIXED"

# Syntax + protected function invariant.
ast.parse(src)
after=fhashes(src)
bad=[]
for name,h in before.items():
    if name in ALLOW: continue
    if after.get(name)!=h: bad.append(name)
if bad:
    raise SystemExit("UNAUTHORIZED_FUNCTION_CHANGES:"+",".join(sorted(bad)))

# Hard protected trading/data formulas.
protected=[
 'calc','ranked','score_codes','update_sector_context','evaluate_nxt_radar_alerts',
 'entry_state_machine','evaluate_entry','rally_dna_match','exit_dna_match',
 '_apply_streamed_rank_result','_finalize_discovery_cycle','build_realtime_targets','registry_diff'
]
for name in protected:
    if name in before and after.get(name)!=before[name]:
        raise SystemExit("PROTECTED_CHANGED:"+name)

# Rank specs byte-level guard.
def block(text,start_marker,end_marker):
    a=text.find(start_marker); b=text.find(end_marker,a)
    if a<0 or b<0:return None
    return text[a:b]
orig=path.read_text(encoding='utf-8')
rb0=block(orig,"RANK_SPECS=[","class RestPacer:")
rb1=block(src,"RANK_SPECS=[","class RestPacer:")
if rb0!=rb1: raise SystemExit("RANK_SPECS_BLOCK_CHANGED")

# Fixed contract guard.
for token in ("'trade_type':'0B'","'program_type':'0u'","'orderbook_type':'0D'"):
    if token not in src: raise SystemExit("WS_CONTRACT_TOKEN_MISSING:"+token)

path.write_text(src,encoding='utf-8')
rep["protected_gate"]="PASS"
rep["rank_specs_gate"]="PASS"
rep["ws_contract_gate"]="PASS"
report_path.write_text(json.dumps(rep,ensure_ascii=False,indent=2),encoding='utf-8')
print(json.dumps(rep,ensure_ascii=False,indent=2))
PY

python3 -m py_compile "$DST"
echo "PY_COMPILE=PASS"

echo "=== SOURCE GUARDS ==="
python3 - "$SRC" "$DST" <<'PY'
from pathlib import Path
a=Path(__import__('sys').argv[1]).read_text()
b=Path(__import__('sys').argv[2]).read_text()
for x in ["'trade_type':'0B'","'program_type':'0u'","'orderbook_type':'0D'"]:
    assert x in a and x in b,x
assert "ka90004" not in b
print("WS_CONTRACT_0B_0u_0D=PASS")
print("KA90003_RETAINED=PASS")
print("KA90004_FORBIDDEN=PASS")
PY

echo "=== PATCH REPORT ==="
cat "$REPORT"
echo "=== DIFF (ONLY TARGETED AREAS) ==="
diff -u "$SRC" "$DST" | grep -E '^[+-].*(maintenance|kst_seconds|runtime_awake|reset_rest|trde_upper_tp|quota|blocked_until|last_error_detail)' | head -120 || true

# Persist current state close to restart.
echo "=== WAIT FOR RECENT PERSIST ==="
for i in $(seq 1 15); do
  age="$(curl -fsS --max-time 3 http://127.0.0.1:3200/api/health | python3 -c 'import sys,json;h=json.load(sys.stdin);print((h.get("performance_guard") or {}).get("last_persist_age_sec") or 999)' 2>/dev/null || echo 999)"
  echo "persist_age=$age"
  python3 - "$age" <<'PY' && break || true
import sys
try: raise SystemExit(0 if float(sys.argv[1])<=15 else 1)
except: raise SystemExit(1)
PY
  sleep 4
done

echo "=== INSTALL CURRENT-SOURCE PATCH ==="
sudo docker cp "$DST" "$APP:/app/app/main.py"

echo "=== RESTART QUANT-NOVA ONLY ==="
sudo docker restart "$APP" >/dev/null
for i in $(seq 1 40); do
  c="$(curl -sS --max-time 2 -o /dev/null -w '%{http_code}' http://127.0.0.1:3200/api/health || true)"
  echo "ready[$i]=$c"
  [[ "$c" == "200" ]] && break
  sleep 1
done
curl -fsS --max-time 5 http://127.0.0.1:3200/api/health >/dev/null || fail "health not recovered"

echo "=== CORE API GATE ==="
for ep in /api/health /api/nova /api/nxt-signal-table /api/opening-shakeout-reversal /api/close-picks; do
  c="$(curl -sS --max-time 5 -o /dev/null -w '%{http_code}' "http://127.0.0.1:3200$ep" || true)"
  echo "$ep=$c"
  [[ "$c" == "200" ]] || fail "api gate $ep"
done

echo "=== 35s RECOVERY SOAK ==="
for i in $(seq 1 7); do
  sleep 5
  curl -fsS --max-time 5 http://127.0.0.1:3200/api/health > "$POST"
  python3 - "$POST" "$i" <<'PY'
import json,sys
h=json.load(open(sys.argv[1],encoding='utf-8')); r=h.get('rest') or {}
m=r.get('_maintenance_cap_v3') or {}; rp=h.get('replay') or {}; rs=h.get('relative_strength_shadow') or {}; ws=h.get('ws') or {}
print("SOAK",sys.argv[2],
      "feed="+str((h.get('feed') or {}).get('state')),
      "maint="+str(m.get('last_error') or '-'),
      "active="+str(m.get('active_count')),
      "replay_q="+str(rp.get('queued')),
      "written="+str(rp.get('written')),
      "rs="+str(rs.get('last_error') or '-'),
      "ws="+str(ws.get('connected')),
      "regfail="+str(ws.get('reg_failed')))
PY
done

echo "=== FINAL VALIDATION ==="
python3 - "$PRE" "$POST" "$REPORT" <<'PY'
import json,sys
pre=json.load(open(sys.argv[1],encoding='utf-8'))
post=json.load(open(sys.argv[2],encoding='utf-8'))
rep=json.load(open(sys.argv[3],encoding='utf-8'))
assert post.get('ok') is True

# contract invariant
a=pre.get('ws') or {}; b=post.get('ws') or {}
bt=tuple(a.get(x) for x in ('trade_type','program_type','orderbook_type'))
at=tuple(b.get(x) for x in ('trade_type','program_type','orderbook_type'))
assert at==bt==('0B','0u','0D'),(bt,at)
print("WS_CONTRACT_GATE=PASS",at)

# maintenance fixed
m=(post.get('rest') or {}).get('_maintenance_cap_v3') or {}
e=str(m.get('last_error') or '')
assert "object has no attribute 'hour'" not in e,e
if m.get('active_count') is not None: assert int(m.get('active_count') or 0)<=4,m
print("MAINTENANCE_GATE=PASS",m.get('active_count'),e or '-')

# rs fixed
rs=post.get('relative_strength_shadow') or {}
rse=str(rs.get('last_error') or '')
assert "runtime_awake" not in rse,rse
print("RS_GATE=PASS",rse or '-')

# replay should recover if there was a backlog
p0=pre.get('replay') or {}; p1=post.get('replay') or {}
q0=int(p0.get('queued') or 0); q1=int(p1.get('queued') or 0)
w0=int(p0.get('written') or 0); w1=int(p1.get('written') or 0)
if q0>0:
    assert w1>w0 or q1<q0,(p0,p1)
print("REPLAY_GATE=PASS",q0,q1,w0,w1)

# ka90003 missing-field error must be gone from current smart status if function has polled.
sm=post.get('smart_money') or {}
errs=[]
for k,v in sm.items():
    if isinstance(v,dict) and 'ka90003' in str(k):
        msg=str(v.get('msg') or '')
        if 'trde_upper_tp' in msg: errs.append((k,msg))
assert not errs,errs
print("KA90003_REQUIRED_FIELD_GATE=PASS")

# No requirement that after-hours discovery sources be nonempty; print truth.
r=post.get('rest') or {}
print("DISCOVERY_STATUS",r.get('_discovery_cycle'))
print("NXT_FAST_STATUS",r.get('_nxt_fast_cycle'))
print("PIPELINE_STATUS",r.get('_pipeline'))

arc=post.get('archive') or {}
print("ARCHIVE_STATUS",arc.get('seal_ready'),arc.get('seal_waiting'))
PY

echo "=== CORE LIVENESS 15/15 ==="
passn=0
for i in $(seq 1 15); do
  out="$(curl -sS --max-time 2 -o /dev/null -w '%{http_code} %{time_total}' http://127.0.0.1:3200/api/health || true)"
  echo "$i $out"
  [[ "$out" == 200* ]] && passn=$((passn+1))
  sleep 1
done
[[ "$passn" -ge 14 ]] || fail "liveness insufficient"
echo "CORE_LIVENESS_GATE=PASS $passn/15"

TAG="quant-nova:2.4.22-pipeline-recovery-v5-$STAMP"
sudo docker commit "$APP" "$TAG" >/dev/null
echo "SNAPSHOT_IMAGE=$TAG"

SUCCESS=1
trap - ERR INT TERM

echo "=== FINAL ==="
echo "MAINTENANCE_STR_HOUR=FIXED"
echo "REPLAY_FLUSH=RECOVERY_VERIFIED"
echo "RS_RUNTIME_AWAKE=FIXED"
echo "KA90003=RETAINED_WITH_LIVE_VALIDATED_REQUIRED_FIELD"
echo "REST_RANK_SPECS=UNCHANGED"
echo "REST_TRANSPORT=SELF_HEAL_ON_EXCEPTION"
echo "WS_QUOTA=COOLDOWN_WITHOUT_TARGET_CHANGE_IF_PATTERN_MATCHED"
echo "WS_CONTRACT=0B/0u/0D_UNCHANGED"
echo "BUY_LOGIC=UNCHANGED"
echo "SCORING_FORMULA=UNCHANGED"
echo "SELECTION_LOGIC=UNCHANGED"
echo "RALLY_DNA=UNCHANGED"
echo "EXIT_DNA=UNCHANGED"
echo "OPENING_FLOW=UNCHANGED"
echo "=== $REV PASS ==="
