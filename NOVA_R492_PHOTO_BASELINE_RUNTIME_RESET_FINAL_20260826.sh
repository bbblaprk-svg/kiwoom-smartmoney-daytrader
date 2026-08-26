#!/usr/bin/env bash
set -Eeuo pipefail

APP="${NOVA_APP_CONTAINER:-quant-nova}"
EXPECTED_VERSION="NOVA-3.3.5-R492-MARKET-INDEX-VERIFY1"
EXPECTED_EMBEDDED="0d2f300af673c7187ae51b3ec9acc0e13e1dfaa6211d7b76a4f721130df632fc"
STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP="${APP}-before-photo-runtime-${STAMP}"
WORK="/tmp/nova-photo-runtime-${STAMP}"
LOG="${WORK}.log"
mkdir -p "$WORK"

exec > >(tee -a "$LOG") 2>&1

fail(){ echo "FAIL: $*"; return 1; }

echo "===== 0. LOCK TO PHOTO-BASELINE SOURCE ====="
docker inspect "$APP" >/dev/null 2>&1 || { echo "FAIL: $APP missing"; exit 2; }
IMAGE_ID="$(docker inspect -f '{{.Image}}' "$APP")"
IMAGE_REF="$(docker inspect -f '{{.Config.Image}}' "$APP")"
VERSION="$(docker image inspect "$IMAGE_ID" -f '{{index .Config.Labels "org.opencontainers.image.version"}}' 2>/dev/null || true)"
EMBEDDED="$(docker image inspect "$IMAGE_ID" -f '{{index .Config.Labels "io.quantnova.embedded_source_sha256"}}' 2>/dev/null || true)"
echo "IMAGE=$IMAGE_REF"
echo "VERSION=$VERSION"
echo "EMBEDDED_SOURCE=$EMBEDDED"
[ "$VERSION" = "$EXPECTED_VERSION" ] || { echo "FAIL: wrong version"; exit 3; }
[ "$EMBEDDED" = "$EXPECTED_EMBEDDED" ] || { echo "FAIL: wrong embedded source"; exit 4; }

echo
echo "===== 1. DIRECT ORIGINAL-vs-CURRENT RUNTIME ENV DIFF ====="
docker inspect "$APP" -f '{{range .Config.Env}}{{println .}}{{end}}' | sort > "$WORK/current.env"
python3 - "$WORK/current.env" "$WORK/keep.env" "$WORK/drop_nova.env" <<'PY'
import sys
src,keepf,dropf=sys.argv[1:]
keep=[]; drop=[]
# The photo-baseline Dockerfile itself defines only NOVA_DATA_DIR and NOVA_LEGACY_DATA_DIR.
# KIWOOM credentials are not NOVA_* and are preserved.
# UI access token is an external access credential; preserve only when non-empty.
allowed_nova={'NOVA_UI_ACCESS_TOKEN'}
for line in open(src,encoding='utf-8',errors='replace'):
    line=line.rstrip('\n')
    if not line or '=' not in line: continue
    k,v=line.split('=',1)
    if k.startswith('NOVA_'):
        if k in allowed_nova and v:
            keep.append(line)
        else:
            drop.append(line)
    else:
        keep.append(line)
open(keepf,'w').write('\n'.join(keep)+'\n')
open(dropf,'w').write('\n'.join(drop)+'\n')
print("PRESERVE_ENV_COUNT=",len(keep))
print("REMOVE_RUNTIME_NOVA_OVERRIDE_COUNT=",len(drop))
for x in drop:
    k=x.split('=',1)[0]
    if k not in ('NOVA_DATA_DIR','NOVA_LEGACY_DATA_DIR'):
        print("REMOVE_OVERRIDE",k)
PY

echo
echo "===== 2. SAVE EXACT CURRENT RUNTIME CONTRACT ====="
docker inspect "$APP" > "$WORK/inspect.before.json"
docker inspect "$APP" -f '{{json .Mounts}}' > "$WORK/mounts.json"
docker inspect "$APP" -f '{{json .HostConfig}}' > "$WORK/hostconfig.json"
echo "BACKUP_NAME=$BACKUP"
echo "WORK=$WORK"

echo
echo "===== 3. BUILD CLEAN RUN ARGUMENTS FROM EXISTING CONTRACT ====="
python3 - "$WORK/inspect.before.json" "$WORK/keep.env" "$WORK/run.args" "$IMAGE_REF" <<'PY'
import json,sys,shlex
inspect_path,env_path,out_path,image=sys.argv[1:]
o=json.load(open(inspect_path))[0]
a=['docker','run','-d','--name','quant-nova','--init']

net=(o.get('HostConfig') or {}).get('NetworkMode') or ''
if net and net not in ('default','bridge'):
    a += ['--network',net]

rp=(o.get('HostConfig') or {}).get('RestartPolicy') or {}
rn=rp.get('Name') or ''
mx=int(rp.get('MaximumRetryCount') or 0)
if rn and rn!='no':
    a += ['--restart', f'{rn}:{mx}' if rn=='on-failure' and mx else rn]

# Preserve mounts exactly; application data is NOT reset or deleted in this operation.
for m in o.get('Mounts') or []:
    typ=m.get('Type'); src=m.get('Source'); dst=m.get('Destination')
    if typ in ('bind','volume') and src and dst:
        spec=f'type={typ},src={src},dst={dst}'
        if not m.get('RW',True): spec += ',readonly'
        a += ['--mount',spec]

# Preserve non-NOVA environment and real credentials, drop inherited NOVA tuning overrides.
for line in open(env_path,encoding='utf-8'):
    line=line.rstrip('\n')
    if line: a += ['-e',line]

user=(o.get('Config') or {}).get('User') or ''
if user: a += ['--user',user]
wd=(o.get('Config') or {}).get('WorkingDir') or ''
if wd: a += ['--workdir',wd]

# Preserve any published ports if the original runtime had them.
pb=(o.get('HostConfig') or {}).get('PortBindings') or {}
for cport,bindings in pb.items():
    if not bindings: continue
    for b in bindings:
        hp=str((b or {}).get('HostPort') or '')
        hi=str((b or {}).get('HostIp') or '')
        if hp:
            spec=f'{hi+":" if hi else ""}{hp}:{cport.split("/")[0]}'
            a += ['-p',spec]

a += [image]
cmd=(o.get('Config') or {}).get('Cmd')
if cmd: a += list(cmd)

open(out_path,'w').write('\0'.join(a))
print("RUN_COMMAND_PREPARED=1")
print("NETWORK=",net)
print("MOUNTS=",len(o.get('Mounts') or []))
print("PORT_BINDING_KEYS=",len(pb))
PY

rollback(){
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

echo
echo "===== 4. CUTOVER: SAME SOURCE, CLEAN PHOTO-BASELINE RUNTIME ENV ====="
docker stop -t 15 "$APP" >/dev/null
docker rename "$APP" "$BACKUP"
python3 - "$WORK/run.args" <<'PY'
import os,sys,subprocess
raw=open(sys.argv[1],'rb').read().split(b'\0')
args=[x.decode() for x in raw if x]
print("+ docker run ... [environment values hidden]")
subprocess.run(args,check=True)
PY

echo
echo "===== 5. VERIFY IMAGE ENV IS BACK TO BASELINE DEFAULTS ====="
docker inspect "$APP" -f '{{range .Config.Env}}{{println .}}{{end}}' | sort > "$WORK/new.env"
echo "ACTIVE_NOVA_ENV_AFTER_RESET:"
grep '^NOVA_' "$WORK/new.env" || true

echo
echo "===== 6. WAIT FOR INTERNAL APP ====="
good=0
for i in $(seq 1 50); do
  set +e
  OUT="$(docker exec "$APP" python -c \
'import json,time,urllib.request,sys;t=time.monotonic();j=json.load(urllib.request.urlopen("http://127.0.0.1:8000/api/livez",timeout=3));print(json.dumps({"ok":j.get("ok"),"feed_state":j.get("feed_state"),"event_loop_beat_age_ms":j.get("event_loop_beat_age_ms"),"ms":round((time.monotonic()-t)*1000,1)},ensure_ascii=False));sys.exit(0 if j.get("ok") else 1)' 2>&1)"
  RC=$?
  set -e
  echo "$OUT"
  if [ "$RC" -eq 0 ]; then good=$((good+1)); else good=0; fi
  [ "$good" -ge 3 ] && break
  sleep 3
done
[ "$good" -ge 3 ] || fail "internal livez failed 3 consecutive checks"

echo
echo "===== 7. 60-SECOND STABILITY / CPU / LATENCY ====="
sleep 60
docker exec "$APP" python -c '
import json,time,urllib.request,statistics,sys
xs=[]; last={}
for i in range(12):
    t=time.monotonic()
    try:
        last=json.load(urllib.request.urlopen("http://127.0.0.1:8000/api/livez",timeout=3))
        xs.append((time.monotonic()-t)*1000)
        print("LIVEZ",i+1,round(xs[-1],1),"ms","feed",last.get("feed_state"))
    except Exception as e:
        print("LIVEZ_FAIL",i+1,repr(e)); sys.exit(2)
    time.sleep(.5)
ys=sorted(xs)
p95=ys[max(0,int(len(ys)*.95)-1)]
print("LIVEZ_P95_MS=",round(p95,1))
print("LIVEZ_MAX_MS=",round(max(xs),1))
if not last.get("ok"): sys.exit(3)
if max(xs)>3000: sys.exit(4)
'

echo
docker stats "$APP" --no-stream --format 'CPU={{.CPUPerc}} MEM={{.MemUsage}} PIDS={{.PIDs}}'
printf 'ZOMBIES='
ps -eo stat= | awk '$1 ~ /^Z/ {n++} END {print n+0}'

echo
echo "===== 8. CADDY -> NOVA ====="
if docker inspect kiwoom-caddy >/dev/null 2>&1; then
  docker exec kiwoom-caddy sh -c 'wget -qO- --timeout=8 http://quant-nova:8000/api/livez' >/tmp/caddy-nova.out
  head -c 500 /tmp/caddy-nova.out; echo
fi

echo
echo "===== 9. OPTIONAL GUARD RECOVERY ONLY IF IT NOW PASSES ====="
if docker inspect nova-http-guard >/dev/null 2>&1; then
  docker start nova-http-guard >/dev/null 2>&1 || true
  sleep 3
  set +e
  docker exec kiwoom-caddy sh -c 'wget -qO- --timeout=5 http://nova-http-guard:8080/api/livez' >/tmp/guard-test.out 2>&1
  GRC=$?
  set -e
  if [ "$GRC" -eq 0 ]; then
    echo "GUARD_TEST=PASS"
    head -c 500 /tmp/guard-test.out; echo
  else
    echo "GUARD_TEST=FAIL_KEEP_CURRENT_CADDY_RUNTIME"
    docker stop nova-http-guard >/dev/null 2>&1 || true
  fi
fi

trap - EXIT
echo
echo "===== SUCCESS ====="
echo "RESULT=SUCCESS"
echo "SOURCE_UNCHANGED=$EXPECTED_EMBEDDED"
echo "RUNTIME_NOVA_OVERRIDES_REMOVED=$(wc -l < "$WORK/drop_nova.env" | tr -d ' ')"
echo "DATA_VOLUME_UNCHANGED=1"
echo "PRE_BUY_NXT_WS_SOURCE_UNCHANGED=1"
echo "BACKUP_CONTAINER=$BACKUP"
echo "LOG=$LOG"
