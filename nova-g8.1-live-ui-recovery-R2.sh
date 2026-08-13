#!/usr/bin/env bash
set -Eeuo pipefail

# QUANT NOVA G8.1 LIVE UI RECOVERY R2
# - quant-nova 본체/신호/DB/WS는 건드리지 않음
# - nova-http-guard의 메모리 preload 단계에서만 최신 nova.js에 인증 UI를 주입
# - 401/403을 circuit 장애로 누적하지 않도록 guard 소스도 함께 보정
# - 실패 시 guard 소스 자동 원복
#
# 기대 구조:
#   Caddy -> nova-http-guard:8080 -> quant-nova:8000
#
# 중요:
#   quant-nova restart/stop/remove 없음
#   quant-nova read-only FS에 쓰기 없음

NOVA_CONTAINER="${NOVA_CONTAINER:-quant-nova}"
GUARD_CONTAINER="${GUARD_CONTAINER:-nova-http-guard}"
PUBLIC_BASE="${PUBLIC_BASE:-https://3-38-25-20.nip.io}"
STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP_DIR="${HOME}/nova-g8-r2-backup-${STAMP}"
HOST_GUARD="/tmp/http_guard.r2.${STAMP}.py"
HOST_ORIG="/tmp/http_guard.orig.${STAMP}.py"

log(){ printf '\n[%s] %s\n' "$(date '+%H:%M:%S')" "$*"; }
die(){ echo "ERROR: $*" >&2; exit 1; }

rollback_guard(){
  echo
  echo "===== ROLLBACK GUARD ====="
  if [ -f "$HOST_ORIG" ]; then
    sudo docker cp "$HOST_ORIG" "${GUARD_CONTAINER}:/srv/http_guard.py" || true
    sudo docker restart "$GUARD_CONTAINER" >/dev/null 2>&1 || true
  fi
}
trap 'rc=$?; if [ $rc -ne 0 ]; then rollback_guard; fi; exit $rc' EXIT

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

log "1. backup guard source"
mkdir -p "$BACKUP_DIR"
sudo docker cp "${GUARD_CONTAINER}:/srv/http_guard.py" "$HOST_ORIG"
cp "$HOST_ORIG" "$BACKUP_DIR/http_guard.py.before"
sha256sum "$HOST_ORIG"

log "2. build patched guard source"
python3 - "$HOST_ORIG" "$HOST_GUARD" <<'PY'
import sys, pathlib, re

src_path = pathlib.Path(sys.argv[1])
dst_path = pathlib.Path(sys.argv[2])
src = src_path.read_text(encoding="utf-8")

MARKER = "__NOVA_G8_R2_PATCH__"
if MARKER in src:
    dst_path.write_text(src, encoding="utf-8")
    print("guard already contains R2 patch")
    raise SystemExit(0)

# 1) 메모리 preload 완료 후 /static/nova.js의 auth bootstrap만 교체하는 함수 추가
inject = r