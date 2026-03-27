#!/usr/bin/env bash
# Backup loopctl Postgres database to Synology DS920+.
# Intended to run via systemd timer on the Beelink.
set -euo pipefail

BACKUP_DIR="/tmp/loopctl_backups"
NAS_USER="mkreyman"
NAS_HOST="192.168.86.53"
NAS_PATH="/volume1/NetBackup/loopctl"
RETENTION_DAYS=7
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
DUMP_FILE="loopctl_${TIMESTAMP}.sql.gz"

mkdir -p "$BACKUP_DIR"

echo "==> Dumping database..."
docker compose -f "$HOME/workspace/loopctl/docker-compose.yml" exec -T db \
  pg_dump -U loopctl -d loopctl_prod --no-owner --no-acl \
  | gzip > "${BACKUP_DIR}/${DUMP_FILE}"

DUMP_SIZE=$(du -h "${BACKUP_DIR}/${DUMP_FILE}" | cut -f1)
echo "==> Dump complete: ${DUMP_FILE} (${DUMP_SIZE})"

echo "==> Syncing to NAS..."
rsync -az --timeout=60 "${BACKUP_DIR}/${DUMP_FILE}" \
  "${NAS_USER}@${NAS_HOST}:${NAS_PATH}/"

echo "==> Cleaning up local backups older than ${RETENTION_DAYS} days..."
find "$BACKUP_DIR" -name "loopctl_*.sql.gz" -mtime +${RETENTION_DAYS} -delete

echo "==> Cleaning up remote backups older than ${RETENTION_DAYS} days..."
ssh "${NAS_USER}@${NAS_HOST}" \
  "find ${NAS_PATH} -name 'loopctl_*.sql.gz' -mtime +${RETENTION_DAYS} -delete"

echo "==> Backup complete: ${DUMP_FILE}"
