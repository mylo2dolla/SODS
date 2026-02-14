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
sudo cp "$ROOT_DIR/agents/vault-ingest.mjs" "$TARGET_DIR/vault-ingest.mjs"
sudo cp "$ROOT_DIR/package.json" "$TARGET_DIR/package.json"

pushd "$TARGET_DIR" >/dev/null
sudo npm install --omit=dev
popd >/dev/null

sudo cp "$ROOT_DIR/services/systemd/strangelab-vault-ingest.service" /etc/systemd/system/strangelab-vault-ingest.service

sudo systemctl disable --now strangelab-exec-agent@pi-logger.service >/dev/null 2>&1 || true
sudo systemctl disable --now strangelab-exec-agent.service >/dev/null 2>&1 || true

sudo systemctl daemon-reload
sudo systemctl enable strangelab-vault-ingest.service
sudo systemctl restart strangelab-vault-ingest.service
sudo systemctl --no-pager --full status strangelab-vault-ingest.service | sed -n '1,40p'

echo "pi-logger install complete (vault-ingest only)"
