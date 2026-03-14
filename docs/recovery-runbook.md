# 🛠 Storage Recovery Runbook

## Symptom: External HDDs missing from `df -h`
This usually occurs after an "unclean" shutdown (power loss or hard reboot), where the Linux kernel detects a "dirty bit" on the filesystem and refuses to mount it to prevent data corruption.

## Phase 1: Diagnostic Commands
1. **Verify Hardware Detection:**
   `lsblk -f` (The drive should appear here but without a MOUNTPOINT).
2. **Check System Logs:**
   `dmesg | tail -n 50` (Look for "Buffer I/O error" or "I/O error, dev sdb").

## Phase 2: Manual Recovery Procedure
1. **Identify the UUID:**
   Always use the UUID to avoid `/dev/sdb` vs `/dev/sdc` swapping.
   `lsblk -d -no UUID /dev/sdb1` (Replace with your drive label).

2. **Clean the Filesystem:**
   If the drive is Ext4: `sudo fsck -y /dev/disk/by-uuid/[YOUR_UUID]`
   If the drive is NTFS: `sudo ntfsfix /dev/disk/by-uuid/[YOUR_UUID]`

3. **Mount and Fix Permissions:**
   ```bash
   sudo mount -U [YOUR_UUID] /mnt/data_live
   sudo chown -R 33:33 /mnt/data_live/nextcloud_data
   sudo chmod -R 770 /mnt/data_live/nextcloud_data

4. **Restart the service:**
    ```bash
    docker restart nextcloud-app-1
