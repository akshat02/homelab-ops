# 01 — Architecture

Complete reference for the hardware, OS, network, and storage design of the home server.

---

## Hardware

| Component | Detail |
|---|---|
| **Device** | HP Pavilion g6 Notebook (2012) |
| **CPU** | Intel Core i3-3110M (Ivy Bridge, 2 cores / 4 threads) |
| **RAM** | 3.9 GB |
| **Internal SSD** | 500 GB (`/dev/sd`) — OS, Docker engine, Immich Postgres data |
| **Live HDD** | 500 GB USB 3.0 (`/dev/sd`) — Primary data storage |
| **Backup HDD** | 500 GB USB 3.0 (`/dev/sd`) — Nightly mirror |
| **USB Hub** | Honeywell 3.0 Hub (both external HDDs connected here) |
| **Operation** | Headless, lid-closed (`HandleLidSwitch=ignore` in `/etc/systemd/logind.conf`) |

### Drive Health Notes
- **Live Drive (`/dev/sd`):** As of last audit — 923 power-on hours, 55 uncorrectable errors (SMART ID 187), operating temperature 53-54°C. **Moderate/high risk. Monitor closely.**
- **Backup Drive (`/dev/sd`):** Practically new at time of audit. 64 power-on hours, 0 errors.
- Live drive is formatted directly on the whole disk (no partition table). Backup drive has a single partition (`sd`). Functional difference is nil but worth noting.

---

## Operating System

| | |
|---|---|
| **OS** | Linux Mint 22.3 XFCE |
| **Swap** | 3.9 GB swapfile (active — RAM is constrained) |

### OS Maintenance
Automated via `unattended-upgrades`:
- Security updates only (no dist-upgrades)
- `Remove-Unused-Dependencies = true`
- Auto-reboot enabled at 04:00 AM for kernel updates

---

## Network & Security

### Remote Access
- **Tailscale** (WireGuard-based VPN) — all remote access goes through Tailscale
- No ports forwarded on the home router
- The server is accessible only via its Tailscale IP from authorised devices

### Firewall (UFW)
- Default policy: **Deny all incoming**
- Exceptions: `tailscale0` interface + Port 22 (SSH)
- Services are bound to `0.0.0.0` but are only reachable via Tailscale in practice

### SSH
- Enabled and configured
- Access from MacBook only (via Tailscale)

---

## Storage Architecture

### Filesystem Layout
```
/dev/sd  →  /                    (OS, Docker, Immich Postgres)
/dev/sd   →  /mnt/data_live       (Primary data)
/dev/sd  →  /mnt/data_backup     (Backup mirror)
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
- User is in the `www-data` group for direct access
- Mount points (`/mnt/data_live`, `/mnt/data_backup`) mode `775`

### fstab (Persistent Mounts)
```
UUID=a025dc6c-7630-4fa8-b56b-42104b1ae7f9  /mnt/data_live   ext4  defaults,nofail,noatime,x-systemd.device-timeout=5s  0  2
UUID=4cc721d9-9d98-41e3-88b2-7a7077985df2  /mnt/data_backup ext4  defaults,nofail,noatime,x-systemd.device-timeout=5s  0  2
```
- `nofail` — system boots even if USB drives are not present
- `noatime` — reduces write load on HDDs
- `x-systemd.device-timeout=5s` — doesn't hang boot waiting for slow USB

---

## Application Stack

### Docker
- Docker Engine 29.3.1 (API 1.54)
- Docker Compose V2
- User is in the `docker` group — no sudo needed for Docker commands

### Nextcloud Stack (`~/nextcloud/`)
| Container | Image | Purpose |
|---|---|---|
| `nextcloud-app-1` | `nextcloud:latest` | Web application |
| `nextcloud-db-1` | `mariadb:10.6` | Database |
| `nextcloud-redis-1` | `redis:alpine` | Cache / session |

- App data: `/mnt/data_live/nextcloud_data`
- Config: `~/nextcloud/config/` (mounted into container at `/var/www/html/config`)
- DB data: `~/nextcloud/db/` (local volume)
- Credentials: `~/nextcloud/.env`

### Immich Stack (`~/immich-app/`)
| Container | Image | Purpose |
|---|---|---|
| `immich_server` | `ghcr.io/immich-app/immich-server` | API + web UI |
| `immich_machine_learning` | `ghcr.io/immich-app/immich-machine-learning` | AI features |
| `immich_postgres` | `ghcr.io/immich-app/postgres:14-vectorchord...` | Database |
| `immich_redis` | `valkey/valkey:9` | Cache |

- Library: `/mnt/data_live/immich_library`
- DB data: `~/immich-app/postgres/` (internal SSD for performance)
- GPU: `/dev/dri` passed through for Intel QuickSync (i3-3110M)
- Background job concurrency throttled to 1 (thermal management)
- Credentials: `~/immich-app/.env`
- **Immich is excluded from auto-updates** — update manually due to breaking changes risk

---

## Design Decisions & Rationale

| Decision | Rationale |
|---|---|
| Zero-Trust / Tailscale over port forwarding | Eliminates attack surface entirely. No ports exposed to internet. |
| EXT4 for external drives | Journaling for crash resilience, full Linux permission support |
| `nofail` in fstab | Server must boot even if USB drives aren't ready yet |
| Immich Postgres on internal SSD | Database I/O is random read/write — SSD is significantly faster than USB HDD |
| Immich excluded from Watchtower/auto-update | Immich is in heavy development, breaking DB migrations have occurred |
| MariaDB 10.6 pinned | Avoid accidental major version upgrades which require manual migration |
| Headless lid-closed operation | Server runs without display, lid closed to save space |
| `www-data` ownership on data dirs | Required by Nextcloud internals. User added to group as bridge. |
