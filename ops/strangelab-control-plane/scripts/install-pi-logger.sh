#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
TARGET_DIR="/opt/strangelab"

if ! command -v node >/dev/null 2>&1; then
  curl -fsSL https://deb.nodesource.com/setup_20.x | sudo -E bash -
  sudo apt-get update
  sudo apt-get install -y nodejs
fi

sudo mkdir -p "$TARGET_DIR"
sudo cp "$ROOT_DIR/agents/exec-agent.mjs" "$TARGET_DIR/exec-agent.mjs"
sudo cp "$ROOT_DIR/package.json" "$TARGET_DIR/package.json"
sudo cp "$ROOT_DIR/services/capabilities/pi-logger.json" "$TARGET_DIR/capabilities.json"

pushd "$TARGET_DIR" >/dev/null
sudo npm install --omit=dev
popd >/dev/null

sudo cp "$ROOT_DIR/services/systemd/strangelab-exec-agent@.service" /etc/systemd/system/strangelab-exec-agent@.service
sudo mkdir -p /etc/strangelab
sudo cp "$ROOT_DIR/services/systemd/exec-agent-pi-logger.env" /etc/strangelab/exec-agent-pi-logger.env

sudo systemctl daemon-reload
sudo systemctl enable strangelab-exec-agent@pi-logger.service
sudo systemctl restart strangelab-exec-agent@pi-logger.service
sudo systemctl --no-pager --full status strangelab-exec-agent@pi-logger.service | sed -n '1,40p'

echo "pi-logger install complete"
