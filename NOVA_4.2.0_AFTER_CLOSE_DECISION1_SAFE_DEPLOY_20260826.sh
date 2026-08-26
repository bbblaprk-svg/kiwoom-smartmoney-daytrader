#!/usr/bin/env bash
set -Eeuo pipefail

REPO_URL="https://github.com/bbblaprk-svg/kiwoom-smartmoney-daytrader.git"
DOCKERFILE_NAME="QUANT_NOVA_4.2.0_AFTER_CLOSE_DECISION1_20260826.Dockerfile"
EXPECTED_SHA256="89417b7a07c8ff85338af97bc4c56d5d74d5b0ef43a4a33f432f112efb06b988"
APP_DIR="$HOME/quant-nova"
DATA_DIR="$APP_DIR/data"
ENV_FILE="$APP_DIR/.env"
IMAGE="quant-nova:4.2.0-after-close-decision1"
CONTAINER="quant-nova"
NETWORK="kiwoom-net"
HOST_PORT="3200"
TMP="$(mktemp -d)"
STAMP="$(date +%Y%m%d%H%M%S)"
BACKUP="${CONTAINER}-pre-after-close-${STAMP}"
STATE_FILE="$APP_DIR/.after_close_previous_container"
OLD_RENAMED=0
NEW_STARTED=0

cleanup(){ rm -rf "$TMP"; }
restore(){
  local ec=$?
  if [[ $ec -eq 0 ]]; then return; fi
  echo "[자동복구] AFTER-CLOSE DECISION 적용 실패 — 직전 NOVA를 복구합니다." >&2
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
sudo docker inspect "$CONTAINER" >/dev/null 2>&1 || { echo "현재 $CONTAINER 컨테이너가 없습니다. 자동복구를 보장할 수 없어 중단합니다." >&2; exit 1; }

printf '\n==> 1/8 새 AFTER-CLOSE DECISION 파일 취득 및 SHA256 검사\n'
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

printf '\n==> 3/8 1GB 서버 보호 — 현재본 정지 후 이름 보존\n'
sudo docker stop -t 20 "$CONTAINER" >/dev/null
sudo docker rename "$CONTAINER" "$BACKUP"
OLD_RENAMED=1

printf '\n==> 4/8 AFTER-CLOSE DECISION 이미지 빌드\n'
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

printf '\n==> 6/8 livez/after-close-decision 응답 검증\n'
OK=0
for i in $(seq 1 40); do
  if curl -fsS --max-time 4 "http://127.0.0.1:${HOST_PORT}/api/livez" >/tmp/nova_livez.json 2>/dev/null && \
     curl -fsS --max-time 4 "http://127.0.0.1:${HOST_PORT}/api/clean-rebuild" >/tmp/nova_after_close.json 2>/dev/null; then
    OK=1; break
  fi
  sleep 3
done
[[ $OK -eq 1 ]] || { echo "새 컨테이너 API 기동 실패" >&2; sudo docker logs --tail 120 "$CONTAINER" >&2 || true; false; }
python3 - <<'PY'
import json
j=json.load(open('/tmp/nova_after_close.json'))
assert j.get('ok') is True, j
assert j.get('version')=='NOVA-4.2.0-AFTER-CLOSE-DECISION1', j.get('version')
assert j.get('engine')=='ACTION_FUNNEL_EXCLUSIVE_STAGE_AFTER_CLOSE', j.get('engine')
rules=j.get('rules') or {}
assert rules.get('exclusive_symbol_per_action_board') is True, rules
assert rules.get('new_broker_ws_types')==0, rules
assert rules.get('new_broker_rest_calls')==0, rules
if j.get('close_mode'):
    cb=j.get('close_boards') or {}
    assert set(cb)=={'tomorrow','nxt_close','positions'}, cb.keys()
    codes=[str(r.get('code')) for rows in cb.values() for r in (rows or []) if r.get('code')]
    assert len(codes)==len(set(codes)), ('duplicate close-board symbols', codes)
    for r in cb.get('nxt_close') or []:
        assert int(r.get('buy_ratio') or 0) in (0,10,20), r
        assert 'allocation_text' in r, r
    print('AFTER_CLOSE_API=PASS source='+str(j.get('source'))+' boards='+str({k:len(v or []) for k,v in cb.items()}))
else:
    boards=j.get('boards') or {}
    codes=[str(r.get('code')) for rows in boards.values() for r in (rows or []) if r.get('code')]
    assert len(codes)==len(set(codes)), ('duplicate action-board symbols', codes)
    print('ACTION_FUNNEL_API=PASS source='+str(j.get('source'))+' action_codes='+str(len(codes)))
PY

printf '\n==> 7/8 이미지 라벨/기준 데이터수급 보존 확인\n'
LABEL="$(sudo docker inspect -f '{{index .Config.Labels "org.opencontainers.image.version"}}' "$CONTAINER")"
BASE="$(sudo docker inspect -f '{{index .Config.Labels "io.quantnova.baseline"}}' "$CONTAINER")"
ACTION="$(sudo docker inspect -f '{{index .Config.Labels "io.quantnova.action_funnel"}}' "$CONTAINER")"
CLOSE="$(sudo docker inspect -f '{{index .Config.Labels "io.quantnova.after_close_decision"}}' "$CONTAINER")"
[[ "$LABEL" == "NOVA-4.2.0-AFTER-CLOSE-DECISION1" ]]
[[ "$BASE" == "NOVA-3.3.5-R492-MARKET-INDEX-VERIFY1" ]]
[[ "$ACTION" == "1" ]]
[[ "$CLOSE" == "1" ]]

printf '\n==> 8/8 완료\n'
echo "새 버전: $LABEL"
echo "직전본 보존 컨테이너: $BACKUP (STOPPED)"
echo "장중: ACTION FUNNEL / 장후: 내일후보 + NXT종가배팅 + 보유·매도관리"
echo "접속: http://<LIGHTSAIL-IP>:${HOST_PORT}/"
trap - ERR
