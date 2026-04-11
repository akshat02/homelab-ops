# Home Server

Personal cloud infrastructure running on a repurposed HP Pavilion g6 laptop.
Self-hosted photo library, file sync, and remote access — zero cloud dependency.

---

## Quick Reference

| | |
|---|---|
| **Host** | `hp-laptop` (Tailscale) / `100.116.25.81` |
| **OS** | Linux Mint 22.3 XFCE |

### Services

| Service | URL (Tailscale) | Port | Stack |
|---|---|---|---|
| Nextcloud | `http://100.116.25.81:8080` | 8080 | `~/nextcloud/` |
| Immich | `http://100.116.25.81:2283` | 2283 | `~/immich-app/` |

### Storage

| Label | Device | Mount | Purpose |
|---|---|---|---|
| Live Drive | `/dev/sdb` | `/mnt/data_live` | Primary data (Nextcloud + Immich) |
| Backup Drive | `/dev/sdc1` | `/mnt/data_backup` | Nightly rsync mirror of Live |
| Internal SSD | `/dev/sda2` | `/` | OS + Docker + Immich Postgres |

### Key Paths

| Path | Purpose |
|---|---|
| `~/nextcloud/` | Nextcloud compose project |
| `~/nextcloud/.env` | Nextcloud/MariaDB credentials |
| `~/nextcloud/config/config.php` | Nextcloud live config |
| `~/immich-app/` | Immich compose project |
| `~/immich-app/.env` | Immich/Postgres credentials |
| `~/daily_backup.sh` | Backup script |
| `~/backup_log.txt` | Backup run log |
| `~/nextcloud_update_log.txt` | Weekly Nextcloud update log |
| `/mnt/data_live/backups/` | DB dumps (7-day retention) |

---

## Scheduled Tasks (Root Crontab)

| Schedule | Task |
|---|---|
| Every 5 min | Nextcloud background cron (`cron.php`) |
| Sunday 02:00 AM | Nextcloud image update (`docker compose pull + up`) |
| Daily 03:00 AM | Full backup — DB dumps + rsync mirror |

---

## Architecture Summary

```
MacBook
  └── Tailscale (WireGuard)
        └── hp-laptop (Linux Mint)
              ├── Docker
              │     ├── Nextcloud (app + MariaDB + Redis)
              │     └── Immich (server + ML + Postgres + Redis)
              ├── /mnt/data_live    ← primary storage (ext4, USB HDD)
              └── /mnt/data_backup  ← nightly mirror  (ext4, USB HDD)
```

---

## Repository Structure

```
home-server/
├── README.md
├── config/
│   ├── nextcloud/
│   │   └── docker-compose.yml
│   └── immich/
│       └── docker-compose.yml
├── scripts/
│   └── daily_backup.sh
├── docs/
│   ├── 01-architecture.md
│   ├── 02-services.md
│   ├── 03-backup-and-recovery.md
│   ├── 04-runbooks/
│   │   ├── RB-01-failover-to-backup-drive.md
│   │   ├── RB-02-password-rotation.md
│   │   ├── RB-03-drive-replacement.md
│   │   ├── RB-04-adding-new-service.md
│   │   └── RB-05-full-reinstall.md
│   ├── 05-maintenance.md
│   └── 06-security.md
└── .gitignore
```

---

## Emergency Contacts

- **Drive failing:** See `docs/04-runbooks/RB-01-failover-to-backup-drive.md`
- **Password rotation:** See `docs/04-runbooks/RB-02-password-rotation.md`
- **Full reinstall:** See `docs/04-runbooks/RB-05-full-reinstall.md`
- **Check backup status:** `cat ~/backup_log.txt | tail -30`
- **Check all containers:** `docker ps -a`
- **Check drive health:** `sudo smartctl -a /dev/sdb`

---

## .env Structure

`~/nextcloud/.env`:
```
DB_ROOT_PASSWORD=
DB_PASSWORD=
DB_USER=nextcloud
DB_NAME=nextcloud
```

`~/immich-app/.env`:
```
UPLOAD_LOCATION=/mnt/data_live/immich_library
DB_DATA_LOCATION=./postgres
TZ=Asia/Kolkata
IMMICH_VERSION=v2
DB_PASSWORD=
DB_USERNAME=postgres
DB_DATABASE_NAME=immich
```