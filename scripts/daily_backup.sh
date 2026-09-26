#!/bin/bash
# Home Server Backup Script
# Runs as root via root crontab at 03:00 AM

# --- Config ---
# Edit these variables to match your environment
SERVER_USER="your_username"
NEXTCLOUD_DB_CONTAINER="nextcloud-db-1"
IMMICH_DB_CONTAINER="immich_postgres"

# --- Derived paths (do not edit) ---
HOME_DIR="/home/${SERVER_USER}"
LOG_FILE="${HOME_DIR}/backup_log.txt"
LIVE="/mnt/data_live"
BACKUP="/mnt/data_backup"

log_message() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" >> "$LOG_FILE"
}

# --- Pre-flight checks ---
# 1. Is the live drive actually mounted?
if ! mountpoint -q "$LIVE"; then
    log_message "FATAL: Live drive ($LIVE) is not mounted. Aborting."
    echo ""
    echo "================================================"
    echo "❌  BACKUP ABORTED — Live drive not mounted"
    echo "================================================"
    exit 1
fi

# 2. Is the backup drive actually mounted?
if ! mountpoint -q "$BACKUP"; then
    log_message "FATAL: Backup drive ($BACKUP) is not mounted. Aborting."
    echo ""
    echo "================================================"
    echo "❌  BACKUP ABORTED — Backup drive not mounted"
    echo "================================================"
    exit 1
fi

# 3. Does the live drive have actual data? (prevent rsync --delete disasters)
LIVE_USED=$(df --output=pcent "$LIVE" 2>/dev/null | tail -1 | tr -d ' %')
if [ -z "$LIVE_USED" ] || [ "$LIVE_USED" -lt 1 ]; then
    log_message "FATAL: Live drive shows <1% usage. Aborting to protect backup."
    echo ""
    echo "================================================"
    echo "❌  BACKUP ABORTED — Live drive appears empty"
    echo "================================================"
    exit 1
fi

log_message "========================================"
log_message "Starting Backup Process..."

# Load environment variables for Nextcloud DB
ENV_FILE="${HOME_DIR}/nextcloud/.env"
if [ -f "$ENV_FILE" ]; then
    export $(grep -v '^#' "$ENV_FILE" | xargs)
    log_message "Environment variables loaded."
else
    log_message "ERROR: .env file not found at $ENV_FILE. Aborting."
    exit 1
fi

# 0. Create backup directories
mkdir -p "$LIVE/backups/immich_db"
mkdir -p "$LIVE/backups/nextcloud_db"

# 1. Immich DB Dump
log_message "Starting Immich DB dump..."
IMMICH_DUMP="$LIVE/backups/immich_db/dump_$(date +%Y-%m-%d).sql.gz"
/usr/bin/docker exec -t "$IMMICH_DB_CONTAINER" pg_dumpall -c -U postgres | gzip > "$IMMICH_DUMP"
if [ ${PIPESTATUS[0]} -ne 0 ]; then
    log_message "ERROR: Immich DB dump failed. Aborting to protect backup integrity."
    exit 1
fi
log_message "Immich DB dump completed: $IMMICH_DUMP"

# 2. Nextcloud DB Dump
log_message "Starting Nextcloud DB dump..."
NC_DUMP="$LIVE/backups/nextcloud_db/nextcloud_db_$(date +%Y-%m-%d).sql"
/usr/bin/docker exec "$NEXTCLOUD_DB_CONTAINER" mysqldump -u "${DB_USER}" -p"${DB_PASSWORD}" "${DB_NAME}" > "$NC_DUMP"
if [ $? -ne 0 ]; then
    log_message "ERROR: Nextcloud DB dump failed. Aborting to protect backup integrity."
    exit 1
fi
log_message "Nextcloud DB dump completed: $NC_DUMP"

# 3. Fix ownership so files are consistent
chown -R www-data:www-data "$LIVE/backups/"
log_message "Ownership corrected on backup files."

# 3b. OpenClaw config & memory backup (runs before mirror so it propagates to backup drive)
OPENCLAW_DIR="/home/${SERVER_USER}/openclaw/agents/user/data"
mkdir -p "$LIVE/backups/openclaw"
log_message "Starting OpenClaw config backup..."
/usr/bin/rsync -av --delete "$OPENCLAW_DIR/" "$LIVE/backups/openclaw/" >> "$LOG_FILE" 2>&1
if [ $? -ne 0 ]; then
    log_message "WARNING: OpenClaw backup had errors (non-fatal)."
else
    log_message "OpenClaw config backup completed."
fi

# 4. Cleanup old Immich DB dumps (keep 7 days)
find "$LIVE/backups/immich_db/" -mtime +7 -type f -delete
log_message "Old Immich DB dumps cleaned up."

# 5. Cleanup old Nextcloud DB dumps (keep 7 days)
find "$LIVE/backups/nextcloud_db/" -mtime +7 -type f -delete
log_message "Old Nextcloud DB dumps cleaned up."

# 6. rsync mirror Live → Backup
log_message "Starting rsync mirror..."
/usr/bin/rsync -av --delete "$LIVE/" "$BACKUP/" >> "$LOG_FILE" 2>&1
RSYNC_EXIT=$?
if [ $RSYNC_EXIT -ne 0 ]; then
    log_message "ERROR: rsync mirror encountered errors. Check output above."
    echo ""
    echo "❌ Backup completed WITH ERRORS. Check ${LOG_FILE} for details."
    echo ""
else
    log_message "rsync mirror completed successfully."
fi

log_message "Backup process finished."
log_message "========================================"

# --- Terminal summary (for manual runs) ---
LAST_IMMICH=$(ls -t "$LIVE/backups/immich_db/"*.sql.gz 2>/dev/null | head -1)
LAST_NC=$(ls -t "$LIVE/backups/nextcloud_db/"*.sql 2>/dev/null | head -1)
IMMICH_SIZE=$(du -sh "$LAST_IMMICH" 2>/dev/null | cut -f1)
NC_SIZE=$(du -sh "$LAST_NC" 2>/dev/null | cut -f1)

echo ""
echo "================================================"
echo "✅  BACKUP COMPLETED SUCCESSFULLY"
echo "================================================"
echo "  Immich DB : $IMMICH_SIZE  →  $(basename $LAST_IMMICH)"
echo "  Nextcloud : $NC_SIZE  →  $(basename $LAST_NC)"
echo "  Mirror    : Live → Backup drive synced"
echo "  Log       : ${LOG_FILE}"
echo "================================================"
echo ""