#!/bin/bash
# ============================================
# shutdown-data-drives.sh
# Safely stops Immich + Nextcloud, checks for
# busy mounts, unmounts, and spins down the
# external HDDs. OpenClaw is not touched.
#
# Run:      sudo bash shutdown-data-drives.sh
# Dry-run:  DRY_RUN=1 sudo bash shutdown-data-drives.sh
#
# Changes from v1:
#   FR1 - docker compose down exit code inspected; real failures abort the drive path
#   FR2 - fuser busy-mount check before every umount; blocking PIDs logged by name
#   FR3 - spindown verified with hdparm -C; state logged; sdparm note if not standby
#   FR4 - each drive runs independently; set -e replaced with per-step error handling
#   FR5 - hdparm targets whole disk (/dev/sdX), not partition (/dev/sdX1)
#   FR6 - log file chowned back to invoking user after sudo run
#   FR7 - DRY_RUN=1 mode logs all actions without executing state-changing commands
# ============================================

set -uo pipefail
# NOTE: set -e intentionally removed. Each drive's shutdown path is handled
# independently — a failure on one must not abort the other (FR4).

# ─── Configuration ────────────────────────────────────────────────────────────
LOG_FILE="<HOME>/backup_log.txt"
LIVE_MOUNT="/mnt/data_live"
BACKUP_MOUNT="/mnt/data_backup"
IMMICH_DIR="<HOME>/immich-app"
NEXTCLOUD_DIR="<HOME>/nextcloud"
DRY_RUN="${DRY_RUN:-0}"

# ─── Helpers ──────────────────────────────────────────────────────────────────
log() {
    local msg="[$(date '+%Y-%m-%d %H:%M:%S')] $1"
    echo "$msg"
    echo "$msg" >> "$LOG_FILE"
}

# Runs a command for real, or logs it as a no-op in dry-run mode.
run_cmd() {
    if [ "$DRY_RUN" = "1" ]; then
        log "[DRY RUN] Would run: $*"
        return 0
    fi
    "$@"
}

# Resolves a partition (e.g. /dev/sdb1) to its parent whole disk (e.g. /dev/sdb).
# hdparm requires the whole disk, not a partition node (FR5).
get_whole_disk() {
    local part="$1"
    lsblk -no pkname "$part" 2>/dev/null | head -1
}

# ─── Per-drive shutdown ────────────────────────────────────────────────────────
# Each drive is shut down via this function independently (FR4).
# Returns 0 on full success, 1 if any step failed.
shutdown_drive() {
    local label="$1"        # Human label: "Live" or "Backup"
    local mount="$2"        # Mount point: /mnt/data_live or /mnt/data_backup
    local compose_dir="$3"  # Docker project dir associated with this drive

    local drive_ok=0

    log "── Starting shutdown of $label drive ($mount) ──"

    # Step A: Stop the associated Docker stack (FR1)
    if [ -d "$compose_dir" ]; then
        log "Stopping containers in $compose_dir..."
        if [ "$DRY_RUN" = "1" ]; then
            log "[DRY RUN] Would run: docker compose down (in $compose_dir)"
        else
            local compose_out compose_exit
            compose_out=$(cd "$compose_dir" && docker compose down 2>&1)
            compose_exit=$?
            if [ $compose_exit -ne 0 ]; then
                # Distinguish "nothing running" (acceptable) from real failures (abort).
                if echo "$compose_out" | grep -qi "no containers\|no such service\|no resource found"; then
                    log "No containers were running in $compose_dir — continuing."
                else
                    log "ERROR: docker compose down failed in $compose_dir (exit $compose_exit)."
                    log "Output: $compose_out"
                    log "Aborting $label drive shutdown — will NOT attempt unmount while containers may be active."
                    return 1
                fi
            else
                log "Containers in $compose_dir stopped cleanly."
            fi
        fi
    else
        log "WARNING: compose dir $compose_dir not found — skipping container stop."
    fi

    # Step B: Flush pending I/O to disk before unmounting
    log "Flushing I/O..."
    run_cmd sync
    [ "$DRY_RUN" != "1" ] && sleep 2

    # Step C: Check mount is actually present before trying to unmount
    if ! mountpoint -q "$mount" 2>/dev/null; then
        log "$mount is not mounted — nothing to unmount."
        log "── $label drive shutdown complete (was not mounted). ──"
        return 0
    fi

    # Step D: Check for active mount users before unmounting (FR2)
    local busy_procs
    busy_procs=$(fuser -m "$mount" 2>/dev/null || true)
    if [ -n "$busy_procs" ]; then
        local busy_names
        # shellcheck disable=SC2086
        busy_names=$(ps -p $busy_procs -o comm= 2>/dev/null | sort -u | tr '\n' ' ' || echo "unknown")
        log "ERROR: $mount is busy — held by PID(s) $busy_procs (${busy_names% })."
        log "Aborting unmount of $label drive. The other drive will still be attempted."
        return 1
    fi

    # Step E: Capture device before unmounting (findmnt returns nothing after umount)
    local partition
    partition=$(findmnt -n -o SOURCE "$mount" 2>/dev/null || echo "")

    # Step F: Unmount
    log "Unmounting $mount (device: ${partition:-unknown})..."
    run_cmd umount "$mount"
    if [ "$DRY_RUN" != "1" ] && mountpoint -q "$mount"; then
        log "ERROR: $mount is still mounted after umount — something unexpected held it."
        return 1
    fi
    log "$mount unmounted."

    # Step G: Spin down the drive (FR3, FR5)
    if [ -n "$partition" ]; then
        local whole_disk
        whole_disk=$(get_whole_disk "$partition")
        if [ -n "$whole_disk" ]; then
            local disk_dev="/dev/$whole_disk"
            log "Sending standby command to $disk_dev..."
            run_cmd hdparm -y "$disk_dev" 2>/dev/null \
                || log "WARNING: hdparm -y returned non-zero on $disk_dev (may be unsupported by this USB bridge)."

            # Step H: Verify spindown actually happened (FR3) — trust the state, not the exit code
            if [ "$DRY_RUN" != "1" ]; then
                sleep 2
                local drive_state
                drive_state=$(hdparm -C "$disk_dev" 2>/dev/null | grep -i "drive state" | xargs || echo "state unknown")
                if echo "$drive_state" | grep -qi "standby"; then
                    log "$disk_dev confirmed in standby ✅ ($drive_state)"
                else
                    log "WARNING: $disk_dev state after spindown: '$drive_state'. Drive may not have parked."
                    log "TIP: Install 'sdparm' (sudo apt install sdparm) for a more reliable SCSI-level fallback."
                    drive_ok=1
                fi
            else
                log "[DRY RUN] Would verify: hdparm -C $disk_dev"
            fi
        else
            log "WARNING: Could not resolve whole-disk device from $partition — skipping spindown."
            drive_ok=1
        fi
    else
        log "WARNING: No source device found for $mount before unmount — skipping spindown."
        drive_ok=1
    fi

    log "── $label drive shutdown complete. ──"
    return $drive_ok
}

# ─── Main ─────────────────────────────────────────────────────────────────────
if [ "$DRY_RUN" = "1" ]; then
    echo ""
    echo "════════════════════════════════════════════════"
    echo "  DRY RUN MODE — no changes will be made"
    echo "════════════════════════════════════════════════"
fi
echo ""
echo "════════════════════════════════════════════════"
echo "  SHUTTING DOWN DATA DRIVES"
echo "════════════════════════════════════════════════"
echo ""
log "Shutdown initiated (DRY_RUN=${DRY_RUN})."

live_result=0
backup_result=0

# Each drive runs independently — failure of one does not prevent the other (FR4)
shutdown_drive "Live"   "$LIVE_MOUNT"   "$IMMICH_DIR"    || live_result=1
shutdown_drive "Backup" "$BACKUP_MOUNT" "$NEXTCLOUD_DIR" || backup_result=1

# ─── Fix log ownership (sudo makes it root-owned) (FR6) ───────────────────────
REAL_USER="${SUDO_USER:-$(whoami)}"
chown "$REAL_USER" "$LOG_FILE" 2>/dev/null || true

# ─── Final status — live-queried, never assumed (FR4) ─────────────────────────
echo ""
echo "════════════════════════════════════════════════"
echo "  FINAL STATUS"
echo "════════════════════════════════════════════════"
for m in "$LIVE_MOUNT" "$BACKUP_MOUNT"; do
    if mountpoint -q "$m" 2>/dev/null; then
        echo "  $m : ❌ still mounted"
    else
        echo "  $m : ✅ unmounted"
    fi
done
echo "  OpenClaw        : untouched (always running)"
echo "════════════════════════════════════════════════"
echo ""

if [ $live_result -ne 0 ] || [ $backup_result -ne 0 ]; then
    log "Shutdown completed WITH ERRORS — review log above for details."
    exit 1
fi

log "Shutdown complete — all drives cleanly unmounted."
exit 0
