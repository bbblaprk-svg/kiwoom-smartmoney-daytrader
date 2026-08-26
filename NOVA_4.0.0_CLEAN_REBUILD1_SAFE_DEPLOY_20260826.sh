#!/usr/bin/env bash
set -Eeuo pipefail

REPO_URL="https://github.com/bbblaprk-svg/kiwoom-smartmoney-daytrader.git"
DOCKERFILE_NAME="QUANT_NOVA_4.0.0_CLEAN_REBUILD1_20260826.Dockerfile"
EXPECTED_SHA256="baf47dfe6af73ccfc0f8a38fa7e661d4dee285d04591d762c7e11a87d4d120bb"
APP_DIR="$HOME/quant-nova"
DATA_DIR="$APP_DIR/data"
ENV_FILE="$APP_DIR/.env"
IMAGE="quant-nova:4.0.0-clean-rebuild1"
CONTAINER="quant-nova"
NETWORK="kiwoom-net"
HOST_PORT="3200"
TMP="$(mktemp -d)"
STAMP="$(date +%Y%m%d%H%M%S)"
BACKUP="${CONTAINER}-baseline-${STAMP}"
STATE_FILE="$APP_DIR/.clean_rebuild_previous_container"
OLD_RENAMED=0
NEW_STARTED=0

cleanup(){ rm -rf "$TMP"; }
restore(){
  local ec=$?
  if [[ $ec -eq 0 ]]; then return; fi
  echo "[자동복구] CLEAN REBUILD 적용 실패 — 직전 NOVA를 복구합니다." >&2
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
sudo docker inspect "$CONTAINER" >/dev/null 2>&1 || { echo "현재 $CONTAINER 컨테이너가 없습니다. 자동 기준복구를 보장할 수 없어 중단합니다." >&2; exit 1; }

printf '\n==> 1/8 새 파일 취득 및 SHA256 고정검사\n'
git clone --depth 1 "$REPO_URL" "$TMP/repo" >/dev/null 2>&1
DF="$TMP/repo/$DOCKERFILE_NAME"
[[ -s "$DF" ]] || { echo "GitHub에 $DOCKERFILE_NAME 파일이 없습니다." >&2; exit 1; }
ACTUAL="$(sha256sum "$DF" | awk '{print $1}')"
[[ "$ACTUAL" == "$EXPECTED_SHA256" ]] || { echo "Dockerfile SHA256 불일치: $ACTUAL" >&2; exit 1; }

printf '\n==> 2/8 현재 운영본 보존\n'
CURRENT_IMAGE="$(sudo docker inspect -f '{{.Image}}' "$CONTAINER")"
CURRENT_LABEL="$(sudo docker inspect -f '{{index .Config.Labels "org.opencontainers.image.version"}}' "$CONTAINER" 2>/dev/null || true)"
echo "현재 image=$CURRENT_IMAGE label=${CURRENT_LABEL:-unknown}"
printf '%s\n' "$BACKUP" > "$STATE_FILE"

printf '\n==> 3/8 1GB 서버 메모리 보호를 위해 현재본 정지 후 이름 보존\n'
sudo docker stop -t 20 "$CONTAINER" >/dev/null
sudo docker rename "$CONTAINER" "$BACKUP"
OLD_RENAMED=1

printf '\n==> 4/8 CLEAN REBUILD 이미지 빌드\n'
sudo docker build --pull=false --tag "$IMAGE" --file "$DF" "$TMP/repo"

printf '\n==> 5/8 새 컨테이너 기동 — 기존 env/data/network 그대로\n'
sudo docker run -d \
  --name "$CONTAINER" \
  --restart unless-stopped \
  --env-file "$ENV_FILE" \
  -e TZ=Asia/Seoul \
  -e NOVA_DATA_DIR=/app/data/nova30 \
  --network "$NETWORK" \
  -p "${HOST_PORT}:8000" \
  -v "$DATA_DIR:/app/data" \
  "$IMAGE" >/dev/null
NEW_STARTED=1

printf '\n==> 6/8 livez/clean-rebuild 응답 확인\n'
OK=0
for i in $(seq 1 40); do
  if curl -fsS --max-time 4 "http://127.0.0.1:${HOST_PORT}/api/livez" >/tmp/nova_livez.json 2>/dev/null && \
     curl -fsS --max-time 4 "http://127.0.0.1:${HOST_PORT}/api/clean-rebuild" >/tmp/nova_clean.json 2>/dev/null; then
    OK=1; break
  fi
  sleep 3
done
[[ $OK -eq 1 ]] || { echo "새 컨테이너 API 기동 실패" >&2; sudo docker logs --tail 120 "$CONTAINER" >&2 || true; false; }
python3 - <<'PY'
import json
j=json.load(open('/tmp/nova_clean.json'))
assert j.get('ok') is True, j
assert j.get('version')=='NOVA-4.0.0-CLEAN-REBUILD1', j.get('version')
assert j.get('engine')=='CLEAN_REBUILD_SINGLE_TRUTH', j.get('engine')
rules=j.get('rules') or {}
if rules:
    assert rules.get('new_broker_ws_types')==0
    assert rules.get('new_broker_rest_calls')==0
print('CLEAN_REBUILD_API=PASS source='+str(j.get('source'))+' frozen='+str(j.get('frozen')))
PY

printf '\n==> 7/8 보호된 기준 데이터경로 이미지 라벨 확인\n'
LABEL="$(sudo docker inspect -f '{{index .Config.Labels "org.opencontainers.image.version"}}' "$CONTAINER")"
BASE="$(sudo docker inspect -f '{{index .Config.Labels "io.quantnova.baseline"}}' "$CONTAINER")"
[[ "$LABEL" == "NOVA-4.0.0-CLEAN-REBUILD1" ]]
[[ "$BASE" == "NOVA-3.3.5-R492-MARKET-INDEX-VERIFY1" ]]

printf '\n==> 8/8 완료\n'
echo "새 버전: $LABEL"
echo "기준본 보존 컨테이너: $BACKUP (STOPPED)"
echo "문제 발생 시 NOVA_4.0.0_CLEAN_REBUILD1_ROLLBACK_20260826.sh 실행"
echo "접속: http://<LIGHTSAIL-IP>:${HOST_PORT}/"
trap - ERR
