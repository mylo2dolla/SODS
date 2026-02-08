#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
if [[ -f "$REPO_ROOT/tools/_env.sh" ]]; then
  # shellcheck disable=SC1091
  source "$REPO_ROOT/tools/_env.sh"
fi
UFW_CIDR="${UFW_CIDR:-${AUX_CIDR:-192.168.8.0/24}}"

ROOT_DIR="$(cd -- "$SCRIPT_DIR/.." && pwd)"
TARGET_DIR="/opt/strangelab"

if ! command -v docker >/dev/null 2>&1; then
  curl -fsSL https://get.docker.com | sh
  sudo usermod -aG docker "$USER"
fi

if ! command -v node >/dev/null 2>&1; then
  curl -fsSL https://deb.nodesource.com/setup_20.x | sudo -E bash -
  sudo apt-get update
  sudo apt-get install -y nodejs
fi

sudo mkdir -p "$TARGET_DIR/livekit"
sudo cp "$ROOT_DIR/services/docker-compose.livekit.yml" "$TARGET_DIR/livekit/docker-compose.yml"

pushd "$TARGET_DIR/livekit" >/dev/null
sudo docker compose up -d
popd >/dev/null

sudo mkdir -p "$TARGET_DIR"
sudo cp "$ROOT_DIR/agents/token-server.mjs" "$TARGET_DIR/token-server.mjs"
sudo cp "$ROOT_DIR/agents/god-gateway.mjs" "$TARGET_DIR/god-gateway.mjs"
sudo cp "$ROOT_DIR/agents/exec-agent.mjs" "$TARGET_DIR/exec-agent.mjs"
sudo cp "$ROOT_DIR/agents/ops-feed.mjs" "$TARGET_DIR/ops-feed.mjs"
sudo cp "$ROOT_DIR/package.json" "$TARGET_DIR/package.json"
sudo cp "$ROOT_DIR/services/capabilities/pi-aux.json" "$TARGET_DIR/capabilities.json"

pushd "$TARGET_DIR" >/dev/null
sudo npm install --omit=dev
popd >/dev/null

sudo cp "$ROOT_DIR/services/systemd/strangelab-token.service" /etc/systemd/system/strangelab-token.service
sudo cp "$ROOT_DIR/services/systemd/strangelab-god-gateway.service" /etc/systemd/system/strangelab-god-gateway.service
sudo cp "$ROOT_DIR/services/systemd/strangelab-exec-agent@.service" /etc/systemd/system/strangelab-exec-agent@.service
sudo cp "$ROOT_DIR/services/systemd/strangelab-ops-feed.service" /etc/systemd/system/strangelab-ops-feed.service

sudo mkdir -p /etc/strangelab
sudo cp "$ROOT_DIR/services/systemd/exec-agent-pi-aux.env" /etc/strangelab/exec-agent-pi-aux.env

sudo systemctl daemon-reload
sudo systemctl enable strangelab-token.service
sudo systemctl enable strangelab-god-gateway.service
sudo systemctl enable strangelab-exec-agent@pi-aux.service
sudo systemctl enable strangelab-ops-feed.service
sudo systemctl restart strangelab-token.service
sudo systemctl restart strangelab-god-gateway.service
sudo systemctl restart strangelab-exec-agent@pi-aux.service
sudo systemctl restart strangelab-ops-feed.service

if command -v ufw >/dev/null 2>&1; then
  sudo ufw allow from "$UFW_CIDR" to any port 9101 proto tcp >/dev/null 2>&1 || true
fi

sudo systemctl --no-pager --full status strangelab-token.service | sed -n '1,40p'
sudo systemctl --no-pager --full status strangelab-god-gateway.service | sed -n '1,40p'
sudo systemctl --no-pager --full status strangelab-exec-agent@pi-aux.service | sed -n '1,40p'
sudo systemctl --no-pager --full status strangelab-ops-feed.service | sed -n '1,40p'

bash "$ROOT_DIR/scripts/install-control-surface.sh"

echo "pi-aux install complete"
