#!/usr/bin/env bash
# =============================================================================
# ForgeOps Platform — Jenkins Credentials Setup Guide
# This script documents and partially automates credential bootstrapping.
# DO NOT commit real credentials — use environment variables or a vault.
# =============================================================================

cat <<'GUIDE'
═══════════════════════════════════════════════════════════════════
  ForgeOps — Jenkins Credential Setup Reference
═══════════════════════════════════════════════════════════════════

OVERVIEW
────────
All credentials are stored in Jenkins' built-in credential store
(encrypted at rest in JENKINS_HOME/credentials.xml).

Never hard-code secrets in Jenkinsfiles or shared library code.
Reference them by credential ID using withCredentials() or
environment injection.

REQUIRED CREDENTIALS
────────────────────

1. github-token  (Secret Text)
   ├── ID:          github-token
   ├── Description: GitHub Personal Access Token
   ├── Scopes:      repo, workflow, read:org
   └── Usage:       SCM checkout, webhook validation, status updates

2. registry-token  (Secret Text)
   ├── ID:          registry-token
   ├── Description: Container registry push token
   ├── Example:     ghcr.io, Docker Hub, or self-hosted registry
   └── Usage:       podman login / push

3. slack-webhook  (Secret Text)
   ├── ID:          slack-webhook
   ├── Description: Slack Incoming Webhook URL
   └── Usage:       Build notifications (success/failure/deploy)

4. github-webhook-secret  (Secret Text)
   ├── ID:          github-webhook-secret
   ├── Description: HMAC secret for GitHub webhook validation
   └── Usage:       Set in GitHub repo Webhook settings

HOW TO ADD CREDENTIALS VIA JENKINS UI
──────────────────────────────────────
1. Open Jenkins → Manage Jenkins → Credentials
2. Click  (global) → Add Credentials
3. Select Kind: "Secret text"
4. Fill in ID, Description, and Secret value
5. Click OK

HOW TO ADD CREDENTIALS VIA REST API
────────────────────────────────────
GUIDE

# ── Example: add a credential via curl ──────────────────────────────────────
add_jenkins_credential() {
  local JENKINS_URL="${1:-http://127.0.0.1:8080/jenkins}"
  local ADMIN_USER="${2:-admin}"
  local ADMIN_PASS="${3:-}"
  local CRED_ID="${4}"
  local CRED_SECRET="${5}"
  local CRED_DESC="${6:-}"

  CRUMB=$(curl -sf -u "${ADMIN_USER}:${ADMIN_PASS}" \
    "${JENKINS_URL}/crumbIssuer/api/json" \
    | python3 -c "import sys,json; print(json.load(sys.stdin)['crumb'])")

  curl -sf -u "${ADMIN_USER}:${ADMIN_PASS}" \
    -H "Jenkins-Crumb: ${CRUMB}" \
    -H "Content-Type: application/xml" \
    "${JENKINS_URL}/credentials/store/system/domain/_/createCredentials" \
    --data-binary @- <<EOF
<org.jenkinsci.plugins.plaincredentials.impl.StringCredentialsImpl>
  <scope>GLOBAL</scope>
  <id>${CRED_ID}</id>
  <description>${CRED_DESC}</description>
  <secret>${CRED_SECRET}</secret>
</org.jenkinsci.plugins.plaincredentials.impl.StringCredentialsImpl>
EOF

  echo "✅ Credential '${CRED_ID}' created."
}

# ── If called directly with arguments, create credentials ────────────────────
if [[ "${1:-}" == "--apply" ]]; then
  JENKINS_URL="${JENKINS_URL:-http://127.0.0.1:8080/jenkins}"
  ADMIN_USER="${JENKINS_ADMIN_USER:-admin}"
  ADMIN_PASS="${JENKINS_ADMIN_PASSWORD:?'Set JENKINS_ADMIN_PASSWORD'}"

  echo "Adding credentials to Jenkins at ${JENKINS_URL}..."

  add_jenkins_credential "${JENKINS_URL}" "${ADMIN_USER}" "${ADMIN_PASS}" \
    "github-token"           "${GITHUB_TOKEN:?'Set GITHUB_TOKEN'}"           "GitHub PAT"
  add_jenkins_credential "${JENKINS_URL}" "${ADMIN_USER}" "${ADMIN_PASS}" \
    "registry-token"         "${REGISTRY_TOKEN:?'Set REGISTRY_TOKEN'}"       "Container Registry Token"
  add_jenkins_credential "${JENKINS_URL}" "${ADMIN_USER}" "${ADMIN_PASS}" \
    "slack-webhook"          "${SLACK_WEBHOOK_URL:?'Set SLACK_WEBHOOK_URL'}" "Slack Webhook URL"
  add_jenkins_credential "${JENKINS_URL}" "${ADMIN_USER}" "${ADMIN_PASS}" \
    "github-webhook-secret"  "${GITHUB_WEBHOOK_SECRET:?'Set GITHUB_WEBHOOK_SECRET'}" "GitHub Webhook HMAC Secret"

  echo "All credentials added."
fi
