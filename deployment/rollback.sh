#!/usr/bin/env bash
# =============================================================================
# ForgeOps Platform — rollback.sh
# Rolls back a container to the previously deployed image.
#
# Usage:
#   ./rollback.sh --app my-app [--port 3000]
# =============================================================================
set -euo pipefail

APP_NAME=""
HOST_PORT="3000"
STATE_DIR="/opt/forgeops/state"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
log()   { echo -e "${GREEN}[rollback]${NC} $*"; }
warn()  { echo -e "${YELLOW}[rollback]${NC} $*"; }
error() { echo -e "${RED}[rollback]${NC} $*" >&2; exit 1; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --app)   APP_NAME="$2";  shift 2 ;;
    --port)  HOST_PORT="$2"; shift 2 ;;
    *) error "Unknown argument: $1" ;;
  esac
done

[[ -z "${APP_NAME}" ]] && error "--app is required"

PREVIOUS_IMAGE_FILE="${STATE_DIR}/${APP_NAME}.previous"

if [[ ! -f "${PREVIOUS_IMAGE_FILE}" ]]; then
  error "No rollback image found for ${APP_NAME} (expected: ${PREVIOUS_IMAGE_FILE})"
fi

PREVIOUS_IMAGE=$(cat "${PREVIOUS_IMAGE_FILE}")
[[ -z "${PREVIOUS_IMAGE}" ]] && error "Rollback image file is empty."

log "════════════════════════════════════════════════"
log " Rolling back: ${APP_NAME}"
log " Restoring to: ${PREVIOUS_IMAGE}"
log "════════════════════════════════════════════════"

# Stop & remove current (failed) container
if podman container exists "${APP_NAME}" 2>/dev/null; then
  log "Stopping failed container..."
  podman stop --time=15 "${APP_NAME}" || true
  podman rm "${APP_NAME}" || true
fi

# Start previous image
log "Starting rollback container..."
podman run -d \
  --name "${APP_NAME}" \
  --restart unless-stopped \
  -p "${HOST_PORT}:3000" \
  --memory="256m" \
  --cpus="0.5" \
  --security-opt=no-new-privileges:true \
  --read-only \
  --tmpfs /tmp:rw,noexec,nosuid,size=64m \
  --cap-drop=ALL \
  --label "app=${APP_NAME}" \
  --label "rollback=true" \
  --label "rollback.time=$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  "${PREVIOUS_IMAGE}"

sleep 3
STATUS=$(podman inspect "${APP_NAME}" --format '{{.State.Status}}' 2>/dev/null || echo "unknown")

if [[ "${STATUS}" != "running" ]]; then
  error "Rollback container failed to start. Status: ${STATUS}"
fi

log "✅ Rollback complete. Running image: ${PREVIOUS_IMAGE}"

# Clear the rollback pointer so we don't re-rollback to a bad image
rm -f "${PREVIOUS_IMAGE_FILE}"
warn "Rollback reference cleared. Run deploy.sh to move forward again."
