#!/usr/bin/env bash
set -Eeuo pipefail
REPO_URL="https://github.com/bbblaprk-svg/kiwoom-smartmoney-daytrader.git"
ZIP_NAME="QUANT_NOVA_1.6.0_RALLY_DNA_SELF_LEARNING.zip"
ROOT_NAME="nova160"
APP_DIR="$HOME/quant-nova"
IMAGE="quant-nova:1.6.0"
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
  echo "[자동복구] NOVA 1.6.0 적용 실패 — 이전 NOVA 복구" >&2
  [[ $NEW_STARTED -eq 1 ]] && sudo docker rm -f "$CONTAINER" >/dev/null 2>&1 || true
  if [[ $OLD_RENAMED -eq 1 ]]; then
    sudo docker rename "$BACKUP" "$CONTAINER" >/dev/null 2>&1 || true
    sudo docker start "$CONTAINER" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT
trap rollback ERR
[[ "$(id -u)" -ne 0 ]] || fail "ubuntu 사용자로 실행하세요."

say "1/7 Key/Secret + 기존 학습/성과 데이터 확인"
[[ -s "$APP_DIR/.env" ]] || fail "$APP_DIR/.env 없음 — 기존 Key/Secret 보존 환경을 찾지 못했습니다."
KEYLEN="$(sed -n 's/^KIWOOM_APP_KEY=//p' "$APP_DIR/.env" | tail -n1 | awk '{print length}')"
SECLEN="$(sed -n -e 's/^KIWOOM_APP_SECRET=//p' -e 's/^KIWOOM_SECRET_KEY=//p' "$APP_DIR/.env" | tail -n1 | awk '{print length}')"
[[ ${KEYLEN:-0} -gt 5 && ${SECLEN:-0} -gt 5 ]] || fail "Key/Secret 값 확인 실패"
mkdir -p "$APP_DIR/data"; chmod 700 "$APP_DIR/data"
echo "KEY_SECRET=OK (values hidden)"
echo "DATA_DIR=$APP_DIR/data"

say "2/7 NOVA 1.6.0 파일 받기"
git clone --depth 1 "$REPO_URL" "$TMP/repo" >/dev/null
[[ -f "$TMP/repo/$ZIP_NAME" ]] || fail "GitHub 최상위에 $ZIP_NAME 파일이 없습니다."
unzip -q "$TMP/repo/$ZIP_NAME" -d "$TMP/src"
ROOT="$TMP/src/$ROOT_NAME"
[[ -f "$ROOT/Dockerfile" && -f "$ROOT/app/main.py" && -f "$ROOT/static/nova.js" ]] || fail "ZIP 내부 구조 오류"

say "3/7 정적 검증 — RALLY DNA EOD 복기 + 다음날 적용 + 이중 BUY"
python3 -m py_compile "$ROOT/app/main.py"
grep -Fq "APP_VERSION='NOVA-1.6.0'" "$ROOT/app/main.py" || fail "버전 동기화 누락"
grep -Fq "ENTRY_V4_RALLY_DNA" "$ROOT/app/main.py" || fail "RALLY DNA 진입 정책 누락"
grep -Fq "PULLBACK_REACCEL" "$ROOT/app/main.py" || fail "눌림 재가속 BUY 누락"
grep -Fq "DIRECT_IGNITION" "$ROOT/app/main.py" || fail "직접점화 BUY 누락"
grep -Fq "DIRECT_ARM" "$ROOT/app/main.py" || fail "DIRECT 확인상태 누락"
grep -Fq "dynamic_reentry_ok" "$ROOT/app/main.py" || fail "새 파동 재진입 판정 누락"
grep -Fq "BUY@" "$ROOT/app/main.py" || fail "BUY별 독립 학습 캡처 누락"
grep -Fq "buy_entry_events_v3.jsonl" "$ROOT/app/main.py" || fail "V3 BUY 원장 누락"
grep -Fq "adaptive_entry_model_v3.json" "$ROOT/app/main.py" || fail "V3 학습모델 누락"
grep -Fq "quota_enforced':False" "$ROOT/app/main.py" || fail "신호 quota 금지 누락"
grep -Fq "독립 확인 경로" "$ROOT/static/index.html" || fail "이중경로 UI 누락"

grep -Fq "rally_dna_model.json" "$ROOT/app/main.py" || fail "RALLY DNA 모델 파일 누락"
grep -Fq "rally_dna_samples.jsonl" "$ROOT/app/main.py" || fail "RALLY DNA 표본 원장 누락"
grep -Fq "rally_trace_loop" "$ROOT/app/main.py" || fail "장중 trace 수집 누락"
grep -Fq "review_rally_day" "$ROOT/app/main.py" || fail "장종료 복기 누락"
grep -Fq "EOD_REVIEW_NEXT_DAY_ONLY" "$ROOT/app/main.py" || fail "미래정보 누출 방지 누락"
grep -Fq "RALLY DNA SELF-LEARNING" "$ROOT/static/index.html" || fail "RALLY DNA UI 누락"

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
  -e NOVA_SECTOR_MAX_BONUS=8 \
  -e NOVA_RALLY_TRACE_INTERVAL=60 \
  -e NOVA_RALLY_TRACE_TOP=80 \
  -e NOVA_RALLY_MIN_SAMPLES=30 \
  -e NOVA_RALLY_MAX_BONUS=8 \
  -e NOVA_RALLY_MAX_PENALTY=6 \
  -e NOVA_RALLY_TRIGGER_RATE=5.0 \
  -e NOVA_RALLY_TARGET_RATE=10.0 \
  -e NOVA_RALLY_TRACE_KEEP_DAYS=20 \
  -e NOVA_ENTRY_PRESSURE_SCORE=62 \
  -e NOVA_ENTRY_HOLD_SEC=8 \
  -e NOVA_ENTRY_PULLBACK_MIN=0.12 \
  -e NOVA_ENTRY_PULLBACK_MAX=2.00 \
  -e NOVA_ENTRY_REACCEL_SEC=3 \
  -e NOVA_ENTRY_COOLDOWN_SEC=600 \
  -e NOVA_ENTRY_REENTRY_MIN_SEC=420 \
  -e NOVA_ENTRY_REENTRY_GAIN_PCT=1.20 \
  -e NOVA_ENTRY_MAX_DAILY=4 \
  -e NOVA_ENTRY_MAX_VWAP_GAP=1.50 \
  -e NOVA_ENTRY_MAX_IMPULSE=2.50 \
  -e NOVA_ENTRY_MIN_BUY_PRESSURE=56 \
  -e NOVA_ENTRY_MIN_ALGO_PERSIST=55 \
  -e NOVA_DIRECT_SCORE=75 \
  -e NOVA_DIRECT_HOLD_SEC=6 \
  -e NOVA_DIRECT_CONFIRM_SEC=3 \
  -e NOVA_DIRECT_MIN_BUY_PRESSURE=61 \
  -e NOVA_DIRECT_MIN_ALGO_PERSIST=60 \
  -e NOVA_DIRECT_MIN_ACCEL=1.65 \
  -e NOVA_DIRECT_MIN_BREAKOUT=0.20 \
  -e NOVA_DIRECT_MIN_IMPULSE=0.25 \
  -e NOVA_DIRECT_MAX_IMPULSE=1.80 \
  -e NOVA_DIRECT_MAX_VWAP_GAP=1.10 \
  -v "$APP_DIR/data:/app/data" \
  -p 127.0.0.1:${HOST_PORT}:8000 \
  "$IMAGE" >/dev/null
NEW_STARTED=1

say "6/7 Health + 균형 정책 확인"
HEALTH=""
for _ in $(seq 1 60); do
  HEALTH="$(curl -fsS --max-time 3 http://127.0.0.1:${HOST_PORT}/api/health 2>/dev/null || true)"
  [[ -n "$HEALTH" ]] && break
  sleep 2
done
[[ -n "$HEALTH" ]] || { sudo docker logs --tail 200 "$CONTAINER" || true; fail "NOVA 1.6.0 health 실패"; }
printf '%s' "$HEALTH" > "$TMP/health.json"
python3 - "$TMP/health.json" <<'PY'
import json,sys
h=json.load(open(sys.argv[1]))
assert h.get('ok') is True,h
assert h.get('version')=='NOVA-1.6.0',h.get('version')
ep=h.get('entry_policy') or {}
assert ep.get('version')=='ENTRY_V4_RALLY_DNA',ep
assert ep.get('routes')==['PULLBACK_REACCEL','DIRECT_IGNITION'],ep
assert ep.get('cooldown_sec')==600,ep
assert ep.get('reentry_min_sec')==420,ep
assert ep.get('max_daily')==4,ep
assert ep.get('quota_enforced') is False,ep
assert ep.get('timezone')=='Asia/Seoul',ep
assert ep.get('rally_min_samples')==30,ep
assert ep.get('rally_max_bonus')==8.0,ep
assert ep.get('rally_max_penalty')==6.0,ep
print('HEALTH=OK version='+h['version']+' entry='+ep.get('version')+' routes='+','.join(ep['routes'])+' rallyDNA=NEXT_DAY_ONLY')
PY
curl -fsS --max-time 5 http://127.0.0.1:${HOST_PORT}/api/nova | python3 -c 'import sys,json;j=json.load(sys.stdin); print("NOVA_API=OK rows=",len(j.get("rows") or []),"policy=",(j.get("policy") or {}).get("entry_policy"))'
curl -fsS --max-time 5 http://127.0.0.1:${HOST_PORT}/api/buy-signals | python3 -c 'import sys,json;j=json.load(sys.stdin); assert j.get("version")=="NOVA-1.6.0"; print("BUY_API=OK rows=",len(j.get("rows") or []),"events=",j.get("total_events"))'
curl -fsS --max-time 5 http://127.0.0.1:${HOST_PORT}/api/rally-dna | python3 -c 'import sys,json;j=json.load(sys.stdin); assert j.get("version")=="NOVA-1.6.0"; print("RALLY_DNA_API=OK samples=",(j.get("status") or {}).get("samples"),"active=",(j.get("status") or {}).get("active"))'

say "7/7 완료"
if [[ $OLD_RENAMED -eq 1 ]]; then sudo docker rm -f "$BACKUP" >/dev/null 2>&1 || true; OLD_RENAMED=0; fi
trap - ERR
sudo docker image prune -f >/dev/null 2>&1 || true
echo "=== QUANT NOVA 1.6.0 FINAL ==="
echo "IMAGE=$IMAGE"
echo "CONTAINER=$CONTAINER"
echo "STATUS=$(sudo docker inspect "$CONTAINER" --format '{{.State.Status}}')"
echo "KEY_SECRET=PRESERVED"
echo "DATA_DIR=$APP_DIR/data"
echo "PUBLIC_URL=https://3-38-25-20.nip.io"
curl -s http://127.0.0.1:${HOST_PORT}/api/health | python3 -c 'import sys,json;h=json.load(sys.stdin); print("version=",h.get("version"));print("feed=",(h.get("feed") or {}).get("state"));print("entry_policy=",h.get("entry_policy"));print("learning=",h.get("learning"));print("rally_dna=",(h.get("entry_policy") or {}).get("rally_dna"))'
