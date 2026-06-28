# 02 — Services

Reference for all services running on the home server — configuration, access, ports, and operational notes.

---

## Service Overview

| Service | Purpose | Port | Project Dir |
|---|---|---|---|
| Nextcloud | File sync and personal cloud | 8080 | `<HOME>/nextcloud/` |
| Immich | Self-hosted photo/video library | 2283 | `<HOME>/immich-app/` |
| OpenClaw | Self-hosted LLM agent gateway | 18789 | `<HOME>/openclaw/` |

All services are accessible **only via Tailscale IP** — no ports are exposed to the public internet.

---

## Nextcloud

### Purpose
Primary file sync and personal cloud storage. Used for document storage, note syncing, and general file access across devices.

### Stack Composition

| Container | Image | Role |
|---|---|---|
| `<NEXTCLOUD_APP_CONTAINER>` | `nextcloud:latest` | Web application (PHP) |
| `<NEXTCLOUD_DB_CONTAINER>` | `mariadb:10.6` | Relational database |
| `<NEXTCLOUD_REDIS_CONTAINER>` | `redis:alpine` | Cache and session store |

> **Note:** MariaDB is pinned to `10.6` to prevent accidental major version upgrades, which require a manual migration procedure.

### Key Paths

| Path | Purpose |
|---|---|
| `<HOME>/nextcloud/docker-compose.yml` | Stack definition |
| `<HOME>/nextcloud/.env` | Credentials (do not commit) |
| `<HOME>/nextcloud/config/config.php` | Live Nextcloud config — authoritative for DB connection |
| `<HOME>/nextcloud/db/` | MariaDB data (on internal SSD) |
| `/mnt/data_live/nextcloud_data/` | User files |

### Access
- URL: `http://<SERVER_TAILSCALE_IP>:8080`
- Admin user: configured at initial setup

### Important Config Notes

- `config.php` is the **authoritative** source for the DB password in a running Nextcloud instance. When rotating credentials, this file must be updated directly on the host — it is accessible via the volume mount at `<HOME>/nextcloud/config/`.
- Always run `docker compose` commands from **inside** `<HOME>/nextcloud/` — Docker Compose looks for `.env` in the current working directory. Running from elsewhere causes containers to start with missing or stale environment variables.
- Shell environment variables set via `export` take precedence over the `.env` file. If you've run `export` in your current shell, open a new shell or `unset` the variables before running `docker compose up`.

### Background Tasks
A cron job runs every 5 minutes to execute Nextcloud background processing (thumbnail generation, file indexing, notifications):

```
*/5 * * * * docker exec -u www-data <NEXTCLOUD_APP_CONTAINER> php -f /var/www/html/cron.php
```

### Bulk File Import (CLI Workflow)
To import large folders without using the web UI (e.g. from a Mac over SSH):

```bash
# 1. Transfer files to server home dir
rsync -aP /path/to/folder <USER>@<SERVER_TAILSCALE_IP>:~/

# 2. Move to Nextcloud data directory
sudo mv ~/folder /mnt/data_live/nextcloud_data/<USER>/files/

# 3. Fix ownership
sudo chown -R www-data:www-data /mnt/data_live/nextcloud_data/<USER>/files/folder

# 4. Trigger Nextcloud file index
docker exec -u www-data <NEXTCLOUD_APP_CONTAINER> php occ files:scan <USER>
```

### Updates
Nextcloud is updated automatically via a weekly cron job (Sunday 02:00 AM):

```
0 02 * * 0 docker compose -f <HOME>/nextcloud/docker-compose.yml pull && docker compose -f <HOME>/nextcloud/docker-compose.yml up -d >> <HOME>/nextcloud_update_log.txt 2>&1
```

Update log: `<HOME>/nextcloud_update_log.txt`

---

## Immich

### Purpose
Self-hosted photo and video library. Handles AI-based face recognition, object tagging, timeline view, and album organisation. Primary destination for iPhone, iCloud, and Google Photos exports.

### Stack Composition

| Container | Image | Role |
|---|---|---|
| `<IMMICH_SERVER_CONTAINER>` | `ghcr.io/immich-app/immich-server` | API + web UI |
| `<IMMICH_ML_CONTAINER>` | `ghcr.io/immich-app/immich-machine-learning` | AI features (face/object recognition) |
| `<IMMICH_DB_CONTAINER>` | `ghcr.io/immich-app/postgres:14-vectorchord...` | PostgreSQL with vector extension |
| `<IMMICH_REDIS_CONTAINER>` | `valkey/valkey:9` | Cache |

> Immich uses a **custom Postgres image** with the `pgvecto.rs` (VectorChord) extension for AI-powered similarity search. Do not substitute a generic Postgres image.

### Key Paths

| Path | Purpose |
|---|---|
| `<HOME>/immich-app/docker-compose.yml` | Stack definition |
| `<HOME>/immich-app/.env` | Credentials and config (do not commit) |
| `<HOME>/immich-app/postgres/` | Postgres data (on internal SSD for I/O performance) |
| `/mnt/data_live/immich_library/` | Photo/video library files |

### `.env` Variables

```
UPLOAD_LOCATION=         # Path to photo/video library (e.g. /mnt/data_live/immich_library)
DB_DATA_LOCATION=        # Path to Postgres data dir (e.g. <HOME>/immich-app/postgres)
TZ=                      # Timezone (e.g. Asia/Kolkata)
IMMICH_VERSION=          # Pinned version tag (or 'release' for latest)
DB_PASSWORD=             # Postgres password (do not commit)
DB_USERNAME=             # Postgres username
DB_DATABASE_NAME=        # Database name
```

### Access
- URL: `http://<SERVER_TAILSCALE_IP>:2283`

### Storage Template
Library files are organised on disk by date using the Immich storage template:

```
{{y}}/{{MM}}/{{filename}}
```

This results in a human-readable structure: `/mnt/data_live/immich_library/2024/06/IMG_0001.jpg`

### Hardware Acceleration
Intel QuickSync is passed through to the Immich server container for video transcoding:

```yaml
devices:
  - /dev/dri:/dev/dri
```

To verify QuickSync is active during video processing:
```bash
sudo apt install intel-gpu-tools
sudo intel_gpu_top
```

### Thermal Management
The server CPU (i3-3110M) runs hot during AI ingestion jobs. Background job concurrency is throttled to **1** in the Immich Admin UI (`Administration → Jobs`). Do not increase this without monitoring temperatures first.

Check CPU temperature:
```bash
sensors
# or
cat /sys/class/thermal/thermal_zone*/temp
```

### Updates
Immich is **excluded from automatic updates** due to its active development phase — breaking database migrations have occurred in past releases. Update manually:

```bash
cd <HOME>/immich-app
docker compose pull
docker compose up -d
```

Review the [Immich release notes](https://github.com/immich-app/immich/releases) before each update, particularly for Postgres migration warnings.

### Cloud Library Ingestion
To import from Google Takeout or Apple iCloud exports while preserving metadata:

- Tool: [`immich-go`](https://github.com/simulot/immich-go)
- Preserves original timestamps and album structure from Google Photos exports
- See the Immich documentation for current `immich-go` usage

---

## OpenClaw

### Purpose
Self-hosted LLM agent gateway and remote tool/agent controller. Connects external interfaces (e.g. Telegram) to internal LLM capabilities with local sandboxed file and command execution permissions.

### Stack Composition

| Container | Role | Image |
|---|---|---|
| `<OPENCLAW_APP_CONTAINER>` | Agent execution engine | `ghcr.io/openclaw/openclaw:2026.5.22` |
| `<DOCKER_PROXY_CONTAINER>` | Safe docker daemon proxy | `tecnativa/docker-socket-proxy` |

### Key Paths

| Path | Purpose |
|---|---|
| `<HOME>/openclaw/docker-compose.yml` | Stack definition |
| `<HOME>/openclaw/.env` | Tokens and API keys (do not commit) |
| `<HOME>/openclaw/secrets/obsidian_key` | Secret encryption key for Obsidian integration |
| `<HOME>/openclaw/agents/` | Local agent persistence folders |

### Access
- Port: `18789` (used for API / webhooks interaction internally or via Tailscale)

### Security Notes
- Mounts host's `<HOME>` folder to `/host-home` in read-only mode (`ro`).
- Uses `docker-socket-proxy` to limit container capabilities. The docker daemon socket is not mounted directly to the agent container to prevent container breakout.

---

## Common Operational Commands

### Check all container status
```bash
docker ps -a
```

### Restart a specific stack
```bash
cd <HOME>/nextcloud && docker compose restart
cd <HOME>/immich-app && docker compose restart
cd <HOME>/openclaw && docker compose restart
```

### View container logs
```bash
docker logs <CONTAINER_NAME> --tail 50 -f
```

### Check Nextcloud maintenance mode
```bash
docker exec -u www-data <NEXTCLOUD_APP_CONTAINER> php occ maintenance:mode
```
