#!/usr/bin/env bash
set -Eeuo pipefail

REV="QUANT-NOVA-2.4.22-MORNING-FLOW-PRESENTATION-RESTORE-V1.1"
APP="quant-nova"
BASE="$HOME/quant-nova"
BK="$BASE/api-presentation-backups"
STAMP="$(date +%Y%m%d%H%M%S)"
WORK="/tmp/nova-api-restore-$STAMP"
OLD="$BK/main.py.before-$STAMP"
NEW="$WORK/main.py"
PATCHER="$WORK/patch.py"
SUCCESS=0

mkdir -p "$BK" "$WORK"
chmod 700 "$BK" "$WORK"

rollback() {
  local ec=$?
  [[ $ec -eq 0 || $SUCCESS -eq 1 ]] && return 0
  echo "=== $REV FAILED: ROLLBACK ===" >&2
  if [[ -s "$OLD" ]]; then
    sudo docker cp "$OLD" "$APP:/app/app/main.py" >/dev/null 2>&1 || true
    sudo docker restart "$APP" >/dev/null 2>&1 || true
    sleep 8
  fi
  echo "ROLLBACK=COMPLETE" >&2
}
trap rollback ERR

echo "=== $REV START ==="
echo "PATCH_SCOPE=API_PRESENTATION_ONLY+MORNING_FLOW_REGRESSION_GUARD"
echo "OPENING_ROUTE_RESTORE=YES_IF_MISSING"
echo "STALE_CLOSE_PICK_DISPLAY_FIX=YES"
echo "SELECTION_LOGIC_CHANGE=NONE"
echo "BUY_THRESHOLDS_CHANGE=NONE"
echo "SCORING_FORMULA_CHANGE=NONE"
echo "CANDIDATE_SELECTION_CHANGE=NONE"
echo "WS_CONTRACT_CHANGE=NONE"

sudo docker inspect "$APP" >/dev/null
sudo docker cp "$APP:/app/app/main.py" "$OLD"
sudo cp "$OLD" "$NEW"
sudo chown "$(id -u):$(id -g)" "$NEW"
chmod 600 "$NEW"

cat > "$PATCHER" <<'PY'
from pathlib import Path
import ast, hashlib, re, sys

p=Path(sys.argv[1])
s=p.read_text(encoding="utf-8")
tree=ast.parse(s)

# Core trading functions must not change.
PROTECTED=["calc","score_codes","ranked","update_sector_context","evaluate_nxt_radar_alerts"]
def fn_text(src,tree,name):
    ls=src.splitlines()
    for n in ast.walk(tree):
        if isinstance(n,(ast.FunctionDef,ast.AsyncFunctionDef)) and n.name==name:
            return "\n".join(ls[n.lineno-1:n.end_lineno])
    raise SystemExit("PROTECTED_FUNCTION_NOT_FOUND:"+name)

before={n:hashlib.sha256(fn_text(s,tree,n).encode()).hexdigest() for n in PROTECTED}

# Morning-flow regression guard. This does NOT change trading logic.
# It prevents this presentation patch from being applied to a source that
# has lost the morning architecture agreed for 2.4.22.
morning_checks={
    "opening_start_0900": bool(re.search(r"OPENING_SHAKEOUT_START_SECONDS\s*=\s*9\s*\*\s*3600",s)),
    "opening_buy_end_1000": bool(re.search(r"OPENING_BUY_END_SECONDS\s*=\s*10\s*\*\s*3600",s)),
    "opening_payload_builder": "def _build_opening_shakeout_payload" in s,
    "opening_row_builder": "def _opening_shakeout_row" in s,
    "next_day_picks_state": "next_day_picks" in s,
    "premarket_rerank": ("premarket_rank" in s or "evaluate_premarket_picks" in s),
    "prior_close_origin": "PRIOR_CLOSE" in s,
    "today_new_origin": "TODAY_NEW" in s,
}
for k,v in morning_checks.items():
    print(f"MORNING_FLOW_{k.upper()}={'PASS' if v else 'FAIL'}")
failed=[k for k,v in morning_checks.items() if not v]
if failed:
    raise SystemExit("MORNING_FLOW_REGRESSION_GUARD_FAIL:"+",".join(failed))


required_helpers=[
    "_snapshot_for_display",
    "_held_snapshot_payload_current_version",
    "_build_opening_shakeout_payload",
    "screen_hold_status",
    "_build_close_picks_payload",
    "kst_seconds",
    "today_kst",
]
for name in required_helpers:
    if name not in s:
        raise SystemExit("REQUIRED_HELPER_MISSING:"+name)

# 1) Restore only the missing API route. The underlying opening-shakeout engine
# is already present; this adds no selection/scoring logic.
opening_route="@app.get('/api/opening-shakeout-reversal')"
if opening_route not in s:
    anchor="@app.get('/api/close-picks')"
    if anchor not in s:
        raise SystemExit("CLOSE_PICKS_ROUTE_ANCHOR_NOT_FOUND")
    block="""@app.get('/api/opening-shakeout-reversal')
async def opening_shakeout_api():
    snap=_snapshot_for_display()
    if snap and isinstance(snap.get('opening_shakeout'),dict):
        out=_held_snapshot_payload_current_version(snap['opening_shakeout'])
        out['screen_hold']=screen_hold_status(snap)
        return out
    out=_build_opening_shakeout_payload()
    out['screen_hold']=screen_hold_status()
    return out

"""
    s=s.replace(anchor,block+anchor,1)
    print("OPENING_ROUTE_ACTION=RESTORED")
else:
    print("OPENING_ROUTE_ACTION=ALREADY_PRESENT")

# 2) Fix presentation bug: held EOD snapshot must not keep yesterday's
# next-day picks visible after the designed 08:50 handoff.
#
# Official live close picks remain controlled by _build_close_picks_payload().
pattern=r"""@app\.get\('/api/close-picks'\)\nasync def close_picks_api\(\):\n(?:    .*\n)+?(?=\n@app\.get\('/api/close-smart-money'\))"""
m=re.search(pattern,s)
if not m:
    raise SystemExit("CLOSE_PICKS_API_BLOCK_NOT_FOUND")

replacement="""@app.get('/api/close-picks')
async def close_picks_api():
    # UI-only freshness gate:
    # - previous close picks may be held through next trading day 08:50
    # - after 08:50, never let a held screen snapshot resurrect yesterday's list
    # - same-day 19:30~20:00 close candidates are still produced by the existing
    #   _build_close_picks_payload() logic unchanged.
    sec=kst_seconds()
    d=STATE.next_day_picks or {'rows':[]}
    held_close_allowed=bool(
        str(d.get('effective_day') or '')==today_kst()
        and sec < 8*3600+50*60
    )

    snap=_snapshot_for_display() if held_close_allowed else None
    if snap and isinstance(snap.get('close_picks'),dict):
        out=_held_snapshot_payload_current_version(snap['close_picks'])
        out['screen_hold']=screen_hold_status(snap)
        out['premarket_active']=False
        out['held_until']='08:50'
        return out

    out=_build_close_picks_payload()
    out['screen_hold']=screen_hold_status()
    out['held_until']='08:50'
    if sec >= 8*3600+50*60 and str(d.get('effective_day') or '')==today_kst():
        out['stale_previous_close_hidden']=True
    return out
"""

s=s[:m.start()]+replacement+s[m.end():]

# Parse and verify protected core functions are byte-identical.
tree2=ast.parse(s)
for name,h in before.items():
    h2=hashlib.sha256(fn_text(s,tree2,name).encode()).hexdigest()
    if h2!=h:
        raise SystemExit("PROTECTED_FUNCTION_CHANGED:"+name)

assert s.count("@app.get('/api/opening-shakeout-reversal')")==1
assert s.count("@app.get('/api/close-picks')")==1
assert "stale_previous_close_hidden" in s
assert "held_close_allowed" in s

p.write_text(s,encoding="utf-8")
compile(s,str(p),"exec")

print("PATCH=PASS")
print("PROTECTED_TRADING_FUNCTION_HASH_GATE=PASS")
print("CLOSE_PICK_SELECTION_LOGIC=UNCHANGED")
print("CLOSE_PICK_DISPLAY_CUTOFF=08:50")
print("OPENING_ROUTE_COUNT=1")
PY

echo "=== PATCH ==="
python3 "$PATCHER" "$NEW"
python3 -m py_compile "$NEW"
echo "PYTHON_COMPILE=PASS"

echo "=== INSTALL ==="
sudo docker cp "$NEW" "$APP:/app/app/main.py"
sudo docker restart "$APP" >/dev/null

echo "=== READY ==="
READY=0
for i in $(seq 1 20); do
  CODE="$(curl -sS --max-time 2 -o /dev/null -w '%{http_code}' http://127.0.0.1:3200/api/health || true)"
  echo "READY $i health=$CODE"
  if [[ "$CODE" == "200" ]]; then READY=1; break; fi
  sleep 1
done
[[ "$READY" == "1" ]] || { echo "READY_GATE=FAIL" >&2; exit 1; }
echo "READY_GATE=PASS"

echo "=== ROUTE TESTS ==="
OPEN_CODE="$(curl -sS --max-time 3 -o /tmp/opening.json -w '%{http_code}' http://127.0.0.1:3200/api/opening-shakeout-reversal || true)"
CLOSE_CODE="$(curl -sS --max-time 3 -o /tmp/closepicks.json -w '%{http_code}' http://127.0.0.1:3200/api/close-picks || true)"
HEALTH_CODE="$(curl -sS --max-time 3 -o /dev/null -w '%{http_code}' http://127.0.0.1:3200/api/health || true)"
NOVA_CODE="$(curl -sS --max-time 3 -o /dev/null -w '%{http_code}' http://127.0.0.1:3200/api/nova || true)"
echo "OPENING_ROUTE_HTTP=$OPEN_CODE"
echo "CLOSE_PICKS_HTTP=$CLOSE_CODE"
echo "HEALTH_HTTP=$HEALTH_CODE"
echo "NOVA_HTTP=$NOVA_CODE"
[[ "$OPEN_CODE" == "200" && "$CLOSE_CODE" == "200" && "$HEALTH_CODE" == "200" && "$NOVA_CODE" == "200" ]] || {
  echo "ROUTE_GATE=FAIL" >&2
  exit 1
}
echo "ROUTE_GATE=PASS"

echo "=== CLOSE PICKS PAYLOAD ==="
python3 - <<'PY'
import json
p='/tmp/closepicks.json'
x=json.load(open(p))
print("visible=",x.get("visible"))
print("count=",x.get("count"))
print("source_day=",x.get("source_day"))
print("effective_day=",x.get("effective_day"))
print("preview=",x.get("preview"))
print("held_until=",x.get("held_until"))
print("stale_previous_close_hidden=",x.get("stale_previous_close_hidden"))
PY

echo "=== SHORT SOAK ==="
PASS=0
for i in $(seq 1 15); do
  CODE="$(curl -sS --max-time 2 -o /dev/null -w '%{http_code}' http://127.0.0.1:3200/api/health || true)"
  [[ "$CODE" == "200" ]] && PASS=$((PASS+1))
  echo "SOAK $i code=$CODE pass=$PASS"
  sleep 1
done
[[ "$PASS" -ge 14 ]] || { echo "SOAK_GATE=FAIL" >&2; exit 1; }
echo "SOAK_GATE=PASS"

echo "=== PUBLIC CHECK ==="
ROOT="$(curl -k -sS --max-time 3 -o /dev/null -w '%{http_code}' https://3-38-25-20.nip.io/ || true)"
STATIC="$(curl -k -sS --max-time 3 -o /dev/null -w '%{http_code}' https://3-38-25-20.nip.io/static/nova.js || true)"
echo "PUBLIC_ROOT=$ROOT"
echo "PUBLIC_STATIC=$STATIC"
if [[ "$ROOT" != "200" || "$STATIC" != "200" ]]; then
  sudo docker restart kiwoom-caddy >/dev/null 2>&1 || true
  sleep 3
  ROOT="$(curl -k -sS --max-time 3 -o /dev/null -w '%{http_code}' https://3-38-25-20.nip.io/ || true)"
  STATIC="$(curl -k -sS --max-time 3 -o /dev/null -w '%{http_code}' https://3-38-25-20.nip.io/static/nova.js || true)"
  echo "PUBLIC_ROOT_AFTER_RECOVERY=$ROOT"
  echo "PUBLIC_STATIC_AFTER_RECOVERY=$STATIC"
fi

echo "=== MORNING FLOW CONTRACT CHECK ==="
sudo docker exec "$APP" python3 - <<'PY'
from pathlib import Path
import re
s=Path('/app/app/main.py').read_text(encoding='utf-8')
checks={
  'OPENING_09_00': bool(re.search(r"OPENING_SHAKEOUT_START_SECONDS\s*=\s*9\s*\*\s*3600",s)),
  'OPENING_BUY_END_10_00': bool(re.search(r"OPENING_BUY_END_SECONDS\s*=\s*10\s*\*\s*3600",s)),
  'PREMARKET_RERANK': ('premarket_rank' in s or 'evaluate_premarket_picks' in s),
  'PRIOR_CLOSE': 'PRIOR_CLOSE' in s,
  'TODAY_NEW': 'TODAY_NEW' in s,
  'OPENING_ROUTE': "@app.get('/api/opening-shakeout-reversal')" in s,
  'CLOSE_PICK_08_50_DISPLAY_GATE': 'held_close_allowed' in s and 'stale_previous_close_hidden' in s,
}
for k,v in checks.items():
    print(f'{k}={"PASS" if v else "FAIL"}')
if not all(checks.values()):
    raise SystemExit('MORNING_FLOW_CONTRACT_FAIL')
print('MORNING_FLOW_CONTRACT=PASS')
PY

echo "=== SNAPSHOT ==="
IMAGE="quant-nova:2.4.22-api-presentation-restore-${STAMP}"
sudo docker commit "$APP" "$IMAGE" >/dev/null
echo "SNAPSHOT_IMAGE=$IMAGE"

echo "=== FINAL ==="
echo "OPENING_SHAKEOUT_ROUTE=RESTORED_OR_VERIFIED"
echo "PREVIOUS_CLOSE_PICK_DISPLAY=HIDDEN_AFTER_08:50"
echo "PREVIOUS_CLOSE_INTERNAL_STATE=PRESERVED_FOR_09:00_COMPETITION"
echo "09:00_POOL=PRIOR_CLOSE+TODAY_NEW"
echo "09:00-09:30=SHAKEOUT_WATCH"
echo "09:10-10:00=REVERSAL_EARLY_TO_BUY_READY"
echo "CLOSE_PICK_DATA=RETAINED_FOR_HISTORY_AND_EVIDENCE"
echo "SELECTION_LOGIC=UNCHANGED"
echo "BUY_THRESHOLDS=UNCHANGED"
echo "SCORING_FORMULA=UNCHANGED"
echo "CANDIDATE_SELECTION=UNCHANGED"
echo "WS_CONTRACT=UNCHANGED"
echo "=== $REV PASS ==="
SUCCESS=1
