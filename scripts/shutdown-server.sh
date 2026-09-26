#!/bin/bash
echo "Starting manual backup"
sudo bash <HOME>/daily_backup.sh
echo "Stopping Immich..."
cd <HOME>/immich-app && docker compose down
echo "Stopping Nextcloud..."
cd <HOME>/nextcloud && docker compose down
echo "Shutting down..."
sudo shutdown -h now
