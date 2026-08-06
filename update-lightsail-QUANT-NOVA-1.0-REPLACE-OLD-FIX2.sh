#!/usr/bin/env bash
set -Eeuo pipefail

REPO_URL="https://github.com/bbblaprk-svg/kiwoom-smartmoney-daytrader.git"
ZIP_NAME="QUANT_NOVA_1.0_KIWOOM_PRE_IGNITION.zip"
APP_DIR="$HOME/quant-nova"
IMAGE="quant-nova:1.0"
CONTAINER="quant-nova"
NETWORK="kiwoom-net"
HOST_PORT="3200"
CADDY="kiwoom-caddy"
TMP="$(mktemp -d)"
STAMP="$(date +%Y%m%d%H%M%S)"
KEY_BACKUP="$HOME/.quant-nova-kiwoom-keys-$STAMP.env"

say(){ printf '\n==> %s\n' "$*"; }
fail(){ printf '\n[오류] %s\n' "$*" >&2; exit 1; }
cleanup(){ rm -rf "$TMP"; }
trap cleanup EXIT

[[ "$(id -u)" -ne 0 ]] || fail "root가 아닌 ubuntu 사용자로 실행하세요."

say "1/9 AWS Lightsail 필수 도구 확인"
sudo apt-get update -qq
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y git docker.io curl ca-certificates unzip python3 >/dev/null
sudo systemctl enable --now docker

get_from_file(){
  local f="$1" k="$2"
  [[ -f "$f" ]] || return 0
  sed -n "s/^${k}=//p" "$f" | tail -n1
}
get_from_container(){
  local c="$1" k="$2"
  sudo docker inspect "$c" --format '{{range .Config.Env}}{{println .}}{{end}}' 2>/dev/null | sed -n "s/^${k}=//p" | tail -n1 || true
}
first_nonempty(){
  local v
  for v in "$@"; do [[ -n "$v" ]] && { printf '%s' "$v"; return 0; }; done
  return 0
}

say "2/9 기존 Kiwoom Key / Secret 선보존"
APP_KEY=""
SECRET_KEY=""
TOKEN_KEY=""

# 다양한 과거 파일/키 이름을 모두 탐색한다.
for f in \
  "$APP_DIR/.env" \
  "$HOME/kiwoom-unified-edge/.env" \
  "$HOME/kiwoom-smartmoney-daytrader/.env" \
  "$HOME/.env"; do
  [[ -n "$APP_KEY" ]] || APP_KEY="$(first_nonempty \
      "$(get_from_file "$f" KIWOOM_APP_KEY)" \
      "$(get_from_file "$f" KIWOOM_APPKEY)" \
      "$(get_from_file "$f" APP_KEY)")"
  [[ -n "$SECRET_KEY" ]] || SECRET_KEY="$(first_nonempty \
      "$(get_from_file "$f" KIWOOM_APP_SECRET)" \
      "$(get_from_file "$f" KIWOOM_SECRET_KEY)" \
      "$(get_from_file "$f" KIWOOM_SECRETKEY)" \
      "$(get_from_file "$f" SECRET_KEY)" \
      "$(get_from_file "$f" APP_SECRET)")"
  [[ -n "$TOKEN_KEY" ]] || TOKEN_KEY="$(get_from_file "$f" APP_ACCESS_TOKEN)"
done

for c in kiwoom-app quant-nova; do
  [[ -n "$APP_KEY" ]] || APP_KEY="$(first_nonempty \
      "$(get_from_container "$c" KIWOOM_APP_KEY)" \
      "$(get_from_container "$c" KIWOOM_APPKEY)" \
      "$(get_from_container "$c" APP_KEY)")"
  [[ -n "$SECRET_KEY" ]] || SECRET_KEY="$(first_nonempty \
      "$(get_from_container "$c" KIWOOM_APP_SECRET)" \
      "$(get_from_container "$c" KIWOOM_SECRET_KEY)" \
      "$(get_from_container "$c" KIWOOM_SECRETKEY)" \
      "$(get_from_container "$c" SECRET_KEY)" \
      "$(get_from_container "$c" APP_SECRET)")"
  [[ -n "$TOKEN_KEY" ]] || TOKEN_KEY="$(get_from_container "$c" APP_ACCESS_TOKEN)"
done

[[ -n "$APP_KEY" ]] || fail "기존 서버에서 Kiwoom APP KEY를 찾지 못했습니다. 기존 파일 삭제 전에 중단합니다."
[[ -n "$SECRET_KEY" ]] || fail "기존 서버에서 Kiwoom SECRET KEY를 찾지 못했습니다. 기존 파일 삭제 전에 중단합니다."

umask 077
cat > "$KEY_BACKUP" <<ENV
KIWOOM_APP_KEY=$APP_KEY
KIWOOM_SECRET_KEY=$SECRET_KEY
KIWOOM_APP_SECRET=$SECRET_KEY
ENV
[[ -z "$TOKEN_KEY" ]] || printf 'APP_ACCESS_TOKEN=%s\n' "$TOKEN_KEY" >> "$KEY_BACKUP"
chmod 600 "$KEY_BACKUP"
echo "KEY_BACKUP=$KEY_BACKUP"
echo "APP_KEY_LENGTH=${#APP_KEY} SECRET_LENGTH=${#SECRET_KEY}"

say "3/9 새 QUANT NOVA 배포 파일 받기"
git clone --depth 1 "$REPO_URL" "$TMP/repo" >/dev/null
[[ -f "$TMP/repo/$ZIP_NAME" ]] || fail "GitHub 최상위에 $ZIP_NAME 파일이 없습니다."
unzip -q "$TMP/repo/$ZIP_NAME" -d "$TMP/src"
ROOT="$TMP/src/quant_nova_release"
[[ -f "$ROOT/Dockerfile" && -f "$ROOT/app/main.py" ]] || fail "QUANT NOVA ZIP 내부 구조 오류"

say "4/9 새 NOVA 환경 구성"
mkdir -p "$APP_DIR"
cat > "$APP_DIR/.env" <<ENV
KIWOOM_APP_KEY=$APP_KEY
KIWOOM_SECRET_KEY=$SECRET_KEY
KIWOOM_APP_SECRET=$SECRET_KEY
NOVA_DISCOVERY_SECONDS=20
NOVA_WS_LIMIT=60
NOVA_MIN_SCORE=58
PORT=8000
ENV
[[ -z "$TOKEN_KEY" ]] || printf 'APP_ACCESS_TOKEN=%s\n' "$TOKEN_KEY" >> "$APP_DIR/.env"
chmod 600 "$APP_DIR/.env"

say "5/9 NOVA 이미지 빌드 및 임시 기동"
sudo docker build --pull -t "$IMAGE" "$ROOT"
sudo docker network inspect "$NETWORK" >/dev/null 2>&1 || sudo docker network create "$NETWORK" >/dev/null
sudo docker rm -f "$CONTAINER" >/dev/null 2>&1 || true
sudo docker run -d \
  --name "$CONTAINER" \
  --restart unless-stopped \
  --network "$NETWORK" \
  --env-file "$APP_DIR/.env" \
  -p 127.0.0.1:${HOST_PORT}:8000 \
  "$IMAGE" >/dev/null

HEALTH=""
for _ in $(seq 1 90); do
  HEALTH="$(curl -fsS --max-time 3 http://127.0.0.1:${HOST_PORT}/api/health 2>/dev/null || true)"
  [[ -n "$HEALTH" ]] && break
  sleep 2
done
[[ -n "$HEALTH" ]] || { sudo docker logs --tail 250 "$CONTAINER" || true; fail "새 NOVA health 실패. 기존 앱은 삭제하지 않았습니다."; }

say "6/9 기존 공개주소를 NOVA로 전환"
PUBLIC_IP="$(curl -fsS --max-time 5 https://checkip.amazonaws.com 2>/dev/null | tr -d '[:space:]' || true)"
if [[ -z "$PUBLIC_IP" ]] && sudo docker inspect "$CADDY" >/dev/null 2>&1; then
  PUBLIC_IP="$(sudo docker exec "$CADDY" sh -c 'cat /etc/caddy/Caddyfile 2>/dev/null' 2>/dev/null | grep -Eo '([0-9]+-){3}[0-9]+\.nip\.io' | head -n1 | tr '-' '.' | sed 's/\.nip\.io$//' || true)"
fi
[[ "$PUBLIC_IP" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "Lightsail 공인 IP 자동 확인 실패"
ROOT_HOST="${PUBLIC_IP//./-}.nip.io"

if ! sudo docker inspect "$CADDY" >/dev/null 2>&1; then
  fail "kiwoom-caddy가 없어 HTTPS 공개주소를 안전하게 인계할 수 없습니다. 기존 앱은 삭제하지 않았습니다."
fi
sudo docker exec "$CADDY" sh -c 'cat /etc/caddy/Caddyfile' > "$APP_DIR/Caddyfile.pre-nova.$STAMP"
cat > "$TMP/Caddyfile" <<EOF
$ROOT_HOST {
    encode gzip zstd
    reverse_proxy quant-nova:8000
}
EOF
sudo docker cp "$TMP/Caddyfile" "$CADDY:/tmp/Caddyfile.nova-replace"
sudo docker exec "$CADDY" caddy validate --config /tmp/Caddyfile.nova-replace --adapter caddyfile >/dev/null
sudo docker exec "$CADDY" sh -c 'cat /tmp/Caddyfile.nova-replace > /etc/caddy/Caddyfile'
sudo docker exec "$CADDY" caddy reload --config /etc/caddy/Caddyfile --adapter caddyfile

HTTPS_OK=0
for _ in $(seq 1 40); do
  if curl -kfsS --max-time 5 "https://${ROOT_HOST}/api/health" >/dev/null 2>&1; then HTTPS_OK=1; break; fi
  sleep 3
done
[[ $HTTPS_OK -eq 1 ]] || fail "NOVA HTTPS 전환 확인 실패. Caddy 백업은 $APP_DIR/Caddyfile.pre-nova.$STAMP 에 있습니다."

say "7/9 기존 앱/뉴스레이더 폐기"
# 새 NOVA가 local+HTTPS 모두 정상인 것을 확인한 뒤에만 구형 컨테이너를 제거한다.
for c in kiwoom-app news-radar; do sudo docker rm -f "$c" >/dev/null 2>&1 || true; done

# 구형 소스/캐시를 제거하되, 방금 보존한 키 백업과 NOVA는 제외한다.
rm -rf "$HOME/kiwoom-unified-edge" "$HOME/kiwoom-smartmoney-daytrader" 2>/dev/null || true
sudo docker images --format '{{.Repository}}:{{.Tag}}' | grep -E '^(kiwoom-unified|kiwoom-news-radar):' | xargs -r sudo docker rmi -f >/dev/null 2>&1 || true
sudo docker image prune -f >/dev/null 2>&1 || true
sudo docker builder prune -f --filter 'until=24h' >/dev/null 2>&1 || true

say "8/9 최종 실시간/키 상태 확인"
FINAL_HEALTH="$(curl -fsS --max-time 5 http://127.0.0.1:${HOST_PORT}/api/health)"
[[ -n "$FINAL_HEALTH" ]] || fail "최종 health 실패"

say "9/9 완료"
printf '\n=== QUANT NOVA REPLACEMENT FINAL ===\n'
echo "OLD_APP=REMOVED"
echo "NEWS_RADAR=REMOVED"
echo "KEY_SECRET=PRESERVED"
echo "KEY_BACKUP=$KEY_BACKUP"
echo "IMAGE=$IMAGE"
echo "CONTAINER=$CONTAINER"
echo "STATUS=$(sudo docker inspect "$CONTAINER" --format '{{.State.Status}}')"
echo "PUBLIC_URL=https://${ROOT_HOST}"
echo "HTTPS=OK"
echo "LOCAL_HEALTH=OK"
printf '%s\n' "$FINAL_HEALTH" | python3 -m json.tool || true
printf '\n※ Key/Secret 실제 값은 화면에 출력하지 않았습니다.\n'
