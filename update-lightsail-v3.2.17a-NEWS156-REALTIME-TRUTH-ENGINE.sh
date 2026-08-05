#!/usr/bin/env bash
set -Eeuo pipefail

REPO_URL="https://github.com/bbblaprk-svg/kiwoom-smartmoney-daytrader.git"
ZIP_NAME="kiwoom-unified-edge-v3.2.17-NEWS156-REALTIME-TRUTH-ENGINE.zip"
SOURCE_DIR_NAME="kiwoom-unified-edge-v3.2.17"
EXPECTED_ZIP_SHA256="22b02838bd4b33b3ed5731965186e26b2b0fc2ba66d67e014679d78b82c3bee3"
OLD_APP_DIR="$HOME/kiwoom-smartmoney-daytrader"
NEW_APP_DIR="$HOME/kiwoom-unified-edge"
TRADER_IMAGE="kiwoom-unified:v3.2.17"
NEWS_IMAGE="kiwoom-news-radar:1.5.6-pre-ignition"
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
  [[ $ec -eq 0 ]] && return
  printf '\n[자동 복구] v3.2.17 REALTIME TRUTH ENGINE 적용 실패 — 기존 앱으로 복구합니다.\n' >&2
  [[ $APP_NEW_STARTED -eq 1 ]] && sudo docker rm -f "$APP_CONTAINER" >/dev/null 2>&1 || true
  [[ $NEWS_NEW_STARTED -eq 1 ]] && sudo docker rm -f "$NEWS_CONTAINER" >/dev/null 2>&1 || true
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
if [[ -f "$NEW_APP_DIR/.env" ]]; then ENV_SOURCE="$NEW_APP_DIR/.env"
elif [[ -f "$OLD_APP_DIR/.env" ]]; then ENV_SOURCE="$OLD_APP_DIR/.env"
else fail "기존 통합앱/키움앱 .env를 찾지 못했습니다. 정상 서버에서 실행하세요."
fi
cp "$ENV_SOURCE" "$TMP_ROOT/trader.env"
chmod 600 "$TMP_ROOT/trader.env"

say "v3.2.17 REALTIME TRUTH ENGINE + News v1.5.6 파일 받기"
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

TRADER_VERSION="$(sed -n 's/.*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$ROOT/trader/package.json" | head -n1)"
NEWS_VERSION="$(sed -n 's/.*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$ROOT/news-radar/package.json" | head -n1)"
[[ "$TRADER_VERSION" == "3.2.17" ]] || fail "trader package 버전 불일치: $TRADER_VERSION"
[[ "$NEWS_VERSION" == "1.5.6" ]] || fail "news package 버전 불일치: $NEWS_VERSION"
grep -q "REALTIME_TRUTH_CHECK PASS" "$ROOT/trader/scripts/realtime-truth-check.js" || fail "realtime truth 검사 누락"
grep -q "OFFICIAL_REALTIME_ROUTE_CHECK PASS" "$ROOT/trader/scripts/official-realtime-route-check.js" || fail "공식 realtime route 검사 누락"
grep -q "REALTIME_ENGINE_V3217_CHECK PASS" "$ROOT/trader/scripts/realtime-engine-v3217-check.js" || fail "v3.2.17 realtime engine 검사 누락"
grep -Fq 'NXT_CORE_${item.code}' "$ROOT/trader/worker/kiwoomRealtime.js" || fail "NXT 종목별 0A 격리 등록 누락"
grep -Fq "const SCOUT_TYPES = ['0A', '0C', '0u'];" "$ROOT/trader/worker/kiwoomRealtime.js" || fail "공식 SCOUT realtime 타입 불일치"
grep -Fq "case '0A': return processTrade" "$ROOT/trader/lib/realtimeStore.js" || fail "0A 체결 parser 누락"
grep -Fq "case '0C': processOrderbook" "$ROOT/trader/lib/realtimeStore.js" || fail "0C 호가잔량 parser 누락"
! grep -Fq "case '0B': return processTrade" "$ROOT/trader/lib/realtimeStore.js" || fail "치명적 route 오류: 0B를 체결로 사용"
! grep -Fq "case '0D': processOrderbook" "$ROOT/trader/lib/realtimeStore.js" || fail "치명적 route 오류: 0D를 정규 호가잔량으로 사용"
grep -q "realtimeEligible" "$ROOT/news-radar/lib/v313Bridge.js" || fail "뉴스 실시간 bridge guard 누락"
grep -q "api/discovery-feed" "$ROOT/news-radar/server.js" || fail "뉴스 discovery-feed 누락"

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
[[ ${#INTERNAL_TOKEN} -ge 32 ]] || INTERNAL_TOKEN="$(openssl rand -hex 32)"

# 기존 Kiwoom 앱키/시크릿/TR 환경값은 보존하고 구조·정책 값만 보강한다.
upsert_env MAX_FOCUS_USER_STOCKS 8
upsert_env MAX_LIGHT_USER_STOCKS 18
upsert_env DAILY_RECOMMENDATIONS_ENABLED true
upsert_env NEWS_RADAR_BASE_URL http://news-radar:3000
upsert_env INTERNAL_BRIDGE_TOKEN "$INTERNAL_TOKEN"
ensure_env_default NEWS_DISCOVERY_CACHE_MS 30000
ensure_env_default NEWS_DISCOVERY_TIMEOUT_MS 4000
ensure_env_default NEWS_DISCOVERY_MAX_ITEMS 100
ensure_env_default MARKET_PROFILE_TTL_MS 86400000
ensure_env_default MARKET_PROFILE_ENRICH_LIMIT 60
ensure_env_default MARKET_POOL_MAX 40

# 실시간 판단 정책은 과거 .env 값보다 v3.2.17 정책을 우선한다.
upsert_env KIWOOM_REALTIME_ENABLED true
upsert_env KIWOOM_WS_URL wss://api.kiwoom.com:10000/api/dostk/websocket
upsert_env KIWOOM_SOCKET_WATCHDOG_MS 20000
upsert_env KIWOOM_WATCHDOG_INTERVAL_MS 1000
upsert_env KIWOOM_VENUE_STALE_MS 5000
upsert_env KIWOOM_VENUE_NO_TRADE_RECOVERY_MS 8000
upsert_env KIWOOM_VENUE_HARD_RECOVERY_MS 18000
upsert_env KIWOOM_VENUE_RECOVERY_COOLDOWN_MS 12000
upsert_env KIWOOM_INTRADAY_REST_DIAGNOSTIC false
upsert_env KIWOOM_REST_FALLBACK_INTERVAL_MS 5000
upsert_env KIWOOM_REST_MIN_GAP_MS 230
upsert_env REALTIME_JUDGMENT_MAX_AGE_MS 2000
upsert_env REALTIME_DISPLAY_MAX_AGE_MS 10000
upsert_env REALTIME_TRADE_EVAL_MIN_MS 40
upsert_env REALTIME_AUX_EVAL_MIN_MS 80

ensure_env_default SMART_MONEY_CLOSE_AUDIT_ENABLED true
ensure_env_default SMART_MONEY_CLOSE_AUDIT_START 1440
ensure_env_default SMART_MONEY_CLOSE_AUDIT_END 1535
ensure_env_default CLOSE_SYNC_MAX_ATTEMPTS 7
ensure_env_default CLOSE_SYNC_POST_FINAL_RETRY_MS 300000
# 구버전 정기 전체 REST 스냅샷은 제거한다.
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
APP_VERSION=1.5.6-pre-ignition
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
chmod 600 "$TMP_ROOT/news.env"
for key in NAVER_CLIENT_ID NAVER_CLIENT_SECRET DART_API_KEY FINNHUB_API_KEY RSS_FEED_URLS; do
  val="$(read_env_value "$key")"
  [[ -z "$val" ]] || printf '%s=%s\n' "$key" "$val" >> "$TMP_ROOT/news.env"
done

say "Docker 이미지 빌드 — manifest/check/load/build gate 포함"
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
  say "기존 뉴스앱 롤백 보관"
  sudo docker stop "$NEWS_CONTAINER" >/dev/null
  sudo docker rename "$NEWS_CONTAINER" "$NEWS_BACKUP"
  NEWS_OLD_RENAMED=1
fi

say "News Radar v1.5.6 실행"
sudo docker run -d --name "$NEWS_CONTAINER" --restart unless-stopped \
  --network "$DOCKER_NETWORK" --env-file "$TMP_ROOT/news.env" \
  -v "$NEWS_DATA_VOLUME:/app/data" -p 127.0.0.1:3100:3000 "$NEWS_IMAGE" >/dev/null
NEWS_NEW_STARTED=1

NEWS_OK=0
for _ in $(seq 1 90); do
  if curl -fsS --max-time 5 http://127.0.0.1:3100/api/health >"$TMP_ROOT/news-health.json" 2>/dev/null; then NEWS_OK=1; break; fi
  sleep 2
done
[[ $NEWS_OK -eq 1 ]] || { sudo docker logs --tail 160 "$NEWS_CONTAINER" || true; fail "News Radar 건강검사 실패"; }
grep -q '"version":"1.5.6-pre-ignition"' "$TMP_ROOT/news-health.json" || fail "News Radar 실행 버전 불일치"

say "Trader v3.2.17 REALTIME TRUTH ENGINE 실행"
sudo docker run -d --name "$APP_CONTAINER" --restart unless-stopped \
  --network "$DOCKER_NETWORK" --env-file "$TMP_ROOT/trader.env" \
  -v "$TRADER_DATA_VOLUME:/app/data" -p 127.0.0.1:3000:3000 "$TRADER_IMAGE" >/dev/null
APP_NEW_STARTED=1

APP_OK=0
for _ in $(seq 1 90); do
  if curl -fsS --max-time 5 http://127.0.0.1:3000/api/health >"$TMP_ROOT/app-health.json" 2>/dev/null; then
    grep -q '"serverTime"' "$TMP_ROOT/app-health.json" && { APP_OK=1; break; }
  fi
  sleep 2
done
[[ $APP_OK -eq 1 ]] || { sudo docker logs --tail 200 "$APP_CONTAINER" || true; fail "Trader 건강검사 실패"; }
RUNNING_VERSION="$(sudo docker exec "$APP_CONTAINER" node -p "require('./package.json').version" 2>/dev/null || true)"
[[ "$RUNNING_VERSION" == "3.2.17" ]] || fail "실행 trader 버전 불일치: $RUNNING_VERSION"

say "VERIFIED REALTIME + PRE-IGNITION 정책 확인"
STRICT_POLICY="$(sudo docker exec "$APP_CONTAINER" node -e "fetch('http://127.0.0.1:3000/api/health').then(r=>r.json()).then(h=>{const t=h.realtimeTruth||{};const p=h.restPolicy||{};const m=h.realtimeTypeMap||{};const ok=String(h.version||'').startsWith('3.2.17')&&h.status==='connected'&&t.judgmentRoute==='KIWOOM_WEBSOCKET_ONLY'&&t.priceRoute==='KIWOOM_WEBSOCKET_0A_ONLY_WHEN_ACTIVE'&&t.restAffectsJudgment===false&&t.closeSnapshotAffectsActiveCurrentPrice===false&&h.fallbackDiagnosticOnly===true&&p.periodicFullSnapshot===false&&p.intradayRestDiagnosticEnabled===false&&m.trade==='0A'&&m.bestQuote==='0B'&&m.orderbook==='0C'&&m.program==='0u'&&m.broker==='0E'&&m.marketStatus==='0m'&&m.vi==='0w'&&Array.isArray(h.scoutRealtimeTypes)&&['0A','0C','0u'].every(x=>h.scoutRealtimeTypes.includes(x))&&h.preIgnitionPolicy?.purpose==='BEFORE_SURGE_NOT_AFTER_SURGE'&&h.preIgnitionPolicy?.liveMarketDataOnly===true&&h.preIgnitionPolicy?.lateChaseBlocked===true;console.log(ok?'OK':'BAD',JSON.stringify({version:h.version,status:h.status,realtimeTruth:t,fallbackDiagnosticOnly:h.fallbackDiagnosticOnly,typeMap:m,restPolicy:p}));process.exit(ok?0:1)}).catch(e=>{console.error(e.message);process.exit(1)})" 2>&1 || true)"
[[ "$STRICT_POLICY" == OK* ]] || fail "OFFICIAL REALTIME 정책 확인 실패: $STRICT_POLICY"
printf '%s\n' "$STRICT_POLICY"

say "KRX/NXT 이중구독 확인"
DUAL_STRUCT="$(sudo docker exec "$APP_CONTAINER" node -e "fetch('http://127.0.0.1:3000/api/health').then(r=>r.json()).then(h=>{const ok=Number(h.subscribed)>0&&Number(h.krxSubscribed)>=Number(h.subscribed)&&Number(h.nxtSubscribed)>=Number(h.subscribed)&&Number(h.wireSubscribed)>=Number(h.subscribed)*2;console.log(ok?'OK':'BAD',JSON.stringify({subscribed:h.subscribed,wire:h.wireSubscribed,krx:h.krxSubscribed,nxt:h.nxtSubscribed,registration:h.venueRegistration}));process.exit(ok?0:1)}).catch(e=>{console.error(e.message);process.exit(1)})" 2>&1 || true)"
[[ "$DUAL_STRUCT" == OK* ]] || fail "KRX/NXT 이중구독 구조 확인 실패: $DUAL_STRUCT"
printf '%s\n' "$DUAL_STRUCT"

# REG ACK는 요청수와 실제 데이터 준비상태를 구분한다. 보조 REG 일부 거절은 가격루트를 죽이지 않는다.
say "실시간 REG ACK 계보 확인"
REG_CHECK=""
for _ in $(seq 1 45); do
  REG_CHECK="$(sudo docker exec "$APP_CONTAINER" node -e "fetch('http://127.0.0.1:3000/api/health').then(r=>r.json()).then(h=>{const v=h.venueRegistration||{};const vals=Object.values(v).map(String);const pending=vals.some(x=>x==='pending');const krx=String(v.KRX_CORE_TRADE||'');const rs=h.registrationStats||{};const okKrx=krx==='ack'||krx==='live'||Number(rs.KRX?.regAccepted||0)>0;console.log(JSON.stringify({pending,okKrx,registration:v,registrationStats:rs,dataStatus:h.dataStatus}));process.exit(!okKrx?2:pending?1:0)}).catch(()=>process.exit(1))" 2>/dev/null || true)"
  [[ "$REG_CHECK" == *'"okKrx":false'* ]] && fail "KRX 핵심 0A REG ACK 실패: $REG_CHECK"
  [[ "$REG_CHECK" != *'"pending":true'* && -n "$REG_CHECK" ]] && break
  sleep 1
done
printf '%s\n' "$REG_CHECK"

# 활성장에서는 실제 WebSocket 0A fresh가 한 건도 없으면 성공 처리하지 않는다.
say "활성 거래소 WebSocket freshness 검증"
LIVE_VERIFY="$(sudo docker exec -i "$APP_CONTAINER" node - <<'NODE'
const sleep=ms=>new Promise(r=>setTimeout(r,ms));
(async()=>{
  const kst=new Date(Date.now()+9*3600e3); const dow=kst.getUTCDay(); const sec=kst.getUTCHours()*3600+kst.getUTCMinutes()*60+kst.getUTCSeconds();
  const weekday=dow>=1&&dow<=5;
  const krxActive=weekday&&sec>=9*3600&&sec<=15*3600+30*60;
  const nxtActive=weekday&&((sec>=8*3600&&sec<=8*3600+50*60)||(sec>=9*3600+30&&sec<=15*3600+20*60)||(sec>=15*3600+40*60&&sec<=20*3600));
  let last=null;
  for(let i=0;i<15;i++){
    last=await fetch('http://127.0.0.1:3000/api/health').then(r=>r.json());
    const k=Number(last.venueFeeds?.KRX?.fresh||0), n=Number(last.venueFeeds?.NXT?.fresh||0);
    if((!krxActive||k>0)&&(!nxtActive||n>0)) break;
    await sleep(3000);
  }
  const k=Number(last?.venueFeeds?.KRX?.fresh||0), n=Number(last?.venueFeeds?.NXT?.fresh||0);
  const rs=last?.registrationStats||{};
  const failed=[];
  if(krxActive&&(k<=0||Number(rs.KRX?.firstTick||0)<=0)) failed.push('KRX');
  if(nxtActive&&(n<=0||Number(rs.NXT?.firstTick||0)<=0)) failed.push('NXT');
  const status=failed.length?'FAIL':(krxActive||nxtActive?'OK':'DEFERRED');
  const routes=last?.venueRouteStats||{}; if(krxActive&&k>0&&Number(routes.KRX||0)<=0) failed.push('KRX_ROUTE'); if(nxtActive&&n>0&&Number(routes.NXT||0)<=0) failed.push('NXT_ROUTE');
  const finalStatus=failed.length?'FAIL':status;
  console.log(JSON.stringify({status:finalStatus,failed,krxActive,nxtActive,krxFresh:k,nxtFresh:n,registrationStats:rs,dataStatus:last?.dataStatus,routeStats:routes,feedReady:last?.feedReady,venueFeeds:last?.venueFeeds,socketFrameAgeMs:last?.socketFrameAgeMs,venueRecovery:last?.venueRecovery||null}));
})().catch(e=>{console.error(e.message);process.exit(1)});
NODE
)"
printf '%s\n' "$LIVE_VERIFY"
if [[ "$LIVE_VERIFY" == *'"status":"FAIL"'* ]]; then
  sudo docker logs --tail 160 "$APP_CONTAINER" || true
  fail "활성 거래소 WebSocket 0A freshness 실패: $LIVE_VERIFY"
fi

# dashboard가 활성장 전일종가/REST를 current price로 노출하거나 stale signal을 관리신호로 남기면 롤백한다.
say "Dashboard anti-stale/current-price 계보 확인"
DASH_VERIFY="$(sudo docker exec "$APP_CONTAINER" node - <<'NODE'
(async()=>{
  const r=await fetch('http://127.0.0.1:3000/api/dashboard',{headers:{Authorization:'Bearer '+process.env.APP_ACCESS_TOKEN}});
  if(!r.ok) throw new Error('dashboard HTTP '+r.status);
  const d=await r.json(); const stocks=Array.isArray(d.stocks)?d.stocks:[]; const bad=[];
  for(const s of stocks){
    if(!s.realtimeSessionActive) continue;
    if(s.realtimeEligible){
      if(!(Number(s.price)>0) || s.realtimePriceSource!=='KIWOOM_WEBSOCKET_0A' || s.dataSource!=='REALTIME_WEBSOCKET') bad.push({code:s.code,why:'eligible-route',price:s.price,source:s.dataSource,priceSource:s.realtimePriceSource});
    } else if(s.price!==null && s.price!==undefined){
      bad.push({code:s.code,why:'stale-price-visible',price:s.price,source:s.dataSource});
    }
    if(s.realtimeJudgmentPolicy!=='WEBSOCKET_ONLY') bad.push({code:s.code,why:'judgment-policy'});
  }
  const badManaged=(d.managedSignals?.rows||[]).filter(x=>!x.boughtActive && x.realtimeEligible!==true);
  if(badManaged.length) bad.push({why:'managed-stale',codes:badManaged.map(x=>x.code)});
  const ok=bad.length===0;
  console.log(ok?'OK':'BAD',JSON.stringify({stocks:stocks.length,active:stocks.filter(x=>x.realtimeSessionActive).length,eligible:stocks.filter(x=>x.realtimeEligible).length,managed:(d.managedSignals?.rows||[]).length,bad}));
  process.exit(ok?0:1);
})().catch(e=>{console.error(e.message);process.exit(1)});
NODE
 2>&1 || true)"
[[ "$DASH_VERIFY" == OK* ]] || fail "Dashboard realtime truth 검증 실패: $DASH_VERIFY"
printf '%s\n' "$DASH_VERIFY"

say "News v1.5.6 realtime discovery bridge 확인"
NEWS_BRIDGE="$(sudo docker exec "$NEWS_CONTAINER" node - <<'NODE'
(async()=>{
  const b=require('./lib/v313Bridge'); const st=b.status(); const snap=await b.getSnapshots({force:true,targets:[]});
  const rows=Array.isArray(snap.rows)?snap.rows:[]; const bad=rows.filter(r=>r.realtimeEligible && (!(Number(r.currentPrice)>0)||r.realtimePriceSource!=='KIWOOM_WEBSOCKET_0A'));
  const noLiveLeak=rows.filter(r=>!r.realtimeEligible && [r.currentPrice,r.changePct,r.foreignNet,r.institutionNet,r.programNet,r.executionStrength,r.vwap].some(v=>v!==null&&v!==undefined)).length===0;
  const ok=st.realtimeOnlyDynamic===true&&st.restFallbackDisabledForJudgment===true&&st.closingFlowDisabledForLiveJudgment===true&&bad.length===0&&noLiveLeak;
  console.log(ok?'OK':'BAD',JSON.stringify({status:st,bridgeStatus:snap.status,rows:rows.length,realtimeEligible:rows.filter(r=>r.realtimeEligible).length,bad:bad.map(r=>r.code),noLiveLeak}));
  process.exit(ok?0:1);
})().catch(e=>{console.error(e.message);process.exit(1)});
NODE
 2>&1 || true)"
[[ "$NEWS_BRIDGE" == OK* ]] || fail "News realtime bridge 검증 실패: $NEWS_BRIDGE"
printf '%s\n' "$NEWS_BRIDGE"

say "News discovery-feed 내부연결 확인"
BRIDGE_OK="$(sudo docker exec "$APP_CONTAINER" node -e "fetch('http://news-radar:3000/api/discovery-feed?limit=5',{headers:{'x-internal-bridge-token':process.env.INTERNAL_BRIDGE_TOKEN},signal:AbortSignal.timeout(7000)}).then(async r=>{await r.text();console.log(r.status);process.exit(r.ok?0:1)}).catch(e=>{console.error(e.message);process.exit(1)})" 2>/dev/null | tail -n1 || true)"
[[ "$BRIDGE_OK" == "200" ]] || fail "뉴스 discovery-feed 응답이 200이 아닙니다: $BRIDGE_OK"

say "HTTPS 프록시 재연결"
sudo docker restart "$CADDY_CONTAINER" >/dev/null 2>&1 || true

say "배포 소스/환경 보관"
rm -rf "$NEW_APP_DIR"
mkdir -p "$NEW_APP_DIR"
cp -a "$ROOT/." "$NEW_APP_DIR/"
cp "$TMP_ROOT/trader.env" "$NEW_APP_DIR/.env"
cp "$TMP_ROOT/news.env" "$NEW_APP_DIR/news.env"
chmod 600 "$NEW_APP_DIR/.env" "$NEW_APP_DIR/news.env"
if [[ -d "$OLD_APP_DIR" ]]; then cp "$TMP_ROOT/trader.env" "$OLD_APP_DIR/.env"; chmod 600 "$OLD_APP_DIR/.env"; fi

if [[ $APP_OLD_RENAMED -eq 1 ]]; then sudo docker rm "$APP_BACKUP" >/dev/null 2>&1 || true; APP_OLD_RENAMED=0; fi
if [[ $NEWS_OLD_RENAMED -eq 1 ]]; then sudo docker rm "$NEWS_BACKUP" >/dev/null 2>&1 || true; NEWS_OLD_RENAMED=0; fi
APP_NEW_STARTED=0
NEWS_NEW_STARTED=0
trap - ERR

PUBLIC_IP="$(curl -4 -fsS --max-time 15 https://api.ipify.org || true)"
DOMAIN="${PUBLIC_IP//./-}.nip.io"
printf '\n============================================================\n'
printf 'KIWOOM UNIFIED EDGE v3.2.17 REALTIME TRUTH ENGINE 설치 완료\n'
printf '공개 앱      : https://%s\n' "$DOMAIN"
printf 'Trader       : kiwoom-unified:v3.2.17\n'
printf 'News         : v1.5.6 ROTATION PICKS / discovery-only realtime bridge\n'
printf '현재가 기준  : 활성장 Kiwoom WebSocket 0A ONLY\n'
printf '판단 기준    : 체결0A·호가잔량0C·프로그램0u·거래원0E 실시간만 동적판정\n'
printf 'REST 역할    : 후보 DISCOVERY / 공식 종가·과거기준 ONLY (장중 신규진입 판정 미사용)\n'
printf '오류 방지    : 0A 미수신 시 현재가 공란 + 신규 EARLY/PRE-BUY/BUY 보류\n'
printf 'News v1.5.6  : ROTATION PICKS + 3/5일 섹터예측, 실시간 표본 부족 시 추천보류\n'
printf '============================================================\n'
printf '앱 건강상태: '; cat "$TMP_ROOT/app-health.json"; printf '\n'
printf '뉴스 건강상태: '; cat "$TMP_ROOT/news-health.json"; printf '\n'
printf '\nSafari/PWA를 완전히 닫았다가 다시 열고 상단 v3.2.17를 확인하세요. 장중에는 카드의 실시간 0A 수신시각도 함께 확인하세요.\n'
