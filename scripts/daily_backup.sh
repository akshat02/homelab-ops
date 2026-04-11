#!/bin/bash
# Home Server Backup Script
# Runs as root via root crontab at 03:00 AM

LOG_FILE="/home/ashtic/backup_log.txt"
LIVE="/mnt/data_live"
BACKUP="/mnt/data_backup"

log_message() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" >> "$LOG_FILE"
}

log_message "========================================"
log_message "Starting Backup Process..."

# Load environment variables for Nextcloud DB
ENV_FILE="/home/ashtic/nextcloud/.env"
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
/usr/bin/docker exec -t immich_postgres pg_dumpall -c -U postgres | gzip > "$IMMICH_DUMP"
if [ ${PIPESTATUS[0]} -ne 0 ]; then
    log_message "ERROR: Immich DB dump failed. Aborting to protect backup integrity."
    exit 1
fi
log_message "Immich DB dump completed: $IMMICH_DUMP"

# 2. Nextcloud DB Dump
log_message "Starting Nextcloud DB dump..."
NC_DUMP="$LIVE/backups/nextcloud_db/nextcloud_db_$(date +%Y-%m-%d).sql"
/usr/bin/docker exec nextcloud-db-1 mysqldump -u nextcloud -p"${DB_PASSWORD}" nextcloud > "$NC_DUMP"
if [ $? -ne 0 ]; then
    log_message "ERROR: Nextcloud DB dump failed. Aborting to protect backup integrity."
    exit 1
fi
log_message "Nextcloud DB dump completed: $NC_DUMP"

# 3. Fix ownership so files are consistent
chown -R www-data:www-data "$LIVE/backups/"
log_message "Ownership corrected on backup files."

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
    echo "❌ Backup completed WITH ERRORS. Check ~/backup_log.txt for details."
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
echo "  Log       : ~/backup_log.txt"
echo "================================================"
echo ""