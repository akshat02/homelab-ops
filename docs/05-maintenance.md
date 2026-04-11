# 05 — Maintenance

Reference for all ongoing maintenance tasks — automated, scheduled, and manual. Covers OS, containers, storage, and off-site backup.

---

## Maintenance Overview

| Task | Frequency | Method | Status |
|---|---|---|---|
| Security updates (OS) | Daily | `unattended-upgrades` | ✅ Automated |
| Kernel reboot (if needed) | As required | `unattended-upgrades` at 04:00 AM | ✅ Automated |
| Nextcloud background tasks | Every 5 min | Root crontab (`cron.php`) | ✅ Automated |
| DB dumps + rsync mirror | Daily 03:00 AM | Root crontab (`daily_backup.sh`) | ✅ Automated |
| Nextcloud image update | Weekly (Sun 02:00 AM) | Root crontab (`docker compose pull`) | ✅ Automated |
| Drive health check | Monthly (manual) | `smartctl` | 🔲 Manual |
| Backup log review | Weekly (manual) | `tail backup_log.txt` | 🔲 Manual |
| Immich update | As needed (manual) | `docker compose pull` | 🔲 Manual |
| Off-site backup (Rclone) | Weekly | Rclone + Backblaze B2 | 🔲 Planned |

---

## OS Maintenance

### Automatic Security Updates
Managed by `unattended-upgrades`. Configured to apply security patches only — no dist-upgrades or major version changes.

Config files:
- `/etc/apt/apt.conf.d/20auto-upgrades` — enables daily update checks and installs
- `/etc/apt/apt.conf.d/50unattended-upgrades` — restricts to security sources, enables auto-reboot at 04:00 AM

Verify it is active:
```bash
sudo systemctl status unattended-upgrades
```

Check upgrade history:
```bash
cat /var/log/unattended-upgrades/unattended-upgrades.log | tail -30
```

> **Educational note:** Limiting auto-upgrades to security patches only is a deliberate trade-off. Feature updates can introduce breaking changes in dependencies (e.g. PHP version bumps affecting Nextcloud). Security patches carry much lower risk and should always be applied promptly — unpatched vulnerabilities in an internet-adjacent system are a meaningful attack surface even behind a VPN.

### Manual Full Upgrade (Periodic)
Run a full system upgrade manually every few months to pick up non-security improvements:
```bash
sudo apt update && sudo apt upgrade -y
sudo apt autoremove -y
```

---

## Container Maintenance

### Nextcloud — Weekly Auto-Update
Nextcloud pulls and restarts automatically every Sunday at 02:00 AM (one hour before the nightly backup):
```
0 02 * * 0 docker compose -f <HOME>/nextcloud/docker-compose.yml pull && docker compose -f <HOME>/nextcloud/docker-compose.yml up -d >> <HOME>/nextcloud_update_log.txt 2>&1
```

Check the update log:
```bash
cat <HOME>/nextcloud_update_log.txt | tail -30
```

If an update causes issues, roll back by pinning the previous image tag in `docker-compose.yml` and running `docker compose up -d`.

> **Note:** MariaDB is pinned to `10.6` in `docker-compose.yml` and is **not** updated automatically. Major MariaDB version upgrades require a manual `mysql_upgrade` step and should be done deliberately. Do not change the pinned tag without reviewing the MariaDB upgrade documentation.

### Immich — Manual Update Only
Immich is excluded from auto-updates due to its active development phase and history of breaking DB migrations. Update manually:

```bash
# 1. Review release notes first
# https://github.com/immich-app/immich/releases

# 2. Pull new images
cd <HOME>/immich-app
docker compose pull

# 3. Apply update
docker compose up -d

# 4. Monitor logs for migration errors
docker logs immich_server --tail 50 -f
```

Key things to check in release notes before updating:
- Any Postgres migration warnings
- Changes to the `.env` variable names or required values
- Breaking changes to the storage template or library structure

### Checking for Outdated Images (All Services)
```bash
docker images | grep -v REPOSITORY
```

To see if a specific image has updates available:
```bash
docker pull <image>:<tag>
```
If the digest changes, an update is available.

### Cleaning Up Unused Docker Resources
Run periodically to reclaim disk space on the internal SSD:
```bash
# Remove stopped containers, unused networks, dangling images
docker system prune -f

# Also remove unused volumes (use with caution — verify nothing important first)
docker volume prune -f
```

Check Docker disk usage:
```bash
docker system df
```

---

## Storage Maintenance

### Monthly Drive Health Check
```bash
sudo smartctl -a <LIVE_DRIVE_DEVICE>
```

Focus on these attributes:

| SMART ID | Name | Action |
|---|---|---|
| 187 | Reported Uncorrectable Errors | Any increase since last check → plan replacement |
| 194 | Temperature | Sustained above 50°C → improve airflow |
| 197 | Current Pending Sector Count | Any value above 0 → run extended self-test |
| 198 | Offline Uncorrectable | Any value above 0 → replace drive immediately |

Run a short self-test:
```bash
sudo smartctl -t short <LIVE_DRIVE_DEVICE>
# Wait 2 minutes
sudo smartctl -a <LIVE_DRIVE_DEVICE> | grep -A5 "Self-test"
```

Run an extended self-test (more thorough, takes longer):
```bash
sudo smartctl -t long <LIVE_DRIVE_DEVICE>
# Check results after completion (time estimate shown in output)
sudo smartctl -a <LIVE_DRIVE_DEVICE> | grep -A10 "Self-test"
```

> **Educational note:** External USB HDDs have a harder life than internal drives — they experience more vibration, run warmer due to enclosure design, and USB-attached drives sometimes don't report SMART data accurately depending on the USB-SATA bridge chip. The `-d sat` flag in `smartd.conf` instructs smartmontools to pass ATA commands through the USB bridge, which improves SMART reliability on most drives.

### Checking Disk Space
```bash
# Overall usage
df -h

# What's consuming space on the Live Drive
du -sh /mnt/data_live/*/
du -sh /mnt/data_live/immich_library/
du -sh /mnt/data_live/nextcloud_data/
```

### Verifying rsync Mirror Integrity
Spot-check that the backup drive mirrors the live drive:
```bash
# Compare file counts in key directories
find /mnt/data_live/immich_library/ -type f | wc -l
find /mnt/data_backup/immich_library/ -type f | wc -l
```

For a full integrity check (dry run — no changes made):
```bash
sudo rsync -avn --delete /mnt/data_live/ /mnt/data_backup/
```
A clean mirror will show no files to transfer. Any listed files are out of sync.

---

## Backup Maintenance

### Weekly Backup Log Review
```bash
tail -30 <HOME>/backup_log.txt
```
Look for any `ERROR:` lines. A clean run ends with `Backup process finished.`

### Verifying DB Dump Files
```bash
# Check dumps exist and are recent
ls -lh /mnt/data_live/backups/immich_db/
ls -lh /mnt/data_live/backups/nextcloud_db/

# Spot-check dump validity
gunzip -c /mnt/data_live/backups/immich_db/dump_YYYY-MM-DD.sql.gz | head -5
head -5 /mnt/data_live/backups/nextcloud_db/nextcloud_db_YYYY-MM-DD.sql
```
A valid dump starts with SQL comments. An empty file or shell error message means the dump failed silently.

### Running a Manual Backup
```bash
sudo bash <HOME>/daily_backup.sh
```

---

## Off-Site Backup — Rclone + Backblaze B2 (Planned)

Not yet implemented. When configured, this section will document the setup and verification steps.

### Planned Design
- **Tool:** `rclone` with a `crypt` remote layered over a Backblaze B2 remote
- **Source:** `/mnt/data_backup/` (post-rsync mirror — already consistent)
- **Encryption:** Client-side via `rclone crypt` — Backblaze sees only encrypted blobs
- **Schedule:** Weekly cron job, after the nightly rsync
- **Retention:** Managed via Backblaze B2 lifecycle rules

### Setup Outline (for implementation)

```bash
# Install rclone
sudo apt install rclone

# Configure remotes interactively
rclone config
# 1. Create a new remote → name: b2 → type: b2
#    Enter B2 Account ID and Application Key
# 2. Create a new remote → name: b2-crypt → type: crypt
#    Remote: b2:your-bucket-name/encrypted
#    Enter filename and directory encryption passwords (store in private notes)

# Test connection
rclone lsd b2-crypt:

# Dry run first
rclone sync /mnt/data_backup/ b2-crypt: --dry-run --progress

# Live run
rclone sync /mnt/data_backup/ b2-crypt: --progress
```

Crontab entry (weekly, Saturday 04:00 AM — after Friday night backup):
```
0 04 * * 6 /usr/bin/rclone sync /mnt/data_backup/ b2-crypt: >> <HOME>/rclone_log.txt 2>&1
```

> **Educational note:** `rclone sync` is destructive in one direction — it makes the destination match the source, including deletions. This is correct for a mirror but means a ransomware event that encrypts your live data and propagates to the backup drive would also propagate to B2 on the next sync. Backblaze B2's object versioning or `rclone copy` (which never deletes) can mitigate this at the cost of higher storage use.

---

## Crontab Reference (Root)

Current root crontab — view with `sudo crontab -l`:

```
*/5 * * * * docker exec -u www-data <NEXTCLOUD_APP_CONTAINER> php -f /var/www/html/cron.php
00 03 * * * /bin/bash <HOME>/daily_backup.sh
0 02 * * 0 docker compose -f <HOME>/nextcloud/docker-compose.yml pull && docker compose -f <HOME>/nextcloud/docker-compose.yml up -d >> <HOME>/nextcloud_update_log.txt 2>&1
```

---

## Log Files Reference

| Log | Location | What it covers |
|---|---|---|
| Backup runs | `<HOME>/backup_log.txt` | DB dumps, rsync, errors |
| Nextcloud updates | `<HOME>/nextcloud_update_log.txt` | Weekly image pull and restart output |
| OS security updates | `/var/log/unattended-upgrades/unattended-upgrades.log` | Packages installed, errors |
| Docker daemon | `journalctl -u docker` | Docker engine events |
| Container logs | `docker logs <container> --tail 50` | Per-container stdout/stderr |
| Kernel / drive errors | `dmesg | grep -i error` | I/O errors, USB disconnects |
| smartd alerts | `journalctl -u smartd` | Drive health events |
