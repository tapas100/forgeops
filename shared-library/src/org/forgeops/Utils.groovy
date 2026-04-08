/**
 * ForgeOps Shared Library — src/org/forgeops/Utils.groovy
 *
 * Utility functions used across pipeline stages.
 * Call via: def utils = new org.forgeops.Utils(this)
 */

package org.forgeops

class Utils implements Serializable {

    // Reference to the pipeline script context (needed to call sh, echo, etc.)
    private def script

    Utils(def script) {
        this.script = script
    }

    // ── Derive image tag from Git context ────────────────────────────────────
    String resolveImageTag() {
        String tag = script.env.TAG_NAME
        if (tag) return tag.replaceAll('[^a-zA-Z0-9._-]', '-')

        String sha = script.env.GIT_COMMIT
        if (sha) return sha.take(8)

        return "build-${script.env.BUILD_NUMBER ?: 'local'}"
    }

    // ── Sanitise a string to be a valid container name ────────────────────────
    static String toContainerName(String appName) {
        return appName.replaceAll('[^a-zA-Z0-9_-]', '-').toLowerCase()
    }

    // ── Wait until an HTTP endpoint returns 200 ────────────────────────────────
    boolean waitForHttp(String url, int timeoutSeconds = 60, int intervalSeconds = 5) {
        int elapsed = 0
        while (elapsed < timeoutSeconds) {
            try {
                int status = script.sh(
                    script:      "curl -so /dev/null -w '%{http_code}' '${url}' || echo 000",
                    returnStdout: true
                ).trim().toInteger()

                if (status == 200) {
                    script.echo "✅ ${url} responded with 200 after ${elapsed}s"
                    return true
                }
            } catch (ignored) { /* keep polling */ }

            script.sleep(intervalSeconds)
            elapsed += intervalSeconds
        }
        script.echo "❌ ${url} did not return 200 within ${timeoutSeconds}s"
        return false
    }

    // ── Retrieve current git short SHA ────────────────────────────────────────
    String gitShortSha() {
        return script.sh(script: 'git rev-parse --short HEAD', returnStdout: true).trim()
    }

    // ── Format a human-readable build summary ─────────────────────────────────
    String buildSummary(String appName, String imageTag) {
        return """
╔══════════════════════════════════════════╗
║  ForgeOps Build Summary
╠══════════════════════════════════════════╣
║  App:     ${appName}
║  Tag:     ${imageTag}
║  Branch:  ${script.env.GIT_BRANCH ?: 'unknown'}
║  Commit:  ${script.env.GIT_COMMIT?.take(8) ?: 'unknown'}
║  Build:   #${script.env.BUILD_NUMBER}
║  URL:     ${script.env.BUILD_URL}
╚══════════════════════════════════════════╝
""".stripIndent()
    }

    // ── Check whether a podman container exists and is running ────────────────
    boolean containerIsRunning(String containerName) {
        def status = script.sh(
            script:       "podman container inspect --format '{{.State.Status}}' '${containerName}' 2>/dev/null || echo 'absent'",
            returnStdout: true
        ).trim()
        return status == 'running'
    }
}
