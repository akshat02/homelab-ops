# RB-02 — Password Rotation

## Purpose
Use this runbook when rotating database credentials for Nextcloud (MariaDB) or Immich (Postgres). This should be done periodically or immediately if credentials have been exposed (e.g. in chat history, logs, or version control).

---

## Prerequisites
- SSH access to the server (via Tailscale)
- A recent successful backup confirmed: `tail -20 <HOME>/backup_log.txt`
- New passwords ready — see password requirements below

## Password Requirements
- Use only alphanumeric characters and `_` or `-`
- **Avoid shell-unsafe characters:** `$`, `` ` ``, `&`, `!`, `\`, `'`, `"`, `(`, `)`
- These characters can silently break the `export $(... | xargs)` pattern used in the backup script to load `.env` variables

---

## Part A — Nextcloud (MariaDB)

Nextcloud credentials exist in **three places simultaneously** and must be updated in the correct sequence. Updating only one will break the application.

| Location | What it controls |
|---|---|
| MariaDB database (inside container) | Actual DB user authentication |
| `<HOME>/nextcloud/.env` | Credentials passed to containers on start |
| `<HOME>/nextcloud/config/config.php` | Live config used by running Nextcloud instance |

### Step-by-step

#### 1. Run a manual backup first
```bash
sudo bash <HOME>/daily_backup.sh
```

#### 2. Enable Nextcloud maintenance mode
```bash
docker exec -u www-data <NEXTCLOUD_APP_CONTAINER> php occ maintenance:mode --on
```

#### 3. Load current credentials into shell
```bash
cd <HOME>/nextcloud
export $(grep -v '^#' .env | xargs)
```

#### 4. Change the password inside MariaDB
```bash
docker exec <NEXTCLOUD_DB_CONTAINER> mariadb \
  -u root -p"${DB_ROOT_PASSWORD}" \
  -e "ALTER USER '${DB_USER}'@'%' IDENTIFIED BY 'NEW_PASSWORD'; FLUSH PRIVILEGES;"
```
Replace `NEW_PASSWORD` with your chosen password.

If rotating the root password as well:
```bash
docker exec <NEXTCLOUD_DB_CONTAINER> mariadb \
  -u root -p"${DB_ROOT_PASSWORD}" \
  -e "ALTER USER 'root'@'%' IDENTIFIED BY 'NEW_ROOT_PASSWORD'; FLUSH PRIVILEGES;"
```

#### 5. Update `.env` with new password(s)
```bash
nano <HOME>/nextcloud/.env
```
Update `DB_PASSWORD` (and `DB_ROOT_PASSWORD` if changed). Save and close.

#### 6. Open a new shell or unset exported variables
Shell environment variables take precedence over `.env`. If you skip this step, `docker compose` will use the old exported values, not the updated `.env`.

```bash
# Either open a new SSH session, or unset manually:
unset DB_PASSWORD DB_ROOT_PASSWORD DB_USER DB_NAME
```

#### 7. Recreate containers from inside the project directory
```bash
cd <HOME>/nextcloud
docker compose down && docker compose up -d
```

> **Critical:** Always run `docker compose` from inside `<HOME>/nextcloud/`. Docker Compose looks for `.env` in the current working directory. Running from elsewhere causes containers to start with missing or empty environment variables.

#### 8. Update `config.php` directly on the host
Nextcloud's `config.php` is the authoritative DB config for a running instance. It is **not** automatically updated when `.env` changes. Edit it directly via the volume mount:

```bash
nano <HOME>/nextcloud/config/config.php
```

Find the `dbpassword` key and update the value:
```php
'dbpassword' => 'NEW_PASSWORD',
```

Save and close.

#### 9. Restart the app container
```bash
cd <HOME>/nextcloud
docker compose restart app
```

#### 10. Disable maintenance mode
```bash
docker exec -u www-data <NEXTCLOUD_APP_CONTAINER> php occ maintenance:mode --off
```

#### 11. Verify
- Open Nextcloud in browser: `http://<SERVER_TAILSCALE_IP>:8080`
- Log in and confirm files are accessible

#### 12. Run a manual backup to confirm script works with new credentials
```bash
sudo bash <HOME>/daily_backup.sh
```
Check the log for errors:
```bash
tail -20 <HOME>/backup_log.txt
```

---

## Part B — Immich (Postgres)

Immich is simpler than Nextcloud — there is no `config.php` equivalent. Credentials only need to be updated in the Postgres database itself and the `.env` file, then containers recreated.

| Location | What it controls |
|---|---|
| Postgres database (inside container) | Actual DB user authentication |
| `<HOME>/immich-app/.env` | Credentials passed to containers on start |

### Step-by-step

#### 1. Run a manual backup first
```bash
sudo bash <HOME>/daily_backup.sh
```

#### 2. Load current credentials into shell
```bash
cd <HOME>/immich-app
export $(grep -v '^#' .env | xargs)
```

#### 3. Change the password inside Postgres
```bash
docker exec -it <IMMICH_DB_CONTAINER> psql -U "${DB_USERNAME}" -d "${DB_DATABASE_NAME}" \
  -c "ALTER USER \"${DB_USERNAME}\" WITH PASSWORD 'NEW_PASSWORD';"
```
Replace `NEW_PASSWORD` with your chosen password.

#### 4. Update `.env` with new password
```bash
nano <HOME>/immich-app/.env
```
Update `DB_PASSWORD`. Save and close.

#### 5. Open a new shell or unset exported variables
```bash
unset DB_PASSWORD DB_USERNAME DB_DATABASE_NAME
```

#### 6. Recreate containers from inside the project directory
```bash
cd <HOME>/immich-app
docker compose down && docker compose up -d
```

#### 7. Verify
```bash
docker ps
# All Immich containers should show 'Up' or 'healthy' within ~30 seconds
```
Open Immich in browser: `http://<SERVER_TAILSCALE_IP>:2283`

#### 8. Run a manual backup to confirm
```bash
sudo bash <HOME>/daily_backup.sh
tail -20 <HOME>/backup_log.txt
```

---

## Common Gotchas

| Gotcha | Explanation |
|---|---|
| Running `docker compose` from wrong directory | Docker Compose resolves `.env` relative to CWD. Always `cd` into the project directory first. |
| Exported shell vars overriding `.env` | If you ran `export $(...)` in the current shell, those values take precedence. Open a new shell or `unset` before running `docker compose up`. |
| Nextcloud `config.php` not updated | Even after container recreate, Nextcloud reads DB password from `config.php`, not environment variables. This file must be edited manually. |
| Shell-unsafe chars in password | Characters like `$`, `` ` ``, `&` break the `xargs` parsing in the backup script. Stick to alphanumeric + `_` `-`. |
| `occ` commands failing during rotation | `occ` needs a live DB connection to run. If the DB password is mid-rotation and mismatched, `occ` will fail. Fix `config.php` first, then retry. |
