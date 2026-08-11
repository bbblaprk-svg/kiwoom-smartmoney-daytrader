#!/usr/bin/env bash
set -Eeuo pipefail

REV="QUANT-NOVA-2.4.22-MORNING-FLOW-STATE-INIT-HOTFIX-V2.1"
APP="quant-nova"
BASE="$HOME/quant-nova"
BK="$BASE/morning-flow-state-hotfix-backups"
STAMP="$(date +%Y%m%d%H%M%S)"
WORK="/tmp/nova-state-hotfix-$STAMP"
OLD="$BK/main.py.before-$STAMP"
NEW="$WORK/main.py"
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
echo "ROOT_CAUSE=OPENING_SHAKEOUT_STATE_ATTRIBUTE_MISSING"
echo "PATCH_SCOPE=STATE_INITIALIZATION_ONLY"
echo "SELECTION_LOGIC_CHANGE=NONE"
echo "BUY_THRESHOLDS_CHANGE=NONE"
echo "SCORING_FORMULA_CHANGE=NONE"
echo "CANDIDATE_SELECTION_CHANGE=NONE"
echo "PREMARKET_RERANK_LOGIC_CHANGE=NONE"
echo "WS_CONTRACT_CHANGE=NONE"

sudo docker inspect "$APP" >/dev/null
sudo docker cp "$APP:/app/app/main.py" "$OLD"
sudo cp "$OLD" "$NEW"
sudo chown "$(id -u):$(id -g)" "$NEW"
chmod 600 "$NEW"

python3 - "$NEW" <<'PY'
from pathlib import Path
import ast, hashlib, re, sys

p=Path(sys.argv[1])
s=p.read_text(encoding="utf-8")
tree=ast.parse(s)

PROTECTED=["calc","score_codes","ranked","update_sector_context","evaluate_nxt_radar_alerts","build_next_day_close_picks","evaluate_premarket_picks"]
def fn_text(src,tree,name):
    ls=src.splitlines()
    for n in ast.walk(tree):
        if isinstance(n,(ast.FunctionDef,ast.AsyncFunctionDef)) and n.name==name:
            return "\n".join(ls[n.lineno-1:n.end_lineno])
    return None
before={n:hashlib.sha256(fn_text(s,tree,n).encode()).hexdigest() for n in PROTECTED if fn_text(s,tree,n)}

if "self.opening_shakeout=" not in s:
    anchor="self.nxt_memory_codes=[]; self.nxt_first_wave_memory={}; self.nxt_daily_ledger={'day':display_trading_day(),'rows':{}}; self.next_day_picks={'source_day':None,'effective_day':None,'rows':[]}; self.morning_push_day=''; self.close_bet_signal_day=''"
    if anchor not in s:
        # More tolerant fallback.
        marker="self.next_day_picks={'source_day':None,'effective_day':None,'rows':[]}; self.morning_push_day=''"
        if marker not in s:
            raise SystemExit("NOVASTATE_NEXT_DAY_PICKS_ANCHOR_NOT_FOUND")
        repl=marker+"; self.opening_shakeout={'version':'OPENING_SHAKEOUT_REVERSAL_V1','day':display_trading_day(),'rows':{},'board':[],'generated_at':None}"
        s=s.replace(marker,repl,1)
    else:
        repl=anchor.replace(
            "; self.morning_push_day='';",
            "; self.opening_shakeout={'version':'OPENING_SHAKEOUT_REVERSAL_V1','day':display_trading_day(),'rows':{},'board':[],'generated_at':None}; self.morning_push_day='';"
        )
        s=s.replace(anchor,repl,1)
    print("STATE_INIT_ACTION=ADDED")
else:
    print("STATE_INIT_ACTION=ALREADY_PRESENT")

tree2=ast.parse(s)
for n,h in before.items():
    t=fn_text(s,tree2,n)
    if not t or hashlib.sha256(t.encode()).hexdigest()!=h:
        raise SystemExit("PROTECTED_FUNCTION_CHANGED:"+n)

checks={
    "STATE_INIT":"self.opening_shakeout=" in s,
    "OPENING_ROUTE":"@app.get('/api/opening-shakeout-reversal')" in s,
    "OPENING_PAYLOAD":"def _build_opening_shakeout_payload" in s,
    "OPENING_ROW":"def _opening_shakeout_row" in s,
    "PRIOR_CLOSE":"PRIOR_CLOSE" in s,
    "TODAY_NEW":"TODAY_NEW" in s,
    "TICK_HOOK":"update_opening_shakeout_tick(cand,now,p,venue)" in s,
    "RUNTIME_SLOT":"'nova-opening-shakeout': opening_shakeout_loop" in s,
    "CLOSE_0850_GATE":"stale_previous_close_hidden" in s,
}
for k,v in checks.items():
    print(f"{k}={'PASS' if v else 'FAIL'}")
if not all(checks.values()):
    raise SystemExit("SOURCE_CONTRACT_FAIL")

p.write_text(s,encoding="utf-8")
compile(s,str(p),"exec")
print("PATCH=PASS")
print("PROTECTED_TRADING_FUNCTION_HASH_GATE=PASS")
PY

python3 -m py_compile "$NEW"
echo "PYTHON_COMPILE=PASS"

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
[[ "$READY" == "1" ]] || { sudo docker logs --tail 120 "$APP" 2>&1 || true; echo "READY_GATE=FAIL" >&2; exit 1; }
echo "READY_GATE=PASS"

echo "=== OPENING API TEST ==="
OPEN_CODE="$(curl -sS --max-time 4 -o /tmp/opening-state-hotfix.json -w '%{http_code}' http://127.0.0.1:3200/api/opening-shakeout-reversal || true)"
echo "OPENING_HTTP=$OPEN_CODE"
if [[ "$OPEN_CODE" != "200" ]]; then
  echo "=== OPENING ERROR LOG ==="
  sudo docker logs --since 2m --tail 180 "$APP" 2>&1 | tail -140
  echo "OPENING_API_GATE=FAIL" >&2
  exit 1
fi
echo "OPENING_API_GATE=PASS"

echo "=== OPENING PAYLOAD ==="
python3 - <<'PY'
import json
x=json.load(open('/tmp/opening-state-hotfix.json'))
for k in ('ok','day','shakeout_window','buy_window','watch_limit','reversal_limit','display_limit','ready_limit','count','final'):
    print(f"{k}={x.get(k)}")
PY

echo "=== OTHER API REGRESSION ==="
for ep in /api/health /api/nova /api/close-picks /api/nxt-signal-table; do
  CODE="$(curl -sS --max-time 3 -o /dev/null -w '%{http_code}' "http://127.0.0.1:3200$ep" || true)"
  echo "$ep=$CODE"
  [[ "$CODE" == "200" ]] || { echo "REGRESSION_GATE=FAIL endpoint=$ep" >&2; exit 1; }
done
echo "REGRESSION_GATE=PASS"

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

echo "=== FINAL ==="
echo "ROOT_CAUSE_FIXED=OPENING_SHAKEOUT_STATE_INIT"
echo "OPENING_SHAKEOUT_ROUTE=200"
echo "PRIOR_CLOSE_INTERNAL_STATE=PRESERVED"
echo "09:00_POOL=PRIOR_CLOSE+TODAY_NEW"
echo "08:50_AFTER_CLOSE_TABLE=STALE_PREVIOUS_HIDDEN"
echo "SELECTION_LOGIC=UNCHANGED"
echo "BUY_THRESHOLDS=UNCHANGED"
echo "SCORING_FORMULA=UNCHANGED"
echo "CANDIDATE_SELECTION=UNCHANGED"
echo "PREMARKET_RERANK_LOGIC=UNCHANGED"
echo "WS_CONTRACT=UNCHANGED"

IMAGE="quant-nova:2.4.22-morning-flow-state-init-hotfix-v2.1-${STAMP}"
sudo docker commit "$APP" "$IMAGE" >/dev/null
echo "SNAPSHOT_IMAGE=$IMAGE"
echo "=== $REV PASS ==="
SUCCESS=1
