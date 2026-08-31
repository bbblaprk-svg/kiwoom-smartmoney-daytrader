#!/usr/bin/env bash
set -Eeuo pipefail
CURRENT="${NOVA_CURRENT_CONTAINER:-kiwoom-smartmoney}"
BACKUP="${1:-}"
if [ -z "$BACKUP" ]; then
  BACKUP="$(docker ps -a --format '{{.Names}}' | grep "^${CURRENT}-backup-v340-" | sort -r | head -1 || true)"
fi
[ -n "$BACKUP" ] || { echo "ERROR: 3.4.0 backup container not found"; exit 1; }
docker container inspect "$BACKUP" >/dev/null 2>&1 || { echo "ERROR: backup not found: $BACKUP"; exit 1; }
docker container inspect "$CURRENT" >/dev/null 2>&1 && docker rm -f "$CURRENT" >/dev/null 2>&1 || true
docker rename "$BACKUP" "$CURRENT"
docker start "$CURRENT" >/dev/null
echo "ROLLBACK=SUCCESS CURRENT=$CURRENT"
