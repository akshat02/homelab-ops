# RB-05 — Full Reinstall

## Purpose
Use this runbook to rebuild the home server from scratch — either on the same hardware after an OS failure, or on a new/replacement machine. Covers OS setup, Docker, storage, service restoration, and verification.

This runbook assumes:
- The **Backup Drive is intact** and contains a recent rsync mirror of all data
- DB dump files are present at `/mnt/data_backup/backups/`
- You have physical or remote access to the machine during OS installation

If the Backup Drive is also lost, restoration must come from off-site backup (Backblaze B2 — if configured). That path is noted where relevant but not fully detailed here.

---

## Estimated Time
- Clean OS install + base config: ~1 hour
- Docker + service restoration: ~1–2 hours
- Data verification: ~30 minutes
- **Total: ~2.5–3.5 hours** (excluding large data transfers)

---

## What You Will Need
- Linux Mint 22.x XFCE ISO (bootable USB)
- Physical keyboard and monitor connected to the server (for initial OS install)
- SSH access from another device once network is up
- Backup Drive with recent data
- Your private notes containing:
  - `<BACKUP_DRIVE_UUID>` and `<LIVE_DRIVE_UUID>`
  - Nextcloud and Immich `.env` credential values
  - Tailscale auth key (or access to Tailscale admin console)

---

## Phase 1 — OS Installation

### 1. Boot from Linux Mint installer USB
Install Linux Mint 22.x XFCE onto the internal SSD. During installation:
- Select the internal SSD as the installation target — **do not touch the external HDDs**
- Create primary user: `<USER>`
- Set a strong system password
- Enable full disk encryption if desired (note: complicates headless reboots)

### 2. First boot — update the system
```bash
sudo apt update && sudo apt upgrade -y
```

### 3. Install essential packages
```bash
sudo apt install -y \
  openssh-server \
  curl \
  wget \
  git \
  nano \
  htop \
  smartmontools \
  unattended-upgrades \
  apt-listchanges
```

### 4. Configure SSH
Verify SSH is running:
```bash
sudo systemctl enable ssh
sudo systemctl start ssh
```

From this point, the rest of the setup can be done over SSH from your Mac.

### 5. Configure headless lid-closed operation
```bash
sudo nano /etc/systemd/logind.conf
```
Set:
```
HandleLidSwitch=ignore
HandleLidSwitchExternalPower=ignore
```
Apply:
```bash
sudo systemctl restart systemd-logind
```

---

## Phase 2 — User and Group Setup

### 6. Add user to required groups
```bash
sudo usermod -aG sudo,docker,www-data <USER>
```
> The `docker` group does not exist yet — Docker installation in Phase 3 will create it. Re-run this after Docker is installed if needed.

### 7. Verify group membership (after re-login)
```bash
groups <USER>
# Should include: sudo docker www-data
```

---

## Phase 3 — Docker Installation

### 8. Install Docker Engine
```bash
curl -fsSL https://get.docker.com | sudo sh
```

### 9. Add user to docker group
```bash
sudo usermod -aG docker <USER>
```
Log out and back in for the group change to take effect.

### 10. Verify Docker
```bash
docker --version
docker compose version
```

---

## Phase 4 — Storage Setup

### 11. Connect external drives
Connect both external HDDs via the USB hub. Identify them:
```bash
lsblk -o NAME,SIZE,FSTYPE,MOUNTPOINT,UUID
```

Cross-reference UUIDs from your private notes:
- `<LIVE_DRIVE_UUID>` → should match the drive containing `nextcloud_data`, `immich_library` etc.
- `<BACKUP_DRIVE_UUID>` → the backup mirror

> If the Live Drive was the one that failed and prompted this reinstall, mount the Backup Drive in its place. See RB-01 and RB-03 for drive promotion steps.

### 12. Create mount points
```bash
sudo mkdir -p /mnt/data_live
sudo mkdir -p /mnt/data_backup
```

### 13. Test mounts manually
```bash
sudo mount UUID=<LIVE_DRIVE_UUID> /mnt/data_live
sudo mount UUID=<BACKUP_DRIVE_UUID> /mnt/data_backup

# Verify data is present
ls /mnt/data_live/
# Expected: nextcloud_data  immich_library  backups  lost+found
```

### 14. Configure persistent mounts in fstab
```bash
sudo nano /etc/fstab
```
Add:
```
UUID=<LIVE_DRIVE_UUID>    /mnt/data_live   ext4  defaults,nofail,noatime,x-systemd.device-timeout=5s  0  2
UUID=<BACKUP_DRIVE_UUID>  /mnt/data_backup ext4  defaults,nofail,noatime,x-systemd.device-timeout=5s  0  2
```

Test fstab without rebooting:
```bash
sudo umount /mnt/data_live /mnt/data_backup
sudo mount -a
ls /mnt/data_live/  # verify
```

### 15. Fix mount point permissions
```bash
sudo chmod 775 /mnt/data_live /mnt/data_backup
sudo chown -R www-data:www-data /mnt/data_live/nextcloud_data
sudo chown -R www-data:www-data /mnt/data_live/immich_library
sudo chown -R www-data:www-data /mnt/data_live/backups
```

---

## Phase 5 — Tailscale Installation

### 16. Install Tailscale
```bash
curl -fsSL https://tailscale.com/install.sh | sh
```

### 17. Authenticate
```bash
sudo tailscale up
```
Follow the authentication URL, or use a pre-generated auth key:
```bash
sudo tailscale up --authkey=<TAILSCALE_AUTH_KEY>
```

### 18. Verify Tailscale IP
```bash
tailscale ip -4
```
Note the IP — this is your `<SERVER_TAILSCALE_IP>` for service access.

---

## Phase 6 — Firewall Configuration

### 19. Configure UFW
```bash
sudo apt install -y ufw
sudo ufw default deny incoming
sudo ufw default allow outgoing
sudo ufw allow in on tailscale0
sudo ufw allow 22/tcp
sudo ufw enable
sudo ufw status
```

---

## Phase 7 — Restore Nextcloud

### 20. Recreate project directory and configs
```bash
mkdir -p <HOME>/nextcloud/config
```

Restore `docker-compose.yml` from the repo:
```bash
# Clone your repo, or copy the file manually
cp /path/to/repo/config/nextcloud/docker-compose.yml <HOME>/nextcloud/
```

Create `.env` with your credentials from private notes:
```bash
nano <HOME>/nextcloud/.env
```
```
DB_ROOT_PASSWORD=
DB_PASSWORD=
DB_USER=
DB_NAME=
```

### 21. Start only the database container first
```bash
cd <HOME>/nextcloud
docker compose up -d db
```
Wait ~15 seconds for MariaDB to initialise:
```bash
docker logs nextcloud-db-1 --tail 20
# Wait until you see: "ready for connections"
```

### 22. Restore Nextcloud database from dump
Identify the most recent dump:
```bash
ls -lh /mnt/data_live/backups/nextcloud_db/
```

Restore:
```bash
docker exec -i <NEXTCLOUD_DB_CONTAINER> mysql \
  -u root -p"${DB_ROOT_PASSWORD}" "${DB_NAME}" \
  < /mnt/data_live/backups/nextcloud_db/nextcloud_db_YYYY-MM-DD.sql
```

### 23. Start the full Nextcloud stack
```bash
cd <HOME>/nextcloud
docker compose up -d
```

### 24. Restore `config.php`
The Nextcloud config is stored in the volume-mounted `<HOME>/nextcloud/config/` directory. If this directory was preserved from the old install (e.g. on the Live Drive or internal SSD), copy it back:
```bash
cp -r /path/to/backup/nextcloud/config/* <HOME>/nextcloud/config/
```

If `config.php` is not available, Nextcloud will run a fresh setup wizard. After completing it, manually update `dbpassword` in the generated `config.php` to match your restored DB credentials.

### 25. Run Nextcloud file scan
```bash
docker exec -u www-data <NEXTCLOUD_APP_CONTAINER> php occ files:scan --all
```
This re-indexes all files from the mounted data volume.

### 26. Verify Nextcloud
```
http://<SERVER_TAILSCALE_IP>:8080
```
Log in and confirm files are accessible.

---

## Phase 8 — Restore Immich

### 27. Recreate project directory
```bash
mkdir -p <HOME>/immich-app
```

Restore `docker-compose.yml` from the repo:
```bash
cp /path/to/repo/config/immich/docker-compose.yml <HOME>/immich-app/
```

Create `.env` from private notes:
```bash
nano <HOME>/immich-app/.env
```
```
UPLOAD_LOCATION=/mnt/data_live/immich_library
DB_DATA_LOCATION=<HOME>/immich-app/postgres
TZ=Asia/Kolkata
IMMICH_VERSION=
DB_PASSWORD=
DB_USERNAME=
DB_DATABASE_NAME=
```

### 28. Start only the database container first
```bash
cd <HOME>/immich-app
docker compose up -d database
```
Wait ~15 seconds:
```bash
docker logs immich_postgres --tail 20
# Wait until: "database system is ready to accept connections"
```

### 29. Restore Immich database from dump
```bash
ls -lh /mnt/data_live/backups/immich_db/
```

Restore:
```bash
gunzip -c /mnt/data_live/backups/immich_db/dump_YYYY-MM-DD.sql.gz | \
  docker exec -i <IMMICH_DB_CONTAINER> psql -U postgres
```

### 30. Start the full Immich stack
```bash
cd <HOME>/immich-app
docker compose up -d
```

Verify all containers are healthy (~30–60 seconds):
```bash
docker ps
```

### 31. Verify Immich
```
http://<SERVER_TAILSCALE_IP>:2283
```
Confirm the photo library is visible. Immich will re-generate thumbnails in the background — this is expected and may take time depending on library size.

---

## Phase 9 — Restore Automation

### 32. Restore backup script
```bash
cp /path/to/repo/scripts/daily_backup.sh <HOME>/daily_backup.sh
nano <HOME>/daily_backup.sh  # set SERVER_USER, container name variables at top
chmod +x <HOME>/daily_backup.sh
```

### 33. Configure root crontab
```bash
sudo crontab -e
```
Add:
```
*/5 * * * * docker exec -u www-data <NEXTCLOUD_APP_CONTAINER> php -f /var/www/html/cron.php
00 03 * * * /bin/bash <HOME>/daily_backup.sh
0 02 * * 0 docker compose -f <HOME>/nextcloud/docker-compose.yml pull && docker compose -f <HOME>/nextcloud/docker-compose.yml up -d >> <HOME>/nextcloud_update_log.txt 2>&1
```

### 34. Run a manual backup to verify
```bash
sudo bash <HOME>/daily_backup.sh
tail -30 <HOME>/backup_log.txt
```

---

## Phase 10 — OS Maintenance Configuration

### 35. Configure unattended-upgrades
```bash
sudo nano /etc/apt/apt.conf.d/20auto-upgrades
```
```
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
```

```bash
sudo nano /etc/apt/apt.conf.d/50unattended-upgrades
```
Ensure these are set:
```
Unattended-Upgrade::Allowed-Origins { "${distro_id}:${distro_codename}-security"; };
Unattended-Upgrade::Remove-Unused-Dependencies "true";
Unattended-Upgrade::Automatic-Reboot "true";
Unattended-Upgrade::Automatic-Reboot-Time "04:00";
```

### 36. Configure smartd for drive monitoring
```bash
sudo nano /etc/smartd.conf
```
Add monitoring for the Live Drive (replace `<LIVE_DRIVE_DEVICE>` with actual device, e.g. `/dev/sdb`):
```
<LIVE_DRIVE_DEVICE> -a -o on -S on -n standby,q -W 4,45,50 -d sat \
  -m root -M exec /usr/local/bin/smartd-notify.sh
```

Restore the notify script:
```bash
sudo nano /usr/local/bin/smartd-notify.sh
```
```bash
#!/bin/bash
notify-send "smartd ALERT" "$SMARTD_MESSAGE" --urgency=critical
```
```bash
sudo chmod +x /usr/local/bin/smartd-notify.sh
sudo systemctl enable smartd
sudo systemctl restart smartd
```

---

## Phase 11 — Final Verification

### Full system checklist

```bash
# All containers running
docker ps -a

# Drives mounted correctly
df -h

# Tailscale connected
tailscale status

# Firewall active
sudo ufw status

# Crontab set
sudo crontab -l

# Drive health
sudo smartctl -a <LIVE_DRIVE_DEVICE> | grep -E "ID#|187|194|197|198"
```

### Service checklist
- [ ] Nextcloud loads and files are accessible: `http://<SERVER_TAILSCALE_IP>:8080`
- [ ] Immich loads and photo library is visible: `http://<SERVER_TAILSCALE_IP>:2283`
- [ ] Manual backup ran successfully: `tail -20 <HOME>/backup_log.txt`
- [ ] Tailscale IP is reachable from Mac/phone
- [ ] SSH access confirmed over Tailscale
- [ ] smartd running: `sudo systemctl status smartd`
- [ ] unattended-upgrades active: `sudo systemctl status unattended-upgrades`

---

## Notes on Immich Thumbnail Regeneration

After a full restore, Immich will have the original photo and video files but will need to regenerate thumbnails and re-run ML jobs (face detection, CLIP embeddings). This happens automatically in the background but can take hours to days on constrained hardware.

To monitor progress:
- Open Immich Admin UI → `Administration → Jobs`
- Throttle concurrency to 1 to avoid thermal issues during regeneration

---

## Notes on New Hardware

If reinstalling on a **different/faster machine**:
- The entire runbook applies — only the hardware context in `docs/01-architecture.md` needs updating
- If the new machine has more RAM (e.g. an Intel N100 Mini PC with 8–16 GB), Immich job concurrency can be increased beyond 1
- Intel N100 and similar modern mini PCs support hardware transcoding via VA-API — review Immich hardware acceleration docs before deploying
- Update `docs/01-architecture.md` with new hardware specs after migration
