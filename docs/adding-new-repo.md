# Adding a New Repository to ForgeOps

Onboarding a new Node.js repository takes **under 5 minutes** with this guide.

---

## Checklist

- [ ] Repository has a `package.json` with `test` and `lint` scripts
- [ ] Repository has a `Containerfile` (not Dockerfile)
- [ ] You have admin access to the GitHub repo
- [ ] Jenkins is running and the shared library is configured

---

## Step 1 — Add a Jenkinsfile to Your Repository

For most repos, this is the **entire Jenkinsfile**:

```groovy
// Jenkinsfile
@Library('forgeops-shared') _

String branch = env.GIT_BRANCH ?: env.BRANCH_NAME ?: ''
boolean isMain = branch.endsWith('main') || branch.endsWith('master')
boolean isTag  = env.TAG_NAME != null

if (isMain || isTag) {
    cdPipeline(
        appName:  'YOUR-APP-NAME',   // ← change this
        port:     3000,               // ← change this
        registry: env.REGISTRY_HOST ?: 'localhost:5000'
    )
} else {
    ciPipeline(
        appName:     'YOUR-APP-NAME',  // ← change this
        port:        3000,
        nodeVersion: 'nodejs-20'
    )
}
```

### Available configuration options

#### `ciPipeline()`

| Option | Default | Description |
|--------|---------|-------------|
| `appName` | **required** | Application identifier (used as container name) |
| `port` | `3000` | Port your app listens on |
| `nodeVersion` | `nodejs-20` | Jenkins Node.js tool name |
| `runSecurity` | `true` | Run secret scan + dependency audit |
| `failSeverity` | `high` | npm audit severity threshold |

#### `cdPipeline()`

| Option | Default | Description |
|--------|---------|-------------|
| `appName` | **required** | Application identifier |
| `port` | `3000` | Port to expose on the host |
| `registry` | `$REGISTRY_HOST` | Container registry host |
| `runTests` | `true` | Run unit tests before building |
| `runScan` | `true` | Run Trivy image scan after building |
| `deployHook` | `null` | Custom deploy Closure (overrides default) |

---

## Step 2 — Add a Containerfile

```dockerfile
# Containerfile  (Podman-compatible, NOT Dockerfile)
FROM docker.io/node:20-alpine AS builder
WORKDIR /build
COPY package.json package-lock.json ./
RUN npm ci --omit=dev --prefer-offline --no-audit
COPY src/ ./src/

FROM docker.io/node:20-alpine AS production
RUN apk add --no-cache dumb-init \
    && addgroup -S app \
    && adduser  -S app -G app
WORKDIR /app
COPY --from=builder --chown=app:app /build/node_modules ./node_modules
COPY --from=builder --chown=app:app /build/src ./src
USER app
EXPOSE 3000
HEALTHCHECK --interval=15s --timeout=5s --retries=3 \
    CMD node -e "require('http').get('http://localhost:3000/health', r => process.exit(r.statusCode === 200 ? 0 : 1)).on('error', () => process.exit(1))"
ENTRYPOINT ["/usr/bin/dumb-init", "--"]
CMD ["node", "src/index.js"]
```

---

## Step 3 — Ensure Required npm Scripts Exist

```json
// package.json
{
  "scripts": {
    "test":  "jest --coverage --forceExit",
    "lint":  "eslint src --ext .js"
  }
}
```

---

## Step 4 — Add a k6 Load Test (Optional but Recommended)

Create `k6/load-test.js`. See `sample-apps/node-api/k6/load-test.js` for a template.

Enable it in your Jenkinsfile CD pipeline:

```groovy
// After deploy, trigger the test pipeline
testPipeline(
    appName:      'YOUR-APP-NAME',
    targetUrl:    "http://localhost:${PORT}",
    loadVus:      10,
    loadDuration: '30s'
)
```

---

## Step 5 — Create Jenkins Pipeline Job

1. Jenkins → New Item → Name: `YOUR-APP-NAME` → **Multibranch Pipeline**
2. Branch Sources → GitHub → select `github-token` credential
3. Set repository URL
4. Save → Scan Now

---

## Step 6 — Add GitHub Webhook

Follow the [webhook setup guide](webhook-setup.md).

---

## Step 7 — Set App-Specific Secrets (If Needed)

If your app needs environment variables at runtime:

1. Create `/etc/forgeops/YOUR-APP-NAME.env` on the deploy server:

```bash
sudo mkdir -p /etc/forgeops
sudo tee /etc/forgeops/YOUR-APP-NAME.env <<EOF
DATABASE_URL=postgres://user:pass@host/db
API_KEY=your-secret-key
EOF
sudo chmod 600 /etc/forgeops/YOUR-APP-NAME.env
```

2. Pass it to the deploy script in your `deployHook`:

```groovy
deployHook: { Map ctx ->
    sh """
        bash \${WORKSPACE}/../../deployment/deploy.sh \\
            --app      "YOUR-APP-NAME" \\
            --image    "${env.FULL_IMAGE}" \\
            --port     "3000" \\
            --env-file "/etc/forgeops/YOUR-APP-NAME.env"
    """
}
```

---

## That's It!

Push a commit to your repo — the CI pipeline runs automatically.
Merge to `main` — the CD pipeline builds, scans, and deploys.
