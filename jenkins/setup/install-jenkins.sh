#!/usr/bin/env bash
# =============================================================================
# ForgeOps Platform — Jenkins Installation Script
# Installs Jenkins LTS inside a Podman (rootless) container on Ubuntu 22.04
# =============================================================================
set -euo pipefail

# ──────────────────────────────────────────────────────────────────────────────
# Configuration
# ──────────────────────────────────────────────────────────────────────────────
JENKINS_IMAGE="docker.io/jenkins/jenkins:lts-jdk17"
JENKINS_CONTAINER_NAME="jenkins"
JENKINS_HOME="/opt/forgeops/jenkins_home"
JENKINS_HTTP_PORT="8080"
JENKINS_AGENT_PORT="50000"
JENKINS_MEMORY="512m"          # Safe for Oracle Free Tier (1 GB RAM)
JENKINS_CPUS="0.8"             # Leave headroom for Nginx and OS

# Text colours
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m' # No Colour

log()    { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()   { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error()  { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }
header() { echo -e "\n${CYAN}════════════════════════════════════════${NC}"; echo -e "${CYAN} $*${NC}"; echo -e "${CYAN}════════════════════════════════════════${NC}"; }

# ──────────────────────────────────────────────────────────────────────────────
# Pre-flight checks
# ──────────────────────────────────────────────────────────────────────────────
header "ForgeOps — Jenkins Installer"

if [[ $EUID -eq 0 ]]; then
  error "Do NOT run as root. Podman rootless requires a regular user."
fi

command -v podman &>/dev/null || error "Podman is not installed. Run: sudo apt-get install -y podman"

log "Podman version: $(podman --version)"

# ──────────────────────────────────────────────────────────────────────────────
# Prepare persistent storage
# ──────────────────────────────────────────────────────────────────────────────
header "Setting up persistent storage"

sudo mkdir -p "${JENKINS_HOME}"
sudo chown -R "$(id -u):$(id -g)" "${JENKINS_HOME}"
chmod 755 "${JENKINS_HOME}"
log "Jenkins home: ${JENKINS_HOME}"

# ──────────────────────────────────────────────────────────────────────────────
# Configure Podman networking (rootless)
# ──────────────────────────────────────────────────────────────────────────────
header "Configuring rootless Podman networking"

# Enable lingering so user containers survive logout
loginctl enable-linger "$(whoami)" 2>/dev/null || warn "loginctl not available — containers may stop on logout"

# Ensure slirp4netns or pasta is available for rootless networking
if command -v slirp4netns &>/dev/null; then
  log "slirp4netns available: $(slirp4netns --version 2>&1 | head -1)"
elif command -v pasta &>/dev/null; then
  log "pasta (passt) available for networking"
else
  warn "Neither slirp4netns nor pasta found. Installing slirp4netns..."
  sudo apt-get install -y slirp4netns
fi

# ──────────────────────────────────────────────────────────────────────────────
# Remove existing Jenkins container (idempotent re-runs)
# ──────────────────────────────────────────────────────────────────────────────
header "Cleaning up any existing Jenkins container"

if podman container exists "${JENKINS_CONTAINER_NAME}" 2>/dev/null; then
  log "Stopping existing container..."
  podman stop "${JENKINS_CONTAINER_NAME}" || true
  podman rm "${JENKINS_CONTAINER_NAME}" || true
  log "Old container removed."
else
  log "No existing container found — fresh install."
fi

# ──────────────────────────────────────────────────────────────────────────────
# Pull Jenkins image
# ──────────────────────────────────────────────────────────────────────────────
header "Pulling Jenkins LTS image"
podman pull "${JENKINS_IMAGE}"
log "Image pulled successfully."

# ──────────────────────────────────────────────────────────────────────────────
# Start Jenkins container
# ──────────────────────────────────────────────────────────────────────────────
header "Starting Jenkins container"

podman run -d \
  --name "${JENKINS_CONTAINER_NAME}" \
  --restart unless-stopped \
  -p "127.0.0.1:${JENKINS_HTTP_PORT}:8080" \
  -p "127.0.0.1:${JENKINS_AGENT_PORT}:50000" \
  -v "${JENKINS_HOME}:/var/jenkins_home:Z" \
  -v "/run/user/$(id -u)/podman/podman.sock:/run/user/1000/podman/podman.sock:ro,Z" \
  --memory="${JENKINS_MEMORY}" \
  --cpus="${JENKINS_CPUS}" \
  --security-opt=no-new-privileges:true \
  --env JAVA_OPTS="-Djenkins.install.runSetupWizard=false \
    -Dhudson.model.DirectoryBrowserSupport.CSP=\"default-src 'self'\" \
    -Xmx400m -Xms200m" \
  --env JENKINS_OPTS="--prefix=/jenkins" \
  --label "app=jenkins" \
  --label "managed-by=forgeops" \
  "${JENKINS_IMAGE}"

log "Jenkins container started."

# ──────────────────────────────────────────────────────────────────────────────
# Wait for Jenkins to boot
# ──────────────────────────────────────────────────────────────────────────────
header "Waiting for Jenkins to initialise"

MAX_WAIT=120
ELAPSED=0
until curl -sf "http://127.0.0.1:${JENKINS_HTTP_PORT}/jenkins/login" &>/dev/null; do
  if [[ $ELAPSED -ge $MAX_WAIT ]]; then
    error "Jenkins did not start within ${MAX_WAIT}s. Check: podman logs ${JENKINS_CONTAINER_NAME}"
  fi
  printf "."
  sleep 5
  ELAPSED=$((ELAPSED + 5))
done
echo ""
log "Jenkins is up at http://127.0.0.1:${JENKINS_HTTP_PORT}/jenkins"

# ──────────────────────────────────────────────────────────────────────────────
# Retrieve initial admin password
# ──────────────────────────────────────────────────────────────────────────────
header "Initial Admin Password"

INIT_PASSWORD_FILE="${JENKINS_HOME}/secrets/initialAdminPassword"
if [[ -f "${INIT_PASSWORD_FILE}" ]]; then
  INIT_PASSWORD=$(cat "${INIT_PASSWORD_FILE}")
  log "Initial admin password: ${INIT_PASSWORD}"
  echo ""
  echo -e "${YELLOW}┌─────────────────────────────────────────────────────┐${NC}"
  echo -e "${YELLOW}│  SAVE THIS PASSWORD — needed to unlock Jenkins UI   │${NC}"
  echo -e "${YELLOW}│                                                     │${NC}"
  echo -e "${YELLOW}│  ${INIT_PASSWORD}  │${NC}"
  echo -e "${YELLOW}└─────────────────────────────────────────────────────┘${NC}"
else
  warn "Password file not found yet. Retrieve with:"
  echo "  podman exec ${JENKINS_CONTAINER_NAME} cat /var/jenkins_home/secrets/initialAdminPassword"
fi

# ──────────────────────────────────────────────────────────────────────────────
# Install systemd user service (auto-start on boot)
# ──────────────────────────────────────────────────────────────────────────────
header "Installing systemd user service"

SYSTEMD_USER_DIR="${HOME}/.config/systemd/user"
mkdir -p "${SYSTEMD_USER_DIR}"

podman generate systemd \
  --name "${JENKINS_CONTAINER_NAME}" \
  --restart-policy unless-stopped \
  --new \
  > "${SYSTEMD_USER_DIR}/container-jenkins.service"

systemctl --user daemon-reload
systemctl --user enable container-jenkins.service

log "Systemd service enabled: container-jenkins.service"
log "Start:   systemctl --user start container-jenkins"
log "Stop:    systemctl --user stop container-jenkins"
log "Status:  systemctl --user status container-jenkins"

# ──────────────────────────────────────────────────────────────────────────────
# Summary
# ──────────────────────────────────────────────────────────────────────────────
header "Installation Complete"
echo ""
echo -e "  Jenkins URL (internal):  ${CYAN}http://127.0.0.1:${JENKINS_HTTP_PORT}/jenkins${NC}"
echo -e "  Jenkins Home:            ${CYAN}${JENKINS_HOME}${NC}"
echo -e "  Container Name:          ${CYAN}${JENKINS_CONTAINER_NAME}${NC}"
echo ""
echo -e "  Next steps:"
echo -e "    1. Configure Nginx reverse proxy (see nginx/conf.d/jenkins.conf)"
echo -e "    2. Open https://your-domain.com/jenkins and complete setup"
echo -e "    3. Run ${CYAN}./jenkins/setup/configure-jenkins.sh${NC} to install plugins"
echo ""
