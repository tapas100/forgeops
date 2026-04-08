/**
 * ForgeOps — Test Pipeline Template
 * ─────────────────────────────────────────────────────────────────────────────
 * Post-deploy testing pipeline: smoke tests + k6 load tests.
 * Triggered by the CD pipeline or manually via Jenkins parameters.
 */

@Library('forgeops-shared') _

properties([
    parameters([
        string(name: 'APP_NAME',       defaultValue: '',              description: 'Application name'),
        string(name: 'TARGET_URL',     defaultValue: 'http://localhost:3000', description: 'Base URL of deployed app'),
        string(name: 'LOAD_VUS',       defaultValue: '10',            description: 'k6 virtual users'),
        string(name: 'LOAD_DURATION',  defaultValue: '30s',           description: 'k6 test duration (e.g. 30s, 2m)'),
        booleanParam(name: 'SKIP_LOAD', defaultValue: false,          description: 'Skip k6 load test'),
    ])
])

pipeline {
    agent any

    options {
        buildDiscarder(logRotator(numToKeepStr: '15'))
        timeout(time: 20, unit: 'MINUTES')
        timestamps()
        ansiColor('xterm')
    }

    environment {
        APP_NAME    = "${params.APP_NAME ?: env.JOB_NAME.tokenize('/')[0]}"
        TARGET_URL  = "${params.TARGET_URL}"
    }

    stages {
        stage('🔍 Smoke Tests') {
            steps {
                sh '''
                    set -euo pipefail

                    echo "═══════════════════════════════════════════"
                    echo " Smoke testing: ${TARGET_URL}"
                    echo "═══════════════════════════════════════════"

                    # Health endpoint check
                    HTTP=$(curl -so /dev/null -w "%{http_code}" "${TARGET_URL}/health" || echo 000)
                    echo "GET /health → ${HTTP}"
                    [ "${HTTP}" = "200" ] || { echo "❌ Health check failed"; exit 1; }

                    # Root endpoint check
                    HTTP=$(curl -so /dev/null -w "%{http_code}" "${TARGET_URL}/" || echo 000)
                    echo "GET / → ${HTTP}"
                    [ "${HTTP}" != "000" ] || { echo "❌ Root endpoint unreachable"; exit 1; }

                    echo "✅ Smoke tests passed."
                '''
            }
        }

        stage('⚡ Load Tests (k6)') {
            when {
                expression { !params.SKIP_LOAD }
            }
            steps {
                script {
                    test(
                        appName:      env.APP_NAME,
                        runLint:      false,
                        runUnit:      false,
                        runLoadTest:  true,
                        targetUrl:    env.TARGET_URL,
                        loadVus:      params.LOAD_VUS.toInteger(),
                        loadDuration: params.LOAD_DURATION
                    )
                }
            }
        }

        stage('📊 Report') {
            steps {
                sh '''
                    if [ -f reports/k6-summary.json ]; then
                        echo "═══════════════════════════════════════════"
                        echo " k6 Load Test Summary"
                        echo "═══════════════════════════════════════════"
                        node -e "
                            const s = require('./reports/k6-summary.json');
                            const m = s.metrics || {};
                            console.log('Requests:     ' + (m.http_reqs?.values?.count ?? 'n/a'));
                            console.log('Failures:     ' + (m.http_req_failed?.values?.rate * 100).toFixed(2) + '%');
                            console.log('Avg latency:  ' + (m.http_req_duration?.values?.avg ?? 0).toFixed(2) + 'ms');
                            console.log('p95 latency:  ' + (m.http_req_duration?.values?.['p(95)'] ?? 0).toFixed(2) + 'ms');
                            console.log('p99 latency:  ' + (m.http_req_duration?.values?.['p(99)'] ?? 0).toFixed(2) + 'ms');
                        " 2>/dev/null || cat reports/k6-summary.json
                    fi
                '''
                archiveArtifacts artifacts: 'reports/**', allowEmptyArchive: true
            }
        }
    }

    post {
        success {
            script { notify.success(appName: env.APP_NAME) }
        }
        failure {
            script { notify.failure(appName: env.APP_NAME, stage: env.STAGE_NAME ?: 'Test Pipeline') }
        }
        always {
            cleanWs()
        }
    }
}
