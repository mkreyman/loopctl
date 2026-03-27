#!/usr/bin/env bash
#
# Deploy script for loopctl on beelink self-hosted server.
#
# This script:
# 1. Pulls latest code from master
# 2. Installs dependencies
# 3. Compiles a Mix release
# 4. Runs database migrations
# 5. Restarts the systemd service
# 6. Verifies health check passes
#
# Usage: bash bin/deploy.sh
#
# Prerequisites:
# - .env file at /opt/loopctl/.env with all required environment variables
# - systemd service unit installed at /etc/systemd/system/loopctl.service
# - PostgreSQL running with the loopctl database
#
set -euo pipefail

APP_NAME="loopctl"
APP_DIR="/opt/${APP_NAME}"
RELEASE_DIR="${APP_DIR}/_build/prod/rel/${APP_NAME}"
PORT="${PORT:-4000}"
HEALTH_URL="http://127.0.0.1:${PORT}/health"
HEALTH_TIMEOUT=30

echo "=== Deploying ${APP_NAME} ==="
echo "Time: $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
echo ""

# 1. Pull latest code
echo "--- Pulling latest code from master ---"
cd "${APP_DIR}"
git fetch origin master
git reset --hard origin/master

# 2. Install dependencies
echo "--- Installing dependencies ---"
export MIX_ENV=prod
mix deps.get --only prod

# 3. Compile release
echo "--- Compiling release ---"
mix compile --warnings-as-errors
mix release --overwrite

# 4. Run migrations
echo "--- Running database migrations ---"
"${RELEASE_DIR}/bin/${APP_NAME}" eval "Loopctl.Release.migrate()"

# 5. Restart the service
echo "--- Restarting systemd service ---"
sudo systemctl restart "${APP_NAME}.service"

# 6. Health check
echo "--- Waiting for health check (timeout: ${HEALTH_TIMEOUT}s) ---"
for i in $(seq 1 "${HEALTH_TIMEOUT}"); do
  if curl -sf "${HEALTH_URL}" > /dev/null 2>&1; then
    echo "Health check passed after ${i}s"
    echo ""
    echo "=== Deploy complete ==="
    exit 0
  fi
  sleep 1
done

echo "ERROR: Health check failed after ${HEALTH_TIMEOUT}s"
echo "Check logs: journalctl -u ${APP_NAME}.service -n 50"
exit 1
