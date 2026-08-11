#!/usr/bin/env bash
set -Eeuo pipefail

REV="QUANT-NOVA-2.4.22-PIPELINE-RECOVERY-ONE-SHOT-V7"
APP="quant-nova"
STAMP="$(date +%Y%m%d%H%M%S)"
WORK="/tmp/nova-v6-$STAMP"
BK="$HOME/quant-nova/pipeline-recovery-v7-backups"
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
print("replay",h.get('replay'))
print("rs_error",(h.get('relative_strength_shadow') or {}).get('last_error'))
print("archive",h.get('archive'))
PY

# ------------------------------------------------------------------
# 1) ka90003 live probe
#    Previous V5 proved trde_upper_tp alone is not enough and Kiwoom
#    next required amt_qty_tp. Probe the documented value domains only.
# ------------------------------------------------------------------
echo "=== KA90003 SAFE PROBE V6 ==="
sudo docker exec -i "$APP" python3 - <<'PY' > "$PROBE"
import os, json, datetime, httpx, re

app=os.getenv("KIWOOM_APP_KEY","").strip()
sec=(os.getenv("KIWOOM_SECRET_KEY") or os.getenv("KIWOOM_APP_SECRET") or "").strip()
out={"ok":False,"chosen":None,"attempts":[]}
if not app or not sec:
    out["error"]="missing app credentials"
    print(json.dumps(out,ensure_ascii=False)); raise SystemExit

with httpx.Client(timeout=8.0) as c:
    t=c.post("https://api.kiwoom.com/oauth2/token",
             json={"grant_type":"client_credentials","appkey":app,"secretkey":sec})
    tj=t.json()
    tok=tj.get("token")
    if not tok:
        out["error"]="token:"+str(tj.get("return_msg") or t.text)[:180]
        print(json.dumps(out,ensure_ascii=False)); raise SystemExit

    headers={"authorization":"Bearer "+tok,"api-id":"ka90003","Content-Type":"application/json;charset=UTF-8"}
    day=datetime.datetime.now(datetime.timezone(datetime.timedelta(hours=9))).strftime("%Y%m%d")
    base={"dt":day,"mrkt_tp":"P00101","stex_tp":"1"}

    # trde_upper_tp domain observed accepted by server in V5: 1/2/3
    # amt_qty_tp documented domain used across Kiwoom program/investor APIs: 1 amount / 2 quantity
    for trde_upper_tp in ("1","2","3"):
        for amt_qty_tp in ("1","2"):
            body=dict(base)
            body["trde_upper_tp"]=trde_upper_tp
            body["amt_qty_tp"]=amt_qty_tp
            try:
                r=c.post("https://api.kiwoom.com/api/dostk/stkinfo",headers=headers,json=body)
                try:j=r.json()
                except Exception:j={"return_code":999,"return_msg":r.text[:180]}
            except Exception as e:
                out["attempts"].append({"trde_upper_tp":trde_upper_tp,"amt_qty_tp":amt_qty_tp,"error":str(e)[:180]})
                continue

            msg=str(j.get("return_msg") or "")
            rec={
                "trde_upper_tp":trde_upper_tp,
                "amt_qty_tp":amt_qty_tp,
                "http":r.status_code,
                "return_code":j.get("return_code"),
                "return_msg":msg[:220],
            }
            # Capture any still-missing required parameter name for diagnosis.
            m=re.search(r'필수[^=]*=([A-Za-z0-9_]+)',msg)
            if m: rec["missing_required"]=m.group(1)
            out["attempts"].append(rec)

            if r.status_code==200 and int(j.get("return_code",999))==0:
                out["ok"]=True
                out["chosen"]={"trde_upper_tp":trde_upper_tp,"amt_qty_tp":amt_qty_tp}
                rows=j.get("stk_prm_trde_prst")
                out["rows"]=len(rows) if isinstance(rows,list) else 0
                break
        if out["ok"]: break

print(json.dumps(out,ensure_ascii=False))
PY
cat "$PROBE"

python3 - "$PROBE" <<'PY'
import json,sys
p=json.load(open(sys.argv[1],encoding='utf-8'))
if not p.get("ok"):
    print("KA90003_PROBE_NOT_CONFIRMED")
    for a in p.get("attempts",[]):
        print(a)
    raise SystemExit(1)
print("KA90003_PROBE=PASS",p.get("chosen"),"rows",p.get("rows"))
PY

# ------------------------------------------------------------------
# 2) Build targeted patch with AST guards.
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
    '_reset_rest_client_v7',
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

# A. maintenance-cap AttributeError
n,fn,_=fn_text(src,'maintenance_liveness_supervisor_loop')
fn2=re.sub(
    r'(?m)^(\s*)now\s*=\s*now_kst\(\)\s*\n\1mins\s*=\s*now\.hour\s*\*\s*60\s*\+\s*now\.minute\s*$',
    lambda m:m.group(1)+"mins=kst_seconds()//60",
    fn,count=1)
if fn2==fn and "kst_seconds()//60" not in fn:
    raise SystemExit("MAINTENANCE_PATTERN_NOT_FOUND")
fn=fn2
if "st.pop('last_error',None)" not in fn:
    anchor=re.search(r'(?m)^(\s*)st\[[\'"]active_count[\'"]\]\s*=\s*len\(_NOVA_MAINT_RUNNING\)',fn)
    if anchor:
        indent=anchor.group(1); e=fn.find("\n",anchor.end())
        fn=fn[:e+1]+indent+"st.pop('last_error',None)\n"+fn[e+1:]
src=replace_fn(src,'maintenance_liveness_supervisor_loop',fn)
rep["maintenance"]="FIXED"

# B. RS shadow NameError; shadow only, zero BUY effect.
n,fn,_=fn_text(src,'rs_market_shadow_loop')
if re.search(r'(?<!realtime_)runtime_awake\(\)',fn):
    fn=re.sub(r'(?<!realtime_)runtime_awake\(\)','realtime_runtime_awake()',fn)
    rep["rs"]="FIXED"
elif 'realtime_runtime_awake()' in fn:
    rep["rs"]="ALREADY_FIXED"
else:
    raise SystemExit("RS_RUNTIME_PATTERN_MISSING")
src=replace_fn(src,'rs_market_shadow_loop',fn)

# C. REST transport self-heal; request bodies/priorities untouched.
if 'async def _reset_rest_client_v7()' not in src:
    n,fn,lines=fn_text(src,'kiwoom_post')
    helper="""async def _reset_rest_client_v7():\n    global _REST_CLIENT\n    old=None\n    async with _REST_CLIENT_LOCK:\n        old=_REST_CLIENT\n        _REST_CLIENT=None\n    if old is not None:\n        try:await old.aclose()\n        except Exception:pass\n\n"""
    src="".join(lines[:n.lineno-1])+helper+"".join(lines[n.lineno-1:])
n,fn,_=fn_text(src,'kiwoom_post')
if 'await _reset_rest_client_v7()' not in fn:
    fn=fn.replace(
        "except Exception:\n            STATE.rest_status['_pipeline']=",
        "except Exception as e:\n            await _reset_rest_client_v7()\n            STATE.rest_status['_pipeline']=",
        1)
    fn=fn.replace("'last_error':True}", "'last_error':True,'last_error_detail':str(e)[:180]}",1)
src=replace_fn(src,'kiwoom_post',fn)
rep["rest_transport"]="RESET_ON_EXCEPTION"

# D. ka90003 exact live-validated required fields only; API id stays ka90003.
if not probe.get("ok") or not probe.get("chosen"):
    raise SystemExit("KA90003_PROBE_NOT_CONFIRMED")
chosen=probe["chosen"]
n,fn,_=fn_text(src,'_refresh_program_rest_cache')
if "'ka90004'" in fn or '"ka90004"' in fn:
    raise SystemExit("UNSAFE_KA90004_PRESENT_ABORT")

if "trde_upper_tp" not in fn or "amt_qty_tp" not in fn:
    old="{'dt':today_kst(),'mrkt_tp':mrkt,'stex_tp':stex}"
    if old not in fn:
        raise SystemExit("KA90003_BODY_PATTERN_NOT_FOUND")
    new=(
        "{'dt':today_kst(),'mrkt_tp':mrkt,'stex_tp':stex,"
        "'trde_upper_tp':'"+str(chosen["trde_upper_tp"])+"',"
        "'amt_qty_tp':'"+str(chosen["amt_qty_tp"])+"'}"
    )
    fn=fn.replace(old,new,1)
src=replace_fn(src,'_refresh_program_rest_cache',fn)
rep["ka90003"]="VALIDATED_FIELDS="+json.dumps(chosen,ensure_ascii=False)

# E. WS quota: keep healthy socket/registrations and defer only failed kind.
n,fn,_=fn_text(src,'ws_loop')
if "WS_QUOTA_COOLDOWN_V7" not in fn:
    old="""                            msg=str(m.get('return_msg') or f"{kind} registry failed")[:180]\n                            if '허용된 요청 건수를 초과' in msg or '요청 건수' in msg:\n                                STATE.ws_status.update({'quota_error':msg,'quota_error_at':time.time(),'quota_guard':'SESSION_AWARE_HARD_CAP','subscription_budget':WS_REG_ITEM_BUDGET})\n                            raise RuntimeError(msg)"""
    new="""                            msg=str(m.get('return_msg') or f"{kind} registry failed")[:180]\n                            if '허용된 요청 건수를 초과' in msg or '요청 건수' in msg:\n                                # WS_QUOTA_COOLDOWN_V7: preserve healthy socket and successful registrations.\n                                blocked_until[kind]=time.time()+60\n                                STATE.ws_status.update({'quota_error':msg,'quota_error_at':time.time(),'quota_guard':'SESSION_AWARE_HARD_CAP_COOLDOWN_V7','subscription_budget':WS_REG_ITEM_BUDGET,'quota_cooldown_kind':kind,'quota_cooldown_until':blocked_until[kind]})\n                                continue\n                            raise RuntimeError(msg)"""
    if old in fn:
        fn=fn.replace(old,new,1)
        src=replace_fn(src,'ws_loop',fn)
        rep["ws_quota"]="COOLDOWN_NO_SOCKET_TEARDOWN"
    else:
        rep["ws_quota"]="SOURCE_SHAPE_UNCHANGED_SKIP"
else:
    rep["ws_quota"]="ALREADY_FIXED"

# AST syntax + protected function invariant
ast.parse(src)
after=fhashes(src)
bad=[]
for name,h in before.items():
    if name in ALLOW: continue
    if after.get(name)!=h: bad.append(name)
if bad:
    raise SystemExit("UNAUTHORIZED_FUNCTION_CHANGES:"+",".join(sorted(bad)))

protected=[
 'calc','ranked','score_codes','update_sector_context','evaluate_nxt_radar_alerts',
 'entry_state_machine','evaluate_entry','rally_dna_match','exit_dna_match',
 '_apply_streamed_rank_result','_finalize_discovery_cycle','build_realtime_targets','registry_diff'
]
for name in protected:
    if name in before and after.get(name)!=before[name]:
        raise SystemExit("PROTECTED_CHANGED:"+name)

def block(text,start_marker,end_marker):
    a=text.find(start_marker); b=text.find(end_marker,a)
    if a<0 or b<0:return None
    return text[a:b]

orig=path.read_text(encoding='utf-8')
if block(orig,"RANK_SPECS=[","class RestPacer:") != block(src,"RANK_SPECS=[","class RestPacer:"):
    raise SystemExit("RANK_SPECS_BLOCK_CHANGED")

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
import sys
a=Path(sys.argv[1]).read_text()
b=Path(sys.argv[2]).read_text()
for x in ["'trade_type':'0B'","'program_type':'0u'","'orderbook_type':'0D'"]:
    assert x in a and x in b,x
assert "ka90004" not in b
print("WS_CONTRACT_0B_0u_0D=PASS")
print("KA90003_RETAINED=PASS")
print("KA90004_FORBIDDEN=PASS")
PY

cat "$REPORT"

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

echo "=== INSTALL ==="
sudo docker cp "$DST" "$APP:/app/app/main.py"

echo "=== RESTART QUANT-NOVA ONLY ==="
sudo docker restart "$APP" >/dev/null
READY=0
for i in $(seq 1 40); do
  c="$(curl -sS --max-time 2 -o /dev/null -w '%{http_code}' http://127.0.0.1:3200/api/health || true)"
  echo "ready[$i]=$c"
  if [[ "$c" == "200" ]]; then READY=1; break; fi
  sleep 1
done
[[ "$READY" == 1 ]] || fail "health not recovered"

echo "=== CORE API GATE ==="
for ep in /api/health /api/nova /api/nxt-signal-table /api/opening-shakeout-reversal /api/close-picks; do
  c="$(curl -sS --max-time 5 -o /dev/null -w '%{http_code}' "http://127.0.0.1:3200$ep" || true)"
  echo "$ep=$c"
  [[ "$c" == "200" ]] || fail "api gate $ep"
done

echo "=== RECOVERY SOAK 45s ==="
for i in $(seq 1 9); do
  sleep 5
  curl -fsS --max-time 5 http://127.0.0.1:3200/api/health > "$POST"
  python3 - "$POST" "$i" <<'PY'
import json,sys
h=json.load(open(sys.argv[1],encoding='utf-8')); r=h.get('rest') or {}
m=r.get('_maintenance_cap_v3') or {}; rp=h.get('replay') or {}; rs=h.get('relative_strength_shadow') or {}; ws=h.get('ws') or {}
print("SOAK",sys.argv[2],
      "feed="+str((h.get('feed') or {}).get('state')),
      "maint_err="+str(m.get('last_error') or '-'),
      "maint_active="+str(m.get('active_count')),
      "replay_q="+str(rp.get('queued')),
      "written="+str(rp.get('written')),
      "rs_err="+str(rs.get('last_error') or '-'),
      "ws="+str(ws.get('connected')),
      "reg_failed="+str(ws.get('reg_failed')))
PY
done

echo "=== FINAL VALIDATION ==="
python3 - "$PRE" "$POST" "$REPORT" <<'PY'
import json,sys
pre=json.load(open(sys.argv[1],encoding='utf-8'))
post=json.load(open(sys.argv[2],encoding='utf-8'))
rep=json.load(open(sys.argv[3],encoding='utf-8'))
assert post.get('ok') is True

# V7: session-aware WS validation.
# MARKET_CLOSED/overnight is allowed to have ws.connected=false and runtime ws type fields=None.
expected=('0B','0u','0D')
feed=post.get('feed') or {}
session=feed.get('session') or {}
active=bool(session.get('active'))
phase=str(session.get('phase') or feed.get('state') or 'UNKNOWN')
w=post.get('ws') or {}
ct=post.get('ws_contract') or {}

runtime_types=tuple(w.get(x) for x in ('trade_type','program_type','orderbook_type'))
declared_types=tuple(ct.get(x) for x in ('trade_type','program_type','orderbook_type'))

if active:
    effective=runtime_types if all(runtime_types) else declared_types
    assert effective==expected,(phase,runtime_types,declared_types)
    assert w.get('connected') is True,(phase,w.get('connected'),w.get('last_error'))
    print("WS_ACTIVE_LIVENESS_GATE=PASS",phase,effective)
else:
    # Static source guard already verified 0B/0u/0D before install.
    # If the health contract object is populated, it must still agree.
    if any(declared_types):
        assert declared_types==expected,(phase,declared_types)
    print("WS_MARKET_CLOSED_GATE=PASS phase=",phase,
          "connected=",w.get('connected'),
          "runtime_types=",runtime_types,
          "declared_types=",declared_types)

m=(post.get('rest') or {}).get('_maintenance_cap_v3') or {}
e=str(m.get('last_error') or '')
assert "object has no attribute 'hour'" not in e,e
if m.get('active_count') is not None:
    assert int(m.get('active_count') or 0)<=4,m
print("MAINTENANCE_GATE=PASS",m.get('active_count'),e or '-')

rs=post.get('relative_strength_shadow') or {}
rse=str(rs.get('last_error') or '')
assert "runtime_awake" not in rse,rse
print("RS_GATE=PASS",rse or '-')

p0=pre.get('replay') or {}; p1=post.get('replay') or {}
q0=int(p0.get('queued') or 0); q1=int(p1.get('queued') or 0)
w0=int(p0.get('written') or 0); w1=int(p1.get('written') or 0)
if q0>0:
    assert w1>w0 or q1<q0,(p0,p1)
print("REPLAY_GATE=PASS",q0,q1,w0,w1)

# The live probe is the primary ka90003 correctness gate.
assert str(rep.get('ka90003') or '').startswith('VALIDATED_FIELDS='),rep
sm=post.get('smart_money') or {}
errs=[]
for k,v in sm.items():
    if isinstance(v,dict) and 'ka90003' in str(k):
        msg=str(v.get('msg') or '')
        if 'trde_upper_tp' in msg or 'amt_qty_tp' in msg:
            errs.append((k,msg))
assert not errs,errs
print("KA90003_REQUIRED_FIELDS_GATE=PASS",rep.get('ka90003'))

r=post.get('rest') or {}
print("DISCOVERY_STATUS",r.get('_discovery_cycle'))
print("NXT_FAST_STATUS",r.get('_nxt_fast_cycle'))
print("PIPELINE_STATUS",r.get('_pipeline'))

arc=post.get('archive') or {}
print("ARCHIVE_STATUS seal_ready=",arc.get('seal_ready'),
      "waiting=",arc.get('seal_waiting'))
print("FINAL_SESSION_MODE=",phase,"active=",active)
PY

echo "=== CORE LIVENESS ==="
PASSN=0
for i in $(seq 1 15); do
  out="$(curl -sS --max-time 2 -o /dev/null -w '%{http_code} %{time_total}' http://127.0.0.1:3200/api/health || true)"
  echo "$i $out"
  [[ "$out" == 200* ]] && PASSN=$((PASSN+1))
  sleep 1
done
[[ "$PASSN" -ge 14 ]] || fail "liveness insufficient"
echo "CORE_LIVENESS_GATE=PASS $PASSN/15"

TAG="quant-nova:2.4.22-pipeline-recovery-v7-$STAMP"
sudo docker commit "$APP" "$TAG" >/dev/null
echo "SNAPSHOT_IMAGE=$TAG"

SUCCESS=1
trap - ERR INT TERM

echo "=== FINAL ==="
echo "MAINTENANCE_STR_HOUR=FIXED"
echo "REPLAY_FLUSH=RECOVERY_VERIFIED"
echo "RS_RUNTIME_AWAKE=FIXED"
echo "KA90003=RETAINED_WITH_LIVE_VALIDATED_trde_upper_tp_AND_amt_qty_tp"
echo "REST_RANK_SPECS=UNCHANGED"
echo "REST_TRANSPORT=SELF_HEAL_ON_EXCEPTION"
echo "WS_QUOTA=COOLDOWN_WITHOUT_TARGET_CHANGE_IF_PATTERN_MATCHED"
echo "WS_CONTRACT=0B/0u/0D_UNCHANGED"
echo "WS_VALIDATION=SESSION_AWARE_V7"
echo "BUY_LOGIC=UNCHANGED"
echo "SCORING_FORMULA=UNCHANGED"
echo "SELECTION_LOGIC=UNCHANGED"
echo "RALLY_DNA=UNCHANGED"
echo "EXIT_DNA=UNCHANGED"
echo "OPENING_FLOW=UNCHANGED"
echo "=== $REV PASS ==="
