#!/usr/bin/env bash
# =============================================================================
# ForgeOps Platform — podman-prune.sh
# Cleans up unused containers, images, volumes and networks.
# Run as a cron job to prevent the Oracle Free Tier disk from filling up.
#
# Recommended cron (run every day at 2am):
#   0 2 * * * /opt/forgeops/cleanup/podman-prune.sh >> /var/log/forgeops-prune.log 2>&1
# =============================================================================
set -euo pipefail

TIMESTAMP=$(date -u '+%Y-%m-%d %H:%M:%S UTC')
LOG_TAG="[forgeops-prune ${TIMESTAMP}]"

# Minimum free disk space (MB) that triggers an aggressive prune
DISK_THRESHOLD_MB=500
# Keep images newer than this (hours) — protects recent builds
IMAGE_KEEP_HOURS=48

echo "═══════════════════════════════════════════════════"
echo "${LOG_TAG} Starting Podman cleanup"
echo "═══════════════════════════════════════════════════"

# ── Disk space before ─────────────────────────────────────────────────────────
FREE_BEFORE=$(df -m /var/lib/containers 2>/dev/null | awk 'NR==2{print $4}' || df -m / | awk 'NR==2{print $4}')
echo "${LOG_TAG} Free disk space before: ${FREE_BEFORE} MB"

# ── Stopped containers ────────────────────────────────────────────────────────
echo "${LOG_TAG} Removing stopped containers..."
REMOVED_CONTAINERS=$(podman container prune --force 2>&1 || echo "none removed")
echo "${LOG_TAG} ${REMOVED_CONTAINERS}"

# ── Dangling images (untagged) ────────────────────────────────────────────────
echo "${LOG_TAG} Removing dangling images..."
REMOVED_DANGLING=$(podman image prune --force 2>&1 || echo "none removed")
echo "${LOG_TAG} ${REMOVED_DANGLING}"

# ── Old images (unused, older than IMAGE_KEEP_HOURS) ─────────────────────────
FREE_CURRENT=$(df -m /var/lib/containers 2>/dev/null | awk 'NR==2{print $4}' || df -m / | awk 'NR==2{print $4}')
if [[ "${FREE_CURRENT}" -lt "${DISK_THRESHOLD_MB}" ]]; then
  echo "${LOG_TAG} Low disk (${FREE_CURRENT} MB < ${DISK_THRESHOLD_MB} MB). Running aggressive image prune..."
  REMOVED_OLD=$(podman image prune --all --force \
    --filter "until=${IMAGE_KEEP_HOURS}h" 2>&1 || echo "none removed")
  echo "${LOG_TAG} ${REMOVED_OLD}"
else
  echo "${LOG_TAG} Disk OK (${FREE_CURRENT} MB). Skipping aggressive image prune."
fi

# ── Unused volumes ────────────────────────────────────────────────────────────
echo "${LOG_TAG} Removing unused volumes..."
REMOVED_VOLUMES=$(podman volume prune --force 2>&1 || echo "none removed")
echo "${LOG_TAG} ${REMOVED_VOLUMES}"

# ── Unused networks ───────────────────────────────────────────────────────────
echo "${LOG_TAG} Removing unused networks..."
REMOVED_NETWORKS=$(podman network prune --force 2>&1 || echo "none removed")
echo "${LOG_TAG} ${REMOVED_NETWORKS}"

# ── Podman system df (storage report) ────────────────────────────────────────
echo "${LOG_TAG} Podman storage report:"
podman system df 2>/dev/null || true

# ── Disk space after ──────────────────────────────────────────────────────────
FREE_AFTER=$(df -m /var/lib/containers 2>/dev/null | awk 'NR==2{print $4}' || df -m / | awk 'NR==2{print $4}')
RECLAIMED=$((FREE_AFTER - FREE_BEFORE))
echo ""
echo "${LOG_TAG} ─────────────────────────────────"
echo "${LOG_TAG} Free before: ${FREE_BEFORE} MB"
echo "${LOG_TAG} Free after:  ${FREE_AFTER} MB"
echo "${LOG_TAG} Reclaimed:   ${RECLAIMED} MB"
echo "${LOG_TAG} Cleanup complete ✅"
echo "═══════════════════════════════════════════════════"
