# RB-01 — Failover to Backup Drive

## Purpose
Use this runbook when the Live Drive (`/dev/sd`, `/mnt/data_live`) has failed or is showing critical SMART errors and you need to promote the Backup Drive to become the new Live Drive.

---

## Prerequisites
- You have SSH access to the server (via Tailscale)
- The Backup Drive (`/dev/sd`, `/mnt/data_backup`) is mounted and accessible
- You have verified the backup drive contains recent data: `ls /mnt/data_backup/`
- You understand this is a one-way operation — the backup drive becomes the live drive

---

## When to Use This
- Live drive SMART report shows rapidly increasing uncorrectable errors (SMART ID 187)
- Drive is making unusual sounds
- `/mnt/data_live` is throwing I/O errors in system logs (`dmesg | grep sdb`)
- Live drive fails to mount on boot

---

## Steps

### 1. Verify backup drive has usable recent data
```bash
ls -la /mnt/data_backup/
ls -la /mnt/data_backup/nextcloud_data/
ls -la /mnt/data_backup/immich_library/
cat ~/backup_log.txt | tail -20
```
Confirm the last successful backup timestamp is acceptable. If the last backup is too old, assess whether to attempt a final rsync from the failing live drive first (only if it's still partially readable).

### 2. Stop all containers
```bash
cd ~/nextcloud && docker compose down
cd ~/immich-app && docker compose down
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
- Disconnect the **Live Drive** (label it as failed)
- The **Backup Drive** will become the new Live Drive
- Connect the Backup Drive to the port/slot previously used by the Live Drive
- Connect a **new blank drive** (if available) as the new Backup Drive

### 5. Identify the new drive assignments
```bash
lsblk -o NAME,SIZE,FSTYPE,MOUNTPOINT,UUID
```
Note the UUIDs of the drives now connected. The old Backup Drive UUID is:
`4cc721d9-9d98-41e3-88b2-7a7077985df2`

### 6. Mount the promoted drive as Live
```bash
sudo mount UUID=4cc721d9-9d98-41e3-88b2-7a7077985df2 /mnt/data_live
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
Update the `/mnt/data_live` line to use the old backup drive's UUID:
```
UUID=4cc721d9-9d98-41e3-88b2-7a7077985df2  /mnt/data_live   ext4  defaults,nofail,noatime,x-systemd.device-timeout=5s  0  2
```
If you have a new blank drive for backup, format it and add its UUID for `/mnt/data_backup`:
```bash
# Format new backup drive (replace sdX with correct device)
sudo mkfs.ext4 /dev/sdX
# Get its UUID
sudo blkid /dev/sdX
# Add to fstab with new UUID
```

### 8. Mount the new backup drive (if available)
```bash
sudo mount /mnt/data_backup
```

### 9. Start all containers
```bash
cd ~/nextcloud && docker compose up -d
cd ~/immich-app && docker compose up -d
```
Wait 30 seconds, then verify:
```bash
docker ps
```
All containers should show `Up` or `healthy`.

### 10. Run a manual backup immediately
```bash
sudo bash ~/daily_backup.sh
```
This creates a fresh backup from the newly promoted live drive onto the new backup drive.

---

## Verification
- Nextcloud loads at `http://localhost:8080`
- Immich loads at `http://localhost:2283`
- Files are visible and accessible in both applications
- Backup log shows successful completion: `tail -20 ~/backup_log.txt`

---

## Rollback
This operation is not easily reversible once containers are pointed at the new drive. If the promoted backup drive also shows errors, your options are:
1. Restore from off-site backup (Backblaze B2 — if configured)
2. Attempt data recovery from the original failed live drive using a recovery machine

---

## Post-Failover Actions
1. Order a replacement drive immediately
2. Once replacement arrives, format it as the new backup drive and add to fstab
3. Run a manual backup to seed the new backup drive
4. Update drive health monitoring in `smartd.conf` to watch the new device path
5. Document the new drive UUIDs in this runbook

---

## Drive Health Monitoring Reference
Check live drive SMART status at any time:
```bash
sudo smartctl -a /dev/sdb
```
Key attributes to watch:
| SMART ID | Name | Concern Threshold |
|---|---|---|
| 187 | Reported Uncorrectable Errors | Any increase is bad. >50 is high risk. |
| 194 | Temperature | Above 50°C is critical for this drive |
| 197 | Current Pending Sector Count | Any value above 0 is concerning |
| 198 | Offline Uncorrectable | Any value above 0 is critical |

Run a short SMART test:
```bash
sudo smartctl -t short /dev/sdb
# Wait 2 minutes, then:
sudo smartctl -a /dev/sdb | grep -A5 "Self-test"
```
