#!/usr/bin/env bash
set -Eeuo pipefail
REPO_URL="https://github.com/bbblaprk-svg/kiwoom-smartmoney-daytrader.git"
ZIP_NAME="QUANT_NOVA_1.4.0_SECTOR_ROTATION.zip"
ROOT_NAME="nova140"
APP_DIR="$HOME/quant-nova"
IMAGE="quant-nova:1.4.0"
CONTAINER="quant-nova"
NETWORK="kiwoom-net"
HOST_PORT="3200"
TMP="$(mktemp -d)"
STAMP="$(date +%Y%m%d%H%M%S)"
BACKUP="${CONTAINER}-backup-${STAMP}"
OLD_RENAMED=0
NEW_STARTED=0
cleanup(){ rm -rf "$TMP"; }
fail(){ printf '\n[오류] %s\n' "$*" >&2; exit 1; }
say(){ printf '\n==> %s\n' "$*"; }
rollback(){
  local ec=$?
  [[ $ec -eq 0 ]] && return
  echo "[자동복구] NOVA 1.4.0 적용 실패 — 이전 NOVA 복구" >&2
  [[ $NEW_STARTED -eq 1 ]] && sudo docker rm -f "$CONTAINER" >/dev/null 2>&1 || true
  if [[ $OLD_RENAMED -eq 1 ]]; then sudo docker rename "$BACKUP" "$CONTAINER" >/dev/null 2>&1 || true; sudo docker start "$CONTAINER" >/dev/null 2>&1 || true; fi
}
trap cleanup EXIT
trap rollback ERR
[[ "$(id -u)" -ne 0 ]] || fail "ubuntu 사용자로 실행하세요."

say "1/7 Key/Secret + 기존 학습데이터 확인"
[[ -s "$APP_DIR/.env" ]] || fail "$APP_DIR/.env 없음 — 기존 Key/Secret 보존 환경을 찾지 못했습니다."
KEYLEN="$(sed -n 's/^KIWOOM_APP_KEY=//p' "$APP_DIR/.env" | tail -n1 | awk '{print length}')"
SECLEN="$(sed -n -e 's/^KIWOOM_APP_SECRET=//p' -e 's/^KIWOOM_SECRET_KEY=//p' "$APP_DIR/.env" | tail -n1 | awk '{print length}')"
[[ ${KEYLEN:-0} -gt 5 && ${SECLEN:-0} -gt 5 ]] || fail "Key/Secret 값 확인 실패"
mkdir -p "$APP_DIR/data"; chmod 700 "$APP_DIR/data"
echo "KEY_SECRET=OK (values hidden)"
echo "DATA_DIR=$APP_DIR/data"

say "2/7 NOVA 1.4.0 파일 받기"
git clone --depth 1 "$REPO_URL" "$TMP/repo" >/dev/null
[[ -f "$TMP/repo/$ZIP_NAME" ]] || fail "GitHub 최상위에 $ZIP_NAME 파일이 없습니다."
unzip -q "$TMP/repo/$ZIP_NAME" -d "$TMP/src"
ROOT="$TMP/src/$ROOT_NAME"
[[ -f "$ROOT/Dockerfile" && -f "$ROOT/app/main.py" && -f "$ROOT/static/nova.js" ]] || fail "ZIP 내부 구조 오류"

say "3/7 정적 검증"
python3 -m py_compile "$ROOT/app/main.py"
grep -Fq "APP_VERSION='NOVA-1.4.0'" "$ROOT/app/main.py" || fail "버전 동기화 누락"
grep -Fq "ka10059" "$ROOT/app/main.py" || fail "기관/투신/연기금 수급 누락"
grep -Fq "penfnd_etc" "$ROOT/app/main.py" || fail "연기금 필드 누락"
grep -Fq "invtrt" "$ROOT/app/main.py" || fail "투신 필드 누락"
grep -Fq "ka90004" "$ROOT/app/main.py" || fail "프로그램매매 누락"
grep -Fq "LEARN_MIN_SAMPLES" "$ROOT/app/main.py" || fail "자기학습 최소표본 게이트 누락"
grep -Fq "LEARN_MAX_ADJUST" "$ROOT/app/main.py" || fail "학습 가중치 상한 누락"
grep -Fq "Adaptive Learning" "$ROOT/static/index.html" || fail "자기학습 UI 누락"
grep -Fq "BUY SIGNAL MANAGEMENT" "$ROOT/static/index.html" || fail "매수신호 관리 UI 누락"
grep -Fq "/api/buy-signals" "$ROOT/app/main.py" || fail "매수신호 API 누락"
grep -Fq "BUY_SIGNAL_FILE" "$ROOT/app/main.py" || fail "매수신호 영구기록 누락"
grep -Fq "record_buy_signal" "$ROOT/app/main.py" || fail "신호횟수 로직 누락"
grep -Fq "update_sector_context" "$ROOT/app/main.py" || fail "섹터 동조 엔진 누락"
grep -Fq "sector_score" "$ROOT/app/main.py" || fail "섹터 점수 누락"
grep -Fq "Leader → Follower" "$ROOT/static/index.html" || fail "섹터 확산 UI 누락"

say "4/7 Docker build"
sudo docker build --pull -t "$IMAGE" "$ROOT"
sudo docker network inspect "$NETWORK" >/dev/null 2>&1 || sudo docker network create "$NETWORK" >/dev/null

say "5/7 기존 NOVA 안전 교체"
sudo docker rm -f "$BACKUP" >/dev/null 2>&1 || true
OWNER_ID="$(sudo docker ps -q --filter publish=${HOST_PORT} | head -n1 || true)"
if sudo docker inspect "$CONTAINER" >/dev/null 2>&1; then
  sudo docker stop "$CONTAINER" >/dev/null 2>&1 || true
  sudo docker rename "$CONTAINER" "$BACKUP"
  OLD_RENAMED=1
elif [[ -n "$OWNER_ID" ]]; then
  OWNER_NAME="$(sudo docker inspect "$OWNER_ID" --format '{{.Name}}' | sed 's#^/##')"
  fail "포트 ${HOST_PORT}을 다른 컨테이너 ${OWNER_NAME}가 사용 중입니다. 자동삭제하지 않고 중단합니다."
fi
sudo docker run -d \
  --name "$CONTAINER" \
  --restart unless-stopped \
  --network "$NETWORK" \
  --env-file "$APP_DIR/.env" \
  -e NOVA_DATA_DIR=/app/data \
  -e NOVA_SMART_POLL_SECONDS=8 \
  -e NOVA_SMART_POLL_BATCH=8 \
  -e NOVA_LEARN_MIN_SAMPLES=60 \
  -e NOVA_LEARN_MAX_ADJUST=0.30 \
  -e NOVA_SECTOR_MAX_BONUS=10 \
  -v "$APP_DIR/data:/app/data" \
  -p 127.0.0.1:${HOST_PORT}:8000 \
  "$IMAGE" >/dev/null
NEW_STARTED=1

say "6/7 Health + 스마트머니 + 학습엔진 확인"
HEALTH=""
for _ in $(seq 1 60); do HEALTH="$(curl -fsS --max-time 3 http://127.0.0.1:${HOST_PORT}/api/health 2>/dev/null || true)"; [[ -n "$HEALTH" ]] && break; sleep 2; done
[[ -n "$HEALTH" ]] || { sudo docker logs --tail 200 "$CONTAINER" || true; fail "NOVA 1.4.0 health 실패"; }
printf '%s' "$HEALTH" > "$TMP/health.json"
python3 - "$TMP/health.json" <<'PY'
import json,sys
h=json.load(open(sys.argv[1]))
assert h.get('ok') is True,h
assert h.get('version')=='NOVA-1.4.0',h.get('version')
assert isinstance(h.get('learning'),dict),h
assert isinstance(h.get('smart_money'),dict),h
assert isinstance(h.get('sector'),dict),h
print('HEALTH=OK version='+h['version']+' learning_samples='+str((h.get('learning') or {}).get('samples'))+' learning_active='+str((h.get('learning') or {}).get('active')))
PY
curl -fsS --max-time 5 http://127.0.0.1:${HOST_PORT}/api/nova | python3 -c 'import sys,json;j=json.load(sys.stdin); h=j.get("health") or {}; print("NOVA_API=OK rows=",len(j.get("rows") or []),"sector=",h.get("sector_status"),"smart=",h.get("smart_status"),"learning=",h.get("learning"))'
curl -fsS --max-time 5 http://127.0.0.1:${HOST_PORT}/api/buy-signals | python3 -c 'import sys,json;j=json.load(sys.stdin); assert j.get("version")=="NOVA-1.4.0"; print("BUY_SIGNAL_API=OK rows=",len(j.get("rows") or []),"events=",j.get("total_events"))'

say "7/7 완료"
if [[ $OLD_RENAMED -eq 1 ]]; then sudo docker rm -f "$BACKUP" >/dev/null 2>&1 || true; OLD_RENAMED=0; fi
trap - ERR
sudo docker image prune -f >/dev/null 2>&1 || true
echo "=== QUANT NOVA 1.4.0 FINAL ==="
echo "IMAGE=$IMAGE"
echo "CONTAINER=$CONTAINER"
echo "STATUS=$(sudo docker inspect "$CONTAINER" --format '{{.State.Status}}')"
echo "KEY_SECRET=PRESERVED"
echo "DATA_DIR=$APP_DIR/data"
echo "PUBLIC_URL=https://3-38-25-20.nip.io"
curl -s http://127.0.0.1:${HOST_PORT}/api/health | python3 -c 'import sys,json;h=json.load(sys.stdin); print("version=",h.get("version"));print("feed=",(h.get("feed") or {}).get("state"));print("smart_money=",h.get("smart_money"));print("learning=",h.get("learning"))'
