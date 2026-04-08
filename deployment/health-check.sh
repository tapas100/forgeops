#!/usr/bin/env bash
# =============================================================================
# ForgeOps Platform — health-check.sh
# Verifies a deployed container is healthy by polling its /health endpoint.
#
# Usage:
#   ./health-check.sh --app my-app --port 3000
#   ./health-check.sh --app my-app --port 3000 --path /ready --timeout 90
# =============================================================================
set -euo pipefail

APP_NAME=""
HOST_PORT="3000"
HEALTH_PATH="/health"
TIMEOUT=60        # seconds to keep retrying
INTERVAL=5        # seconds between retries
EXPECTED_STATUS="200"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
log()   { echo -e "${GREEN}[health]${NC} $*"; }
warn()  { echo -e "${YELLOW}[health]${NC} $*"; }
error() { echo -e "${RED}[health]${NC} $*" >&2; exit 1; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --app)     APP_NAME="$2";    shift 2 ;;
    --port)    HOST_PORT="$2";   shift 2 ;;
    --path)    HEALTH_PATH="$2"; shift 2 ;;
    --timeout) TIMEOUT="$2";     shift 2 ;;
    *) error "Unknown argument: $1" ;;
  esac
done

[[ -z "${APP_NAME}" ]] && error "--app is required"

HEALTH_URL="http://127.0.0.1:${HOST_PORT}${HEALTH_PATH}"

log "Checking health: ${HEALTH_URL}"
log "Timeout: ${TIMEOUT}s  Interval: ${INTERVAL}s"

ELAPSED=0
while [[ ${ELAPSED} -lt ${TIMEOUT} ]]; do
  HTTP_STATUS=$(curl -so /dev/null -w "%{http_code}" \
    --connect-timeout 5 --max-time 10 \
    "${HEALTH_URL}" 2>/dev/null || echo "000")

  if [[ "${HTTP_STATUS}" == "${EXPECTED_STATUS}" ]]; then
    log "✅ ${APP_NAME} is healthy (HTTP ${HTTP_STATUS}) after ${ELAPSED}s"

    # Also verify the container is still running
    CONTAINER_STATUS=$(podman inspect "${APP_NAME}" \
        --format '{{.State.Status}}' 2>/dev/null || echo "unknown")
    log "   Container status: ${CONTAINER_STATUS}"

    exit 0
  fi

  warn "Not ready yet (HTTP ${HTTP_STATUS}) — retrying in ${INTERVAL}s (${ELAPSED}/${TIMEOUT}s)"
  sleep "${INTERVAL}"
  ELAPSED=$((ELAPSED + INTERVAL))
done

# Dump container logs to aid debugging before failing
echo ""
warn "Container logs (last 50 lines):"
podman logs --tail=50 "${APP_NAME}" 2>/dev/null || true

error "Health check failed for ${APP_NAME} after ${TIMEOUT}s"
