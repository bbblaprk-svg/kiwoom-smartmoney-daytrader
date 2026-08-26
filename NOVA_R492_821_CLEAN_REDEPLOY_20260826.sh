#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

REPO="bbblaprk-svg/kiwoom-smartmoney-daytrader"
BRANCH="main"
REMOTE_DOCKERFILE="Dockerfile"
APP="quant-nova"
EXPECTED_VERSION="NOVA-3.3.5-R492-MARKET-INDEX-VERIFY1"
EXPECTED_DOCKERFILE_SHA="246deb1bd45854af17ab5c7ed80652bebabb576270ee1ac5b47866401a49ea45"
EXPECTED_EMBEDDED_SHA="1aafb56ee8ad2d2b5997c7dfee6738f6709b6995bcfc0e5219f446706400aca2"
EXPECTED_POLICY_SHA="18cb96ef1afb9de48136d39c3e9b8216e62a94dccf0229aa027479783eb9151a"
EXPECTED_WS_SHA="50fefc5faa1457210af758636279bea0bc3926e505bc91317962a0d451e35602"
EXPECTED_DISCOVERY_SHA="7035a5b5c90a23324c44d80eb3c0c278f75c5d73d8fed2a01cc367a03c35cb86"
EXPECTED_SERVICE_SHA="e325b7a76d6ddfa291b800ef97fb13e6b85fa9bb9ccb2365130ef2d5abf512c3"
STAMP="$(date +%Y%m%d-%H%M%S)"
IMAGE="quant-nova:r492-821-exact-${STAMP}"
BACKUP="${APP}-pre-clean821-${STAMP}"
WORK="$(mktemp -d /tmp/nova-r492-821-clean.XXXXXX)"
LOG="/tmp/nova-r492-821-clean-${STAMP}.log"
MARKER="/home/ubuntu/quant-nova/.r492-clean821-last"
DOCKERFILE="$WORK/Dockerfile"
ENVFILE="$WORK/runtime.env"
RUNNING_BEFORE="$WORK/running-apps-before.txt"
CANONICAL_BACKED_UP=0
NEW_STARTED=0
STATE_MUTATED=0

exec > >(tee -a "$LOG") 2>&1

if docker info >/dev/null 2>&1; then DOCKER=(docker)
elif sudo -n docker info >/dev/null 2>&1; then DOCKER=(sudo docker)
else echo "FAIL: Docker access unavailable"; exit 2
fi
dc(){ "${DOCKER[@]}" "$@"; }
say(){ printf '\n===== %s =====\n' "$*"; }
cleanup(){ rm -rf -- "$WORK" 2>/dev/null || true; }

is_nova_app_container(){
  local n="$1" iid title cmd
  iid="$(dc inspect "$n" --format '{{.Image}}' 2>/dev/null || true)"
  [ -n "$iid" ] || return 1
  title="$(dc image inspect "$iid" --format '{{index .Config.Labels "org.opencontainers.image.title"}}' 2>/dev/null || true)"
  cmd="$(dc inspect "$n" --format '{{json .Config.Cmd}}' 2>/dev/null || true)"
  [ "$title" = "QUANT NOVA" ] && printf '%s' "$cmd" | grep -Fq 'app.main:app'
}

image_version(){
  local n="$1" iid
  iid="$(dc inspect "$n" --format '{{.Image}}' 2>/dev/null || true)"
  [ -n "$iid" ] || return 0
  dc image inspect "$iid" --format '{{index .Config.Labels "org.opencontainers.image.version"}}' 2>/dev/null || true
}

rollback(){
  local rc=$?
  trap - ERR INT TERM EXIT
  if [ "$STATE_MUTATED" -eq 0 ]; then
    echo "RESULT=ABORTED_NO_CHANGE"
    echo "LOG=$LOG"
    cleanup
    exit "${rc:-1}"
  fi
  say "AUTO ROLLBACK"
  if [ "$NEW_STARTED" -eq 1 ] && dc inspect "$APP" >/dev/null 2>&1; then
    dc logs --tail 150 "$APP" || true
    dc rm -f "$APP" >/dev/null 2>&1 || true
  fi
  if [ "$CANONICAL_BACKED_UP" -eq 1 ] && dc inspect "$BACKUP" >/dev/null 2>&1; then
    dc rename "$BACKUP" "$APP" >/dev/null 2>&1 || true
    dc start "$APP" >/dev/null 2>&1 || true
  fi
  if [ -f "$RUNNING_BEFORE" ]; then
    while IFS= read -r n; do
      [ -n "$n" ] || continue
      [ "$n" = "$APP" ] && continue
      dc start "$n" >/dev/null 2>&1 || true
    done < "$RUNNING_BEFORE"
  fi
  echo "RESULT=ROLLED_BACK"
  echo "LOG=$LOG"
  cleanup
  exit "${rc:-1}"
}
trap rollback ERR INT TERM EXIT

say "1/10 FETCH EXACT 8:21 DOCKERFILE + SHA LOCK"
RAW="https://raw.githubusercontent.com/${REPO}/${BRANCH}/${REMOTE_DOCKERFILE}"
curl -fL --retry 5 --retry-delay 2 --connect-timeout 10 --max-time 90 \
  -H 'Cache-Control: no-cache' "$RAW?ts=$(date +%s)" -o "$DOCKERFILE"
ACTUAL_DOCKERFILE_SHA="$(sha256sum "$DOCKERFILE" | awk '{print $1}')"
echo "DOCKERFILE_SHA256=$ACTUAL_DOCKERFILE_SHA"
[ "$ACTUAL_DOCKERFILE_SHA" = "$EXPECTED_DOCKERFILE_SHA" ] || {
  echo "FAIL: GitHub Dockerfile is NOT the verified 8:21 original."
  echo "EXPECTED=$EXPECTED_DOCKERFILE_SHA"
  echo "ACTUAL=$ACTUAL_DOCKERFILE_SHA"
  exit 10
}
grep -Fq "org.opencontainers.image.version=\"$EXPECTED_VERSION\"" "$DOCKERFILE"
grep -Fq "expected='$EXPECTED_EMBEDDED_SHA'" "$DOCKERFILE"

say "2/10 FULL EMBEDDED SOURCE RESTORE + MANIFEST + CORE HASHES"
python3 - "$DOCKERFILE" "$EXPECTED_EMBEDDED_SHA" "$EXPECTED_POLICY_SHA" "$EXPECTED_WS_SHA" "$EXPECTED_DISCOVERY_SHA" "$EXPECTED_SERVICE_SHA" <<'PY'
import base64,hashlib,io,pathlib,re,subprocess,sys,tarfile,tempfile
p=pathlib.Path(sys.argv[1]); expected=sys.argv[2]
want={
'app/signal/policy.py':sys.argv[3],
'app/broker/websocket.py':sys.argv[4],
'app/broker/discovery.py':sys.argv[5],
'app/service.py':sys.argv[6],
}
text=p.read_text()
parts=re.findall(r"RUN printf '%s' '([^']*)' >> /tmp/nova-source\.tar\.gz\.b64",text)
if not parts: raise SystemExit('PREFLIGHT_FAIL: embedded payload missing')
raw=base64.b64decode(''.join(parts),validate=True)
got=hashlib.sha256(raw).hexdigest()
if got!=expected: raise SystemExit(f'PREFLIGHT_FAIL embedded sha {got} != {expected}')
if raw[:2]!=b'\x1f\x8b': raise SystemExit('PREFLIGHT_FAIL not gzip')
with tempfile.TemporaryDirectory(prefix='nova821-preflight-') as td:
    root=pathlib.Path(td)
    with tarfile.open(fileobj=io.BytesIO(raw),mode='r:gz') as tf:
        for m in tf.getmembers():
            name=m.name.replace('\\','/')
            if name.startswith('/') or '..' in name.split('/') or m.isdev() or m.issym() or m.islnk():
                raise SystemExit('PREFLIGHT_FAIL unsafe tar '+m.name)
        tf.extractall(root)
    cp=subprocess.run(['sha256sum','-c','SOURCE_MANIFEST.sha256'],cwd=root,stdout=subprocess.DEVNULL,stderr=subprocess.STDOUT)
    if cp.returncode: raise SystemExit('PREFLIGHT_FAIL SOURCE_MANIFEST mismatch')
    for rel,w in want.items():
        h=hashlib.sha256((root/rel).read_bytes()).hexdigest()
        if h!=w: raise SystemExit(f'PREFLIGHT_FAIL core mismatch {rel} {h}')
print(f'PREFLIGHT=PASS chunks={len(parts)} gzip_bytes={len(raw)} embedded_sha={got} manifest=PASS core=PASS')
PY

say "3/10 DISCOVER DATA / NETWORK / CREDENTIALS WITHOUT INHERITING TUNING ENV"
: > "$RUNNING_BEFORE"
mapfile -t ALL_CONTAINERS < <(dc ps -a --format '{{.Names}}')
for n in "${ALL_CONTAINERS[@]}"; do
  if is_nova_app_container "$n"; then
    if [ "$(dc inspect "$n" --format '{{.State.Running}}' 2>/dev/null || true)" = "true" ]; then
      echo "$n" >> "$RUNNING_BEFORE"
    fi
  fi
done
sort -u -o "$RUNNING_BEFORE" "$RUNNING_BEFORE"
echo "RUNNING_NOVA_APPS_BEFORE=$(paste -sd, "$RUNNING_BEFORE" 2>/dev/null || true)"

# Discover a single persistent data source. Prefer the known historical host path if present.
DATA_SRC=""
declare -A DATA_SEEN=()
for n in "${ALL_CONTAINERS[@]}"; do
  if is_nova_app_container "$n"; then
    while IFS='|' read -r src dst; do
      [ "$dst" = "/app/data/nova30" ] || continue
      [ -n "$src" ] || continue
      DATA_SEEN["$src"]=1
    done < <(dc inspect "$n" --format '{{range .Mounts}}{{println .Source "|" .Destination}}{{end}}' 2>/dev/null || true)
  fi
done
if [ -d /home/ubuntu/quant-nova/data/nova30 ]; then
  DATA_SRC="/home/ubuntu/quant-nova/data/nova30"
elif [ "${#DATA_SEEN[@]}" -eq 1 ]; then
  for k in "${!DATA_SEEN[@]}"; do DATA_SRC="$k"; done
elif [ "${#DATA_SEEN[@]}" -gt 1 ]; then
  echo "FAIL: multiple nova30 data sources detected; refusing to guess: ${!DATA_SEEN[*]}"
  exit 11
fi
[ -n "$DATA_SRC" ] && [ -d "$DATA_SRC" ] || { echo "FAIL: nova30 data directory not found"; exit 12; }
echo "DATA_SRC=$DATA_SRC"

NETWORK=""
if dc inspect kiwoom-caddy >/dev/null 2>&1; then
  NETWORK="$(dc inspect kiwoom-caddy --format '{{range $k,$v := .NetworkSettings.Networks}}{{println $k}}{{end}}' | grep -vE '^(bridge|host|none)$' | head -1 || true)"
fi
if [ -z "$NETWORK" ]; then
  for n in "${ALL_CONTAINERS[@]}"; do
    if is_nova_app_container "$n"; then
      NETWORK="$(dc inspect "$n" --format '{{range $k,$v := .NetworkSettings.Networks}}{{println $k}}{{end}}' | grep -vE '^(bridge|host|none)$' | head -1 || true)"
      [ -n "$NETWORK" ] && break
    fi
  done
fi
[ -n "$NETWORK" ] || { echo "FAIL: application network not found"; exit 13; }
echo "NETWORK=$NETWORK"

# Preserve only credentials/access tokens. All other NOVA_* runtime overrides are deliberately NOT inherited.
: > "$ENVFILE"
for key in KIWOOM_APP_KEY KIWOOM_APP_SECRET KIWOOM_SECRET_KEY NOVA_UI_ACCESS_TOKEN APP_ACCESS_TOKEN; do
  val=""
  for n in "$APP" $(tac "$RUNNING_BEFORE" 2>/dev/null || true) "${ALL_CONTAINERS[@]}"; do
    [ -n "$n" ] || continue
    dc inspect "$n" >/dev/null 2>&1 || continue
    line="$(dc inspect "$n" --format '{{range .Config.Env}}{{println .}}{{end}}' 2>/dev/null | grep -m1 "^${key}=" || true)"
    if [ -n "$line" ]; then val="${line#*=}"; [ -n "$val" ] && break; fi
  done
  if [ -n "$val" ]; then printf '%s=%s\n' "$key" "$val" >> "$ENVFILE"; echo "PRESERVE_SECRET_KEY=$key"; fi
done
if ! grep -q '^KIWOOM_APP_KEY=' "$ENVFILE"; then echo "FAIL: KIWOOM_APP_KEY not found in existing runtime"; exit 14; fi
if ! grep -Eq '^KIWOOM_(APP_SECRET|SECRET_KEY)=' "$ENVFILE"; then echo "FAIL: Kiwoom secret not found in existing runtime"; exit 15; fi

echo "RUNTIME_NOVA_TUNING_OVERRIDES_INHERITED=0"

say "4/10 BUILD EXACT ORIGINAL IMAGE"
dc build --pull=false --build-arg BUILD_GIT_SHA="8-21-verified-${EXPECTED_DOCKERFILE_SHA:0:12}" --build-arg BUILD_CREATED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)" -t "$IMAGE" -f "$DOCKERFILE" "$WORK"
BUILT_VERSION="$(dc image inspect "$IMAGE" --format '{{index .Config.Labels "org.opencontainers.image.version"}}')"
[ "$BUILT_VERSION" = "$EXPECTED_VERSION" ] || { echo "FAIL built version=$BUILT_VERSION"; exit 16; }

say "5/10 VERIFY BUILT IMAGE CORE BYTES"
dc run --rm --entrypoint python "$IMAGE" -c "import hashlib,pathlib; x={'policy':'$EXPECTED_POLICY_SHA','ws':'$EXPECTED_WS_SHA','discovery':'$EXPECTED_DISCOVERY_SHA','service':'$EXPECTED_SERVICE_SHA'}; p={'policy':'/app/app/signal/policy.py','ws':'/app/app/broker/websocket.py','discovery':'/app/app/broker/discovery.py','service':'/app/app/service.py'}; g={k:hashlib.sha256(pathlib.Path(v).read_bytes()).hexdigest() for k,v in p.items()}; print(g); assert g==x"

say "6/10 STOP ONLY QUANT-NOVA APPLICATION CONTAINERS; KEEP CADDY/GUARD UNTOUCHED"
STATE_MUTATED=1
while IFS= read -r n; do
  [ -n "$n" ] || continue
  echo "STOP_OLD_APP=$n"
  dc stop -t 15 "$n" >/dev/null 2>&1 || true
done < "$RUNNING_BEFORE"

if dc inspect "$APP" >/dev/null 2>&1; then
  dc rename "$APP" "$BACKUP"
  CANONICAL_BACKED_UP=1
  echo "BACKUP_CONTAINER=$BACKUP"
fi

say "7/10 START ONE CLEAN CANONICAL quant-nova"
RUN_ARGS=(run -d --name "$APP" --init --restart unless-stopped --network "$NETWORK" \
  --mount "type=bind,src=$DATA_SRC,dst=/app/data/nova30")
while IFS= read -r line; do [ -n "$line" ] && RUN_ARGS+=(--env "$line"); done < "$ENVFILE"
RUN_ARGS+=("$IMAGE")
dc "${RUN_ARGS[@]}" >/dev/null
NEW_STARTED=1

echo "ACTIVE_ENV_OVERRIDES:"
dc inspect "$APP" --format '{{range .Config.Env}}{{println .}}{{end}}' | grep -E '^(KIWOOM_|NOVA_|APP_ACCESS_TOKEN=)' | sed -E 's#=(.*)$#=<hidden>#' || true

say "8/10 INTERNAL STARTUP + 3 CONSECUTIVE LIVEZ"
GOOD=0
for i in $(seq 1 60); do
  set +e
  OUT="$(dc exec "$APP" python -c 'import json,time,urllib.request,sys;t=time.monotonic();j=json.load(urllib.request.urlopen("http://127.0.0.1:8000/api/livez",timeout=5));ms=(time.monotonic()-t)*1000;print(json.dumps({"ok":j.get("ok"),"version":j.get("version"),"feed":j.get("feed_state"),"beat_ms":j.get("event_loop_beat_age_ms"),"response_ms":round(ms,1)},ensure_ascii=False));sys.exit(0 if j.get("ok") else 1)' 2>&1)"
  RC=$?
  set -e
  echo "$OUT"
  if [ "$RC" -eq 0 ] && echo "$OUT" | grep -Fq "$EXPECTED_VERSION"; then GOOD=$((GOOD+1)); else GOOD=0; fi
  [ "$GOOD" -ge 3 ] && break
  sleep 3
done
[ "$GOOD" -ge 3 ] || { echo "FAIL: livez never stabilized"; exit 20; }

say "9/10 90-SECOND STABILITY + REALTIME HEALTH + CADDY PATH"
sleep 90
dc exec "$APP" python - <<'PY'
import json,os,statistics,time,urllib.request,sys
t=(os.getenv('NOVA_UI_ACCESS_TOKEN') or os.getenv('APP_ACCESS_TOKEN') or '').strip()
h={'X-App-Token':t,'Authorization':'Bearer '+t} if t else {}
def get(path,timeout=5):
    q=urllib.request.Request('http://127.0.0.1:8000'+path,headers=h)
    with urllib.request.urlopen(q,timeout=timeout) as r:return json.load(r)
xs=[]; last=None
for i in range(20):
    s=time.monotonic(); last=get('/api/livez',5); ms=(time.monotonic()-s)*1000; xs.append(ms)
    print('LIVEZ_SAMPLE',i+1,round(ms,1),'ms',last.get('feed_state'))
    time.sleep(.5)
ys=sorted(xs); p95=ys[max(0,int(len(ys)*.95)-1)]
print('LIVEZ_P95_MS=',round(p95,1),'LIVEZ_MAX_MS=',round(max(xs),1))
if not last.get('ok'): raise SystemExit('livez_not_ok')
if p95>1500 or max(xs)>4000: raise SystemExit('livez_latency_too_high')
rh=get('/api/realtime-health',5)
print('REALTIME_HEALTH=',json.dumps({k:rh.get(k) for k in ('load_mode','event_loop_lag_p95_ms','trade_queue_depth','trade_queue_oldest_age_ms','ws_status','feed_state')},ensure_ascii=False))
lag=float(rh.get('event_loop_lag_p95_ms') or 0)
qage=float(rh.get('trade_queue_oldest_age_ms') or 0)
if lag>250: raise SystemExit('event_loop_lag_too_high')
if qage>1000: raise SystemExit('trade_queue_age_too_high')
PY

dc stats "$APP" --no-stream --format 'CPU={{.CPUPerc}} MEM={{.MemUsage}} PIDS={{.PIDs}}'
printf 'ZOMBIES='; ps -eo stat= | awk '$1 ~ /^Z/ {n++} END {print n+0}'

if dc inspect kiwoom-caddy >/dev/null 2>&1; then
  echo "CADDY_TO_NOVA_TEST:"
  dc exec kiwoom-caddy sh -c 'wget -qO- --timeout=8 http://quant-nova:8000/api/livez' | head -c 1000
  echo
fi
if dc inspect nova-http-guard >/dev/null 2>&1; then
  echo "GUARD_PRESENT=1 (configuration/source untouched)"
  set +e
  dc exec kiwoom-caddy sh -c 'wget -qO- --timeout=5 http://nova-http-guard:8080/api/livez' >/tmp/nova821-guard-check.out 2>&1
  GRC=$?
  set -e
  echo "GUARD_LIVEZ_RC=$GRC"
  [ -s /tmp/nova821-guard-check.out ] && head -c 500 /tmp/nova821-guard-check.out && echo || true
fi

say "10/10 SUCCESS + ROLLBACK MARKER"
mkdir -p "$(dirname "$MARKER")"
{
  echo "STAMP=$STAMP"
  echo "NEW_IMAGE=$IMAGE"
  echo "BACKUP_CONTAINER=$([ "$CANONICAL_BACKED_UP" -eq 1 ] && echo "$BACKUP" || true)"
  echo "DATA_SRC=$DATA_SRC"
  echo "NETWORK=$NETWORK"
  echo "DOCKERFILE_SHA=$EXPECTED_DOCKERFILE_SHA"
  echo "EMBEDDED_SHA=$EXPECTED_EMBEDDED_SHA"
  echo "RUNNING_BEFORE=$(paste -sd, "$RUNNING_BEFORE" 2>/dev/null || true)"
} > "$MARKER"

trap - ERR INT TERM EXIT
cleanup
echo "RESULT=SUCCESS"
echo "VERSION=$EXPECTED_VERSION"
echo "DOCKERFILE_SHA=$EXPECTED_DOCKERFILE_SHA"
echo "EMBEDDED_SOURCE_SHA=$EXPECTED_EMBEDDED_SHA"
echo "SOURCE=EXACT_8_21_PHOTO_BASELINE"
echo "RUNTIME_NOVA_TUNING_OVERRIDES_INHERITED=0"
echo "DATA_VOLUME_UNCHANGED=1"
echo "CADDY_GUARD_SOURCE_CONFIG_CHANGED=0"
echo "CURRENT=$APP"
echo "BACKUP_CONTAINER=$([ "$CANONICAL_BACKED_UP" -eq 1 ] && echo "$BACKUP" || true)"
echo "LOG=$LOG"
