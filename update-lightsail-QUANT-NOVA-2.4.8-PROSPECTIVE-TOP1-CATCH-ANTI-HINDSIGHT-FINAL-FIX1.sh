#!/usr/bin/env bash
set -Eeuo pipefail

REPO_URL="https://github.com/bbblaprk-svg/kiwoom-smartmoney-daytrader.git"
ZIP_NAME="QUANT_NOVA_2.4.8_PROSPECTIVE_TOP1_CATCH_ANTI_HINDSIGHT_FINAL.zip"
ROOT_NAME="nova248"
EXPECTED_ZIP_SHA256="b10b01d9d9baa83120b23f9d8c071a12915cdcb829062a8e711d16dc9be2320b"
APP_DIR="$HOME/quant-nova"
IMAGE="quant-nova:2.4.8"
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
  echo "[자동복구] NOVA 2.4.8 적용 실패 — 이전 NOVA 복구" >&2
  [[ $NEW_STARTED -eq 1 ]] && sudo docker rm -f "$CONTAINER" >/dev/null 2>&1 || true
  if [[ $OLD_RENAMED -eq 1 ]]; then
    sudo docker rename "$BACKUP" "$CONTAINER" >/dev/null 2>&1 || true
    sudo docker start "$CONTAINER" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT
trap rollback ERR
[[ "$(id -u)" -ne 0 ]] || fail "ubuntu 사용자로 실행하세요."

say "1/7 Key/Secret + 기존 BUY/RALLY/EXIT/학습 데이터 보존 확인"
[[ -s "$APP_DIR/.env" ]] || fail "$APP_DIR/.env 없음 — 기존 Key/Secret 보존 환경을 찾지 못했습니다."
KEYLEN="$(sed -n 's/^KIWOOM_APP_KEY=//p' "$APP_DIR/.env" | tail -n1 | awk '{print length}')"
SECLEN="$(sed -n -e 's/^KIWOOM_APP_SECRET=//p' -e 's/^KIWOOM_SECRET_KEY=//p' "$APP_DIR/.env" | tail -n1 | awk '{print length}')"
[[ ${KEYLEN:-0} -gt 5 && ${SECLEN:-0} -gt 5 ]] || fail "Key/Secret 값 확인 실패"
mkdir -p "$APP_DIR/data"; chmod 700 "$APP_DIR/data"
echo "KEY_SECRET=OK (values hidden)"
echo "DATA_DIR=$APP_DIR/data"

say "2/7 NOVA 2.4.8 파일 받기 + SHA/manifest 검증"
for c in git unzip python3 node curl docker sha256sum; do command -v "$c" >/dev/null 2>&1 || fail "필수 명령 없음: $c"; done
git clone --depth 1 "$REPO_URL" "$TMP/repo" >/dev/null
[[ -f "$TMP/repo/$ZIP_NAME" ]] || fail "GitHub 최상위에 $ZIP_NAME 파일이 없습니다."
ACTUAL_SHA="$(sha256sum "$TMP/repo/$ZIP_NAME" | awk '{print $1}')"
[[ "$ACTUAL_SHA" == "$EXPECTED_ZIP_SHA256" ]] || fail "ZIP SHA256 불일치: 예상=$EXPECTED_ZIP_SHA256 실제=$ACTUAL_SHA"
unzip -q "$TMP/repo/$ZIP_NAME" -d "$TMP/src"
ROOT="$TMP/src/$ROOT_NAME"
[[ -f "$ROOT/Dockerfile" && -f "$ROOT/app/main.py" && -f "$ROOT/app/evidence_engine.py" && -f "$ROOT/app/archive_engine.py" && -f "$ROOT/static/nova.js" && -f "$ROOT/config/krx_holidays.json" && -f "$ROOT/scripts/replay_backtest.py" && -f "$ROOT/scripts/selfcheck.py" && -f "$ROOT/SOURCE_MANIFEST.sha256" ]] || fail "ZIP 내부 구조 오류"
(cd "$ROOT" && sha256sum -c SOURCE_MANIFEST.sha256 >/dev/null) || fail "SOURCE_MANIFEST 무결성 검사 실패"

say "3/7 정적 사전검증 — full selfcheck는 Docker 내부에서 requirements 설치 후 실행"
python3 -m py_compile "$ROOT/app/main.py" "$ROOT/app/evidence_engine.py" "$ROOT/app/archive_engine.py" "$ROOT/scripts/replay_backtest.py" "$ROOT/scripts/selfcheck.py"
# Host preflight intentionally avoids importing app dependencies.
# Full selfcheck runs inside Docker after requirements.txt is installed.
node --check "$ROOT/static/nova.js"
grep -Fq "APP_VERSION='NOVA-2.4.8'" "$ROOT/app/main.py" || fail "버전 동기화 누락"
grep -Fq "ENTRY_V18_TRUTH_GUARD_MAX_PROFIT" "$ROOT/app/main.py" || fail "ENTRY V18 정책 누락"
# Official realtime semantics: trade 0B / program 0w / orderbook 0D.
grep -Fq "official={'trade':'0B','program':'0w','orderbook':'0D'}" "$ROOT/app/main.py" || fail "공식 WS 0B/0w/0D health check 누락"
grep -Fq "c.update({'trade_type':'0B','program_type':'0w','orderbook_type':'0D','source':'OFFICIAL_FIXED_CONTRACT'})" "$ROOT/app/main.py" || fail "공식 WS 계약 고정 누락"
grep -Fq "UNKNOWN_VENUE_FAIL_CLOSED" "$ROOT/app/main.py" || fail "UNKNOWN venue fail-closed 누락"
grep -Fq "orderbook_prev_by_venue" "$ROOT/app/main.py" || fail "KRX/NXT 호가 baseline 분리 누락"
grep -Fq "krx_buy_pressure" "$ROOT/app/main.py" || fail "KRX venue microflow 분리 누락"
grep -Fq "nxt_buy_pressure" "$ROOT/app/main.py" || fail "NXT venue microflow 분리 누락"
grep -Fq "def venue_flow_snapshot" "$ROOT/app/main.py" || fail "venue flow snapshot 누락"
grep -Fq "def venue_exit_strength" "$ROOT/app/main.py" || fail "자동 EXIT venue strength 누락"
grep -Fq "def venue_smart_direction_ok" "$ROOT/app/main.py" || fail "venue smart-money gate 누락"
grep -Fq "entry_venue_strength" "$ROOT/app/main.py" || fail "EXIT entry venue strength baseline 누락"
grep -Fq "market_price" "$ROOT/app/main.py" || fail "same-venue EXIT price 누락"
grep -Fq "c.last_signal_venue=='NXT'" "$ROOT/app/main.py" || fail "NXT 관리테이블 KRX BUY 차단 누락"
grep -Fq "venue_smart_flow_score(c,'NXT')" "$ROOT/app/main.py" || fail "NXT 관리테이블 NXT-only smart score 누락"
grep -Fq "c.last_price_by_venue.get('NXT')" "$ROOT/app/main.py" || fail "NXT 관리테이블 NXT-only price 누락"
grep -Fq "if nxt_price<=0 or not nxt_at:return False" "$ROOT/app/main.py" || fail "NXT alert verified-tick fail-closed 누락"
grep -Fq "style in ('SWING','CLOSE_BET') and mode=='ELITE'" "$ROOT/app/main.py" || fail "ELITE SWING/CLOSE_BET 보호곡선 누락"
grep -Fq "if mfe>=35:return 18.0" "$ROOT/app/main.py" || fail "ELITE MFE35 보호선 누락"
grep -Fq "if mfe>=22:return 10.0" "$ROOT/app/main.py" || fail "ELITE MFE22 보호선 누락"
grep -Fq "if mfe>=12:return 4.0" "$ROOT/app/main.py" || fail "ELITE MFE12 보호선 누락"
grep -Fq "NXT_CLOSE_BET_WINDOW_START_SECONDS=19*3600+30*60" "$ROOT/app/main.py" || fail "19:30 CLOSE_BET window 누락"
grep -Fq "NXT_CLOSE_BET_WINDOW_END_SECONDS=19*3600+50*60" "$ROOT/app/main.py" || fail "19:50 CLOSE_BET window 종료 누락"
grep -Fq "emit_close_bet_candidate_alert" "$ROOT/app/main.py" || fail "CLOSE_BET 후보별 READY/BUY Push 누락"
grep -Fq "NXT_RECOVERY_RECLAIM" "$ROOT/app/main.py" || fail "NXT 장기회복 BUY route 누락"
grep -Fq "RECOVERY_READY" "$ROOT/app/main.py" || fail "RECOVERY_READY 누락"
grep -Fq "RECOVERY_BUY" "$ROOT/app/main.py" || fail "RECOVERY_BUY 누락"
grep -Fq "NXT_RECOVERY_MAX_PEAK_AGE_SECONDS" "$ROOT/app/main.py" || fail "5시간 recovery horizon 누락"
grep -Fq "def _auto_exit_runner_trail_floor" "$ROOT/app/main.py" || fail "자동 ELITE runner trail 누락"
grep -Fq "elif style in ('SWING','CLOSE_BET') and mfe>=15" "$ROOT/app/main.py" || fail "CLOSE_BET 실제 runner trail branch 누락"
grep -Fq "if style=='SCALP' and 19*3600+50*60<=kst_seconds()<20*3600+5*60" "$ROOT/app/main.py" || fail "19:50 강제청산 SCALP-only guard 누락"
grep -Fq "push_delivered_count" "$ROOT/app/main.py" || fail "Push delivery accounting 누락"
grep -Fq "07:55_FULL_LIVE_REINIT" "$ROOT/app/main.py" || fail "07:55 WS 강제 재로그인 누락"
grep -Fq "runtime_window':'07:30-20:05 KST" "$ROOT/app/main.py" || fail "야간 WS 휴면창 누락"
grep -Fq "visibilitychange" "$ROOT/static/nova.js" || fail "iOS visibility wake 누락"
grep -Fq "pageshow" "$ROOT/static/nova.js" || fail "iOS pageshow wake 누락"
grep -Fq "addEventListener('focus'" "$ROOT/static/nova.js" || fail "iOS focus wake 누락"
grep -Fq "NXT SCORE" "$ROOT/static/nova.js" || fail "NXT 관리테이블 NXT score label 누락"
grep -Fq "MAX_CANDIDATES" "$ROOT/app/main.py" || fail "Candidate hard cap 누락"
grep -Fq "STRUCTURAL_ONLY" "$ROOT/app/main.py" || fail "STATE.lock structural-only policy 누락"
grep -Fq "orphan_ticks_dropped" "$ROOT/app/main.py" || fail "orphan WS tick drop guard 누락"
grep -Fq "def classify_market_event" "$ROOT/app/main.py" || fail "Event Polarity Guard 누락"
grep -Fq "nxt_orderbook_wall_v2_score" "$ROOT/app/main.py" || fail "Orderbook Wall V2 NXT metric 누락"
grep -Fq "orderbook_wall_cancel_risk" "$ROOT/app/main.py" || fail "Wall V2 cancel-risk 누락"
grep -Fq "def replay_journal_file" "$ROOT/app/main.py" || fail "Replay Journal 누락"
grep -Fq "write_evidence_report" "$ROOT/app/main.py" || fail "Evidence Engine 연결 누락"
grep -Fq "archive_day" "$ROOT/app/archive_engine.py" || fail "daily gzip archive 누락"
grep -Fq "auto_apply" "$ROOT/scripts/replay_backtest.py" || fail "backtest no-auto-apply guard 누락"
grep -Fq "FAST_JUMP_WATCH" "$ROOT/app/main.py" || fail "FAST_JUMP WATCH 누락"
grep -Fq "FAST_JUMP_READY" "$ROOT/app/main.py" || fail "FAST_JUMP READY 누락"
grep -Fq "buy_prohibited':True" "$ROOT/app/main.py" || fail "FAST_JUMP/RECOVERY 매수금지 강제 누락"
grep -Fq "RECOVERY_EARLY" "$ROOT/app/main.py" || fail "RECOVERY_EARLY 관찰단계 누락"
grep -Fq "PROSPECTIVE_OBSERVATION_FILE" "$ROOT/app/main.py" || fail "prospective point-in-time 원장 누락"
grep -Fq "'future_label':None" "$ROOT/app/main.py" || fail "사후라벨 차단 누락"
grep -Fq "'future_return':None" "$ROOT/app/main.py" || fail "사후수익 차단 누락"
grep -Fq "NXT_FAST_JUMP_READY_PERCENTILE" "$ROOT/app/main.py" || fail "99백분위 관찰목표 누락"
grep -Fq "NXT_TOP1_MIN_POPULATION=max(100" "$ROOT/app/main.py" || fail "TOP1 최소 동시표본 100 guard 누락"
grep -Fq "UNPROVEN_UNTIL_SUFFICIENT_OOS" "$ROOT/app/main.py" || fail "TOP1 미검증 상태표기 누락"
grep -Fq "TOP1_AUDIT_MIN_SAMPLES=300" "$ROOT/app/evidence_engine.py" || fail "TOP1 OOS 300 표본 gate 누락"
grep -Fq "('signal','micro','observation')" "$ROOT/app/main.py" || fail "observation backtest status 누락"
grep -Fq "PROSPECTIVE TOP1 CATCH + EVIDENCE · 2.4.8" "$ROOT/static/index.html" || fail "2.4.8 UI 동기화 누락"
python3 - "$ROOT/BUILD_INFO.json" <<'PYBI'
import json,sys
b=json.load(open(sys.argv[1]))
assert b.get('version')=='NOVA-2.4.8',b
for k in ('fast_jump','recovery_early','prospective_audit','top1_target','top1_oos_gate','evidence_engine','offline_backtest','buy_policy'):
    assert b.get(k),(k,b)
assert 'UNPROVEN' in b.get('top1_target',''),b
assert '300' in b.get('top1_oos_gate',''),b
print('BUILD_INFO=OK')
PYBI

say "4/7 Docker build — 내부 py_compile/selfcheck 통과해야 적용"
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
  --log-driver json-file \
  --log-opt max-size=10m \
  --log-opt max-file=3 \
  --network "$NETWORK" \
  --env-file "$APP_DIR/.env" \
  -e NOVA_DATA_DIR=/app/data \
  -e NOVA_DISCOVERY_SECONDS=8 \
  -e NOVA_NXT_AFTER_DISCOVERY_SECONDS=5 \
  -e NOVA_NXT_EARLY_MAX_RATE=5.0 \
  -e NOVA_NXT_PRE_MAX_RATE=7.5 \
  -e NOVA_NXT_IGNITION_MAX_RATE=9.5 \
  -e NOVA_NXT_LATE_RATE=10.0 \
  -e NOVA_NXT_ALERT_COOLDOWN=180 \
  -e NOVA_NXT_RADAR_TOP=30 \
  -e NOVA_NXT_FASTEST_DISCOVERY_SECONDS=3 \
  -e NOVA_NXT_PREMARKET_DISCOVERY_SECONDS=4 \
  -e NOVA_NXT_ALLDAY_DISCOVERY_SECONDS=5 \
  -e NOVA_NXT_FAST_REST_TIMEOUT=2.7 \
  -e NOVA_NXT_SLOW_CONTEXT_SECONDS=15 \
  -e NOVA_NXT_ALLDAY_INTEGRATED_EVERY=2 \
  -e NOVA_NXT_BURST_WATCH_LIMIT=20 \
  -e NOVA_NXT_BURST_HIGHRES_LIMIT=8 \
  -e NOVA_NXT_WS_EMERGENCY_ACCEL30=2.20 \
  -e NOVA_NXT_WS_EMERGENCY_ACCEL60=1.70 \
  -e NOVA_NXT_WS_EMERGENCY_BUY_PRESSURE=62 \
  -e NOVA_NXT_WS_EMERGENCY_MAX_RATE=9.5 \
  -e NOVA_NXT_WS_EMERGENCY_COOLDOWN=90 \
  -e NOVA_NXT_FAST_JUMP_MIN_RATE=8.0 \
  -e NOVA_NXT_FAST_JUMP_MAX_RATE=15.0 \
  -e NOVA_NXT_FAST_JUMP_READY_HOLD_SECONDS=20 \
  -e NOVA_NXT_FAST_JUMP_MIN_BP=60 \
  -e NOVA_NXT_FAST_JUMP_MIN_ALGO=58 \
  -e NOVA_NXT_FAST_JUMP_MIN_ACCEL30=1.70 \
  -e NOVA_NXT_FAST_JUMP_MIN_ACCEL60=1.30 \
  -e NOVA_NXT_FAST_JUMP_WATCH_PERCENTILE=95 \
  -e NOVA_NXT_FAST_JUMP_READY_PERCENTILE=99 \
  -e NOVA_NXT_FAST_JUMP_READY_MIN_POPULATION=20 \
  -e NOVA_NXT_TOP1_MIN_POPULATION=100 \
  -e NOVA_NXT_BURST_TTL_SECONDS=90 \
  -e NOVA_NXT_SECOND_WAVE_MEMORY_SECONDS=18000 \
  -e NOVA_NXT_SECOND_WAVE_POOL_LIMIT=20 \
  -e NOVA_NXT_MEMORY_BAR_KEEP_MINUTES=300 \
  -e NOVA_NXT_SECOND_WAVE_MIN_PEAK_RATE=5.0 \
  -e NOVA_NXT_SECOND_WAVE_MIN_PULLBACK=3.0 \
  -e NOVA_NXT_SECOND_WAVE_MAX_PULLBACK=10.0 \
  -e NOVA_NXT_SECOND_WAVE_BASE_MIN_SECONDS=360 \
  -e NOVA_NXT_SECOND_WAVE_BASE_MAX_SECONDS=1200 \
  -e NOVA_NXT_SECOND_WAVE_MAX_RANGE=1.35 \
  -e NOVA_NXT_SECOND_WAVE_MAX_DRYUP=0.45 \
  -e NOVA_NXT_SECOND_WAVE_READY_ACCEL30=1.45 \
  -e NOVA_NXT_SECOND_WAVE_READY_ACCEL60=1.25 \
  -e NOVA_NXT_SECOND_WAVE_BUY_ACCEL30=1.70 \
  -e NOVA_NXT_SECOND_WAVE_BUY_ACCEL60=1.40 \
  -e NOVA_NXT_SECOND_WAVE_BREAKOUT=0.18 \
  -e NOVA_NXT_SECOND_WAVE_MAX_ENTRY_RATE=12.0 \
  -e NOVA_NXT_RECOVERY_MIN_PULLBACK=4.0 \
  -e NOVA_NXT_RECOVERY_MAX_PULLBACK=15.0 \
  -e NOVA_NXT_RECOVERY_MIN_PEAK_AGE_SECONDS=900 \
  -e NOVA_NXT_RECOVERY_MAX_PEAK_AGE_SECONDS=18000 \
  -e NOVA_NXT_RECOVERY_MIN_TROUGH_AGE_SECONDS=120 \
  -e NOVA_NXT_RECOVERY_EARLY_RATIO=0.30 \
  -e NOVA_NXT_RECOVERY_EARLY_TROUGH_AGE_SECONDS=60 \
  -e NOVA_NXT_RECOVERY_READY_RATIO=0.50 \
  -e NOVA_NXT_RECOVERY_BUY_RATIO=0.68 \
  -e NOVA_NXT_RECOVERY_READY_BP=55 \
  -e NOVA_NXT_RECOVERY_BUY_BP=58 \
  -e NOVA_NXT_RECOVERY_READY_ALGO=54 \
  -e NOVA_NXT_RECOVERY_BUY_ALGO=58 \
  -e NOVA_NXT_RECOVERY_READY_PEAK_GAP=5.0 \
  -e NOVA_NXT_RECOVERY_BUY_PEAK_GAP=3.5 \
  -e NOVA_NXT_RECOVERY_MAX_ENTRY_RATE=18.5 \
  -e NOVA_NXT_CLOSE_PICK_LIMIT=12 \
  -e NOVA_NXT_CLOSE_PICK_MIN_SCORE=52 \
  -e NOVA_NXT_CLOSE_BET_READY_SCORE=64 \
  -e NOVA_NXT_CLOSE_BET_BUY_SCORE=74 \
  -e NOVA_NXT_CLOSE_BET_LIMIT=5 \
  -e NOVA_WS_CORE_LIMIT=40 \
  -e NOVA_WS_CHALLENGER_LIMIT=40 \
  -e NOVA_SOURCE_TTL_SECONDS=24 \
  -e NOVA_CANDIDATE_TTL_SECONDS=600 \
  -e NOVA_REST_PACE_SECONDS=0.225 \
  -e NOVA_REST_MAX_INFLIGHT=4 \
  -e NOVA_SCORING_COALESCE_MS=80 \
  -e NOVA_SECTOR_CONTEXT_INTERVAL=0.75 \
  -e NOVA_PERSIST_INTERVAL_SECONDS=60 \
  -e NOVA_PERF_GUARD_INTERVAL_SECONDS=30 \
  -e NOVA_LOG_MAINTENANCE_SECONDS=600 \
  -e NOVA_OP_LOG_MAX_MB=32 \
  -e NOVA_OP_LOG_KEEP_LINES=50000 \
  -e NOVA_WS_REG_ACK_TIMEOUT=5 \
  -e NOVA_WS_REG_MAX_RETRY=2 \
  -e NOVA_WS_RECONNECT_BASE=1 \
  -e NOVA_WS_RECONNECT_MAX=30 \
  -e NOVA_WS_RECONNECT_JITTER=0.20 \
  -e NOVA_WS_WAKE_GUARD_SECONDS=5 \
  -e NOVA_WS_CONTRACT_PROBE_SECONDS=3 \
  -e NOVA_WS_CONTRACT_REPROBE_SECONDS=3600 \
  -e NOVA_MAX_CANDIDATES=1200 \
  -e NOVA_EVIDENCE_REFRESH_SECONDS=300 \
  -e NOVA_REPLAY_INTERVAL_SECONDS=2 \
  -e NOVA_REPLAY_QUEUE_MAX=10000 \
  -e NOVA_ARCHIVE_REFRESH_SECONDS=1800 \
  -e NOVA_ORDERBOOK_WALL_RATIO=2.2 \
  -e NOVA_ORDERBOOK_WALL_PERSIST_SECONDS=3 \
  -e NOVA_ORDERBOOK_WALL_V2_MAX_BONUS=2.5 \
  -e NOVA_ORDERBOOK_WALL_CANCEL_DROP=0.65 \
  -e NOVA_ORDERBOOK_CORE_LIMIT=30 \
  -e NOVA_ORDERBOOK_CHALLENGER_LIMIT=10 \
  -e NOVA_ORDERBOOK_FRESH_SECONDS=3 \
  -e NOVA_ORDERBOOK_MAX_BONUS=6 \
  -e NOVA_MARKET_EVENT_POLL_SECONDS=60 \
  -e NOVA_MARKET_EVENT_TTL_SECONDS=1800 \
  -e NOVA_MARKET_EVENT_MAX_BONUS=4 \
  -e NOVA_SMART_POLL_SECONDS=5 \
  -e NOVA_SMART_POLL_BATCH=10 \
  -e NOVA_CHALLENGER_SMART_LIMIT=10 \
  -e NOVA_CHALLENGER_INVESTOR_INTERVAL=30 \
  -e NOVA_INVESTOR_REFRESH_TARGET_SECONDS=30 \
  -e NOVA_PROGRAM_FALLBACK_REFRESH_SECONDS=18 \
  -e NOVA_SMART_PROGRAM_FALLBACK_BATCH=3 \
  -e NOVA_PROGRAM_HARD_FRESH_SECONDS=25 \
  -e NOVA_INVESTOR_FRESH_SECONDS=45 \
  -e NOVA_TICK_SIGNATURE_WINDOW=160 \
  -e NOVA_PRICE_JUMP_QUARANTINE_PCT=6 \
  -e NOVA_PRICE_HARD_JUMP_PCT=12 \
  -e NOVA_PRICE_CONFIRM_TOLERANCE_PCT=1.5 \
  -e NOVA_PRICE_QUARANTINE_SECONDS=3 \
  -e NOVA_PRICE_RATE_MISMATCH_PCT=2 \
  -e NOVA_LEARN_MIN_SAMPLES=60 \
  -e NOVA_LEARN_MAX_ADJUST=0.30 \
  -e NOVA_SECTOR_MAX_BONUS=8 \
  -e NOVA_RALLY_EPISODE_GAP_SECONDS=1200 \
  -e NOVA_RALLY_TRACE_INTERVAL=60 \
  -e NOVA_RALLY_TRACE_TOP=220 \
  -e NOVA_RALLY_MIN_SAMPLES=30 \
  -e NOVA_RALLY_MAX_BONUS=8 \
  -e NOVA_RALLY_MAX_PENALTY=6 \
  -e NOVA_RALLY_TRIGGER_RATE=5.0 \
  -e NOVA_RALLY_TARGET_RATE=10.0 \
  -e NOVA_RALLY_TRACE_KEEP_DAYS=20 \
  -e NOVA_RALLY_SAMPLE_KEEP=5000 \
  -e NOVA_RALLY_SAMPLE_COMPACT_TRIGGER=6500 \
  -e NOVA_RALLY_CAL_MIN_OOS=40 \
  -e NOVA_EXIT_TRACE_INTERVAL=60 \
  -e NOVA_EXIT_TRACE_KEEP_DAYS=20 \
  -e NOVA_EXIT_SAMPLE_KEEP=5000 \
  -e NOVA_EXIT_SAMPLE_COMPACT_TRIGGER=6500 \
  -e NOVA_EXIT_MIN_SAMPLES=40 \
  -e NOVA_EXIT_CAL_MIN_OOS=40 \
  -e NOVA_EXIT_STOP_MIN=1.8 \
  -e NOVA_EXIT_STOP_MAX=3.5 \
  -e NOVA_EXIT_PROTECT_MFE2=0.5 \
  -e NOVA_EXIT_PROTECT_MFE4=1.5 \
  -e NOVA_EXIT_PROTECT_MFE7=3.0 \
  -e NOVA_EXIT_ADD_MIN_RETURN=0.5 \
  -e NOVA_EXIT_ADD_MAX_RETURN=2.5 \
  -e NOVA_MANUAL_SCALP_TP1=3.0 \
  -e NOVA_MANUAL_SCALP_TP1_PCT=30 \
  -e NOVA_MANUAL_SCALP_TP2=5.5 \
  -e NOVA_MANUAL_SCALP_TP2_PCT=30 \
  -e NOVA_MANUAL_SCALP_STOP_MIN=2.2 \
  -e NOVA_MANUAL_SCALP_STOP_MAX=3.5 \
  -e NOVA_MANUAL_SCALP_FADE_CONFIRM=8 \
  -e NOVA_MANUAL_SWING_TP1=8.0 \
  -e NOVA_MANUAL_SWING_TP1_PCT=25 \
  -e NOVA_MANUAL_SWING_TP2=15.0 \
  -e NOVA_MANUAL_SWING_TP2_PCT=25 \
  -e NOVA_MANUAL_SWING_STOP=6.0 \
  -e NOVA_MANUAL_SWING_FADE_CONFIRM=30 \
  -e NOVA_ENTRY_PRESSURE_SCORE=62 \
  -e NOVA_ENTRY_HOLD_SEC=8 \
  -e NOVA_ENTRY_PULLBACK_MIN=0.12 \
  -e NOVA_ENTRY_PULLBACK_MAX=2.00 \
  -e NOVA_ENTRY_REACCEL_SEC=3 \
  -e NOVA_ENTRY_COOLDOWN_SEC=600 \
  -e NOVA_ENTRY_REENTRY_MIN_SEC=420 \
  -e NOVA_ENTRY_REENTRY_GAIN_PCT=1.20 \
  -e NOVA_ENTRY_MAX_DAILY=2 \
  -e NOVA_ENTRY_MAX_VWAP_GAP=1.50 \
  -e NOVA_ENTRY_MAX_IMPULSE=2.50 \
  -e NOVA_ENTRY_MIN_BUY_PRESSURE=56 \
  -e NOVA_ENTRY_MIN_ALGO_PERSIST=55 \
  -e NOVA_PULLBACK_CONFIRM_SCORE=58 \
  -e NOVA_PULLBACK_CONFIRM_BUY_PRESSURE=58 \
  -e NOVA_PULLBACK_CONFIRM_ACCEL=1.20 \
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


say "6/7 Health + Prospective/TOP1/Evidence + 기존 live engine 검증"
HEALTH=""
for _ in $(seq 1 60); do
  HEALTH="$(curl -fsS --max-time 3 http://127.0.0.1:${HOST_PORT}/api/health 2>/dev/null || true)"
  [[ -n "$HEALTH" ]] && break
  sleep 2
done
[[ -n "$HEALTH" ]] || { sudo docker logs --tail 300 "$CONTAINER" || true; fail "NOVA 2.4.8 health 실패"; }
printf '%s' "$HEALTH" > "$TMP/health.json"
python3 - "$TMP/health.json" <<'PYH'
import json,sys
h=json.load(open(sys.argv[1]))
assert h.get('ok') is True,h
assert h.get('version')=='NOVA-2.4.8',h.get('version')
ep=h.get('entry_policy') or {}
assert ep.get('version')=='ENTRY_V18_TRUTH_GUARD_MAX_PROFIT',ep
assert ep.get('quota_enforced') is False and ep.get('max_daily')==2,ep
assert ep.get('fid9081_policy')=='MISSING_OR_UNKNOWN=>UNKNOWN_FAIL_CLOSED',ep
assert '0B/0w/0D' in ep.get('ws_contract_probe',''),ep
assert '0w' in ep.get('program_realtime','') and 'ka90004' in ep.get('program_realtime',''),ep
assert 'NXT-ONLY' in ep.get('nxt_after_radar',''),ep
assert 'prospective RECOVERY_EARLY(WATCH_ONLY)' in ep.get('nxt_second_wave',''),ep
assert '19:30-19:50 sustained NXT-only strength' in ep.get('nxt_next_day_close_picks',''),ep
assert 'NXT_RECOVERY_RECLAIM' in (ep.get('routes') or []),ep
assert 'BUY-PROHIBITED' in ep.get('nxt_alert_push',''),ep
pc=ep.get('nxt_prospective_catch') or {}
assert float(pc.get('ready_percentile') or 0)==99,pc
assert int(pc.get('ready_min_population') or 0)==20,pc
assert int(pc.get('top1_min_population') or 0)==100,pc
assert pc.get('buy_policy')=='FAST_JUMP_WATCH_READY_NEVER_BUY_DIRECT',pc
assert pc.get('top1_status')=='UNPROVEN_UNTIL_SUFFICIENT_OOS',pc
mp=ep.get('manual_position_manager') or {}
assert mp.get('pricing')=='USER_ACTUAL_ENTRY/EXIT + VENUE_LOCKED_KRX_NXT',mp
assert (mp.get('SWING') or {}).get('ELITE',{}).get('runner_pct')==65.0,mp
assert (mp.get('CLOSE_BET') or {}).get('ELITE',{}).get('runner_pct')==65.0,mp
ct=h.get('ws_contract') or {}
assert ct.get('trade_type')=='0B' and ct.get('program_type')=='0w' and ct.get('orderbook_type')=='0D',ct
assert ct.get('source')=='OFFICIAL_FIXED_CONTRACT',ct
pg=h.get('performance_guard') or {}
assert (pg.get('scoring') or {}).get('mode')=='DIRTY_COALESCED',pg
cc=h.get('candidate_cap') or {}; assert int(cc.get('limit') or 0)==1200,cc
lp=h.get('lock_policy') or {}; assert lp.get('mode')=='STRUCTURAL_ONLY',lp
assert (h.get('evidence') or {}).get('version')=='EVIDENCE_ENGINE_V2_PROSPECTIVE',h.get('evidence')
assert (h.get('replay') or {}).get('version')=='REPLAY_JOURNAL_V1',h.get('replay')
assert (h.get('archive') or {}).get('version')=='DAILY_GZIP_ARCHIVE_V1',h.get('archive')
files=h.get('data_files') or {}
for k in ('buy_signals','exit_positions','nxt_alerts','nxt_second_wave','nxt_next_day_picks','nxt_daily_strong_ledger','manual_positions','evidence_report','replay_journal_today','prospective_observations'):
    assert k in files,(k,files)
na=h.get('nxt_after') or {}
assert 'fast_jump_watch' in na and 'top1_target_count' in na,na
print('HEALTH=OK version='+h['version']+' contract='+ct.get('trade_type','?')+'/'+ct.get('program_type','?')+'/'+ct.get('orderbook_type','?')+' TOP1='+pc.get('top1_status','?'))
PYH

curl -fsS --max-time 5 http://127.0.0.1:${HOST_PORT}/api/nova | python3 -c 'import sys,json;j=json.load(sys.stdin); assert j.get("version")=="NOVA-2.4.8"; print("NOVA_API=OK rows=",len(j.get("rows") or []))'
curl -fsS --max-time 5 http://127.0.0.1:${HOST_PORT}/api/ws-contract | python3 -c 'import sys,json;j=json.load(sys.stdin); assert j.get("version")=="NOVA-2.4.8"; c=j.get("contract") or {}; assert c.get("trade_type")=="0B" and c.get("program_type")=="0w" and c.get("orderbook_type")=="0D"; print("WS_CONTRACT_API=OK",c)'
curl -fsS --max-time 5 http://127.0.0.1:${HOST_PORT}/api/nxt-signal-table | python3 -c 'import sys,json;j=json.load(sys.stdin); assert j.get("version")=="NOVA-2.4.8" and "rows" in j; print("NXT_SIGNAL_TABLE_API=OK rows=",len(j.get("rows") or []))'
curl -fsS --max-time 5 http://127.0.0.1:${HOST_PORT}/api/close-picks | python3 -c 'import sys,json;j=json.load(sys.stdin); assert j.get("version")=="NOVA-2.4.8" and "visible" in j; print("CLOSE_PICKS_API=OK visible=",j.get("visible"),"count=",j.get("count"))'
curl -fsS --max-time 5 http://127.0.0.1:${HOST_PORT}/api/position-manager | python3 -c 'import sys,json;j=json.load(sys.stdin); assert j.get("version")=="NOVA-2.4.8"; p=j.get("plans") or {}; assert p.get("SWING",{}).get("ELITE",{}).get("runner_pct")==65.0; print("POSITION_MANAGER_API=OK open=",j.get("open_count"))'
curl -fsS --max-time 5 http://127.0.0.1:${HOST_PORT}/api/exit-dna | python3 -c 'import sys,json;j=json.load(sys.stdin); assert j.get("version")=="NOVA-2.4.8"; print("EXIT_DNA_API=OK")'
curl -fsS --max-time 5 http://127.0.0.1:${HOST_PORT}/api/nxt-alerts | python3 -c 'import sys,json;j=json.load(sys.stdin); assert j.get("version")=="NOVA-2.4.8"; print("NXT_ALERT_API=OK count=",j.get("count"))'

curl -fsS --max-time 8 http://127.0.0.1:${HOST_PORT}/api/evidence | python3 -c 'import sys,json;j=json.load(sys.stdin); assert j.get("ok") is True and j.get("version")=="NOVA-2.4.8"; r=j.get("report") or {}; assert r.get("version")=="EVIDENCE_ENGINE_V2_PROSPECTIVE"; t=((r.get("prospective") or {}).get("top1_target_audit") or {}); assert int(t.get("min_oos_samples") or 300)==300; assert t.get("top1_target_precision_pct") is None or int(t.get("samples") or 0)>=300; print("EVIDENCE_API=OK TOP1_STATUS=",t.get("status"))'
curl -fsS --max-time 5 http://127.0.0.1:${HOST_PORT}/api/backtest/status | python3 -c 'import sys,json;j=json.load(sys.stdin); assert j.get("ok") is True and j.get("version")=="NOVA-2.4.8" and j.get("auto_apply") is False; assert "observation" in j.get("command",""); print("BACKTEST_STATUS_API=OK auto_apply=",j.get("auto_apply"))'

say "7/7 완료"
if [[ $OLD_RENAMED -eq 1 ]]; then sudo docker rm -f "$BACKUP" >/dev/null 2>&1 || true; OLD_RENAMED=0; fi
trap - ERR
sudo docker image prune -f >/dev/null 2>&1 || true
echo "=== QUANT NOVA 2.4.8 PROSPECTIVE TOP1 CATCH + ANTI-HINDSIGHT ==="
echo "IMAGE=$IMAGE"
echo "CONTAINER=$CONTAINER"
echo "STATUS=$(sudo docker inspect "$CONTAINER" --format '{{.State.Status}}')"
echo "KEY_SECRET=PRESERVED"
echo "DATA_DIR=$APP_DIR/data"
echo "PUBLIC_URL=https://3-38-25-20.nip.io"
curl -s http://127.0.0.1:${HOST_PORT}/api/health | python3 -c 'import sys,json;h=json.load(sys.stdin);ct=h.get("ws_contract") or {};print("version=",h.get("version"));print("feed=",(h.get("feed") or {}).get("state"));print("contract=",ct.get("trade_type"),ct.get("program_type"),ct.get("orderbook_type"),ct.get("source"));print("nxt_after=",h.get("nxt_after"));print("push=",h.get("push"))'
