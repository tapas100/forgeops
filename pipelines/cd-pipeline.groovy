/**
 * ForgeOps — CD Pipeline Template
 * ─────────────────────────────────────────────────────────────────────────────
 * Triggered on pushes to main or semver tags (v*).
 * Builds, scans, and deploys the container image via Podman.
 */

@Library('forgeops-shared') _

import org.forgeops.PipelineConfig
import org.forgeops.Utils

// ── Pipeline parameters ───────────────────────────────────────────────────────
properties([
    parameters([
        string(name: 'APP_NAME',    defaultValue: '',    description: 'Application name'),
        string(name: 'APP_PORT',    defaultValue: '3000', description: 'Host port to expose'),
        string(name: 'REGISTRY',    defaultValue: '',    description: 'Registry host (overrides env)'),
        booleanParam(name: 'SKIP_TESTS',  defaultValue: false, description: 'Skip test stage'),
        booleanParam(name: 'SKIP_SCAN',   defaultValue: false, description: 'Skip Trivy image scan'),
        booleanParam(name: 'DRY_RUN',     defaultValue: false, description: 'Build & scan only — do not deploy'),
    ])
])

pipeline {
    agent any

    options {
        buildDiscarder(logRotator(numToKeepStr: '10', artifactNumToKeepStr: '3'))
        timeout(time: 45, unit: 'MINUTES')
        timestamps()
        ansiColor('xterm')
        disableConcurrentBuilds(abortPrevious: false)
        skipDefaultCheckout(false)
    }

    triggers {
        githubPush()
    }

    environment {
        REGISTRY_HOST = "${params.REGISTRY ?: env.REGISTRY_HOST ?: 'localhost:5000'}"
        DEPLOY_HOST   = "${env.DEPLOY_HOST ?: 'localhost'}"
        NODE_OPTIONS  = '--max-old-space-size=256'
    }

    stages {
        // ── Gate: only run CD on main or tags ────────────────────────────────
        stage('🔒 Branch Gate') {
            steps {
                script {
                    boolean isMainBranch = env.GIT_BRANCH?.endsWith('main') || env.GIT_BRANCH?.endsWith('master')
                    boolean isTag        = env.TAG_NAME != null

                    if (!isMainBranch && !isTag) {
                        currentBuild.result = 'ABORTED'
                        error("CD pipeline only runs on main branch or version tags. Branch: ${env.GIT_BRANCH}")
                    }

                    def utils = new org.forgeops.Utils(this)
                    env.APP_NAME  = params.APP_NAME ?: (env.JOB_NAME.tokenize('/')[0])
                    env.IMAGE_TAG = utils.resolveImageTag()

                    echo utils.buildSummary(env.APP_NAME, env.IMAGE_TAG)
                }
            }
        }

        // ── Parallel: tests + secret scan ────────────────────────────────────
        stage('🧪 Pre-Build Checks') {
            when { expression { !params.SKIP_TESTS } }
            parallel {
                stage('Unit Tests') {
                    steps {
                        script {
                            test(
                                appName:    env.APP_NAME,
                                runLint:    true,
                                runUnit:    true,
                                runLoadTest: false
                            )
                        }
                    }
                }
                stage('Secret Scan') {
                    steps {
                        script { security.detectSecrets(failOnDetection: true) }
                    }
                }
            }
        }

        // ── Build ─────────────────────────────────────────────────────────────
        stage('🏗️  Build Image') {
            steps {
                script {
                    env.FULL_IMAGE = build(
                        appName:  env.APP_NAME,
                        imageTag: env.IMAGE_TAG,
                        registry: env.REGISTRY_HOST,
                        push:     true
                    )
                }
            }
        }

        // ── Security scan ─────────────────────────────────────────────────────
        stage('🔐 Image Scan') {
            when { expression { !params.SKIP_SCAN } }
            steps {
                script {
                    security.scanImage(
                        image:      env.FULL_IMAGE,
                        severity:   'HIGH,CRITICAL',
                        failOnVuln: true
                    )
                }
            }
        }

        // ── Deploy ────────────────────────────────────────────────────────────
        stage('🚀 Deploy') {
            when { expression { !params.DRY_RUN } }
            steps {
                sh """
                    set -euo pipefail
                    SCRIPT_DIR="\$(git rev-parse --show-toplevel)/deployment"

                    bash "\${SCRIPT_DIR}/deploy.sh" \\
                        --app   "${env.APP_NAME}" \\
                        --image "${env.FULL_IMAGE}" \\
                        --port  "${params.APP_PORT ?: 3000}"
                """
            }
        }

        // ── Health check ──────────────────────────────────────────────────────
        stage('❤️  Health Check') {
            when { expression { !params.DRY_RUN } }
            steps {
                sh """
                    set -euo pipefail
                    SCRIPT_DIR="\$(git rev-parse --show-toplevel)/deployment"

                    bash "\${SCRIPT_DIR}/health-check.sh" \\
                        --app  "${env.APP_NAME}" \\
                        --port "${params.APP_PORT ?: 3000}"
                """
            }
        }
    }

    post {
        success {
            script {
                notify.deployment(
                    appName:     env.APP_NAME,
                    environment: 'production',
                    version:     env.IMAGE_TAG,
                    url:         "http://${env.DEPLOY_HOST}:${params.APP_PORT ?: 3000}"
                )
            }
        }
        failure {
            script {
                notify.failure(appName: env.APP_NAME, stage: env.STAGE_NAME ?: 'CD')
            }
            sh """
                SCRIPT_DIR="\$(git rev-parse --show-toplevel)/deployment"
                bash "\${SCRIPT_DIR}/rollback.sh" --app "${env.APP_NAME}" || true
            """
        }
        always {
            archiveArtifacts artifacts: 'reports/**', allowEmptyArchive: true
            cleanWs()
        }
    }
}
