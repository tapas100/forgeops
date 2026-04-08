# 🔧 ForgeOps Platform

> Production-grade CI/CD platform running on Hetzner Cloud (CAX11 ARM)  
> Powered by Jenkins + Podman (rootless, daemonless) + Nginx

---

## 🏗️ Architecture Overview

```
GitHub Repos
     │
     │  (Webhooks)
     ▼
  Nginx (HTTPS Reverse Proxy)
     │
     ▼
  Jenkins LTS (Podman container)
     │
     ├── Shared Pipeline Library (vars/)
     │       ├── build.groovy
     │       ├── test.groovy
     │       ├── security.groovy
     │       └── notify.groovy
     │
     ├── CI Pipeline  → Install → Lint → Unit Tests
     ├── CD Pipeline  → Build Image → Push → Deploy
     └── Test Pipeline → API Tests → k6 Load Tests
          │
          ▼
     Podman (rootless) → Running Containers
```

---

## 📁 Repository Structure

```
forgeops/
├── README.md                          # This file
│
├── jenkins/                           # Jenkins setup & configuration
│   ├── setup/
│   │   ├── install-jenkins.sh         # Jenkins installation via Podman
│   │   ├── configure-jenkins.sh       # Post-install configuration
│   │   └── podman-systemd.service     # Systemd unit for Jenkins container
│   ├── casc/
│   │   └── jenkins.yaml               # Configuration-as-Code (JCasC)
│   └── plugins.txt                    # Required Jenkins plugins list
│
├── shared-library/                    # Jenkins Shared Pipeline Library
│   ├── vars/
│   │   ├── build.groovy               # Build stage logic
│   │   ├── test.groovy                # Test stage logic
│   │   ├── security.groovy            # Security scanning logic
│   │   └── notify.groovy              # Notification logic
│   └── src/
│       └── org/forgeops/
│           ├── PipelineConfig.groovy  # Pipeline configuration class
│           └── Utils.groovy           # Utility functions
│
├── pipelines/                         # Pipeline templates
│   ├── ci-pipeline.groovy             # CI pipeline template
│   ├── cd-pipeline.groovy             # CD pipeline template
│   └── test-pipeline.groovy           # Testing pipeline template
│
├── nginx/                             # Nginx reverse proxy configuration
│   ├── nginx.conf                     # Main Nginx config
│   ├── conf.d/
│   │   └── jenkins.conf               # Jenkins site config
│   └── ssl/
│       └── .gitkeep                   # Placeholder for SSL certs
│
├── deployment/                        # Podman-based deployment scripts
│   ├── deploy.sh                      # Generic deployment script
│   ├── rollback.sh                    # Rollback to previous image
│   └── health-check.sh                # Post-deploy health check
│
├── cleanup/                           # Maintenance & cleanup scripts
│   ├── podman-prune.sh                # Container/image cleanup
│   └── log-rotate.sh                  # Log rotation script
│
├── security/                          # Security configurations
│   ├── seccomp-profile.json           # Podman seccomp security profile
│   └── jenkins-credentials-setup.sh  # Credential bootstrapping guide
│
├── observability/                     # Logging & metrics stubs
│   ├── prometheus/
│   │   └── prometheus.yml             # Prometheus scrape config (future)
│   └── loki/
│       └── loki-config.yaml           # Loki log aggregation (future)
│
├── sample-apps/                       # Sample Node.js applications
│   ├── node-api/                      # Sample REST API
│   │   ├── src/
│   │   │   └── index.js
│   │   ├── tests/
│   │   │   └── index.test.js
│   │   ├── k6/
│   │   │   └── load-test.js
│   │   ├── Containerfile              # Podman-compatible (not Dockerfile)
│   │   ├── Jenkinsfile
│   │   └── package.json
│   └── node-worker/                   # Sample background worker
│       ├── src/
│       │   └── worker.js
│       ├── tests/
│       │   └── worker.test.js
│       ├── Containerfile
│       ├── Jenkinsfile
│       └── package.json
│
└── docs/                              # Documentation
    ├── webhook-setup.md               # GitHub webhook configuration guide
    ├── adding-new-repo.md             # How to onboard a new repository
    ├── security-hardening.md          # Security best practices
    └── troubleshooting.md             # Common issues & solutions
```

---

## 🚀 Quick Start

### Prerequisites

- **Hetzner Cloud CAX11** server (2 vCPU ARM / 4 GB RAM / 40 GB NVMe — ~€3.29/mo)
- Ubuntu 22.04 LTS (select during Hetzner server creation)
- Domain name (or use IP directly for testing)
- GitHub account with repositories to connect

### 1. Provision the Server

```bash
# On Hetzner Cloud Console (console.hetzner.cloud):
# 1. New Project → Add Server
# 2. Location: Falkenstein / Nuremberg / Helsinki (pick closest)
# 3. OS Image: Ubuntu 22.04
# 4. Type: Shared vCPU → ARM64 (Ampere) → CAX11 (2 vCPU / 4 GB / €3.29)
# 5. Add your SSH public key
# 6. Create & Buy (firewall opens 22/80/443 by default)
```

### 2. Install Podman

```bash
sudo apt-get update
sudo apt-get install -y podman
podman --version  # Verify installation
```

### 3. Deploy Jenkins

```bash
git clone https://github.com/YOUR_ORG/forgeops.git
cd forgeops
chmod +x jenkins/setup/install-jenkins.sh
./jenkins/setup/install-jenkins.sh
```

### 4. Configure Nginx

```bash
sudo apt-get install -y nginx certbot python3-certbot-nginx
sudo cp nginx/conf.d/jenkins.conf /etc/nginx/conf.d/
# Edit the server_name in jenkins.conf to your domain
sudo nginx -t && sudo systemctl reload nginx
sudo certbot --nginx -d your-domain.com
```

### 5. Complete Jenkins Setup

Open `https://your-domain.com` and follow the setup wizard, or use JCasC:

```bash
chmod +x jenkins/setup/configure-jenkins.sh
./jenkins/setup/configure-jenkins.sh
```

### 6. Register the Shared Library

In Jenkins → Manage Jenkins → Configure System → Global Pipeline Libraries:
- Name: `forgeops-shared`
- SCM: Git
- URL: `https://github.com/YOUR_ORG/forgeops.git`
- Credential: your GitHub PAT
- Path: `shared-library`

---

## 🔄 Pipeline Modes

| Pipeline | Trigger | Stages |
|----------|---------|--------|
| **CI** | Every push | Install → Lint → Unit Tests |
| **CD** | `main` branch / tag | Build Image → Push → Deploy |
| **Test** | Post-deploy | API Tests → k6 Load Tests |

---

## 📦 Adding a New Repository

See [`docs/adding-new-repo.md`](docs/adding-new-repo.md) for the full guide.

**TL;DR**: Add this minimal `Jenkinsfile` to your repo:

```groovy
@Library('forgeops-shared') _

ciPipeline(
  appName: 'my-app',
  port: 3000
)
```

---

## 🔐 Security Highlights

- Jenkins runs as non-root via Podman rootless
- No secrets in code — all credentials via Jenkins Credential Store
- Nginx enforces HTTPS with TLS 1.2+
- Containers run with seccomp profiles
- Automatic container image vulnerability awareness

---

## 🗺️ Roadmap

- [ ] Kubernetes migration support (Helm charts)
- [ ] Prometheus + Grafana metrics dashboard
- [ ] Loki log aggregation
- [ ] Automated SSL renewal
- [ ] Multi-node Jenkins agent support
- [ ] GitOps workflow (ArgoCD integration)

---

## 📄 License

MIT — see [LICENSE](LICENSE)
