# RB-03 — Drive Replacement

## Purpose
Use this runbook when replacing a failing or failed external HDD — either the Live Drive or the Backup Drive. This covers both a planned replacement (drive showing SMART warnings) and an emergency replacement (drive already failed).

For the emergency case where the Live Drive has failed and you need to immediately promote the Backup Drive, see `RB-01-failover-to-backup-drive.md` first, then return here to set up the new replacement as the Backup Drive.

---

## Prerequisites
- SSH access to the server (via Tailscale)
- Replacement drive available (500 GB+, USB 3.0 recommended)
- Recent successful backup confirmed: `tail -20 <HOME>/backup_log.txt`

---

## When to Use This

- Live Drive SMART report shows increasing uncorrectable errors (SMART ID 187 > 0 and rising)
- Drive temperature consistently above 50°C
- Drive is making unusual sounds (clicking, grinding)
- `dmesg` shows I/O errors for the drive device
- Drive fails to mount on boot despite correct fstab entry

Check current drive health:
```bash
sudo smartctl -a <LIVE_DRIVE_DEVICE>
```

Key SMART attributes to watch:

| SMART ID | Name | Action Threshold |
|---|---|---|
| 187 | Reported Uncorrectable Errors | Any increase is bad. Non-zero = plan replacement now. |
| 194 | Temperature | Above 50°C is critical |
| 197 | Current Pending Sector Count | Any value above 0 is concerning |
| 198 | Offline Uncorrectable | Any value above 0 is critical |

---

## Scenario A — Replacing the Backup Drive (lower urgency)

The backup drive is near-new and low risk, but if it needs replacement this is the simpler case — no data migration needed since it is a mirror.

### Steps

#### 1. Stop all containers
```bash
cd <HOME>/nextcloud && docker compose down
cd <HOME>/immich-app && docker compose down
docker ps  # should be empty
```

#### 2. Unmount the backup drive
```bash
sudo umount /mnt/data_backup
```

#### 3. Physically swap the drive
Disconnect the old backup drive. Connect the new replacement drive.

#### 4. Identify the new drive
```bash
lsblk -o NAME,SIZE,FSTYPE,MOUNTPOINT,UUID
```
The new drive will appear without a filesystem or UUID (unformatted).

#### 5. Format the new drive
```bash
sudo mkfs.ext4 /dev/<NEW_DRIVE_DEVICE>
```
> This will take a few minutes and permanently erases any existing data on the drive.

#### 6. Get the new drive's UUID
```bash
sudo blkid /dev/<NEW_DRIVE_DEVICE>
```
Note the UUID value.

#### 7. Update fstab
```bash
sudo nano /etc/fstab
```
Replace the old `<BACKUP_DRIVE_UUID>` on the `/mnt/data_backup` line with the new UUID. Save and close.

#### 8. Mount the new drive
```bash
sudo mount /mnt/data_backup
sudo chmod 775 /mnt/data_backup
```

Verify:
```bash
ls /mnt/data_backup/  # should be empty — this is expected for a new drive
```

#### 9. Start all containers
```bash
cd <HOME>/nextcloud && docker compose up -d
cd <HOME>/immich-app && docker compose up -d
docker ps  # verify all containers healthy
```

#### 10. Run a manual backup to seed the new drive
```bash
sudo bash <HOME>/daily_backup.sh
```
This triggers a full rsync from the Live Drive to the new Backup Drive. Depending on data volume, this may take a while.

#### 11. Update smartd monitoring
Edit `/etc/smartd.conf` to monitor the new drive device if the device path has changed:
```bash
sudo nano /etc/smartd.conf
sudo systemctl restart smartd
```

#### 12. Record the new UUID
Store the new `<BACKUP_DRIVE_UUID>` in your private notes for reference during future recovery operations.

---

## Scenario B — Planned Replacement of the Live Drive

Use this when the Live Drive is degrading but still readable. Performs a controlled migration rather than an emergency failover.

### Steps

#### 1. Run a manual backup first
Ensure the backup drive has the freshest possible copy of all data:
```bash
sudo bash <HOME>/daily_backup.sh
tail -20 <HOME>/backup_log.txt  # confirm success
```

#### 2. Stop all containers
```bash
cd <HOME>/nextcloud && docker compose down
cd <HOME>/immich-app && docker compose down
docker ps  # should be empty
```

#### 3. Unmount both drives
```bash
sudo umount /mnt/data_live
sudo umount /mnt/data_backup
```

#### 4. Physically swap the drives
- Disconnect the **failing Live Drive** — label it as failed/retired
- Move the **Backup Drive** to the Live slot
- Connect the **new replacement drive** in the Backup slot

#### 5. Identify drive assignments
```bash
lsblk -o NAME,SIZE,FSTYPE,MOUNTPOINT,UUID
```
- The promoted Backup Drive will have its existing UUID (cross-reference your private notes for `<BACKUP_DRIVE_UUID>`)
- The new replacement drive will appear without a filesystem

#### 6. Mount the promoted drive as Live
```bash
sudo mount UUID=<BACKUP_DRIVE_UUID> /mnt/data_live
ls /mnt/data_live/  # verify: nextcloud_data, immich_library, backups etc. should be present
```

#### 7. Format the new replacement drive as Backup
```bash
sudo mkfs.ext4 /dev/<NEW_DRIVE_DEVICE>
sudo blkid /dev/<NEW_DRIVE_DEVICE>  # note the UUID
sudo mount /dev/<NEW_DRIVE_DEVICE> /mnt/data_backup
```

#### 8. Update fstab
```bash
sudo nano /etc/fstab
```
- Update `/mnt/data_live` line: replace old Live UUID with the promoted drive's UUID (`<BACKUP_DRIVE_UUID>`)
- Update `/mnt/data_backup` line: replace old Backup UUID with the new replacement drive's UUID

#### 9. Fix permissions
```bash
sudo chmod 775 /mnt/data_live /mnt/data_backup
```

#### 10. Start all containers
```bash
cd <HOME>/nextcloud && docker compose up -d
cd <HOME>/immich-app && docker compose up -d
docker ps  # verify all containers healthy
```

Verify services:
- Nextcloud: `http://<SERVER_TAILSCALE_IP>:8080`
- Immich: `http://<SERVER_TAILSCALE_IP>:2283`

#### 11. Run a manual backup to seed the new backup drive
```bash
sudo bash <HOME>/daily_backup.sh
```

#### 12. Update smartd and private notes
```bash
sudo nano /etc/smartd.conf  # update device path for new Live drive
sudo systemctl restart smartd
```
Record both new UUIDs in your private notes.

---

## Post-Replacement Checklist

- [ ] fstab updated with new UUID(s)
- [ ] Both drives mount cleanly on reboot: `sudo reboot` then verify `df -h`
- [ ] All containers running: `docker ps`
- [ ] Manual backup ran successfully: `tail -20 <HOME>/backup_log.txt`
- [ ] smartd updated to monitor new device path
- [ ] New UUIDs recorded in private notes
- [ ] Old failing drive physically labelled and set aside (do not reuse without a full wipe and test)

---

## Useful Commands Reference

```bash
# List all drives with UUIDs
lsblk -o NAME,SIZE,FSTYPE,MOUNTPOINT,UUID

# Full SMART report for a drive
sudo smartctl -a /dev/<DEVICE>

# Run a short SMART self-test
sudo smartctl -t short /dev/<DEVICE>
# Wait 2 minutes, then check:
sudo smartctl -a /dev/<DEVICE> | grep -A5 "Self-test"

# Check kernel I/O errors for a device
dmesg | grep <DEVICE>

# Check current mount status
df -h
```
