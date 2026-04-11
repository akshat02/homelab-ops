# 03 — Backup and Recovery

Complete reference for the backup strategy, schedule, verification, and recovery procedures.

---

## Backup Strategy Overview

This setup follows a **3-2-1 backup principle** (partially implemented):

| Tier | Type | Tool | Status |
|---|---|---|---|
| 1 | Local mirror (Live → Backup drive) | `rsync` | ✅ Active |
| 2 | DB snapshots with retention | `pg_dumpall` / `mysqldump` | ✅ Active |
| 3 | Off-site encrypted backup | `rclone` + Backblaze B2 (Tentative) | 🔲 Planned |

> **Educational note:** The 3-2-1 rule means: 3 copies of data, on 2 different media types, with 1 copy off-site. The local rsync mirror satisfies redundancy against drive failure, but not against physical loss (fire, theft) or ransomware. Off-site backup closes that gap.

---

## What Gets Backed Up

| Data | Method | Destination | Retention |
|---|---|---|---|
| Immich Postgres DB | `pg_dumpall` → gzip | `/mnt/data_live/backups/immich_db/` | 7 days |
| Nextcloud MariaDB | `mysqldump` | `/mnt/data_live/backups/nextcloud_db/` | 7 days |
| Immich library (files) | `rsync` mirror | `/mnt/data_backup/immich_library/` | Mirror (latest) |
| Nextcloud data (files) | `rsync` mirror | `/mnt/data_backup/nextcloud_data/` | Mirror (latest) |
| DB dump staging folder | `rsync` mirror | `/mnt/data_backup/backups/` | Mirror (latest) |

---

## Backup Schedule

| Time | Task |
|---|---|
| Daily 03:00 AM | Full backup — DB dumps + rsync mirror (`daily_backup.sh`) |
| Sunday 02:00 AM | Nextcloud image update (one hour before backup, so post-update state is immediately captured) |

Managed via root crontab:
```
00 03 * * * /bin/bash <HOME>/daily_backup.sh
```

---

## Backup Script

**Location:** `<HOME>/daily_backup.sh`  
**Runs as:** root  
**Log:** `<HOME>/backup_log.txt`

### Script Execution Order

1. Load Nextcloud `.env` for DB credentials
2. Create backup staging directories if missing
3. Dump Immich Postgres DB → compressed `.sql.gz` (abort on failure)
4. Dump Nextcloud MariaDB → `.sql` (abort on failure)
5. Fix ownership on staging files (`www-data:www-data`)
6. Clean up dumps older than 7 days
7. `rsync` mirror Live HDD → Backup HDD

### Key Design Decisions

- **Abort on DB dump failure** — if either DB dump fails, the script exits before rsync runs. This prevents a bad backup from overwriting a good one on the backup drive.
- **DB dumps land on Live drive first** — dumps are staged on the Live drive and then replicated to the Backup drive via rsync in the same run. This means both drives always have the latest dumps.
- **`PIPESTATUS[0]` for Immich dump** — the Immich dump uses a pipe (`docker exec ... | gzip`), so a plain `$?` would only catch the gzip exit code. `PIPESTATUS[0]` correctly captures the `docker exec` exit code.
- **Script config block** — container names and the server username are defined as variables at the top of the script. Credentials are never hardcoded — they are sourced from the Nextcloud `.env` at runtime.

---

## Verifying Backups

### Check last backup run
```bash
cat <HOME>/backup_log.txt | tail -30
```

### Verify DB dump files exist and are recent
```bash
ls -lh /mnt/data_live/backups/immich_db/
ls -lh /mnt/data_live/backups/nextcloud_db/
```

### Verify backup drive mirror is current
```bash
ls -la /mnt/data_backup/
# Compare modification timestamps against /mnt/data_live/
```

### Run a manual backup
```bash
sudo bash <HOME>/daily_backup.sh
```

### Test DB dump integrity (Immich)
```bash
# Decompress and check the dump is valid SQL
gunzip -c /mnt/data_live/backups/immich_db/dump_YYYY-MM-DD.sql.gz | head -20
```

### Test DB dump integrity (Nextcloud)
```bash
head -20 /mnt/data_live/backups/nextcloud_db/nextcloud_db_YYYY-MM-DD.sql
```
A valid dump begins with SQL comments and `CREATE` / `INSERT` statements. An empty file or an error message indicates a failed dump.

---

## Recovery Procedures

### Scenario 1 — Restore Immich database from dump

Use this if the Immich Postgres container is healthy but data is corrupted or accidentally deleted.

```bash
# 1. Stop Immich stack
cd <HOME>/immich-app && docker compose down

# 2. Identify the dump to restore
ls -lh /mnt/data_live/backups/immich_db/

# 3. Start only the database container
docker compose up -d database

# 4. Restore the dump
gunzip -c /mnt/data_live/backups/immich_db/dump_YYYY-MM-DD.sql.gz | \
  docker exec -i immich_postgres psql -U postgres

# 5. Start the full stack
docker compose up -d

# 6. Verify Immich loads correctly
# Visit http://<SERVER_TAILSCALE_IP>:2283
```

---

### Scenario 2 — Restore Nextcloud database from dump

```bash
# 1. Enable Nextcloud maintenance mode
docker exec -u www-data <NEXTCLOUD_APP_CONTAINER> php occ maintenance:mode --on

# 2. Stop the stack
cd <HOME>/nextcloud && docker compose down

# 3. Start only the DB container
docker compose up -d db

# 4. Restore the dump
docker exec -i <NEXTCLOUD_DB_CONTAINER> mysql \
  -u root -p"${DB_ROOT_PASSWORD}" <DB_NAME> \
  < /mnt/data_live/backups/nextcloud_db/nextcloud_db_YYYY-MM-DD.sql

# 5. Start the full stack
docker compose up -d

# 6. Disable maintenance mode
docker exec -u www-data <NEXTCLOUD_APP_CONTAINER> php occ maintenance:mode --off

# 7. Verify Nextcloud loads correctly
# Visit http://<SERVER_TAILSCALE_IP>:8080
```

---

### Scenario 3 — Live drive failure (promote backup drive)

See `docs/04-runbooks/RB-01-failover-to-backup-drive.md` for the full step-by-step procedure.

**Summary:**
1. Stop all containers
2. Unmount both drives
3. Physically swap: backup drive → Live slot, new drive → Backup slot
4. Update `/etc/fstab` with new UUIDs
5. Start all containers
6. Run a manual backup immediately to seed the new backup drive

---

### Scenario 4 — Full server reinstall

See `docs/04-runbooks/RB-05-full-reinstall.md`.

---

## Off-Site Backup (Planned)

Off-site backup via Rclone + Backblaze B2 is planned but not yet implemented. When configured, it will encrypt and sync the local backup drive contents to a remote bucket on a nightly or weekly schedule.

Candidate setup:
- **Tool:** `rclone` with `crypt` remote layered over a B2 remote
- **Source:** `/mnt/data_backup/` (already-mirrored data)
- **Encryption:** Client-side via rclone crypt (Backblaze sees only encrypted blobs)
- **Schedule:** Weekly, after the nightly rsync completes

> **Educational note:** Rclone's `crypt` remote works by wrapping another remote — you configure a B2 remote first, then a crypt remote on top of it. All encryption and decryption happens locally before data leaves the machine. Backblaze has no access to your keys or plaintext data.

See `docs/05-maintenance.md` for implementation notes when this is set up.

---

## Backup Failure Response

If the backup log shows errors:

| Error | Likely Cause | Action |
|---|---|---|
| `.env file not found` | Script config `SERVER_USER` incorrect, or `.env` deleted | Check path, verify config block in script |
| `Immich DB dump failed` | `immich_postgres` container not running | `docker ps`, restart Immich stack |
| `Nextcloud DB dump failed` | `nextcloud-db-1` container not running, or wrong credentials | `docker ps`, check `.env` DB_PASSWORD |
| `rsync mirror encountered errors` | Backup drive not mounted or I/O errors | Check `dmesg`, verify `/mnt/data_backup` is mounted |
| Empty dump file | DB dump ran but produced no output | Check container logs, verify DB is healthy |
