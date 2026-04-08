# GitHub Webhook Setup Guide

This guide walks you through connecting your GitHub repositories to the ForgeOps Jenkins CI/CD platform.

---

## Prerequisites

- Jenkins is running and accessible at `https://your-domain.com/jenkins`
- The **GitHub** plugin is installed in Jenkins
- You have a GitHub account with admin rights to the target repository
- You have a **GitHub Personal Access Token (PAT)** with `repo` and `workflow` scope

---

## Step 1 — Create a Webhook Secret

Generate a strong HMAC secret for webhook payload validation:

```bash
# Generate a 32-byte random secret
openssl rand -hex 32
# Example output: 8f3a2b1c9d4e7f0a1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6e7f8a9b0c1d2e3f4a
```

Store this value:
1. In Jenkins → Manage Jenkins → Credentials → Add `github-webhook-secret` (Secret Text)
2. Save it separately — you'll also paste it into GitHub

---

## Step 2 — Create a Jenkins Multibranch Pipeline Job

1. Open Jenkins → **New Item**
2. Enter the repo name (e.g., `node-api`)
3. Select **Multibranch Pipeline** → OK
4. Under **Branch Sources** → Add Source → **GitHub**
5. Set credentials to your `github-token` credential
6. Set Owner and Repository
7. Under **Behaviors**, enable:
   - Discover branches
   - Discover pull requests from origin
8. Under **Build Configuration**, set Script Path to `Jenkinsfile`
9. Save

---

## Step 3 — Configure the GitHub Webhook

1. Open your GitHub repository
2. Go to **Settings** → **Webhooks** → **Add webhook**

| Field | Value |
|-------|-------|
| **Payload URL** | `https://your-domain.com/jenkins/github-webhook/` |
| **Content type** | `application/json` |
| **Secret** | The secret you generated in Step 1 |
| **Which events?** | Select: Push events, Pull request events |

3. Click **Add webhook**
4. GitHub will send a ping — verify it shows a green checkmark (✅)

---

## Step 4 — Trigger a Test Build

Push a commit to your repository:

```bash
git commit --allow-empty -m "chore: test CI trigger"
git push origin main
```

Open Jenkins → your pipeline job. A build should start within 5–10 seconds.

---

## Step 5 — Configure GitHub Commit Status Updates (Optional)

To show ✅/❌ build status on GitHub PRs:

1. In Jenkins → Manage Jenkins → Configure System
2. Find **GitHub** section
3. Add a GitHub server with your `github-token` credential
4. Click **Test connection** → should show rate limit info

Pipelines using the shared library will automatically post commit statuses.

---

## Webhook Security Notes

- The webhook secret ensures only GitHub can trigger builds (HMAC-SHA256 validation)
- Jenkins verifies the `X-Hub-Signature-256` header automatically (GitHub plugin)
- The Nginx rate limit (`zone=webhooks`) protects against webhook flooding
- Only allow inbound traffic on port 443 from GitHub's IP ranges (optional hardening):

```bash
# GitHub webhook IP ranges (check https://api.github.com/meta for current list)
sudo ufw allow from 185.199.108.0/22 to any port 443
sudo ufw allow from 140.82.112.0/20  to any port 443
sudo ufw allow from 192.30.252.0/22  to any port 443
```

---

## Troubleshooting

| Symptom | Check |
|---------|-------|
| Webhook shows red X on GitHub | Check Jenkins URL is reachable; verify HTTPS certificate |
| Build not triggered | Check Jenkins logs: `podman logs jenkins \| grep webhook` |
| `403 Forbidden` | Jenkins CSRF crumb mismatch — ensure webhook URL ends with `/` |
| `401 Unauthorized` | Webhook secret mismatch between GitHub and Jenkins |
| Build triggered but checkout fails | Verify `github-token` credential has `repo` scope |
