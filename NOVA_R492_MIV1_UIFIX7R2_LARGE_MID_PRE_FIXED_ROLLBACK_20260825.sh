#!/usr/bin/env bash
set -Eeuo pipefail
umask 077
APP="${NOVA_APP_CONTAINER:-quant-nova}"
EXPECTED_VERSION="NOVA-3.3.5-R492-MARKET-INDEX-VERIFY1"
EXPECTED_UIFIX7="CLOSE_FROZEN_PERSIST_TRISTATE_SPARSE_IO_R2"
EXPECTED_PATCH="CORE2000_FRESH1000_1999_CAP2_FIXED20_VERIFY1"
BASE_SOURCE_SHA="a30625c253e1435b71ad9271f9cfe97f6ef7e95249b4d1cef4732882cf222a85"
STAMP="$(date +%Y%m%d-%H%M%S)"
FAILED="${APP}-failed-lmpre-manual-${STAMP}"
if docker info >/dev/null 2>&1; then DOCKER=(docker); elif sudo -n docker info >/dev/null 2>&1; then DOCKER=(sudo docker); else echo "FAIL: Docker 권한 없음"; exit 2; fi
dc(){ "${DOCKER[@]}" "$@"; }
image_id(){ dc inspect "$1" --format '{{.Image}}' 2>/dev/null || true; }
image_label(){ local iid;iid="$(image_id "$1")";[ -n "$iid" ]||return 0;dc image inspect "$iid" --format "{{index .Config.Labels \"$2\"}}" 2>/dev/null|sed 's/^<no value>$//'||true; }
image_version(){ image_label "$1" org.opencontainers.image.version; }
wait_health(){ local n="$1" i s;for i in $(seq 1 72);do s="$(dc inspect "$n" --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' 2>/dev/null||true)";echo "health=$s";[ "$s" = healthy ]&&return 0;sleep 5;done;return 1; }

dc inspect "$APP" >/dev/null
CURVER="$(image_version "$APP")";CURFIX="$(image_label "$APP" io.quantnova.r492_uifix7)";CURPATCH="$(image_label "$APP" io.quantnova.large_mid_pre_fixed)";CURSRC="$(image_label "$APP" io.quantnova.embedded_source_sha256)"
if [ "$CURVER" = "$EXPECTED_VERSION" ] && [ "$CURFIX" = "$EXPECTED_UIFIX7" ] && [ -z "$CURPATCH" ] && [ "$CURSRC" = "$BASE_SOURCE_SHA" ]; then echo "RESULT=ALREADY_PHOTO_BASELINE CURRENT=$APP";exit 0;fi
[ "$CURVER" = "$EXPECTED_VERSION" ] && [ "$CURFIX" = "$EXPECTED_UIFIX7" ] && [ "$CURPATCH" = "$EXPECTED_PATCH" ] || { echo "FAIL: current app is not approved LMPRE patch; no change";exit 1; }
BACKUP=""
while IFS= read -r c;do
  [ -n "$c" ]||continue
  if [ "$(image_version "$c")" = "$EXPECTED_VERSION" ] && [ "$(image_label "$c" io.quantnova.r492_uifix7)" = "$EXPECTED_UIFIX7" ] && [ "$(image_label "$c" io.quantnova.embedded_source_sha256)" = "$BASE_SOURCE_SHA" ];then BACKUP="$c";break;fi
done < <(dc ps -a --format '{{.Names}}'|grep -E "^${APP}-pre-lmpre-[0-9]{8}-[0-9]{6}$"|sort -r||true)
[ -n "$BACKUP" ] || { echo "FAIL: exact pre-LMPRE photo baseline backup not found; no change";exit 1; }
echo "FOUND_BASELINE=$BACKUP"
dc stop -t 5 "$APP" >/dev/null||true
dc rename "$APP" "$FAILED"
dc stop -t 5 "$BACKUP" >/dev/null 2>&1||true
dc rename "$BACKUP" "$APP"
dc start "$APP" >/dev/null
wait_health "$APP"
[ "$(image_version "$APP")" = "$EXPECTED_VERSION" ]
[ "$(image_label "$APP" io.quantnova.r492_uifix7)" = "$EXPECTED_UIFIX7" ]
[ "$(image_label "$APP" io.quantnova.embedded_source_sha256)" = "$BASE_SOURCE_SHA" ]
echo "RESULT=RESTORED_PHOTO_BASELINE CURRENT=$APP FAILED_SAVED=$FAILED"
