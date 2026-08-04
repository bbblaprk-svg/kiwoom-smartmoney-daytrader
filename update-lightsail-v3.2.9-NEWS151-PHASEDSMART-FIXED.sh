#!/usr/bin/env bash
set -Eeuo pipefail

REPO_URL="https://github.com/bbblaprk-svg/kiwoom-smartmoney-daytrader.git"
ZIP_NAME="kiwoom-unified-edge-v3.2.9-NEWS151-PHASEDSMART.zip"
SOURCE_DIR_NAME="kiwoom-unified-edge-v3.2.9"
EXPECTED_ZIP_SHA256="99cc590c7f435b70f2bcdfc8519d08d3a6f349b2c7b58d82027e80b21a2229cd"
OLD_APP_DIR="$HOME/kiwoom-smartmoney-daytrader"
NEW_APP_DIR="$HOME/kiwoom-unified-edge"
TRADER_IMAGE="kiwoom-unified:v3.2.9"
NEWS_IMAGE="kiwoom-news-radar:1.5.1-unified"
APP_CONTAINER="kiwoom-app"
NEWS_CONTAINER="news-radar"
CADDY_CONTAINER="kiwoom-caddy"
DOCKER_NETWORK="kiwoom-net"
TRADER_DATA_VOLUME="kiwoom-data"
NEWS_DATA_VOLUME="news-radar-data"
TMP_ROOT="$(mktemp -d)"
APP_BACKUP="${APP_CONTAINER}-backup-$(date +%Y%m%d%H%M%S)"
NEWS_BACKUP="${NEWS_CONTAINER}-backup-$(date +%Y%m%d%H%M%S)"
APP_OLD_RENAMED=0
NEWS_OLD_RENAMED=0
APP_NEW_STARTED=0
NEWS_NEW_STARTED=0

say() { printf '\n==> %s\n' "$*"; }
fail() { printf '\n[오류] %s\n' "$*" >&2; exit 1; }
cleanup() { rm -rf "$TMP_ROOT"; }
trap cleanup EXIT

rollback() {
  local ec=$?
  if [[ $ec -eq 0 ]]; then return; fi
  printf '\n[자동 복구] v3.2.9 PHASED SMART MONEY 적용 실패 — 기존 앱으로 복구합니다.\n' >&2
  if [[ $APP_NEW_STARTED -eq 1 ]]; then sudo docker rm -f "$APP_CONTAINER" >/dev/null 2>&1 || true; fi
  if [[ $NEWS_NEW_STARTED -eq 1 ]]; then sudo docker rm -f "$NEWS_CONTAINER" >/dev/null 2>&1 || true; fi
  if [[ $APP_OLD_RENAMED -eq 1 ]]; then
    sudo docker rename "$APP_BACKUP" "$APP_CONTAINER" >/dev/null 2>&1 || true
    sudo docker start "$APP_CONTAINER" >/dev/null 2>&1 || true
  fi
  if [[ $NEWS_OLD_RENAMED -eq 1 ]]; then
    sudo docker rename "$NEWS_BACKUP" "$NEWS_CONTAINER" >/dev/null 2>&1 || true
    sudo docker start "$NEWS_CONTAINER" >/dev/null 2>&1 || true
  fi
  sudo docker restart "$CADDY_CONTAINER" >/dev/null 2>&1 || true
  printf '[자동 복구] 완료를 시도했습니다.\n' >&2
}
trap rollback ERR

[[ "$(id -u)" -ne 0 ]] || fail "root가 아닌 기본 ubuntu 사용자로 실행하세요."

say "필수 도구 확인"
sudo apt-get update -qq
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y git docker.io curl ca-certificates unzip openssl >/dev/null
sudo systemctl enable --now docker

ENV_SOURCE=""
if [[ -f "$NEW_APP_DIR/.env" ]]; then ENV_SOURCE="$NEW_APP_DIR/.env";
elif [[ -f "$OLD_APP_DIR/.env" ]]; then ENV_SOURCE="$OLD_APP_DIR/.env";
else fail "기존 통합앱/키움앱 .env를 찾지 못했습니다. 정상 서버에서 실행하세요."; fi
cp "$ENV_SOURCE" "$TMP_ROOT/trader.env"
chmod 600 "$TMP_ROOT/trader.env"

say "v3.2.9 PHASED SMART MONEY 파일 받기"
git clone --depth 1 "$REPO_URL" "$TMP_ROOT/repo"
cd "$TMP_ROOT/repo"
[[ -f "$ZIP_NAME" ]] || fail "GitHub 최상위에 $ZIP_NAME 파일이 없습니다."
ACTUAL_SHA="$(sha256sum "$ZIP_NAME" | awk '{print $1}')"
[[ "$ACTUAL_SHA" == "$EXPECTED_ZIP_SHA256" ]] || fail "ZIP SHA256 불일치. 예상 $EXPECTED_ZIP_SHA256 / 실제 $ACTUAL_SHA"

say "배포 ZIP 무결성 확인"
unzip -q "$ZIP_NAME" -d "$TMP_ROOT/source"
ROOT="$TMP_ROOT/source/$SOURCE_DIR_NAME"
[[ -d "$ROOT/trader" && -d "$ROOT/news-radar" ]] || fail "ZIP 내부 trader/news-radar 구조가 없습니다."
(
  cd "$ROOT"
  sha256sum -c BUNDLE_MANIFEST.sha256 >/dev/null
  cd trader && sha256sum -c SOURCE_MANIFEST.sha256 >/dev/null
  cd ../news-radar && sha256sum -c SOURCE_MANIFEST.sha256 >/dev/null
)

# v3.2.9 compatibility check: 기존 trader와 동일하게 APP_ACCESS_TOKEN 최소 길이를 8자로 통일한다.
# 원본 ZIP 무결성 검증이 끝난 뒤 build source에만 적용하며, Kiwoom 수신/판정 로직은 변경하지 않는다.
sed -i "s/token.length < 16/token.length < 8/; s/production에서 16자 이상이어야 합니다/production에서 8자 이상이어야 합니다/" "$ROOT/news-radar/lib/auth.js"
grep -q "token.length < 8" "$ROOT/news-radar/lib/auth.js" || fail "News Radar APP_ACCESS_TOKEN 호환패치 실패"

TRADER_VERSION="$(sed -n 's/.*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$ROOT/trader/package.json" | head -n1)"
[[ "$TRADER_VERSION" == "3.2.9" ]] || fail "trader package 버전이 3.2.9이 아닙니다: $TRADER_VERSION"

read_env_value() {
  local key="$1" file="${2:-$TMP_ROOT/trader.env}"
  sed -n "s/^${key}=//p" "$file" | tail -n 1
}
upsert_env() {
  local key="$1" value="$2" file="${3:-$TMP_ROOT/trader.env}"
  if grep -q "^${key}=" "$file"; then sed -i "s#^${key}=.*#${key}=${value}#" "$file"; else printf '%s=%s\n' "$key" "$value" >> "$file"; fi
}
ensure_env_default() {
  local key="$1" value="$2" file="${3:-$TMP_ROOT/trader.env}"
  grep -q "^${key}=" "$file" || printf '%s=%s\n' "$key" "$value" >> "$file"
}

ACCESS_TOKEN="$(read_env_value APP_ACCESS_TOKEN)"
SESSION_SECRET="$(read_env_value APP_SESSION_SECRET)"
[[ ${#ACCESS_TOKEN} -ge 8 ]] || fail "APP_ACCESS_TOKEN이 없거나 8자 미만입니다."
[[ ${#SESSION_SECRET} -ge 32 ]] || fail "APP_SESSION_SECRET이 없거나 너무 짧습니다."
INTERNAL_TOKEN="$(read_env_value INTERNAL_BRIDGE_TOKEN)"
if [[ ${#INTERNAL_TOKEN} -lt 32 ]]; then INTERNAL_TOKEN="$(openssl rand -hex 32)"; fi

# Kiwoom 앱키/시크릿, REST/WebSocket, TR/FID 관련 기존 환경값은 절대 덮어쓰지 않는다.
upsert_env MAX_FOCUS_USER_STOCKS 8
upsert_env MAX_LIGHT_USER_STOCKS 18
upsert_env DAILY_RECOMMENDATIONS_ENABLED true
upsert_env NEWS_RADAR_BASE_URL http://news-radar:3000
upsert_env INTERNAL_BRIDGE_TOKEN "$INTERNAL_TOKEN"
ensure_env_default NEWS_DISCOVERY_CACHE_MS 30000
ensure_env_default NEWS_DISCOVERY_TIMEOUT_MS 4000
ensure_env_default NEWS_DISCOVERY_MAX_ITEMS 100
# v3.2.9 추천용 시장발굴 + KRX/NXT dual-feed + pipeline guard. Kiwoom 실시간 WebSocket/TR/FID 수신 설정은 변경하지 않는다.
ensure_env_default MARKET_PROFILE_TTL_MS 86400000
ensure_env_default MARKET_PROFILE_ENRICH_LIMIT 60
ensure_env_default MARKET_POOL_MAX 40
# v3.2.9 PHASED SMART MONEY dual-feed 장애방어 기본값. 기존 사용자가 명시한 값은 보존한다.
ensure_env_default KIWOOM_REALTIME_ENABLED true
ensure_env_default KIWOOM_WS_URL wss://api.kiwoom.com:10000/api/dostk/websocket
ensure_env_default KIWOOM_SOCKET_WATCHDOG_MS 45000
ensure_env_default KIWOOM_VENUE_STALE_MS 12000
ensure_env_default KIWOOM_REST_FALLBACK_INTERVAL_MS 5000
ensure_env_default KIWOOM_REST_MIN_GAP_MS 230
upsert_env REALTIME_TRADE_EVAL_MIN_MS 80
upsert_env REALTIME_AUX_EVAL_MIN_MS 180
ensure_env_default CLOSE_SYNC_MAX_ATTEMPTS 7
ensure_env_default CLOSE_SYNC_POST_FINAL_RETRY_MS 300000
# v3.2.9에서는 15분 전체 스냅샷 환경값을 사용하지 않는다. 오래된 값은 제거해 혼선을 방지한다.
sed -i '/^MARKET_SNAPSHOT_INTERVAL_MS=/d' "$TMP_ROOT/trader.env"
upsert_env MANAGED_SIGNAL_NORMAL_MIN 4
upsert_env MANAGED_SIGNAL_NORMAL_TARGET 5
upsert_env MANAGED_SIGNAL_NORMAL_MAX 6
ensure_env_default UNIFIED_ROTATION_ENABLED true
ensure_env_default INTRADAY_AUTO_APPLY_DEFAULT true
ensure_env_default UNIFIED_ROTATION_INTERVAL_MS 300000
ensure_env_default UNIFIED_LIGHT_MIN_HOLD_MS 600000
ensure_env_default UNIFIED_LIGHT_MAX_REPLACEMENTS 2
ensure_env_default UNIFIED_REPLACEMENT_MARGIN 8
upsert_env ADAPTIVE_LEARNING_MIN_TOTAL_SAMPLES 60
upsert_env ADAPTIVE_LEARNING_MIN_BUCKET_SAMPLES 12
ensure_env_default ADAPTIVE_LEARNING_MAX_OUTCOMES 500
upsert_env ADAPTIVE_LEARNING_MAX_ADJUSTMENT 6
upsert_env ADAPTIVE_LEARNING_PRIOR_STRENGTH 32
upsert_env CLOSE_LEARNING_MIN_TOTAL 60
upsert_env CLOSE_LEARNING_MIN_BUCKET 12
upsert_env CLOSE_LEARNING_MAX_ADJUSTMENT 6
ensure_env_default POST_PROCESS_CONCURRENCY 4
upsert_env HOST 0.0.0.0
upsert_env PORT 3000
chmod 600 "$TMP_ROOT/trader.env"

cat > "$TMP_ROOT/news.env" <<ENV
NODE_ENV=production
PORT=3000
APP_VERSION=1.5.1-unified
STORE_DIR=/app/data
APP_ACCESS_TOKEN=$ACCESS_TOKEN
APP_SESSION_SECRET=$SESSION_SECRET
INTERNAL_BRIDGE_TOKEN=$INTERNAL_TOKEN
V313_BASE_URL=http://kiwoom-app:3000
SMARTMONEY_BASE_URL=http://kiwoom-app:3000
V313_ACCESS_TOKEN=$ACCESS_TOKEN
SMARTMONEY_ACCESS_TOKEN=$ACCESS_TOKEN
ENV
chmod 600 "$TMP_ROOT/news.env"

# 선택사항: 기존 .env에 뉴스 제공자 키가 있으면 AWS 뉴스컨테이너에도 전달한다.
for key in NAVER_CLIENT_ID NAVER_CLIENT_SECRET DART_API_KEY FINNHUB_API_KEY RSS_FEED_URLS; do
  val="$(read_env_value "$key")"
  if [[ -n "$val" ]]; then printf '%s=%s\n' "$key" "$val" >> "$TMP_ROOT/news.env"; fi
done

say "Docker 이미지 빌드 — 뉴스/트레이더 검사 포함"
sudo docker build --pull -t "$NEWS_IMAGE" "$ROOT/news-radar"
sudo docker build --pull -t "$TRADER_IMAGE" "$ROOT/trader"

say "데이터 볼륨/내부 네트워크 준비"
sudo docker network inspect "$DOCKER_NETWORK" >/dev/null 2>&1 || sudo docker network create "$DOCKER_NETWORK" >/dev/null
sudo docker volume inspect "$TRADER_DATA_VOLUME" >/dev/null 2>&1 || sudo docker volume create "$TRADER_DATA_VOLUME" >/dev/null
sudo docker volume inspect "$NEWS_DATA_VOLUME" >/dev/null 2>&1 || sudo docker volume create "$NEWS_DATA_VOLUME" >/dev/null

if sudo docker container inspect "$APP_CONTAINER" >/dev/null 2>&1; then
  say "기존 키움앱 롤백 보관"
  sudo docker stop "$APP_CONTAINER" >/dev/null
  sudo docker rename "$APP_CONTAINER" "$APP_BACKUP"
  APP_OLD_RENAMED=1
fi
if sudo docker container inspect "$NEWS_CONTAINER" >/dev/null 2>&1; then
  say "기존 AWS 뉴스컨테이너 롤백 보관"
  sudo docker stop "$NEWS_CONTAINER" >/dev/null
  sudo docker rename "$NEWS_CONTAINER" "$NEWS_BACKUP"
  NEWS_OLD_RENAMED=1
fi

say "AWS 내부 News Radar 실행"
sudo docker run -d \
  --name "$NEWS_CONTAINER" \
  --restart unless-stopped \
  --network "$DOCKER_NETWORK" \
  --env-file "$TMP_ROOT/news.env" \
  -v "$NEWS_DATA_VOLUME:/app/data" \
  -p 127.0.0.1:3100:3000 \
  "$NEWS_IMAGE" >/dev/null
NEWS_NEW_STARTED=1

NEWS_OK=0
for _ in $(seq 1 90); do
  if curl -fsS --max-time 5 http://127.0.0.1:3100/api/health >"$TMP_ROOT/news-health.json" 2>/dev/null; then NEWS_OK=1; break; fi
  sleep 2
done
if [[ $NEWS_OK -ne 1 ]]; then sudo docker logs --tail 160 "$NEWS_CONTAINER" || true; fail "AWS News Radar 건강검사 실패"; fi
grep -q '"version":"1.5.1-unified"' "$TMP_ROOT/news-health.json" || fail "News Radar 실행 버전이 1.5.1-unified가 아닙니다."

# Render 학습상태가 별도 환경값으로 보존돼 있으면 선택적으로 AWS로 복사한다. 실패해도 배포는 계속한다.
RENDER_URL="$(read_env_value NEWS_RENDER_BASE_URL)"
RENDER_TOKEN="$(read_env_value NEWS_RENDER_ACCESS_TOKEN)"
if [[ -n "$RENDER_URL" && -n "$RENDER_TOKEN" ]]; then
  say "기존 Render 뉴스 학습상태 선택적 이전"
  curl -fsS --max-time 15 -H "Authorization: Bearer $RENDER_TOKEN" "${RENDER_URL%/}/api/calibration" -o "$TMP_ROOT/calibration.json" 2>/dev/null \
    && curl -fsS --max-time 15 -X POST -H "Authorization: Bearer $ACCESS_TOKEN" -H 'Content-Type: application/json' --data-binary @"$TMP_ROOT/calibration.json" http://127.0.0.1:3100/api/calibration >/dev/null 2>&1 || true
  curl -fsS --max-time 15 -H "Authorization: Bearer $RENDER_TOKEN" "${RENDER_URL%/}/api/next-us-session-state" -o "$TMP_ROOT/next-us.json" 2>/dev/null \
    && curl -fsS --max-time 15 -X POST -H "Authorization: Bearer $ACCESS_TOKEN" -H 'Content-Type: application/json' --data-binary @"$TMP_ROOT/next-us.json" http://127.0.0.1:3100/api/next-us-session-state >/dev/null 2>&1 || true
fi

say "v3.2.9 PHASED SMART MONEY 공개앱 실행"
sudo docker run -d \
  --name "$APP_CONTAINER" \
  --restart unless-stopped \
  --network "$DOCKER_NETWORK" \
  --env-file "$TMP_ROOT/trader.env" \
  -v "$TRADER_DATA_VOLUME:/app/data" \
  -p 127.0.0.1:3000:3000 \
  "$TRADER_IMAGE" >/dev/null
APP_NEW_STARTED=1

APP_OK=0
for _ in $(seq 1 90); do
  if curl -fsS --max-time 5 http://127.0.0.1:3000/api/health >"$TMP_ROOT/app-health.json" 2>/dev/null; then
    if grep -q '"serverTime"' "$TMP_ROOT/app-health.json"; then APP_OK=1; break; fi
  fi
  sleep 2
done
if [[ $APP_OK -ne 1 ]]; then sudo docker logs --tail 200 "$APP_CONTAINER" || true; fail "통합앱 건강검사 실패"; fi
RUNNING_VERSION="$(sudo docker exec "$APP_CONTAINER" node -p "require('./package.json').version" 2>/dev/null || true)"
[[ "$RUNNING_VERSION" == "3.2.9" ]] || fail "실행 버전 불일치: $RUNNING_VERSION"

say "LOW TRAFFIC 정책 확인"
LOW_TRAFFIC_OK="$(sudo docker exec "$APP_CONTAINER" node -e "fetch('http://127.0.0.1:3000/api/health').then(r=>r.json()).then(h=>{const p=h.restPolicy||{};const m=h.realtimeTypeMap||{};const ok=h.trafficMode==='LOW_TRAFFIC_WEBSOCKET_FIRST_PIPELINE_GUARD_V2'&&h.snapshotPolicy==='CLOSE_ONLY'&&p.periodicFullSnapshot===false&&p.retryScope==='FAILED_SYMBOLS_ONLY'&&p.restartCatchup===true&&p.closeBuyRequiresOfficialKrxClose===true&&p.closeSyncCoalescing===true&&p.nxtFinalFastPath==='WEBSOCKET_THEN_REST'&&p.foreignDetailFallbackOnly===true&&m.trade==='0B'&&m.orderbook==='0D'&&m.broker==='0F'&&m.program==='0w'&&m.marketStatus==='0s'&&m.vi==='1h';console.log(ok?'OK':'BAD',JSON.stringify({trafficMode:h.trafficMode,snapshotPolicy:h.snapshotPolicy,realtimeTypeMap:m,restPolicy:p,closeSync:h.closeSync,restMetrics:h.restMetrics}));process.exit(ok?0:1)}).catch(e=>{console.error(e.message);process.exit(1)})" 2>&1 || true)"
[[ "$LOW_TRAFFIC_OK" == OK* ]] || fail "LOW TRAFFIC 정책 확인 실패: $LOW_TRAFFIC_OK"
printf '%s\n' "$LOW_TRAFFIC_OK"

say "PIPELINE GUARD 런타임 상태 확인"
PIPELINE_RUNTIME="$(sudo docker exec "$APP_CONTAINER" node -e "fetch('http://127.0.0.1:3000/api/health',{headers:{Authorization:'Bearer '+process.env.APP_ACCESS_TOKEN}}).then(r=>r.json()).then(h=>{const rt=h.load&&h.load.realtime||{};const ok=h.trafficMode==='LOW_TRAFFIC_WEBSOCKET_FIRST_PIPELINE_GUARD_V2'&&h.realtimeTypeMap&&Number.isFinite(Number(rt.signalEvaluations||0))&&Number.isFinite(Number(rt.signalEvaluationSkips||0));console.log(ok?'OK':'BAD',JSON.stringify({smartMoneyReady:h.smartMoneyReady,feedReady:h.feedReady,realtime:rt,typeMap:h.realtimeTypeMap}));process.exit(ok?0:1)}).catch(e=>{console.error(e.message);process.exit(1)})" 2>&1 || true)"
[[ "$PIPELINE_RUNTIME" == OK* ]] || fail "PIPELINE GUARD 런타임 상태 확인 실패: $PIPELINE_RUNTIME"
printf '%s\n' "$PIPELINE_RUNTIME"

say "KRX/NXT dual-feed 구독 구조 확인"
DUAL_STRUCT_OK="$(sudo docker exec "$APP_CONTAINER" node -e "fetch('http://127.0.0.1:3000/api/health').then(r=>r.json()).then(h=>{const ok=Number(h.subscribed)>0&&Number(h.krxSubscribed)>=Number(h.subscribed)&&Number(h.nxtSubscribed)>=Number(h.subscribed)&&Number(h.wireSubscribed)>=Number(h.subscribed)*2;console.log(ok?'OK':'BAD',JSON.stringify({subscribed:h.subscribed,wire:h.wireSubscribed,krx:h.krxSubscribed,nxt:h.nxtSubscribed,registration:h.venueRegistration}));process.exit(ok?0:1)}).catch(e=>{console.error(e.message);process.exit(1)})" 2>&1 || true)"
[[ "$DUAL_STRUCT_OK" == OK* ]] || fail "KRX/NXT 이중 구독 구조 확인 실패: $DUAL_STRUCT_OK"
printf '%s\n' "$DUAL_STRUCT_OK"

# REG 응답은 비동기이므로 잠시 기다린 뒤 KRX 등록 실패는 배포 실패로 처리한다.
REG_CHECK=""
for _ in $(seq 1 30); do
  REG_CHECK="$(sudo docker exec "$APP_CONTAINER" node -e "fetch('http://127.0.0.1:3000/api/health').then(r=>r.json()).then(h=>{const v=h.venueRegistration||{};const krx=String(v.KRX||'');const pending=Object.values(v).some(x=>String(x)==='pending');const fatal=krx.startsWith('degraded');console.log(JSON.stringify({krx,pending,registration:v}));process.exit(fatal?2:pending?1:0)}).catch(()=>process.exit(1))" 2>/dev/null || true)"
  if [[ "$REG_CHECK" == *'"krx":"degraded'* ]]; then fail "KRX 실시간 REG 실패: $REG_CHECK"; fi
  if [[ "$REG_CHECK" != *'"pending":true'* && -n "$REG_CHECK" ]]; then break; fi
  sleep 1
done
say "실시간 REG 상태 $REG_CHECK"

# 장중 실제 체결 freshness를 최대 75초 관찰한다. 활성 거래소에서 fresh=0이면 새 버전을 성공 처리하지 않고 기존 컨테이너로 롤백한다.
LIVE_VERIFY="$(sudo docker exec -i "$APP_CONTAINER" node - <<'NODE'
const sleep=ms=>new Promise(r=>setTimeout(r,ms));
(async()=>{
  const kst=new Date(Date.now()+9*3600e3); const dow=kst.getUTCDay(); const sec=kst.getUTCHours()*3600+kst.getUTCMinutes()*60+kst.getUTCSeconds();
  const weekday=dow>=1&&dow<=5; const krxActive=weekday&&sec>=9*3600&&sec<=15*3600+30*60;
  const nxtActive=weekday&&((sec>=8*3600&&sec<=8*3600+50*60)||(sec>=9*3600+30&&sec<=15*3600+20*60)||(sec>=15*3600+40*60&&sec<=20*3600));
  let last=null;
  for(let i=0;i<15;i++){
    last=await fetch('http://127.0.0.1:3000/api/health').then(r=>r.json());
    const k=Number(last.venueFeeds?.KRX?.fresh||0), n=Number(last.venueFeeds?.NXT?.fresh||0);
    if((!krxActive||k>0)&&(!nxtActive||n>0)) break;
    await sleep(5000);
  }
  const k=Number(last?.venueFeeds?.KRX?.fresh||0), n=Number(last?.venueFeeds?.NXT?.fresh||0);
  const failed=[]; if(krxActive&&k<=0) failed.push('KRX'); if(nxtActive&&n<=0) failed.push('NXT');
  const status=failed.length?'FAIL':(krxActive||nxtActive?'OK':'DEFERRED');
  console.log(JSON.stringify({status,failed,krxActive,nxtActive,krxFresh:k,nxtFresh:n,dualFresh:Number(last?.venueFeeds?.dualFresh||0),socketFrameAgeMs:last?.socketFrameAgeMs,registration:last?.venueRegistration,fallbackLastAt:last?.fallbackLastAt,fallbackLastVenue:last?.fallbackLastVenue}));
})().catch(e=>{console.error(e.message);process.exit(1)});
NODE
)"
say "장중 거래소 freshness $LIVE_VERIFY"
if [[ "$LIVE_VERIFY" == *'"status":"FAIL"'* ]]; then
  sudo docker logs --tail 120 "$APP_CONTAINER" || true
  fail "활성 거래소 실시간 체결 freshness 검증 실패: $LIVE_VERIFY"
fi
say "뉴스 내부브리지 확인"
BRIDGE_OK="$(sudo docker exec "$APP_CONTAINER" node -e "fetch('http://news-radar:3000/api/discovery-feed?limit=5',{headers:{'x-internal-bridge-token':process.env.INTERNAL_BRIDGE_TOKEN},signal:AbortSignal.timeout(5000)}).then(async r=>{await r.text();console.log(r.status);process.exit(r.ok?0:1)}).catch(e=>{console.error(e.message);process.exit(1)})" 2>/dev/null | tail -n1 || true)"
[[ "$BRIDGE_OK" == "200" ]] || fail "뉴스 내부브리지 응답이 200이 아닙니다: $BRIDGE_OK"
BRIDGE_TIME="$(curl -sS -o /dev/null --max-time 5 -w '%{time_total}' -H "x-internal-bridge-token: $INTERNAL_TOKEN" "http://127.0.0.1:3100/api/discovery-feed?limit=5" || true)"
[[ -n "$BRIDGE_TIME" ]] || fail "뉴스 내부브리지 5초 응답검사 실패"
say "뉴스 내부브리지 응답시간 ${BRIDGE_TIME}s"

say "HTTPS 프록시 재연결"
sudo docker restart "$CADDY_CONTAINER" >/dev/null 2>&1 || true

say "배포 소스/환경 보관"
rm -rf "$NEW_APP_DIR"
mkdir -p "$NEW_APP_DIR"
cp -a "$ROOT/." "$NEW_APP_DIR/"
cp "$TMP_ROOT/trader.env" "$NEW_APP_DIR/.env"
cp "$TMP_ROOT/news.env" "$NEW_APP_DIR/news.env"
chmod 600 "$NEW_APP_DIR/.env" "$NEW_APP_DIR/news.env"
# 기존 경로의 .env도 최신 통합환경을 유지해 다음 업데이트와 호환
cp "$TMP_ROOT/trader.env" "$OLD_APP_DIR/.env"
chmod 600 "$OLD_APP_DIR/.env"

if [[ $APP_OLD_RENAMED -eq 1 ]]; then sudo docker rm "$APP_BACKUP" >/dev/null 2>&1 || true; APP_OLD_RENAMED=0; fi
if [[ $NEWS_OLD_RENAMED -eq 1 ]]; then sudo docker rm "$NEWS_BACKUP" >/dev/null 2>&1 || true; NEWS_OLD_RENAMED=0; fi
APP_NEW_STARTED=0
NEWS_NEW_STARTED=0
trap - ERR

PUBLIC_IP="$(curl -4 -fsS --max-time 15 https://api.ipify.org || true)"
DOMAIN="${PUBLIC_IP//./-}.nip.io"
printf '\n============================================================\n'
printf 'KIWOOM UNIFIED EDGE v3.2.9 PHASED SMART MONEY 설치 완료\n'
printf '공개 앱     : https://%s\n' "$DOMAIN"
printf '공개 컨테이너: kiwoom-app v3.2.9\n'
printf '내부 뉴스   : news-radar v1.5.1-unified (AWS 내부망)\n'
printf '발굴 구조   : 신선 해외뉴스(TOP3 국내연관주) + MONEY FLOW -> 시총균형 시장풀40 -> 실시간 감시 최대30\n'
printf '시총 목표   : <1,000억 8 / 1,000~5,000억 14 / 5,000억~3조 10 / 3조+ 8 (후보부족 시 백필)\n'
printf '시장 가속   : 장중 5분 거래량급증 + 거래대금 속도/가속 + 상대거래량\n'
printf '진입 단계   : EARLY -> PRE-BUY -> TURN/MARKUP 확인 -> 엄격한 BUY\n'
printf '스마트머니  : tape 중복가산 제거 + ACCUMULATION -> SHAKEOUT -> TURN -> MARKUP -> DISTRIBUTION/EXHAUSTION\n'
printf '실시간 구조 : KRX/NXT 상태분리 + 모든 체결저장 + 평가 throttle + 45초 watchdog + stale REST 보조\n'
printf 'LOW TRAFFIC : 장중 전체 REST 제거 · KRX 15:32 / NXT 20:01 동기화 + 실패종목만 재시도\n'
printf '신호 관리   : 정상장 4~6개 관리목표 · BUY 임계값은 숫자를 맞추기 위해 완화하지 않음\n'
printf '관리 테이블 : 점수 · 현재가 · 진입/기준가 · 수익률 · 등락률 · KRX/NXT · 스마트머니\n'
printf '학습 구조   : 60/12표본 이후 순위만 ±6 보정 · 실제 BUY/CLOSE_BUY 체결성과 60건 이후 우선학습 · 하드게이트 불변\n'
printf '동적 교체   : 새 설치 자동적용 기본 ON · AUTO 목록 1회 bootstrap 후 경량만 5분 주기 최대2종목\n'
printf '수동 보호   : 고정/수동/집중종목 자동교체 금지\n'
printf 'Render      : 통합앱은 더 이상 Render를 실시간 경로로 사용하지 않음\n'
printf '============================================================\n'
printf '앱 건강상태: '; cat "$TMP_ROOT/app-health.json"; printf '\n'
printf '뉴스 건강상태: '; cat "$TMP_ROOT/news-health.json"; printf '\n'
printf '\nSafari/PWA를 완전히 닫았다가 다시 열고 상단 v3.2.9 PHASED SMART MONEY와 통합레이더 탭을 확인하세요.\n'
