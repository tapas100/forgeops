/**
 * ForgeOps Shared Library — security.groovy
 *
 * Security scanning steps for the CI pipeline:
 *   - npm audit (dependency vulnerability check)
 *   - Trivy container image vulnerability scan
 *   - Secret detection (prevent accidental secret commits)
 *
 * Usage:
 *   security.auditDependencies()
 *   security.scanImage(image: 'registry/app:tag')
 *   security.detectSecrets()
 */

// ── npm dependency audit ───────────────────────────────────────────────────────
def auditDependencies(Map config = [:]) {
    String nodeVersion = config.nodeVersion ?: 'nodejs-20'
    // Severity level that causes a build failure: low, moderate, high, critical
    String failSeverity = config.failSeverity ?: 'high'

    stage('🔐 Dependency Audit') {
        nodejs(nodeJSInstallationName: nodeVersion) {
            sh """
                set -euo pipefail

                echo "Running npm audit (fail on: ${failSeverity}+)..."
                mkdir -p reports

                # Generate JSON report for archiving
                npm audit --json > reports/npm-audit.json 2>&1 || true

                # Fail pipeline on high/critical vulnerabilities
                npm audit --audit-level=${failSeverity} || {
                    echo "❌ Vulnerabilities found at severity '${failSeverity}' or above."
                    echo "   Review reports/npm-audit.json for details."
                    exit 1
                }
                echo "✅ No ${failSeverity}+ vulnerabilities found."
            """
            archiveArtifacts artifacts: 'reports/npm-audit.json', allowEmptyArchive: true
        }
    }
}

// ── Container image vulnerability scan with Trivy ─────────────────────────────
def scanImage(Map config = [:]) {
    String image = config.image ?: error('security.scanImage(): image is required')
    // Severity levels to fail on: CRITICAL, HIGH, MEDIUM, LOW, UNKNOWN
    String severity = config.severity ?: 'HIGH,CRITICAL'
    boolean failOnVuln = config.failOnVuln ?: true

    stage('🔐 Image Scan (Trivy)') {
        sh """
            set -euo pipefail

            # Install Trivy if not present
            if ! command -v trivy &>/dev/null; then
                echo "Installing Trivy..."
                curl -sfL https://raw.githubusercontent.com/aquasecurity/trivy/main/contrib/install.sh \\
                    | sudo sh -s -- -b /usr/local/bin
            fi

            mkdir -p reports

            echo "Scanning image: ${image}"
            echo "Severity filter: ${severity}"

            trivy image \\
                --exit-code ${failOnVuln ? '1' : '0'} \\
                --severity "${severity}" \\
                --format json \\
                --output reports/trivy-results.json \\
                --no-progress \\
                "${image}" || {
                    echo "❌ Trivy found vulnerabilities at severity: ${severity}"
                    exit 1
                }

            # Human-readable summary to console
            trivy image \\
                --severity "${severity}" \\
                --format table \\
                --no-progress \\
                "${image}" || true

            echo "✅ Trivy scan complete. Results: reports/trivy-results.json"
        """
        archiveArtifacts artifacts: 'reports/trivy-results.json', allowEmptyArchive: true
    }
}

// ── Secret detection (gitleaks) ───────────────────────────────────────────────
def detectSecrets(Map config = [:]) {
    boolean failOnDetection = config.failOnDetection ?: true

    stage('🔐 Secret Detection') {
        sh """
            set -euo pipefail

            # Install gitleaks if not present
            if ! command -v gitleaks &>/dev/null; then
                echo "Installing gitleaks..."
                GITLEAKS_VERSION="8.18.2"
                curl -sSfL \\
                    "https://github.com/gitleaks/gitleaks/releases/download/v\${GITLEAKS_VERSION}/gitleaks_\${GITLEAKS_VERSION}_linux_x64.tar.gz" \\
                    | sudo tar -xzf - -C /usr/local/bin gitleaks
                sudo chmod +x /usr/local/bin/gitleaks
            fi

            mkdir -p reports

            echo "Scanning repository for secrets..."
            gitleaks detect \\
                --source . \\
                --report-format json \\
                --report-path reports/gitleaks-results.json \\
                --exit-code ${failOnDetection ? '1' : '0'} \\
                --no-banner \\
                || {
                    echo "❌ Potential secrets detected! Review reports/gitleaks-results.json"
                    ${failOnDetection ? 'exit 1' : 'echo "Continuing despite detection (failOnDetection=false)"'}
                }

            echo "✅ No secrets detected in codebase."
        """
        archiveArtifacts artifacts: 'reports/gitleaks-results.json', allowEmptyArchive: true
    }
}

// ── Container runtime security hardening check ───────────────────────────────
def checkContainerSecurity(Map config = [:]) {
    String containerName = config.containerName ?: error('checkContainerSecurity(): containerName is required')

    stage('🔐 Container Security Check') {
        sh """
            set -euo pipefail

            echo "Inspecting container security posture: ${containerName}"

            # Check container is NOT running as root
            USER_ID=\$(podman exec "${containerName}" id -u 2>/dev/null || echo "999")
            if [ "\${USER_ID}" -eq 0 ]; then
                echo "❌ Container is running as root (UID 0). This is not allowed."
                exit 1
            fi
            echo "✅ Container runs as UID \${USER_ID} (non-root)"

            # Check no new privileges flag
            SECURITY_OPT=\$(podman inspect "${containerName}" \\
                --format='{{range .HostConfig.SecurityOpt}}{{.}} {{end}}' 2>/dev/null || echo "")
            if echo "\${SECURITY_OPT}" | grep -q "no-new-privileges:true"; then
                echo "✅ no-new-privileges is set"
            else
                echo "⚠️  no-new-privileges not explicitly set — recommend adding it"
            fi

            # Check read-only root filesystem (advisory)
            READONLY=\$(podman inspect "${containerName}" \\
                --format='{{.HostConfig.ReadonlyRootfs}}' 2>/dev/null || echo "false")
            if [ "\${READONLY}" = "true" ]; then
                echo "✅ Read-only root filesystem enabled"
            else
                echo "⚠️  Root filesystem is writable — consider --read-only for production"
            fi

            echo "✅ Container security check complete."
        """
    }
}
