#!/usr/bin/env bash
# =============================================================================
# ForgeOps Platform — log-rotate.sh
# Rotates and compresses application and Jenkins logs.
# Run daily via cron.
# =============================================================================
set -euo pipefail

TIMESTAMP=$(date -u '+%Y-%m-%d %H:%M:%S UTC')
LOG_TAG="[log-rotate ${TIMESTAMP}]"

# Directories to rotate
LOG_DIRS=(
  "/opt/forgeops/jenkins_home/logs"
  "/var/log/nginx"
  "/var/log/forgeops"
)

# Settings
MAX_SIZE_MB=50          # Rotate if log > 50 MB
KEEP_DAYS=14            # Keep logs for 14 days
COMPRESS_DAYS=3         # Compress logs older than 3 days

echo "${LOG_TAG} Starting log rotation..."

for LOG_DIR in "${LOG_DIRS[@]}"; do
  [[ -d "${LOG_DIR}" ]] || continue
  echo "${LOG_TAG} Processing: ${LOG_DIR}"

  # Compress logs older than COMPRESS_DAYS
  find "${LOG_DIR}" -name "*.log" -mtime "+${COMPRESS_DAYS}" ! -name "*.gz" \
    -exec gzip -v {} \; 2>/dev/null || true

  # Delete compressed logs older than KEEP_DAYS
  find "${LOG_DIR}" -name "*.log.gz" -mtime "+${KEEP_DAYS}" \
    -exec rm -v {} \; 2>/dev/null || true

  # Rotate files larger than MAX_SIZE_MB
  find "${LOG_DIR}" -name "*.log" -size "+${MAX_SIZE_MB}M" | while read -r logfile; do
    ROTATED="${logfile}.$(date +%Y%m%d%H%M%S)"
    mv "${logfile}" "${ROTATED}"
    gzip "${ROTATED}"
    touch "${logfile}"  # Re-create empty log file
    echo "${LOG_TAG} Rotated large file: ${logfile}"
  done
done

# Tell Nginx to re-open its log files (after we moved them)
if systemctl is-active --quiet nginx 2>/dev/null; then
  nginx -s reopen 2>/dev/null || true
  echo "${LOG_TAG} Sent reopen signal to Nginx"
fi

echo "${LOG_TAG} Log rotation complete ✅"
