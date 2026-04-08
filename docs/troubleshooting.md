# Troubleshooting Guide

Common issues and solutions for the ForgeOps platform.

---

## Jenkins

### Jenkins won't start

```bash
# Check container status
podman ps -a | grep jenkins

# Check logs
podman logs jenkins --tail 100

# Check if port is in use
ss -tlnp | grep 8080
```

Common causes:
- `JENKINS_HOME` permission denied → `sudo chown -R $(id -u) /opt/forgeops/jenkins_home`
- Port 8080 already in use → change `JENKINS_HTTP_PORT` in `install-jenkins.sh`
- Not enough memory → reduce `JENKINS_MEMORY` or check `free -h`

---

### Jenkins restarts on server reboot

```bash
# Verify systemd user service is enabled
systemctl --user status container-jenkins

# Re-enable if needed
systemctl --user enable container-jenkins

# Ensure lingering is active (allows user services to run without login)
loginctl show-user $(whoami) | grep Linger
# Should show: Linger=yes
# If not:
loginctl enable-linger $(whoami)
```

---

### Pipeline checkout fails with auth error

```bash
# Test the token manually
curl -H "Authorization: token YOUR_TOKEN" https://api.github.com/user

# Verify credential is stored correctly in Jenkins
# Jenkins → Manage Credentials → (global) → github-token → Update
```

---

### Build stuck / hangs

```bash
# Check running builds
podman exec jenkins cat /proc/$(podman exec jenkins pgrep -n java)/status

# Kill stuck build via Jenkins UI
# Jenkins → Build History → Click the build → Stop (✕)

# Or via CLI
java -jar jenkins-cli.jar -s http://127.0.0.1:8080/jenkins stop-builds JOB_NAME
```

---

## Podman

### `podman: command not found` in pipeline

The Jenkins container does not have Podman inside it. Deploy scripts run **on the host** (or a Podman agent), not inside Jenkins.

To run Podman commands from Jenkins pipelines:
1. Add the host's Podman socket to the Jenkins container (see `install-jenkins.sh`)
2. OR use SSH to connect to the deploy host from the pipeline

---

### `ERRO[...] open /run/user/.../podman.sock: no such file or directory`

```bash
# Start the Podman socket for your user
systemctl --user start podman.socket
systemctl --user enable podman.socket

# Verify
ls /run/user/$(id -u)/podman/podman.sock
```

---

### Container exits immediately after deploy

```bash
# Check exit code and logs
podman ps -a --filter name=YOUR-APP
podman logs YOUR-APP

# Common cause: process crashes on startup
# Fix: test the image locally first
podman run --rm -it YOUR-IMAGE node src/index.js
```

---

### `Error: crun: ... EPERM: Operation not permitted`

This happens when a container tries to use a denied system call.

```bash
# Try running without seccomp (diagnosis only — revert after)
podman run --security-opt=seccomp=unconfined YOUR-IMAGE

# If it works, the seccomp profile needs updating
# Add the required syscall to security/seccomp-profile.json
```

---

### Disk full / no space left

```bash
# Check disk usage
df -h
podman system df

# Run cleanup immediately
/opt/forgeops/cleanup/podman-prune.sh

# Nuclear option (removes ALL unused images — use carefully)
podman system prune --all --volumes --force
```

---

## Nginx

### 502 Bad Gateway

```bash
# Check Jenkins is running
curl -s http://127.0.0.1:8080/jenkins/login | head -20

# Check Nginx error log
sudo tail -50 /var/log/nginx/error.log

# Reload Nginx config
sudo nginx -t && sudo systemctl reload nginx
```

---

### SSL certificate errors

```bash
# Renew certificates
sudo certbot renew --dry-run   # Test first
sudo certbot renew             # If dry-run passes

# Check certificate expiry
sudo certbot certificates

# Check Nginx is using the right cert
openssl s_client -connect your-domain.com:443 -servername your-domain.com < /dev/null \
  | openssl x509 -noout -dates
```

---

## Build Failures

### `npm ci` fails: `ENOENT package-lock.json`

Commit your `package-lock.json` to the repository. `npm ci` requires it.

```bash
npm install   # Generates package-lock.json
git add package-lock.json
git commit -m "chore: add package-lock.json"
```

---

### k6 test fails with `connection refused`

The app is not yet listening when k6 starts. The health-check stage should catch this, but if k6 runs in a separate pipeline job:

```bash
# Wait for the app to be ready before running k6
until curl -sf http://localhost:3000/health; do sleep 2; done
k6 run k6/load-test.js
```

---

### Trivy scan times out

```bash
# Pre-download the Trivy vulnerability database manually
trivy image --download-db-only

# Or skip db update in the scan (use cached db)
trivy image --skip-db-update YOUR-IMAGE
```

---

## Getting More Information

```bash
# Jenkins system log
podman exec jenkins cat /var/jenkins_home/logs/jenkins.log | tail -100

# All container events
podman events --since 1h

# Podman version and info
podman info

# System resources
free -h && df -h && uptime
```
