#!/usr/bin/env bash
set -Eeuo pipefail
REPO_URL="https://github.com/bbblaprk-svg/kiwoom-smartmoney-daytrader.git"
ZIP_NAME="QUANT_NOVA_1.0.1_KIWOOM_PRE_IGNITION.zip"
APP_DIR="$HOME/quant-nova"
IMAGE="quant-nova:1.0.1"
CONTAINER="quant-nova"
NETWORK="kiwoom-net"
HOST_PORT="3200"
TMP="$(mktemp -d)"
OLD_IMAGE="$(sudo docker inspect "$CONTAINER" --format '{{.Config.Image}}' 2>/dev/null || true)"
cleanup(){ rm -rf "$TMP"; }
trap cleanup EXIT
fail(){ printf '\n[오류] %s\n' "$*" >&2; exit 1; }
say(){ printf '\n==> %s\n' "$*"; }
[[ "$(id -u)" -ne 0 ]] || fail "ubuntu 사용자로 실행하세요."
[[ -f "$APP_DIR/.env" ]] || fail "$APP_DIR/.env 없음 — Key/Secret 보존 파일을 찾을 수 없습니다."
say "1/6 NOVA 1.0.1 파일 받기"
git clone --depth 1 "$REPO_URL" "$TMP/repo" >/dev/null
[[ -f "$TMP/repo/$ZIP_NAME" ]] || fail "GitHub 최상위에 $ZIP_NAME 파일이 없습니다."
unzip -q "$TMP/repo/$ZIP_NAME" -d "$TMP/src"
ROOT="$TMP/src/nova101"
[[ -f "$ROOT/Dockerfile" && -f "$ROOT/app/main.py" ]] || fail "ZIP 내부 구조 오류"
python3 -m py_compile "$ROOT/app/main.py"
say "2/6 수정내용 검증"
grep -Fq "'bid_surge','ka10021'" "$ROOT/app/main.py" || fail "ka10021 누락"
grep -Fq "'residual_ratio_surge','ka10022'" "$ROOT/app/main.py" || fail "ka10022 누락"
grep -Fq "'trde_qty_cnd':'0'" "$ROOT/app/main.py" || fail "ka10027 trde_qty_cnd 수정 누락"
grep -Fq "'tm':'5'" "$ROOT/app/main.py" || fail "ka10023 tm 누락"
! grep -Fq "'program_top','ka90003'" "$ROOT/app/main.py" || fail "잘못된 ka90003 ranking 호출 잔존"
say "3/6 Docker build"
sudo docker build --pull -t "$IMAGE" "$ROOT"
say "4/6 컨테이너 교체"
sudo docker rm -f "${CONTAINER}-old" >/dev/null 2>&1 || true
if sudo docker inspect "$CONTAINER" >/dev/null 2>&1; then sudo docker rename "$CONTAINER" "${CONTAINER}-old"; fi
sudo docker run -d --name "$CONTAINER" --restart unless-stopped --network "$NETWORK" --env-file "$APP_DIR/.env" -p 127.0.0.1:${HOST_PORT}:8000 "$IMAGE" >/dev/null
HEALTH=""
for _ in $(seq 1 60); do HEALTH="$(curl -fsS --max-time 3 http://127.0.0.1:${HOST_PORT}/api/health 2>/dev/null || true)"; [[ -n "$HEALTH" ]] && break; sleep 2; done
if [[ -z "$HEALTH" ]]; then
  sudo docker logs --tail 200 "$CONTAINER" || true
  sudo docker rm -f "$CONTAINER" >/dev/null 2>&1 || true
  if sudo docker inspect "${CONTAINER}-old" >/dev/null 2>&1; then sudo docker rename "${CONTAINER}-old" "$CONTAINER"; sudo docker start "$CONTAINER" >/dev/null; fi
  fail "1.0.1 health 실패 — 이전 NOVA로 복구"
fi
say "5/6 Discovery source 확인"
sleep 25
H2="$(curl -fsS --max-time 5 http://127.0.0.1:${HOST_PORT}/api/health)"
printf '%s\n' "$H2" | python3 - <<'PY'
import sys,json
h=json.load(sys.stdin)
print('version=',h.get('version'))
rs=h.get('rest_status') or {}
for k in sorted(rs):
    x=rs[k] or {}
    print(k,'ok='+str(x.get('ok')),'rows='+str(x.get('rows')),'msg='+str(x.get('msg',''))[:80])
PY
sudo docker rm -f "${CONTAINER}-old" >/dev/null 2>&1 || true
say "6/6 완료"
echo "IMAGE=$IMAGE"
echo "STATUS=$(sudo docker inspect "$CONTAINER" --format '{{.State.Status}}')"
echo "LOCAL_URL=http://127.0.0.1:${HOST_PORT}"
echo "PUBLIC_URL=https://3-38-25-20.nip.io"
echo "KEY_SECRET=PRESERVED"
