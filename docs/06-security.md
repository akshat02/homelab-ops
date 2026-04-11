# 06 — Security

Security posture, threat model, hardening decisions, and ongoing security practices for the home server.

---

## Threat Model

This server is a personal home cloud — not a public-facing production system. The threat model is scoped accordingly:

| Threat | Likelihood | Mitigation |
|---|---|---|
| External attacker via open port | Low (no ports exposed) | Tailscale Zero-Trust — no ports forwarded on router |
| Compromised Tailscale account | Low-Medium | Strong account password + 2FA on Tailscale admin |
| Credential exposure (chat, logs, git) | Medium | `.env` files excluded from git; regular rotation |
| Physical drive theft/loss | Low-Medium | Off-site backup (planned); encryption optional |
| Drive failure / data loss | Medium | Nightly rsync mirror; DB dumps with 7-day retention |
| Malicious Docker image | Low | Pinned versions; official/trusted image sources only |
| OS vulnerability exploitation | Low | Automated security patches via `unattended-upgrades` |
| Container escape | Very Low | No privileged containers; limited device passthrough |

---

## Network Security

### Zero-Trust Model (Tailscale / WireGuard)
All remote access goes exclusively through Tailscale. No ports are forwarded on the home router — the server has no public IP exposure whatsoever.

How it works:
- Tailscale creates an encrypted WireGuard tunnel between authorised devices
- The server is only reachable from devices logged into the same Tailscale account
- Services bind to `0.0.0.0` inside Docker, but are unreachable from the public internet in practice

Verify Tailscale is running and connected:
```bash
tailscale status
```

> **Educational note:** WireGuard (which Tailscale is built on) is a modern VPN protocol designed to be significantly simpler and faster than OpenVPN or IPSec. Its codebase is ~4,000 lines vs OpenVPN's ~600,000 — a smaller attack surface by design. Tailscale adds a control plane on top that handles key distribution and device authentication, removing the need to manage WireGuard keys manually.

### Firewall (UFW)
Default deny on all incoming traffic. Only two exceptions:

```bash
sudo ufw status verbose
```

Expected output:
```
Default: deny (incoming), allow (outgoing)

To                         Action      From
--                         ------      ----
Anywhere on tailscale0     ALLOW IN    Anywhere
22/tcp                     ALLOW IN    Anywhere
```

Port 22 is allowed for SSH. In practice, SSH is only used via Tailscale (the Tailscale IP is the target), so this rule primarily covers local network access.

### SSH Hardening
SSH is enabled for remote administration. Access is via Tailscale only in normal operation.

Verify SSH config:
```bash
sudo nano /etc/ssh/sshd_config
```

Recommended settings (apply if not already set):
```
PermitRootLogin no
PasswordAuthentication yes   # acceptable behind Tailscale; switch to 'no' + key-only for stricter posture
MaxAuthTries 3
```

After any changes:
```bash
sudo systemctl restart ssh
```

> If switching to key-only authentication, ensure your SSH public key is added to `~/.ssh/authorized_keys` on the server **before** disabling password auth — locking yourself out requires physical console access.

---

## Credential Management

### What Credentials Exist

| Credential | Location | Rotation Runbook |
|---|---|---|
| Nextcloud DB password | `<HOME>/nextcloud/.env` + `config.php` | RB-02 |
| Nextcloud DB root password | `<HOME>/nextcloud/.env` | RB-02 |
| Immich DB password | `<HOME>/immich-app/.env` | RB-02 |
| System user password (`<USER>`) | OS | Standard `passwd` command |
| Tailscale account | Tailscale admin console | Tailscale account settings |

### Rules for `.env` Files
- **Never commit `.env` files to version control** — add to `.gitignore` in each project directory
- Store credential values in a separate private notes system (password manager or encrypted note)
- Use only alphanumeric characters and `_` `-` in passwords — shell-unsafe characters (`$`, `` ` ``, `&`, `!`) can break the `export $(... | xargs)` pattern used in the backup script
- Rotate credentials if they have been exposed in chat history, logs, terminal output, or accidentally committed to git

Verify `.env` files are gitignored:
```bash
cat <HOME>/nextcloud/.gitignore
cat <HOME>/immich-app/.gitignore
```

### Credential Rotation
See `docs/04-runbooks/RB-02-password-rotation.md` for the full step-by-step rotation procedure for both Nextcloud and Immich.

Rotate credentials immediately if:
- Credentials appear in chat history or shared documents
- A device with saved SSH sessions is lost or compromised
- You suspect unauthorised access

---

## Docker Security

### Image Policy
- Use **official or project-maintained images** only (Docker Hub official images, `ghcr.io/immich-app/`, etc.)
- **Pin specific versions** for DB-backed services — avoid `latest` tags for anything stateful
- For Immich's Postgres image, use the exact digest-pinned version from the official Immich `docker-compose.yml` — it includes required extensions (`pgvecto.rs`) that a generic Postgres image does not have

### No Privileged Containers
No containers run with `--privileged`. The only elevated capability granted is the `/dev/dri` device passthrough to the Immich server and machine-learning containers for Intel QuickSync hardware acceleration. This is a minimal, scoped grant — not broad privilege escalation.

Verify no privileged containers:
```bash
docker inspect $(docker ps -q) --format '{{.Name}}: Privileged={{.HostConfig.Privileged}}'
```
All values should be `false`.

### Docker Socket Exposure
The Docker socket (`/var/run/docker.sock`) grants root-equivalent access to the host. It was previously mounted into Watchtower. **Watchtower has been removed** — no container currently has access to the Docker socket.

If adding any future container that requests Docker socket access, treat this as a significant security decision requiring deliberate review.

### Volume Mounts
All volume mounts are explicit and scoped:
- No containers mount the entire host filesystem
- Config and data paths are specific subdirectories
- Read-only mounts used where write access is not needed (e.g. `/etc/localtime:/etc/localtime:ro`)

---

## OS Security

### Automatic Security Patches
`unattended-upgrades` applies OS security patches daily. Only security updates are applied automatically — feature releases require manual intervention.

Verify:
```bash
sudo systemctl status unattended-upgrades
cat /var/log/unattended-upgrades/unattended-upgrades.log | tail -20
```

### Minimal Attack Surface
The server runs headless with no desktop environment active during normal operation. XFCE is installed but not used for services — it exists only for occasional local console access if needed.

No unnecessary services are running. Verify listening ports:
```bash
sudo ss -tlnp
```
Expected listeners: SSH (22), Nextcloud (8080), Immich (2283), and Tailscale internal ports.

### Sudo Access
Only `<USER>` has sudo access. The backup script runs as root via root crontab — this is appropriate given it requires `docker exec`, `chown`, and broad filesystem access. No service containers run as root on the host.

---

## Physical Security

### Drive Encryption
Drives are currently **not encrypted**. This means physical access to the external HDDs gives direct access to all data without a password.

For the current threat model (home environment, low physical theft risk), this is an accepted trade-off — encryption adds complexity to headless reboots (requires manual passphrase entry or a key escrow solution).

If the threat model changes (e.g. the server moves to a shared space), consider:
- **LUKS** encryption on the external drives
- **VeraCrypt** containers for particularly sensitive data subsets

### Headless Operation Notes
The server runs lid-closed. If the machine reboots unexpectedly (e.g. after a kernel update at 04:00 AM), it will come back up automatically without requiring physical interaction — all services restart via `restart: always` in Docker Compose, and drives mount via fstab with `nofail`.

Verify the server came back up cleanly after a reboot:
```bash
uptime
docker ps
df -h
```

---

## Security Checklist (Periodic Review)

Run through this every few months:

- [ ] Backup log clean — no errors in last 7 days: `tail -50 <HOME>/backup_log.txt`
- [ ] No containers running as privileged: `docker inspect $(docker ps -q) --format '{{.Name}}: {{.HostConfig.Privileged}}'`
- [ ] No `.env` files committed to git: `git -C <HOME>/nextcloud status` / `git -C <HOME>/immich-app status`
- [ ] Docker socket not mounted in any container: `docker inspect $(docker ps -q) --format '{{.Name}}: {{.HostConfig.Binds}}'`
- [ ] UFW rules unchanged: `sudo ufw status verbose`
- [ ] Tailscale connected and only authorised devices in network: check Tailscale admin console
- [ ] OS security patches up to date: `cat /var/log/unattended-upgrades/unattended-upgrades.log | tail -10`
- [ ] Live drive SMART health not degrading: `sudo smartctl -a <LIVE_DRIVE_DEVICE> | grep -E "187|194|197|198"`
- [ ] Credentials rotated if any exposure occurred since last review: see RB-02
