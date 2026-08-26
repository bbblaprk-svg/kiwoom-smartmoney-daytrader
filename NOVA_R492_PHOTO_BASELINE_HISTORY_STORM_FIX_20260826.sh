#!/usr/bin/env bash
set -Eeuo pipefail

APP="${NOVA_APP_CONTAINER:-quant-nova}"
EXPECTED_VERSION="NOVA-3.3.5-R492-MARKET-INDEX-VERIFY1"
EXPECTED_EMBEDDED="0d2f300af673c7187ae51b3ec9acc0e13e1dfaa6211d7b76a4f721130df632fc"
STAMP="$(date +%Y%m%d-%H%M%S)"
DAY="$(TZ=Asia/Seoul date +%Y%m%d)"
WORK="/tmp/nova-history-guard-${STAMP}"
NEW_IMAGE="quant-nova:r492-photo-history-guard-${STAMP}"
BACKUP="${APP}-before-history-guard-${STAMP}"
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

echo "===== 0. LOCK TO PHOTO BASELINE ====="
docker inspect "$APP" >/dev/null
BASE_IMAGE_ID="$(docker inspect -f '{{.Image}}' "$APP")"
BASE_IMAGE_REF="$(docker inspect -f '{{.Config.Image}}' "$APP")"
VERSION="$(docker image inspect "$BASE_IMAGE_ID" -f '{{index .Config.Labels "org.opencontainers.image.version"}}' 2>/dev/null || true)"
EMBEDDED="$(docker image inspect "$BASE_IMAGE_ID" -f '{{index .Config.Labels "io.quantnova.embedded_source_sha256"}}' 2>/dev/null || true)"
echo "BASE_IMAGE=$BASE_IMAGE_REF"
echo "VERSION=$VERSION"
echo "EMBEDDED=$EMBEDDED"
[ "$VERSION" = "$EXPECTED_VERSION" ] || { echo "FAIL wrong version"; exit 2; }
[ "$EMBEDDED" = "$EXPECTED_EMBEDDED" ] || { echo "FAIL wrong source"; exit 3; }

echo
echo "===== 1. FORENSIC: IMPORTANT_HISTORY BY KIND / STATE ====="
docker exec "$APP" python -c '
import sqlite3, json, os
from app.config import SETTINGS
day=os.environ.get("DAY_ARG") or "'"$DAY"'"
db=SETTINGS.data_dir/"signal_wal.sqlite3"
c=sqlite3.connect("file:"+str(db)+"?mode=ro",uri=True,timeout=10)
print("DB=",db)
print("DAY=",day)
print("TOTAL_TODAY=",c.execute("select count(*) from important_history where day=?",(day,)).fetchone()[0])
print("BY_KIND")
for row in c.execute("select kind,count(*) n from important_history where day=? group by kind order by n desc limit 20",(day,)):
    print(row[0],row[1])
print("RAW_BY_STATE")
for row in c.execute("select json_extract(payload,'"'$.state'"'),count(*) n from important_history where day=? and kind='SIGNAL_REPEAT_RAW' group by 1 order by n desc limit 20",(day,)):
    print(row[0],row[1])
c.close()
'

echo
echo "===== 2. MEASURE 20-SECOND WRITE GROWTH ====="
read_counts() {
  docker exec "$APP" python -c '
import sqlite3, os, json
from app.config import SETTINGS
day="'"$DAY"'"; db=SETTINGS.data_dir/"signal_wal.sqlite3"
c=sqlite3.connect("file:"+str(db)+"?mode=ro",uri=True,timeout=10)
tot=c.execute("select count(*) from important_history where day=?",(day,)).fetchone()[0]
raw=c.execute("select count(*) from important_history where day=? and kind='SIGNAL_REPEAT_RAW'",(day,)).fetchone()[0]
top=c.execute("select count(*) from important_history where day=? and kind='TOP10'",(day,)).fetchone()[0]
sig=c.execute("select count(*) from important_history where day=? and kind='SIGNAL'",(day,)).fetchone()[0]
print(tot,raw,top,sig)
c.close()
'
}
A="$(read_counts)"; echo "BEFORE $A"
sleep 20
B="$(read_counts)"; echo "AFTER  $B"

python3 - "$A" "$B" "$WORK/diagnosis.json" <<'PY'
import sys,json
a=list(map(int,sys.argv[1].split())); b=list(map(int,sys.argv[2].split()))
dt=[y-x for x,y in zip(a,b)]
tot,raw,top,sig=dt
share=(raw/tot) if tot>0 else 0.0
diag={
 "delta_total":tot,"delta_raw":raw,"delta_top10":top,"delta_signal":sig,
 "raw_share":share,
 "confirmed": bool(raw>=5 and (tot==0 or share>=0.50))
}
open(sys.argv[3],'w').write(json.dumps(diag))
print("DELTA_TOTAL=",tot)
print("DELTA_SIGNAL_REPEAT_RAW=",raw)
print("DELTA_TOP10=",top)
print("DELTA_SIGNAL=",sig)
print("RAW_SHARE=",round(share,3))
print("DIAGNOSIS_CONFIRMED=",diag["confirmed"])
if not diag["confirmed"]:
    print("ABORT_NO_MUTATION: SIGNAL_REPEAT_RAW is not >=50% of current important_history growth.")
    sys.exit(9)
PY

echo
echo "===== 3. BUILD ONE-FILE PERSISTENCE GUARD ====="
docker cp "$APP:/app/app/storage/wal.py" "$WORK/wal.py"
cp "$WORK/wal.py" "$WORK/wal.py.before"

python3 - "$WORK/wal.py" <<'PY'
from pathlib import Path
import sys
p=Path(sys.argv[1]); s=p.read_text()
old="""    def append_important(self,record:dict[str,Any])->bool:
        try:self.important.put_nowait(dict(record)); self.work_evt.set(); return True
"""
new="""    def append_important(self,record:dict[str,Any])->bool:
        # PHOTO-BASELINE R492 runtime guard:
        # Mechanical duplicate formal-stage observations are intentionally excluded from
        # signal acceleration semantics and are not durable state. Keep them in Candidate.history
        # (append_history sees True and appends in memory), but do not write every duplicate to
        # SQLite important_history. Official SIGNAL/BUY/TOP10/lifecycle behavior is unchanged.
        if str(record.get('kind') or '') == 'SIGNAL_REPEAT_RAW':
            self.stats['important_transient_suppressed']=int(self.stats.get('important_transient_suppressed') or 0)+1
            return True
        try:self.important.put_nowait(dict(record)); self.work_evt.set(); return True
"""
if old not in s:
    raise SystemExit("PATCH_ANCHOR_NOT_FOUND")
s=s.replace(old,new,1)
p.write_text(s)
print("PATCH_APPLIED=1")
PY

cat > "$WORK/Dockerfile" <<EOF
FROM ${BASE_IMAGE_ID}
COPY wal.py /app/app/storage/wal.py
RUN python -m py_compile /app/app/storage/wal.py
RUN PYTHONPATH=/app python -m pytest -q \
    /app/tests/test_core.py \
    /app/tests/test_r49_signal_acceleration.py \
    /app/tests/test_r492_safe_extension.py
LABEL io.quantnova.photo_baseline_history_guard="SIGNAL_REPEAT_RAW_MEMORY_ONLY"
LABEL io.quantnova.photo_baseline_source="${EXPECTED_EMBEDDED}"
EOF

docker build --pull=false -t "$NEW_IMAGE" "$WORK"

echo
echo "===== 4. CAPTURE EXACT CURRENT RUNTIME CONTRACT ====="
docker inspect "$APP" > "$WORK/inspect.json"
docker inspect "$APP" -f '{{range .Config.Env}}{{println .}}{{end}}' > "$WORK/env.list"

python3 - "$WORK/inspect.json" "$WORK/env.list" "$WORK/run.args" "$NEW_IMAGE" <<'PY'
import json,sys
insp,envf,outf,image=sys.argv[1:]
o=json.load(open(insp))[0]
h=o.get("HostConfig") or {}; c=o.get("Config") or {}
a=["docker","run","-d","--name","quant-nova"]

if h.get("Init") is True: a+=["--init"]
hc=c.get("Healthcheck") or {}
if (hc.get("Test") or [])==["NONE"]: a+=["--no-healthcheck"]

net=h.get("NetworkMode") or ""
if net and net not in ("default","bridge"): a+=["--network",net]

rp=h.get("RestartPolicy") or {}; rn=rp.get("Name") or ""; mx=int(rp.get("MaximumRetryCount") or 0)
if rn and rn!="no":
    a+=["--restart", f"{rn}:{mx}" if rn=="on-failure" and mx else rn]

for m in o.get("Mounts") or []:
    typ=m.get("Type"); src=m.get("Source"); dst=m.get("Destination")
    if typ in ("bind","volume") and src and dst:
        spec=f"type={typ},src={src},dst={dst}"
        if not m.get("RW",True): spec+=",readonly"
        a+=["--mount",spec]

for line in open(envf,encoding="utf-8",errors="ignore"):
    line=line.rstrip("\n")
    if line: a+=["-e",line]

user=c.get("User") or ""
if user: a+=["--user",user]
wd=c.get("WorkingDir") or ""
if wd: a+=["--workdir",wd]

pb=h.get("PortBindings") or {}
for cp,bs in pb.items():
    for b in (bs or []):
        hp=str((b or {}).get("HostPort") or "")
        hi=str((b or {}).get("HostIp") or "")
        if hp:a+=["-p",f"{hi+':' if hi else ''}{hp}:{cp.split('/')[0]}"]

a+=[image]
cmd=c.get("Cmd")
if cmd:a+=list(cmd)
open(outf,"wb").write(b"\0".join(x.encode() for x in a))
print("RUN_ARGS_READY=1")
PY

echo
echo "===== 5. CUTOVER ====="
docker stop -t 15 "$APP" >/dev/null
docker rename "$APP" "$BACKUP"
python3 - "$WORK/run.args" <<'PY'
import sys,subprocess
a=[x.decode() for x in open(sys.argv[1],"rb").read().split(b"\0") if x]
print("+ docker run ...")
subprocess.run(a,check=True)
PY

echo
echo "===== 6. INTERNAL LIVEZ: 3 CONSECUTIVE OK ====="
good=0
for i in $(seq 1 50); do
  set +e
  O="$(docker exec "$APP" python -c \
'import json,time,urllib.request,sys;t=time.monotonic();j=json.load(urllib.request.urlopen("http://127.0.0.1:8000/api/livez",timeout=4));print(json.dumps({"ok":j.get("ok"),"feed":j.get("feed_state"),"ms":round((time.monotonic()-t)*1000,1)},ensure_ascii=False));sys.exit(0 if j.get("ok") else 1)' 2>&1)"
  R=$?
  set -e
  echo "$O"
  if [ "$R" -eq 0 ]; then good=$((good+1)); else good=0; fi
  [ "$good" -ge 3 ] && break
  sleep 3
done
[ "$good" -ge 3 ] || { echo "FAIL livez"; exit 12; }

echo
echo "===== 7. POST-PATCH 30-SECOND WRITE GROWTH ====="
C="$(read_counts)"; echo "POST_BEFORE $C"
sleep 30
D="$(read_counts)"; echo "POST_AFTER  $D"
python3 - "$C" "$D" <<'PY'
import sys
c=list(map(int,sys.argv[1].split())); d=list(map(int,sys.argv[2].split()))
x=[b-a for a,b in zip(c,d)]
print("POST_DELTA_TOTAL=",x[0])
print("POST_DELTA_SIGNAL_REPEAT_RAW=",x[1])
print("POST_DELTA_TOP10=",x[2])
print("POST_DELTA_SIGNAL=",x[3])
if x[1] != 0:
    raise SystemExit("RAW_REPEAT_STILL_PERSISTING")
PY

echo
echo "===== 8. LATENCY / LOAD ====="
docker exec "$APP" python -c '
import json,time,urllib.request,sys
xs=[]
for i in range(10):
    t=time.monotonic()
    try:
        j=json.load(urllib.request.urlopen("http://127.0.0.1:8000/api/livez",timeout=4))
    except Exception as e:
        print("LIVEZ_FAIL",repr(e));sys.exit(2)
    ms=(time.monotonic()-t)*1000;xs.append(ms)
    print("LIVEZ",i+1,round(ms,1),"ms",j.get("feed_state"))
    time.sleep(.5)
print("LIVEZ_MAX_MS=",round(max(xs),1))
if max(xs)>4000:sys.exit(3)
'
docker stats "$APP" --no-stream --format 'CPU={{.CPUPerc}} MEM={{.MemUsage}} PIDS={{.PIDs}}'
printf 'ZOMBIES='
ps -eo stat= | awk '$1 ~ /^Z/ {n++} END {print n+0}'

trap - EXIT
echo
echo "===== SUCCESS ====="
echo "RESULT=SUCCESS"
echo "DIAGNOSIS=SIGNAL_REPEAT_RAW_DURABLE_WRITE_STORM_CONFIRMED"
echo "PATCH_SCOPE=DurableJournal.append_important SIGNAL_REPEAT_RAW only"
echo "OFFICIAL_SIGNAL_BUY_TOP10_PRE_NXT_WS_LOGIC=UNCHANGED"
echo "DATA_VOLUME=UNCHANGED"
echo "BACKUP_CONTAINER=$BACKUP"
echo "NEW_IMAGE=$NEW_IMAGE"
echo "LOG=$LOG"
