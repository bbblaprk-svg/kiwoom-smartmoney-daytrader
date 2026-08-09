#!/usr/bin/env bash
set -Eeuo pipefail

REPO_URL="https://github.com/bbblaprk-svg/kiwoom-smartmoney-daytrader.git"
ZIP_NAME="QUANT_NOVA_2.4.16_ALERT_TOGGLE_SAFE_FINAL.zip"
ROOT_NAME="nova2416"
EXPECTED_ZIP_SHA256="f05eb2a8d74b9ec76cfaaa84493520171e4c927495618a8aa8f035b7f373c3fc"
APP_DIR="$HOME/quant-nova"
IMAGE="quant-nova:2.4.16"
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
  echo "[자동복구] NOVA 2.4.16 적용 실패 — 이전 NOVA 복구" >&2
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
# Source repository privacy and runtime API protection are separate. Generate a write-only API token if absent.
ACCESS_TOKEN_CREATED=0
ACCESS_TOKEN_VALUE="$(sed -n 's/^APP_ACCESS_TOKEN=//p' "$APP_DIR/.env" | tail -n1)"
if [[ -z "$ACCESS_TOKEN_VALUE" ]]; then
  command -v python3 >/dev/null 2>&1 || fail "APP_ACCESS_TOKEN 생성에 python3 필요"
  ACCESS_TOKEN_VALUE="$(python3 -c 'import secrets; print(secrets.token_urlsafe(32))')"
  printf '\nAPP_ACCESS_TOKEN=%s\n' "$ACCESS_TOKEN_VALUE" >> "$APP_DIR/.env"
  chmod 600 "$APP_DIR/.env"
  ACCESS_TOKEN_CREATED=1
fi
echo "KEY_SECRET=OK (values hidden)"
echo "WRITE_API_GUARD=ENABLED (token value hidden)"
echo "DATA_DIR=$APP_DIR/data"

say "2/7 NOVA 2.4.16 파일 받기 + SHA/manifest 검증"
for c in git unzip python3 node curl docker sha256sum; do command -v "$c" >/dev/null 2>&1 || fail "필수 명령 없음: $c"; done
if [[ -n "${GITHUB_TOKEN:-}" ]]; then
  git -c http.extraHeader="Authorization: Bearer ${GITHUB_TOKEN}" clone --depth 1 "$REPO_URL" "$TMP/repo" >/dev/null
else
  git clone --depth 1 "$REPO_URL" "$TMP/repo" >/dev/null
fi
[[ -f "$TMP/repo/$ZIP_NAME" ]] || fail "GitHub 최상위에 $ZIP_NAME 파일이 없습니다."
ACTUAL_SHA="$(sha256sum "$TMP/repo/$ZIP_NAME" | awk '{print $1}')"
[[ "$ACTUAL_SHA" == "$EXPECTED_ZIP_SHA256" ]] || fail "ZIP SHA256 불일치: 예상=$EXPECTED_ZIP_SHA256 실제=$ACTUAL_SHA"
unzip -q "$TMP/repo/$ZIP_NAME" -d "$TMP/src"
ROOT="$TMP/src/$ROOT_NAME"
[[ -f "$ROOT/Dockerfile" && -f "$ROOT/app/main.py" && -f "$ROOT/app/evidence_engine.py" && -f "$ROOT/app/archive_engine.py" && -f "$ROOT/app/shadow_engine.py" && -f "$ROOT/config/live_parity_2.4.13.json" && -f "$ROOT/static/nova.js" && -f "$ROOT/config/krx_holidays.json" && -f "$ROOT/scripts/replay_backtest.py" && -f "$ROOT/scripts/selfcheck.py" && -f "$ROOT/SOURCE_MANIFEST.sha256" ]] || fail "ZIP 내부 구조 오류"
(cd "$ROOT" && sha256sum -c SOURCE_MANIFEST.sha256 >/dev/null) || fail "SOURCE_MANIFEST 무결성 검사 실패"

say "3/7 정적 사전검증 — full selfcheck는 Docker 내부에서 requirements 설치 후 실행"
python3 -m py_compile "$ROOT/app/main.py" "$ROOT/app/evidence_engine.py" "$ROOT/app/archive_engine.py" "$ROOT/app/shadow_engine.py" "$ROOT/scripts/replay_backtest.py" "$ROOT/scripts/selfcheck.py"
# Host preflight intentionally avoids importing app dependencies.
# Full selfcheck runs inside Docker after requirements.txt is installed.
node --check "$ROOT/static/nova.js"
grep -Fq "APP_VERSION='NOVA-2.4.16'" "$ROOT/app/main.py" || fail "버전 동기화 누락"
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
grep -Fq "NXT_RECOVERY_MAX_PEAK_AGE_SECONDS" "$ROOT/app/main.py" || fail "whole-day recovery horizon 누락"
grep -Fq "NXT_SECOND_WAVE_MEMORY_SECONDS=max(3600,int(os.getenv('NOVA_NXT_SECOND_WAVE_MEMORY_SECONDS','43200')))" "$ROOT/app/main.py" || fail "12시간 first-wave memory default 누락"
grep -Fq "NXT_MEMORY_BAR_KEEP_MINUTES=max(300,min(780,int(os.getenv('NOVA_NXT_MEMORY_BAR_KEEP_MINUTES','720'))))" "$ROOT/app/main.py" || fail "12시간 minute-bar anchor 누락"
grep -Fq "NXT_RECOVERY_MAX_PEAK_AGE_SECONDS=max(NXT_RECOVERY_MIN_PEAK_AGE_SECONDS+600,int(os.getenv('NOVA_NXT_RECOVERY_MAX_PEAK_AGE_SECONDS','43200')))" "$ROOT/app/main.py" || fail "whole-day recovery max-age 누락"
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
grep -Fq "def _shadow_observe_candidate" "$ROOT/app/main.py" || fail "Shadow observation bridge 누락"
grep -Fq "SHADOW_SCORE_V2_DEDUP_GROUP_CAP_ADAPTIVE_LOAD_SHED_OBSERVE_ONLY" "$ROOT/app/shadow_engine.py" || fail "De-duplicated Shadow Score 누락"
grep -Fq "auto_apply':False" "$ROOT/app/shadow_engine.py" || fail "Shadow auto-apply 차단 누락"
grep -Fq "shadow_leave_one_out" "$ROOT/app/main.py" || fail "Leave-one-feature-out replay ledger 누락"
grep -Fq "mutation_violations" "$ROOT/app/main.py" || fail "Shadow protected-state mutation guard 누락"
grep -Fq "shadow_oos" "$ROOT/app/evidence_engine.py" || fail "LIVE-vs-Shadow OOS Evidence 연결 누락"
grep -Fq "live_parity_2.4.13.json" "$ROOT/scripts/selfcheck.py" || fail "2.4.13 LIVE parity baseline guard 누락"
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
grep -Fq "PROSPECTIVE EVIDENCE TRUTH + SHADOW VALIDATION · 2.4.16" "$ROOT/static/index.html" || fail "2.4.16 Shadow Evidence UI 동기화 누락"
grep -Fq "LAST MARKET SNAPSHOT" "$ROOT/static/nova.js" || fail "Last Market Snapshot UI 누락"
grep -Fq "serverRuntimeAwake" "$ROOT/static/nova.js" || fail "서버 캘린더 기반 프런트 runtime 누락"
grep -Fq "/api/screen-state" "$ROOT/static/nova.js" || fail "screen-state 저빈도 probe 누락"
grep -Fq "EOD_SCREEN_SNAPSHOT_FILE" "$ROOT/app/main.py" || fail "EOD screen snapshot 파일 누락"
grep -Fq "def display_trading_day" "$ROOT/app/main.py" || fail "실제 거래일 display-day 정책 누락"
grep -Fq "def screen_hold_active" "$ROOT/app/main.py" || fail "주말/휴일 last-screen hold 누락"
grep -Fq "async def eod_screen_snapshot_loop" "$ROOT/app/main.py" || fail "20:00~20:05 EOD snapshot loop 누락"
grep -Fq "LAST_COMPLETED_TRADING_DAY_UNTIL_NEXT_TRADING_DAY_07:30_KST" "$ROOT/app/main.py" || fail "익일 실제 거래일 07:30 hold 정책 누락"
grep -Fq "@app.get('/api/screen-state')" "$ROOT/app/main.py" || fail "screen-state API 누락"
grep -Fq "09:00:30~15:20" "$ROOT/static/index.html" || fail "NXT 동시시장 09:00:30 UI 누락"
grep -Fq "확정 BUY 경로(PULLBACK·DIRECT·DNA EARLY·NXT EMERGENCY·SECOND WAVE·RECOVERY)" "$ROOT/static/index.html" || fail "BUY 경로 UI 설명 동기화 누락"
grep -Fq "def capture_krx_close_context" "$ROOT/app/main.py" || fail "KRX 종가수급 동결 캡처 누락"
grep -Fq "def build_close_smart_money_matrix" "$ROOT/app/main.py" || fail "KRX×NXT 스마트머니 종가매트릭스 누락"
grep -Fq "@app.get('/api/close-smart-money')" "$ROOT/app/main.py" || fail "close smart-money API 누락"
grep -Fq "SMART_MONEY_CLOSE" "$ROOT/app/main.py" || fail "19:50 스마트머니 요약 Push 누락"
grep -Fq "SMART MONEY CROSS-VENUE · 2.4.16" "$ROOT/static/index.html" || fail "2.4.16 스마트머니 TOP10 UI 누락"
grep -Fq "WATCH_ONLY_NO_AUTO_BUY" "$ROOT/app/main.py" || fail "스마트머니 매트릭스 자동BUY 차단 누락"
grep -Fq "KRX_ONLY_NO_NXT_FALLBACK_BOUNDED_SAMPLER" "$ROOT/app/main.py" || fail "KRX/NXT venue fallback 차단 누락"
grep -Fq "SMART_CLOSE_UNIVERSE_START_SECONDS=19*3600+15*60" "$ROOT/app/main.py" || fail "19:15 CLOSE 확대유니버스 시작 누락"
grep -Fq "SMART_CLOSE_UNIVERSE_END_SECONDS=19*3600+25*60" "$ROOT/app/main.py" || fail "19:25 CLOSE 확대유니버스 종료 누락"
grep -Fq "async def refresh_close_observation_universe" "$ROOT/app/main.py" || fail "CLOSE 확대유니버스 함수 누락"
grep -Fq "async def backfill_krx_close_context" "$ROOT/app/main.py" || fail "19:15 신규종목 KRX 종가수급 backfill 누락"
grep -Fq "KRX_ONLY_KA90004_KA10059_NO_AMBIGUOUS_PRICE_FALLBACK" "$ROOT/app/main.py" || fail "KRX-only backfill venue truth guard 누락"
grep -Fq "SMART_CLOSE_KRX_BACKFILL_MAX_CODES" "$ROOT/app/main.py" || fail "KRX close backfill bounded cap 누락"
grep -Fq '"2027"' "$ROOT/config/krx_holidays.json" || fail "2027 KRX 캘린더 누락"
grep -Fq '"2028"' "$ROOT/config/krx_holidays.json" || fail "2028 KRX 캘린더 누락"
grep -Fq '"2029"' "$ROOT/config/krx_holidays.json" || fail "2029 KRX 캘린더 누락"
grep -Fq '"2030"' "$ROOT/config/krx_holidays.json" || fail "2030 KRX 캘린더 누락"
grep -Fq "nxt_program_delta_1m" "$ROOT/app/main.py" || fail "NXT 프로그램 1분 delta 누락"
grep -Fq "nxt_program_delta_3m" "$ROOT/app/main.py" || fail "NXT 프로그램 3분 delta 누락"
grep -Fq "nxt_program_delta_5m" "$ROOT/app/main.py" || fail "NXT 프로그램 5분 delta 누락"
grep -Fq "FLOW_REVERSAL" "$ROOT/app/main.py" || fail "NXT 최근 수급반전 guard 누락"
grep -Fq "eligible_count" "$ROOT/app/main.py" || fail "전체 적격후보 sector breadth 누락"
grep -Fq "if not c:continue" "$ROOT/app/main.py" || fail "프리마켓 candidate null guard 누락"
grep -Fq "APP_ACCESS_TOKEN" "$ROOT/app/main.py" || fail "runtime write API token guard 누락"
grep -Fq "@app.get('/api/auth/check')" "$ROOT/app/main.py" || fail "auth check API 누락"
grep -Fq "if(!j.auth_required)return ''" "$ROOT/static/nova.js" || fail "auth_required 확인 후 prompt guard 누락"
grep -Fq "async function disableNotifications()" "$ROOT/static/nova.js" || fail "알림 OFF 함수 누락"
grep -Fq "async function toggleNotifications()" "$ROOT/static/nova.js" || fail "알림 ON/OFF 토글 함수 누락"
grep -Fq "/api/push/unsubscribe" "$ROOT/static/nova.js" || fail "Push unsubscribe 연결 누락"
grep -Fq "addEventListener('click',toggleNotifications)" "$ROOT/static/nova.js" || fail "알림 버튼 토글 연결 누락"
grep -Fq "alertDeliveryEnabled()" "$ROOT/static/nova.js" || fail "앱내 알림 OFF guard 누락"
grep -Fq "신호기록 유지 · 알림 OFF" "$ROOT/static/index.html" || fail "알림 OFF UI 설명 누락"
grep -Fq "PROSPECTIVE_OUTCOME_FILE" "$ROOT/app/main.py" || fail "prospective fixed-horizon outcome 원장 누락"
grep -Fq "async def prospective_followup_loop" "$ROOT/app/main.py" || fail "5/15/30분 강제 follow-up loop 누락"
grep -Fq "SPARE_ONLY_NO_LIVE_SLOT_STEAL" "$ROOT/app/main.py" || fail "Evidence follow-up WS spare-only 정책 누락"
grep -Fq "async def run_nxt_market_top1_audit" "$ROOT/app/main.py" || fail "시장 전체 TOP1 recall audit 누락"
grep -Fq "ka10099" "$ROOT/app/main.py" || fail "NXT 가능종목 모집단 census 누락"
grep -Fq "ka10027" "$ROOT/app/main.py" || fail "NXT 시장 TOP1 ranking audit 누락"
grep -Fq "def archive_seal_readiness" "$ROOT/app/main.py" || fail "EOD archive readiness gate 누락"
grep -Fq "PROSPECTIVE_FOLLOWUP" "$ROOT/app/main.py" || fail "archive prospective follow-up readiness 누락"
grep -Fq "MARKET_TOP1_AUDIT" "$ROOT/app/main.py" || fail "archive market audit readiness 누락"
grep -Fq "resolved_positive=['거래정지 해제'" "$ROOT/app/main.py" || fail "Event Guard 해제문맥 override 누락"
grep -Fq "for page_no in range(1,6)" "$ROOT/app/main.py" || fail "DART pagination 5-page guard 누락"
grep -Fq "EVIDENCE_ENGINE_V3_HORIZON_COVERAGE" "$ROOT/app/evidence_engine.py" || fail "Evidence V3 누락"
grep -Fq "prospective_outcomes.jsonl" "$ROOT/app/archive_engine.py" || fail "prospective outcomes archive 누락"
grep -Fq "nxt_market_top1_audit.json" "$ROOT/app/archive_engine.py" || fail "market TOP1 audit archive 누락"
grep -Fq "OFFLINE_REPLAY_BACKTEST_V2_FIXED_HORIZON" "$ROOT/scripts/replay_backtest.py" || fail "fixed-horizon observation backtest 누락"
python3 - "$ROOT/BUILD_INFO.json" <<'PYBI'
import json,sys
b=json.load(open(sys.argv[1]))
assert b.get('version')=='NOVA-2.4.16',b
for k in ('fast_jump','recovery_early','prospective_audit','top1_target','top1_oos_gate','evidence_engine','offline_backtest','buy_policy','whole_day_recovery','archive','event_guard','last_screen_hold','rollover_policy','frontend_runtime','smart_money_close_matrix','cross_venue_policy','close_universe','premarket_guard','runtime_write_guard','krx_close_backfill','trading_calendar','shadow_score','parity_guard','alert_toggle'):
    assert b.get(k),(k,b)
assert 'FROZEN_FROM_2.4.8' in b.get('buy_policy',''),b
assert 'shadow' in b.get('release_focus','').lower(),b
assert 'live' in b.get('release_focus','').lower(),b
assert '2030' in b.get('trading_calendar',''),b
assert '12h' in b.get('whole_day_recovery',''),b
assert '07:30' in b.get('last_screen_hold',''),b
assert '07:30' in b.get('rollover_policy',''),b
assert 'server-calendar' in b.get('frontend_runtime',''),b
print('BUILD_INFO=OK')
PYBI

grep -Fq "def _shadow_load_mode" "$ROOT/app/main.py" || fail "Adaptive Shadow Load Shed 누락"
grep -Fq "SHADOW_SHED_P95_HIGH_MS" "$ROOT/app/main.py" || fail "Shadow p95 load threshold 누락"
grep -Fq "SHADOW_SHED_DIRTY_HIGH" "$ROOT/app/main.py" || fail "Shadow dirty-queue threshold 누락"
grep -Fq "SHADOW_REDUCED_LOO_FEATURES" "$ROOT/app/main.py" || fail "Shadow reduced LOO set 누락"
grep -Fq "load_mode='FULL'" "$ROOT/app/shadow_engine.py" || fail "Shadow load-mode pure API 누락"
grep -Fq "LIVE BUY/EXIT/scoring logic is untouched" "$ROOT/app/main.py" || fail "LIVE-first load-shed contract 누락"

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
  -e NOVA_SMART_CLOSE_KRX_BACKFILL_MAX_CODES=80 \
  -e NOVA_SMART_CLOSE_KRX_BACKFILL_RETRY_SECONDS=180 \
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
  -e NOVA_NXT_SECOND_WAVE_MEMORY_SECONDS=43200 \
  -e NOVA_NXT_SECOND_WAVE_POOL_LIMIT=20 \
  -e NOVA_NXT_MEMORY_BAR_KEEP_MINUTES=720 \
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
  -e NOVA_NXT_RECOVERY_MAX_PEAK_AGE_SECONDS=43200 \
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
  -e NOVA_SMART_CLOSE_UNIVERSE_REFRESH_SECONDS=120 \
  -e NOVA_SMART_CLOSE_UNIVERSE_MAX_ROWS=160 \
  -e NOVA_SMART_CLOSE_FLOW_HISTORY_SECONDS=600 \
  -e NOVA_NXT_CLOSE_PICK_LIMIT=12 \
  -e NOVA_NXT_CLOSE_PICK_MIN_SCORE=52 \
  -e NOVA_NXT_CLOSE_BET_READY_SCORE=64 \
  -e NOVA_NXT_CLOSE_BET_BUY_SCORE=74 \
  -e NOVA_NXT_CLOSE_BET_LIMIT=5 \
  -e NOVA_SMART_CLOSE_TOP_LIMIT=10 \
  -e NOVA_SMART_CLOSE_SECTOR_LIMIT=5 \
  -e NOVA_SMART_CLOSE_MIN_SCORE=48 \
  -e NOVA_SMART_CLOSE_NXT_FRESH_SECONDS=12 \
  -e NOVA_SMART_CLOSE_KRX_TICK_MAX_AGE_SECONDS=150 \
  -e NOVA_SMART_CLOSE_KRX_CAPTURE_LEAD_SECONDS=600 \
  -e NOVA_SMART_CLOSE_KRX_CAPTURE_LAG_SECONDS=300 \
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
  -e NOVA_PROSPECTIVE_FOLLOWUP_GRACE_SECONDS=120 \
  -e NOVA_PROSPECTIVE_FOLLOWUP_MAX=400 \
  -e NOVA_PROSPECTIVE_FOLLOWUP_WS_LIMIT=20 \
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


say "6/7 Health + Last-Screen/Holiday + Prospective/TOP1/Evidence + 기존 live engine 검증"
HEALTH=""
for _ in $(seq 1 60); do
  HEALTH="$(curl -fsS --max-time 3 http://127.0.0.1:${HOST_PORT}/api/health 2>/dev/null || true)"
  [[ -n "$HEALTH" ]] && break
  sleep 2
done
[[ -n "$HEALTH" ]] || { sudo docker logs --tail 300 "$CONTAINER" || true; fail "NOVA 2.4.16 health 실패"; }
printf '%s' "$HEALTH" > "$TMP/health.json"
python3 - "$TMP/health.json" <<'PYH'
import json,sys
h=json.load(open(sys.argv[1]))
assert h.get('ok') is True,h
assert h.get('version')=='NOVA-2.4.16',h.get('version')
csm=h.get('close_smart_money') or {}
policy=str(csm.get('policy') or '')
assert policy.startswith('WATCH_ONLY_NO_AUTO_BUY'),csm
# Session-aware CLOSE matrix validation: on weekends/holidays an empty matrix is expected,
# while on trading days we only require structural integrity outside the actual 19:30-19:50 window.
cal=h.get('calendar') or {}
feed=h.get('feed') or {}
sess=feed.get('session') or {}
trading_day=bool(cal.get('trading_day',sess.get('trading_day')))
for k in ('eligible_count','count','sector_count','dual_confirmed_count','flow_reversal_count'):
    assert int(csm.get(k) or 0) >= 0,(k,csm)
assert isinstance(csm.get('universe_refresh') or {},dict),csm
if not trading_day:
    assert int(csm.get('eligible_count') or 0)==0,csm
    assert int(csm.get('count') or 0)==0,csm
    assert int(csm.get('sector_count') or 0)==0,csm
    assert int(csm.get('dual_confirmed_count') or 0)==0,csm
    assert int(csm.get('flow_reversal_count') or 0)==0,csm
    assert csm.get('generated_at') in (None,''),csm
    assert feed.get('state')=='MARKET_CLOSED',feed
ep=h.get('entry_policy') or {}
assert ep.get('version')=='ENTRY_V18_TRUTH_GUARD_MAX_PROFIT',ep
assert ep.get('quota_enforced') is False and ep.get('max_daily')==2,ep
assert ep.get('fid9081_policy')=='MISSING_OR_UNKNOWN=>UNKNOWN_FAIL_CLOSED',ep
assert '0B/0w/0D' in ep.get('ws_contract_probe',''),ep
assert 'LAST_SCREEN_HELD_UNTIL_NEXT_REAL_TRADING_DAY_07:30' in ep.get('trading_calendar',''),ep
assert '0w' in ep.get('program_realtime','') and 'ka90004' in ep.get('program_realtime',''),ep
assert 'NXT-ONLY' in ep.get('nxt_after_radar',''),ep
assert 'WHOLE-DAY' in ep.get('nxt_second_wave','') and 'BUY thresholds unchanged' in ep.get('nxt_second_wave',''),ep
assert '19:30-19:50 sustained NXT-only strength' in ep.get('nxt_next_day_close_picks',''),ep
assert 'NXT_RECOVERY_RECLAIM' in (ep.get('routes') or []),ep
assert 'BUY-PROHIBITED' in ep.get('nxt_alert_push',''),ep
pc=ep.get('nxt_prospective_catch') or {}
assert float(pc.get('ready_percentile') or 0)==99,pc
assert int(pc.get('top1_min_population') or 0)==100,pc
assert pc.get('buy_policy')=='FAST_JUMP_WATCH_READY_NEVER_BUY_DIRECT',pc
assert pc.get('top1_status')=='UNPROVEN_UNTIL_SUFFICIENT_OOS',pc
ct=h.get('ws_contract') or {}
assert ct.get('trade_type')=='0B' and ct.get('program_type')=='0w' and ct.get('orderbook_type')=='0D',ct
assert ct.get('source')=='OFFICIAL_FIXED_CONTRACT',ct
pg=h.get('performance_guard') or {}
assert (pg.get('scoring') or {}).get('mode')=='DIRTY_COALESCED',pg
cc=h.get('candidate_cap') or {}; assert int(cc.get('limit') or 0)==1200,cc
lp=h.get('lock_policy') or {}; assert lp.get('mode')=='STRUCTURAL_ONLY',lp
assert (h.get('evidence') or {}).get('version')=='EVIDENCE_ENGINE_V3_HORIZON_COVERAGE',h.get('evidence')
assert (h.get('replay') or {}).get('version')=='REPLAY_JOURNAL_V2_FORCED_FOLLOWUP',h.get('replay')
assert (h.get('archive') or {}).get('version')=='DAILY_GZIP_ARCHIVE_V2_READINESS_SEAL',h.get('archive')
assert 'version' in (h.get('prospective_followup') or {}),h.get('prospective_followup')
assert isinstance(h.get('market_top1_audit'),dict),h.get('market_top1_audit')
files=h.get('data_files') or {}
for k in ('buy_signals','exit_positions','nxt_alerts','nxt_second_wave','nxt_next_day_picks','nxt_daily_strong_ledger','manual_positions','evidence_report','replay_journal_today','prospective_observations','prospective_outcomes','nxt_market_top1_audit','eod_screen_snapshot'):
    assert k in files,(k,files)
print('HEALTH=OK version='+h['version']+' contract='+ct.get('trade_type','?')+'/'+ct.get('program_type','?')+'/'+ct.get('orderbook_type','?')+' evidence='+(h.get('evidence') or {}).get('version','?')+' trading_day='+str(trading_day)+' close_count='+str(csm.get('count',0)))
PYH

curl -fsS --max-time 5 http://127.0.0.1:${HOST_PORT}/api/nova | python3 -c 'import sys,json;j=json.load(sys.stdin); assert j.get("version")=="NOVA-2.4.16"; print("NOVA_API=OK rows=",len(j.get("rows") or []))'
curl -fsS --max-time 5 http://127.0.0.1:${HOST_PORT}/api/screen-state | python3 -c 'import sys,json;j=json.load(sys.stdin); assert j.get("version")=="NOVA-2.4.16"; assert "runtime_awake" in j and "screen_hold" in j; h=j.get("screen_hold") or {}; assert "07:30" in str(h.get("policy") or ""); print("SCREEN_STATE_API=OK awake=",j.get("runtime_awake")," hold=",h.get("active")," display_day=",j.get("display_day"))'
curl -fsS --max-time 5 http://127.0.0.1:${HOST_PORT}/api/ws-contract | python3 -c 'import sys,json;j=json.load(sys.stdin); assert j.get("version")=="NOVA-2.4.16"; c=j.get("contract") or {}; assert c.get("trade_type")=="0B" and c.get("program_type")=="0w" and c.get("orderbook_type")=="0D"; print("WS_CONTRACT_API=OK",c)'
curl -fsS --max-time 5 http://127.0.0.1:${HOST_PORT}/api/nxt-signal-table | python3 -c 'import sys,json;j=json.load(sys.stdin); assert j.get("version")=="NOVA-2.4.16" and "rows" in j; print("NXT_SIGNAL_TABLE_API=OK rows=",len(j.get("rows") or []))'
curl -fsS --max-time 5 http://127.0.0.1:${HOST_PORT}/api/close-picks | python3 -c 'import sys,json;j=json.load(sys.stdin); assert j.get("version")=="NOVA-2.4.16" and "visible" in j; print("CLOSE_PICKS_API=OK visible=",j.get("visible"),"count=",j.get("count"))'
curl -fsS --max-time 5 http://127.0.0.1:${HOST_PORT}/api/close-smart-money | python3 -c 'import sys,json;j=json.load(sys.stdin); assert j.get("version")=="NOVA-2.4.16" and "rows" in j and "sectors" in j; print("CLOSE_SMART_MONEY_API=OK visible=",j.get("visible"),"count=",j.get("count"),"dual=",j.get("dual_confirmed_count"))'
curl -fsS --max-time 5 http://127.0.0.1:${HOST_PORT}/api/position-manager | python3 -c 'import sys,json;j=json.load(sys.stdin); assert j.get("version")=="NOVA-2.4.16"; p=j.get("plans") or {}; assert p.get("SWING",{}).get("ELITE",{}).get("runner_pct")==65.0; print("POSITION_MANAGER_API=OK open=",j.get("open_count"))'
curl -fsS --max-time 5 http://127.0.0.1:${HOST_PORT}/api/exit-dna | python3 -c 'import sys,json;j=json.load(sys.stdin); assert j.get("version")=="NOVA-2.4.16"; print("EXIT_DNA_API=OK")'
curl -fsS --max-time 5 http://127.0.0.1:${HOST_PORT}/api/nxt-alerts | python3 -c 'import sys,json;j=json.load(sys.stdin); assert j.get("version")=="NOVA-2.4.16"; print("NXT_ALERT_API=OK count=",j.get("count"))'

# evidence_report.json is a derived cache and may have been written by an older NOVA version.
# Rebuild only this derived report from preserved source ledgers before asserting the 2.4.16 schema.
sudo docker exec "$CONTAINER" python -c 'from pathlib import Path; from app.evidence_engine import write_report; r=write_report(Path("/app/data"),Path("/app/data/evidence_report.json")); assert r.get("version")=="EVIDENCE_ENGINE_V3_HORIZON_COVERAGE"; assert (r.get("shadow_oos") or {}).get("auto_apply") is False; print("EVIDENCE_CACHE_REFRESH=OK version="+r.get("version"))'

curl -fsS --max-time 8 http://127.0.0.1:${HOST_PORT}/api/evidence | python3 -c 'import sys,json;j=json.load(sys.stdin); assert j.get("ok") is True and j.get("version")=="NOVA-2.4.16"; r=j.get("report") or {}; assert r.get("version")=="EVIDENCE_ENGINE_V3_HORIZON_COVERAGE"; p=r.get("prospective") or {}; assert "coverage" in p and "market_top1_audit" in p; sh=r.get("shadow_oos") or {}; assert sh.get("auto_apply") is False; t=p.get("top1_target_audit") or {}; assert int(t.get("min_oos_samples") or 300)==300; assert t.get("top1_target_precision_pct") is None or int(t.get("samples") or 0)>=300; print("EVIDENCE_API=OK 30M_COVERAGE=",(p.get("coverage") or {}).get("30m")," MARKET_TOP1=",(p.get("market_top1_audit") or {}).get("status"))'
curl -fsS --max-time 5 http://127.0.0.1:${HOST_PORT}/api/backtest/status | python3 -c 'import sys,json;j=json.load(sys.stdin); assert j.get("ok") is True and j.get("version")=="NOVA-2.4.16" and j.get("auto_apply") is False; assert "observation" in j.get("command",""); print("BACKTEST_STATUS_API=OK auto_apply=",j.get("auto_apply"))'

say "7/7 완료"
if [[ $OLD_RENAMED -eq 1 ]]; then sudo docker rm -f "$BACKUP" >/dev/null 2>&1 || true; OLD_RENAMED=0; fi
trap - ERR
sudo docker image prune -f >/dev/null 2>&1 || true
echo "=== QUANT NOVA 2.4.16 ALERT TOGGLE SAFE · LIVE FREEZE ==="
echo "IMAGE=$IMAGE"
echo "CONTAINER=$CONTAINER"
echo "STATUS=$(sudo docker inspect "$CONTAINER" --format '{{.State.Status}}')"
echo "KEY_SECRET=PRESERVED"
echo "WRITE_API_GUARD=ENABLED"
if [[ "$ACCESS_TOKEN_CREATED" -eq 1 ]]; then echo "APP_ACCESS_TOKEN=GENERATED (확인: grep ^APP_ACCESS_TOKEN= $APP_DIR/.env)"; else echo "APP_ACCESS_TOKEN=PRESERVED"; fi
echo "DATA_DIR=$APP_DIR/data"
echo "PUBLIC_URL=https://3-38-25-20.nip.io"
curl -s http://127.0.0.1:${HOST_PORT}/api/health | python3 -c 'import sys,json;h=json.load(sys.stdin);ct=h.get("ws_contract") or {};print("version=",h.get("version"));print("feed=",(h.get("feed") or {}).get("state"));print("contract=",ct.get("trade_type"),ct.get("program_type"),ct.get("orderbook_type"),ct.get("source"));print("nxt_after=",h.get("nxt_after"));print("push=",h.get("push"))'
