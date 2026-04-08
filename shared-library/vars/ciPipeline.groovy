/**
 * ForgeOps Shared Library — ciPipeline.groovy
 *
 * High-level CI pipeline entry point.
 * Designed to be the ONLY thing a repo's Jenkinsfile needs to call.
 *
 * Usage in a repo Jenkinsfile:
 *   @Library('forgeops-shared') _
 *   ciPipeline(appName: 'my-app', port: 3000)
 */

def call(Map config = [:]) {
    String appName    = config.appName    ?: error('ciPipeline(): appName is required')
    int    port       = config.port       ?: 3000
    String nodeVersion = config.nodeVersion ?: 'nodejs-20'
    boolean runSecurity = config.runSecurity ?: true
    String failSeverity = config.failSeverity ?: 'high'

    // Expose app name as env var so notify helpers can pick it up
    env.APP_NAME = appName

    pipeline {
        agent any

        options {
            buildDiscarder(logRotator(numToKeepStr: '20'))
            timeout(time: 30, unit: 'MINUTES')
            timestamps()
            ansiColor('xterm')
            disableConcurrentBuilds(abortPrevious: true)
        }

        triggers {
            // Trigger on any GitHub push via webhook
            githubPush()
        }

        stages {
            stage('🔐 Security Pre-Check') {
                when { expression { runSecurity } }
                steps {
                    script {
                        security.detectSecrets()
                        security.auditDependencies(
                            nodeVersion:  nodeVersion,
                            failSeverity: failSeverity
                        )
                    }
                }
            }

            stage('🧪 Test Suite') {
                steps {
                    script {
                        test(
                            appName:     appName,
                            nodeVersion: nodeVersion,
                            runLint:     true,
                            runUnit:     true,
                            runLoadTest: false,
                            port:        port
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
                script { notify.failure(appName: appName, stage: env.STAGE_NAME ?: 'CI') }
            }
            unstable {
                script { notify.unstable(appName: appName) }
            }
            always {
                cleanWs()
            }
        }
    }
}
