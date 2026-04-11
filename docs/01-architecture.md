# 01 — Architecture

Complete reference for the hardware, OS, network, and storage design of the home server.

---

## Hardware

| Component | Detail |
|---|---|
| **Device** | Repurposed laptop (2012 era) |
| **CPU** | Intel Core i3 (Ivy Bridge, 2 cores / 4 threads) |
| **RAM** | ~4 GB |
| **Internal SSD** | 500 GB — OS, Docker engine, Immich Postgres data |
| **Live HDD** | 500 GB USB 3.0 — Primary data storage |
| **Backup HDD** | 500 GB USB 3.0 — Nightly mirror |
| **USB Hub** | USB 3.0 Hub (both external HDDs connected here) |
| **Operation** | Headless, lid-closed (`HandleLidSwitch=ignore` in `/etc/systemd/logind.conf`) |

### Drive Health Notes
- **Live Drive (`<LIVE_DRIVE_DEVICE>`):** Moderate/high risk as of last audit — elevated uncorrectable errors (SMART ID 187), operating temperature 53-54°C. Monitor closely.
- **Backup Drive (`<BACKUP_DRIVE_DEVICE>`):** Near-new at time of audit. Low hours, no errors.
- Run `sudo smartctl -a <LIVE_DRIVE_DEVICE>` regularly to track SMART ID 187 trend.

---

## Operating System

| | |
|---|---|
| **OS** | Linux Mint 22.3 XFCE |
| **Primary user** | `<USER>` |
| **Required groups** | `sudo`, `docker`, `www-data` |
| **Swap** | ~4 GB swapfile (active — RAM is constrained) |

### OS Maintenance
Automated via `unattended-upgrades`:
- Security updates only (no dist-upgrades)
- `Remove-Unused-Dependencies = true`
- Auto-reboot enabled at 04:00 AM for kernel updates

---

## Network & Security (Zero-Trust Model)

### Remote Access
- **Tailscale** (WireGuard-based VPN) — all remote access goes through Tailscale
- No ports forwarded on the home router
- Server is accessible only via its Tailscale IP from authorised devices on the same Tailscale account

### Firewall (UFW)
- Default policy: **Deny all incoming**
- Exceptions: `tailscale0` interface + Port 22 (SSH)
- Services are bound to `0.0.0.0` but only reachable via Tailscale in practice

### SSH
- Enabled and configured
- Access from personal devices only (via Tailscale)

---

## Storage Architecture

### Filesystem Layout
```
<INTERNAL_SSD>  →  /                  (OS, Docker, Immich Postgres)
<LIVE_DRIVE>    →  /mnt/data_live     (Primary data)
<BACKUP_DRIVE>  →  /mnt/data_backup   (Backup mirror)
```

### `/mnt/data_live` Directory Structure
```
/mnt/data_live/
├── nextcloud_data/          # Nextcloud user files
├── immich_library/          # Immich photo/video library
│   └── YYYY/MM/filename     # Storage template: {{y}}/{{MM}}/{{filename}}
├── backups/
│   ├── immich_db/           # Immich Postgres dumps (7-day retention)
│   │   └── dump_YYYY-MM-DD.sql.gz
│   └── nextcloud_db/        # Nextcloud MariaDB dumps (7-day retention)
│       └── nextcloud_db_YYYY-MM-DD.sql
└── lost+found/
```

### `/mnt/data_backup` Directory Structure
Exact mirror of `/mnt/data_live` via nightly `rsync --delete`.

### Permissions
- All data directories owned by `www-data:www-data`, mode `770`
- `<USER>` is in the `www-data` group for direct access without sudo
- Mount points (`/mnt/data_live`, `/mnt/data_backup`) mode `775`

### fstab (Persistent Mounts)
```
UUID=<LIVE_DRIVE_UUID>    /mnt/data_live   ext4  defaults,nofail,noatime,x-systemd.device-timeout=5s  0  2
UUID=<BACKUP_DRIVE_UUID>  /mnt/data_backup ext4  defaults,nofail,noatime,x-systemd.device-timeout=5s  0  2
```

Key mount options explained:
- `nofail` — system boots even if USB drives are not detected
- `noatime` — reduces unnecessary write load on HDDs
- `x-systemd.device-timeout=5s` — prevents boot hanging while waiting for slow USB devices

To find current UUIDs: `lsblk -o NAME,SIZE,FSTYPE,MOUNTPOINT,UUID`

---

## Application Stack

### Docker
- Docker Engine (Community Edition)
- Docker Compose V2
- `<USER>` is in the `docker` group — no sudo needed for Docker commands

### Nextcloud Stack (`<HOME>/nextcloud/`)
| Container | Image | Purpose |
|---|---|---|
| `<NEXTCLOUD_APP_CONTAINER>` | `nextcloud:latest` | Web application |
| `<NEXTCLOUD_DB_CONTAINER>` | `mariadb:10.6` | Database |
| `<NEXTCLOUD_REDIS_CONTAINER>` | `redis:alpine` | Cache / session |

- App data: `/mnt/data_live/nextcloud_data`
- Config: `<HOME>/nextcloud/config/` (mounted into container at `/var/www/html/config`)
- DB data: `<HOME>/nextcloud/db/` (local volume on internal SSD)
- Credentials: `<HOME>/nextcloud/.env`
- **Important:** `<HOME>/nextcloud/config/config.php` is the authoritative config for a running Nextcloud instance. DB password changes must be reflected here, not just in `.env`.

### Immich Stack (`<HOME>/immich-app/`)
| Container | Image | Purpose |
|---|---|---|
| `<IMMICH_SERVER_CONTAINER>` | `ghcr.io/immich-app/immich-server` | API + web UI |
| `<IMMICH_ML_CONTAINER>` | `ghcr.io/immich-app/immich-machine-learning` | AI features |
| `<IMMICH_DB_CONTAINER>` | `ghcr.io/immich-app/postgres:14-vectorchord...` | Database |
| `<IMMICH_REDIS_CONTAINER>` | `valkey/valkey:9` | Cache |

- Library: `/mnt/data_live/immich_library`
- DB data: `<HOME>/immich-app/postgres/` (internal SSD for I/O performance)
- GPU: `/dev/dri` passed through for Intel QuickSync hardware transcoding
- Background job concurrency throttled to 1 in Admin UI (thermal management on constrained hardware)
- Credentials: `<HOME>/immich-app/.env`
- **Immich is excluded from auto-updates** — update manually due to breaking DB migration risk

---

## Design Decisions & Rationale

| Decision | Rationale |
|---|---|
| Zero-Trust / Tailscale over port forwarding | Eliminates attack surface entirely. No ports exposed to internet. |
| EXT4 for external drives | Journaling for crash resilience, full Linux permission support |
| `nofail` in fstab | Server must boot even if USB drives aren't ready yet |
| Immich Postgres on internal SSD | Database I/O is random read/write — SSD significantly faster than USB HDD |
| Immich excluded from auto-update | Heavy development phase, breaking DB migrations have occurred in the past |
| MariaDB 10.6 pinned | Avoid accidental major version upgrades which require manual migration steps |
| Headless lid-closed operation | Server runs without display, lid closed to save space |
| `www-data` ownership on data dirs | Required by Nextcloud internals. Primary user added to `www-data` group as bridge. |
| Root crontab for backup script | Script requires docker exec, chown, and broad filesystem access — root is appropriate |
| Weekly Nextcloud image update (Sunday 02:00) | Scheduled one hour before daily backup so post-update state is immediately backed up |