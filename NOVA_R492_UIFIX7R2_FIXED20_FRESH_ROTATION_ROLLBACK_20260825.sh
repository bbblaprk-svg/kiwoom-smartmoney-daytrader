#!/usr/bin/env bash
set -Eeuo pipefail
APP="${NOVA_APP_CONTAINER:-quant-nova}"
BASE_VERSION="NOVA-3.3.5-R492-MARKET-INDEX-VERIFY1"
BASE_UIFIX7="CLOSE_FROZEN_PERSIST_TRISTATE_SPARSE_IO_R2"
BASE_PATCH="CORE2000_FRESH1000_1999_CAP2_FIXED20_VERIFY1"
BASE_SOURCE="0d2f300af673c7187ae51b3ec9acc0e13e1dfaa6211d7b76a4f721130df632fc"
STAMP="$(date +%Y%m%d-%H%M%S)"
if docker info >/dev/null 2>&1; then D=(docker); elif sudo -n docker info >/dev/null 2>&1; then D=(sudo docker); else echo 'FAIL: Docker permission'; exit 2; fi
dc(){ "${D[@]}" "$@"; }
label(){ local c="$1" k="$2" iid; iid="$(dc inspect "$c" --format '{{.Image}}' 2>/dev/null || true)"; [ -n "$iid" ] || return 0; dc image inspect "$iid" --format "{{index .Config.Labels \"$k\"}}" 2>/dev/null | sed 's/^<no value>$//'; }
wait_health(){ local c="$1" s i; for i in $(seq 1 72); do s="$(dc inspect "$c" --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' 2>/dev/null || true)"; echo "health=$s"; [ "$s" = healthy ] && return 0; sleep 5; done; return 1; }
CURSRC="$(label "$APP" io.quantnova.embedded_source_sha256 || true)"
if [ "$CURSRC" = "$BASE_SOURCE" ]; then echo "RESULT=ALREADY_FIXED20_BASELINE CURRENT=$APP"; exit 0; fi
FOUND=""
while IFS= read -r c; do
  [ -n "$c" ] || continue
  [ "$c" = "$APP" ] && continue
  if [ "$(label "$c" org.opencontainers.image.version)" = "$BASE_VERSION" ] && \
     [ "$(label "$c" io.quantnova.r492_uifix7)" = "$BASE_UIFIX7" ] && \
     [ "$(label "$c" io.quantnova.large_mid_pre_fixed)" = "$BASE_PATCH" ] && \
     [ "$(label "$c" io.quantnova.embedded_source_sha256)" = "$BASE_SOURCE" ]; then FOUND="$c"; break; fi
done < <(dc ps -a --format '{{.Names}}' | sort -r)
[ -n "$FOUND" ] || { echo 'FAIL: exact FIXED20 baseline backup not found; no change'; exit 1; }
FAILED="${APP}-failed-fresh-rotation-manual-${STAMP}"
if dc inspect "$APP" >/dev/null 2>&1; then dc stop -t 5 "$APP" >/dev/null 2>&1 || true; dc rename "$APP" "$FAILED"; fi
dc rename "$FOUND" "$APP"
dc start "$APP" >/dev/null
wait_health "$APP"
[ "$(label "$APP" io.quantnova.embedded_source_sha256)" = "$BASE_SOURCE" ]
echo "RESULT=RESTORED_FIXED20_BASELINE CURRENT=$APP VERSION=$BASE_VERSION SOURCE=$BASE_SOURCE"
