#!/usr/bin/env bash
set -Eeuo pipefail

# QUANT NOVA 3.1.0 GROUNDUP-9 — SOURCE REBUILD PREPARATION
#
# 목적:
#   현재 G8.1 컨테이너를 절대 수정하지 않고,
#   실행 중인 이미지의 /app 전체를 별도 SOURCE TREE로 추출해
#   새 버전(NOVA-3.1.0-GROUNDUP-9) 제작용 기준 소스를 만든다.
#
# 중요:
#   - quant-nova restart 0회
#   - nova-http-guard 변경 0건
#   - 실행 중 컨테이너 내부 파일 변경 0건
#   - Docker build 실행 안 함
#   - 새 source tree만 생성
#
# 생성 결과:
#   ~/quant-nova-3.1.0-groundup-9/
#   ~/quant-nova-3.1.0-groundup-9-source.tar.gz
#
# 다음 단계에서 이 source tree를 기준으로 display/current-price
# 구조를 원론적으로 수정한다.

NOVA_CONTAINER="${NOVA_CONTAINER:-quant-nova}"
OUT_DIR="${HOME}/quant-nova-3.1.0-groundup-9"
ARCHIVE="${HOME}/quant-nova-3.1.0-groundup-9-source.tar.gz"
STAMP="$(date +%Y%m%d-%H%M%S)"
MANIFEST="${OUT_DIR}/REBUILD_MANIFEST.txt"

log(){ printf '\n[%s] %s\n' "$(date '+%H:%M:%S')" "$*"; }
die(){ echo "ERROR: $*" >&2; exit 1; }

log "0. preflight"
sudo docker inspect "$NOVA_CONTAINER" >/dev/null 2>&1 || die "$NOVA_CONTAINER not found"

STATUS_BEFORE="$(sudo docker inspect "$NOVA_CONTAINER" --format '{{.State.Status}}')"
RESTARTS_BEFORE="$(sudo docker inspect "$NOVA_CONTAINER" --format '{{.RestartCount}}')"
IMAGE="$(sudo docker inspect "$NOVA_CONTAINER" --format '{{.Config.Image}}')"
ID="$(sudo docker inspect "$NOVA_CONTAINER" --format '{{.Id}}')"

echo "STATUS_BEFORE=$STATUS_BEFORE"
echo "RESTARTS_BEFORE=$RESTARTS_BEFORE"
echo "IMAGE=$IMAGE"
echo "CONTAINER_ID=$ID"

[ "$STATUS_BEFORE" = "running" ] || die "quant-nova not running"

log "1. create isolated source tree"
rm -rf "$OUT_DIR"
mkdir -p "$OUT_DIR"

# docker cp는 실행 중 컨테이너를 변경하지 않고 읽기만 한다.
sudo docker cp "${NOVA_CONTAINER}:/app/." "$OUT_DIR/"
sudo chown -R "$(id -u):$(id -g)" "$OUT_DIR"

[ -d "$OUT_DIR/app" ] || die "expected /app/app source missing after copy"

log "2. preserve original files + hashes"
{
  echo "QUANT NOVA GROUNDUP REBUILD MANIFEST"
  echo "created_at=$(date -Is)"
  echo "source_container=$NOVA_CONTAINER"
  echo "source_image=$IMAGE"
  echo "source_container_id=$ID"
  echo "source_restart_count=$RESTARTS_BEFORE"
  echo
  echo "[critical hashes]"
  for f in \
    "$OUT_DIR/app/runtime/display.py" \
    "$OUT_DIR/app/model.py" \
    "$OUT_DIR/app/signal/policy.py" \
    "$OUT_DIR/app/signal/coordinator.py" \
    "$OUT_DIR/app/api/app.py" \
    "$OUT_DIR/app/service.py"
  do
    if [ -f "$f" ]; then
      sha256sum "$f"
    fi
  done
} > "$MANIFEST"

log "3. verify critical source exists"
for rel in \
  app/runtime/display.py \
  app/signal/policy.py \
  app/signal/coordinator.py \
  app/api/app.py \
  app/service.py
do
  [ -f "$OUT_DIR/$rel" ] || die "missing critical source: $rel"
done

echo "CRITICAL_SOURCE=PASS"

log "4. Python syntax check — entire copied source"
PYFILES="$(find "$OUT_DIR/app" -type f -name '*.py' | wc -l | tr -d ' ')"
echo "PYTHON_FILES=$PYFILES"

python3 - "$OUT_DIR" <<'PY'
import pathlib, py_compile, sys
root=pathlib.Path(sys.argv[1])/"app"
errors=[]
count=0
for p in root.rglob("*.py"):
    count += 1
    try:
        py_compile.compile(str(p), doraise=True)
    except Exception as e:
        errors.append((str(p),repr(e)))
print("PY_COMPILE_COUNT=",count)
if errors:
    for p,e in errors[:20]:
        print("PY_COMPILE_ERROR",p,e)
    raise SystemExit(1)
print("FULL_SOURCE_PY_COMPILE=PASS")
PY

log "5. extract display/current-price architecture for rebuild"
{
  echo
  echo "[display.py 1-180]"
  nl -ba "$OUT_DIR/app/runtime/display.py" | sed -n '1,180p'
  echo
  echo "[Candidate/public/current-price references]"
  grep -RniE \
    'def public|class Candidate|venue_state|last_tick_at|best_signal_venue|current_price|signal_price|change_rate' \
    "$OUT_DIR/app" --include='*.py' 2>/dev/null | head -500 || true
} > "$OUT_DIR/REBUILD_DISPLAY_ARCHITECTURE.txt"

log "6. create immutable baseline copy"
mkdir -p "$OUT_DIR/_baseline"
cp "$OUT_DIR/app/runtime/display.py" "$OUT_DIR/_baseline/display.py"
cp "$OUT_DIR/app/signal/policy.py" "$OUT_DIR/_baseline/policy.py"
cp "$OUT_DIR/app/signal/coordinator.py" "$OUT_DIR/_baseline/coordinator.py"

log "7. package source tree"
rm -f "$ARCHIVE"
tar -C "$(dirname "$OUT_DIR")" -czf "$ARCHIVE" "$(basename "$OUT_DIR")"

echo "SOURCE_TREE_SHA256=$(tar -C "$OUT_DIR" -cf - app | sha256sum | awk '{print $1}')"
echo "ARCHIVE_SHA256=$(sha256sum "$ARCHIVE" | awk '{print $1}')"
echo "ARCHIVE_BYTES=$(wc -c < "$ARCHIVE" | tr -d ' ')"

log "8. prove live NOVA untouched"
STATUS_AFTER="$(sudo docker inspect "$NOVA_CONTAINER" --format '{{.State.Status}}')"
RESTARTS_AFTER="$(sudo docker inspect "$NOVA_CONTAINER" --format '{{.RestartCount}}')"

echo "STATUS_AFTER=$STATUS_AFTER"
echo "RESTARTS_AFTER=$RESTARTS_AFTER"

[ "$STATUS_AFTER" = "running" ] || die "live quant-nova stopped"
[ "$RESTARTS_AFTER" = "$RESTARTS_BEFORE" ] || die "live quant-nova restart count changed"

echo
echo "===== GROUNDUP SOURCE PREP = PASS ====="
echo "LIVE_CONTAINER_UNTOUCHED=YES"
echo "LIVE_RESTARTS=$RESTARTS_AFTER"
echo "SOURCE_DIR=$OUT_DIR"
echo "SOURCE_ARCHIVE=$ARCHIVE"
echo "ARCHITECTURE_REPORT=$OUT_DIR/REBUILD_DISPLAY_ARCHITECTURE.txt"
echo
echo "NEXT=이제 이 새 source tree만 수정한다. 실행 중 G8.1은 더 이상 패치하지 않는다."
