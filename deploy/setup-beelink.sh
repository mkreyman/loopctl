#!/usr/bin/env bash
# One-time setup script for the Beelink deployment host.
# Run this manually: ssh beelink 'bash -s' < deploy/setup-beelink.sh
set -euo pipefail

APP_DIR="$HOME/workspace/loopctl"
REPO_URL="git@github.com:mkreyman/loopctl.git"

echo "==> Checking Docker..."
docker --version
docker compose version

echo "==> Cloning repository..."
if [ -d "$APP_DIR" ]; then
  echo "    Repository already exists at $APP_DIR"
  cd "$APP_DIR" && git pull
else
  git clone "$REPO_URL" "$APP_DIR"
fi

echo "==> Generating self-signed TLS certificate..."
CERT_DIR="$APP_DIR/deploy/certs"
mkdir -p "$CERT_DIR"
if [ ! -f "$CERT_DIR/selfsigned.crt" ]; then
  openssl req -x509 -nodes -days 3650 \
    -newkey rsa:2048 \
    -keyout "$CERT_DIR/selfsigned.key" \
    -out "$CERT_DIR/selfsigned.crt" \
    -subj "/CN=loopctl.local"
  echo "    Certificate generated at $CERT_DIR"
else
  echo "    Certificate already exists, skipping"
fi

echo "==> Setting up .env file..."
if [ ! -f "$APP_DIR/.env" ]; then
  cp "$APP_DIR/.env.example" "$APP_DIR/.env"
  echo "    IMPORTANT: Edit $APP_DIR/.env with your actual secrets!"
  echo "    Generate secrets with:"
  echo "      mix phx.gen.secret  (for SECRET_KEY_BASE)"
  echo "      elixir -e ':crypto.strong_rand_bytes(32) |> Base.encode64() |> IO.puts()'  (for CLOAK_KEY)"
else
  echo "    .env already exists, skipping"
fi

echo "==> Making deploy scripts executable..."
chmod +x "$APP_DIR/deploy/deploy.sh"
chmod +x "$APP_DIR/deploy/backup.sh"

echo "==> Installing systemd backup timer..."
sudo cp "$APP_DIR/deploy/loopctl-backup.service" /etc/systemd/system/
sudo cp "$APP_DIR/deploy/loopctl-backup.timer" /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now loopctl-backup.timer
echo "    Backup timer status:"
systemctl status loopctl-backup.timer --no-pager || true

echo "==> Installing GitHub Actions self-hosted runner..."
if [ -d "$HOME/actions-runner" ]; then
  echo "    Runner already installed at $HOME/actions-runner"
else
  echo "    To install the GitHub Actions runner:"
  echo "    1. Go to https://github.com/mkreyman/loopctl/settings/actions/runners/new"
  echo "    2. Select Linux x64"
  echo "    3. Follow the download and configure instructions"
  echo "    4. Install as a service: sudo ./svc.sh install && sudo ./svc.sh start"
fi

echo ""
echo "==> Setup complete!"
echo ""
echo "Next steps:"
echo "  1. Edit $APP_DIR/.env with your secrets"
echo "  2. Install the GitHub Actions runner (see instructions above)"
echo "  3. Run: cd $APP_DIR && docker compose up -d"
echo "  4. Run: docker compose exec app /app/bin/migrate"
