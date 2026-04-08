/**
 * ForgeOps — CI Pipeline Template
 * ─────────────────────────────────────────────────────────────────────────────
 * Standalone pipeline script for use as a Jenkins template or directly as a
 * Jenkinsfile in repos that need fine-grained CI control beyond ciPipeline().
 *
 * Parallelised test execution to maximise speed on the Oracle Free Tier VM.
 */

@Library('forgeops-shared') _

import org.forgeops.PipelineConfig
import org.forgeops.Utils

// ── Pipeline parameters ───────────────────────────────────────────────────────
properties([
    parameters([
        string(name: 'APP_NAME',    defaultValue: '',       description: 'Application name (overrides SCM default)'),
        string(name: 'NODE_VER',    defaultValue: 'nodejs-20', description: 'Node.js tool version'),
        booleanParam(name: 'SKIP_SECURITY', defaultValue: false, description: 'Skip security scans (use only for testing)'),
    ])
])

pipeline {
    agent any

    options {
        buildDiscarder(logRotator(numToKeepStr: '20', artifactNumToKeepStr: '5'))
        timeout(time: 30, unit: 'MINUTES')
        timestamps()
        ansiColor('xterm')
        disableConcurrentBuilds(abortPrevious: true)
        skipDefaultCheckout(false)
    }

    triggers {
        githubPush()
    }

    environment {
        // Injected by JCasC / Jenkins global env vars
        REGISTRY_HOST = "${env.REGISTRY_HOST ?: 'localhost:5000'}"
        NODE_OPTIONS  = '--max-old-space-size=256'
    }

    stages {
        // ── Initialise ───────────────────────────────────────────────────────
        stage('⚙️  Init') {
            steps {
                script {
                    def utils = new org.forgeops.Utils(this)

                    env.APP_NAME  = params.APP_NAME ?: (env.JOB_NAME.tokenize('/')[0])
                    env.IMAGE_TAG = utils.resolveImageTag()

                    echo utils.buildSummary(env.APP_NAME, env.IMAGE_TAG)
                }
            }
        }

        // ── Security (parallel: secrets + deps) ──────────────────────────────
        stage('🔐 Security Checks') {
            when {
                expression { !params.SKIP_SECURITY }
            }
            parallel {
                stage('Secret Scan') {
                    steps {
                        script { security.detectSecrets(failOnDetection: true) }
                    }
                }
                stage('Dependency Audit') {
                    steps {
                        script {
                            security.auditDependencies(
                                nodeVersion:  params.NODE_VER,
                                failSeverity: 'high'
                            )
                        }
                    }
                }
            }
        }

        // ── Test (parallel: lint + unit) ─────────────────────────────────────
        stage('🧪 Test Suite') {
            parallel {
                stage('Lint') {
                    steps {
                        script {
                            test(
                                appName:    env.APP_NAME,
                                nodeVersion: params.NODE_VER,
                                runLint:    true,
                                runUnit:    false
                            )
                        }
                    }
                }
                stage('Unit Tests') {
                    steps {
                        script {
                            test(
                                appName:    env.APP_NAME,
                                nodeVersion: params.NODE_VER,
                                runLint:    false,
                                runUnit:    true
                            )
                        }
                    }
                }
            }
        }
    }

    post {
        success {
            script { notify.success(appName: env.APP_NAME) }
        }
        failure {
            script { notify.failure(appName: env.APP_NAME, stage: env.STAGE_NAME ?: 'CI') }
        }
        unstable {
            script { notify.unstable(appName: env.APP_NAME, reason: 'Tests unstable') }
        }
        always {
            // Archive test reports
            archiveArtifacts artifacts: 'reports/**', allowEmptyArchive: true
            cleanWs()
        }
    }
}
