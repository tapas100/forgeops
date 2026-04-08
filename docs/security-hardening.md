# Security Hardening Guide

Production security practices applied in the ForgeOps platform.

---

## 1. Podman Rootless Operation

Jenkins and all application containers run without root privileges.

**How it works:**
- Jenkins container is started by a regular OS user (not `root` or `sudo`)
- Podman uses user namespaces — UID 0 inside the container maps to a non-privileged UID on the host
- The container runtime daemon is Podman (daemonless) — there is no privileged daemon to compromise

**Verify:**
```bash
# Container should show a non-root UID on the host
ps aux | grep jenkins
# Expected: your_user 12345 ... /usr/bin/conmon ...

# Inside the container
podman exec jenkins id
# Expected: uid=0(root) gid=0(root) -- this is the *container* root, not host root
```

---

## 2. Container Capabilities

All application containers are started with `--cap-drop=ALL`.

Only add specific capabilities if your app explicitly needs them:

```bash
# Only grant what is needed, never --cap-add=SYS_ADMIN
podman run --cap-drop=ALL --cap-add=NET_BIND_SERVICE myapp
```

**Capabilities denied by default:**
- `SYS_ADMIN` — prevents namespace escapes
- `NET_ADMIN` — prevents network manipulation
- `SETUID` / `SETGID` — prevents privilege escalation
- `SYS_PTRACE` — prevents process inspection

---

## 3. Seccomp Profiles

The `security/seccomp-profile.json` restricts which Linux system calls containers may make.

Apply to a container:

```bash
podman run \
  --security-opt seccomp=/opt/forgeops/security/seccomp-profile.json \
  --name myapp \
  myimage
```

The profile allows ~200 common syscalls and blocks ~300+ dangerous ones
(e.g., `ptrace`, `reboot`, `mount`, `unshare`).

---

## 4. No New Privileges

All containers run with `--security-opt=no-new-privileges:true`.

This prevents:
- SUID/SGID privilege escalation
- Ambient capability acquisition

---

## 5. Read-Only Root Filesystem

Application containers use `--read-only` with an explicit tmpfs for writable paths:

```bash
podman run \
  --read-only \
  --tmpfs /tmp:rw,noexec,nosuid,size=64m \
  myapp
```

This prevents:
- Writing malicious binaries to the container filesystem
- Log injection / log replacement attacks

---

## 6. Jenkins Authentication

Jenkins is configured with:
- **Local user database** (sign-up disabled)
- **Matrix-based security** (only `admin` has full access)
- **CSRF protection** (crumb issuer enabled)
- **Content Security Policy** header to prevent XSS

**Disable the Jenkins Script Console for non-admins:**
```
Jenkins → Manage Jenkins → Security → Disable CLI over remoting ✓
```

---

## 7. Secret Management

Secrets are **never** stored in:
- Jenkinsfiles
- Shared library code
- Container images
- Git repositories
- Environment files committed to VCS

Secrets are stored in **Jenkins Credential Store** (encrypted at rest) and injected at runtime:

```groovy
withCredentials([string(credentialsId: 'my-secret', variable: 'MY_SECRET')]) {
    sh 'use-secret "$MY_SECRET"'
}
```

Runtime secrets (database passwords, API keys) are stored in `/etc/forgeops/*.env` files with `chmod 600`.

---

## 8. Nginx TLS Configuration

- **TLS 1.2 and 1.3 only** (TLS 1.0 / 1.1 disabled)
- **HSTS** enforced (6 months, including subdomains)
- **Forward secrecy** (ECDHE key exchange only)
- **OCSP stapling** via certbot renewal
- Nginx version hidden (`server_tokens off`)

**Test your TLS configuration:**
```bash
# Using ssllabs-scan or nmap
nmap --script ssl-enum-ciphers -p 443 your-domain.com
```

---

## 9. Network Isolation

- Jenkins binds to `127.0.0.1` only — Nginx is the only public entry point
- Application containers expose ports on `127.0.0.1` only (not `0.0.0.0`)
- Oracle Cloud Security List: only ports 22, 80, 443 open inbound

```bash
# Verify Jenkins is NOT exposed externally
ss -tlnp | grep 8080
# Expected: 127.0.0.1:8080 (not 0.0.0.0:8080)
```

---

## 10. Image Supply Chain

- Base images are pinned to digest (not just tag) in production Containerfiles:
  ```dockerfile
  FROM docker.io/node:20-alpine@sha256:DIGEST
  ```
- All images are scanned with **Trivy** before deployment
- Images are built from source — no pre-built images from untrusted sources
- **Gitleaks** runs on every commit to prevent secret leaks

---

## 11. Audit Log

Jenkins records all user actions. Enable the audit trail plugin for forensics:

```
Jenkins → Manage Jenkins → System Log → Add new log recorder
```

Forward Nginx and Jenkins logs to a SIEM or Loki instance for retention.

---

## Periodic Security Tasks

| Task | Frequency |
|------|-----------|
| `npm audit` on all apps | Every CI run |
| Trivy image scan | Every CD run |
| Gitleaks secret scan | Every CI run |
| Update base images | Weekly |
| Rotate Jenkins admin password | Quarterly |
| Review active credentials | Monthly |
| Podman + OS security updates | Weekly (`unattended-upgrades`) |
