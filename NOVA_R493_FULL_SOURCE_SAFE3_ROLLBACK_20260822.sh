#!/usr/bin/env bash
set -Eeuo pipefail
APP="${NOVA_APP_CONTAINER:-quant-nova}"
if docker info >/dev/null 2>&1; then D=(docker); elif sudo -n docker info >/dev/null 2>&1; then D=(sudo docker); else echo 'FAIL: Docker permission'; exit 2; fi
dc(){ "${D[@]}" "$@"; }
ver(){ local n="$1" i; i="$(dc inspect "$n" --format '{{.Image}}' 2>/dev/null || true)"; [ -n "$i" ] && dc image inspect "$i" --format '{{index .Config.Labels "org.opencontainers.image.version"}}' 2>/dev/null || true; }
TARGET=""
while read -r n; do v="$(ver "$n")"; case "$v" in NOVA-3.3.5-R492-FRESH-ENERGY-PATH-SAFE|NOVA-3.3.4-MARKET-WIDE-ROTATION-VERIFY) TARGET="$n"; break;; esac; done < <(dc ps -a --format '{{.Names}}' | grep -E '^quant-nova-pre-r493' | sort -r)
[ -n "$TARGET" ] || { echo 'FAIL: approved preserved R492/R491 container not found'; exit 1; }
CURRENT_BACKUP="${APP}-failed-manual-$(date +%Y%m%d-%H%M%S)"
if dc inspect "$APP" >/dev/null 2>&1; then dc stop -t 10 "$APP" >/dev/null 2>&1 || true; dc rename "$APP" "$CURRENT_BACKUP"; fi
dc rename "$TARGET" "$APP"; dc start "$APP" >/dev/null
for i in $(seq 1 72); do s="$(dc inspect "$APP" --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' 2>/dev/null || true)"; [ "$s" = healthy ] && break; sleep 5; done
echo "RESULT=ROLLED_BACK CURRENT=$APP VERSION=$(ver "$APP") FAILED_NEW=$CURRENT_BACKUP"
