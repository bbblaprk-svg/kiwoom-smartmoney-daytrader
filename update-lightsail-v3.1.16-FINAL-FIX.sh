#!/usr/bin/env bash
set -Eeuo pipefail

REPO_URL="https://github.com/bbblaprk-svg/kiwoom-smartmoney-daytrader.git"
APP_DIR="$HOME/kiwoom-smartmoney-daytrader"
ZIP_NAME="kiwoom-smartmoney-daytrader-v3.1.16-FINAL.zip"
SOURCE_DIR_NAME="kiwoom-smartmoney-daytrader-v3.1.16"
EXPECTED_ZIP_SHA256="4bd92a3c8c3f8b6e85257ab151bb25a1e2f31999fb55fc1bda46183b507d3df8"
IMAGE_NAME="kiwoom-smartmoney:v3.1.16"
APP_CONTAINER="kiwoom-app"
CADDY_CONTAINER="kiwoom-caddy"
DOCKER_NETWORK="kiwoom-net"
DATA_VOLUME="kiwoom-data"
TMP_ROOT="$(mktemp -d)"
BACKUP_CONTAINER="${APP_CONTAINER}-backup-$(date +%Y%m%d%H%M%S)"
NEW_STARTED=0
OLD_RENAMED=0

say() { printf '\n==> %s\n' "$*"; }
fail() { printf '\n[오류] %s\n' "$*" >&2; exit 1; }
cleanup() { rm -rf "$TMP_ROOT"; }
trap cleanup EXIT

rollback() {
  local exit_code=$?
  if [[ $exit_code -eq 0 ]]; then return; fi
  printf '\n[자동 복구] v3.1.16 적용 실패 — 기존 앱으로 되돌립니다.\n' >&2
  if [[ $NEW_STARTED -eq 1 ]]; then sudo docker rm -f "$APP_CONTAINER" >/dev/null 2>&1 || true; fi
  if [[ $OLD_RENAMED -eq 1 ]]; then
    sudo docker rename "$BACKUP_CONTAINER" "$APP_CONTAINER" >/dev/null 2>&1 || true
    sudo docker start "$APP_CONTAINER" >/dev/null 2>&1 || true
  fi
  sudo docker restart "$CADDY_CONTAINER" >/dev/null 2>&1 || true
  printf '[자동 복구] 기존 앱 복구를 시도했습니다.\n' >&2
}
trap rollback ERR

if [[ "$(id -u)" -eq 0 ]]; then fail "root가 아닌 기본 ubuntu 사용자로 실행하세요."; fi

say "필수 도구 확인"
sudo apt-get update -qq
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y git docker.io curl ca-certificates unzip >/dev/null
sudo systemctl enable --now docker

[[ -f "$APP_DIR/.env" ]] || fail "기존 $APP_DIR/.env가 없습니다. 기존 설치 서버에서 실행하세요."
cp "$APP_DIR/.env" "$TMP_ROOT/original.env"
chmod 600 "$TMP_ROOT/original.env"

say "v3.1.16 FINAL 파일 받기"
git clone --depth 1 "$REPO_URL" "$TMP_ROOT/repo"
cd "$TMP_ROOT/repo"
[[ -f "$ZIP_NAME" ]] || fail "GitHub 최상위에 $ZIP_NAME 파일이 없습니다."
ACTUAL_ZIP_SHA256="$(sha256sum "$ZIP_NAME" | awk '{print $1}')"
if [[ "$ACTUAL_ZIP_SHA256" != "$EXPECTED_ZIP_SHA256" ]]; then
  printf "[오류] GitHub ZIP이 최신 v3.1.16 수정본이 아닙니다.\n예상 SHA256: %s\n실제 SHA256: %s\n" "$EXPECTED_ZIP_SHA256" "$ACTUAL_ZIP_SHA256" >&2
  fail "GitHub의 $ZIP_NAME 파일을 최신 수정본으로 다시 업로드하세요."
fi
cp "$TMP_ROOT/original.env" .env

read_env_value() {
  local key="$1"
  sed -n "s/^${key}=//p" .env | tail -n 1
}
ACCESS_TOKEN_VALUE="$(read_env_value APP_ACCESS_TOKEN)"
SESSION_SECRET_VALUE="$(read_env_value APP_SESSION_SECRET)"
[[ ${#ACCESS_TOKEN_VALUE} -ge 8 ]] || fail "APP_ACCESS_TOKEN이 없거나 8자 미만입니다. 기존 .env를 먼저 수정하세요."
[[ ${#SESSION_SECRET_VALUE} -ge 32 ]] || fail "APP_SESSION_SECRET이 없거나 32자 미만입니다. 기존 .env를 먼저 수정하세요."
[[ "$ACCESS_TOKEN_VALUE" != "$SESSION_SECRET_VALUE" ]] || fail "APP_ACCESS_TOKEN과 APP_SESSION_SECRET은 서로 달라야 합니다."
unset ACCESS_TOKEN_VALUE SESSION_SECRET_VALUE

upsert_env() {
  local key="$1" value="$2"
  if grep -q "^${key}=" .env; then
    sed -i "s#^${key}=.*#${key}=${value}#" .env
  else
    printf '%s=%s\n' "$key" "$value" >> .env
  fi
}
ensure_env_default() {
  local key="$1" value="$2"
  grep -q "^${key}=" .env || printf '%s=%s\n' "$key" "$value" >> .env
}

# Kiwoom REST/WebSocket 주소, TR/FID, 앱키/시크릿 등 기존 데이터수신 환경값은 덮어쓰지 않는다.
# v3.1.16 변경의 중심은 판정 후 표시·기록·알림이다.
upsert_env MAX_FOCUS_USER_STOCKS 8
upsert_env MAX_LIGHT_USER_STOCKS 8
upsert_env DAILY_RECOMMENDATIONS_ENABLED true
ensure_env_default INTRADAY_RECOMMENDATION_MIN_REFRESH_MS 60000
ensure_env_default POST_PROCESS_CONCURRENCY 4
ensure_env_default STORE_CACHE_TTL_MS 30000
ensure_env_default ALERT_BATCH_MS 750
ensure_env_default POSITION_BATCH_MS 750
ensure_env_default LEDGER_BATCH_MS 5000
ensure_env_default SHADOW_LEDGER_BATCH_MS 5000
upsert_env HOST 0.0.0.0
upsert_env PORT 3000
chmod 600 .env

say "배포 ZIP 무결성 확인"
mkdir -p "$TMP_ROOT/verify"
unzip -q "$ZIP_NAME" -d "$TMP_ROOT/verify"
[[ -d "$TMP_ROOT/verify/$SOURCE_DIR_NAME" ]] || fail "ZIP 내부 최상위 폴더가 $SOURCE_DIR_NAME이 아닙니다."
(
  cd "$TMP_ROOT/verify/$SOURCE_DIR_NAME"
  [[ -f SOURCE_MANIFEST.sha256 ]] || fail "SOURCE_MANIFEST.sha256이 없습니다."
  sha256sum -c SOURCE_MANIFEST.sha256 >/dev/null
  PACKAGE_VERSION="$(sed -n 's/.*"version"[[:space:]]*:[[:space:]]*"\([^" ]*\)".*/\1/p' package.json | head -n1)"
  [[ "$PACKAGE_VERSION" == "3.1.16" ]] || fail "ZIP 내부 package.json 버전이 3.1.16이 아닙니다: ${PACKAGE_VERSION:-미확인}"
)

BUILD_CONTEXT="$TMP_ROOT/build-context"
mkdir -p "$BUILD_CONTEXT"
cp "$ZIP_NAME" "$BUILD_CONTEXT/$ZIP_NAME"
cat > "$BUILD_CONTEXT/Dockerfile" <<'DOCKER'
FROM node:22-alpine AS build
LABEL org.opencontainers.image.version="3.1.16"
RUN apk add --no-cache unzip
WORKDIR /app
ENV NEXT_TELEMETRY_DISABLED=1
COPY kiwoom-smartmoney-daytrader-v3.1.16-FINAL.zip /tmp/app.zip
RUN mkdir -p /tmp/source \
    && unzip -q /tmp/app.zip -d /tmp/source \
    && cp -a /tmp/source/kiwoom-smartmoney-daytrader-v3.1.16/. /app/ \
    && rm -rf /tmp/app.zip /tmp/source
RUN sha256sum -c SOURCE_MANIFEST.sha256
RUN npm config set registry https://registry.npmjs.org/ \
    && npm install --no-audit --no-fund
RUN npm run check \
    && LOAD_TEST_SYMBOLS=20 LOAD_TEST_TICKS=20000 npm run check:load \
    && npm run build

FROM node:22-alpine AS runtime
WORKDIR /app
ENV NODE_ENV=production
ENV NEXT_TELEMETRY_DISABLED=1
RUN mkdir -p /app/data
COPY --from=build /app/package.json ./package.json
COPY --from=build /app/node_modules ./node_modules
COPY --from=build /app/.next ./.next
COPY --from=build /app/public ./public
COPY --from=build /app/server.js ./server.js
COPY --from=build /app/next.config.js ./next.config.js
COPY --from=build /app/lib ./lib
COPY --from=build /app/worker ./worker
COPY --from=build /app/pages ./pages
VOLUME ["/app/data"]
EXPOSE 3000
CMD ["npm", "start"]
DOCKER

say "v3.1.16 Docker 이미지 빌드 — 전체검사·20종목 부하검사·Next 빌드 포함"
sudo docker build --pull -t "$IMAGE_NAME" "$BUILD_CONTEXT"

say "데이터 볼륨과 네트워크 준비"
sudo docker network inspect "$DOCKER_NETWORK" >/dev/null 2>&1 || sudo docker network create "$DOCKER_NETWORK" >/dev/null
sudo docker volume inspect "$DATA_VOLUME" >/dev/null 2>&1 || sudo docker volume create "$DATA_VOLUME" >/dev/null

if sudo docker container inspect "$APP_CONTAINER" >/dev/null 2>&1; then
  say "기존 앱을 롤백용으로 보관"
  sudo docker stop "$APP_CONTAINER" >/dev/null
  sudo docker rename "$APP_CONTAINER" "$BACKUP_CONTAINER"
  OLD_RENAMED=1
fi

say "v3.1.16 앱 실행"
sudo docker run -d \
  --name "$APP_CONTAINER" \
  --restart unless-stopped \
  --network "$DOCKER_NETWORK" \
  --env-file "$TMP_ROOT/repo/.env" \
  -v "$DATA_VOLUME:/app/data" \
  -p 127.0.0.1:3000:3000 \
  "$IMAGE_NAME" >/dev/null
NEW_STARTED=1

say "로컬 건강검사"
HEALTH_OK=0
for _ in $(seq 1 90); do
  if curl -fsS --max-time 5 http://127.0.0.1:3000/api/health >"$TMP_ROOT/health.json" 2>/dev/null; then
    if grep -q '"serverTime"' "$TMP_ROOT/health.json"; then HEALTH_OK=1; break; fi
  fi
  sleep 2
done
if [[ $HEALTH_OK -ne 1 ]]; then
  sudo docker logs --tail 180 "$APP_CONTAINER" || true
  fail "새 앱의 /api/health 응답을 확인하지 못했습니다."
fi

RUNNING_VERSION="$(sudo docker exec "$APP_CONTAINER" node -p "require('./package.json').version" 2>/dev/null || true)"
[[ "$RUNNING_VERSION" == "3.1.16" ]] || fail "실행 컨테이너 버전이 3.1.16이 아닙니다: $RUNNING_VERSION"

if grep -q '"status":"connected"' "$TMP_ROOT/health.json"; then
  say "Kiwoom 연결상태 connected 확인"
else
  printf '[주의] 앱 서버/버전은 정상 기동했지만 Kiwoom 연결은 아직 connected가 아닙니다. 점검시간/인증/네트워크를 /api/health에서 확인하세요.\n' >&2
fi

say "HTTPS 프록시 재연결"
sudo docker restart "$CADDY_CONTAINER" >/dev/null 2>&1 || true

say "새 소스와 환경설정 보관"
rm -rf "$APP_DIR"
mv "$TMP_ROOT/repo" "$APP_DIR"
chmod 600 "$APP_DIR/.env"

if [[ $OLD_RENAMED -eq 1 ]]; then
  sudo docker rm "$BACKUP_CONTAINER" >/dev/null 2>&1 || true
  OLD_RENAMED=0
fi
NEW_STARTED=0
trap - ERR

PUBLIC_IP="$(curl -4 -fsS --max-time 15 https://api.ipify.org || true)"
DOMAIN="${PUBLIC_IP//./-}.nip.io"
printf '\n============================================================\n'
printf 'v3.1.16 PROFIT FOCUS 업데이트 완료\n'
printf '앱 주소   : https://%s\n' "$DOMAIN"
printf '상태 확인 : https://%s/api/health\n' "$DOMAIN"
printf '감시 구조 : 고정4 + 사용자집중8 + 경량8 = 최대 20종목\n'
printf '핵심목적  : 상승초입 EARLY → 급등 사전포착 → 엄격한 BUY 선별\n'
printf '매도잡음  : 일반 감시종목 RISK/EARLY_SELL/SELL 표시·푸시 제거\n'
printf '보유관리  : 실제 보유종목의 설정 손절가 도달만 1회 알림\n'
printf '알림정책  : 확정 BUY + 실제 보유 STOP만 푸시\n'
printf '추천기능  : 일일 8+8 / 장중 강한종목 8+8 / 수동보호 / 자동적용 ON/OFF 유지\n'
printf '화면안정  : 1.5초 묶음표시 + 같은 단계 점수변화로 카드 위치 변경 억제\n'
printf '============================================================\n'
printf '현재 건강상태: '
cat "$TMP_ROOT/health.json"
printf '\n\n최근 앱 로그:\n'
sudo docker logs --tail 60 "$APP_CONTAINER" || true
printf '\nSafari/PWA를 완전히 닫았다가 다시 열고 화면 상단 v3.1.16을 확인하세요.\n'
printf 'subscribed 값은 현재 실제 등록 종목 수이며 최대 20입니다.\n'
