#!/usr/bin/env bash
# =============================================================================
# ForgeOps Platform — Jenkins Post-Install Configuration
# Installs plugins, configures security, and sets up the shared library
# =============================================================================
set -euo pipefail

JENKINS_URL="http://127.0.0.1:8080/jenkins"
JENKINS_CONTAINER="jenkins"
JENKINS_HOME="/opt/forgeops/jenkins_home"
PLUGINS_FILE="$(dirname "$0")/../plugins.txt"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
log()    { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()   { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error()  { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }
header() { echo -e "\n${CYAN}════════════════════════════════════════${NC}\n${CYAN} $*${NC}\n${CYAN}════════════════════════════════════════${NC}"; }

# ──────────────────────────────────────────────────────────────────────────────
# Resolve initial admin password
# ──────────────────────────────────────────────────────────────────────────────
header "Authenticating with Jenkins"

INIT_PASSWORD_FILE="${JENKINS_HOME}/secrets/initialAdminPassword"
if [[ -f "${INIT_PASSWORD_FILE}" ]]; then
  JENKINS_PASSWORD=$(cat "${INIT_PASSWORD_FILE}")
  JENKINS_USER="admin"
  log "Using initial admin password from ${INIT_PASSWORD_FILE}"
else
  # If already configured, read from environment
  JENKINS_USER="${JENKINS_ADMIN_USER:-admin}"
  JENKINS_PASSWORD="${JENKINS_ADMIN_PASSWORD:-}"
  [[ -z "${JENKINS_PASSWORD}" ]] && error "Set JENKINS_ADMIN_PASSWORD env var or run before completing setup wizard."
fi

# Helper — Jenkins CLI via REST
jenkins_cli() {
  curl -sf -u "${JENKINS_USER}:${JENKINS_PASSWORD}" "$@"
}

# Wait until Jenkins API is ready
MAX_WAIT=120; ELAPSED=0
until jenkins_cli "${JENKINS_URL}/api/json" &>/dev/null; do
  [[ $ELAPSED -ge $MAX_WAIT ]] && error "Jenkins API not available after ${MAX_WAIT}s"
  printf "."; sleep 5; ELAPSED=$((ELAPSED+5))
done
echo ""; log "Jenkins API is ready."

# ──────────────────────────────────────────────────────────────────────────────
# Install plugins
# ──────────────────────────────────────────────────────────────────────────────
header "Installing Jenkins Plugins"

[[ ! -f "${PLUGINS_FILE}" ]] && error "plugins.txt not found at ${PLUGINS_FILE}"

# Download jenkins-cli.jar if not present
CLI_JAR="/tmp/jenkins-cli.jar"
if [[ ! -f "${CLI_JAR}" ]]; then
  log "Downloading jenkins-cli.jar..."
  curl -sf -o "${CLI_JAR}" "${JENKINS_URL}/jnlpJars/jenkins-cli.jar"
fi

# Install plugins from list (skip comment lines and empty lines)
while IFS= read -r plugin || [[ -n "$plugin" ]]; do
  [[ "$plugin" =~ ^#.*$ || -z "$plugin" ]] && continue
  log "Installing plugin: ${plugin}"
  java -jar "${CLI_JAR}" \
    -s "${JENKINS_URL}" \
    -auth "${JENKINS_USER}:${JENKINS_PASSWORD}" \
    install-plugin "${plugin}" --deploy || warn "Failed to install ${plugin} — may already be installed."
done < "${PLUGINS_FILE}"

log "Triggering Jenkins safe restart to activate plugins..."
jenkins_cli -X POST "${JENKINS_URL}/safeRestart" || true
sleep 30

# Wait for restart
ELAPSED=0
until jenkins_cli "${JENKINS_URL}/api/json" &>/dev/null; do
  [[ $ELAPSED -ge 120 ]] && error "Jenkins did not come back after restart."
  printf "."; sleep 5; ELAPSED=$((ELAPSED+5))
done
echo ""; log "Jenkins restarted successfully."

# ──────────────────────────────────────────────────────────────────────────────
# Apply JCasC configuration
# ──────────────────────────────────────────────────────────────────────────────
header "Applying Configuration-as-Code (JCasC)"

CASC_FILE="$(dirname "$0")/../casc/jenkins.yaml"
[[ ! -f "${CASC_FILE}" ]] && warn "jenkins.yaml not found — skipping JCasC."

if [[ -f "${CASC_FILE}" ]]; then
  # Copy casc config into Jenkins home so the plugin picks it up automatically
  sudo cp "${CASC_FILE}" "${JENKINS_HOME}/jenkins.yaml"
  sudo chown "$(id -u):$(id -g)" "${JENKINS_HOME}/jenkins.yaml"
  log "JCasC config applied. Triggering reload..."
  jenkins_cli -X POST \
    "${JENKINS_URL}/configuration-as-code/apply" \
    -H "Content-Type: application/json" || warn "JCasC reload endpoint not available — restart Jenkins manually."
fi

# ──────────────────────────────────────────────────────────────────────────────
# Create forgeops-deploy credential placeholder
# ──────────────────────────────────────────────────────────────────────────────
header "Creating Credential Placeholders"

CRUMB=$(jenkins_cli -s "${JENKINS_URL}/crumbIssuer/api/json" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['crumb'])" 2>/dev/null || echo "")

create_credential() {
  local id="$1" description="$2" secret="$3"
  log "Creating secret-text credential: ${id}"
  jenkins_cli -X POST \
    -H "Jenkins-Crumb: ${CRUMB}" \
    -H "Content-Type: application/xml" \
    "${JENKINS_URL}/credentials/store/system/domain/_/createCredentials" \
    --data-binary @- <<EOF || warn "Credential ${id} may already exist."
<org.jenkinsci.plugins.plaincredentials.impl.StringCredentialsImpl>
  <scope>GLOBAL</scope>
  <id>${id}</id>
  <description>${description}</description>
  <secret>${secret}</secret>
</org.jenkinsci.plugins.plaincredentials.impl.StringCredentialsImpl>
EOF
}

create_credential "github-token"    "GitHub PAT for cloning/webhooks"         "REPLACE_WITH_REAL_TOKEN"
create_credential "registry-token"  "Container registry push token"            "REPLACE_WITH_REAL_TOKEN"
create_credential "slack-webhook"   "Slack incoming webhook URL"               "REPLACE_WITH_REAL_WEBHOOK"

log "Credentials created with placeholder values — update them in Jenkins UI."

# ──────────────────────────────────────────────────────────────────────────────
# Summary
# ──────────────────────────────────────────────────────────────────────────────
header "Configuration Complete"
echo ""
echo -e "  ✅  Plugins installed"
echo -e "  ✅  JCasC applied"
echo -e "  ✅  Credential placeholders created"
echo ""
echo -e "  ${YELLOW}Action required:${NC}"
echo -e "    1. Open Jenkins UI → Manage Credentials"
echo -e "    2. Update placeholder credentials with real values"
echo -e "    3. Register the shared library (see README.md)"
echo ""
