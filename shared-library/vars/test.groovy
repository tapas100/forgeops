/**
 * ForgeOps Shared Library — test.groovy
 *
 * Runs the full test suite for a Node.js application:
 *   - Dependency installation (npm ci)
 *   - ESLint static analysis
 *   - Jest unit tests with coverage
 *   - k6 load tests (post-deploy, optional)
 *
 * Usage:
 *   test(appName: 'my-app', nodeVersion: 'nodejs-20')
 *   test(appName: 'my-app', runLoadTest: true, targetUrl: 'http://localhost:3000')
 */

def call(Map config = [:]) {
    String appName       = config.appName     ?: error('test(): appName is required')
    String nodeVersion   = config.nodeVersion ?: 'nodejs-20'
    boolean runLint      = config.runLint     ?: true
    boolean runUnit      = config.runUnit     ?: true
    boolean runLoadTest  = config.runLoadTest ?: false
    String  targetUrl    = config.targetUrl   ?: "http://localhost:${config.port ?: 3000}"
    int     loadVus      = config.loadVus     ?: 10
    String  loadDuration = config.loadDuration ?: '30s'
    String  reportDir    = config.reportDir   ?: 'reports'

    // ── Dependency installation ──────────────────────────────────────────────
    stage('📦 Install Dependencies') {
        nodejs(nodeJSInstallationName: nodeVersion) {
            sh """
                set -euo pipefail
                echo "Node.js: \$(node --version)"
                echo "npm:     \$(npm --version)"

                # Use ci for reproducible installs (honours package-lock.json)
                npm ci --prefer-offline --no-audit
            """
        }
    }

    // ── Linting ──────────────────────────────────────────────────────────────
    if (runLint) {
        stage('🔎 Lint') {
            nodejs(nodeJSInstallationName: nodeVersion) {
                sh """
                    set -euo pipefail
                    mkdir -p ${reportDir}

                    # Run ESLint — output as JUnit XML for Jenkins reporting
                    npx eslint . \\
                        --ext .js,.ts \\
                        --format junit \\
                        --output-file ${reportDir}/eslint-results.xml \\
                        || (echo "⚠️  Lint warnings found — see report" && true)

                    # Also output human-readable summary
                    npx eslint . --ext .js,.ts || true
                """
                // Archive lint results
                junit allowEmptyResults: true, testResults: "${reportDir}/eslint-results.xml"
            }
        }
    }

    // ── Unit tests ───────────────────────────────────────────────────────────
    if (runUnit) {
        stage('🧪 Unit Tests') {
            nodejs(nodeJSInstallationName: nodeVersion) {
                sh """
                    set -euo pipefail
                    mkdir -p ${reportDir}

                    # Jest with coverage — JUnit reporter for Jenkins
                    npx jest \\
                        --ci \\
                        --coverage \\
                        --coverageDirectory=${reportDir}/coverage \\
                        --reporters=default \\
                        --reporters=jest-junit \\
                        --forceExit \\
                        --detectOpenHandles
                """
            }

            // Publish JUnit results
            junit testResults: 'junit.xml', allowEmptyResults: false

            // Publish HTML coverage report
            publishHTML(target: [
                reportName:           'Coverage Report',
                reportDir:            "${reportDir}/coverage",
                reportFiles:          'index.html',
                keepAll:              true,
                alwaysLinkToLastBuild: true,
                allowMissing:         false
            ])

            // Fail build if coverage drops below threshold
            sh """
                COVERAGE=\$(node -e "
                    const s = require('./${reportDir}/coverage/coverage-summary.json');
                    console.log(Math.round(s.total.lines.pct));
                " 2>/dev/null || echo 0)
                echo "Line coverage: \${COVERAGE}%"
                if [ "\${COVERAGE}" -lt 60 ]; then
                    echo "❌ Coverage \${COVERAGE}% is below the 60% threshold."
                    exit 1
                fi
                echo "✅ Coverage \${COVERAGE}% meets threshold."
            """
        }
    }

    // ── k6 Load tests ────────────────────────────────────────────────────────
    if (runLoadTest) {
        stage('⚡ Load Tests (k6)') {
            sh """
                set -euo pipefail

                # Install k6 if not present
                if ! command -v k6 &>/dev/null; then
                    echo "Installing k6..."
                    curl -fsSL https://dl.k6.io/key.gpg | sudo gpg --dearmor -o /usr/share/keyrings/k6-archive-keyring.gpg
                    echo "deb [signed-by=/usr/share/keyrings/k6-archive-keyring.gpg] https://dl.k6.io/deb stable main" \\
                        | sudo tee /etc/apt/sources.list.d/k6.list
                    sudo apt-get update -qq && sudo apt-get install -y k6
                fi

                mkdir -p ${reportDir}

                K6_SCRIPT="k6/load-test.js"
                if [ ! -f "\${K6_SCRIPT}" ]; then
                    echo "❌ k6 script not found at \${K6_SCRIPT}"
                    exit 1
                fi

                echo "Running k6 load test against: ${targetUrl}"
                k6 run \\
                    --vus=${loadVus} \\
                    --duration=${loadDuration} \\
                    --env BASE_URL="${targetUrl}" \\
                    --out json=${reportDir}/k6-results.json \\
                    --summary-export=${reportDir}/k6-summary.json \\
                    "\${K6_SCRIPT}"
            """

            // Archive k6 results as build artifacts
            archiveArtifacts artifacts: "${reportDir}/k6-*.json", allowEmptyArchive: true

            // Parse k6 summary and fail if p95 > 500ms or error rate > 1%
            sh """
                node -e "
                    const fs = require('fs');
                    const summary = JSON.parse(fs.readFileSync('${reportDir}/k6-summary.json'));
                    const p95 = summary.metrics?.http_req_duration?.values?.['p(95)'] ?? 0;
                    const errRate = summary.metrics?.http_req_failed?.values?.rate ?? 0;
                    console.log('k6 p95 latency:', p95.toFixed(2) + 'ms');
                    console.log('k6 error rate:', (errRate * 100).toFixed(2) + '%');
                    if (p95 > 500) { console.error('❌ p95 exceeds 500ms'); process.exit(1); }
                    if (errRate > 0.01) { console.error('❌ Error rate exceeds 1%'); process.exit(1); }
                    console.log('✅ Load test passed');
                "
            """
        }
    }
}
