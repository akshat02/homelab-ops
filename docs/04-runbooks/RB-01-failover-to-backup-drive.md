# RB-01 — Failover to Backup Drive

## Purpose
Use this runbook when the Live Drive (`/mnt/data_live`) has failed or is showing critical SMART errors and you need to promote the Backup Drive to become the new Live Drive.

---

## Prerequisites
- SSH access to the server (via Tailscale)
- Backup Drive (`/mnt/data_backup`) is mounted and accessible
- Recent data confirmed on backup drive: `ls /mnt/data_backup/`
- Understand this is a one-way operation — the backup drive becomes the new live drive

---

## When to Use This
- Live drive SMART report shows rapidly increasing uncorrectable errors (SMART ID 187)
- Drive is making unusual sounds
- `/mnt/data_live` is throwing I/O errors: `dmesg | grep <LIVE_DRIVE_DEVICE>`
- Live drive fails to mount on boot

---

## Steps

### 1. Verify backup drive has usable recent data
```bash
ls -la /mnt/data_backup/
ls -la /mnt/data_backup/nextcloud_data/
ls -la /mnt/data_backup/immich_library/
cat <HOME>/backup_log.txt | tail -20
```
Confirm the last successful backup timestamp is acceptable. If the last backup is too old, assess whether to attempt a final rsync from the failing live drive first (only if it's still partially readable).

### 2. Stop all containers
```bash
cd <HOME>/nextcloud && docker compose down
cd <HOME>/immich-app && docker compose down
```
Verify all containers are stopped:
```bash
docker ps
```
Output should be empty.

### 3. Unmount both drives
```bash
sudo umount /mnt/data_live
sudo umount /mnt/data_backup
```

### 4. Physically swap the drives
- Disconnect the **Live Drive** — label it as failed
- The **Backup Drive** becomes the new Live Drive
- Connect a **new blank drive** (if available) as the new Backup Drive

### 5. Identify new drive assignments
```bash
lsblk -o NAME,SIZE,FSTYPE,MOUNTPOINT,UUID
```
Note the UUID of the drive now in the Live slot (previously the backup drive). You can cross-reference against the UUID recorded in your private notes as `<BACKUP_DRIVE_UUID>`.

### 6. Mount the promoted drive as Live
```bash
sudo mount UUID=<BACKUP_DRIVE_UUID> /mnt/data_live
```
Verify:
```bash
ls /mnt/data_live/
```
You should see `nextcloud_data`, `immich_library`, `backups` etc.

### 7. Update fstab
```bash
sudo nano /etc/fstab
```
Update the `/mnt/data_live` line to use `<BACKUP_DRIVE_UUID>`.

If you have a new blank drive for the backup slot, format it and update `/mnt/data_backup`:
```bash
# Identify the new blank drive device
lsblk

# Format it
sudo mkfs.ext4 /dev/<NEW_DRIVE_DEVICE>

# Get its UUID
sudo blkid /dev/<NEW_DRIVE_DEVICE>

# Update fstab /mnt/data_backup line with new UUID
sudo nano /etc/fstab
```

### 8. Mount the new backup drive
```bash
sudo mount /mnt/data_backup
```

### 9. Fix permissions on promoted drive
```bash
sudo chmod 775 /mnt/data_live /mnt/data_backup
```

### 10. Start all containers
```bash
cd <HOME>/nextcloud && docker compose up -d
cd <HOME>/immich-app && docker compose up -d
```
Wait 30 seconds, then verify:
```bash
docker ps
```
All containers should show `Up` or `healthy`.

### 11. Run a manual backup immediately
```bash
sudo bash <HOME>/daily_backup.sh
```
This seeds the new backup drive from the newly promoted live drive.

---

## Verification
- Nextcloud loads at `http://<SERVER_TAILSCALE_IP>:8080`
- Immich loads at `http://<SERVER_TAILSCALE_IP>:2283`
- Files are visible and accessible in both applications
- Backup log shows successful run: `tail -20 <HOME>/backup_log.txt`

---

## Rollback
This operation is not easily reversible once containers are running against the promoted drive. If the promoted drive also fails:
1. Restore from off-site backup (Backblaze B2 — if configured, see `03-backup-and-recovery.md`)
2. Attempt data recovery from the original failed live drive using a separate machine

---

## Post-Failover Actions
1. Order a replacement drive immediately
2. Once replacement arrives, format as new backup drive and update fstab
3. Run a manual backup to seed it
4. Update `smartd.conf` to monitor the new device path
5. Record the new drive UUIDs in your private notes

---

## Drive Health Monitoring Reference

Check live drive SMART status:
```bash
sudo smartctl -a <LIVE_DRIVE_DEVICE>
```

Key attributes to watch:
| SMART ID | Name | Concern Threshold |
|---|---|---|
| 187 | Reported Uncorrectable Errors | Any increase is bad. High values indicate imminent failure. |
| 194 | Temperature | Above 50°C is critical |
| 197 | Current Pending Sector Count | Any value above 0 is concerning |
| 198 | Offline Uncorrectable | Any value above 0 is critical |

Run a short self-test:
```bash
sudo smartctl -t short <LIVE_DRIVE_DEVICE>
# Wait 2 minutes, then check results:
sudo smartctl -a <LIVE_DRIVE_DEVICE> | grep -A5 "Self-test"
```