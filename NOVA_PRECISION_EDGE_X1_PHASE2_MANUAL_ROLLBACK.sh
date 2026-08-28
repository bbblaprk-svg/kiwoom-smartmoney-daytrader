#!/usr/bin/env bash
set -Eeuo pipefail

CURRENT_CONTAINER="${NOVA_CURRENT_CONTAINER:-quant-nova}"
STAMP="$(date -u +%Y%m%d-%H%M%S)"
FAILED_CONTAINER="quant-nova-failed-precision-edge-x1-phase2-${STAMP}"

say(){ printf '%s\n' "$*"; }
die(){ say "ERROR: $*"; exit 1; }
exists(){ docker container inspect "$1" >/dev/null 2>&1; }

command -v docker >/dev/null || die 'docker command not found'
docker info >/dev/null 2>&1 || die 'docker permission denied or daemon unavailable'

BACKUP_CONTAINER="${1:-}"
if [[ -z "${BACKUP_CONTAINER}" ]]; then
  BACKUP_CONTAINER="$(
    docker ps -a --format '{{.Names}}' |
      awk '/^quant-nova-backup-precision-edge-x1-phase2-[0-9]{8}-[0-9]{6}$/{print}' |
      sort -r | head -n 1
  )"
fi
[[ "${BACKUP_CONTAINER}" =~ ^quant-nova-backup-precision-edge-x1-phase2-[0-9]{8}-[0-9]{6}$ ]] ||
  die 'backup name is invalid; pass the exact BACKUP value printed by SAFE_CUTOVER'
exists "${BACKUP_CONTAINER}" || die "backup container not found: ${BACKUP_CONTAINER}"

if exists "${CURRENT_CONTAINER}"; then
  docker stop --time 35 "${CURRENT_CONTAINER}" >/dev/null 2>&1 || true
  docker rename "${CURRENT_CONTAINER}" "${FAILED_CONTAINER}"
fi
docker rename "${BACKUP_CONTAINER}" "${CURRENT_CONTAINER}"
docker start "${CURRENT_CONTAINER}" >/dev/null

STATE=''
for _ in $(seq 1 48); do
  STATE="$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "${CURRENT_CONTAINER}")"
  [[ "${STATE}" == 'healthy' || "${STATE}" == 'running' ]] && break
  [[ "${STATE}" == 'unhealthy' || "${STATE}" == 'exited' || "${STATE}" == 'dead' ]] && die "restored container failed: ${STATE}"
  sleep 5
done
[[ "${STATE}" == 'healthy' || "${STATE}" == 'running' ]] || die "rollback health timeout: ${STATE}"
say "RESULT=ROLLED_BACK CURRENT=${CURRENT_CONTAINER} STATE=${STATE}"
say "FAILED_PHASE2_CONTAINER=${FAILED_CONTAINER}"
say 'The failed PHASE2 container was preserved for inspection and can be removed later by exact name.'
