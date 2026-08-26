#!/usr/bin/env bash
set -Eeuo pipefail

APP="${NOVA_APP_CONTAINER:-quant-nova}"
EXPECTED_VERSION="NOVA-3.3.5-R492-MARKET-INDEX-VERIFY1"
EXPECTED_BASE_SHA="0d2f300af673c7187ae51b3ec9acc0e13e1dfaa6211d7b76a4f721130df632fc"
PATCH_SHA="cb1021622ffed821191787913fc8be441f58dd3bd54d7f76505cd271f903c81c"
STAMP="$(date +%Y%m%d-%H%M%S)"
DAY="$(TZ=Asia/Seoul date +%Y%m%d)"
WORK="/tmp/nova-entry-state-fix-${STAMP}"
BACKUP="${APP}-before-entry-state-fix-${STAMP}"
NEW_IMAGE="quant-nova:r492-photo-entry-state-fix-${STAMP}"
LOG="${WORK}.log"
mkdir -p "$WORK"
exec > >(tee -a "$LOG") 2>&1

rollback() {
  set +e
  echo
  echo "===== AUTO ROLLBACK ====="
  docker rm -f "$APP" >/dev/null 2>&1 || true
  if docker inspect "$BACKUP" >/dev/null 2>&1; then
    docker rename "$BACKUP" "$APP" >/dev/null 2>&1 || true
    docker start "$APP" >/dev/null 2>&1 || true
  fi
  echo "RESULT=ROLLED_BACK"
  echo "LOG=$LOG"
}
trap 'rc=$?; if [ "$rc" -ne 0 ]; then rollback; fi; exit "$rc"' EXIT

echo "===== 0. LOCK TO USER PHOTO BASELINE ====="
docker inspect "$APP" >/dev/null
BASE_IMAGE_ID="$(docker inspect -f '{{.Image}}' "$APP")"
BASE_IMAGE_REF="$(docker inspect -f '{{.Config.Image}}' "$APP")"
VERSION="$(docker image inspect "$BASE_IMAGE_ID" -f '{{index .Config.Labels "org.opencontainers.image.version"}}' 2>/dev/null || true)"
BASE_SHA="$(docker image inspect "$BASE_IMAGE_ID" -f '{{index .Config.Labels "io.quantnova.embedded_source_sha256"}}' 2>/dev/null || true)"
echo "BASE_IMAGE=$BASE_IMAGE_REF"
echo "VERSION=$VERSION"
echo "BASE_SOURCE_SHA=$BASE_SHA"
[ "$VERSION" = "$EXPECTED_VERSION" ] || { echo "FAIL wrong version"; exit 2; }
[ "$BASE_SHA" = "$EXPECTED_BASE_SHA" ] || { echo "FAIL wrong photo-baseline source"; exit 3; }

echo
echo "===== 1. PROVE THE SOURCE DEFECT BEFORE MUTATION ====="
docker exec "$APP" python -c '
from pathlib import Path
p=Path("/app/app/signal/policy.py")
s=p.read_text()
anchor="now=time.time();v=c.venue_state[venue];lane=v.entry;lane.state=state;lane.state_since=now"
print("BUGGY_SAME_STATE_SET_PRESENT=",anchor in s)
if anchor not in s: raise SystemExit(10)
'

echo
echo "===== 2. CURRENT ENTRY_STATE WRITE RATE / DISTRIBUTION ====="
read_entry_count() {
  docker exec "$APP" python -c '
import sqlite3
from app.config import SETTINGS
day="'"$DAY"'"
db=SETTINGS.data_dir/"signal_wal.sqlite3"
c=sqlite3.connect("file:"+str(db)+"?mode=ro",uri=True,timeout=10)
n=c.execute("select count(*) from important_history where day=? and kind=?",(day,"ENTRY_STATE")).fetchone()[0]
print(n)
c.close()
'
}
docker exec "$APP" python -c '
import sqlite3,json
from app.config import SETTINGS
day="'"$DAY"'"
db=SETTINGS.data_dir/"signal_wal.sqlite3"
c=sqlite3.connect("file:"+str(db)+"?mode=ro",uri=True,timeout=10)
print("ENTRY_STATE_TOTAL_TODAY=",c.execute("select count(*) from important_history where day=? and kind=?",(day,"ENTRY_STATE")).fetchone()[0])
print("ENTRY_STATE_BY_STATE=")
for st,n in c.execute("""select json_extract(payload,'$.state'),count(*) from important_history
                         where day=? and kind=? group by 1 order by 2 desc limit 20""",(day,"ENTRY_STATE")):
    print(st,n)
c.close()
'
PRE1="$(read_entry_count)"
sleep 15
PRE2="$(read_entry_count)"
PRE_DELTA=$((PRE2-PRE1))
echo "ENTRY_STATE_DELTA_15S_BEFORE=$PRE_DELTA"

echo
echo "===== 3. CREATE EXACT ONE-FUNCTION PATCH ====="
cat > "$WORK/policy.py" <<'PYFILE'
from __future__ import annotations
import time
from dataclasses import dataclass
from app.domain import Candidate,SignalEvent,SignalTrack,Venue,EntryLane
from app.runtime.clock import trade_day
from app.runtime.state import RuntimeState
from app.storage.wal import DurableJournal
from app.config import SETTINGS

# Frozen ENTRY_V18 numeric policy. Runtime refactoring must not silently change these values.
ENTRY_PRESSURE_SCORE=62;ENTRY_HOLD_SEC=8;ENTRY_PULLBACK_MIN=.12;ENTRY_PULLBACK_MAX=2.0;ENTRY_REACCEL_SEC=3
ENTRY_COOLDOWN_SEC=600;ENTRY_REENTRY_MIN_SEC=420;ENTRY_REENTRY_GAIN_PCT=1.20;ENTRY_MAX_DAILY=2
ENTRY_MAX_VWAP_GAP=1.50;ENTRY_MAX_IMPULSE=2.50;ENTRY_MIN_BUY_PRESSURE=56;ENTRY_MIN_ALGO_PERSIST=55
PULLBACK_CONFIRM_SCORE=58;PULLBACK_CONFIRM_BUY_PRESSURE=58;PULLBACK_CONFIRM_ACCEL=1.20
DIRECT_SCORE=75;DIRECT_HOLD_SEC=6;DIRECT_CONFIRM_SEC=3;DIRECT_MIN_BUY_PRESSURE=61;DIRECT_MIN_ALGO_PERSIST=60
DIRECT_MIN_ACCEL=1.65;DIRECT_MIN_BREAKOUT=.20;DIRECT_MIN_IMPULSE=.25;DIRECT_MAX_IMPULSE=1.80;DIRECT_MAX_VWAP_GAP=1.10

@dataclass(slots=True,frozen=True)
class TickSource:
    venue:Venue;price:float;rate:float;recv_seq:int;exchange_time:str;server_receive_time:float

@dataclass(slots=True)
class BuyIntent:
    route:str;reasons:list[str];source:TickSource;metrics:dict;created_at:float

class EntryPolicy:
    """Venue-isolated ENTRY_V18 state machine. No I/O occurs in `advance`."""
    def __init__(self,state:RuntimeState,journal:DurableJournal):self.state=state;self.journal=journal

    @staticmethod
    def source(c:Candidate,venue:Venue)->TickSource:
        v=c.venue_state[venue];return TickSource(venue,v.last_price,v.last_rate,v.last_recv_seq,v.last_exchange_time,v.last_tick_at)

    @staticmethod
    def hard_reject(c:Candidate,m:dict)->list[str]:
        reasons=[];rate=float(m.get('rate') or 0);imp=float(m.get('impulse_60s') or 0);vgap=float(m.get('micro_vwap_gap') or 0);one=float(m.get('one_tick_ratio') or 0)
        if rate>12:reasons.append('당일 상승률 과열')
        if imp>ENTRY_MAX_IMPULSE:reasons.append('1분 급등 과열')
        if vgap>ENTRY_MAX_VWAP_GAP:reasons.append('Micro VWAP 추격구간')
        if float(m.get('session_vwap_gap') or 0)>max(2.0,ENTRY_MAX_VWAP_GAP+.5):reasons.append('Session VWAP 과이격')
        if one>.45:reasons.append('단일체결 편중')
        if bool(c.metrics.get('sector_overheat')):reasons.append('섹터 과열')
        if float(c.metrics.get('event_signal') or 0)<=-5:reasons.append('중대 악재 공시/뉴스')
        if not bool(m.get('continuity_ok',True)):reasons.append('실시간 연속성 미복구')
        return reasons

    @staticmethod
    def _smart_ok(m:dict)->tuple[bool,str]:
        if bool(m.get('program_fresh')):
            if float(m.get('program_delta') or 0)<0 and not bool(m.get('smart_money_realtime_proxy_surge')):return False,'프로그램 수급 둔화'
            return True,'프로그램/실시간 수급 확인'
        if bool(m.get('smart_money_realtime_proxy_surge')) and float(m.get('buy_pressure') or 0)>=60:return True,'실시간 스마트머니 proxy 확인'
        return False,'수급 freshness/연속성 부족'

    def _set(self,c:Candidate,venue:Venue,state:str,reason:str=''):
        now=time.time();v=c.venue_state[venue];lane=v.entry
        # A same-state evaluation is not a state transition.  Do not reset state_since or
        # persist another ENTRY_STATE row on every policy tick; only refresh the display reason.
        if lane.state==state:
            v.metrics['entry_reason']=reason
            return
        lane.state=state;lane.state_since=now;v.metrics['entry_reason']=reason
        if state=='DISCOVERY':lane.pressure_started_at=lane.pressure_peak=lane.pullback_low=lane.reaccel_started_at=lane.reaccel_start_price=lane.direct_started_at=lane.direct_start_price=0
        elif state=='PRESSURE_BUILD':lane.pressure_started_at=now;lane.pressure_peak=v.last_price;lane.pullback_low=0;lane.reaccel_started_at=0;lane.direct_started_at=0
        elif state=='PULLBACK':lane.pullback_low=v.last_price
        elif state=='REACCEL':lane.reaccel_started_at=now;lane.reaccel_start_price=v.last_price
        elif state=='DIRECT_ARM':lane.direct_started_at=now;lane.direct_start_price=v.last_price
        c.append_history('ENTRY_STATE',state,v.last_price,reason,venue,now)

    def advance(self,c:Candidate,venue:Venue,session_active:bool,src:TickSource)->BuyIntent|None:
        now=time.time();v=c.venue_state[venue];m=v.metrics;lane=v.entry;price=src.price
        if not price:return None
        age_ms=(now-src.server_receive_time)*1000 if src.server_receive_time else 10**12
        if not session_active or age_ms>3500 or not bool(m.get('fresh')):
            if lane.state not in ('BUY','COOLDOWN'):self._set(c,venue,'DISCOVERY','세션/실체결 비활성')
            m.update({'entry_state':lane.state,'entry_ready':False,'entry_route':''});return None
        score=v.score;bp=float(m.get('buy_pressure') or 0);acc=float(m.get('volume_accel') or 1);algo=float(m.get('algo_persistence') or 0);vgap=float(m.get('micro_vwap_gap') or 0);sgap=float(m.get('session_vwap_gap') or 0);imp=float(m.get('impulse_60s') or 0);br=float(m.get('micro_breakout') or 0)
        hard=self.hard_reject(c,m);smart_ok,smart_note=self._smart_ok(m);direct_ok=smart_ok and (bool(m.get('program_fresh')) or (bool(m.get('dual_venue')) and bp>=64))
        if lane.cooldown_until>now:
            if lane.state!='BUY' or now-lane.state_since>=30:lane.state='COOLDOWN'
            m.update({'entry_state':lane.state,'entry_reason':'재신호 보호구간','entry_ready':False,'cooldown_sec':round(lane.cooldown_until-now)});return None
        if lane.state in ('BUY','COOLDOWN'):self._set(c,venue,'DISCOVERY')
        if lane.buy_count_today>=ENTRY_MAX_DAILY:lane.state='COOLDOWN';m.update({'entry_state':'COOLDOWN','entry_reason':'일일 BUY 상한 도달','entry_ready':False});return None
        if lane.state=='REJECTED':
            if now-lane.state_since<20:m.update({'entry_state':'REJECTED','entry_ready':False});return None
            self._set(c,venue,'DISCOVERY')
        pull=((lane.pressure_peak-price)/lane.pressure_peak*100) if lane.pressure_peak else 0;recovery=((price/lane.pullback_low-1)*100) if lane.pullback_low else 0;intent=None
        if lane.state=='DISCOVERY':
            if score>=ENTRY_PRESSURE_SCORE and bp>=53 and algo>=50 and not hard:self._set(c,venue,'PRESSURE_BUILD','압력 지속성 확인 중')
        elif lane.state=='PRESSURE_BUILD':
            lane.pressure_peak=max(lane.pressure_peak or price,price);pull=((lane.pressure_peak-price)/lane.pressure_peak*100) if lane.pressure_peak else 0;held=now-lane.pressure_started_at if lane.pressure_started_at else 0
            direct_arm=bool(m.get('volume_accel_ready')) and held>=DIRECT_HOLD_SEC and score>=DIRECT_SCORE and bp>=DIRECT_MIN_BUY_PRESSURE and acc>=DIRECT_MIN_ACCEL and algo>=DIRECT_MIN_ALGO_PERSIST and br>=DIRECT_MIN_BREAKOUT and DIRECT_MIN_IMPULSE<=imp<=DIRECT_MAX_IMPULSE and .05<=vgap<=DIRECT_MAX_VWAP_GAP and -.10<=sgap<=1.60 and pull<ENTRY_PULLBACK_MIN and src.rate<=9.5 and direct_ok and not hard
            if hard:self._set(c,venue,'REJECTED',' · '.join(hard[:2]))
            elif direct_arm:self._set(c,venue,'DIRECT_ARM','DIRECT 수급/모멘텀 동조')
            elif score<52 or bp<48:self._set(c,venue,'DISCOVERY','압력 소멸')
            elif held>=ENTRY_HOLD_SEC and ENTRY_PULLBACK_MIN<=pull<=ENTRY_PULLBACK_MAX and score>=54:self._set(c,venue,'PULLBACK','건강한 눌림 확인')
            elif held>120:self._set(c,venue,'REJECTED','눌림·직접점화 모두 미확인')
        elif lane.state=='PULLBACK':
            lane.pullback_low=min(lane.pullback_low or price,price);pull=((lane.pressure_peak-price)/lane.pressure_peak*100) if lane.pressure_peak else 0;recovery=((price/lane.pullback_low-1)*100) if lane.pullback_low else 0
            if hard or pull>ENTRY_PULLBACK_MAX or score<46:self._set(c,venue,'REJECTED','눌림 실패/과열' if not hard else ' · '.join(hard[:2]))
            elif recovery>=.15 and bp>=ENTRY_MIN_BUY_PRESSURE and acc>=1.15 and algo>=ENTRY_MIN_ALGO_PERSIST and -.20<=vgap<=1.35 and -.35<=sgap<=1.85 and imp<=2.20 and smart_ok:self._set(c,venue,'REACCEL','눌림 후 재가속 확인 중')
        elif lane.state=='REACCEL':
            if hard or score<54 or (lane.pullback_low and price<lane.pullback_low*.998):self._set(c,venue,'PULLBACK','재가속 실패')
            else:
                confirm=now-lane.reaccel_started_at>=ENTRY_REACCEL_SEC and price>=lane.reaccel_start_price*1.0004 and score>=PULLBACK_CONFIRM_SCORE and bp>=PULLBACK_CONFIRM_BUY_PRESSURE and acc>=PULLBACK_CONFIRM_ACCEL and algo>=ENTRY_MIN_ALGO_PERSIST and -.10<=vgap<=1.35 and -.25<=sgap<=1.85 and imp<=2.20 and smart_ok
                if confirm:intent=BuyIntent('PULLBACK_REACCEL',['PULLBACK BUY · 눌림 후 재가속',f'공격매수 {bp:.0f}% · 지속 {algo:.0f}%',smart_note]+v.reasons,src,dict(m),now)
        elif lane.state=='DIRECT_ARM':
            elapsed=now-lane.direct_started_at if lane.direct_started_at else 0
            maintain=bool(m.get('volume_accel_ready')) and score>=72 and bp>=59 and acc>=1.45 and algo>=58 and br>=.15 and DIRECT_MIN_IMPULSE*.6<=imp<=DIRECT_MAX_IMPULSE and -.02<=vgap<=1.15 and -.10<=sgap<=1.70 and direct_ok and not hard and src.rate<=10
            if not maintain or (lane.direct_start_price and price<lane.direct_start_price*.997):self._set(c,venue,'PRESSURE_BUILD','DIRECT 점화 확인 실패')
            elif elapsed>=DIRECT_CONFIRM_SEC and price>=lane.direct_start_price*1.0008:intent=BuyIntent('DIRECT_IGNITION',['DIRECT IGNITION BUY · 눌림 없는 초강세',f'가속 {acc:.1f}x · 공격매수 {bp:.0f}% · 지속 {algo:.0f}%','DIRECT 수급 동조']+v.reasons,src,dict(m),now)
        m.update({'entry_state':lane.state,'entry_ready':bool(intent) or lane.state in ('REACCEL','DIRECT_ARM','BUY'),'entry_route':intent.route if intent else ('DIRECT_IGNITION' if lane.state=='DIRECT_ARM' else 'PULLBACK_REACCEL' if lane.state in ('PULLBACK','REACCEL') else lane.last_buy_route if lane.state in ('BUY','COOLDOWN') else ''),'pressure_hold_sec':round(now-lane.pressure_started_at,1) if lane.pressure_started_at else 0,'pullback_pct':round(pull,3),'recovery_pct':round(recovery,3),'cooldown_sec':max(0,round(lane.cooldown_until-now)) if lane.cooldown_until else 0})
        return intent

    def wal_record(self,c:Candidate,intent:BuyIntent)->dict:
        s=intent.source;day=trade_day();signal_at=s.server_receive_time or intent.created_at;signal_id=f'{day}:{s.venue.value}:{c.code}:BUY:{s.recv_seq}';m=intent.metrics
        return {'event':'BUY_CONFIRMED','policy':'ENTRY_V18_TRUTH_GUARD_MAX_PROFIT','runtime':SETTINGS.version,'signal_id':signal_id,'day':day,'trade_day':day,'code':c.code,'symbol':c.code,'name':c.name,'venue':s.venue.value,'stage':'BUY','route':intent.route,'signal_time':signal_at,'decision_time':intent.created_at,'signal_price':s.price,'current_price_at_signal':s.price,'signal_change_rate':s.rate,'recv_seq':s.recv_seq,'exchange_time':s.exchange_time,'server_receive_time':s.server_receive_time,'reasons':intent.reasons[:5],'metrics':m,'volume_state':m.get('cum_volume'),'turnover_state':m.get('cum_turnover'),'vwap_state':m.get('session_vwap'),'rvol_state':m.get('rvol_intraday'),'execution_strength_state':m.get('execution_strength'),'smart_money_state':{'score':m.get('smart_money_realtime_proxy_score'),'surge':m.get('smart_money_realtime_proxy_surge'),'label':m.get('smart_money_proxy_label')},'valid_repeat_count':c.valid_repeat_count+1,'origin':c.origin.value}

    def apply_committed(self,c:Candidate,intent:BuyIntent,record:dict):
        s=intent.source;now=intent.created_at;signal_at=float(record.get('signal_time') or s.server_receive_time or now);v=c.venue_state[s.venue];lane=v.entry
        sig=SignalEvent(record['signal_id'],record['day'],c.code,c.name,s.venue,'BUY',intent.route,signal_at,s.price,s.rate,s.recv_seq,s.exchange_time,s.server_receive_time,intent.reasons[:5],intent.metrics,lane.buy_count_today+1,c.origin)
        lane.buy_count_today+=1;lane.valid_repeat_count+=1;lane.last_buy_at=now;lane.last_buy_price=s.price;lane.last_buy_route=intent.route;lane.cooldown_until=now+ENTRY_COOLDOWN_SEC;lane.state='BUY';lane.state_since=now
        c.last_buy_at=signal_at;c.last_buy_price=s.price;c.last_buy_route=intent.route;c.last_buy_venue=s.venue;c.live_track_pin=True
        if c.first_signal is None:c.first_signal=sig
        c.last_signal=sig;c.signal_tracks.append(SignalTrack(sig.signal_id,s.venue,s.price,signal_at,s.price,s.price,s.price,signal_at));c.signal_high=s.price;c.signal_low=s.price;c.buy_high=s.price;c.buy_low=s.price
        c.append_history('SIGNAL','BUY',s.price,' · '.join(intent.reasons[:3]),s.venue,signal_at);self.state.pinned_codes.add(c.code);c.refresh_aggregate()

PYFILE
ACTUAL_PATCH_SHA="$(sha256sum "$WORK/policy.py" | awk '{print $1}')"
echo "PATCH_SHA=$ACTUAL_PATCH_SHA"
[ "$ACTUAL_PATCH_SHA" = "$PATCH_SHA" ] || { echo "FAIL patch sha"; exit 4; }

cat > "$WORK/Dockerfile" <<EOF
FROM $BASE_IMAGE_ID
COPY policy.py /app/app/signal/policy.py
RUN python -m py_compile /app/app/signal/policy.py
RUN PYTHONPATH=/app python -m pytest -q /app/tests/test_core.py /app/tests/test_r49_signal_acceleration.py /app/tests/test_r492_safe_extension.py
LABEL io.quantnova.photo_baseline_patch="ENTRY_STATE_SAME_STATE_IDEMPOTENCE"
LABEL io.quantnova.photo_baseline_patch_sha256="$PATCH_SHA"
LABEL io.quantnova.photo_baseline_parent_sha256="$EXPECTED_BASE_SHA"
EOF

echo
echo "===== 4. BUILD + TEST PATCH IMAGE ====="
docker build --pull=false -t "$NEW_IMAGE" "$WORK"

echo
echo "===== 5. CAPTURE CURRENT RUNTIME CONTRACT EXACTLY ====="
docker inspect "$APP" > "$WORK/inspect.json"
docker inspect "$APP" -f '{{range .Config.Env}}{{println .}}{{end}}' > "$WORK/env.list"

python3 - "$WORK/inspect.json" "$WORK/env.list" "$WORK/run.args" "$NEW_IMAGE" <<'PY'
import json,sys
insp,envf,outf,image=sys.argv[1:]
o=json.load(open(insp))[0]; h=o.get("HostConfig") or {}; c=o.get("Config") or {}
a=["docker","run","-d","--name","quant-nova"]
if h.get("Init") is True: a+=["--init"]
hc=c.get("Healthcheck") or {}
if (hc.get("Test") or [])==["NONE"]: a+=["--no-healthcheck"]
net=h.get("NetworkMode") or ""
if net and net not in ("default","bridge"): a+=["--network",net]
rp=h.get("RestartPolicy") or {}; rn=rp.get("Name") or ""; mx=int(rp.get("MaximumRetryCount") or 0)
if rn and rn!="no": a+=["--restart",f"{rn}:{mx}" if rn=="on-failure" and mx else rn]
for m in o.get("Mounts") or []:
    typ=m.get("Type"); src=m.get("Source"); dst=m.get("Destination")
    if typ in ("bind","volume") and src and dst:
        spec=f"type={typ},src={src},dst={dst}"
        if not m.get("RW",True): spec+=",readonly"
        a+=["--mount",spec]
for line in open(envf,encoding="utf-8",errors="ignore"):
    line=line.rstrip("\n")
    if line:a+=["-e",line]
user=c.get("User") or ""
if user:a+=["--user",user]
wd=c.get("WorkingDir") or ""
if wd:a+=["--workdir",wd]
pb=h.get("PortBindings") or {}
for cp,bs in pb.items():
    for b in (bs or []):
        hp=str((b or {}).get("HostPort") or ""); hi=str((b or {}).get("HostIp") or "")
        if hp:a+=["-p",f"{hi+':' if hi else ''}{hp}:{cp.split('/')[0]}"]
a+=[image]
cmd=c.get("Cmd")
if cmd:a+=list(cmd)
open(outf,"wb").write(b"\0".join(x.encode() for x in a))
print("RUNTIME_CONTRACT_CAPTURED=1")
PY

echo
echo "===== 6. CUTOVER ====="
docker stop -t 15 "$APP" >/dev/null
docker rename "$APP" "$BACKUP"
python3 - "$WORK/run.args" <<'PY'
import sys,subprocess
a=[x.decode() for x in open(sys.argv[1],"rb").read().split(b"\0") if x]
subprocess.run(a,check=True)
PY

echo
echo "===== 7. VERIFY PATCH IS ACTIVE ====="
docker exec "$APP" python -c '
from pathlib import Path
s=Path("/app/app/signal/policy.py").read_text()
assert "if lane.state==state:" in s
assert "return" in s
print("PATCH_ACTIVE=1")
'

echo
echo "===== 8. WAIT FOR 3 CONSECUTIVE LIVEZ OK ====="
good=0
for i in $(seq 1 60); do
  set +e
  O="$(docker exec "$APP" python -c 'import json,time,urllib.request,sys;t=time.monotonic();j=json.load(urllib.request.urlopen("http://127.0.0.1:8000/api/livez",timeout=4));print(json.dumps({"ok":j.get("ok"),"feed":j.get("feed_state"),"ms":round((time.monotonic()-t)*1000,1)},ensure_ascii=False));sys.exit(0 if j.get("ok") else 1)' 2>&1)"
  R=$?
  set -e
  echo "$O"
  if [ "$R" -eq 0 ]; then good=$((good+1)); else good=0; fi
  [ "$good" -ge 3 ] && break
  sleep 3
done
[ "$good" -ge 3 ] || { echo "FAIL livez"; exit 20; }

echo
echo "===== 9. VERIFY ENTRY_STATE WRITE RATE AFTER FIX ====="
POST1="$(read_entry_count)"
sleep 30
POST2="$(read_entry_count)"
POST_DELTA=$((POST2-POST1))
echo "ENTRY_STATE_DELTA_30S_AFTER=$POST_DELTA"
if [ "$PRE_DELTA" -ge 20 ]; then
  # After fix, allow legitimate state transitions, but not the old per-tick storm.
  LIMIT=$(( PRE_DELTA / 2 ))
  [ "$POST_DELTA" -le "$LIMIT" ] || { echo "FAIL ENTRY_STATE write storm not sufficiently reduced"; exit 21; }
fi

echo
echo "===== 10. LATENCY / CPU / ZOMBIES ====="
docker exec "$APP" python -c '
import json,time,urllib.request,sys
xs=[]
for i in range(12):
    t=time.monotonic()
    try:j=json.load(urllib.request.urlopen("http://127.0.0.1:8000/api/livez",timeout=4))
    except Exception as e:print("LIVEZ_FAIL",repr(e));sys.exit(2)
    ms=(time.monotonic()-t)*1000;xs.append(ms)
    print("LIVEZ",i+1,round(ms,1),"ms",j.get("feed_state"))
    time.sleep(.5)
print("LIVEZ_MAX_MS=",round(max(xs),1))
if max(xs)>4000:sys.exit(3)
'
docker stats "$APP" --no-stream --format 'CPU={.CPUPerc} MEM={.MemUsage} PIDS={.PIDs}'
printf 'ZOMBIES='
ps -eo stat= | awk '$1 ~ /^Z/ {n++} END {print n+0}'

trap - EXIT
echo
echo "===== SUCCESS ====="
echo "RESULT=SUCCESS"
echo "ROOT_CAUSE=EntryPolicy._set persisted same-state ENTRY_STATE on every policy evaluation"
echo "FIX=Same-state _set is idempotent: reason refresh only, no state_since reset, no duplicate history write"
echo "PRE_BUY_NXT_WS_NUMERIC_POLICY=UNCHANGED"
echo "DATA_VOLUME=UNCHANGED"
echo "BACKUP_CONTAINER=$BACKUP"
echo "NEW_IMAGE=$NEW_IMAGE"
echo "LOG=$LOG"
