#!/usr/bin/env bash
set -Eeuo pipefail
umask 077
APP="${NOVA_APP_CONTAINER:-quant-nova}"
VERSION="NOVA-3.3.5-R492-MARKET-INDEX-VERIFY1"
UIFIX7="CLOSE_FROZEN_PERSIST_TRISTATE_SPARSE_IO_R2"
FIXED20="CORE2000_FRESH1000_1999_CAP2_FIXED20_VERIFY1"
DIVERSITY="FIXED_TABLES_FRESH_ROTATION_V1"
BASE_SOURCE="0d2f300af673c7187ae51b3ec9acc0e13e1dfaa6211d7b76a4f721130df632fc"
STAMP="$(date +%Y%m%d-%H%M%S)"
FAILED="${APP}-failed-diversity-manual-${STAMP}"
if docker info >/dev/null 2>&1; then DOCKER=(docker); elif sudo -n docker info >/dev/null 2>&1; then DOCKER=(sudo docker); else echo "FAIL: Docker 권한 없음"; exit 2; fi
dc(){ "${DOCKER[@]}" "$@"; }
image_id(){ dc inspect "$1" --format '{{.Image}}' 2>/dev/null || true; }
label(){ local iid;iid="$(image_id "$1")";[ -n "$iid" ]||return 0;dc image inspect "$iid" --format "{{index .Config.Labels \"$2\"}}" 2>/dev/null|sed 's/^<no value>$//'||true; }
wait_health(){ local i s;for i in $(seq 1 72);do s="$(dc inspect "$APP" --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' 2>/dev/null||true)";echo "health=$s";[ "$s" = healthy ]&&return 0;sleep 5;done;return 1; }

dc inspect "$APP" >/dev/null
CURVER="$(label "$APP" org.opencontainers.image.version)";CURFIX="$(label "$APP" io.quantnova.r492_uifix7)";CURPATCH="$(label "$APP" io.quantnova.large_mid_pre_fixed)";CURDIV="$(label "$APP" io.quantnova.diversity_patch)";CURSRC="$(label "$APP" io.quantnova.embedded_source_sha256)"
if [ "$CURVER" = "$VERSION" ] && [ "$CURFIX" = "$UIFIX7" ] && [ "$CURPATCH" = "$FIXED20" ] && [ -z "$CURDIV" ] && [ "$CURSRC" = "$BASE_SOURCE" ]; then
  echo "RESULT=ALREADY_FIXED20 CURRENT=$APP";exit 0
fi
[ "$CURVER" = "$VERSION" ] && [ "$CURFIX" = "$UIFIX7" ] && [ "$CURPATCH" = "$FIXED20" ] && [ "$CURDIV" = "$DIVERSITY" ] || { echo "FAIL: current app is not approved diversity patch; no change";exit 1; }

FOUND=""
while IFS='|' read -r created name;do
  [ -n "$name" ]||continue
  [ "$(label "$name" org.opencontainers.image.version)" = "$VERSION" ]||continue
  [ "$(label "$name" io.quantnova.r492_uifix7)" = "$UIFIX7" ]||continue
  [ "$(label "$name" io.quantnova.large_mid_pre_fixed)" = "$FIXED20" ]||continue
  [ "$(label "$name" io.quantnova.embedded_source_sha256)" = "$BASE_SOURCE" ]||continue
  [ -z "$(label "$name" io.quantnova.diversity_patch)" ]||continue
  FOUND="$name";break
done < <(for c in $(dc ps -a --format '{{.Names}}');do [ "$c" = "$APP" ]&&continue;printf '%s|%s\n' "$(dc inspect "$c" --format '{{.Created}}' 2>/dev/null||true)" "$c";done|sort -r)
[ -n "$FOUND" ] || { echo "FAIL: exact FIXED20 backup not found; no change";exit 1; }
echo "FOUND_FIXED20=$FOUND"
BACKUP_IMAGE="$(image_id "$FOUND")";[ -n "$BACKUP_IMAGE" ]||{ echo "FAIL: backup image missing";exit 1; }

dc stop -t 8 "$APP" >/dev/null 2>&1 || true
dc rename "$APP" "$FAILED"
if ! dc rename "$FOUND" "$APP"; then dc rename "$FAILED" "$APP" >/dev/null 2>&1 || true;dc start "$APP" >/dev/null 2>&1 || true;echo "FAIL: rename restore failed; original restarted";exit 1;fi
dc start "$APP" >/dev/null
if ! wait_health; then
  dc stop -t 5 "$APP" >/dev/null 2>&1||true;dc rename "$APP" "$FOUND" >/dev/null 2>&1||true;dc rename "$FAILED" "$APP" >/dev/null 2>&1||true;dc start "$APP" >/dev/null 2>&1||true
  echo "FAIL: fixed20 backup unhealthy; diversity app restored";exit 1
fi
[ "$(image_id "$APP")" = "$BACKUP_IMAGE" ]
[ "$(label "$APP" io.quantnova.embedded_source_sha256)" = "$BASE_SOURCE" ]
[ -z "$(label "$APP" io.quantnova.diversity_patch)" ]
echo "RESULT=ROLLED_BACK_TO_FIXED20 CURRENT=$APP FAILED_SAVED=$FAILED VERSION=$(label "$APP" org.opencontainers.image.version) PATCH=$(label "$APP" io.quantnova.large_mid_pre_fixed)"
