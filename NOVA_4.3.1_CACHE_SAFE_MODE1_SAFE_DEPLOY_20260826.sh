#!/usr/bin/env bash
set -Eeuo pipefail
REPO_URL="https://github.com/bbblaprk-svg/kiwoom-smartmoney-daytrader.git"
DOCKERFILE_NAME="QUANT_NOVA_4.3.1_CACHE_SAFE_MODE1_20260826.Dockerfile"
EXPECTED_SHA256="2e78eef2276e2baf3fd6f97de7ab503d933246f190f100eb451337694d4ddc4a"
APP_DIR="$HOME/quant-nova"
DATA_DIR="$APP_DIR/data"
ENV_FILE="$APP_DIR/.env"
IMAGE="quant-nova:4.3.1-cache-safe-mode1"
CONTAINER="quant-nova"
NETWORK="kiwoom-net"
HOST_PORT="3200"
TMP="$(mktemp -d)"
STAMP="$(date +%Y%m%d%H%M%S)"
BACKUP="${CONTAINER}-pre-cache-safe-mode-${STAMP}"
STATE_FILE="$APP_DIR/.cache_safe_mode_previous_container"
OLD_RENAMED=0
NEW_STARTED=0
cleanup(){ rm -rf "$TMP"; }
restore(){
  local ec=$?
  if [[ $ec -eq 0 ]]; then return; fi
  echo "[자동복구] CACHE-SAFE-MODE 적용 실패 — 직전 NOVA를 복구합니다." >&2
  if [[ $NEW_STARTED -eq 1 ]]; then sudo docker rm -f "$CONTAINER" >/dev/null 2>&1 || true; fi
  if [[ $OLD_RENAMED -eq 1 ]]; then
    sudo docker rename "$BACKUP" "$CONTAINER" >/dev/null 2>&1 || true
    sudo docker start "$CONTAINER" >/dev/null 2>&1 || true
  fi
  exit "$ec"
}
trap cleanup EXIT
trap restore ERR
[[ "$(id -u)" -ne 0 ]] || { echo "ubuntu 사용자로 실행하세요." >&2; exit 1; }
mkdir -p "$APP_DIR" "$DATA_DIR"
[[ -s "$ENV_FILE" ]] || { echo "$ENV_FILE 없음 — 기존 KIWOOM Key/Secret 환경을 보존할 수 없습니다." >&2; exit 1; }
sudo docker inspect "$CONTAINER" >/dev/null 2>&1 || { echo "현재 $CONTAINER 컨테이너가 없습니다." >&2; exit 1; }

printf '\n==> 1/8 CACHE-SAFE-MODE 파일 취득 및 SHA256 검사\n'
git clone --depth 1 "$REPO_URL" "$TMP/repo" >/dev/null 2>&1
DF="$TMP/repo/$DOCKERFILE_NAME"
[[ -s "$DF" ]] || { echo "GitHub에 $DOCKERFILE_NAME 파일이 없습니다." >&2; exit 1; }
ACTUAL="$(sha256sum "$DF" | awk '{print $1}')"
[[ "$ACTUAL" == "$EXPECTED_SHA256" ]] || { echo "Dockerfile SHA256 불일치: $ACTUAL" >&2; exit 1; }

printf '\n==> 2/8 현재 운영본 보존\n'
printf '%s\n' "$BACKUP" > "$STATE_FILE"
echo "현재 버전: $(sudo docker inspect -f '{{index .Config.Labels \"org.opencontainers.image.version\"}}' "$CONTAINER" 2>/dev/null || true)"

printf '\n==> 3/8 1GB 서버 보호 — 현재본 정지 후 이름 보존\n'
sudo docker stop -t 20 "$CONTAINER" >/dev/null
sudo docker rename "$CONTAINER" "$BACKUP"
OLD_RENAMED=1

printf '\n==> 4/8 CACHE-SAFE-MODE 이미지 빌드\n'
sudo docker build --pull=false --tag "$IMAGE" --file "$DF" "$TMP/repo"

printf '\n==> 5/8 새 컨테이너 기동 — 기존 env/data/network 그대로\n'
sudo docker run -d --name "$CONTAINER" --restart unless-stopped --env-file "$ENV_FILE" -e TZ=Asia/Seoul -e NOVA_DATA_DIR=/app/data/nova30 --network "$NETWORK" -p "${HOST_PORT}:8000" -v "$DATA_DIR:/app/data" "$IMAGE" >/dev/null
NEW_STARTED=1

printf '\n==> 6/8 API + 새 UI 실물파일 검증\n'
OK=0
for i in $(seq 1 40); do
  if curl -fsS --max-time 4 "http://127.0.0.1:${HOST_PORT}/api/clean-rebuild?ui=431" >/tmp/nova431.json 2>/dev/null &&      curl -fsS --max-time 4 "http://127.0.0.1:${HOST_PORT}/?ui=4311" >/tmp/nova431.html 2>/dev/null &&      curl -fsS --max-time 4 "http://127.0.0.1:${HOST_PORT}/static/nova-ui-431.js?v=4311" >/tmp/nova431.js 2>/dev/null; then OK=1; break; fi
  sleep 3
done
[[ $OK -eq 1 ]] || { echo "새 컨테이너 API/UI 기동 실패" >&2; sudo docker logs --tail 120 "$CONTAINER" >&2 || true; false; }
python3 - <<'PY'
import json
j=json.load(open('/tmp/nova431.json'))
assert j.get('ok') is True,j
assert j.get('version')=='NOVA-4.3.1-CACHE-SAFE-MODE1',j.get('version')
h=open('/tmp/nova431.html').read(); s=open('/tmp/nova431.js').read()
assert 'nova-ui-431.js?v=4311' in h and 'nova-ui-431.css?v=4311' in h
assert 'id="closeSection" class="modeSection" hidden' in h
assert 'id="liveSection" class="modeSection" hidden' in h
assert 'c.hidden=!close;l.hidden=close' in s
if j.get('close_mode'):
    cb=j.get('close_boards') or {}
    print('CACHE_SAFE_MODE_API=PASS close_mode=True boards='+str({k:len(v or []) for k,v in cb.items()}))
else:
    print('CACHE_SAFE_MODE_API=PASS close_mode=False')
PY

printf '\n==> 7/8 이미지 라벨/기준 데이터수급 보존 확인\n'
LABEL="$(sudo docker inspect -f '{{index .Config.Labels "org.opencontainers.image.version"}}' "$CONTAINER")"
BASE="$(sudo docker inspect -f '{{index .Config.Labels "io.quantnova.baseline"}}' "$CONTAINER")"
CACHE_SAFE="$(sudo docker inspect -f '{{index .Config.Labels "io.quantnova.cache_safe_mode"}}' "$CONTAINER")"
[[ "$LABEL" == "NOVA-4.3.1-CACHE-SAFE-MODE1" ]]
[[ "$BASE" == "NOVA-3.3.5-R492-MARKET-INDEX-VERIFY1" ]]
[[ "$CACHE_SAFE" == "1" ]]

printf '\n==> 8/8 완료\n'
echo "새 버전: $LABEL"
echo "직전본 보존 컨테이너: $BACKUP (STOPPED)"
echo "캐시대책: 새 물리 JS/CSS 파일명 + 시작시 양쪽 모드 hidden + API가 한쪽만 해제 + legacy service worker/cache 제거"
echo "첫 확인 주소: http://<LIGHTSAIL-IP>:${HOST_PORT}/?ui=4311"
trap - ERR
