#!/usr/bin/env bash
set -Eeuo pipefail

# QUANT NOVA G8.1 LIVE SCREEN RECOVERY R7
# WebSocket 상태와 무관하게 2초 dashboard polling을 항상 유지한다.
# quant-nova / Kiwoom / BUY / scoring / DB / WAL은 변경하지 않는다.
# nova-http-guard HOST bind source만 수정하고 guard만 restart한다.
# 실패 시 자동 rollback한다.

NOVA_CONTAINER="${NOVA_CONTAINER:-quant-nova}"
GUARD_CONTAINER="${GUARD_CONTAINER:-nova-http-guard}"
PUBLIC_BASE="${PUBLIC_BASE:-https://3-38-25-20.nip.io}"

STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP_DIR="${HOME}/nova-g8-r7-backup-${STAMP}"
ORIG="${HOME}/http_guard.r7.orig.${STAMP}.py"
PATCHED="${HOME}/http_guard.r7.${STAMP}.py"
PATCHER="${HOME}/nova-r7-patcher-${STAMP}.py"
SELFTEST_DIR="${HOME}/nova-r7-selftest-${STAMP}"

log(){ printf '\n[%s] %s\n' "$(date '+%H:%M:%S')" "$*"; }
die(){ echo "ERROR: $*" >&2; exit 1; }

HOST_GUARD=""
ARMED=0
NOVA_RESTARTS_BEFORE=""

rollback(){
  rc=$?
  if [ "$rc" -ne 0 ] && [ "$ARMED" = "1" ] && [ -n "$HOST_GUARD" ] && [ -f "$ORIG" ]; then
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
sudo test -f "$HOST_GUARD" || die "guard host source missing"
echo "HOST_GUARD=$HOST_GUARD"

mkdir -p "$BACKUP_DIR"
sudo cp "$HOST_GUARD" "$ORIG"
sudo cp "$HOST_GUARD" "$BACKUP_DIR/http_guard.py.before"
sudo chown "$(id -u):$(id -g)" "$ORIG" "$BACKUP_DIR/http_guard.py.before" || true
echo "ORIGINAL_SHA256=$(sha256sum "$ORIG" | awk '{print $1}')"

log "2. build R7 patcher"
cat > "$PATCHER" <<'PY'
import pathlib, sys, base64

LIVE_POLL_B64='LypfX05PVkFfQUxXQVlTX09OX1BPTExfUjdfXyovCihmdW5jdGlvbigpewogIGxldCBfX25vdmFSN0J1c3k9ZmFsc2U7CiAgbGV0IF9fbm92YVI3VGltZXI9bnVsbDsKCiAgYXN5bmMgZnVuY3Rpb24gX19ub3ZhUjdQb2xsKCl7CiAgICBpZihfX25vdmFSN0J1c3kgfHwgIXRva2VuKSByZXR1cm47CiAgICBfX25vdmFSN0J1c3k9dHJ1ZTsKICAgIHRyeXsKICAgICAgY29uc3Qgcj1hd2FpdCBmZXRjaCgnL2FwaS9saXZlLWRhc2hib2FyZD9ub3ZhX3I3PScrRGF0ZS5ub3coKSx7CiAgICAgICAgbWV0aG9kOidHRVQnLAogICAgICAgIGNhY2hlOiduby1zdG9yZScsCiAgICAgICAgaGVhZGVyczp7CiAgICAgICAgICAnQXV0aG9yaXphdGlvbic6J0JlYXJlciAnK3Rva2VuLAogICAgICAgICAgJ0NhY2hlLUNvbnRyb2wnOiduby1jYWNoZSwgbm8tc3RvcmUsIG1heC1hZ2U9MCcsCiAgICAgICAgICAnUHJhZ21hJzonbm8tY2FjaGUnCiAgICAgICAgfQogICAgICB9KTsKCiAgICAgIGlmKHIuc3RhdHVzPT09NDAxIHx8IHIuc3RhdHVzPT09NDAzKXsKICAgICAgICBsb2NhbFN0b3JhZ2UucmVtb3ZlSXRlbSgnbm92YV90b2tlbicpOwogICAgICAgIHRva2VuPScnOwogICAgICAgIHJldHVybjsKICAgICAgfQogICAgICBpZighci5vaykgcmV0dXJuOwoKICAgICAgY29uc3QgbXNnPWF3YWl0IHIuanNvbigpOwogICAgICBsZXQgbmV4dD1udWxsOwogICAgICB0cnl7IG5leHQ9YXBwbHlQYXlsb2FkKG1zZyk7IH1jYXRjaChlKXsgY29uc29sZS5lcnJvcignTk9WQV9SN19BUFBMWScsZSk7IH0KCiAgICAgIGlmKG5leHQpewogICAgICAgIHJlbmRlcihuZXh0KTsKICAgICAgfWVsc2UgaWYobXNnICYmIG1zZy50eXBlPT09J3NuYXBzaG90Jyl7CiAgICAgICAgcmVuZGVyKG1zZyk7CiAgICAgIH0KICAgIH1jYXRjaChlKXsKICAgICAgY29uc29sZS5lcnJvcignTk9WQV9SN19QT0xMJyxlKTsKICAgIH1maW5hbGx5ewogICAgICBfX25vdmFSN0J1c3k9ZmFsc2U7CiAgICB9CiAgfQoKICBmdW5jdGlvbiBfX25vdmFSN1N0YXJ0KCl7CiAgICBpZihfX25vdmFSN1RpbWVyKSByZXR1cm47CiAgICBfX25vdmFSN1BvbGwoKTsKICAgIF9fbm92YVI3VGltZXI9c2V0SW50ZXJ2YWwoX19ub3ZhUjdQb2xsLDIwMDApOwogICAgd2luZG93Ll9fbm92YVI3UG9sbD1fX25vdmFSN1BvbGw7CiAgICB3aW5kb3cuX19ub3ZhUjdUaW1lcj1fX25vdmFSN1RpbWVyOwogIH0KCiAgaWYoZG9jdW1lbnQucmVhZHlTdGF0ZT09PSdsb2FkaW5nJyl7CiAgICBkb2N1bWVudC5hZGRFdmVudExpc3RlbmVyKCdET01Db250ZW50TG9hZGVkJywoKT0+c2V0VGltZW91dChfX25vdmFSN1N0YXJ0LDcwMCkse29uY2U6dHJ1ZX0pOwogIH1lbHNlewogICAgc2V0VGltZW91dChfX25vdmFSN1N0YXJ0LDcwMCk7CiAgfQp9KSgpOwo='

def patch_source(src:str)->str:
    if "__NOVA_G8_R7__" in src:
        return src

    main=None
    for m in ('if __name__=="__main__":',"if __name__ == '__main__':"):
        if m in src:
            main=m
            break
    if not main:
        raise RuntimeError("MAIN_MARKER_NOT_FOUND")

    helper=f'''
# __NOVA_G8_R7__
def _nova_g8_r7_patch_always_on_poll():
    import base64
    try:
        rec=_static_mem.get("/static/nova.js")
        if not rec:
            print("NOVA_R7:STATIC_MISSING",flush=True)
            return False
        ct,body=rec
        text=body if isinstance(body,str) else body.decode("utf-8")

        if "__NOVA_ALWAYS_ON_POLL_R7__" in text:
            print("NOVA_R7:ALREADY_PATCHED",flush=True)
            return True

        addon=base64.b64decode('LypfX05PVkFfQUxXQVlTX09OX1BPTExfUjdfXyovCihmdW5jdGlvbigpewogIGxldCBfX25vdmFSN0J1c3k9ZmFsc2U7CiAgbGV0IF9fbm92YVI3VGltZXI9bnVsbDsKCiAgYXN5bmMgZnVuY3Rpb24gX19ub3ZhUjdQb2xsKCl7CiAgICBpZihfX25vdmFSN0J1c3kgfHwgIXRva2VuKSByZXR1cm47CiAgICBfX25vdmFSN0J1c3k9dHJ1ZTsKICAgIHRyeXsKICAgICAgY29uc3Qgcj1hd2FpdCBmZXRjaCgnL2FwaS9saXZlLWRhc2hib2FyZD9ub3ZhX3I3PScrRGF0ZS5ub3coKSx7CiAgICAgICAgbWV0aG9kOidHRVQnLAogICAgICAgIGNhY2hlOiduby1zdG9yZScsCiAgICAgICAgaGVhZGVyczp7CiAgICAgICAgICAnQXV0aG9yaXphdGlvbic6J0JlYXJlciAnK3Rva2VuLAogICAgICAgICAgJ0NhY2hlLUNvbnRyb2wnOiduby1jYWNoZSwgbm8tc3RvcmUsIG1heC1hZ2U9MCcsCiAgICAgICAgICAnUHJhZ21hJzonbm8tY2FjaGUnCiAgICAgICAgfQogICAgICB9KTsKCiAgICAgIGlmKHIuc3RhdHVzPT09NDAxIHx8IHIuc3RhdHVzPT09NDAzKXsKICAgICAgICBsb2NhbFN0b3JhZ2UucmVtb3ZlSXRlbSgnbm92YV90b2tlbicpOwogICAgICAgIHRva2VuPScnOwogICAgICAgIHJldHVybjsKICAgICAgfQogICAgICBpZighci5vaykgcmV0dXJuOwoKICAgICAgY29uc3QgbXNnPWF3YWl0IHIuanNvbigpOwogICAgICBsZXQgbmV4dD1udWxsOwogICAgICB0cnl7IG5leHQ9YXBwbHlQYXlsb2FkKG1zZyk7IH1jYXRjaChlKXsgY29uc29sZS5lcnJvcignTk9WQV9SN19BUFBMWScsZSk7IH0KCiAgICAgIGlmKG5leHQpewogICAgICAgIHJlbmRlcihuZXh0KTsKICAgICAgfWVsc2UgaWYobXNnICYmIG1zZy50eXBlPT09J3NuYXBzaG90Jyl7CiAgICAgICAgcmVuZGVyKG1zZyk7CiAgICAgIH0KICAgIH1jYXRjaChlKXsKICAgICAgY29uc29sZS5lcnJvcignTk9WQV9SN19QT0xMJyxlKTsKICAgIH1maW5hbGx5ewogICAgICBfX25vdmFSN0J1c3k9ZmFsc2U7CiAgICB9CiAgfQoKICBmdW5jdGlvbiBfX25vdmFSN1N0YXJ0KCl7CiAgICBpZihfX25vdmFSN1RpbWVyKSByZXR1cm47CiAgICBfX25vdmFSN1BvbGwoKTsKICAgIF9fbm92YVI3VGltZXI9c2V0SW50ZXJ2YWwoX19ub3ZhUjdQb2xsLDIwMDApOwogICAgd2luZG93Ll9fbm92YVI3UG9sbD1fX25vdmFSN1BvbGw7CiAgICB3aW5kb3cuX19ub3ZhUjdUaW1lcj1fX25vdmFSN1RpbWVyOwogIH0KCiAgaWYoZG9jdW1lbnQucmVhZHlTdGF0ZT09PSdsb2FkaW5nJyl7CiAgICBkb2N1bWVudC5hZGRFdmVudExpc3RlbmVyKCdET01Db250ZW50TG9hZGVkJywoKT0+c2V0VGltZW91dChfX25vdmFSN1N0YXJ0LDcwMCkse29uY2U6dHJ1ZX0pOwogIH1lbHNlewogICAgc2V0VGltZW91dChfX25vdmFSN1N0YXJ0LDcwMCk7CiAgfQp9KSgpOwo=').decode("utf-8")
        patched=text+chr(10)+addon+chr(10)
        _static_mem["/static/nova.js"]=(ct,patched.encode("utf-8"))
        print("NOVA_R7:PATCHED",flush=True)
        return True
    except Exception as e:
        print("NOVA_R7:ERROR",repr(e),flush=True)
        return False
'''

    out=src.replace(main,helper+"\n"+main,1)

    r6=(
        "    if not _nova_g8_r6_patch_live_poll():\n"
        "        raise SystemExit('NOVA_R6_LIVE_POLL_PATCH_FAILED')"
    )
    r3=(
        "    if not _nova_g8_r3_patch_frontend():\n"
        "        raise SystemExit('NOVA_R3_FRONTEND_PATCH_FAILED')"
    )
    r7=(
        "\n    if not _nova_g8_r7_patch_always_on_poll():"
        "\n        raise SystemExit('NOVA_R7_ALWAYS_ON_POLL_PATCH_FAILED')"
    )

    if r6 in out:
        out=out.replace(r6,r6+r7,1)
    elif r3 in out:
        out=out.replace(r3,r3+r7,1)
    elif "    preload_static()" in out:
        out=out.replace("    preload_static()","    preload_static()"+r7,1)
    else:
        raise RuntimeError("PATCH_INSERTION_POINT_NOT_FOUND")

    return out

srcp=pathlib.Path(sys.argv[1])
dstp=pathlib.Path(sys.argv[2])
dstp.write_text(patch_source(srcp.read_text(encoding="utf-8")),encoding="utf-8")
print("R7_PATCH_BUILD=PASS")
PY

python3 -m py_compile "$PATCHER"
echo "PATCHER_PY_COMPILE=PASS"

log "3. mandatory synthetic self-test"
mkdir -p "$SELFTEST_DIR"
cat > "$SELFTEST_DIR/fixture.py" <<'PY'
_static_mem={}

def preload_static():
    _static_mem["/static/nova.js"]=(
        "application/javascript",
        b"let token=''; function applyPayload(x){return x;} function render(x){} function connect(){}"
    )

def _nova_g8_r3_patch_frontend():
    return True

def _nova_g8_r6_patch_live_poll():
    return True

if __name__=="__main__":
    preload_static()
    if not _nova_g8_r3_patch_frontend():
        raise SystemExit('NOVA_R3_FRONTEND_PATCH_FAILED')
    if not _nova_g8_r6_patch_live_poll():
        raise SystemExit('NOVA_R6_LIVE_POLL_PATCH_FAILED')
    print("fixture")
PY

python3 "$PATCHER" "$SELFTEST_DIR/fixture.py" "$SELFTEST_DIR/fixture.r7.py"
python3 -m py_compile "$SELFTEST_DIR/fixture.r7.py"

SELFTEST_OUT="$SELFTEST_DIR/runtime.out"
python3 "$SELFTEST_DIR/fixture.r7.py" > "$SELFTEST_OUT" 2>&1
grep -q "NOVA_R7:PATCHED" "$SELFTEST_OUT" || {
  cat "$SELFTEST_OUT"
  die "self-test runtime injection failed"
}

python3 - "$SELFTEST_DIR/fixture.r7.py" <<'PY'
import runpy, sys
ns=runpy.run_path(sys.argv[1],run_name="not_main")
ns["preload_static"]()
assert ns["_nova_g8_r7_patch_always_on_poll"]()
body=ns["_static_mem"]["/static/nova.js"][1]
text=body.decode("utf-8")
assert "__NOVA_ALWAYS_ON_POLL_R7__" in text
assert "setInterval(__novaR7Poll,2000)" in text
assert "nova_r7=" in text
print("R7_SYNTHETIC_JS_MARKERS=PASS")
PY

echo "R7_SYNTHETIC_SELFTEST=PASS"

log "4. patch REAL guard OFFLINE"
python3 "$PATCHER" "$ORIG" "$PATCHED"
python3 -m py_compile "$PATCHED"
grep -q "__NOVA_G8_R7__" "$PATCHED" || die "real guard R7 marker missing"
echo "REAL_PATCH_PY_COMPILE=PASS"
echo "PATCHED_SHA256=$(sha256sum "$PATCHED" | awk '{print $1}')"
cp "$PATCHED" "$BACKUP_DIR/http_guard.py.r7"

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
[ "$READY" = "1" ] || die "guard not ready"

log "7. verify guard loaded R7"
LOGS="$(sudo docker logs --tail 220 "$GUARD_CONTAINER" 2>&1 || true)"
printf '%s\n' "$LOGS" | tail -100
printf '%s\n' "$LOGS" | grep -q "NOVA_R7:PATCHED\|NOVA_R7:ALREADY_PATCHED" \
  || die "guard did not load R7"

log "8. verify PUBLIC JS contains permanent R7 poll"
PUB="${HOME}/nova-r7-public-${STAMP}.js"
curl -sk --max-time 8 "${PUBLIC_BASE}/static/nova.js?nova_r7_verify=${STAMP}" -o "$PUB"

grep -q "__NOVA_INLINE_AUTH_V3__" "$PUB" || die "R3 auth marker missing"
grep -q "__NOVA_ALWAYS_ON_POLL_R7__" "$PUB" || die "R7 marker missing"
grep -q "setInterval(__novaR7Poll,2000)" "$PUB" || die "R7 timer missing"
grep -q "nova_r7=" "$PUB" || die "R7 cache-buster missing"

echo "PUBLIC_R3_AUTH=YES"
echo "PUBLIC_R7_ALWAYS_ON_POLL=YES"
echo "PUBLIC_R7_TIMER_2S=YES"
echo "PUBLIC_JS_BYTES=$(wc -c < "$PUB" | tr -d ' ')"
echo "PUBLIC_JS_SHA256=$(sha256sum "$PUB" | awk '{print $1}')"
rm -f "$PUB"

log "9. verify public dashboard advances"
TOKEN="$(
  sudo docker inspect "$NOVA_CONTAINER" \
    --format '{{range .Config.Env}}{{println .}}{{end}}' \
  | sed -n 's/^APP_ACCESS_TOKEN=//p' | head -1
)"
[ -n "$TOKEN" ] || die "APP_ACCESS_TOKEN missing"

A="${HOME}/nova-r7-a-${STAMP}.json"
B="${HOME}/nova-r7-b-${STAMP}.json"

curl -sk --max-time 8 \
  -H "Authorization: Bearer $TOKEN" \
  -H "Cache-Control: no-cache, no-store, max-age=0" \
  "${PUBLIC_BASE}/api/live-dashboard?nova_r7_a=$(date +%s%N)" -o "$A"

sleep 3

curl -sk --max-time 8 \
  -H "Authorization: Bearer $TOKEN" \
  -H "Cache-Control: no-cache, no-store, max-age=0" \
  "${PUBLIC_BASE}/api/live-dashboard?nova_r7_b=$(date +%s%N)" -o "$B"

python3 - "$A" "$B" <<'PY'
import json,sys
a=json.load(open(sys.argv[1],encoding="utf-8"))
b=json.load(open(sys.argv[2],encoding="utf-8"))
print("A_GENERATION=",a.get("generation"),"A_AT=",a.get("generated_at"))
print("B_GENERATION=",b.get("generation"),"B_AT=",b.get("generated_at"))
print("FEED=",b.get("feed_state"),"PHASE=",b.get("phase"))
if a.get("generation")==b.get("generation") and a.get("generated_at")==b.get("generated_at"):
    raise SystemExit("PUBLIC_DASHBOARD_NOT_ADVANCING")
print("PUBLIC_DASHBOARD_ADVANCE=YES")
PY

rm -f "$A" "$B"
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
echo "R7_SYNTHETIC_SELFTEST=PASS"
echo "REAL_PATCH_PY_COMPILE=PASS"
echo "PUBLIC_R3_AUTH=YES"
echo "PUBLIC_R7_ALWAYS_ON_POLL=YES"
echo "PUBLIC_R7_TIMER_2S=YES"
echo "PUBLIC_DASHBOARD_ADVANCE=YES"
echo "NOVA_RESTARTS=$NOVA_RESTARTS_AFTER"
echo "BACKUP_DIR=$BACKUP_DIR"
echo "NEXT=Safari 기존 NOVA 탭 전체 종료 후 새 탭으로 $PUBLIC_BASE 접속"
