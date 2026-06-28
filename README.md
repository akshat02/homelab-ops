# Home Server

Personal cloud infrastructure running on a repurposed laptop.
Self-hosted photo library, file sync, and remote access — zero cloud dependency.

---

## Quick Reference

| | |
|---|---|
| **Host** | `<SERVER_HOSTNAME>` (Tailscale) |
| **OS** | Linux Mint 22.3 XFCE |

### Services

| Service | URL (Tailscale) | Port | Project Dir |
|---|---|---|---|
| Nextcloud | `http://<SERVER_TAILSCALE_IP>:8080` | 8080 | `<HOME>/nextcloud/` |
| Immich | `http://<SERVER_TAILSCALE_IP>:2283` | 2283 | `<HOME>/immich-app/` |
| OpenClaw | `http://<SERVER_TAILSCALE_IP>:18789` | 18789 | `<HOME>/openclaw/` |

### Storage

| Label | Mount | Purpose |
|---|---|---|
| Live Drive | `/mnt/data_live` | Primary data (Nextcloud + Immich + OpenClaw backup dumps) |
| Backup Drive | `/mnt/data_backup` | Nightly rsync mirror of Live |
| Internal SSD | `/` | OS + Docker engine + Immich Postgres + OpenClaw database/agent cache |

### Key Paths

| Path | Purpose |
|---|---|
| `<HOME>/nextcloud/` | Nextcloud compose project |
| `<HOME>/nextcloud/.env` | Nextcloud/MariaDB credentials |
| `<HOME>/nextcloud/config/config.php` | Nextcloud live config (includes dbpassword) |
| `<HOME>/immich-app/` | Immich compose project |
| `<HOME>/immich-app/.env` | Immich/Postgres credentials |
| `<HOME>/openclaw/` | OpenClaw agent gateway project |
| `<HOME>/openclaw/.env` | OpenClaw API keys and gateway tokens |
| `<HOME>/daily_backup.sh` | Backup script |
| `<HOME>/shutdown-server.sh` | Clean shutdown helper script |
| `<HOME>/backup_log.txt` | Backup run log |
| `<HOME>/nextcloud_update_log.txt` | Weekly Nextcloud update log |
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
Client Device
  └── Tailscale (WireGuard)
        └── Home Server (Linux Mint)
              ├── Docker
              │     ├── Nextcloud (app + MariaDB + Redis)
              │     ├── Immich (server + ML + Postgres + Redis)
              │     └── OpenClaw (agent gateway + docker socket proxy)
              ├── /mnt/data_live    ← primary storage (ext4, USB HDD)
              └── /mnt/data_backup  ← nightly mirror  (ext4, USB HDD)
```

---

## Repository Structure

```
homelab-ops/
├── README.md
├── configs/
│   ├── nextcloud/
│   │   └── docker-compose.yml
│   ├── immich-app/
│   │   └── docker-compose.yml
│   └── openclaw/
│       └── docker-compose.yml
├── scripts/
│   ├── daily_backup.sh
│   └── shutdown-server.sh
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

## Emergency Reference

- **Drive failing:** See `docs/04-runbooks/RB-01-failover-to-backup-drive.md`
- **Password rotation:** See `docs/04-runbooks/RB-02-password-rotation.md`
- **Full reinstall:** See `docs/04-runbooks/RB-05-full-reinstall.md`
- **Check backup status:** `cat <HOME>/backup_log.txt | tail -30`
- **Check all containers:** `docker ps -a`
- **Check drive health:** `sudo smartctl -a <LIVE_DRIVE_DEVICE>`

---

## .env Structure (Do Not Commit Actual Values)

`<HOME>/nextcloud/.env`:
```
DB_ROOT_PASSWORD=
DB_PASSWORD=
DB_USER=
DB_NAME=
```

`<HOME>/immich-app/.env`:
```
UPLOAD_LOCATION=
DB_DATA_LOCATION=
TZ=
IMMICH_VERSION=
DB_PASSWORD=
DB_USERNAME=
DB_DATABASE_NAME=
```

`<HOME>/openclaw/.env`:
```
OPENCLAW_GATEWAY_TOKEN=
DEEPSEEK_API_KEY=
TELEGRAM_TOKEN_USER=
```