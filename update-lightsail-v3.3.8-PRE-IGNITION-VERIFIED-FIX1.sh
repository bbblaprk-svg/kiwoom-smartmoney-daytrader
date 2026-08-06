#!/usr/bin/env bash
set -Eeuo pipefail

REPO_URL="https://github.com/bbblaprk-svg/kiwoom-smartmoney-daytrader.git"
ZIP_NAME="kiwoom-unified-edge-v3.3.8-PRE-IGNITION-VERIFIED.zip"
SOURCE_DIR_NAME="kiwoom-unified-edge-v3.3.8"
EXPECTED_ZIP_SHA256="d26cef61583666f4ed615647ba3724f0ed0f5b460e1ee72c3b52fefd414cffeb"
OLD_APP_DIR="$HOME/kiwoom-smartmoney-daytrader"
NEW_APP_DIR="$HOME/kiwoom-unified-edge"
TRADER_IMAGE="kiwoom-unified:v3.3.8"
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
APP_OLD_RENAMED=0; NEWS_OLD_RENAMED=0; APP_NEW_STARTED=0; NEWS_NEW_STARTED=0

say(){ printf '\n==> %s\n' "$*"; }
fail(){ printf '\n[오류] %s\n' "$*" >&2; exit 1; }
cleanup(){ rm -rf "$TMP_ROOT"; }
rollback(){
  local ec=$?; [[ $ec -eq 0 ]] && return
  printf '\n[자동복구] v3.3.8 PRE-IGNITION TRUTH RANKING 검증 실패 — 기존 컨테이너로 복구합니다.\n' >&2
  [[ $APP_NEW_STARTED -eq 1 ]] && sudo docker rm -f "$APP_CONTAINER" >/dev/null 2>&1 || true
  [[ $NEWS_NEW_STARTED -eq 1 ]] && sudo docker rm -f "$NEWS_CONTAINER" >/dev/null 2>&1 || true
  if [[ $APP_OLD_RENAMED -eq 1 ]]; then sudo docker rename "$APP_BACKUP" "$APP_CONTAINER" >/dev/null 2>&1 || true; sudo docker start "$APP_CONTAINER" >/dev/null 2>&1 || true; fi
  if [[ $NEWS_OLD_RENAMED -eq 1 ]]; then sudo docker rename "$NEWS_BACKUP" "$NEWS_CONTAINER" >/dev/null 2>&1 || true; sudo docker start "$NEWS_CONTAINER" >/dev/null 2>&1 || true; fi
  sudo docker restart "$CADDY_CONTAINER" >/dev/null 2>&1 || true
}
trap cleanup EXIT
trap rollback ERR
[[ "$(id -u)" -ne 0 ]] || fail "root가 아닌 ubuntu 사용자로 실행하세요."

say "필수 도구/디스크 확인"
sudo apt-get update -qq
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y git docker.io curl ca-certificates unzip openssl python3 >/dev/null
sudo systemctl enable --now docker
sudo docker builder prune -f --filter 'until=24h' >/dev/null 2>&1 || true
sudo docker image prune -f >/dev/null 2>&1 || true
AVAIL_KB="$(df -Pk / | awk 'NR==2{print $4}')"
[[ "${AVAIL_KB:-0}" -ge 3145728 ]] || fail "Docker/Next 빌드용 디스크 여유가 3GiB 미만입니다."
df -h /

ENV_SOURCE=""
if [[ -f "$NEW_APP_DIR/.env" ]]; then ENV_SOURCE="$NEW_APP_DIR/.env"
elif [[ -f "$OLD_APP_DIR/.env" ]]; then ENV_SOURCE="$OLD_APP_DIR/.env"
else fail "기존 앱 .env를 찾지 못했습니다."
fi
cp "$ENV_SOURCE" "$TMP_ROOT/trader.env"; chmod 600 "$TMP_ROOT/trader.env"

say "v3.3.8 PRE-IGNITION TRUTH RANKING 파일 받기"
git clone --depth 1 "$REPO_URL" "$TMP_ROOT/repo" >/dev/null
cd "$TMP_ROOT/repo"
[[ -f "$ZIP_NAME" ]] || fail "GitHub 최상위에 $ZIP_NAME 파일이 없습니다."
ACTUAL_SHA="$(sha256sum "$ZIP_NAME" | awk '{print $1}')"
[[ "$ACTUAL_SHA" == "$EXPECTED_ZIP_SHA256" ]] || fail "ZIP SHA256 불일치: 예상=$EXPECTED_ZIP_SHA256 실제=$ACTUAL_SHA"

say "ZIP/manifest/registration layer 검증"
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
[[ "$TRADER_VERSION" == "3.3.8" ]] || fail "trader 버전 불일치: $TRADER_VERSION"
[[ "$NEWS_VERSION" == "1.5.6" ]] || fail "news 버전 불일치: $NEWS_VERSION"
grep -Fq "KRX_TRADE_BARE_0B" "$ROOT/trader/worker/kiwoomRealtime.js" || fail "KRX bare 0B REG 누락"
grep -Fq "NXT_TRADE_SUFFIX_0B" "$ROOT/trader/worker/kiwoomRealtime.js" || fail "NXT _NX 0B REG 누락"
grep -Fq 'const nxtWire = baseCodes.map((code) => `${code}_NX`)' "$ROOT/trader/worker/kiwoomRealtime.js" || fail "NXT suffix wire 생성 누락"
grep -Fq "CORE_TRADE_NXT" "$ROOT/trader/worker/kiwoomRealtime.js" || fail "NXT CORE ACK 계층 누락"
grep -Fq "KRX_BARE_PLUS_NXT_SUFFIX_0B_V337" "$ROOT/trader/worker/kiwoomRealtime.js" || fail "v3.3.8 기반 REG mode 누락"
grep -Fq "REAL_0B_FID9081_ONLY" "$ROOT/trader/worker/kiwoomRealtime.js" || fail "FID9081 truth policy 누락"
! grep -Eq "stex_tp[[:space:]]*:" "$ROOT/trader/worker/kiwoomRealtime.js" || fail "국내 WebSocket에 stex_tp item-map 혼입"
grep -Fq "급등 '이후' 추격보다 급등 '전' 사전포착" "$ROOT/trader/lib/recommendationEngine.js" || fail "v3.3.8 사전포착 점수정책 누락"
grep -Fq "DISCOVERY_SNAPSHOT_ONLY" "$ROOT/trader/lib/recommendationEngine.js" || fail "REST 발굴시 snapshot 분리 누락"
grep -Fq "KIWOOM_WEBSOCKET_TRADE_AUTO" "$ROOT/trader/lib/recommendationEngine.js" || fail "실시간 현재등락 truth source 누락"
grep -Fq "장중 사전포착 8 · 급등 전 현재강도" "$ROOT/trader/pages/index.js" || fail "v3.3.8 사전포착 UI 누락"

read_env_value(){ local key="$1"; sed -n "s/^${key}=//p" "$TMP_ROOT/trader.env" | tail -n1; }
upsert_env(){ local key="$1" value="$2"; if grep -q "^${key}=" "$TMP_ROOT/trader.env"; then sed -i "s#^${key}=.*#${key}=${value}#" "$TMP_ROOT/trader.env"; else printf '%s=%s\n' "$key" "$value" >> "$TMP_ROOT/trader.env"; fi; }
ensure_env(){ local key="$1" value="$2"; grep -q "^${key}=" "$TMP_ROOT/trader.env" || printf '%s=%s\n' "$key" "$value" >> "$TMP_ROOT/trader.env"; }
ACCESS_TOKEN="$(read_env_value APP_ACCESS_TOKEN)"; SESSION_SECRET="$(read_env_value APP_SESSION_SECRET)"
[[ ${#ACCESS_TOKEN} -ge 8 ]] || fail "APP_ACCESS_TOKEN 누락"
[[ ${#SESSION_SECRET} -ge 32 ]] || fail "APP_SESSION_SECRET 누락"
INTERNAL_TOKEN="$(read_env_value INTERNAL_BRIDGE_TOKEN)"; [[ ${#INTERNAL_TOKEN} -ge 32 ]] || INTERNAL_TOKEN="$(openssl rand -hex 32)"
upsert_env INTERNAL_BRIDGE_TOKEN "$INTERNAL_TOKEN"
upsert_env NEWS_RADAR_BASE_URL http://news-radar:3000
upsert_env KIWOOM_REALTIME_ENABLED true
upsert_env KIWOOM_WS_URL wss://api.kiwoom.com:10000/api/dostk/websocket
upsert_env KIWOOM_INTRADAY_REST_DIAGNOSTIC false
upsert_env KIWOOM_WATCHDOG_INTERVAL_MS 1000
upsert_env KIWOOM_SOCKET_WATCHDOG_MS 20000
upsert_env KIWOOM_VENUE_STALE_MS 5000
upsert_env REALTIME_JUDGMENT_MAX_AGE_MS 2000
upsert_env REALTIME_DISPLAY_MAX_AGE_MS 10000
upsert_env HOST 0.0.0.0; upsert_env PORT 3000
ensure_env NEWS_DISCOVERY_CACHE_MS 30000
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
for key in NAVER_CLIENT_ID NAVER_CLIENT_SECRET DART_API_KEY FINNHUB_API_KEY RSS_FEED_URLS; do val="$(read_env_value "$key")"; [[ -z "$val" ]] || printf '%s=%s\n' "$key" "$val" >> "$TMP_ROOT/news.env"; done
chmod 600 "$TMP_ROOT/news.env"

say "Docker build — npm check/load/build gate 포함"
sudo docker build --pull -t "$NEWS_IMAGE" "$ROOT/news-radar"
sudo docker build --pull -t "$TRADER_IMAGE" "$ROOT/trader"
sudo docker network inspect "$DOCKER_NETWORK" >/dev/null 2>&1 || sudo docker network create "$DOCKER_NETWORK" >/dev/null
sudo docker volume inspect "$TRADER_DATA_VOLUME" >/dev/null 2>&1 || sudo docker volume create "$TRADER_DATA_VOLUME" >/dev/null
sudo docker volume inspect "$NEWS_DATA_VOLUME" >/dev/null 2>&1 || sudo docker volume create "$NEWS_DATA_VOLUME" >/dev/null

if sudo docker container inspect "$APP_CONTAINER" >/dev/null 2>&1; then sudo docker stop "$APP_CONTAINER" >/dev/null; sudo docker rename "$APP_CONTAINER" "$APP_BACKUP"; APP_OLD_RENAMED=1; fi
if sudo docker container inspect "$NEWS_CONTAINER" >/dev/null 2>&1; then sudo docker stop "$NEWS_CONTAINER" >/dev/null; sudo docker rename "$NEWS_CONTAINER" "$NEWS_BACKUP"; NEWS_OLD_RENAMED=1; fi

say "News Radar 실행"
sudo docker run -d --name "$NEWS_CONTAINER" --restart unless-stopped --network "$DOCKER_NETWORK" --env-file "$TMP_ROOT/news.env" -v "$NEWS_DATA_VOLUME:/app/data" -p 127.0.0.1:3100:3000 "$NEWS_IMAGE" >/dev/null; NEWS_NEW_STARTED=1
say "Trader v3.3.8 실행"
sudo docker run -d --name "$APP_CONTAINER" --restart unless-stopped --network "$DOCKER_NETWORK" --env-file "$TMP_ROOT/trader.env" -v "$TRADER_DATA_VOLUME:/app/data" -p 127.0.0.1:3000:3000 "$TRADER_IMAGE" >/dev/null; APP_NEW_STARTED=1
for _ in $(seq 1 90); do curl -fsS --max-time 3 http://127.0.0.1:3000/api/health > "$TMP_ROOT/health.json" 2>/dev/null && break; sleep 2; done
[[ -s "$TMP_ROOT/health.json" ]] || { sudo docker logs --tail 200 "$APP_CONTAINER" || true; fail "Trader health 실패"; }
RUNNING_VERSION="$(sudo docker exec "$APP_CONTAINER" node -p "require('./package.json').version")"
[[ "$RUNNING_VERSION" == "3.3.8" ]] || fail "실행 버전 불일치: $RUNNING_VERSION"

say "실제 수신 검증 — KRX bare ACK + NXT suffix ACK + FID9081 NXT firstTick/fresh (최대 90초)"
RUNTIME_OK=0
for _ in $(seq 1 30); do
  OUT="$(curl -fsS --max-time 3 http://127.0.0.1:3000/api/health 2>/dev/null || true)"
  [[ -z "$OUT" ]] || printf '%s' "$OUT" > "$TMP_ROOT/health.json"
  CHECK="$(python3 - "$TMP_ROOT/health.json" <<'PYCHK'
import json,sys
h=json.load(open(sys.argv[1])); r=h.get('registrationStats') or {}; exp=h.get('expectedVenues') or []
d=r.get('DOMESTIC') or {}; nreg=r.get('NXT_SUFFIX') or {}; k=r.get('KRX') or {}; n=r.get('NXT') or {}
dack=int(d.get('regAccepted') or 0); nack=int(nreg.get('regAccepted') or 0)
kfirst=int(k.get('firstTick') or 0); kfresh=int(k.get('fresh') or 0)
nfirst=int(n.get('firstTick') or 0); nfresh=int(n.get('fresh') or 0); nconf=bool(n.get('venueConfirmed'))
need_nxt='NXT' in exp
ok=h.get('status')=='connected' and dack>0 and (not need_nxt or (nack>0 and nfirst>0 and nfresh>0 and nconf))
print(('OK' if ok else 'WAIT'), f'DOMESTIC_ACK={dack}', f'NXT_SUFFIX_ACK={nack}', f'KRX={kfirst}/{kfresh}', f'NXT={nfirst}/{nfresh}/confirmed={nconf}', 'expected='+','.join(exp), 'dataStatus='+str(h.get('dataStatus')))
PYCHK
)"
  echo "$CHECK"
  [[ "$CHECK" == OK* ]] && { RUNTIME_OK=1; break; }
  sleep 3
done
if [[ $RUNTIME_OK -ne 1 ]]; then
  echo "=== V3.3.8 FAILURE DIAGNOSTIC ==="
  cat "$TMP_ROOT/health.json" || true
  curl -s "http://127.0.0.1:3000/api/realtime-debug?limit=20" || true
  sudo docker logs --tail 240 "$APP_CONTAINER" || true
  fail "NXT _NX REG 또는 실제 FID9081=NXT 체결 검증 실패 — 기존 컨테이너로 자동 롤백합니다."
fi

say "배포 성공 — NXT 실제 수신 확인"
if [[ $APP_OLD_RENAMED -eq 1 ]]; then sudo docker rm -f "$APP_BACKUP" >/dev/null 2>&1 || true; APP_OLD_RENAMED=0; fi
if [[ $NEWS_OLD_RENAMED -eq 1 ]]; then sudo docker rm -f "$NEWS_BACKUP" >/dev/null 2>&1 || true; NEWS_OLD_RENAMED=0; fi
trap - ERR

echo "=== FINAL ==="
sudo docker inspect "$APP_CONTAINER" --format='IMAGE={{.Config.Image}} STATUS={{.State.Status}} STARTED={{.State.StartedAt}}'
curl -s http://127.0.0.1:3000/api/health | python3 -c 'import sys,json; h=json.load(sys.stdin); print("version=",h.get("version")); print("status=",h.get("status")); print("dataStatus=",h.get("dataStatus")); print("registrationStats=",h.get("registrationStats")); print("venueFeeds=",h.get("venueFeeds"))'
echo "=== REALTIME DEBUG SUMMARY ==="
curl -s "http://127.0.0.1:3000/api/realtime-debug?limit=5" | python3 -c 'import sys,json; d=json.load(sys.stdin); print("version=",d.get("version")); print("detectedTradeType=",d.get("detectedTradeType")); print("byType=",d.get("byType")); print("itemSuffix=",d.get("itemSuffix")); print("marketHints=",d.get("marketHints")); print("samples=",len(d.get("samples") or []))'
