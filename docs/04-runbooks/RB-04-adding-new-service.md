# RB-04 — Adding a New Service

## Purpose
Use this runbook when deploying a new self-hosted service on the home server alongside the existing Nextcloud and Immich stacks. Following this process ensures the new service integrates cleanly with the existing storage, networking, backup, and maintenance patterns.

---

## Prerequisites
- SSH access to the server (via Tailscale)
- Confirmed available resources — see constraints below
- A recent successful backup: `tail -20 <HOME>/backup_log.txt`

---

## Hardware Constraints

This server is resource-constrained. Before adding a service, assess its fit:

| Resource | Available | Notes |
|---|---|---|
| RAM | ~4 GB total | Nextcloud + Immich already consume ~2–2.5 GB under load. Budget ~500 MB per new service max. |
| CPU | 2 cores / 4 threads (i3-3110M) | Immich ML jobs already spike CPU. Avoid services with heavy background processing. |
| Storage | Limited by Live Drive capacity | Check with `df -h /mnt/data_live` before committing. |
| USB bandwidth | Shared across both HDDs via hub | High-throughput services (e.g. media servers) may saturate the USB bus. |

Check current resource usage before proceeding:
```bash
# Memory
free -h

# CPU and per-container memory usage
docker stats --no-stream

# Disk space
df -h /mnt/data_live
```

> **Educational note:** Running too many services on a memory-constrained host leads to swap thrashing — the kernel begins swapping active memory to disk, causing everything to slow to a crawl. On a USB-attached HDD, swap I/O is especially slow. If `free -h` shows swap usage above 50%, the server is already under pressure.

---

## Step 1 — Plan the Service

Before writing any config, answer these questions:

| Question | Why it matters |
|---|---|
| Does it need a database? | If yes, decide whether to use a dedicated container or share an existing DB instance. Dedicated is safer for isolation. |
| Where will its data live? | All persistent data should go under `/mnt/data_live/<service_name>/` to be picked up by the nightly rsync. |
| What port will it use? | Check for conflicts: `sudo ss -tlnp` |
| Does it need to be accessible remotely? | All access is via Tailscale — no router config needed, but confirm the port is not blocked by UFW. |
| Should it auto-update? | Only safe for stateless or simple services. DB-backed services with active development (like Immich) should update manually. |
| Does it need to be included in DB backups? | If it has its own database, the backup script must be updated. |

---

## Step 2 — Create the Project Directory

Keep each service in its own directory under `<HOME>`:

```bash
mkdir -p <HOME>/<service_name>
cd <HOME>/<service_name>
```

---

## Step 3 — Create `docker-compose.yml` and `.env`

Create a `docker-compose.yml` for the service. Follow the existing patterns:

```yaml
# <HOME>/<service_name>/docker-compose.yml

services:
  <service_name>:
    image: <image>:<tag>        # Pin a specific tag — avoid 'latest' for DB-backed services
    container_name: <service_name>
    restart: always
    ports:
      - <HOST_PORT>:<CONTAINER_PORT>
    volumes:
      - /mnt/data_live/<service_name>/data:/data   # persistent data on Live Drive
      - ./<service_name>/config:/config             # config on internal SSD
    env_file:
      - .env
```

Create a `.env` file for credentials and config:
```bash
nano <HOME>/<service_name>/.env
```

Add `.env` to `.gitignore` if tracking the config in version control:
```bash
echo ".env" >> <HOME>/<service_name>/.gitignore
```

---

## Step 4 — Create Data Directory on Live Drive

All service data must live under `/mnt/data_live/` to be included in the nightly rsync backup:

```bash
sudo mkdir -p /mnt/data_live/<service_name>
sudo chown -R <USER>:<USER> /mnt/data_live/<service_name>
```

> If the service runs as a specific UID inside the container (e.g. `www-data`, `nobody`, or a custom UID), set ownership accordingly. Check the service's documentation for the expected UID.

---

## Step 5 — Check for Port Conflicts

```bash
sudo ss -tlnp | grep <HOST_PORT>
```

If the port is in use, choose a different host port in `docker-compose.yml`.

Existing ports in use:

| Port | Service |
|---|---|
| 8080 | Nextcloud |
| 2283 | Immich |
| 18789 | OpenClaw |
| 22 | SSH |

---

## Step 6 — Start the Service

```bash
cd <HOME>/<service_name>
docker compose up -d
```

Verify it started cleanly:
```bash
docker ps
docker logs <service_name> --tail 30
```

Access it via Tailscale:
```
http://<SERVER_TAILSCALE_IP>:<HOST_PORT>
```

---

## Step 7 — Update the Backup Script (if service has a database)

If the new service runs its own database container, add a dump step to `<HOME>/daily_backup.sh`.

### For a Postgres database:
Add after the existing Immich dump block:

```bash
# <SERVICE_NAME> DB Dump
log_message "Starting <SERVICE_NAME> DB dump..."
SERVICE_DUMP="$LIVE/backups/<service_name>_db/<service_name>_db_$(date +%Y-%m-%d).sql.gz"
mkdir -p "$LIVE/backups/<service_name>_db"
/usr/bin/docker exec -t <SERVICE_DB_CONTAINER> pg_dumpall -c -U postgres | gzip > "$SERVICE_DUMP"
if [ ${PIPESTATUS[0]} -ne 0 ]; then
    log_message "ERROR: <SERVICE_NAME> DB dump failed. Aborting."
    exit 1
fi
log_message "<SERVICE_NAME> DB dump completed: $SERVICE_DUMP"
```

### For a MariaDB/MySQL database:
Add after the existing Nextcloud dump block:

```bash
# <SERVICE_NAME> DB Dump
log_message "Starting <SERVICE_NAME> DB dump..."
SERVICE_DUMP="$LIVE/backups/<service_name>_db/<service_name>_db_$(date +%Y-%m-%d).sql"
mkdir -p "$LIVE/backups/<service_name>_db"
/usr/bin/docker exec <SERVICE_DB_CONTAINER> mysqldump \
  -u "${SERVICE_DB_USER}" -p"${SERVICE_DB_PASSWORD}" "${SERVICE_DB_NAME}" > "$SERVICE_DUMP"
if [ $? -ne 0 ]; then
    log_message "ERROR: <SERVICE_NAME> DB dump failed. Aborting."
    exit 1
fi
log_message "<SERVICE_NAME> DB dump completed: $SERVICE_DUMP"
```

Also add a 7-day retention cleanup for the new dump directory:
```bash
find "$LIVE/backups/<service_name>_db/" -mtime +7 -type f -delete
```

Test the updated script manually:
```bash
sudo bash <HOME>/daily_backup.sh
tail -30 <HOME>/backup_log.txt
```

---

## Step 8 — Configure Auto-Updates (Optional)

**Simple / stateless services** — safe to add to the weekly Nextcloud update cron:
```bash
sudo crontab -e
```
Append a new line for the service:
```
0 02 * * 0 docker compose -f <HOME>/<service_name>/docker-compose.yml pull && docker compose -f <HOME>/<service_name>/docker-compose.yml up -d >> <HOME>/<service_name>_update_log.txt 2>&1
```

**DB-backed services in active development** — exclude from auto-updates. Update manually and review release notes before each update:
```bash
cd <HOME>/<service_name>
docker compose pull
docker compose up -d
```

---

## Step 9 — Update Documentation

- Add the new service to the services table in `README.md`
- Add a service entry in `docs/02-services.md`
- If the service has a database, note it in `docs/03-backup-and-recovery.md`
- Record any new port assignments in this runbook's port table above

---

## Post-Deployment Checklist

- [ ] Service is running: `docker ps`
- [ ] Service is accessible via Tailscale IP and correct port
- [ ] Data directory is on `/mnt/data_live/` (not internal SSD or home dir)
- [ ] `.env` is not committed to version control
- [ ] Backup script updated (if service has a DB) and tested
- [ ] Port conflict check done: `sudo ss -tlnp`
- [ ] Auto-update decision made and configured (or explicitly skipped)
- [ ] README and docs updated
