#!/usr/bin/env bash
set -Eeuo pipefail

NOVA_CONTAINER="${NOVA_CONTAINER:-quant-nova}"
GUARD_CONTAINER="${GUARD_CONTAINER:-nova-http-guard}"
PUBLIC_BASE="${PUBLIC_BASE:-https://3-38-25-20.nip.io}"
STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP_DIR="${HOME}/nova-g8-r3-backup-${STAMP}"
WORK_ORIG="${HOME}/http_guard.orig.${STAMP}.py"
WORK_PATCHED="${HOME}/http_guard.r3.${STAMP}.py"

log(){ printf '\n[%s] %s\n' "$(date '+%H:%M:%S')" "$*"; }
die(){ echo "ERROR: $*" >&2; exit 1; }

GUARD_HOST_SOURCE=""
ROLLBACK_ARMED=0
NOVA_RESTARTS_BEFORE=""

rollback(){
  rc=$?
  if [ "$rc" -ne 0 ] && [ "$ROLLBACK_ARMED" = "1" ] && [ -n "$GUARD_HOST_SOURCE" ] && [ -f "$WORK_ORIG" ]; then
    echo
    echo "===== AUTO ROLLBACK ====="
    sudo sh -c "cat '$WORK_ORIG' > '$GUARD_HOST_SOURCE'" || true
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

log "1. discover host bind source of /srv/http_guard.py"
GUARD_HOST_SOURCE="$(
  sudo docker inspect "$GUARD_CONTAINER" \
    --format '{{range .Mounts}}{{if eq .Destination "/srv/http_guard.py"}}{{.Source}}{{end}}{{end}}'
)"
if [ -z "$GUARD_HOST_SOURCE" ]; then
  sudo docker inspect "$GUARD_CONTAINER" \
    --format '{{range .Mounts}}{{println .Source " -> " .Destination " RW=" .RW}}{{end}}'
  die "/srv/http_guard.py host bind source not found"
fi

echo "GUARD_HOST_SOURCE=$GUARD_HOST_SOURCE"
sudo test -f "$GUARD_HOST_SOURCE" || die "guard host source missing"

mkdir -p "$BACKUP_DIR"
sudo cp "$GUARD_HOST_SOURCE" "$WORK_ORIG"
sudo cp "$GUARD_HOST_SOURCE" "$BACKUP_DIR/http_guard.py.before"
sudo chown "$(id -u):$(id -g)" "$WORK_ORIG" "$BACKUP_DIR/http_guard.py.before" || true
sha256sum "$WORK_ORIG"

log "2. build R3 guard patch offline"
python3 - "$WORK_ORIG" "$WORK_PATCHED" <<'PY'
import sys, pathlib, base64
src_path=pathlib.Path(sys.argv[1])
dst_path=pathlib.Path(sys.argv[2])
src=src_path.read_text(encoding="utf-8")

if "__NOVA_G8_R3__" in src:
    dst_path.write_text(src,encoding="utf-8")
    print("R3_ALREADY_PRESENT=YES")
    raise SystemExit(0)

main=None
for m in ('if __name__=="__main__":',"if __name__ == '__main__':"):
    if m in src:
        main=m
        break
if not main:
    raise SystemExit("MAIN_MARKER_NOT_FOUND")
if "    preload_static()" not in src:
    raise SystemExit("PRELOAD_STATIC_CALL_NOT_FOUND")

JS_B64="LypfX05PVkFfSU5MSU5FX0FVVEhfVjNfXyovCmFzeW5jIGZ1bmN0aW9uIF9fbm92YUlubGluZVRva2VuKCl7CiAgcmV0dXJuIGF3YWl0IG5ldyBQcm9taXNlKChyZXNvbHZlKT0+ewogICAgY29uc3Qgb2xkPWRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCdfX25vdmFfYXV0aF9vdmVybGF5Jyk7IGlmKG9sZCkgb2xkLnJlbW92ZSgpOwogICAgY29uc3Qgd3JhcD1kb2N1bWVudC5jcmVhdGVFbGVtZW50KCdkaXYnKTsKICAgIHdyYXAuaWQ9J19fbm92YV9hdXRoX292ZXJsYXknOwogICAgd3JhcC5zdHlsZS5jc3NUZXh0PSdwb3NpdGlvbjpmaXhlZDtpbnNldDowO3otaW5kZXg6MjE0NzQ4MzY0NztiYWNrZ3JvdW5kOnJnYmEoNSwxMCwyMCwuOTQpO2Rpc3BsYXk6ZmxleDthbGlnbi1pdGVtczpjZW50ZXI7anVzdGlmeS1jb250ZW50OmNlbnRlcjtwYWRkaW5nOjI0cHg7Zm9udC1mYW1pbHk6LWFwcGxlLXN5c3RlbSxCbGlua01hY1N5c3RlbUZvbnQsU2Vnb2UgVUksc2Fucy1zZXJpZic7CiAgICBjb25zdCBib3g9ZG9jdW1lbnQuY3JlYXRlRWxlbWVudCgnZGl2Jyk7CiAgICBib3guc3R5bGUuY3NzVGV4dD0nd2lkdGg6bWluKDkydncsNDIwcHgpO2JhY2tncm91bmQ6IzEwMTgyNztib3JkZXI6MXB4IHNvbGlkICMzMzQxNTU7Ym9yZGVyLXJhZGl1czoxNnB4O3BhZGRpbmc6MjBweDtjb2xvcjojZTVlN2ViO2JveC1zaGFkb3c6MCAyNHB4IDcwcHggcmdiYSgwLDAsMCwuNDUpJzsKICAgIGNvbnN0IHRpdGxlPWRvY3VtZW50LmNyZWF0ZUVsZW1lbnQoJ2RpdicpOwogICAgdGl0bGUudGV4dENvbnRlbnQ9J1FVQU5UIE5PVkEg7J247KadJzsKICAgIHRpdGxlLnN0eWxlLmNzc1RleHQ9J2ZvbnQtd2VpZ2h0OjgwMDtmb250LXNpemU6MjBweDttYXJnaW4tYm90dG9tOjhweCc7CiAgICBjb25zdCBkZXNjPWRvY3VtZW50LmNyZWF0ZUVsZW1lbnQoJ2RpdicpOwogICAgZGVzYy50ZXh0Q29udGVudD0n7ZiE7J6sIEFQUF9BQ0NFU1NfVE9LRU7snYQg7J6F66Cl7ZWY7IS47JqULiDthqDtgbDsnYAg7J20IOu4jOudvOyasOyggOyXkOunjCDsoIDsnqXrkKnri4jri6QuJzsKICAgIGRlc2Muc3R5bGUuY3NzVGV4dD0nZm9udC1zaXplOjEzcHg7bGluZS1oZWlnaHQ6MS41O2NvbG9yOiNhZWI4Yzg7bWFyZ2luLWJvdHRvbToxNHB4JzsKICAgIGNvbnN0IGlucHV0PWRvY3VtZW50LmNyZWF0ZUVsZW1lbnQoJ2lucHV0Jyk7CiAgICBpbnB1dC50eXBlPSdwYXNzd29yZCc7IGlucHV0LmF1dG9jb21wbGV0ZT0nb2ZmJzsgaW5wdXQucGxhY2Vob2xkZXI9J0FQUF9BQ0NFU1NfVE9LRU4nOwogICAgaW5wdXQuc3R5bGUuY3NzVGV4dD0nd2lkdGg6MTAwJTtib3gtc2l6aW5nOmJvcmRlci1ib3g7Zm9udC1zaXplOjE2cHg7cGFkZGluZzoxMnB4IDEzcHg7Ym9yZGVyLXJhZGl1czoxMHB4O2JvcmRlcjoxcHggc29saWQgIzQ3NTU2OTtiYWNrZ3JvdW5kOiMwODExMWY7Y29sb3I6I2ZmZjtvdXRsaW5lOm5vbmUnOwogICAgY29uc3QgbXNnPWRvY3VtZW50LmNyZWF0ZUVsZW1lbnQoJ2RpdicpOwogICAgbXNnLnN0eWxlLmNzc1RleHQ9J21pbi1oZWlnaHQ6MjBweDttYXJnaW4tdG9wOjhweDtmb250LXNpemU6MTJweDtjb2xvcjojZmNhNWE1JzsKICAgIGNvbnN0IGJ0bj1kb2N1bWVudC5jcmVhdGVFbGVtZW50KCdidXR0b24nKTsKICAgIGJ0bi50ZXh0Q29udGVudD0n7Jew6rKwJzsKICAgIGJ0bi5zdHlsZS5jc3NUZXh0PSd3aWR0aDoxMDAlO21hcmdpbi10b3A6OHB4O3BhZGRpbmc6MTJweDtib3JkZXI6MDtib3JkZXItcmFkaXVzOjEwcHg7YmFja2dyb3VuZDojMjU2M2ViO2NvbG9yOndoaXRlO2ZvbnQtc2l6ZToxNnB4O2ZvbnQtd2VpZ2h0OjcwMCc7CiAgICBjb25zdCBzdWJtaXQ9KCk9Pntjb25zdCB2PShpbnB1dC52YWx1ZXx8JycpLnRyaW0oKTtpZighdil7bXNnLnRleHRDb250ZW50PSfthqDtgbDsnYQg7J6F66Cl7ZWY7IS47JqULic7cmV0dXJuO313cmFwLnJlbW92ZSgpO3Jlc29sdmUodik7fTsKICAgIGJ0bi5vbmNsaWNrPXN1Ym1pdDsKICAgIGlucHV0LmFkZEV2ZW50TGlzdGVuZXIoJ2tleWRvd24nLChlKT0+e2lmKGUua2V5PT09J0VudGVyJylzdWJtaXQoKTt9KTsKICAgIGJveC5hcHBlbmQodGl0bGUsZGVzYyxpbnB1dCxtc2csYnRuKTsgd3JhcC5hcHBlbmQoYm94KTsgZG9jdW1lbnQuYm9keS5hcHBlbmQod3JhcCk7CiAgICBzZXRUaW1lb3V0KCgpPT5pbnB1dC5mb2N1cygpLDUwKTsKICB9KTsKfQphc3luYyBmdW5jdGlvbiBhdXRoKCl7CiAgdHJ5ewogICAgdG9rZW49bG9jYWxTdG9yYWdlLmdldEl0ZW0oJ25vdmFfdG9rZW4nKXx8dG9rZW58fCcnOwogICAgZm9yKDs7KXsKICAgICAgaWYoIXRva2VuKXsKICAgICAgICB0b2tlbj1hd2FpdCBfX25vdmFJbmxpbmVUb2tlbigpOwogICAgICAgIGlmKCF0b2tlbilyZXR1cm4gZmFsc2U7CiAgICAgICAgbG9jYWxTdG9yYWdlLnNldEl0ZW0oJ25vdmFfdG9rZW4nLHRva2VuKTsKICAgICAgfQogICAgICBsZXQgcjsKICAgICAgdHJ5ewogICAgICAgIHI9YXdhaXQgZmV0Y2goJy9hcGkvbGl2ZS1kYXNoYm9hcmQnLHttZXRob2Q6J0dFVCcsY2FjaGU6J25vLXN0b3JlJyxoZWFkZXJzOnsnQXV0aG9yaXphdGlvbic6J0JlYXJlciAnK3Rva2VufX0pOwogICAgICB9Y2F0Y2goZSl7Y29uc29sZS5lcnJvcignTk9WQV9BVVRIX05FVFdPUksnLGUpO3JldHVybiBmYWxzZTt9CiAgICAgIGlmKHIub2spcmV0dXJuIHRydWU7CiAgICAgIGlmKHIuc3RhdHVzPT09NDAxfHxyLnN0YXR1cz09PTQwMyl7bG9jYWxTdG9yYWdlLnJlbW92ZUl0ZW0oJ25vdmFfdG9rZW4nKTt0b2tlbj0nJztjb250aW51ZTt9CiAgICAgIGNvbnNvbGUuZXJyb3IoJ05PVkFfQVVUSF9TRVJWRVInLHIuc3RhdHVzKTtyZXR1cm4gZmFsc2U7CiAgICB9CiAgfWNhdGNoKGUpe2NvbnNvbGUuZXJyb3IoJ05PVkFfQVVUSF9CT09UJyxlKTtyZXR1cm4gZmFsc2U7fQp9Cg=="

helper = '''
# __NOVA_G8_R3__
def _nova_g8_r3_patch_frontend():
    import base64
    try:
        rec=_static_mem.get("/static/nova.js")
        if not rec:
            print("NOVA_R3_FRONTEND:STATIC_MISSING",flush=True)
            return False
        ct,body=rec
        text=body if isinstance(body,str) else body.decode("utf-8")
        if "__NOVA_INLINE_AUTH_V3__" in text:
            print("NOVA_R3_FRONTEND:ALREADY_PATCHED",flush=True)
            return True
        start=text.find("async function auth()")
        end=text.find("function connect()",start)
        if start < 0 or end < 0:
            print("NOVA_R3_FRONTEND:AUTH_PATTERN_MISSING",flush=True)
            return False
        replacement=base64.b64decode("''' + JS_B64 + '''").decode("utf-8")
        patched=text[:start]+replacement+text[end:]
        _static_mem["/static/nova.js"]=(ct,patched.encode("utf-8"))
        print("NOVA_R3_FRONTEND:PATCHED",flush=True)
        return True
    except Exception as e:
        print("NOVA_R3_FRONTEND:ERROR",repr(e),flush=True)
        return False
'''

src=src.replace(main,helper+"\n"+main,1)
src=src.replace(
    "    preload_static()",
    "    preload_static()\n    if not _nova_g8_r3_patch_frontend():\n        raise SystemExit('NOVA_R3_FRONTEND_PATCH_FAILED')",
    1
)
dst_path.write_text(src,encoding="utf-8")
print("R3_SOURCE_BUILD=PASS")
PY

python3 -m py_compile "$WORK_PATCHED"
grep -q "__NOVA_G8_R3__" "$WORK_PATCHED" || die "R3 guard marker missing"
grep -q "__NOVA_INLINE_AUTH_V3__" "$WORK_PATCHED" || die "R3 JS marker missing"
echo "R3_OFFLINE_VALIDATE=PASS"
sha256sum "$WORK_PATCHED"
cp "$WORK_PATCHED" "$BACKUP_DIR/http_guard.py.r3"

log "3. install patch to host bind source"
ROLLBACK_ARMED=1
sudo sh -c "cat '$WORK_PATCHED' > '$GUARD_HOST_SOURCE'"
sudo python3 -m py_compile "$GUARD_HOST_SOURCE"
echo "HOST_SOURCE_INSTALL=PASS"

log "4. restart GUARD ONLY"
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

log "5. verify guard loaded R3"
LOGS="$(sudo docker logs --tail 160 "$GUARD_CONTAINER" 2>&1 || true)"
printf '%s\n' "$LOGS" | tail -80
printf '%s\n' "$LOGS" | grep -q "NOVA_R3_FRONTEND:PATCHED\|NOVA_R3_FRONTEND:ALREADY_PATCHED" \
  || die "R3 frontend patch marker missing from guard logs"

log "6. verify public JS"
PUB_JS="${HOME}/nova-r3-public-${STAMP}.js"
curl -sk --max-time 8 "${PUBLIC_BASE}/static/nova.js" -o "$PUB_JS"
grep -q "__NOVA_INLINE_AUTH_V3__" "$PUB_JS" || die "public nova.js is not R3 patched"
echo "PUBLIC_JS_R3=YES"
wc -c "$PUB_JS"
sha256sum "$PUB_JS"
rm -f "$PUB_JS"

log "7. verify protected public APIs"
TOKEN="$(
  sudo docker inspect "$NOVA_CONTAINER" \
    --format '{{range .Config.Env}}{{println .}}{{end}}' \
  | sed -n 's/^APP_ACCESS_TOKEN=//p' | head -1
)"
[ -n "$TOKEN" ] || die "APP_ACCESS_TOKEN missing"

FAIL=0
API_TMP="${HOME}/nova-r3-api-${STAMP}.tmp"
for API in \
  /api/live-dashboard \
  /api/prebuy-recommendations \
  /api/nxt-alerts \
  /api/nxt-signal-table
do
  CODE="$(curl -sk --max-time 8 \
    -H "Authorization: Bearer $TOKEN" \
    -o "$API_TMP" \
    -w '%{http_code}' \
    "${PUBLIC_BASE}${API}" || true)"
  printf '%-34s HTTP %s\n' "$API" "$CODE"
  [ "$CODE" = "200" ] || FAIL=1
done
rm -f "$API_TMP"
unset TOKEN
[ "$FAIL" = "0" ] || die "one or more public APIs are not HTTP 200"

log "8. prove quant-nova untouched"
NOVA_STATUS_AFTER="$(sudo docker inspect "$NOVA_CONTAINER" --format '{{.State.Status}}')"
NOVA_RESTARTS_AFTER="$(sudo docker inspect "$NOVA_CONTAINER" --format '{{.RestartCount}}')"
echo "NOVA_STATUS_AFTER=$NOVA_STATUS_AFTER"
echo "NOVA_RESTARTS_AFTER=$NOVA_RESTARTS_AFTER"
[ "$NOVA_STATUS_AFTER" = "running" ] || die "quant-nova is not running"
[ "$NOVA_RESTARTS_AFTER" = "$NOVA_RESTARTS_BEFORE" ] || die "quant-nova restart count changed"

ROLLBACK_ARMED=0
trap - EXIT
rm -f "$WORK_ORIG" "$WORK_PATCHED"

echo
echo "===== RESULT=PASS ====="
echo "PUBLIC_JS_R3=YES"
echo "NOVA_RESTARTS=$NOVA_RESTARTS_AFTER"
echo "BACKUP_DIR=$BACKUP_DIR"
echo "NEXT=Safari 기존 QUANT NOVA 탭을 모두 닫고 새 탭에서 $PUBLIC_BASE 접속"
