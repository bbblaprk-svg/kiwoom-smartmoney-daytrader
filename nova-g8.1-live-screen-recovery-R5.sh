#!/usr/bin/env bash
set -Eeuo pipefail

# QUANT NOVA G8.1 LIVE SCREEN RECOVERY R5
#
# FIX SCOPE
#   - 현재가/후보/성과 화면이 고정되는 프런트 표시 경로만 보강
#   - 기존 WebSocket은 그대로 유지
#   - 2초마다 /api/live-dashboard를 no-store + cache-busting으로 읽어 render
#
# NEVER CHANGED
#   - quant-nova 프로세스
#   - Kiwoom REST/WebSocket 구독
#   - BUY / BUY_READY / PREBUY 판정
#   - 점수 / 반복신호 / DB / WAL
#
# DEPLOYMENT
#   - nova-http-guard의 HOST bind source만 수정
#   - guard만 restart
#   - 적용 전/후 py_compile
#   - 실패 시 host guard 자동 원복
#   - quant-nova RestartCount 불변 검증

NOVA_CONTAINER="${NOVA_CONTAINER:-quant-nova}"
GUARD_CONTAINER="${GUARD_CONTAINER:-nova-http-guard}"
PUBLIC_BASE="${PUBLIC_BASE:-https://3-38-25-20.nip.io}"

STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP_DIR="${HOME}/nova-g8-r5-backup-${STAMP}"
ORIG="${HOME}/http_guard.r5.orig.${STAMP}.py"
PATCHED="${HOME}/http_guard.r5.${STAMP}.py"
SELFTEST_DIR="${HOME}/nova-r5-selftest-${STAMP}"

log(){ printf '\n[%s] %s\n' "$(date '+%H:%M:%S')" "$*"; }
die(){ echo "ERROR: $*" >&2; exit 1; }

HOST_GUARD=""
ROLLBACK_ARMED=0
NOVA_RESTARTS_BEFORE=""

rollback(){
  rc=$?
  if [ "$rc" -ne 0 ] && [ "$ROLLBACK_ARMED" = "1" ] && [ -n "$HOST_GUARD" ] && [ -f "$ORIG" ]; then
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
NOVA_IMAGE="$(sudo docker inspect "$NOVA_CONTAINER" --format '{{.Config.Image}}')"

echo "NOVA_STATUS_BEFORE=$NOVA_STATUS_BEFORE"
echo "NOVA_RESTARTS_BEFORE=$NOVA_RESTARTS_BEFORE"
echo "NOVA_IMAGE=$NOVA_IMAGE"
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

log "2. build R5 patcher helper"
cat > "${HOME}/nova-r5-patcher-${STAMP}.py" <<'PY'
import pathlib, sys, base64

LIVE_POLL_B64 = 'LypfX05PVkFfTElWRV9QT0xMX1I1X18qLwooZnVuY3Rpb24oKXsKICBsZXQgYnVzeT1mYWxzZTsKICBsZXQgdGltZXI9bnVsbDsKCiAgYXN5bmMgZnVuY3Rpb24gcG9sbE9uY2UoKXsKICAgIGlmKGJ1c3kgfHwgIXRva2VuKSByZXR1cm47CiAgICBidXN5PXRydWU7CiAgICB0cnl7CiAgICAgIGNvbnN0IHI9YXdhaXQgZmV0Y2goJy9hcGkvbGl2ZS1kYXNoYm9hcmQ/bm92YV9yNT0nK0RhdGUubm93KCksewogICAgICAgIG1ldGhvZDonR0VUJywKICAgICAgICBjYWNoZTonbm8tc3RvcmUnLAogICAgICAgIGhlYWRlcnM6ewogICAgICAgICAgJ0F1dGhvcml6YXRpb24nOidCZWFyZXIgJyt0b2tlbiwKICAgICAgICAgICdDYWNoZS1Db250cm9sJzonbm8tY2FjaGUnLAogICAgICAgICAgJ1ByYWdtYSc6J25vLWNhY2hlJwogICAgICAgIH0KICAgICAgfSk7CgogICAgICBpZihyLnN0YXR1cz09PTQwMSB8fCByLnN0YXR1cz09PTQwMyl7CiAgICAgICAgbG9jYWxTdG9yYWdlLnJlbW92ZUl0ZW0oJ25vdmFfdG9rZW4nKTsKICAgICAgICB0b2tlbj0nJzsKICAgICAgICByZXR1cm47CiAgICAgIH0KICAgICAgaWYoIXIub2spIHJldHVybjsKCiAgICAgIGNvbnN0IG1zZz1hd2FpdCByLmpzb24oKTsKICAgICAgY29uc3QgbmV4dD1hcHBseVBheWxvYWQobXNnKTsKICAgICAgaWYobmV4dCl7CiAgICAgICAgcmVuZGVyKG5leHQpOwogICAgICB9ZWxzZSBpZihtc2cgJiYgbXNnLnR5cGU9PT0nc25hcHNob3QnKXsKICAgICAgICByZW5kZXIobXNnKTsKICAgICAgfQogICAgfWNhdGNoKGUpewogICAgICBjb25zb2xlLmVycm9yKCdOT1ZBX1I1X0xJVkVfUE9MTCcsZSk7CiAgICB9ZmluYWxseXsKICAgICAgYnVzeT1mYWxzZTsKICAgIH0KICB9CgogIGZ1bmN0aW9uIHN0YXJ0KCl7CiAgICBpZih0aW1lcikgcmV0dXJuOwogICAgcG9sbE9uY2UoKTsKICAgIHRpbWVyPXNldEludGVydmFsKHBvbGxPbmNlLDIwMDApOwogIH0KCiAgaWYoZG9jdW1lbnQucmVhZHlTdGF0ZT09PSdsb2FkaW5nJyl7CiAgICBkb2N1bWVudC5hZGRFdmVudExpc3RlbmVyKCdET01Db250ZW50TG9hZGVkJywoKT0+c2V0VGltZW91dChzdGFydCw4MDApLHtvbmNlOnRydWV9KTsKICB9ZWxzZXsKICAgIHNldFRpbWVvdXQoc3RhcnQsODAwKTsKICB9Cn0pKCk7Cg=='

def patch_source(src: str) -> str:
    if "__NOVA_G8_R5__" in src:
        return src

    main = None
    for marker in ('if __name__=="__main__":', "if __name__ == '__main__':"):
        if marker in src:
            main = marker
            break
    if not main:
        raise RuntimeError("MAIN_MARKER_NOT_FOUND")

    helper = f'''
# __NOVA_G8_R5__
def _nova_g8_r5_patch_live_poll():
    import base64
    try:
        rec = _static_mem.get("/static/nova.js")
        if not rec:
            print("NOVA_R5:STATIC_MISSING", flush=True)
            return False

        ct, body = rec
        text = body if isinstance(body, str) else body.decode("utf-8")

        if "__NOVA_LIVE_POLL_R5__" in text:
            print("NOVA_R5:ALREADY_PATCHED", flush=True)
            return True

        addon = base64.b64decode('LypfX05PVkFfTElWRV9QT0xMX1I1X18qLwooZnVuY3Rpb24oKXsKICBsZXQgYnVzeT1mYWxzZTsKICBsZXQgdGltZXI9bnVsbDsKCiAgYXN5bmMgZnVuY3Rpb24gcG9sbE9uY2UoKXsKICAgIGlmKGJ1c3kgfHwgIXRva2VuKSByZXR1cm47CiAgICBidXN5PXRydWU7CiAgICB0cnl7CiAgICAgIGNvbnN0IHI9YXdhaXQgZmV0Y2goJy9hcGkvbGl2ZS1kYXNoYm9hcmQ/bm92YV9yNT0nK0RhdGUubm93KCksewogICAgICAgIG1ldGhvZDonR0VUJywKICAgICAgICBjYWNoZTonbm8tc3RvcmUnLAogICAgICAgIGhlYWRlcnM6ewogICAgICAgICAgJ0F1dGhvcml6YXRpb24nOidCZWFyZXIgJyt0b2tlbiwKICAgICAgICAgICdDYWNoZS1Db250cm9sJzonbm8tY2FjaGUnLAogICAgICAgICAgJ1ByYWdtYSc6J25vLWNhY2hlJwogICAgICAgIH0KICAgICAgfSk7CgogICAgICBpZihyLnN0YXR1cz09PTQwMSB8fCByLnN0YXR1cz09PTQwMyl7CiAgICAgICAgbG9jYWxTdG9yYWdlLnJlbW92ZUl0ZW0oJ25vdmFfdG9rZW4nKTsKICAgICAgICB0b2tlbj0nJzsKICAgICAgICByZXR1cm47CiAgICAgIH0KICAgICAgaWYoIXIub2spIHJldHVybjsKCiAgICAgIGNvbnN0IG1zZz1hd2FpdCByLmpzb24oKTsKICAgICAgY29uc3QgbmV4dD1hcHBseVBheWxvYWQobXNnKTsKICAgICAgaWYobmV4dCl7CiAgICAgICAgcmVuZGVyKG5leHQpOwogICAgICB9ZWxzZSBpZihtc2cgJiYgbXNnLnR5cGU9PT0nc25hcHNob3QnKXsKICAgICAgICByZW5kZXIobXNnKTsKICAgICAgfQogICAgfWNhdGNoKGUpewogICAgICBjb25zb2xlLmVycm9yKCdOT1ZBX1I1X0xJVkVfUE9MTCcsZSk7CiAgICB9ZmluYWxseXsKICAgICAgYnVzeT1mYWxzZTsKICAgIH0KICB9CgogIGZ1bmN0aW9uIHN0YXJ0KCl7CiAgICBpZih0aW1lcikgcmV0dXJuOwogICAgcG9sbE9uY2UoKTsKICAgIHRpbWVyPXNldEludGVydmFsKHBvbGxPbmNlLDIwMDApOwogIH0KCiAgaWYoZG9jdW1lbnQucmVhZHlTdGF0ZT09PSdsb2FkaW5nJyl7CiAgICBkb2N1bWVudC5hZGRFdmVudExpc3RlbmVyKCdET01Db250ZW50TG9hZGVkJywoKT0+c2V0VGltZW91dChzdGFydCw4MDApLHtvbmNlOnRydWV9KTsKICB9ZWxzZXsKICAgIHNldFRpbWVvdXQoc3RhcnQsODAwKTsKICB9Cn0pKCk7Cg==').decode("utf-8")
        patched = text + chr(10) + addon + chr(10)
        _static_mem["/static/nova.js"] = (ct, patched.encode("utf-8"))

        print("NOVA_R5:PATCHED", flush=True)
        return True
    except Exception as e:
        print("NOVA_R5:ERROR", repr(e), flush=True)
        return False
'''

    out = src.replace(main, helper + "\n" + main, 1)

    r3_call = (
        "    if not _nova_g8_r3_patch_frontend():\n"
        "        raise SystemExit('NOVA_R3_FRONTEND_PATCH_FAILED')"
    )

    if r3_call in out:
        replacement = (
            r3_call
            + "\n    if not _nova_g8_r5_patch_live_poll():"
            + "\n        raise SystemExit('NOVA_R5_LIVE_POLL_PATCH_FAILED')"
        )
        out = out.replace(r3_call, replacement, 1)
    elif "    preload_static()" in out:
        replacement = (
            "    preload_static()"
            + "\n    if not _nova_g8_r5_patch_live_poll():"
            + "\n        raise SystemExit('NOVA_R5_LIVE_POLL_PATCH_FAILED')"
        )
        out = out.replace("    preload_static()", replacement, 1)
    else:
        raise RuntimeError("PRELOAD_OR_R3_CALL_NOT_FOUND")

    return out

src_path = pathlib.Path(sys.argv[1])
dst_path = pathlib.Path(sys.argv[2])
source = src_path.read_text(encoding="utf-8")
patched = patch_source(source)
dst_path.write_text(patched, encoding="utf-8")

print("R5_PATCH_BUILD=PASS")
PY

PATCHER="${HOME}/nova-r5-patcher-${STAMP}.py"
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

python3 "$PATCHER" "$SELFTEST_DIR/fixture.py" "$SELFTEST_DIR/fixture.r5.py"
python3 -m py_compile "$SELFTEST_DIR/fixture.r5.py"
grep -q "__NOVA_G8_R5__" "$SELFTEST_DIR/fixture.r5.py" || die "self-test guard marker missing"
grep -q "__NOVA_LIVE_POLL_R5__" "$SELFTEST_DIR/fixture.r5.py" || die "self-test JS marker missing"
python3 "$SELFTEST_DIR/fixture.r5.py" | grep -q "NOVA_R5:PATCHED" || die "self-test runtime injection failed"
echo "R5_SYNTHETIC_SELFTEST=PASS"

log "4. patch REAL guard source OFFLINE"
python3 "$PATCHER" "$ORIG" "$PATCHED"
python3 -m py_compile "$PATCHED"
grep -q "__NOVA_G8_R5__" "$PATCHED" || die "real patched guard marker missing"
grep -q "__NOVA_LIVE_POLL_R5__" "$PATCHED" || die "real patched JS marker missing"
echo "REAL_PATCH_PY_COMPILE=PASS"
echo "PATCHED_SHA256=$(sha256sum "$PATCHED" | awk '{print $1}')"
cp "$PATCHED" "$BACKUP_DIR/http_guard.py.r5"

log "5. install patched HOST guard source"
ROLLBACK_ARMED=1
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

log "7. verify guard actually loaded R5"
LOGS="$(sudo docker logs --tail 200 "$GUARD_CONTAINER" 2>&1 || true)"
printf '%s\n' "$LOGS" | tail -80
printf '%s\n' "$LOGS" | grep -q "NOVA_R5:PATCHED\|NOVA_R5:ALREADY_PATCHED" \
  || die "guard did not load R5"

log "8. verify PUBLIC nova.js contains R3 auth + R5 live poll"
PUB="${HOME}/nova-r5-public-${STAMP}.js"
curl -sk --max-time 8 "${PUBLIC_BASE}/static/nova.js?nova_r5_verify=${STAMP}" -o "$PUB"

grep -q "__NOVA_INLINE_AUTH_V3__" "$PUB" || die "R3 auth marker missing from public JS"
grep -q "__NOVA_LIVE_POLL_R5__" "$PUB" || die "R5 live poll marker missing from public JS"

echo "PUBLIC_R3_AUTH=YES"
echo "PUBLIC_R5_LIVE_POLL=YES"
echo "PUBLIC_JS_BYTES=$(wc -c < "$PUB" | tr -d ' ')"
echo "PUBLIC_JS_SHA256=$(sha256sum "$PUB" | awk '{print $1}')"
rm -f "$PUB"

log "9. verify protected APIs and dashboard freshness"
TOKEN="$(
  sudo docker inspect "$NOVA_CONTAINER" \
    --format '{{range .Config.Env}}{{println .}}{{end}}' \
  | sed -n 's/^APP_ACCESS_TOKEN=//p' | head -1
)"
[ -n "$TOKEN" ] || die "APP_ACCESS_TOKEN missing"

FAIL=0
TMP="${HOME}/nova-r5-api-${STAMP}.tmp"

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
    "${PUBLIC_BASE}${API}?nova_r5_check=$(date +%s%N)" || true)"
  printf '%-34s HTTP %s\n' "$API" "$CODE"
  [ "$CODE" = "200" ] || FAIL=1
done

[ "$FAIL" = "0" ] || die "one or more protected APIs are not HTTP 200"

A="${HOME}/nova-r5-a-${STAMP}.json"
B="${HOME}/nova-r5-b-${STAMP}.json"

curl -sk --max-time 8 -H "Authorization: Bearer $TOKEN" \
  "${PUBLIC_BASE}/api/live-dashboard?nova_r5_a=$(date +%s%N)" -o "$A"
sleep 3
curl -sk --max-time 8 -H "Authorization: Bearer $TOKEN" \
  "${PUBLIC_BASE}/api/live-dashboard?nova_r5_b=$(date +%s%N)" -o "$B"

python3 - "$A" "$B" <<'PY'
import json, sys
a=json.load(open(sys.argv[1],encoding="utf-8"))
b=json.load(open(sys.argv[2],encoding="utf-8"))

print("A_GENERATION=",a.get("generation"),"A_AT=",a.get("generated_at"))
print("B_GENERATION=",b.get("generation"),"B_AT=",b.get("generated_at"))
print("FEED=",b.get("feed_state"),"PHASE=",b.get("phase"))

if a.get("generation") == b.get("generation") and a.get("generated_at") == b.get("generated_at"):
    raise SystemExit("DASHBOARD_SNAPSHOT_NOT_ADVANCING")

print("DASHBOARD_SNAPSHOT_ADVANCE=YES")
PY

rm -f "$TMP" "$A" "$B"
unset TOKEN

log "10. prove quant-nova remained untouched"
NOVA_STATUS_AFTER="$(sudo docker inspect "$NOVA_CONTAINER" --format '{{.State.Status}}')"
NOVA_RESTARTS_AFTER="$(sudo docker inspect "$NOVA_CONTAINER" --format '{{.RestartCount}}')"

echo "NOVA_STATUS_AFTER=$NOVA_STATUS_AFTER"
echo "NOVA_RESTARTS_AFTER=$NOVA_RESTARTS_AFTER"

[ "$NOVA_STATUS_AFTER" = "running" ] || die "quant-nova is not running"
[ "$NOVA_RESTARTS_AFTER" = "$NOVA_RESTARTS_BEFORE" ] || die "quant-nova restart count changed"

ROLLBACK_ARMED=0
trap - EXIT

rm -rf "$SELFTEST_DIR"
rm -f "$ORIG" "$PATCHED" "$PATCHER"

echo
echo "===== RESULT=PASS ====="
echo "R5_SYNTHETIC_SELFTEST=PASS"
echo "REAL_PATCH_PY_COMPILE=PASS"
echo "PUBLIC_R3_AUTH=YES"
echo "PUBLIC_R5_LIVE_POLL=YES"
echo "DASHBOARD_SNAPSHOT_ADVANCE=YES"
echo "NOVA_RESTARTS=$NOVA_RESTARTS_AFTER"
echo "BACKUP_DIR=$BACKUP_DIR"
echo
echo "NEXT=Safari의 기존 QUANT NOVA 탭을 완전히 닫고 새 탭에서 $PUBLIC_BASE 접속"
