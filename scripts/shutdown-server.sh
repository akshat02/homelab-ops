#!/bin/bash
# Home Server Graceful Shutdown Script
# Performs a manual backup, stops running Docker stacks, and powers down the machine.

echo "Starting manual backup..."
sudo bash <HOME>/daily_backup.sh

echo "Stopping Immich..."
cd <HOME>/immich-app && docker compose down

echo "Stopping Nextcloud..."
cd <HOME>/nextcloud && docker compose down

echo "Shutting down system..."
sudo shutdown -h now
