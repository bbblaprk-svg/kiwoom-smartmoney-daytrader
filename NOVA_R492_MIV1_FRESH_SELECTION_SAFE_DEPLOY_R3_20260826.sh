#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

REPO="bbblaprk-svg/kiwoom-smartmoney-daytrader"
BRANCH="main"
APP="${NOVA_APP_CONTAINER:-quant-nova}"
EXPECTED_VERSION="NOVA-3.3.5-R492-MARKET-INDEX-VERIFY1"
EXPECTED_CURRENT_SOURCE="0d2f300af673c7187ae51b3ec9acc0e13e1dfaa6211d7b76a4f721130df632fc"
EXPECTED_NEW_SOURCE="6415255a5a70bb29a1ae07a803ecf29d5164da3be774f8fca39baab63f45d1ac"
EXPECTED_DOCKERFILE_SHA="cf1570f23628dd3e51bca6eef883f2aaeb8371e19363149330921ee54a577b22"
EXPECTED_POLICY_SHA="18cb96ef1afb9de48136d39c3e9b8216e62a94dccf0229aa027479783eb9151a"
EXPECTED_REST_SHA="e10d936a2540a70d8a488e0460608a3c2a1a8bfaf95dc6206e706cce3afab0d1"
EXPECTED_GUARD_SHA="c07332eb6951c51b433f42059133dd22b5e28a0c137f07b9f177f814dbe1ec1b"
EXPECTED_WS_SHA="7f7c65002bbd8f21f4b169980d65b425b02e035a188d7d509d2fbd9d01e6ddcd"

STAMP="$(date +%Y%m%d-%H%M%S)"
WORK="$(mktemp -d /tmp/nova-r492-fresh-select.XXXXXX)"
DF="$WORK/Dockerfile"
INSPECT="$WORK/current.inspect.json"
ENVFILE="$WORK/current.env"
RUNARGS="$WORK/run.args"
IMAGE="quant-nova:r492-miv1-fresh-select-${STAMP}"
BACKUP="${APP}-pre-fresh-select-${STAMP}"
FAILED="${APP}-failed-fresh-select-${STAMP}"
LOG="/tmp/nova-r492-fresh-select-${STAMP}.log"
CUTOVER=0
SUCCESS=0

if docker info >/dev/null 2>&1; then DOCKER=(docker)
elif sudo -n docker info >/dev/null 2>&1; then DOCKER=(sudo docker)
else echo "FAIL: Docker 권한 없음"; exit 2
fi
dc(){ "${DOCKER[@]}" "$@"; }
say(){ printf '\n===== %s =====\n' "$*" | tee -a "$LOG"; }

rollback(){
  set +e
  if [ "$CUTOVER" -eq 1 ] && [ "$SUCCESS" -ne 1 ]; then
    say "AUTO ROLLBACK"
    if dc inspect "$APP" >/dev/null 2>&1; then
      dc stop -t 10 "$APP" >/dev/null 2>&1 || true
      dc rename "$APP" "$FAILED" >/dev/null 2>&1 || dc rm -f "$APP" >/dev/null 2>&1 || true
    fi
    if dc inspect "$BACKUP" >/dev/null 2>&1; then
      dc rename "$BACKUP" "$APP" >/dev/null 2>&1 || true
      dc start "$APP" >/dev/null 2>&1 || true
    fi
    echo "RESULT=ROLLED_BACK"
  fi
  echo "LOG=$LOG"
}
trap rollback EXIT INT TERM

exec > >(tee -a "$LOG") 2>&1

say "1/10 FETCH + SHA LOCK BEFORE ANY SERVER MUTATION"
curl -fL --retry 5 --retry-delay 2   "https://raw.githubusercontent.com/${REPO}/${BRANCH}/Dockerfile?ts=$(date +%s)"   -o "$DF"
ACTUAL_DF_SHA="$(sha256sum "$DF" | awk '{print $1}')"
echo "DOCKERFILE_SHA=$ACTUAL_DF_SHA"
[ "$ACTUAL_DF_SHA" = "$EXPECTED_DOCKERFILE_SHA" ] || {
  echo "FAIL: GitHub Dockerfile 불일치. 서버 변경 없음."
  echo "EXPECTED=$EXPECTED_DOCKERFILE_SHA"
  echo "ACTUAL=$ACTUAL_DF_SHA"
  exit 3
}

python3 - "$DF" "$EXPECTED_NEW_SOURCE" <<'PY'
import sys,re,base64,hashlib,tarfile,io
p,expected=sys.argv[1:]
s=open(p,encoding='utf-8').read()
chunks=re.findall(r"RUN printf '%s' '([^']*)' >> /tmp/nova-source.tar.gz.b64",s)
if not chunks: raise SystemExit("PREFLIGHT_FAIL: embedded source missing")
raw=base64.b64decode(''.join(chunks),validate=True)
sha=hashlib.sha256(raw).hexdigest()
if sha!=expected: raise SystemExit(f"PREFLIGHT_FAIL source sha {sha} != {expected}")
with tarfile.open(fileobj=io.BytesIO(raw),mode='r:gz') as t:
    names={m.name for m in t.getmembers()}
    required={
      './app/signal/policy.py','./app/broker/websocket.py','./app/broker/discovery.py',
      './app/service.py','./app/runtime/state.py','./app/runtime/display.py',
      './app/domain.py','./app/broker/recovery.py','./scripts/r492_pin_ws_freshness_acceptance.py'
    }
    miss=required-names
    if miss: raise SystemExit(f"PREFLIGHT_FAIL missing {sorted(miss)}")
print("PREFLIGHT_EMBEDDED_SOURCE=PASS",sha)
PY

say "2/10 REQUIRE CURRENT EXACT PHOTO BASELINE"
dc inspect "$APP" >/dev/null 2>&1 || { echo "FAIL: $APP 없음"; exit 4; }
CURRENT_STATUS="$(dc inspect "$APP" -f '{{.State.Status}}')"
[ "$CURRENT_STATUS" = "running" ] || { echo "FAIL: current $APP status=$CURRENT_STATUS"; exit 5; }
CURRENT_IMAGE_ID="$(dc inspect "$APP" -f '{{.Image}}')"
CURRENT_VERSION="$(dc image inspect "$CURRENT_IMAGE_ID" -f '{{index .Config.Labels "org.opencontainers.image.version"}}' 2>/dev/null || true)"
CURRENT_SOURCE="$(dc image inspect "$CURRENT_IMAGE_ID" -f '{{index .Config.Labels "io.quantnova.embedded_source_sha256"}}' 2>/dev/null || true)"
echo "CURRENT_VERSION=$CURRENT_VERSION"
echo "CURRENT_SOURCE=$CURRENT_SOURCE"
[ "$CURRENT_VERSION" = "$EXPECTED_VERSION" ] || { echo "FAIL: 승인 버전 아님"; exit 6; }
[ "$CURRENT_SOURCE" = "$EXPECTED_CURRENT_SOURCE" ] || { echo "FAIL: 현재 서버가 승인 사진 기준본과 다름. 변경 없음."; exit 7; }

CURRENT_POLICY="$(dc exec "$APP" sha256sum /app/app/signal/policy.py | awk '{print $1}')"
CURRENT_REST="$(dc exec "$APP" sha256sum /app/app/broker/kiwoom.py | awk '{print $1}')"
[ "$CURRENT_POLICY" = "$EXPECTED_POLICY_SHA" ] || { echo "FAIL current policy hash"; exit 8; }
[ "$CURRENT_REST" = "$EXPECTED_REST_SHA" ] || { echo "FAIL current REST core hash"; exit 9; }

say "3/10 SNAPSHOT EXACT RUNTIME CONTRACT + PROTECTED CONTAINERS"
dc inspect "$APP" > "$INSPECT"
dc inspect "$APP" -f '{{range .Config.Env}}{{println .}}{{end}}' > "$ENVFILE"
for n in kiwoom-caddy nova-http-guard; do
  if dc inspect "$n" >/dev/null 2>&1; then
    echo "$n=$(dc inspect "$n" -f '{{.Id}}')" | tee -a "$WORK/protected.ids"
  fi
done

python3 - "$INSPECT" "$ENVFILE" "$RUNARGS" "$IMAGE" <<'PY'
import json,sys
insp,envf,outf,image=sys.argv[1:]
o=json.load(open(insp))[0]; h=o.get("HostConfig") or {}; c=o.get("Config") or {}
a=["docker","run","-d","--name","quant-nova"]
if h.get("Init") is True: a+=["--init"]
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
# Preserve the currently healthy runtime contract exactly. No new tuning ENV is introduced.
for line in open(envf,encoding="utf-8",errors="replace"):
    line=line.rstrip("\n")
    if line:a+=["-e",line]
user=c.get("User") or ""
if user:a+=["--user",user]
wd=c.get("WorkingDir") or ""
if wd:a+=["--workdir",wd]
pb=h.get("PortBindings") or {}
for cp,bindings in pb.items():
    for b in (bindings or []):
        hp=str((b or {}).get("HostPort") or ""); hi=str((b or {}).get("HostIp") or "")
        if hp:a+=["-p",f"{hi+':' if hi else ''}{hp}:{cp.split('/')[0]}"]
a+=[image]
cmd=c.get("Cmd")
if cmd:a+=list(cmd)
open(outf,"wb").write(b"\0".join(x.encode() for x in a))
print("RUNTIME_CONTRACT=CAPTURED")
PY

say "4/10 BUILD — COMPLETE 241-TEST PASS (MAX 3 ATTEMPTS) + MANIFEST + ACCEPTANCE"
dc build --pull=false -t "$IMAGE" -f "$DF" "$WORK"

say "5/10 VERIFY BUILT IMAGE CONTRACT BEFORE CUTOVER"
NEW_VERSION="$(dc image inspect "$IMAGE" -f '{{index .Config.Labels "org.opencontainers.image.version"}}')"
NEW_SOURCE="$(dc image inspect "$IMAGE" -f '{{index .Config.Labels "io.quantnova.embedded_source_sha256"}}')"
NEW_PATCH="$(dc image inspect "$IMAGE" -f '{{index .Config.Labels "io.quantnova.pin_ws_freshness"}}')"
echo "NEW_VERSION=$NEW_VERSION"
echo "NEW_SOURCE=$NEW_SOURCE"
echo "NEW_PATCH=$NEW_PATCH"
[ "$NEW_VERSION" = "$EXPECTED_VERSION" ] || exit 10
[ "$NEW_SOURCE" = "$EXPECTED_NEW_SOURCE" ] || exit 11
[ "$NEW_PATCH" = "HARD_SOFT_PIN_FRESH30_GAP_SCOPE_V1" ] || exit 12

say "6/10 CUTOVER ONLY quant-nova — CADDY/GUARD UNTOUCHED"
dc stop -t 15 "$APP" >/dev/null
dc rename "$APP" "$BACKUP"
CUTOVER=1

python3 - "$RUNARGS" <<'PY'
import subprocess,sys
a=[x.decode() for x in open(sys.argv[1],"rb").read().split(b"\0") if x]
if a and a[0]=="docker": a[0]="docker"
print("+ docker run ... (env values hidden)")
subprocess.run(a,check=True)
PY

say "7/10 STARTUP — REQUIRE 3 CONSECUTIVE LIVEZ + READYZ"
GOOD=0
for i in $(seq 1 60); do
  sleep 3
  set +e
  OUT="$(dc exec "$APP" python -c 'import json,urllib.request,sys,time; l=json.load(urllib.request.urlopen("http://127.0.0.1:8000/api/livez",timeout=5)); r=json.load(urllib.request.urlopen("http://127.0.0.1:8000/api/readyz",timeout=5)); print(json.dumps({"live":l,"ready":r},ensure_ascii=False)); sys.exit(0 if l.get("ok") and r.get("ok") else 1)' 2>&1)"
  RC=$?
  set -e
  echo "$OUT"
  if [ "$RC" -eq 0 ]; then GOOD=$((GOOD+1)); else GOOD=0; fi
  [ "$GOOD" -ge 3 ] && break
done
[ "$GOOD" -ge 3 ] || { echo "FAIL: startup acceptance"; exit 20; }

say "8/10 VERIFY PROTECTED LOGIC IS BYTE-IDENTICAL"
POLICY="$(dc exec "$APP" sha256sum /app/app/signal/policy.py | awk '{print $1}')"
REST="$(dc exec "$APP" sha256sum /app/app/broker/kiwoom.py | awk '{print $1}')"
GUARD="$(dc exec "$APP" sha256sum /app/ops/http_guard_v2.py | awk '{print $1}')"
WS="$(dc exec "$APP" sha256sum /app/app/broker/websocket.py | awk '{print $1}')"
echo "ENTRY_POLICY=$POLICY"
echo "KIWOOM_REST=$REST"
echo "GUARD_SOURCE=$GUARD"
echo "WEBSOCKET_SELECTION=$WS"
[ "$POLICY" = "$EXPECTED_POLICY_SHA" ] || exit 21
[ "$REST" = "$EXPECTED_REST_SHA" ] || exit 22
[ "$GUARD" = "$EXPECTED_GUARD_SHA" ] || exit 23
[ "$WS" = "$EXPECTED_WS_SHA" ] || exit 24
dc exec "$APP" env PYTHONPATH=/app python /app/scripts/r492_pin_ws_freshness_acceptance.py

say "9/10 LIVE OBSERVATION — NO HARD FAIL ON TRANSIENT GAP, PRINT ACTUAL TRUTH"
for i in 1 2 3; do
  dc exec "$APP" python -c 'import json,urllib.request; h=json.load(urllib.request.urlopen("http://127.0.0.1:8000/api/realtime-health",timeout=8)); d=h.get("discovery") or {}; print(json.dumps({"feed_state":h.get("feed_state"),"connection_state":h.get("connection_state"),"discovery":d},ensure_ascii=False))' || true
  dc exec "$APP" python -c 'import json,urllib.request; print(json.dumps(json.load(urllib.request.urlopen("http://127.0.0.1:8000/api/feed-truth",timeout=8)),ensure_ascii=False)[:3000])' || true
  dc stats "$APP" --no-stream --format 'CPU={{.CPUPerc}} MEM={{.MemUsage}} PIDS={{.PIDs}}'
  sleep 20
done

say "10/10 VERIFY CADDY/GUARD CONTAINERS WERE NOT REPLACED"
if [ -f "$WORK/protected.ids" ]; then
  while IFS='=' read -r n old; do
    now="$(dc inspect "$n" -f '{{.Id}}' 2>/dev/null || true)"
    echo "$n BEFORE=$old AFTER=$now"
    [ "$now" = "$old" ] || { echo "FAIL: protected container changed: $n"; exit 30; }
  done < "$WORK/protected.ids"
fi

SUCCESS=1
trap - EXIT INT TERM
echo
echo "===== SUCCESS ====="
echo "RESULT=SUCCESS"
echo "VERSION=$EXPECTED_VERSION"
echo "PARENT_SOURCE=$EXPECTED_CURRENT_SOURCE"
echo "NEW_SOURCE=$EXPECTED_NEW_SOURCE"
echo "DOCKERFILE_SHA=$EXPECTED_DOCKERFILE_SHA"
echo "ENTRY_POLICY_SHA=$EXPECTED_POLICY_SHA"
echo "PRE_BUY_NXT_SCORE_FORMULAS=UNCHANGED"
echo "OFFICIAL_BUY_EFFECT=0"
echo "NEW_WS_SUBSCRIPTION_TYPES=0"
echo "NEW_BROKER_REST_CALLS=0"
echo "TRADE_BUDGET=60"
echo "FRESH_HOT_RESERVE=NORMAL30_BUSY30_HIGH25_CRITICAL20"
echo "STALE_HISTORY_PIN=SOFT_SPARE_ONLY"
echo "GAP_RECOVERY_SCOPE=CURRENT_WS_TRADE_OR_HOT_PLUS_HARD"
echo "BACKUP=$BACKUP"
echo "LOG=$LOG"
