/**
 * ForgeOps Shared Library — src/org/forgeops/PipelineConfig.groovy
 *
 * Strongly-typed configuration class passed through pipeline stages.
 * Provides defaults and validates required fields.
 */

package org.forgeops

class PipelineConfig implements Serializable {

    // ── Application identity ─────────────────────────────────────────────────
    String appName
    String version
    String registry        = System.getenv('REGISTRY_HOST') ?: 'localhost:5000'
    String deployHost      = System.getenv('DEPLOY_HOST')   ?: 'localhost'

    // ── Build ────────────────────────────────────────────────────────────────
    String containerfile   = 'Containerfile'
    String buildContext    = '.'
    String platform        = 'linux/amd64'
    List   buildArgs       = []
    boolean pushImage      = true

    // ── Runtime ──────────────────────────────────────────────────────────────
    int    port            = 3000
    String nodeVersion     = 'nodejs-20'
    int    healthTimeout   = 60   // seconds to wait for healthy container
    String healthEndpoint  = '/health'

    // ── Testing ──────────────────────────────────────────────────────────────
    boolean runLint        = true
    boolean runUnit        = true
    boolean runLoadTest    = false
    int     loadVus        = 10
    String  loadDuration   = '30s'
    int     coverageThreshold = 60    // minimum line coverage %

    // ── Security ─────────────────────────────────────────────────────────────
    boolean runSecretScan  = true
    boolean runDepAudit    = true
    boolean runImageScan   = true
    String  auditSeverity  = 'high'
    String  imageScanSeverity = 'HIGH,CRITICAL'

    // ── Notifications ────────────────────────────────────────────────────────
    String  slackChannel   = '#deployments'
    String  emailRecipient = 'devops@yourcompany.com'

    // ── Compute full image reference ─────────────────────────────────────────
    String getFullImage() {
        return "${registry}/${appName}:${version}"
    }

    // ── Validate required fields ─────────────────────────────────────────────
    void validate() {
        assert appName  : "PipelineConfig: appName is required"
        assert version  : "PipelineConfig: version is required"
        assert port > 0 : "PipelineConfig: port must be > 0"
    }

    // ── Pretty-print config for build logs ───────────────────────────────────
    @Override
    String toString() {
        return """
PipelineConfig {
  appName:    ${appName}
  version:    ${version}
  image:      ${getFullImage()}
  port:       ${port}
  platform:   ${platform}
  runUnit:    ${runUnit}
  runLoad:    ${runLoadTest}
  scanImage:  ${runImageScan}
}""".stripIndent()
    }
}
