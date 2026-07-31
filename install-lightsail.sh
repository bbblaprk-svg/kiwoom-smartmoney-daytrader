#!/usr/bin/env bash
set -Eeuo pipefail

REPO_URL="https://github.com/bbblaprk-svg/kiwoom-smartmoney-daytrader.git"
APP_DIR="$HOME/kiwoom-smartmoney-daytrader"
IMAGE_NAME="kiwoom-smartmoney:v3"
APP_CONTAINER="kiwoom-app"
CADDY_CONTAINER="kiwoom-caddy"
DOCKER_NETWORK="kiwoom-net"

say() { printf '\n==> %s\n' "$*"; }
fail() { printf '\n[오류] %s\n' "$*" >&2; exit 1; }

if [[ "$(id -u)" -eq 0 ]]; then
  fail "root가 아닌 기본 ubuntu 사용자로 실행하세요."
fi

say "필수 프로그램 설치"
sudo apt-get update
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y git docker.io curl openssl ca-certificates
sudo systemctl enable --now docker

say "1GB 서버용 2GB 스왑 준비"
if ! sudo swapon --show=NAME --noheadings | grep -qx '/swapfile'; then
  if [[ ! -f /swapfile ]]; then
    sudo fallocate -l 2G /swapfile || sudo dd if=/dev/zero of=/swapfile bs=1M count=2048 status=progress
  fi
  sudo chmod 600 /swapfile
  sudo mkswap /swapfile >/dev/null
  sudo swapon /swapfile
  grep -q '^/swapfile ' /etc/fstab || echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab >/dev/null
fi

say "앱 파일 받기"
rm -rf "$APP_DIR"
git clone --depth 1 "$REPO_URL" "$APP_DIR"
cd "$APP_DIR"
[[ -f Dockerfile ]] || fail "GitHub 저장소 최상위에 Dockerfile이 없습니다."
[[ -f kiwoom-smartmoney-daytrader-v3.0.0.zip ]] || fail "앱 ZIP 파일이 없습니다."

printf '\n아래 세 값은 GitHub에 저장되지 않고 이 서버의 .env에만 보관됩니다.\n'
read -r -s -p '키움 APP KEY 입력: ' KIWOOM_APP_KEY </dev/tty; echo
read -r -s -p '키움 APP SECRET 입력: ' KIWOOM_APP_SECRET </dev/tty; echo
read -r -s -p '앱 접속 비밀번호 입력: ' APP_ACCESS_TOKEN </dev/tty; echo

[[ -n "$KIWOOM_APP_KEY" ]] || fail "APP KEY가 비어 있습니다."
[[ -n "$KIWOOM_APP_SECRET" ]] || fail "APP SECRET이 비어 있습니다."
[[ ${#APP_ACCESS_TOKEN} -ge 8 ]] || fail "앱 접속 비밀번호는 8자 이상으로 입력하세요."

APP_SESSION_SECRET="$(openssl rand -hex 48)"
cat > .env <<EOF_ENV
KIWOOM_APP_KEY=$KIWOOM_APP_KEY
KIWOOM_APP_SECRET=$KIWOOM_APP_SECRET
KIWOOM_BASE_URL=https://api.kiwoom.com
KIWOOM_WS_URL=wss://api.kiwoom.com:10000/api/dostk/websocket
KIWOOM_REALTIME_ENABLED=true
MAX_FOCUS_USER_STOCKS=4
MAX_LIGHT_USER_STOCKS=4
APP_ACCESS_TOKEN=$APP_ACCESS_TOKEN
APP_SESSION_SECRET=$APP_SESSION_SECRET
STORE_CACHE_TTL_MS=30000
HOST=0.0.0.0
PORT=3000
EOF_ENV
chmod 600 .env
unset KIWOOM_APP_KEY KIWOOM_APP_SECRET APP_ACCESS_TOKEN APP_SESSION_SECRET

say "Docker 이미지 빌드 — 5~15분 정도 걸릴 수 있습니다"
sudo docker build --pull -t "$IMAGE_NAME" .

say "앱 컨테이너 실행"
sudo docker network inspect "$DOCKER_NETWORK" >/dev/null 2>&1 || sudo docker network create "$DOCKER_NETWORK" >/dev/null
sudo docker rm -f "$APP_CONTAINER" >/dev/null 2>&1 || true
sudo docker run -d \
  --name "$APP_CONTAINER" \
  --restart unless-stopped \
  --network "$DOCKER_NETWORK" \
  --env-file "$APP_DIR/.env" \
  -p 127.0.0.1:3000:3000 \
  "$IMAGE_NAME" >/dev/null

say "HTTPS 주소 구성"
PUBLIC_IP="$(curl -4 -fsS --max-time 15 https://api.ipify.org)"
[[ "$PUBLIC_IP" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "공인 IPv4 확인에 실패했습니다: $PUBLIC_IP"
DOMAIN="${PUBLIC_IP//./-}.nip.io"
CADDY_DIR="$HOME/kiwoom-caddy"
mkdir -p "$CADDY_DIR/data" "$CADDY_DIR/config"
cat > "$CADDY_DIR/Caddyfile" <<EOF_CADDY
$DOMAIN {
  encode zstd gzip
  reverse_proxy $APP_CONTAINER:3000
}
EOF_CADDY
sudo docker rm -f "$CADDY_CONTAINER" >/dev/null 2>&1 || true
sudo docker run -d \
  --name "$CADDY_CONTAINER" \
  --restart unless-stopped \
  --network "$DOCKER_NETWORK" \
  -p 80:80 -p 443:443 \
  -v "$CADDY_DIR/Caddyfile:/etc/caddy/Caddyfile:ro" \
  -v "$CADDY_DIR/data:/data" \
  -v "$CADDY_DIR/config:/config" \
  caddy:2-alpine >/dev/null

say "앱 시작 확인"
for _ in $(seq 1 60); do
  if curl -fsS http://127.0.0.1:3000/api/health >/tmp/kiwoom-health.json 2>/dev/null; then
    break
  fi
  sleep 2
done

if [[ ! -s /tmp/kiwoom-health.json ]]; then
  sudo docker logs --tail 80 "$APP_CONTAINER" || true
  fail "앱이 시작되지 않았습니다. 위 로그를 확인하세요."
fi

printf '\n============================================================\n'
printf '설치 완료\n'
printf '앱 주소   : https://%s\n' "$DOMAIN"
printf '상태 확인 : https://%s/api/health\n' "$DOMAIN"
printf '============================================================\n'
printf '\nHTTPS 인증서 발급은 방화벽 80·443이 열린 뒤 1~3분 걸릴 수 있습니다.\n'
printf '현재 로컬 상태: '
cat /tmp/kiwoom-health.json
printf '\n\n최근 앱 로그:\n'
sudo docker logs --tail 30 "$APP_CONTAINER" || true
