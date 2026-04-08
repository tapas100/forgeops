#!/usr/bin/env bash
# =============================================================================
# ForgeOps Platform — deploy.sh
# Generic Podman-based deployment script.
# Stops/removes the old container, starts the new one.
#
# Usage:
#   ./deploy.sh --app my-app --image registry/my-app:v1.2 --port 3000
#   ./deploy.sh --app my-app --image registry/my-app:v1.2 --port 3000 --env-file /etc/myapp.env
# =============================================================================
set -euo pipefail

# ── Defaults ──────────────────────────────────────────────────────────────────
APP_NAME=""
IMAGE=""
HOST_PORT=""
ENV_FILE=""
MEMORY="256m"       # Hetzner CAX11: 4 GB total — Jenkins takes 2.5 GB, each app gets 256m
CPUS="0.4"          # 0.4 of 2 vCPUs per app container
RESTART_POLICY="unless-stopped"
# Directory that holds a file named "${APP_NAME}.previous" with the last image ref
STATE_DIR="/opt/forgeops/state"

# ── Colour helpers ─────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
log()   { echo -e "${GREEN}[deploy]${NC} $*"; }
warn()  { echo -e "${YELLOW}[deploy]${NC} $*"; }
error() { echo -e "${RED}[deploy]${NC} $*" >&2; exit 1; }

# ── Argument parsing ──────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    --app)       APP_NAME="$2";    shift 2 ;;
    --image)     IMAGE="$2";       shift 2 ;;
    --port)      HOST_PORT="$2";   shift 2 ;;
    --env-file)  ENV_FILE="$2";    shift 2 ;;
    --memory)    MEMORY="$2";      shift 2 ;;
    --cpus)      CPUS="$2";        shift 2 ;;
    *) error "Unknown argument: $1" ;;
  esac
done

# ── Validate ─────────────────────────────────────────────────────────────────
[[ -z "${APP_NAME}" ]] && error "--app is required"
[[ -z "${IMAGE}" ]]    && error "--image is required"
[[ -z "${HOST_PORT}" ]] && error "--port is required"

CONTAINER_NAME="${APP_NAME}"

log "════════════════════════════════════════════════"
log " Deploying: ${APP_NAME}"
log " Image:     ${IMAGE}"
log " Port:      ${HOST_PORT} → 3000 (container)"
log "════════════════════════════════════════════════"

# ── Record current image for rollback ─────────────────────────────────────────
mkdir -p "${STATE_DIR}"
CURRENT_IMAGE_FILE="${STATE_DIR}/${APP_NAME}.previous"

if podman container exists "${CONTAINER_NAME}" 2>/dev/null; then
  CURRENT_IMAGE=$(podman inspect "${CONTAINER_NAME}" \
      --format '{{.Config.Image}}' 2>/dev/null || echo "")
  echo "${CURRENT_IMAGE}" > "${CURRENT_IMAGE_FILE}"
  log "Saved rollback reference: ${CURRENT_IMAGE}"
fi

# ── Pull latest image ─────────────────────────────────────────────────────────
log "Pulling image: ${IMAGE}"
podman pull "${IMAGE}"

# ── Stop and remove old container ────────────────────────────────────────────
if podman container exists "${CONTAINER_NAME}" 2>/dev/null; then
  log "Stopping container: ${CONTAINER_NAME}"
  podman stop --time=30 "${CONTAINER_NAME}" || warn "Container did not stop cleanly (continuing)"

  log "Removing container: ${CONTAINER_NAME}"
  podman rm "${CONTAINER_NAME}" || warn "Container removal returned non-zero (may already be gone)"
else
  log "No existing container to remove."
fi

# ── Build env-file flag ───────────────────────────────────────────────────────
ENV_FLAG=""
if [[ -n "${ENV_FILE}" && -f "${ENV_FILE}" ]]; then
  ENV_FLAG="--env-file=${ENV_FILE}"
  log "Loading env vars from: ${ENV_FILE}"
fi

# ── Start new container ───────────────────────────────────────────────────────
log "Starting container: ${CONTAINER_NAME}"

podman run -d \
  --name "${CONTAINER_NAME}" \
  --restart "${RESTART_POLICY}" \
  -p "${HOST_PORT}:3000" \
  --memory="${MEMORY}" \
  --cpus="${CPUS}" \
  --security-opt=no-new-privileges:true \
  --read-only \
  --tmpfs /tmp:rw,noexec,nosuid,size=64m \
  --cap-drop=ALL \
  --label "app=${APP_NAME}" \
  --label "image=${IMAGE}" \
  --label "deploy.time=$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --label "managed-by=forgeops" \
  ${ENV_FLAG} \
  "${IMAGE}"

log "Container started. Verifying status..."
sleep 3

CONTAINER_STATUS=$(podman inspect "${CONTAINER_NAME}" \
    --format '{{.State.Status}}' 2>/dev/null || echo "unknown")

if [[ "${CONTAINER_STATUS}" != "running" ]]; then
  error "Container did not start properly. Status: ${CONTAINER_STATUS}"
fi

log "✅ Deployment complete."
log "   Container: ${CONTAINER_NAME}  Status: ${CONTAINER_STATUS}"
log "   Listening on port: ${HOST_PORT}"
