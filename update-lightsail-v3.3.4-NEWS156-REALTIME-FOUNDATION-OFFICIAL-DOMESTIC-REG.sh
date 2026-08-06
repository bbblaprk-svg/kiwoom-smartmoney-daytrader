#!/usr/bin/env bash
set -Eeuo pipefail

REPO_URL="https://github.com/bbblaprk-svg/kiwoom-smartmoney-daytrader.git"
ZIP_NAME="kiwoom-unified-edge-v3.3.4-NEWS156-REALTIME-FOUNDATION-OFFICIAL-DOMESTIC-REG.zip"
SOURCE_DIR_NAME="kiwoom-unified-edge-v3.3.4"
EXPECTED_ZIP_SHA256="361979bcf2a12dcd323f8e2d3595ba99f50f5818895d7676d4ae5de8b39f3c58"
OLD_APP_DIR="$HOME/kiwoom-smartmoney-daytrader"
NEW_APP_DIR="$HOME/kiwoom-unified-edge"
TRADER_IMAGE="kiwoom-unified:v3.3.4"
NEWS_IMAGE="kiwoom-news-radar:1.5.6-rotation"
APP_CONTAINER="kiwoom-app"
NEWS_CONTAINER="news-radar"
CADDY_CONTAINER="kiwoom-caddy"
DOCKER_NETWORK="kiwoom-net"
TRADER_DATA_VOLUME="kiwoom-data"
NEWS_DATA_VOLUME="news-radar-data"
TMP_ROOT="$(mktemp -d)"
STAMP="$(date +%Y%m%d%H%M%S)"
APP_BACKUP="${APP_CONTAINER}-backup-${STAMP}"
NEWS_BACKUP="${NEWS_CONTAINER}-backup-${STAMP}"
APP_OLD_RENAMED=0
NEWS_OLD_RENAMED=0
APP_NEW_STARTED=0
NEWS_NEW_STARTED=0

say(){ printf '\n==> %s\n' "$*"; }
fail(){ printf '\n[오류] %s\n' "$*" >&2; exit 1; }
cleanup(){ rm -rf "$TMP_ROOT"; }
rollback(){
  local ec=$?
  [[ $ec -eq 0 ]] && return
  printf '\n[자동복구] v3.3.4 OFFICIAL DOMESTIC REG 적용 실패 — 기존 컨테이너로 복구합니다.\n' >&2
  [[ $APP_NEW_STARTED -eq 1 ]] && sudo docker rm -f "$APP_CONTAINER" >/dev/null 2>&1 || true
  [[ $NEWS_NEW_STARTED -eq 1 ]] && sudo docker rm -f "$NEWS_CONTAINER" >/dev/null 2>&1 || true
  if [[ $APP_OLD_RENAMED -eq 1 ]]; then sudo docker rename "$APP_BACKUP" "$APP_CONTAINER" >/dev/null 2>&1 || true; sudo docker start "$APP_CONTAINER" >/dev/null 2>&1 || true; fi
  if [[ $NEWS_OLD_RENAMED -eq 1 ]]; then sudo docker rename "$NEWS_BACKUP" "$NEWS_CONTAINER" >/dev/null 2>&1 || true; sudo docker start "$NEWS_CONTAINER" >/dev/null 2>&1 || true; fi
  sudo docker restart "$CADDY_CONTAINER" >/dev/null 2>&1 || true
}
trap cleanup EXIT
trap rollback ERR

[[ "$(id -u)" -ne 0 ]] || fail "root가 아닌 ubuntu 사용자로 실행하세요."

say "필수 도구 확인"
sudo apt-get update -qq
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y git docker.io curl ca-certificates unzip openssl >/dev/null
sudo systemctl enable --now docker

say "디스크 여유 확인/오래된 빌드 캐시 정리"
df -h /
sudo docker builder prune -f --filter 'until=24h' >/dev/null 2>&1 || true
sudo docker image prune -f >/dev/null 2>&1 || true
sudo docker builder prune -af >/dev/null 2>&1 || true
sudo apt-get clean >/dev/null 2>&1 || true
AVAIL_KB="$(df -Pk / | awk 'NR==2{print $4}')"
[[ "${AVAIL_KB:-0}" -ge 3145728 ]] || fail "Docker/Next 빌드용 디스크 여유가 3GiB 미만입니다. 현재 여유: $(( ${AVAIL_KB:-0} / 1024 )) MiB"

ENV_SOURCE=""
if [[ -f "$NEW_APP_DIR/.env" ]]; then ENV_SOURCE="$NEW_APP_DIR/.env"
elif [[ -f "$OLD_APP_DIR/.env" ]]; then ENV_SOURCE="$OLD_APP_DIR/.env"
else fail "기존 앱 .env를 찾지 못했습니다."
fi
cp "$ENV_SOURCE" "$TMP_ROOT/trader.env"
chmod 600 "$TMP_ROOT/trader.env"

say "v3.3.4 REALTIME FOUNDATION + OFFICIAL DOMESTIC REG + News 1.5.6 파일 받기"
git clone --depth 1 "$REPO_URL" "$TMP_ROOT/repo" >/dev/null
cd "$TMP_ROOT/repo"
[[ -f "$ZIP_NAME" ]] || fail "GitHub 최상위에 $ZIP_NAME 파일이 없습니다."
ACTUAL_SHA="$(sha256sum "$ZIP_NAME" | awk '{print $1}')"
[[ "$ACTUAL_SHA" == "$EXPECTED_ZIP_SHA256" ]] || fail "ZIP SHA256 불일치: 예상=$EXPECTED_ZIP_SHA256 실제=$ACTUAL_SHA"

say "ZIP/manifest 무결성 검사"
unzip -q "$ZIP_NAME" -d "$TMP_ROOT/source"
ROOT="$TMP_ROOT/source/$SOURCE_DIR_NAME"
[[ -d "$ROOT/trader" && -d "$ROOT/news-radar" ]] || fail "ZIP 내부 구조 오류"
(cd "$ROOT" && sha256sum -c BUNDLE_MANIFEST.sha256 >/dev/null)
(cd "$ROOT/trader" && sha256sum -c SOURCE_MANIFEST.sha256 >/dev/null)
(cd "$ROOT/news-radar" && sha256sum -c SOURCE_MANIFEST.sha256 >/dev/null)

TRADER_VERSION="$(python3 - "$ROOT/trader/package.json" <<'PYVER'
import json,sys
print(json.load(open(sys.argv[1], encoding='utf-8')).get('version',''))
PYVER
)"
NEWS_VERSION="$(python3 - "$ROOT/news-radar/package.json" <<'PYVER'
import json,sys
print(json.load(open(sys.argv[1], encoding='utf-8')).get('version',''))
PYVER
)"
[[ "$TRADER_VERSION" == "3.3.4" ]] || fail "trader 버전 불일치: $TRADER_VERSION"
[[ "$NEWS_VERSION" == "1.5.6" ]] || fail "news 버전 불일치: $NEWS_VERSION"
grep -Fq "DOMESTIC_TRADE_0B" "$ROOT/trader/worker/kiwoomRealtime.js" || fail "키움 공식 bare 종목코드 0B REG 누락"
grep -Fq "KIWOOM_OFFICIAL_DOMESTIC_BARE_REG_V4" "$ROOT/trader/worker/kiwoomRealtime.js" || fail "v3.3.4 공식 국내 WebSocket 등록모드 누락"
! grep -Fq 'NXT_CORE_${code}_0B' "$ROOT/trader/worker/kiwoomRealtime.js" || fail "비공식 NXT suffix CORE REG 잔존"
! grep -Fq '`${code}_NX`' "$ROOT/trader/worker/kiwoomRealtime.js" || fail "REST 전용 _NX 코드가 WebSocket REG에 잔존"
! grep -Eq "stex_tp[[:space:]]*:" "$ROOT/trader/worker/kiwoomRealtime.js" || fail "미국주식용 stex_tp item-map 코드가 국내 WebSocket REG에 잔존"
! grep -Fq "NXT_SUFFIX" "$ROOT/trader/worker/kiwoomRealtime.js" || fail "NXT suffix ACK 계층 잔존"
! grep -Fq "startNxtProbeSocket" "$ROOT/trader/worker/kiwoomRealtime.js" || fail "구형 NXT 별도 probe socket 잔존"
grep -Fq "DUPLICATE_SKIPPED" "$ROOT/trader/worker/kiwoomRealtime.js" || fail "중복 0B 억제 누락"
grep -Fq "VENUE_DATA_MISSING_FAIL_CLOSED_NO_SOCKET_RESTART" "$ROOT/trader/worker/kiwoomRealtime.js" || fail "NXT 미수신시 전체 socket churn 방지 누락"
grep -Fq "FID9081_MISSING_OR_UNKNOWN" "$ROOT/trader/lib/realtimeStore.js" || fail "FID9081 fail-closed 거래소 게이트 누락"
grep -Fq "buildRealtimeFeatures" "$ROOT/trader/lib/realtimeStore.js" || fail "realtimeStore→feature engine 경로 누락"
grep -Fq "REAL_0B_FID9081_ONLY" "$ROOT/trader/worker/kiwoomRealtime.js" || fail "실수신 거래소 진실정책 누락"
grep -Fq "closeSnapshotFreshness" "$ROOT/trader/lib/marketSnapshot.js" || fail "종가 freshness gate 누락"
grep -Fq "runStartupCloseCatchup" "$ROOT/trader/worker/kiwoomRealtime.js" || fail "startup close catch-up 누락"
grep -Fq "KIWOOM_WEBSOCKET_TRADE_AUTO" "$ROOT/trader/pages/index.js" || fail "실시간 진입가 source 연결 누락"
! grep -Fq "realtimePriceSource === 'KIWOOM_WEBSOCKET_0A'" "$ROOT/trader/pages/index.js" || fail "구형 0A 진입가 UI 경로 잔존"
grep -q "api/discovery-feed" "$ROOT/news-radar/server.js" || fail "뉴스 discovery-feed 누락"

read_env_value(){ local key="$1"; sed -n "s/^${key}=//p" "$TMP_ROOT/trader.env" | tail -n1; }
upsert_env(){ local key="$1" value="$2"; if grep -q "^${key}=" "$TMP_ROOT/trader.env"; then sed -i "s#^${key}=.*#${key}=${value}#" "$TMP_ROOT/trader.env"; else printf '%s=%s\n' "$key" "$value" >> "$TMP_ROOT/trader.env"; fi; }
ensure_env(){ local key="$1" value="$2"; grep -q "^${key}=" "$TMP_ROOT/trader.env" || printf '%s=%s\n' "$key" "$value" >> "$TMP_ROOT/trader.env"; }

ACCESS_TOKEN="$(read_env_value APP_ACCESS_TOKEN)"
SESSION_SECRET="$(read_env_value APP_SESSION_SECRET)"
[[ ${#ACCESS_TOKEN} -ge 8 ]] || fail "APP_ACCESS_TOKEN 누락"
[[ ${#SESSION_SECRET} -ge 32 ]] || fail "APP_SESSION_SECRET 누락"
INTERNAL_TOKEN="$(read_env_value INTERNAL_BRIDGE_TOKEN)"
[[ ${#INTERNAL_TOKEN} -ge 32 ]] || INTERNAL_TOKEN="$(openssl rand -hex 32)"

upsert_env INTERNAL_BRIDGE_TOKEN "$INTERNAL_TOKEN"
upsert_env NEWS_RADAR_BASE_URL http://news-radar:3000
upsert_env KIWOOM_REALTIME_ENABLED true
upsert_env KIWOOM_WS_URL wss://api.kiwoom.com:10000/api/dostk/websocket
upsert_env KIWOOM_INTRADAY_REST_DIAGNOSTIC false
upsert_env KIWOOM_WATCHDOG_INTERVAL_MS 1000
upsert_env KIWOOM_SOCKET_WATCHDOG_MS 20000
upsert_env KIWOOM_VENUE_STALE_MS 5000
upsert_env KIWOOM_VENUE_NO_TRADE_RECOVERY_MS 8000
upsert_env KIWOOM_VENUE_HARD_RECOVERY_MS 18000
upsert_env KIWOOM_VENUE_RECOVERY_COOLDOWN_MS 12000
upsert_env REALTIME_JUDGMENT_MAX_AGE_MS 2000
upsert_env REALTIME_DISPLAY_MAX_AGE_MS 10000
upsert_env REALTIME_TRADE_EVAL_MIN_MS 40
upsert_env REALTIME_AUX_EVAL_MIN_MS 80
upsert_env REALTIME_DEBUG_MAX_SAMPLES 80
upsert_env MAX_FOCUS_USER_STOCKS 8
upsert_env MAX_LIGHT_USER_STOCKS 18
upsert_env HOST 0.0.0.0
upsert_env PORT 3000
ensure_env NEWS_DISCOVERY_CACHE_MS 30000
ensure_env MARKET_PROFILE_TTL_MS 86400000
ensure_env SMART_MONEY_CLOSE_AUDIT_ENABLED true
ensure_env ADAPTIVE_LEARNING_MIN_TOTAL_SAMPLES 60
ensure_env ADAPTIVE_LEARNING_MIN_BUCKET_SAMPLES 12
upsert_env ADAPTIVE_LEARNING_MAX_ADJUSTMENT 6
sed -i '/^MARKET_SNAPSHOT_INTERVAL_MS=/d' "$TMP_ROOT/trader.env"
chmod 600 "$TMP_ROOT/trader.env"

cat > "$TMP_ROOT/news.env" <<ENV
NODE_ENV=production
PORT=3000
APP_VERSION=1.5.6-rotation
STORE_DIR=/app/data
APP_ACCESS_TOKEN=$ACCESS_TOKEN
APP_SESSION_SECRET=$SESSION_SECRET
INTERNAL_BRIDGE_TOKEN=$INTERNAL_TOKEN
V313_BASE_URL=http://kiwoom-app:3000
SMARTMONEY_BASE_URL=http://kiwoom-app:3000
V313_ACCESS_TOKEN=$ACCESS_TOKEN
SMARTMONEY_ACCESS_TOKEN=$ACCESS_TOKEN
MARKET_SNAPSHOT_CACHE_MS=500
V313_BRIDGE_CACHE_MS=500
V313_BRIDGE_TIMEOUT_MS=5000
ENV
for key in NAVER_CLIENT_ID NAVER_CLIENT_SECRET DART_API_KEY FINNHUB_API_KEY RSS_FEED_URLS; do
  val="$(read_env_value "$key")"; [[ -z "$val" ]] || printf '%s=%s\n' "$key" "$val" >> "$TMP_ROOT/news.env"
done
chmod 600 "$TMP_ROOT/news.env"

say "Docker build — 내부 npm check/load/build gate 포함"
sudo docker build --pull -t "$NEWS_IMAGE" "$ROOT/news-radar"
sudo docker build --pull -t "$TRADER_IMAGE" "$ROOT/trader"

sudo docker network inspect "$DOCKER_NETWORK" >/dev/null 2>&1 || sudo docker network create "$DOCKER_NETWORK" >/dev/null
sudo docker volume inspect "$TRADER_DATA_VOLUME" >/dev/null 2>&1 || sudo docker volume create "$TRADER_DATA_VOLUME" >/dev/null
sudo docker volume inspect "$NEWS_DATA_VOLUME" >/dev/null 2>&1 || sudo docker volume create "$NEWS_DATA_VOLUME" >/dev/null

if sudo docker container inspect "$APP_CONTAINER" >/dev/null 2>&1; then sudo docker stop "$APP_CONTAINER" >/dev/null; sudo docker rename "$APP_CONTAINER" "$APP_BACKUP"; APP_OLD_RENAMED=1; fi
if sudo docker container inspect "$NEWS_CONTAINER" >/dev/null 2>&1; then sudo docker stop "$NEWS_CONTAINER" >/dev/null; sudo docker rename "$NEWS_CONTAINER" "$NEWS_BACKUP"; NEWS_OLD_RENAMED=1; fi

say "News Radar 실행"
sudo docker run -d --name "$NEWS_CONTAINER" --restart unless-stopped --network "$DOCKER_NETWORK" --env-file "$TMP_ROOT/news.env" -v "$NEWS_DATA_VOLUME:/app/data" -p 127.0.0.1:3100:3000 "$NEWS_IMAGE" >/dev/null
NEWS_NEW_STARTED=1

say "Trader v3.3.4 실행"
sudo docker run -d --name "$APP_CONTAINER" --restart unless-stopped --network "$DOCKER_NETWORK" --env-file "$TMP_ROOT/trader.env" -v "$TRADER_DATA_VOLUME:/app/data" -p 127.0.0.1:3000:3000 "$TRADER_IMAGE" >/dev/null
APP_NEW_STARTED=1

for _ in $(seq 1 90); do curl -fsS --max-time 3 http://127.0.0.1:3000/api/health > "$TMP_ROOT/health.json" 2>/dev/null && break; sleep 2; done
[[ -s "$TMP_ROOT/health.json" ]] || { sudo docker logs --tail 200 "$APP_CONTAINER" || true; fail "Trader health 실패"; }
RUNNING_VERSION="$(sudo docker exec "$APP_CONTAINER" node -p "require('./package.json').version")"
[[ "$RUNNING_VERSION" == "3.3.4" ]] || fail "실행 버전 불일치: $RUNNING_VERSION"

say "실제 수신 검증 — 공식 DOMESTIC REG ACK + REAL firstTick/fresh 관찰 (최대 90초)"
RUNTIME_OK=0
NXT_UNCONFIRMED=0
for _ in $(seq 1 30); do
  OUT="$(curl -fsS --max-time 3 http://127.0.0.1:3000/api/health 2>/dev/null || true)"
  if [[ -n "$OUT" ]]; then
    printf '%s' "$OUT" > "$TMP_ROOT/health.json"
    CHECK="$(python3 - "$TMP_ROOT/health.json" <<'PYCHK'
import json,sys
h=json.load(open(sys.argv[1]))
r=h.get('registrationStats') or {}
exp=h.get('expectedVenues') or []
dom=r.get('DOMESTIC') or {}
ack=int(dom.get('regAccepted') or 0)
rows=[f'DOMESTIC:ack={ack}']
ok=ack>0 and h.get('status')=='connected'
for v in exp:
    x=r.get(v) or {}
    first=int(x.get('firstTick') or 0); fresh=int(x.get('fresh') or 0); conf=bool(x.get('venueConfirmed'))
    rows.append(f'{v}:first={first},fresh={fresh},confirmed={conf}')
print(('OK' if ok else 'WAIT'), 'expected='+','.join(exp), *rows, 'status='+str(h.get('dataStatus')))
PYCHK
)"
    echo "$CHECK"
    [[ "$CHECK" == OK* ]] && { RUNTIME_OK=1; break; }
  fi
  sleep 3
done
if [[ $RUNTIME_OK -ne 1 ]]; then
  cat "$TMP_ROOT/health.json" || true
  sudo docker logs --tail 220 "$APP_CONTAINER" || true
  fail "공식 국내 WebSocket REG ACK/연결 검증 실패. 기존 컨테이너로 자동 롤백합니다."
fi
# NXT 활성시간에는 실제 NXT firstTick/fresh를 별도로 관찰하되, 공식 REG 자체가 정상이라면 배포를 되돌리지는 않는다.
# 미수신은 API 제공/계정 권한/서버측 stream 문제를 분리하기 위해 fail-closed 상태로 남긴다.
NXT_CHECK="$(python3 - "$TMP_ROOT/health.json" <<'PYCHK2'
import json,sys
h=json.load(open(sys.argv[1])); r=h.get('registrationStats') or {}; exp=h.get('expectedVenues') or []
n=r.get('NXT') or {}; ok=('NXT' not in exp) or (int(n.get('firstTick') or 0)>0 and int(n.get('fresh') or 0)>0 and bool(n.get('venueConfirmed')))
print('NXT_CONFIRMED' if ok else 'NXT_FEED_UNCONFIRMED')
PYCHK2
)"
echo "$NXT_CHECK"

say "배포 성공"
if [[ $APP_OLD_RENAMED -eq 1 ]]; then sudo docker rm -f "$APP_BACKUP" >/dev/null 2>&1 || true; APP_OLD_RENAMED=0; fi
if [[ $NEWS_OLD_RENAMED -eq 1 ]]; then sudo docker rm -f "$NEWS_BACKUP" >/dev/null 2>&1 || true; NEWS_OLD_RENAMED=0; fi
sudo docker image prune -f >/dev/null 2>&1 || true
sudo docker builder prune -f --filter 'until=24h' >/dev/null 2>&1 || true
trap - ERR

echo "=== FINAL ==="
sudo docker inspect "$APP_CONTAINER" --format='IMAGE={{.Config.Image}} STATUS={{.State.Status}} STARTED={{.State.StartedAt}}'
curl -s http://127.0.0.1:3000/api/health | python3 -c 'import sys,json; h=json.load(sys.stdin); print("version=",h.get("version")); print("status=",h.get("status")); print("dataStatus=",h.get("dataStatus")); print("closeSnapshots=",h.get("closeSnapshots"),"staleCloseSnapshots=",h.get("staleCloseSnapshots")); print("startupCloseCatchup=",h.get("startupCloseCatchup")); print("closeSync=",h.get("closeSync")); print("registrationStats=",h.get("registrationStats")); print("feedReady=",h.get("feedReady")); print("venueFeeds=",h.get("venueFeeds"))'
echo "=== REALTIME DEBUG SUMMARY ==="
curl -s "http://127.0.0.1:3000/api/realtime-debug?limit=5" | python3 -c 'import sys,json; d=json.load(sys.stdin); print("version=",d.get("version")); print("detectedTradeType=",d.get("detectedTradeType")); print("byType=",d.get("byType")); print("itemSuffix=",d.get("itemSuffix")); print("marketHints=",d.get("marketHints")); print("samples=",len(d.get("samples") or []))'
