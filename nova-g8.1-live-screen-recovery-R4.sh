#!/usr/bin/env bash
set -Eeuo pipefail

# QUANT NOVA G8.1 LIVE SCREEN RECOVERY R4
# 목적: 현재가/후보/성과 화면 고정 문제를 프런트 표시 경로에서만 복구
# 방식:
#   - 기존 WebSocket은 그대로 둠
#   - 2초마다 /api/live-dashboard를 cache-busting + no-store로 읽어 render
#   - Kiwoom REST/WS 구독, BUY 조건, 점수, DB/WAL은 변경하지 않음
#   - quant-nova 재시작/쓰기 없음
#   - nova-http-guard host bind source만 패치 후 guard만 재시작
#   - 실패 시 자동 원복

NOVA_CONTAINER="${NOVA_CONTAINER:-quant-nova}"
GUARD_CONTAINER="${GUARD_CONTAINER:-nova-http-guard}"
PUBLIC_BASE="${PUBLIC_BASE:-https://3-38-25-20.nip.io}"

STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP_DIR="${HOME}/nova-g8-r4-backup-${STAMP}"
ORIG="${HOME}/http_guard.r4.orig.${STAMP}.py"
PATCHED="${HOME}/http_guard.r4.${STAMP}.py"

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
[ "$NOVA_STATUS_BEFORE" = "running" ] || die "quant-nova not running"

log "1. locate guard host bind source"
HOST_GUARD="$(
  sudo docker inspect "$GUARD_CONTAINER" \
    --format '{{range .Mounts}}{{if eq .Destination "/srv/http_guard.py"}}{{.Source}}{{end}}{{end}}'
)"
[ -n "$HOST_GUARD" ] || die "guard host source not found"
sudo test -f "$HOST_GUARD" || die "guard host source missing"
echo "HOST_GUARD=$HOST_GUARD"

mkdir -p "$BACKUP_DIR"
sudo cp "$HOST_GUARD" "$ORIG"
sudo cp "$HOST_GUARD" "$BACKUP_DIR/http_guard.py.before"
sudo chown "$(id -u):$(id -g)" "$ORIG" "$BACKUP_DIR/http_guard.py.before" || true
sha256sum "$ORIG"

log "2. build R4 patch offline"
python3 - "$ORIG" "$PATCHED" <<'PY'
import pathlib, sys, base64

src_path=pathlib.Path(sys.argv[1])
dst_path=pathlib.Path(sys.argv[2])
src=src_path.read_text(encoding="utf-8")

if "__NOVA_G8_R4__" in src:
    dst_path.write_text(src,encoding="utf-8")
    print("R4_ALREADY_PRESENT=YES")
    raise SystemExit(0)

main=None
for m in ('if __name__=="__main__":',"if __name__ == '__main__':"):
    if m in src:
        main=m
        break
if not main:
    raise SystemExit("MAIN_MARKER_NOT_FOUND")

# R3가 이미 있으면 R3 호출 다음에 R4를 붙이고,
# 없으면 preload_static() 직후 R4를 붙인다.
POLL_B64="Ci8qX19OT1ZBX0xJVkVfUE9MTF9SNF9fKi8KKGZ1bmN0aW9uKCl7CiAgbGV0IF9fbm92YVBvbGxCdXN5PWZhbHNlOwogIGxldCBfX25vdmFQb2xsVGltZXI9bnVsbDsKCiAgYXN5bmMgZnVuY3Rpb24gX19ub3ZhUG9sbE9uY2UoKXsKICAgIGlmKF9fbm92YVBvbGxCdXN5IHx8ICF0b2tlbikgcmV0dXJuOwogICAgX19ub3ZhUG9sbEJ1c3k9dHJ1ZTsKICAgIHRyeXsKICAgICAgY29uc3Qgcj1hd2FpdCBmZXRjaCgnL2FwaS9saXZlLWRhc2hib2FyZD9fX25vdmFfbGl2ZT0nK0RhdGUubm93KCksewogICAgICAgIG1ldGhvZDonR0VUJywKICAgICAgICBjYWNoZTonbm8tc3RvcmUnLAogICAgICAgIGhlYWRlcnM6ewogICAgICAgICAgJ0F1dGhvcml6YXRpb24nOidCZWFyZXIgJyt0b2tlbiwKICAgICAgICAgICdDYWNoZS1Db250cm9sJzonbm8tY2FjaGUnCiAgICAgICAgfQogICAgICB9KTsKICAgICAgaWYoci5zdGF0dXM9PT00MDEgfHwgci5zdGF0dXM9PT00MDMpewogICAgICAgIGxvY2FsU3RvcmFnZS5yZW1vdmVJdGVtKCdub3ZhX3Rva2VuJyk7CiAgICAgICAgdG9rZW49Jyc7CiAgICAgICAgcmV0dXJuOwogICAgICB9CiAgICAgIGlmKCFyLm9rKSByZXR1cm47CgogICAgICBjb25zdCBtc2c9YXdhaXQgci5qc29uKCk7CiAgICAgIGNvbnN0IG5leHQ9YXBwbHlQYXlsb2FkKG1zZyk7CiAgICAgIGlmKG5leHQpewogICAgICAgIHJlbmRlcihuZXh0KTsKICAgICAgfWVsc2UgaWYobXNnICYmIG1zZy50eXBlPT09J3NuYXBzaG90Jyl7CiAgICAgICAgcmVuZGVyKG1zZyk7CiAgICAgIH0KICAgIH1jYXRjaChlKXsKICAgICAgY29uc29sZS5lcnJvcignTk9WQV9MSVZFX1BPTEwnLGUpOwogICAgfWZpbmFsbHl7CiAgICAgIF9fbm92YVBvbGxCdXN5PWZhbHNlOwogICAgfQogIH0KCiAgZnVuY3Rpb24gX19ub3ZhU3RhcnRQb2xsKCl7CiAgICBpZihfX25vdmFQb2xsVGltZXIpIHJldHVybjsKICAgIF9fbm92YVBvbGxPbmNlKCk7CiAgICBfX25vdmFQb2xsVGltZXI9c2V0SW50ZXJ2YWwoX19ub3ZhUG9sbE9uY2UsMjAwMCk7CiAgfQoKICBpZihkb2N1bWVudC5yZWFkeVN0YXRlPT09J2xvYWRpbmcnKXsKICAgIGRvY3VtZW50LmFkZEV2ZW50TGlzdGVuZXIoJ0RPTUNvbnRlbnRMb2FkZWQnLCgpPT5zZXRUaW1lb3V0KF9fbm92YVN0YXJ0UG9sbCwxMjAwKSx7b25jZTp0cnVlfSk7CiAgfWVsc2V7CiAgICBzZXRUaW1lb3V0KF9fbm92YVN0YXJ0UG9sbCwxMjAwKTsKICB9Cn0pKCk7Cg=="

helper = '''
# __NOVA_G8_R4__
def _nova_g8_r4_patch_live_poll():
    import base64
    try:
        rec=_static_mem.get("/static/nova.js")
        if not rec:
            print("NOVA_R4:STATIC_MISSING",flush=True)
            return False
        ct,body=rec
        text=body if isinstance(body,str) else body.decode("utf-8")
        if "__NOVA_LIVE_POLL_R4__" in text:
            print("NOVA_R4:ALREADY_PATCHED",flush=True)
            return True
        addon=base64.b64decode("''' + POLL_B64 + '''").decode("utf-8")
        text=text + "\n" + addon + "\n"
        _static_mem["/static/nova.js"]=(ct,text.encode("utf-8"))
        print("NOVA_R4:PATCHED",flush=True)
        return True
    except Exception as e:
        print("NOVA_R4:ERROR",repr(e),flush=True)
        return False
'''

src=src.replace(main,helper+"\n"+main,1)

r3_call="    if not _nova_g8_r3_patch_frontend():\n        raise SystemExit('NOVA_R3_FRONTEND_PATCH_FAILED')"
if r3_call in src:
    src=src.replace(
        r3_call,
        r3_call+"\n    if not _nova_g8_r4_patch_live_poll():\n        raise SystemExit('NOVA_R4_LIVE_POLL_PATCH_FAILED')",
        1
    )
elif "    preload_static()" in src:
    src=src.replace(
        "    preload_static()",
        "    preload_static()\n    if not _nova_g8_r4_patch_live_poll():\n        raise SystemExit('NOVA_R4_LIVE_POLL_PATCH_FAILED')",
        1
    )
else:
    raise SystemExit("PRELOAD_OR_R3_CALL_NOT_FOUND")

dst_path.write_text(src,encoding="utf-8")
print("R4_SOURCE_BUILD=PASS")
PY

python3 -m py_compile "$PATCHED"
grep -q "__NOVA_G8_R4__" "$PATCHED" || die "R4 guard marker missing"
grep -q "__NOVA_LIVE_POLL_R4__" "$PATCHED" || die "R4 JS marker missing"
echo "R4_OFFLINE_VALIDATE=PASS"
sha256sum "$PATCHED"
cp "$PATCHED" "$BACKUP_DIR/http_guard.py.r4"

log "3. install host guard patch"
ARMED=1
sudo sh -c "cat '$PATCHED' > '$HOST_GUARD'"
sudo python3 -m py_compile "$HOST_GUARD"
echo "HOST_INSTALL=PASS"

log "4. restart guard ONLY"
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

log "5. verify R3 + R4 public JS"
PUB="${HOME}/nova-r4-public-${STAMP}.js"
curl -sk --max-time 8 "${PUBLIC_BASE}/static/nova.js?verify=${STAMP}" -o "$PUB"
grep -q "__NOVA_INLINE_AUTH_V3__" "$PUB" || die "R3 auth marker missing"
grep -q "__NOVA_LIVE_POLL_R4__" "$PUB" || die "R4 poll marker missing"
echo "PUBLIC_R3_AUTH=YES"
echo "PUBLIC_R4_LIVE_POLL=YES"
wc -c "$PUB"
sha256sum "$PUB"
rm -f "$PUB"

log "6. verify dashboard changes over time"
TOKEN="$(
  sudo docker inspect "$NOVA_CONTAINER" \
    --format '{{range .Config.Env}}{{println .}}{{end}}' \
  | sed -n 's/^APP_ACCESS_TOKEN=//p' | head -1
)"
[ -n "$TOKEN" ] || die "APP_ACCESS_TOKEN missing"

A="${HOME}/r4-a-${STAMP}.json"
B="${HOME}/r4-b-${STAMP}.json"

curl -sk --max-time 8 -H "Authorization: Bearer $TOKEN" \
  "${PUBLIC_BASE}/api/live-dashboard?audit_a=$(date +%s%N)" -o "$A"
sleep 3
curl -sk --max-time 8 -H "Authorization: Bearer $TOKEN" \
  "${PUBLIC_BASE}/api/live-dashboard?audit_b=$(date +%s%N)" -o "$B"

python3 - "$A" "$B" <<'PY'
import json,sys
a=json.load(open(sys.argv[1],encoding="utf-8"))
b=json.load(open(sys.argv[2],encoding="utf-8"))
print("A_GENERATION=",a.get("generation"),"A_AT=",a.get("generated_at"))
print("B_GENERATION=",b.get("generation"),"B_AT=",b.get("generated_at"))
print("FEED=",b.get("feed_state"),"PHASE=",b.get("phase"))
if a.get("generation")==b.get("generation") and a.get("generated_at")==b.get("generated_at"):
    print("WARNING=SNAPSHOT_DID_NOT_ADVANCE_IN_3S")
else:
    print("SNAPSHOT_ADVANCE=YES")
PY
rm -f "$A" "$B"
unset TOKEN

log "7. prove quant-nova untouched"
NOVA_STATUS_AFTER="$(sudo docker inspect "$NOVA_CONTAINER" --format '{{.State.Status}}')"
NOVA_RESTARTS_AFTER="$(sudo docker inspect "$NOVA_CONTAINER" --format '{{.RestartCount}}')"
echo "NOVA_STATUS_AFTER=$NOVA_STATUS_AFTER"
echo "NOVA_RESTARTS_AFTER=$NOVA_RESTARTS_AFTER"
[ "$NOVA_STATUS_AFTER" = "running" ] || die "quant-nova not running"
[ "$NOVA_RESTARTS_AFTER" = "$NOVA_RESTARTS_BEFORE" ] || die "quant-nova restart count changed"

ARMED=0
trap - EXIT
rm -f "$ORIG" "$PATCHED"

echo
echo "===== RESULT=PASS ====="
echo "PUBLIC_R3_AUTH=YES"
echo "PUBLIC_R4_LIVE_POLL=YES"
echo "NOVA_RESTARTS=$NOVA_RESTARTS_AFTER"
echo "NEXT=Safari 기존 NOVA 탭을 완전히 닫고 새 탭에서 $PUBLIC_BASE 접속"
