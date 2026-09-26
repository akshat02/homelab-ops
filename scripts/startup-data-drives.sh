#!/bin/bash
# ============================================
# startup-data-drives.sh
# Mounts external HDDs and starts Immich +
# Nextcloud. OpenClaw is not touched.
#
# Run:      sudo bash startup-data-drives.sh
# Dry-run:  DRY_RUN=1 sudo bash startup-data-drives.sh
#
# Changes from v1:
#   FR1 - ABORT if any drive fails to mount; containers never start on unmounted dirs
#   FR2 - Dead "wake" block removed; mount itself wakes drives from standby
#   FR3 - Container names discovered dynamically from compose projects (not hardcoded)
#   FR4 - Immich healthcheck polling (up to 30s); Nextcloud fixed-sleep fallback
#   FR5 - Log file chowned back to invoking user after sudo run
#   FR6 - DRY_RUN=1 mode logs all actions without executing state-changing commands
# ============================================

set -uo pipefail

# ─── Configuration ────────────────────────────────────────────────────────────
LOG_FILE="<HOME>/backup_log.txt"
LIVE_MOUNT="/mnt/data_live"
BACKUP_MOUNT="/mnt/data_backup"
IMMICH_DIR="<HOME>/immich-app"
NEXTCLOUD_DIR="<HOME>/nextcloud"
DRY_RUN="${DRY_RUN:-0}"
HEALTH_POLL_TIMEOUT=30  # seconds to wait for healthcheck-enabled containers

# ─── Helpers ──────────────────────────────────────────────────────────────────
log() {
    local msg="[$(date '+%Y-%m-%d %H:%M:%S')] $1"
    echo "$msg"
    echo "$msg" >> "$LOG_FILE"
}

run_cmd() {
    if [ "$DRY_RUN" = "1" ]; then
        log "[DRY RUN] Would run: $*"
        return 0
    fi
    "$@"
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
echo "  STARTING UP DATA DRIVES"
echo "════════════════════════════════════════════════"
echo ""
log "Startup initiated (DRY_RUN=${DRY_RUN})."

# ─── Step 1: Mount drives ─────────────────────────────────────────────────────
# NOTE: mount itself wakes drives from standby — no explicit hdparm wake needed.
for mount in "$LIVE_MOUNT" "$BACKUP_MOUNT"; do
    if mountpoint -q "$mount" 2>/dev/null; then
        log "$mount is already mounted — skipping."
    else
        log "Mounting $mount..."
        run_cmd mount "$mount"
    fi
done

# ─── Step 2: Verify mounts — ABORT before starting any container ──────────────
# If a drive fails to mount, Docker will auto-create the mount point as a plain
# directory on the internal SSD and begin writing data there. This check prevents
# that from happening (FR1 — the most critical safety fix).
log "Verifying mounts..."
mount_ok=1
for m in "$LIVE_MOUNT" "$BACKUP_MOUNT"; do
    if [ "$DRY_RUN" = "1" ]; then
        log "[DRY RUN] Would verify: mountpoint -q $m"
    elif mountpoint -q "$m"; then
        log "$m ✅ mounted"
    else
        log "ERROR: $m failed to mount."
        mount_ok=0
    fi
done

if [ "$mount_ok" = "0" ]; then
    log "One or more drives failed to mount. Aborting — no containers will be started."
    log "This prevents Docker from creating data directories on the internal SSD."
    exit 1
fi

# ─── Step 3: Start Immich ─────────────────────────────────────────────────────
log "Starting Immich..."
if [ "$DRY_RUN" = "1" ]; then
    log "[DRY RUN] Would run: docker compose up -d (in $IMMICH_DIR)"
else
    cd "$IMMICH_DIR"
    docker compose up -d 2>&1 || log "WARNING: docker compose up returned non-zero for Immich — check logs."
fi

# ─── Step 4: Start Nextcloud ──────────────────────────────────────────────────
log "Starting Nextcloud..."
if [ "$DRY_RUN" = "1" ]; then
    log "[DRY RUN] Would run: docker compose up -d (in $NEXTCLOUD_DIR)"
else
    cd "$NEXTCLOUD_DIR"
    docker compose up -d 2>&1 || log "WARNING: docker compose up returned non-zero for Nextcloud — check logs."
fi

# ─── Step 5: Health checks ────────────────────────────────────────────────────
echo ""
log "Running container health checks..."

# Discover actual container names from each compose project (FR3 — no hardcoding)
get_compose_containers() {
    local dir="$1"
    cd "$dir" 2>/dev/null || { echo ""; return; }
    docker compose ps --format '{{.Name}}' 2>/dev/null || true
}

# Poll a container's healthcheck until healthy or timeout (FR4)
poll_health() {
    local container="$1"
    local timeout="$2"
    local elapsed=0
    while [ "$elapsed" -lt "$timeout" ]; do
        local state
        state=$(docker inspect --format '{{.State.Health.Status}}' "$container" 2>/dev/null || echo "")
        case "$state" in
            healthy)   return 0 ;;
            unhealthy) return 1 ;;
        esac
        sleep 2
        elapsed=$((elapsed + 2))
    done
    return 1
}

if [ "$DRY_RUN" = "1" ]; then
    log "[DRY RUN] Would discover containers from $IMMICH_DIR and $NEXTCLOUD_DIR and run health checks."
else
    echo "  Immich containers:"
    for container in $(get_compose_containers "$IMMICH_DIR"); do
        has_health=$(docker inspect --format '{{if .State.Health}}yes{{else}}no{{end}}' "$container" 2>/dev/null || echo "no")
        if [ "$has_health" = "yes" ]; then
            # Container has a healthcheck — poll until healthy or timeout (FR4)
            echo -n "  $container : waiting for healthy"
            if poll_health "$container" "$HEALTH_POLL_TIMEOUT"; then
                echo " ✅ healthy"
            else
                echo " ❌ unhealthy or timed out after ${HEALTH_POLL_TIMEOUT}s"
            fi
        else
            # No healthcheck — fall back to simple presence check
            STATUS=$(docker ps --filter "name=^${container}$" --format "{{.Status}}" 2>/dev/null)
            if [ -n "$STATUS" ]; then
                echo "  $container : $STATUS ✅"
            else
                echo "  $container : NOT RUNNING ❌"
            fi
        fi
    done

    echo "  Nextcloud containers:"
    # Nextcloud has no healthchecks defined — fixed sleep then presence check (FR4 fallback)
    sleep 5
    for container in $(get_compose_containers "$NEXTCLOUD_DIR"); do
        STATUS=$(docker ps --filter "name=^${container}$" --format "{{.Status}}" 2>/dev/null)
        if [ -n "$STATUS" ]; then
            echo "  $container : $STATUS ✅"
        else
            echo "  $container : NOT RUNNING ❌"
        fi
    done
fi

# ─── Fix log ownership (sudo makes it root-owned) (FR5) ───────────────────────
REAL_USER="${SUDO_USER:-$(whoami)}"
chown "$REAL_USER" "$LOG_FILE" 2>/dev/null || true

# ─── Final status — live-queried ──────────────────────────────────────────────
echo ""
echo "════════════════════════════════════════════════"
echo "  FINAL STATUS"
echo "════════════════════════════════════════════════"
for m in "$LIVE_MOUNT" "$BACKUP_MOUNT"; do
    if [ "$DRY_RUN" = "1" ]; then
        echo "  $m : [DRY RUN — not checked]"
    elif mountpoint -q "$m" 2>/dev/null; then
        echo "  $m : ✅ mounted"
    else
        echo "  $m : ❌ NOT mounted"
    fi
done
echo "  OpenClaw        : untouched (always running)"
echo "════════════════════════════════════════════════"
echo ""
log "Startup complete."
exit 0
