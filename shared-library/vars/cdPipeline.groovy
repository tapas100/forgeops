/**
 * ForgeOps Shared Library — cdPipeline.groovy
 *
 * High-level CD pipeline entry point.
 * Triggered on main branch pushes or version tags.
 *
 * Usage in a repo Jenkinsfile:
 *   @Library('forgeops-shared') _
 *   cdPipeline(
 *     appName:  'my-app',
 *     port:     3000,
 *     registry: 'ghcr.io/myorg'
 *   )
 */

def call(Map config = [:]) {
    String appName    = config.appName    ?: error('cdPipeline(): appName is required')
    int    port       = config.port       ?: 3000
    String registry   = config.registry   ?: env.REGISTRY_HOST ?: 'localhost:5000'
    String nodeVersion = config.nodeVersion ?: 'nodejs-20'
    boolean runTests  = config.runTests   ?: true
    boolean runScan   = config.runScan    ?: true
    // Custom deploy hook — callers can override with their own closure
    Closure deployHook = config.deployHook ?: null

    // Determine image tag: use git tag if available, otherwise short SHA
    String imageTag = env.TAG_NAME
        ?: (env.GIT_COMMIT ? env.GIT_COMMIT.take(8) : "build-${env.BUILD_NUMBER}")

    env.APP_NAME  = appName
    env.IMAGE_TAG = imageTag

    pipeline {
        agent any

        options {
            buildDiscarder(logRotator(numToKeepStr: '10'))
            timeout(time: 45, unit: 'MINUTES')
            timestamps()
            ansiColor('xterm')
            // Do not abort previous CD runs — allow them to finish
            disableConcurrentBuilds(abortPrevious: false)
        }

        triggers {
            githubPush()
        }

        stages {
            stage('🧪 Run Tests') {
                when {
                    expression { runTests }
                }
                steps {
                    script {
                        test(
                            appName:     appName,
                            nodeVersion: nodeVersion,
                            runLint:     true,
                            runUnit:     true,
                            runLoadTest: false
                        )
                    }
                }
            }

            stage('🏗️  Build & Push') {
                steps {
                    script {
                        String fullImage = build(
                            appName:  appName,
                            imageTag: imageTag,
                            registry: registry,
                            push:     true
                        )
                        env.FULL_IMAGE = fullImage
                    }
                }
            }

            stage('🔐 Image Security Scan') {
                when {
                    expression { runScan }
                }
                steps {
                    script {
                        security.scanImage(
                            image:       env.FULL_IMAGE,
                            severity:    'HIGH,CRITICAL',
                            failOnVuln:  true
                        )
                    }
                }
            }

            stage('🚀 Deploy') {
                steps {
                    script {
                        if (deployHook) {
                            // Caller-provided custom deploy logic
                            deployHook.call(appName: appName, imageTag: imageTag, port: port)
                        } else {
                            // Default: use the shared deploy.sh script
                            sh """
                                bash \${WORKSPACE}/../../deployment/deploy.sh \\
                                    --app      "${appName}" \\
                                    --image    "${env.FULL_IMAGE}" \\
                                    --port     "${port}"
                            """
                        }
                    }
                }
            }

            stage('❤️  Health Check') {
                steps {
                    sh """
                        bash \${WORKSPACE}/../../deployment/health-check.sh \\
                            --app  "${appName}" \\
                            --port "${port}"
                    """
                }
            }
        }

        post {
            success {
                script {
                    notify.deployment(
                        appName:     appName,
                        environment: 'production',
                        version:     imageTag,
                        url:         "http://${env.DEPLOY_HOST}:${port}"
                    )
                }
            }
            failure {
                script {
                    notify.failure(appName: appName, stage: env.STAGE_NAME ?: 'CD')
                }
                // Attempt automatic rollback on deploy failure
                sh """
                    echo "Attempting automatic rollback..."
                    bash \${WORKSPACE}/../../deployment/rollback.sh \\
                        --app "${appName}" || echo "⚠️  Rollback script not found or failed — manual intervention required."
                """
            }
            always {
                cleanWs()
            }
        }
    }
}
