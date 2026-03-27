#!/usr/bin/env bash
# Deploy script — runs on the Beelink after code is pulled.
# Called by the GitHub Actions self-hosted runner deploy job.
set -euo pipefail

APP_DIR="$HOME/workspace/loopctl"
cd "$APP_DIR"

echo "==> Pulling latest code..."
git fetch origin master
git reset --hard origin/master

echo "==> Building and starting containers..."
docker compose build --pull
docker compose up -d --force-recreate

echo "==> Running migrations..."
docker compose exec -T app /app/bin/migrate

echo "==> Cleaning up old Docker images..."
docker image prune -f

echo "==> Deploy complete!"
docker compose ps
