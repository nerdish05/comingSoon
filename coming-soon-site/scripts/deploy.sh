#!/usr/bin/env bash
# Executed ON THE EC2 INSTANCE by the GitHub Actions workflow over SSH.
# Pulls the latest code, rebuilds the container, and restarts with zero
# meaningful downtime (Docker swaps the container, Nginx keeps listening).

set -euo pipefail

APP_DIR="${APP_DIR:-/opt/coming-soon-site}"

cd "$APP_DIR"

echo "==> Pulling latest code"
git fetch origin
git reset --hard origin/main

echo "==> Building updated image"
docker compose build web

echo "==> Restarting services"
docker compose up -d --no-deps --remove-orphans web nginx

echo "==> Pruning old images"
docker image prune -f

echo "==> Deploy complete. Current containers:"
docker compose ps
