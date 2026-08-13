#!/usr/bin/env bash
set -Eeuo pipefail

# QUANT NOVA G8.1 LIVE SCREEN RECOVERY R6
# R5 self-test의 pipefail/BrokenPipe 문제를 제거한 검증판.
# quant-nova 본체/BUY/점수/DB/WAL/WS 구독은 건드리지 않는다.
# nova-http-guard의 HOST bind source만 수정하고 guard만 재시작한다.
# 실패 시 자동 원복한다.

NOVA_CONTAINER="${NOVA_CONTAINER:-quant-nova}"
GUARD_CONTAINER="${GUARD_CONTAINER:-nova-http-guard}"
PUBLIC_BASE="${PUBLIC_BASE:-https://3-38-25-20.nip.io}"

STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP_DIR="${HOME}/nova-g8-r6-backup-${STAMP}"
ORIG="${HOME}/http_guard.r6.orig.${STAMP}.py"
PATCHED="${HOME}/http_guard.r6.${STAMP}.py"
PATCHER="${HOME}/nova-r6-patcher-${STAMP}.py"
SELFTEST_DIR="${HOME}/nova-r6-selftest-${STAMP}"

log(){ printf '\n[%s] %s\n' "$(date '+%H:%M:%S')" "$*"; }
die(){ echo "ERROR: $*" >&2; exit 1; }

HOST_GUARD=""
ARMED=0
NOVA_RESTARTS_BEFORE=""

rollback(){
  rc=$?
  if [ "$rc" -ne 0 ] && [ "$ARMED" = "1" ] && [ -n "$HOST_GUARD" ] && [ -f "$ORIG" ]; then
    echo
    echo "===== AUTO ROLLBACK ====="
    sudo sh -c "cat '$ORIG' > '$HOST_GUARD'" || true
    sudo python3 -m py_compile "$HOST_GUARD" >/dev/null 2>&1 || true
    sudo docker restart "$GUARD_CONTAINER" >/dev/null 2>&1 || true
    echo "ROLLBACK_ATTEMPTED=YES"
  fi
  exit "$rc"
}
trap rollback EXIT

log "0. preflight"
sudo docker inspect "$NOVA_CONTAINER" >/dev/null 2>&1 || die "$NOVA_CONTAINER not found"
sudo docker inspect "$GUARD_CONTAINER" >/dev/null 2>&1 || die "$GUARD_CONTAINER not found"

NOVA_STATUS_BEFORE="$(sudo docker inspect "$NOVA_CONTAINER" --format '{{.State.Status}}')"
NOVA_RESTARTS_BEFORE="$(sudo docker inspect "$NOVA_CONTAINER" --format '{{.RestartCount}}')"
echo "NOVA_STATUS_BEFORE=$NOVA_STATUS_BEFORE"
echo "NOVA_RESTARTS_BEFORE=$NOVA_RESTARTS_BEFORE"
[ "$NOVA_STATUS_BEFORE" = "running" ] || die "quant-nova is not running"

log "1. locate guard HOST bind source"
HOST_GUARD="$(
  sudo docker inspect "$GUARD_CONTAINER" \
    --format '{{range .Mounts}}{{if eq .Destination "/srv/http_guard.py"}}{{.Source}}{{end}}{{end}}'
)"
[ -n "$HOST_GUARD" ] || die "/srv/http_guard.py host bind source not found"
sudo test -f "$HOST_GUARD" || die "guard host source missing: $HOST_GUARD"
echo "HOST_GUARD=$HOST_GUARD"

mkdir -p "$BACKUP_DIR"
sudo cp "$HOST_GUARD" "$ORIG"
sudo cp "$HOST_GUARD" "$BACKUP_DIR/http_guard.py.before"
sudo chown "$(id -u):$(id -g)" "$ORIG" "$BACKUP_DIR/http_guard.py.before" || true
echo "ORIGINAL_SHA256=$(sha256sum "$ORIG" | awk '{print $1}')"

log "2. build R6 patcher helper"
cat > "$PATCHER" <<'PY'
import pathlib, sys, base64

LIVE_POLL_B64 = 'LypfX05PVkFfTElWRV9QT0xMX1I2X18qLwooZnVuY3Rpb24oKXsKICBsZXQgYnVzeT1mYWxzZTsKICBsZXQgdGltZXI9bnVsbDsKCiAgYXN5bmMgZnVuY3Rpb24gcG9sbE9uY2UoKXsKICAgIGlmKGJ1c3kgfHwgIXRva2VuKSByZXR1cm47CiAgICBidXN5PXRydWU7CiAgICB0cnl7CiAgICAgIGNvbnN0IHI9YXdhaXQgZmV0Y2goJy9hcGkvbGl2ZS1kYXNoYm9hcmQ/bm92YV9yNj0nK0RhdGUubm93KCksewogICAgICAgIG1ldGhvZDonR0VUJywKICAgICAgICBjYWNoZTonbm8tc3RvcmUnLAogICAgICAgIGhlYWRlcnM6ewogICAgICAgICAgJ0F1dGhvcml6YXRpb24nOidCZWFyZXIgJyt0b2tlbiwKICAgICAgICAgICdDYWNoZS1Db250cm9sJzonbm8tY2FjaGUnLAogICAgICAgICAgJ1ByYWdtYSc6J25vLWNhY2hlJwogICAgICAgIH0KICAgICAgfSk7CiAgICAgIGlmKHIuc3RhdHVzPT09NDAxIHx8IHIuc3RhdHVzPT09NDAzKXsKICAgICAgICBsb2NhbFN0b3JhZ2UucmVtb3ZlSXRlbSgnbm92YV90b2tlbicpOwogICAgICAgIHRva2VuPScnOwogICAgICAgIHJldHVybjsKICAgICAgfQogICAgICBpZighci5vaykgcmV0dXJuOwoKICAgICAgY29uc3QgbXNnPWF3YWl0IHIuanNvbigpOwogICAgICBjb25zdCBuZXh0PWFwcGx5UGF5bG9hZChtc2cpOwogICAgICBpZihuZXh0KXsKICAgICAgICByZW5kZXIobmV4dCk7CiAgICAgIH1lbHNlIGlmKG1zZyAmJiBtc2cudHlwZT09PSdzbmFwc2hvdCcpewogICAgICAgIHJlbmRlcihtc2cpOwogICAgICB9CiAgICB9Y2F0Y2goZSl7CiAgICAgIGNvbnNvbGUuZXJyb3IoJ05PVkFfUjZfTElWRV9QT0xMJyxlKTsKICAgIH1maW5hbGx5ewogICAgICBidXN5PWZhbHNlOwogICAgfQogIH0KCiAgZnVuY3Rpb24gc3RhcnQoKXsKICAgIGlmKHRpbWVyKSByZXR1cm47CiAgICBwb2xsT25jZSgpOwogICAgdGltZXI9c2V0SW50ZXJ2YWwocG9sbE9uY2UsMjAwMCk7CiAgfQoKICBpZihkb2N1bWVudC5yZWFkeVN0YXRlPT09J2xvYWRpbmcnKXsKICAgIGRvY3VtZW50LmFkZEV2ZW50TGlzdGVuZXIoJ0RPTUNvbnRlbnRMb2FkZWQnLCgpPT5zZXRUaW1lb3V0KHN0YXJ0LDgwMCkse29uY2U6dHJ1ZX0pOwogIH1lbHNlewogICAgc2V0VGltZW91dChzdGFydCw4MDApOwogIH0KfSkoKTsK'

def patch_source(src: str) -> str:
    if "__NOVA_G8_R6__" in src:
        return src

    main = None
    for marker in ('if __name__=="__main__":', "if __name__ == '__main__':"):
        if marker in src:
            main = marker
            break
    if not main:
        raise RuntimeError("MAIN_MARKER_NOT_FOUND")

    helper = f'''
# __NOVA_G8_R6__
def _nova_g8_r6_patch_live_poll():
    import base64
    try:
        rec = _static_mem.get("/static/nova.js")
        if not rec:
            print("NOVA_R6:STATIC_MISSING", flush=True)
            return False

        ct, body = rec
        text = body if isinstance(body, str) else body.decode("utf-8")

        if "__NOVA_LIVE_POLL_R6__" in text:
            print("NOVA_R6:ALREADY_PATCHED", flush=True)
            return True

        addon = base64.b64decode('LypfX05PVkFfTElWRV9QT0xMX1I2X18qLwooZnVuY3Rpb24oKXsKICBsZXQgYnVzeT1mYWxzZTsKICBsZXQgdGltZXI9bnVsbDsKCiAgYXN5bmMgZnVuY3Rpb24gcG9sbE9uY2UoKXsKICAgIGlmKGJ1c3kgfHwgIXRva2VuKSByZXR1cm47CiAgICBidXN5PXRydWU7CiAgICB0cnl7CiAgICAgIGNvbnN0IHI9YXdhaXQgZmV0Y2goJy9hcGkvbGl2ZS1kYXNoYm9hcmQ/bm92YV9yNj0nK0RhdGUubm93KCksewogICAgICAgIG1ldGhvZDonR0VUJywKICAgICAgICBjYWNoZTonbm8tc3RvcmUnLAogICAgICAgIGhlYWRlcnM6ewogICAgICAgICAgJ0F1dGhvcml6YXRpb24nOidCZWFyZXIgJyt0b2tlbiwKICAgICAgICAgICdDYWNoZS1Db250cm9sJzonbm8tY2FjaGUnLAogICAgICAgICAgJ1ByYWdtYSc6J25vLWNhY2hlJwogICAgICAgIH0KICAgICAgfSk7CiAgICAgIGlmKHIuc3RhdHVzPT09NDAxIHx8IHIuc3RhdHVzPT09NDAzKXsKICAgICAgICBsb2NhbFN0b3JhZ2UucmVtb3ZlSXRlbSgnbm92YV90b2tlbicpOwogICAgICAgIHRva2VuPScnOwogICAgICAgIHJldHVybjsKICAgICAgfQogICAgICBpZighci5vaykgcmV0dXJuOwoKICAgICAgY29uc3QgbXNnPWF3YWl0IHIuanNvbigpOwogICAgICBjb25zdCBuZXh0PWFwcGx5UGF5bG9hZChtc2cpOwogICAgICBpZihuZXh0KXsKICAgICAgICByZW5kZXIobmV4dCk7CiAgICAgIH1lbHNlIGlmKG1zZyAmJiBtc2cudHlwZT09PSdzbmFwc2hvdCcpewogICAgICAgIHJlbmRlcihtc2cpOwogICAgICB9CiAgICB9Y2F0Y2goZSl7CiAgICAgIGNvbnNvbGUuZXJyb3IoJ05PVkFfUjZfTElWRV9QT0xMJyxlKTsKICAgIH1maW5hbGx5ewogICAgICBidXN5PWZhbHNlOwogICAgfQogIH0KCiAgZnVuY3Rpb24gc3RhcnQoKXsKICAgIGlmKHRpbWVyKSByZXR1cm47CiAgICBwb2xsT25jZSgpOwogICAgdGltZXI9c2V0SW50ZXJ2YWwocG9sbE9uY2UsMjAwMCk7CiAgfQoKICBpZihkb2N1bWVudC5yZWFkeVN0YXRlPT09J2xvYWRpbmcnKXsKICAgIGRvY3VtZW50LmFkZEV2ZW50TGlzdGVuZXIoJ0RPTUNvbnRlbnRMb2FkZWQnLCgpPT5zZXRUaW1lb3V0KHN0YXJ0LDgwMCkse29uY2U6dHJ1ZX0pOwogIH1lbHNlewogICAgc2V0VGltZW91dChzdGFydCw4MDApOwogIH0KfSkoKTsK').decode("utf-8")
        patched = text + chr(10) + addon + chr(10)
        _static_mem["/static/nova.js"] = (ct, patched.encode("utf-8"))

        print("NOVA_R6:PATCHED", flush=True)
        return True
    except Exception as e:
        print("NOVA_R6:ERROR", repr(e), flush=True)
        return False
'''

    out = src.replace(main, helper + "\n" + main, 1)

    r3_call = (
        "    if not _nova_g8_r3_patch_frontend():\n"
        "        raise SystemExit('NOVA_R3_FRONTEND_PATCH_FAILED')"
    )

    if r3_call in out:
        out = out.replace(
            r3_call,
            r3_call
            + "\n    if not _nova_g8_r6_patch_live_poll():"
            + "\n        raise SystemExit('NOVA_R6_LIVE_POLL_PATCH_FAILED')",
            1
        )
    elif "    preload_static()" in out:
        out = out.replace(
            "    preload_static()",
            "    preload_static()"
            + "\n    if not _nova_g8_r6_patch_live_poll():"
            + "\n        raise SystemExit('NOVA_R6_LIVE_POLL_PATCH_FAILED')",
            1
        )
    else:
        raise RuntimeError("PRELOAD_OR_R3_CALL_NOT_FOUND")

    return out

src_path = pathlib.Path(sys.argv[1])
dst_path = pathlib.Path(sys.argv[2])
source = src_path.read_text(encoding="utf-8")
dst_path.write_text(patch_source(source), encoding="utf-8")
print("R6_PATCH_BUILD=PASS")
PY

python3 -m py_compile "$PATCHER"
echo "PATCHER_PY_COMPILE=PASS"

log "3. mandatory synthetic self-test"
mkdir -p "$SELFTEST_DIR"
cat > "$SELFTEST_DIR/fixture.py" <<'PY'
_static_mem = {}

def preload_static():
    _static_mem["/static/nova.js"] = (
        "application/javascript",
        b"let token=''; function applyPayload(x){return x;} function render(x){} async function auth(){return true;} function connect(){}"
    )

def _nova_g8_r3_patch_frontend():
    return True

if __name__=="__main__":
    preload_static()
    if not _nova_g8_r3_patch_frontend():
        raise SystemExit('NOVA_R3_FRONTEND_PATCH_FAILED')
    print("fixture")
PY

python3 "$PATCHER" "$SELFTEST_DIR/fixture.py" "$SELFTEST_DIR/fixture.r6.py"
python3 -m py_compile "$SELFTEST_DIR/fixture.r6.py"
grep -q "__NOVA_G8_R6__" "$SELFTEST_DIR/fixture.r6.py" || die "self-test guard marker missing"
grep -q "__NOVA_LIVE_POLL_R6__" "$SELFTEST_DIR/fixture.r6.py" || die "self-test JS marker missing"

# 중요: grep 파이프로 Python stdout을 조기 종료시키지 않는다.
SELFTEST_OUT="$SELFTEST_DIR/runtime.out"
python3 "$SELFTEST_DIR/fixture.r6.py" > "$SELFTEST_OUT" 2>&1
grep -q "NOVA_R6:PATCHED" "$SELFTEST_OUT" || {
  cat "$SELFTEST_OUT"
  die "self-test runtime injection failed"
}
echo "R6_SYNTHETIC_SELFTEST=PASS"

log "4. patch REAL guard source OFFLINE"
python3 "$PATCHER" "$ORIG" "$PATCHED"
python3 -m py_compile "$PATCHED"
grep -q "__NOVA_G8_R6__" "$PATCHED" || die "real guard marker missing"
grep -q "__NOVA_LIVE_POLL_R6__" "$PATCHED" || die "real JS marker missing"
echo "REAL_PATCH_PY_COMPILE=PASS"
echo "PATCHED_SHA256=$(sha256sum "$PATCHED" | awk '{print $1}')"
cp "$PATCHED" "$BACKUP_DIR/http_guard.py.r6"

log "5. install HOST guard patch"
ARMED=1
sudo sh -c "cat '$PATCHED' > '$HOST_GUARD'"
sudo python3 -m py_compile "$HOST_GUARD"
echo "HOST_INSTALL_PY_COMPILE=PASS"

log "6. restart GUARD ONLY"
sudo docker restart "$GUARD_CONTAINER" >/dev/null

READY=0
for i in $(seq 1 30); do
  if sudo docker exec "$GUARD_CONTAINER" python -c \
    'import urllib.request; urllib.request.urlopen("http://127.0.0.1:8080/_guard/health",timeout=2)' \
    >/dev/null 2>&1; then
    READY=1
    echo "GUARD_READY=YES"
    break
  fi
  sleep 1
done
[ "$READY" = "1" ] || die "guard did not become ready"

log "7. verify guard loaded R6"
LOGS="$(sudo docker logs --tail 200 "$GUARD_CONTAINER" 2>&1 || true)"
printf '%s\n' "$LOGS" | tail -80
printf '%s\n' "$LOGS" | grep -q "NOVA_R6:PATCHED\|NOVA_R6:ALREADY_PATCHED" \
  || die "guard did not load R6"

log "8. verify PUBLIC JS"
PUB="${HOME}/nova-r6-public-${STAMP}.js"
curl -sk --max-time 8 "${PUBLIC_BASE}/static/nova.js?nova_r6_verify=${STAMP}" -o "$PUB"

grep -q "__NOVA_INLINE_AUTH_V3__" "$PUB" || die "R3 auth marker missing"
grep -q "__NOVA_LIVE_POLL_R6__" "$PUB" || die "R6 live poll marker missing"

echo "PUBLIC_R3_AUTH=YES"
echo "PUBLIC_R6_LIVE_POLL=YES"
echo "PUBLIC_JS_BYTES=$(wc -c < "$PUB" | tr -d ' ')"
echo "PUBLIC_JS_SHA256=$(sha256sum "$PUB" | awk '{print $1}')"
rm -f "$PUB"

log "9. verify protected APIs + dashboard advance"
TOKEN="$(
  sudo docker inspect "$NOVA_CONTAINER" \
    --format '{{range .Config.Env}}{{println .}}{{end}}' \
  | sed -n 's/^APP_ACCESS_TOKEN=//p' | head -1
)"
[ -n "$TOKEN" ] || die "APP_ACCESS_TOKEN missing"

FAIL=0
TMP="${HOME}/nova-r6-api-${STAMP}.tmp"

for API in \
  /api/live-dashboard \
  /api/prebuy-recommendations \
  /api/buy-signals \
  /api/nxt-alerts \
  /api/nxt-signal-table \
  /api/position-manager
do
  CODE="$(curl -sk --max-time 8 \
    -H "Authorization: Bearer $TOKEN" \
    -o "$TMP" \
    -w '%{http_code}' \
    "${PUBLIC_BASE}${API}?nova_r6_check=$(date +%s%N)" || true)"
  printf '%-34s HTTP %s\n' "$API" "$CODE"
  [ "$CODE" = "200" ] || FAIL=1
done
[ "$FAIL" = "0" ] || die "one or more APIs are not HTTP 200"

A="${HOME}/nova-r6-a-${STAMP}.json"
B="${HOME}/nova-r6-b-${STAMP}.json"

curl -sk --max-time 8 -H "Authorization: Bearer $TOKEN" \
  "${PUBLIC_BASE}/api/live-dashboard?nova_r6_a=$(date +%s%N)" -o "$A"
sleep 3
curl -sk --max-time 8 -H "Authorization: Bearer $TOKEN" \
  "${PUBLIC_BASE}/api/live-dashboard?nova_r6_b=$(date +%s%N)" -o "$B"

python3 - "$A" "$B" <<'PY'
import json,sys
a=json.load(open(sys.argv[1],encoding="utf-8"))
b=json.load(open(sys.argv[2],encoding="utf-8"))
print("A_GENERATION=",a.get("generation"),"A_AT=",a.get("generated_at"))
print("B_GENERATION=",b.get("generation"),"B_AT=",b.get("generated_at"))
print("FEED=",b.get("feed_state"),"PHASE=",b.get("phase"))
if a.get("generation")==b.get("generation") and a.get("generated_at")==b.get("generated_at"):
    raise SystemExit("DASHBOARD_SNAPSHOT_NOT_ADVANCING")
print("DASHBOARD_SNAPSHOT_ADVANCE=YES")
PY

rm -f "$TMP" "$A" "$B"
unset TOKEN

log "10. prove quant-nova untouched"
NOVA_STATUS_AFTER="$(sudo docker inspect "$NOVA_CONTAINER" --format '{{.State.Status}}')"
NOVA_RESTARTS_AFTER="$(sudo docker inspect "$NOVA_CONTAINER" --format '{{.RestartCount}}')"
echo "NOVA_STATUS_AFTER=$NOVA_STATUS_AFTER"
echo "NOVA_RESTARTS_AFTER=$NOVA_RESTARTS_AFTER"

[ "$NOVA_STATUS_AFTER" = "running" ] || die "quant-nova is not running"
[ "$NOVA_RESTARTS_AFTER" = "$NOVA_RESTARTS_BEFORE" ] || die "quant-nova restart count changed"

ARMED=0
trap - EXIT
rm -rf "$SELFTEST_DIR"
rm -f "$ORIG" "$PATCHED" "$PATCHER"

echo
echo "===== RESULT=PASS ====="
echo "R6_SYNTHETIC_SELFTEST=PASS"
echo "REAL_PATCH_PY_COMPILE=PASS"
echo "PUBLIC_R3_AUTH=YES"
echo "PUBLIC_R6_LIVE_POLL=YES"
echo "DASHBOARD_SNAPSHOT_ADVANCE=YES"
echo "NOVA_RESTARTS=$NOVA_RESTARTS_AFTER"
echo "BACKUP_DIR=$BACKUP_DIR"
echo "NEXT=Safari 기존 QUANT NOVA 탭을 완전히 닫고 새 탭에서 $PUBLIC_BASE 접속"
