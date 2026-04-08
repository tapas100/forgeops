/**
 * ForgeOps Shared Library — testPipeline.groovy
 *
 * Dedicated post-deployment testing pipeline.
 * Runs API smoke tests and k6 load tests against a live environment.
 *
 * Usage:
 *   @Library('forgeops-shared') _
 *   testPipeline(
 *     appName:      'my-app',
 *     targetUrl:    'http://localhost:3000',
 *     loadVus:      20,
 *     loadDuration: '60s'
 *   )
 */

def call(Map config = [:]) {
    String appName      = config.appName      ?: error('testPipeline(): appName is required')
    String targetUrl    = config.targetUrl    ?: error('testPipeline(): targetUrl is required')
    int    loadVus      = config.loadVus      ?: 10
    String loadDuration = config.loadDuration ?: '30s'
    String nodeVersion  = config.nodeVersion  ?: 'nodejs-20'

    env.APP_NAME = appName

    pipeline {
        agent any

        options {
            buildDiscarder(logRotator(numToKeepStr: '10'))
            timeout(time: 20, unit: 'MINUTES')
            timestamps()
            ansiColor('xterm')
        }

        stages {
            stage('🔍 Smoke Tests') {
                steps {
                    sh """
                        set -euo pipefail
                        echo "Running API smoke tests against: ${targetUrl}"
                        mkdir -p reports

                        # Quick availability check
                        HTTP_STATUS=\$(curl -so /dev/null -w "%{http_code}" "${targetUrl}/health" || echo "000")
                        echo "Health endpoint HTTP status: \${HTTP_STATUS}"

                        if [ "\${HTTP_STATUS}" != "200" ]; then
                            echo "❌ Health check failed — expected 200, got \${HTTP_STATUS}"
                            exit 1
                        fi
                        echo "✅ Smoke test passed."
                    """
                }
            }

            stage('⚡ Load Tests (k6)') {
                steps {
                    script {
                        test(
                            appName:      appName,
                            nodeVersion:  nodeVersion,
                            runLint:      false,
                            runUnit:      false,
                            runLoadTest:  true,
                            targetUrl:    targetUrl,
                            loadVus:      loadVus,
                            loadDuration: loadDuration
                        )
                    }
                }
            }
        }

        post {
            success {
                script { notify.success(appName: appName) }
            }
            failure {
                script { notify.failure(appName: appName, stage: env.STAGE_NAME ?: 'Test Pipeline') }
            }
            always {
                cleanWs()
            }
        }
    }
}
