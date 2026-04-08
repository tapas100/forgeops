#!/usr/bin/env bash
# =============================================================================
# ForgeOps Platform — Jenkins Installation Script
# Installs Jenkins LTS inside a Podman (rootless) container
#
# TARGET: Oracle Cloud Always Free Tier — VM.Standard.A1.Flex (Ampere ARM)
#   OS    : Ubuntu 22.04 Minimal (Canonical)  ← lean, no snap, no GUI
#   Shape : 2 OCPU (ARM aarch64) | 12 GB RAM | ~50 GB boot volume
#   Free pool: 4 OCPU + 24 GB RAM total across all Always Free instances
#
# What this script does automatically:
#   1. Installs ALL required packages  (podman, curl, git, fuse-overlayfs …)
#   2. Skips swap creation             → 12 GB RAM is more than sufficient
#   3. Tunes kernel for performance    (not memory-saving)
#   4. Disables wasteful OS services   (snapd, multipathd, apport …)
#   5. Configures Podman rootless      (subuid/subgid, socket, storage)
#   6. Starts Jenkins with G1GC + generous heap (fast builds, parallel stages)
#   7. Installs a systemd user service for auto-start on every reboot
#
# WHY NOT "PODMAN LITE"?
#   Podman IS already the lightweight alternative to Docker.
#   It is daemonless (zero background process when idle),
#   rootless (no root daemon), and uses ~0 MB RAM when not running.
#   There is no lighter container runtime suitable for production use.
# =============================================================================
set -euo pipefail

# ──────────────────────────────────────────────────────────────────────────────
# Configuration — edit these if needed
# ──────────────────────────────────────────────────────────────────────────────
JENKINS_IMAGE="docker.io/jenkins/jenkins:lts-jdk17"
JENKINS_CONTAINER_NAME="jenkins"
JENKINS_HOME="/opt/forgeops/jenkins_home"
JENKINS_HTTP_PORT="8080"
JENKINS_AGENT_PORT="50000"

# Memory limits for the Jenkins container
# A1.Flex 2 OCPU / 12 GB — Jenkins gets 4 GB, leaving 8 GB for the OS,
# Nginx, Podman builds, and up to 3 parallel app containers.
JENKINS_MEMORY="4g"            # Hard container memory limit
JENKINS_MEMORY_SWAP="4g"       # Same as limit — no need for swap
JENKINS_JVM_MAX_HEAP="2g"      # -Xmx  — G1GC works well at 2 GB+
JENKINS_JVM_MIN_HEAP="512m"    # -Xms  — start with 512 MB, grow as needed
JENKINS_JVM_METASPACE="256m"   # Class metadata — plenty of room
JENKINS_CPUS="1.8"             # Use 1.8 of 2 OCPUs — leave 0.2 for OS

SWAP_FILE="/swapfile"
SWAP_SIZE_GB=0                 # No swap needed — 12 GB RAM is sufficient

# ── Colours ───────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'
YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'

log()    { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()   { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error()  { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }
ok()     { echo -e "${GREEN}[ OK ]${NC}  $*"; }
header() {
  echo -e "\n${CYAN}════════════════════════════════════════════════${NC}"
  echo -e "${CYAN}  $*${NC}"
  echo -e "${CYAN}════════════════════════════════════════════════${NC}"
}

# ──────────────────────────────────────────────────────────────────────────────
# Pre-flight checks
# ──────────────────────────────────────────────────────────────────────────────
header "ForgeOps — Jenkins Installer (Ubuntu 22.04 Minimal / Ampere A1.Flex)"

[[ $EUID -eq 0 ]] && error "Do NOT run as root. Podman rootless requires a regular user."

ARCH=$(uname -m)
log "OS: $(grep PRETTY_NAME /etc/os-release | cut -d= -f2 | tr -d '\"')  |  Arch: ${ARCH}"
[[ "${ARCH}" != "aarch64" ]] && warn "Arch is ${ARCH} — this script is optimised for aarch64 (Ampere A1.Flex)."

# ──────────────────────────────────────────────────────────────────────────────
# Step 1 — Install ALL required packages from apt
# (Ubuntu 22.04 Minimal ships with very little — we install everything needed)
# ──────────────────────────────────────────────────────────────────────────────
header "Step 1 — Installing required packages"

sudo apt-get update -qq

PACKAGES=(
  # Container runtime (daemonless, rootless — the point of this platform)
  podman              # Main container engine
  fuse-overlayfs      # Efficient overlay filesystem for rootless Podman
  slirp4netns         # Rootless container networking
  uidmap              # newuidmap/newgidmap for user namespace mapping
  buildah             # OCI image builder (used by Podman internally)

  # System utilities
  curl                # HTTP client — health checks, Jenkins CLI
  wget                # Alternative downloader
  git                 # Source control
  jq                  # JSON parser — used in helper scripts
  ca-certificates     # SSL root certificates
  gnupg               # GPG key handling
  lsb-release         # OS version detection

  # Diagnostics
  net-tools           # netstat / ifconfig
  htop                # Process monitor
  iotop               # Disk I/O monitor
  sysstat             # iostat / mpstat for performance profiling
)

for pkg in "${PACKAGES[@]}"; do
  if dpkg -l "${pkg}" &>/dev/null 2>&1; then
    log "Already installed: ${pkg}"
  else
    log "Installing: ${pkg} ..."
    sudo apt-get install -y -qq "${pkg}"
    ok "Installed: ${pkg}"
  fi
done

ok "All packages ready."
log "Podman: $(podman --version)"

# ──────────────────────────────────────────────────────────────────────────────
# Step 2 — Swap file (2 GB) → effective 3 GB memory
# ──────────────────────────────────────────────────────────────────────────────
header "Step 2 — Memory check (12 GB RAM — no swap needed)"

TOTAL_RAM_MB=$(awk '/MemTotal/ {print int($2/1024)}' /proc/meminfo)
log "Total RAM: ${TOTAL_RAM_MB} MB"

if [[ ${TOTAL_RAM_MB} -ge 8000 ]]; then
  ok "Excellent! ${TOTAL_RAM_MB} MB RAM detected — Ampere A1.Flex confirmed."
  ok "No swap file needed. Jenkins gets 4 GB, OS + builds get the rest."
elif [[ ${TOTAL_RAM_MB} -ge 1800 ]]; then
  log "Moderate RAM (${TOTAL_RAM_MB} MB) — skipping swap, still sufficient for Jenkins."
else
  warn "Only ${TOTAL_RAM_MB} MB RAM — creating ${SWAP_SIZE_GB} GB swap as fallback..."
  if ! swapon --show | grep -q "${SWAP_FILE}"; then
    sudo fallocate -l "${SWAP_SIZE_GB}G" "${SWAP_FILE}" 2>/dev/null \
      || sudo dd if=/dev/zero of="${SWAP_FILE}" bs=1M count=$((SWAP_SIZE_GB * 1024)) status=progress
    sudo chmod 600 "${SWAP_FILE}"
    sudo mkswap  "${SWAP_FILE}"
    sudo swapon  "${SWAP_FILE}"
    grep -q "${SWAP_FILE}" /etc/fstab \
      || echo "${SWAP_FILE} none swap sw 0 0" | sudo tee -a /etc/fstab
    ok "Swap created and activated."
  fi
fi

log "Memory layout:"
free -h | awk 'NR<=3 {printf "  %s\n", $0}'

# ──────────────────────────────────────────────────────────────────────────────
# Step 3 — Kernel tuning for performance (A1.Flex 2 OCPU / 12 GB)
# ──────────────────────────────────────────────────────────────────────────────
header "Step 3 — Kernel performance tuning"

apply_sysctl() {
  local key="$1" val="$2"
  sudo sysctl -w "${key}=${val}" &>/dev/null
  grep -q "^${key}" /etc/sysctl.conf 2>/dev/null \
    || echo "${key}=${val}" | sudo tee -a /etc/sysctl.conf &>/dev/null
  log "sysctl ${key}=${val}"
}

# With 12 GB RAM we tune for throughput, not memory saving
apply_sysctl vm.swappiness              1    # Almost never swap — we have plenty of RAM
apply_sysctl vm.vfs_cache_pressure      50   # Retain directory/inode cache longer
apply_sysctl vm.overcommit_memory       1    # Allow JVM fork() overcommit
apply_sysctl vm.dirty_ratio             20   # More write buffering → faster builds
apply_sysctl vm.dirty_background_ratio  5    # Start flushing early in background
apply_sysctl net.core.somaxconn         1024 # Larger socket backlog for Jenkins HTTP
apply_sysctl fs.file-max                100000 # High open-file limit for containers
ok "Kernel tuning applied."

# ──────────────────────────────────────────────────────────────────────────────
# Step 4 — Disable wasteful OS services
# ──────────────────────────────────────────────────────────────────────────────
header "Step 4 — Disabling unused OS services"

DISABLE_SERVICES=(snapd snapd.socket multipathd apport motd-news.service motd-news.timer)
for svc in "${DISABLE_SERVICES[@]}"; do
  if systemctl list-unit-files "${svc}" &>/dev/null \
     && systemctl is-enabled "${svc}" &>/dev/null; then
    sudo systemctl disable --now "${svc}" &>/dev/null || true
    log "Disabled: ${svc}"
  fi
done

if dpkg -l snapd &>/dev/null 2>&1; then
  warn "Purging snapd (~80 MB RAM reclaimed) ..."
  sudo apt-get purge -y snapd &>/dev/null || true
  sudo apt-get autoremove -y  &>/dev/null || true
  ok "snapd purged."
fi

log "Memory after OS tuning:"
free -h | awk '{printf "  %s\n", $0}'

# ──────────────────────────────────────────────────────────────────────────────
# Step 5 — Configure Podman rootless
# ──────────────────────────────────────────────────────────────────────────────
header "Step 5 — Configuring Podman rootless"

loginctl enable-linger "$(whoami)" 2>/dev/null \
  || warn "loginctl unavailable — containers may stop on SSH logout"

USERNAME="$(whoami)"
grep -q "^${USERNAME}:" /etc/subuid 2>/dev/null \
  || echo "${USERNAME}:100000:65536" | sudo tee -a /etc/subuid
grep -q "^${USERNAME}:" /etc/subgid 2>/dev/null \
  || echo "${USERNAME}:100000:65536" | sudo tee -a /etc/subgid

systemctl --user enable --now podman.socket 2>/dev/null \
  || warn "Podman socket not started — may need re-login"

mkdir -p "${HOME}/.config/containers"
cat > "${HOME}/.config/containers/storage.conf" <<'STORAGECFG'
[storage]
  driver = "overlay"
  [storage.options]
    mount_program = "/usr/bin/fuse-overlayfs"
  [storage.options.overlay]
    mountopt = "nodev,metacopy=on"
STORAGECFG

cat > "${HOME}/.config/containers/containers.conf" <<'CONTAINERCFG'
[containers]
  default_ulimits = ["nofile=1024:1024"]
[engine]
  image_parallel_copies = 2
CONTAINERCFG

ok "Podman rootless configured."

# ──────────────────────────────────────────────────────────────────────────────
# Step 6 — Persistent storage for Jenkins
# ──────────────────────────────────────────────────────────────────────────────
header "Step 6 — Setting up Jenkins persistent storage"

sudo mkdir -p "${JENKINS_HOME}"
sudo chown -R "$(id -u):$(id -g)" "${JENKINS_HOME}"
chmod 755 "${JENKINS_HOME}"
ok "Jenkins home: ${JENKINS_HOME}"

# ──────────────────────────────────────────────────────────────────────────────
# Step 7 — Remove any existing Jenkins container (idempotent re-runs)
# ──────────────────────────────────────────────────────────────────────────────
header "Step 7 — Cleaning up any existing Jenkins container"

if podman container exists "${JENKINS_CONTAINER_NAME}" 2>/dev/null; then
  log "Stopping and removing existing container ..."
  podman stop --time=20 "${JENKINS_CONTAINER_NAME}" || true
  podman rm "${JENKINS_CONTAINER_NAME}" || true
  ok "Old container removed."
else
  log "No existing container — fresh install."
fi

# ──────────────────────────────────────────────────────────────────────────────
# Step 8 — Pull Jenkins LTS image
# ──────────────────────────────────────────────────────────────────────────────
header "Step 8 — Pulling Jenkins LTS image (~470 MB, takes 2-5 min)"

podman pull "${JENKINS_IMAGE}"
ok "Image pulled: ${JENKINS_IMAGE}"

# ──────────────────────────────────────────────────────────────────────────────
# Step 9 — Start Jenkins (G1GC, generous heap — tuned for A1.Flex 2 OCPU / 12 GB)
# ──────────────────────────────────────────────────────────────────────────────
header "Step 9 — Starting Jenkins container"

PODMAN_SOCK="/run/user/$(id -u)/podman/podman.sock"

podman run -d \
  --name  "${JENKINS_CONTAINER_NAME}" \
  --restart unless-stopped \
  -p "127.0.0.1:${JENKINS_HTTP_PORT}:8080" \
  -p "127.0.0.1:${JENKINS_AGENT_PORT}:50000" \
  -v "${JENKINS_HOME}:/var/jenkins_home:Z" \
  -v "${PODMAN_SOCK}:/run/user/1000/podman/podman.sock:ro,Z" \
  --memory="${JENKINS_MEMORY}" \
  --memory-swap="${JENKINS_MEMORY_SWAP}" \
  --cpus="${JENKINS_CPUS}" \
  --security-opt=no-new-privileges:true \
  --cap-drop=ALL \
  --cap-add=SETUID --cap-add=SETGID --cap-add=CHOWN --cap-add=DAC_OVERRIDE \
  --env JAVA_OPTS=" \
    -Xmx${JENKINS_JVM_MAX_HEAP} \
    -Xms${JENKINS_JVM_MIN_HEAP} \
    -XX:MaxMetaspaceSize=${JENKINS_JVM_METASPACE} \
    -XX:+UseG1GC \
    -XX:G1HeapRegionSize=16m \
    -XX:+UseStringDeduplication \
    -XX:+ParallelRefProcEnabled \
    -Djava.awt.headless=true \
    -Djenkins.install.runSetupWizard=false \
    -Dhudson.model.DirectoryBrowserSupport.CSP=default-src 'self'" \
  --env JENKINS_OPTS="--prefix=/jenkins --sessionTimeout=60 --sessionEviction=3600" \
  --label "app=jenkins" \
  --label "managed-by=forgeops" \
  --label "shape=VM.Standard.A1.Flex" \
  "${JENKINS_IMAGE}"

ok "Jenkins container started."

# ──────────────────────────────────────────────────────────────────────────────
# Step 10 — Wait for Jenkins to boot (slow on 1 OCPU — allow 4 min)
# ──────────────────────────────────────────────────────────────────────────────
header "Step 10 — Waiting for Jenkins to initialise (A1.Flex is fast — ~60s)"

MAX_WAIT=180
ELAPSED=0
printf "  Waiting"
until curl -sf "http://127.0.0.1:${JENKINS_HTTP_PORT}/jenkins/login" &>/dev/null; do
  [[ ${ELAPSED} -ge ${MAX_WAIT} ]] \
    && { echo ""; error "Jenkins did not start in ${MAX_WAIT}s.\n  Debug: podman logs ${JENKINS_CONTAINER_NAME}"; }
  printf "."
  sleep 5
  ELAPSED=$((ELAPSED + 5))
done
echo ""
ok "Jenkins is up! (${ELAPSED}s)"

# ──────────────────────────────────────────────────────────────────────────────
# Step 11 — Show initial admin password
# ──────────────────────────────────────────────────────────────────────────────
header "Step 11 — Initial Admin Password"

INIT_PASSWORD_FILE="${JENKINS_HOME}/secrets/initialAdminPassword"
if [[ -f "${INIT_PASSWORD_FILE}" ]]; then
  INIT_PASSWORD=$(cat "${INIT_PASSWORD_FILE}")
  echo ""
  echo -e "${YELLOW}  ╔══════════════════════════════════════════════════════╗${NC}"
  echo -e "${YELLOW}  ║   SAVE THIS — needed to unlock Jenkins UI           ║${NC}"
  echo -e "${YELLOW}  ╠══════════════════════════════════════════════════════╣${NC}"
  echo -e "${YELLOW}  ║   ${CYAN}${INIT_PASSWORD}${YELLOW}   ║${NC}"
  echo -e "${YELLOW}  ╚══════════════════════════════════════════════════════╝${NC}"
  echo ""
else
  warn "Password file not found yet. Run:"
  echo "  podman exec ${JENKINS_CONTAINER_NAME} cat /var/jenkins_home/secrets/initialAdminPassword"
fi

# ──────────────────────────────────────────────────────────────────────────────
# Step 12 — Systemd user service (Jenkins auto-starts on every reboot)
# ──────────────────────────────────────────────────────────────────────────────
header "Step 12 — Installing systemd auto-start service"

SYSTEMD_USER_DIR="${HOME}/.config/systemd/user"
mkdir -p "${SYSTEMD_USER_DIR}"

podman generate systemd \
  --name "${JENKINS_CONTAINER_NAME}" \
  --restart-policy unless-stopped \
  --new \
  > "${SYSTEMD_USER_DIR}/container-jenkins.service"

systemctl --user daemon-reload
systemctl --user enable container-jenkins.service
ok "Systemd service installed: container-jenkins.service"

# ──────────────────────────────────────────────────────────────────────────────
# Memory snapshot after full install
# ──────────────────────────────────────────────────────────────────────────────
header "Memory snapshot (post-install)"
free -h
echo ""
log "Container resource usage:"
podman stats --no-stream "${JENKINS_CONTAINER_NAME}" \
  --format "  CPU: {{.CPUPerc}}   RAM: {{.MemUsage}}   RAM%: {{.MemPerc}}" 2>/dev/null || true

# ──────────────────────────────────────────────────────────────────────────────
# ✅ Summary
# ──────────────────────────────────────────────────────────────────────────────
header "✅  Installation Complete"
echo ""
echo -e "  VM shape:    ${CYAN}VM.Standard.A1.Flex  (2 OCPU ARM / 12 GB RAM)${NC}"
echo -e "  OS:          ${CYAN}Ubuntu 22.04 Minimal (aarch64)${NC}"
echo -e "  Podman:      ${CYAN}$(podman --version)  (rootless, daemonless)${NC}"
echo -e "  Jenkins RAM: ${CYAN}${JENKINS_MEMORY} container limit  |  ${JENKINS_JVM_MIN_HEAP}→${JENKINS_JVM_MAX_HEAP} heap  |  G1GC${NC}"
echo -e "  Jenkins URL: ${CYAN}http://127.0.0.1:${JENKINS_HTTP_PORT}/jenkins${NC}"
echo -e "  Executors:   ${CYAN}2  (parallel builds supported on A1.Flex)${NC}"
echo ""
echo -e "  ${YELLOW}Useful commands:${NC}"
echo -e "    podman logs -f ${JENKINS_CONTAINER_NAME}             # live logs"
echo -e "    podman stats   ${JENKINS_CONTAINER_NAME}             # RAM/CPU usage"
echo -e "    systemctl --user status container-jenkins  # service status"
echo -e "    systemctl --user restart container-jenkins # restart"
echo ""
echo -e "  ${YELLOW}Next steps:${NC}"
echo -e "    1. Copy Nginx config:  ${CYAN}sudo cp nginx/conf.d/jenkins.conf /etc/nginx/conf.d/${NC}"
echo -e "    2. Replace domain:     ${CYAN}sudo sed -i 's/YOUR_DOMAIN_HERE/ci.yourdomain.com/g' /etc/nginx/conf.d/jenkins.conf${NC}"
echo -e "    3. Get TLS cert:       ${CYAN}sudo certbot --nginx -d ci.yourdomain.com${NC}"
echo -e "    4. Configure Jenkins:  ${CYAN}./jenkins/setup/configure-jenkins.sh${NC}"
echo ""