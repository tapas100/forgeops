#!/usr/bin/env bash
# =============================================================================
# ForgeOps Platform — Jenkins Installation Script
# Installs Jenkins LTS inside a Podman (rootless) container
#
# TARGET: Hetzner Cloud — CAX11 (Ampere ARM)
#   OS    : Ubuntu 22.04 (Canonical)
#   Server: 2 vCPU (ARM aarch64) | 4 GB RAM | 40 GB NVMe SSD
#   Cost  : €3.29/month  (~$3.50) — best value CI/CD server available
#   Region: Falkenstein / Nuremberg / Helsinki / Ashburn
#
# Why Hetzner over Oracle Free Tier:
#   ✅ Enterprise-grade NVMe SSD  (Oracle uses HDD)
#   ✅ 20 Gbps network            (Oracle: 0.48 Gbps)
#   ✅ Instant provisioning       (Oracle: capacity issues)
#   ✅ Stable — no surprise terminations
#   ✅ Real support
#
# What this script does automatically:
#   1. Installs ALL required packages  (podman, curl, git, fuse-overlayfs …)
#   2. Creates 2 GB swap as safety net (4 GB RAM — swap prevents OOM on big builds)
#   3. Tunes kernel for NVMe + ARM performance
#   4. Disables wasteful OS services   (snapd, multipathd, apport …)
#   5. Configures Podman rootless      (subuid/subgid, socket, storage)
#   6. Starts Jenkins with G1GC + balanced heap (2 GB — fits in 4 GB safely)
#   7. Installs a systemd user service for auto-start on every reboot
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

# Memory limits — Hetzner CAX11: 4 GB RAM
# Jenkins gets 2.5 GB, leaving ~1.5 GB for OS + Nginx + app containers
JENKINS_MEMORY="2500m"         # Hard container memory limit
JENKINS_MEMORY_SWAP="4g"       # Allow swap overflow on heavy builds
JENKINS_JVM_MAX_HEAP="1500m"   # -Xmx  — G1GC comfortable at 1.5 GB
JENKINS_JVM_MIN_HEAP="512m"    # -Xms  — start at 512m, grow as needed
JENKINS_JVM_METASPACE="192m"   # Class metadata space
JENKINS_CPUS="1.8"             # Use 1.8 of 2 vCPUs — leave 0.2 for OS

SWAP_FILE="/swapfile"
SWAP_SIZE_GB=2                 # 2 GB swap → 6 GB effective on heavy builds

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
header "ForgeOps — Jenkins Installer (Hetzner / Ubuntu 24.04 / x86_64)"

[[ $EUID -eq 0 ]] && error "Do NOT run as root. Podman rootless requires a regular user."

ARCH=$(uname -m)
OS_NAME=$(grep PRETTY_NAME /etc/os-release | cut -d= -f2 | tr -d '"')
log "OS: ${OS_NAME}  |  Arch: ${ARCH}"
log "Supported architectures: x86_64 and aarch64"

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
header "Step 2 — Memory check + swap setup (Hetzner CAX11: 4 GB RAM)"

TOTAL_RAM_MB=$(awk '/MemTotal/ {print int($2/1024)}' /proc/meminfo)
log "Total RAM: ${TOTAL_RAM_MB} MB"

if [[ ${TOTAL_RAM_MB} -ge 3500 ]]; then
  ok "${TOTAL_RAM_MB} MB RAM detected — Hetzner CAX11 confirmed."
  log "Creating ${SWAP_SIZE_GB} GB swap as safety net for heavy builds..."

  if swapon --show | grep -q "${SWAP_FILE}"; then
    ok "Swap already active at ${SWAP_FILE} — skipping."
  else
    sudo fallocate -l "${SWAP_SIZE_GB}G" "${SWAP_FILE}" 2>/dev/null \
      || sudo dd if=/dev/zero of="${SWAP_FILE}" bs=1M count=$((SWAP_SIZE_GB * 1024)) status=progress
    sudo chmod 600 "${SWAP_FILE}"
    sudo mkswap  "${SWAP_FILE}"
    sudo swapon  "${SWAP_FILE}"
    grep -q "${SWAP_FILE}" /etc/fstab \
      || echo "${SWAP_FILE} none swap sw 0 0" | sudo tee -a /etc/fstab
    ok "Swap created: ${SWAP_FILE} (${SWAP_SIZE_GB} GB) — total effective: $((TOTAL_RAM_MB/1024 + SWAP_SIZE_GB)) GB"
  fi
else
  warn "Only ${TOTAL_RAM_MB} MB RAM — creating ${SWAP_SIZE_GB} GB swap..."
  sudo fallocate -l "${SWAP_SIZE_GB}G" "${SWAP_FILE}" 2>/dev/null \
    || sudo dd if=/dev/zero of="${SWAP_FILE}" bs=1M count=$((SWAP_SIZE_GB * 1024)) status=progress
  sudo chmod 600 "${SWAP_FILE}"
  sudo mkswap "${SWAP_FILE}" && sudo swapon "${SWAP_FILE}"
  grep -q "${SWAP_FILE}" /etc/fstab \
    || echo "${SWAP_FILE} none swap sw 0 0" | sudo tee -a /etc/fstab
  ok "Swap activated."
fi

log "Memory layout:"
free -h | awk 'NR<=3 {printf "  %s\n", $0}'

# ──────────────────────────────────────────────────────────────────────────────
# Step 3 — Kernel tuning for NVMe + ARM performance (Hetzner CAX11)
# ──────────────────────────────────────────────────────────────────────────────
header "Step 3 — Kernel performance tuning"

apply_sysctl() {
  local key="$1" val="$2"
  sudo sysctl -w "${key}=${val}" &>/dev/null
  grep -q "^${key}" /etc/sysctl.conf 2>/dev/null \
    || echo "${key}=${val}" | sudo tee -a /etc/sysctl.conf &>/dev/null
  log "sysctl ${key}=${val}"
}

# Balanced — 4 GB RAM with swap safety net
apply_sysctl vm.swappiness              10   # Use swap only when RAM is low
apply_sysctl vm.vfs_cache_pressure      50   # Retain directory/inode cache longer
apply_sysctl vm.overcommit_memory       1    # Allow JVM fork() overcommit
apply_sysctl vm.dirty_ratio             20   # More write buffering → faster NVMe builds
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
  --env "JAVA_OPTS=-Xmx${JENKINS_JVM_MAX_HEAP} -Xms${JENKINS_JVM_MIN_HEAP} -XX:MaxMetaspaceSize=${JENKINS_JVM_METASPACE} -XX:+UseG1GC -XX:G1HeapRegionSize=16m -XX:+UseStringDeduplication -XX:+ParallelRefProcEnabled -Djava.awt.headless=true -Djenkins.install.runSetupWizard=false" \
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

# Enable linger so user services survive across reboots (no login needed)
sudo loginctl enable-linger "$(whoami)"

# Write a plain systemd user service file.
# NOTE: We do NOT use Quadlets here because Podman 4.9's Quadlet Environment=
# key splits multi-word values into separate --env args, breaking JAVA_OPTS.
# A plain service file with quoted --env arguments works correctly on all
# Podman versions >= 3.x.
SYSTEMD_USER_DIR="${HOME}/.config/systemd/user"
mkdir -p "${SYSTEMD_USER_DIR}"

cat > "${SYSTEMD_USER_DIR}/jenkins.service" <<SERVICE
[Unit]
Description=Jenkins CI/CD (ForgeOps — Podman rootless)
After=network-online.target
Wants=network-online.target

[Service]
Restart=always
RestartSec=10
TimeoutStartSec=300
ExecStartPre=/usr/bin/podman rm -f ${JENKINS_CONTAINER_NAME} 2>/dev/null || true
ExecStart=/usr/bin/podman run \\
  --name=${JENKINS_CONTAINER_NAME} \\
  --rm \\
  -p 127.0.0.1:${JENKINS_HTTP_PORT}:8080 \\
  -p 127.0.0.1:${JENKINS_AGENT_PORT}:50000 \\
  -v ${JENKINS_HOME}:/var/jenkins_home:Z \\
  --memory=${JENKINS_MEMORY} \\
  --memory-swap=${JENKINS_MEMORY_SWAP} \\
  --cpus=${JENKINS_CPUS} \\
  --security-opt=no-new-privileges:true \\
  --cap-drop=ALL \\
  --cap-add=SETUID --cap-add=SETGID --cap-add=CHOWN --cap-add=DAC_OVERRIDE \\
  --env "JAVA_OPTS=-Xmx${JENKINS_JVM_MAX_HEAP} -Xms${JENKINS_JVM_MIN_HEAP} -XX:MaxMetaspaceSize=${JENKINS_JVM_METASPACE} -XX:+UseG1GC -XX:G1HeapRegionSize=16m -XX:+UseStringDeduplication -XX:+ParallelRefProcEnabled -Djava.awt.headless=true -Djenkins.install.runSetupWizard=false" \\
  --env "JENKINS_OPTS=--prefix=/jenkins --sessionTimeout=60 --sessionEviction=3600" \\
  --label app=jenkins \\
  --label managed-by=forgeops \\
  ${JENKINS_IMAGE}
ExecStop=/usr/bin/podman stop -t 20 ${JENKINS_CONTAINER_NAME}

[Install]
WantedBy=default.target
SERVICE

systemctl --user daemon-reload
systemctl --user enable jenkins.service
ok "Systemd service installed and enabled: jenkins.service"

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
echo -e "  Server:      ${CYAN}Hetzner CX22  (2 vCPU x86_64 / 4 GB RAM / 40 GB NVMe)${NC}"
echo -e "  OS:          ${CYAN}Ubuntu 24.04 LTS (x86_64)${NC}"
echo -e "  Podman:      ${CYAN}$(podman --version)  (rootless, daemonless)${NC}"
echo -e "  Swap:        ${CYAN}${SWAP_SIZE_GB} GB  →  6 GB effective memory${NC}"
echo -e "  Jenkins RAM: ${CYAN}${JENKINS_MEMORY} container limit  |  ${JENKINS_JVM_MIN_HEAP}→${JENKINS_JVM_MAX_HEAP} heap  |  G1GC${NC}"
echo -e "  Jenkins URL: ${CYAN}http://127.0.0.1:${JENKINS_HTTP_PORT}/jenkins${NC}"
echo -e "  Executors:   ${CYAN}2  (parallel builds supported)${NC}"
echo ""
echo -e "  ${YELLOW}Useful commands:${NC}"
echo -e "    podman logs -f ${JENKINS_CONTAINER_NAME}             # live logs"
echo -e "    podman stats   ${JENKINS_CONTAINER_NAME}             # RAM/CPU usage"
echo -e "    systemctl --user status jenkins      # service status"
echo -e "    systemctl --user restart jenkins     # restart"
echo ""
echo -e "  ${YELLOW}Next steps:${NC}"
echo -e "    1. Install Nginx:      ${CYAN}sudo apt-get install -y nginx certbot python3-certbot-nginx${NC}"
echo -e "    2. Copy Nginx config:  ${CYAN}sudo cp nginx/conf.d/jenkins.conf /etc/nginx/conf.d/${NC}"
echo -e "    3. Replace domain:     ${CYAN}sudo sed -i 's/YOUR_DOMAIN_HERE/ci.yourdomain.com/g' /etc/nginx/conf.d/jenkins.conf${NC}"
echo -e "    4. Get TLS cert:       ${CYAN}sudo certbot --nginx -d ci.yourdomain.com${NC}"
echo -e "    5. Configure Jenkins:  ${CYAN}./jenkins/setup/configure-jenkins.sh${NC}"
echo ""