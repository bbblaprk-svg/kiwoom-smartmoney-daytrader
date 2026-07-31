#!/usr/bin/env bash
set -Eeuo pipefail

REPO_URL="https://github.com/bbblaprk-svg/kiwoom-smartmoney-daytrader.git"
APP_DIR="$HOME/kiwoom-smartmoney-daytrader"
IMAGE_NAME="kiwoom-smartmoney:v3.1.0"
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
  printf '\n[자동 복구] v3.1.0 적용 실패 — 기존 앱으로 되돌립니다.\n' >&2
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
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y git docker.io curl ca-certificates >/dev/null
sudo systemctl enable --now docker

[[ -f "$APP_DIR/.env" ]] || fail "기존 $APP_DIR/.env가 없습니다. APP KEY를 보존한 설치 서버에서 실행하세요."
cp "$APP_DIR/.env" "$TMP_ROOT/original.env"
chmod 600 "$TMP_ROOT/original.env"

say "v3.1.0 파일 받기"
git clone --depth 1 "$REPO_URL" "$TMP_ROOT/repo"
cd "$TMP_ROOT/repo"
[[ -f Dockerfile ]] || fail "GitHub 최상위에 Dockerfile이 없습니다."
[[ -f kiwoom-smartmoney-daytrader-v3.1.0.zip ]] || fail "GitHub 최상위에 v3.1.0 ZIP이 없습니다."
cp "$TMP_ROOT/original.env" .env

upsert_env() {
  local key="$1" value="$2"
  if grep -q "^${key}=" .env; then
    sed -i "s#^${key}=.*#${key}=${value}#" .env
  else
    printf '%s=%s\n' "$key" "$value" >> .env
  fi
}
upsert_env KIWOOM_DAILY_CHART_API_ID ka10081
upsert_env MARKET_SNAPSHOT_INTERVAL_MS 900000
upsert_env STORE_FILE_PATH /app/data/store.json
upsert_env HOST 0.0.0.0
upsert_env PORT 3000
chmod 600 .env

say "v3.1.0 Docker 이미지 빌드 — 5~15분 걸릴 수 있습니다"
sudo docker build --pull -t "$IMAGE_NAME" .

say "데이터 볼륨과 네트워크 준비"
sudo docker network inspect "$DOCKER_NETWORK" >/dev/null 2>&1 || sudo docker network create "$DOCKER_NETWORK" >/dev/null
sudo docker volume inspect "$DATA_VOLUME" >/dev/null 2>&1 || sudo docker volume create "$DATA_VOLUME" >/dev/null

if sudo docker container inspect "$APP_CONTAINER" >/dev/null 2>&1; then
  say "기존 앱을 롤백용으로 보관"
  sudo docker stop "$APP_CONTAINER" >/dev/null
  sudo docker rename "$APP_CONTAINER" "$BACKUP_CONTAINER"
  OLD_RENAMED=1
fi

say "v3.1.0 앱 실행"
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
  sudo docker logs --tail 100 "$APP_CONTAINER" || true
  fail "새 앱의 /api/health 응답을 확인하지 못했습니다."
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
printf 'v3.1.0 업데이트 완료\n'
printf '앱 주소   : https://%s\n' "$DOMAIN"
printf '상태 확인 : https://%s/api/health\n' "$DOMAIN"
printf '============================================================\n'
printf '현재 건강상태: '
cat "$TMP_ROOT/health.json"
printf '\n\n최근 앱 로그:\n'
sudo docker logs --tail 40 "$APP_CONTAINER" || true
printf '\n앱에서 “종가 동기화”를 누르고 KRX 종가·NXT 최종가·종가판단을 확인하세요.\n'
