/**
 * ForgeOps Shared Library — build.groovy
 *
 * Provides the `build` step for building and pushing container images
 * using Podman (rootless, daemonless). Callable from any Jenkinsfile.
 *
 * Usage:
 *   build(appName: 'my-app', imageTag: 'v1.2.3', registry: 'ghcr.io/myorg')
 */

def call(Map config = [:]) {
    // ── Defaults ──────────────────────────────────────────────────────────────
    String appName    = config.appName    ?: error('build(): appName is required')
    String imageTag   = config.imageTag   ?: env.BUILD_TAG?.replaceAll('[^a-zA-Z0-9._-]', '-') ?: 'latest'
    String registry   = config.registry   ?: env.REGISTRY_HOST ?: 'localhost:5000'
    String context    = config.context    ?: '.'
    String containerfile = config.containerfile ?: 'Containerfile'
    List   buildArgs  = config.buildArgs  ?: []
    boolean pushImage = config.push       ?: true
    String platform   = config.platform   ?: 'linux/amd64'

    String fullImage  = "${registry}/${appName}:${imageTag}"
    String latestTag  = "${registry}/${appName}:latest"

    stage('🏗️  Build Image') {
        echo "Building image: ${fullImage}"
        echo "Containerfile: ${containerfile}  Context: ${context}"

        // Construct --build-arg flags
        String buildArgFlags = buildArgs.collect { "--build-arg ${it}" }.join(' ')

        // Build with podman
        sh """
            set -euo pipefail

            echo "──────────────────────────────────────"
            echo " Podman build: ${fullImage}"
            echo "──────────────────────────────────────"

            podman build \\
                --platform=${platform} \\
                --file="${containerfile}" \\
                --tag="${fullImage}" \\
                --tag="${latestTag}" \\
                --label="build.number=${env.BUILD_NUMBER}" \\
                --label="build.url=${env.BUILD_URL}" \\
                --label="git.commit=${env.GIT_COMMIT ?: 'unknown'}" \\
                --label="git.branch=${env.GIT_BRANCH ?: 'unknown'}" \\
                --label="build.date=\$(date -u +%Y-%m-%dT%H:%M:%SZ)" \\
                --squash-all \\
                ${buildArgFlags} \\
                "${context}"

            echo "✅ Image built: ${fullImage}"
        """

        // Record image digest for traceability
        env.BUILT_IMAGE     = fullImage
        env.BUILT_IMAGE_TAG = imageTag
    }

    if (pushImage) {
        stage('📤 Push Image') {
            withCredentials([string(credentialsId: 'registry-token', variable: 'REGISTRY_TOKEN')]) {
                sh """
                    set -euo pipefail

                    echo "──────────────────────────────────────"
                    echo " Pushing: ${fullImage}"
                    echo "──────────────────────────────────────"

                    # Login to registry
                    echo "\${REGISTRY_TOKEN}" | podman login \\
                        --username=forgeops \\
                        --password-stdin \\
                        "${registry}"

                    podman push "${fullImage}"
                    podman push "${latestTag}"

                    echo "✅ Image pushed: ${fullImage}"
                    echo "✅ Image pushed: ${latestTag}"

                    # Logout immediately after push
                    podman logout "${registry}"
                """
            }
        }
    }

    // ── Post-build image inspection ──────────────────────────────────────────
    stage('🔍 Image Inspect') {
        sh """
            echo "── Image details ─────────────────────────────────────"
            podman inspect "${fullImage}" \\
                --format='ID:     {{.Id}}\nSize:   {{.Size}}\nOS:     {{.Os}}/{{.Architecture}}\nLayers: {{len .RootFS.Layers}}'
            echo "──────────────────────────────────────────────────────"
        """
    }

    return fullImage
}
