#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

APP="${NOVA_APP_CONTAINER:-quant-nova}"
EXPECTED_VERSION="NOVA-3.3.5-R492-MARKET-INDEX-VERIFY1"
EXPECTED_PARENT_SOURCE="0d2f300af673c7187ae51b3ec9acc0e13e1dfaa6211d7b76a4f721130df632fc"
PATCH_SHA="0b710a3c531fbceb2030f369a397484d7579401eb5f101c9f18aa055764b276a"
STAMP="$(date +%Y%m%d-%H%M%S)"
WORK="$(mktemp -d /tmp/nova-fresh-overlay.XXXXXX)"
PATCH_TGZ="$WORK/fresh-selection-overlay.tar.gz"
STAGE="${APP}-overlay-stage-${STAMP}"
BACKUP="${APP}-pre-overlay-${STAMP}"
FAILED="${APP}-failed-overlay-${STAMP}"
NEW_IMAGE="quant-nova:r492-fresh-selection-overlay-${STAMP}"
LOG="/tmp/nova-r492-fresh-overlay-${STAMP}.log"
CUTOVER=0
SUCCESS=0

if docker info >/dev/null 2>&1; then D=(docker)
elif sudo -n docker info >/dev/null 2>&1; then D=(sudo docker)
else echo "FAIL: Docker permission"; exit 2
fi
dc(){ "${D[@]}" "$@"; }
say(){ printf '\n===== %s =====\n' "$*"; }

rollback(){
  set +e
  if [ "$CUTOVER" -eq 1 ] && [ "$SUCCESS" -ne 1 ]; then
    say "AUTO ROLLBACK"
    dc rm -f "$APP" >/dev/null 2>&1 || true
    if dc inspect "$BACKUP" >/dev/null 2>&1; then
      dc rename "$BACKUP" "$APP" >/dev/null 2>&1 || true
      dc start "$APP" >/dev/null 2>&1 || true
    fi
    echo "RESULT=ROLLED_BACK"
  fi
  dc rm -f "$STAGE" >/dev/null 2>&1 || true
  echo "LOG=$LOG"
}
trap rollback EXIT INT TERM
exec > >(tee -a "$LOG") 2>&1

say "0/9 CURRENT HEALTHY PHOTO BASELINE ONLY"
dc inspect "$APP" >/dev/null
STATUS="$(dc inspect -f '{{.State.Status}}' "$APP")"
[ "$STATUS" = running ] || { echo "FAIL current status=$STATUS"; exit 3; }
IMG_ID="$(dc inspect -f '{{.Image}}' "$APP")"
VER="$(dc image inspect "$IMG_ID" -f '{{index .Config.Labels "org.opencontainers.image.version"}}' 2>/dev/null || true)"
SRC="$(dc image inspect "$IMG_ID" -f '{{index .Config.Labels "io.quantnova.embedded_source_sha256"}}' 2>/dev/null || true)"
echo "VERSION=$VER"
echo "PARENT_SOURCE=$SRC"
[ "$VER" = "$EXPECTED_VERSION" ] || { echo "FAIL wrong version"; exit 4; }
[ "$SRC" = "$EXPECTED_PARENT_SOURCE" ] || { echo "FAIL not exact photo baseline"; exit 5; }

check_hash(){
  rel="$1"; want="$2"
  got="$(dc exec "$APP" sha256sum "/app/$rel" | awk '{print $1}')"
  printf '%-34s %s\n' "$rel" "$got"
  [ "$got" = "$want" ] || { echo "FAIL protected core mismatch: $rel"; exit 6; }
}

say "1/9 PROVE PROTECTED CORE IS EXACT — NO CORE PATCH"
check_hash "app/signal/policy.py" "18cb96ef1afb9de48136d39c3e9b8216e62a94dccf0229aa027479783eb9151a"
check_hash "app/broker/kiwoom.py" "e10d936a2540a70d8a488e0460608a3c2a1a8bfaf95dc6206e706cce3afab0d1"
check_hash "app/broker/websocket.py" "50fefc5faa1457210af758636279bea0bc3926e505bc91317962a0d451e35602"
check_hash "app/broker/discovery.py" "2b12de4c44af1242287c5b9883c2ffc4e646522d13a0dfa0a243c3e4c024fa59"
check_hash "app/service.py" "e325b7a76d6ddfa291b800ef97fb13e6b85fa9bb9ccb2365130ef2d5abf512c3"
check_hash "app/addons/energy_path.py" "cd403cda76cb9d515c9228bf310287ad639bed125075fa835a3607cac2e81595"
check_hash "app/runtime/state.py" "28e835a781ed4a0a00bf4ab1fb1f2dcfb6c3c23ed77750c492788a168c80451b"

say "2/9 MATERIALIZE TINY 2-FILE OVERLAY"
cat > "$WORK/patch.b64" <<'B64'
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
B64
base64 -d "$WORK/patch.b64" > "$PATCH_TGZ"
ACTUAL_PATCH_SHA="$(sha256sum "$PATCH_TGZ" | awk '{print $1}')"
echo "PATCH_SHA=$ACTUAL_PATCH_SHA"
[ "$ACTUAL_PATCH_SHA" = "$PATCH_SHA" ] || exit 7
mkdir -p "$WORK/patch"
tar -xzf "$PATCH_TGZ" -C "$WORK/patch"
python3 -m py_compile "$WORK/patch/app/addons/fresh_selection_guard.py" "$WORK/patch/app/api/app.py"

say "3/9 CREATE DERIVED IMAGE WITHOUT DOCKER BUILD"
dc create --name "$STAGE" "$IMG_ID" >/dev/null
dc cp "$WORK/patch/app/addons/fresh_selection_guard.py" "$STAGE:/app/app/addons/fresh_selection_guard.py"
dc cp "$WORK/patch/app/api/app.py" "$STAGE:/app/app/api/app.py"
dc commit   --change 'LABEL io.quantnova.selection_overlay="FRESH_PIN_GUARD_V1"'   --change 'LABEL io.quantnova.selection_overlay_scope="API_ADDON_ONLY_NO_CORE_MUTATION"'   --change 'LABEL io.quantnova.selection_overlay_parent="0d2f300af673c7187ae51b3ec9acc0e13e1dfaa6211d7b76a4f721130df632fc"'   --change 'LABEL io.quantnova.selection_overlay_patch_sha256="0b710a3c531fbceb2030f369a397484d7579401eb5f101c9f18aa055764b276a"'   "$STAGE" "$NEW_IMAGE" >/dev/null
dc rm -f "$STAGE" >/dev/null

say "4/9 OFFLINE ACCEPTANCE — NO NETWORK / NO BROKER CALLS"
dc run --rm --entrypoint python "$NEW_IMAGE" - <<'PY'
import time
from app.runtime.state import RuntimeState
from app.domain import Origin,Venue,Signal
from app.addons.fresh_selection_guard import FreshSelectionGuard

st=RuntimeState(); now=time.time()
# 45 historical saturated pins: preserved on Candidate, must lose realtime membership.
for i in range(45):
    code=f"8{i:05d}"; c=st.candidate(code,code,Origin.TODAY_NEW)
    c.live_track_pin=True
    c.metrics['discovery_scout_score']=10
    st.pinned_codes.add(code)
# 3 current hard pins.
for i in range(3):
    code=f"7{i:05d}"; c=st.candidate(code,code,Origin.TODAY_NEW)
    c.live_track_pin=True; c.entry_state='BUY' if i==0 else 'DISCOVERY'
    if i:
        c.last_signal=Signal(code,Venue.KRX,100,1,now-60,'x',1)
    st.pinned_codes.add(code)
# 40 fresh candidates.
for i in range(40):
    code=f"6{i:05d}"; c=st.candidate(code,code,Origin.TODAY_NEW)
    c.source_hits['volume_surge']=now
    c.metrics.update({'fresh_scout_fast_track':True,'discovery_scout_score':80-i*.1,'early_edge_score':60-i*.1})
    v=c.venue_state[Venue.KRX]; v.last_tick_at=now; v.last_price=1000+i; v.metrics['fresh']=True

g=FreshSelectionGuard(st)
out=g.reconcile_once()
assert out['hard_pins']==3, out
assert out['soft_history']==45, out
assert out['selected_fresh']>=20, out
assert all(st.candidates[x].live_track_pin for x in [f"8{i:05d}" for i in range(45)])
assert len(st.pinned_codes)==3
assert set(st.pinned_codes).issubset(st.hot_codes)
assert out['contracts']['pre_buy_nxt_score_formula_changed'] is False
assert out['contracts']['new_rest_calls']==0
assert out['contracts']['new_ws_subscription_types']==0
print("FRESH_SELECTION_OVERLAY_ACCEPTANCE=PASS",out)
PY

say "5/9 VERIFY PROTECTED CORE IN DERIVED IMAGE STILL BYTE-IDENTICAL"
check_image_hash(){
  rel="$1"; want="$2"
  got="$(dc run --rm --entrypoint sha256sum "$NEW_IMAGE" "/app/$rel" | awk '{print $1}')"
  [ "$got" = "$want" ] || { echo "FAIL derived protected hash $rel"; exit 8; }
}
check_image_hash "app/signal/policy.py" "18cb96ef1afb9de48136d39c3e9b8216e62a94dccf0229aa027479783eb9151a"
check_image_hash "app/broker/kiwoom.py" "e10d936a2540a70d8a488e0460608a3c2a1a8bfaf95dc6206e706cce3afab0d1"
check_image_hash "app/broker/websocket.py" "50fefc5faa1457210af758636279bea0bc3926e505bc91317962a0d451e35602"
check_image_hash "app/broker/discovery.py" "2b12de4c44af1242287c5b9883c2ffc4e646522d13a0dfa0a243c3e4c024fa59"
check_image_hash "app/service.py" "e325b7a76d6ddfa291b800ef97fb13e6b85fa9bb9ccb2365130ef2d5abf512c3"
check_image_hash "app/addons/energy_path.py" "cd403cda76cb9d515c9228bf310287ad639bed125075fa835a3607cac2e81595"
check_image_hash "app/runtime/state.py" "28e835a781ed4a0a00bf4ab1fb1f2dcfb6c3c23ed77750c492788a168c80451b"
echo "PROTECTED_CORE=UNCHANGED"

say "6/9 CAPTURE CURRENT RUNTIME CONTRACT"
dc inspect "$APP" > "$WORK/inspect.json"
dc inspect "$APP" -f '{{range .Config.Env}}{{println .}}{{end}}' > "$WORK/env.list"
python3 - "$WORK/inspect.json" "$WORK/env.list" "$WORK/run.args" "$NEW_IMAGE" <<'PY'
import json,sys
insp,envf,outf,image=sys.argv[1:]
o=json.load(open(insp))[0]; h=o.get("HostConfig") or {}; c=o.get("Config") or {}
a=["docker","run","-d","--name","quant-nova"]
if h.get("Init") is True:a+=["--init"]
net=h.get("NetworkMode") or ""
if net and net not in ("default","bridge"):a+=["--network",net]
rp=h.get("RestartPolicy") or {};rn=rp.get("Name") or "";mx=int(rp.get("MaximumRetryCount") or 0)
if rn and rn!="no":a+=["--restart",f"{rn}:{mx}" if rn=="on-failure" and mx else rn]
for m in o.get("Mounts") or []:
    typ=m.get("Type");src=m.get("Source");dst=m.get("Destination")
    if typ in ("bind","volume") and src and dst:
        spec=f"type={typ},src={src},dst={dst}"
        if not m.get("RW",True):spec+=",readonly"
        a+=["--mount",spec]
for line in open(envf,encoding="utf-8",errors="replace"):
    line=line.rstrip("\n")
    if line:a+=["-e",line]
user=c.get("User") or ""
if user:a+=["--user",user]
wd=c.get("WorkingDir") or ""
if wd:a+=["--workdir",wd]
for cp,bindings in (h.get("PortBindings") or {}).items():
    for b in bindings or []:
        hp=str((b or {}).get("HostPort") or "");hi=str((b or {}).get("HostIp") or "")
        if hp:a+=["-p",f"{hi+':' if hi else ''}{hp}:{cp.split('/')[0]}"]
a+=[image]
if c.get("Cmd"):a+=list(c["Cmd"])
open(outf,"wb").write(b"\0".join(x.encode() for x in a))
PY

say "7/9 CUTOVER ONLY quant-nova"
dc stop -t 15 "$APP" >/dev/null
dc rename "$APP" "$BACKUP"
CUTOVER=1
python3 - "$WORK/run.args" <<'PY'
import subprocess,sys
a=[x.decode() for x in open(sys.argv[1],"rb").read().split(b"\0") if x]
subprocess.run(a,check=True)
PY

say "8/9 REQUIRE LIVEZ/READYZ + OVERLAY STATUS"
GOOD=0
for i in $(seq 1 45); do
  sleep 2
  set +e
  OUT="$(dc exec "$APP" python - <<'PY'
import json,urllib.request,sys
def g(p):
    return json.load(urllib.request.urlopen("http://127.0.0.1:8000"+p,timeout=5))
l=g("/api/livez");r=g("/api/readyz");f=g("/api/fresh-selection-guard")
print(json.dumps({"live":l,"ready":r,"fresh_guard":f},ensure_ascii=False))
sys.exit(0 if l.get("ok") and r.get("ok") and f.get("ok") and f.get("generation",0)>0 else 1)
PY
)"
  RC=$?
  set -e
  echo "$OUT"
  if [ "$RC" -eq 0 ]; then GOOD=$((GOOD+1)); else GOOD=0; fi
  [ "$GOOD" -ge 3 ] && break
done
[ "$GOOD" -ge 3 ] || { echo "FAIL startup/overlay acceptance"; exit 20; }

say "9/9 FINAL LIVE OBSERVATION"
dc stats "$APP" --no-stream --format 'CPU={{.CPUPerc}} MEM={{.MemUsage}} PIDS={{.PIDs}}'
dc exec "$APP" python - <<'PY'
import json,urllib.request
for p in ("/api/fresh-selection-guard","/api/realtime-health","/api/feed-truth"):
    try:
        j=json.load(urllib.request.urlopen("http://127.0.0.1:8000"+p,timeout=8))
        print(p,json.dumps(j,ensure_ascii=False)[:3500])
    except Exception as e: print(p,"ERROR",repr(e))
PY

SUCCESS=1
trap - EXIT INT TERM
echo
echo "===== SUCCESS ====="
echo "RESULT=SUCCESS"
echo "ARCHITECTURE=SELECTION_OVERLAY_NO_CORE_REBUILD"
echo "PROTECTED_CORE=BYTE_IDENTICAL"
echo "PRE_BUY_NXT_SCORE_FORMULAS=UNCHANGED"
echo "ENTRY_POLICY=UNCHANGED"
echo "HISTORY=UNDELETED"
echo "STALE_256_HISTORY=RETAINED_BUT_REALTIME_PRIORITY_REMOVED"
echo "NEW_REST_CALLS=0"
echo "NEW_WS_TYPES=0"
echo "GAP_SCOPE=EXISTING_PIN_HOT_RECOVERY_NOW_RECEIVES_FRESH_MEMBERSHIP_SETS"
echo "BACKUP=$BACKUP"
echo "NEW_IMAGE=$NEW_IMAGE"
echo "LOG=$LOG"
