/**
 * ForgeOps Shared Library — notify.groovy
 *
 * Centralised notification dispatch for pipeline events.
 * Supports: Slack, email (and is extensible for Teams/PagerDuty).
 *
 * Usage:
 *   notify.success(appName: 'my-app', version: 'v1.2.3')
 *   notify.failure(appName: 'my-app', stage: 'Unit Tests')
 *   notify.deployment(appName: 'my-app', environment: 'production', url: 'https://...')
 */

// ── Internal helper ───────────────────────────────────────────────────────────
private String _buildContext() {
    return [
        "App:     ${env.APP_NAME ?: 'unknown'}",
        "Branch:  ${env.GIT_BRANCH ?: 'unknown'}",
        "Commit:  ${env.GIT_COMMIT?.take(8) ?: 'unknown'}",
        "Build:   <${env.BUILD_URL}|#${env.BUILD_NUMBER}>",
        "Node:    ${env.NODE_NAME ?: 'built-in'}",
    ].join('\n')
}

// ── Success notification ───────────────────────────────────────────────────────
def success(Map config = [:]) {
    String appName  = config.appName  ?: env.APP_NAME ?: 'unknown'
    String version  = config.version  ?: env.BUILD_TAG ?: "build-${env.BUILD_NUMBER}"
    String channel  = config.channel  ?: '#deployments'
    String message  = config.message  ?: "✅ *${appName}* pipeline succeeded"

    _sendSlack(
        channel:  channel,
        colour:   'good',
        message:  "${message}\nVersion: `${version}`\n${_buildContext()}"
    )
    _sendEmail(
        subject: "✅ [ForgeOps] ${appName} — Build #${env.BUILD_NUMBER} Passed",
        body:    "Pipeline succeeded for ${appName} (${version}).\n\nBuild URL: ${env.BUILD_URL}"
    )
}

// ── Failure notification ───────────────────────────────────────────────────────
def failure(Map config = [:]) {
    String appName  = config.appName  ?: env.APP_NAME ?: 'unknown'
    String stageName = config.stage  ?: 'Pipeline'
    String channel  = config.channel  ?: '#deployments'

    _sendSlack(
        channel: channel,
        colour:  'danger',
        message: "❌ *${appName}* pipeline FAILED at stage: *${stageName}*\n${_buildContext()}\n\nLogs: <${env.BUILD_URL}console|View Console>"
    )
    _sendEmail(
        subject: "❌ [ForgeOps] ${appName} — Build #${env.BUILD_NUMBER} FAILED",
        body:    "Pipeline failed at stage '${stageName}' for ${appName}.\n\nBuild URL: ${env.BUILD_URL}\nConsole: ${env.BUILD_URL}console"
    )
}

// ── Deployment notification ────────────────────────────────────────────────────
def deployment(Map config = [:]) {
    String appName  = config.appName      ?: env.APP_NAME ?: 'unknown'
    String env_name = config.environment  ?: 'production'
    String url      = config.url          ?: ''
    String version  = config.version      ?: "build-${env.BUILD_NUMBER}"
    String channel  = config.channel      ?: '#deployments'

    String urlLine = url ? "\nURL: <${url}|${url}>" : ''

    _sendSlack(
        channel: channel,
        colour:  '#0052CC',
        message: "🚀 *${appName}* deployed to *${env_name}*\nVersion: \`${version}\`${urlLine}\n${_buildContext()}"
    )
}

// ── PR/review notification (informational) ────────────────────────────────────
def unstable(Map config = [:]) {
    String appName  = config.appName ?: env.APP_NAME ?: 'unknown'
    String channel  = config.channel ?: '#deployments'
    String reason   = config.reason  ?: 'Unstable build'

    _sendSlack(
        channel: channel,
        colour:  'warning',
        message: "⚠️  *${appName}* build is UNSTABLE\nReason: ${reason}\n${_buildContext()}"
    )
}

// ── Private: send Slack message ────────────────────────────────────────────────
private void _sendSlack(Map args) {
    try {
        slackSend(
            channel:    args.channel,
            color:      args.colour ?: '#808080',
            message:    args.message,
            tokenCredentialId: 'slack-webhook',
            botUser:    true
        )
    } catch (Exception e) {
        echo "⚠️  Slack notification failed (non-fatal): ${e.message}"
    }
}

// ── Private: send email ────────────────────────────────────────────────────────
private void _sendEmail(Map args) {
    try {
        String recipients = env.NOTIFY_EMAIL ?: 'devops@yourcompany.com'
        emailext(
            subject:    args.subject,
            body:       args.body,
            to:         recipients,
            mimeType:   'text/plain',
            replyTo:    'noreply@yourcompany.com'
        )
    } catch (Exception e) {
        echo "⚠️  Email notification failed (non-fatal): ${e.message}"
    }
}
