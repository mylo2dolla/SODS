#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
TARGET_DIR="/opt/strangelab"

if ! command -v node >/dev/null 2>&1; then
  curl -fsSL https://deb.nodesource.com/setup_20.x | sudo -E bash -
  sudo apt-get update
  sudo apt-get install -y nodejs
fi

if ! command -v sqlite3 >/dev/null 2>&1; then
  sudo apt-get update
  sudo apt-get install -y sqlite3
fi

sudo mkdir -p "$TARGET_DIR"
sudo cp "$ROOT_DIR/agents/vault-ingest.mjs" "$TARGET_DIR/vault-ingest.mjs"
sudo mkdir -p "$TARGET_DIR/services/ble"
sudo cp "$ROOT_DIR/services/ble/identity-core.mjs" "$TARGET_DIR/services/ble/identity-core.mjs"
sudo cp "$ROOT_DIR/package.json" "$TARGET_DIR/package.json"

pushd "$TARGET_DIR" >/dev/null
sudo npm install --omit=dev
popd >/dev/null

sudo mkdir -p /vault/sods/vault
sudo mkdir -p /var/sods
if [ -d /var/sods/vault ] && [ ! -L /var/sods/vault ]; then
  if command -v rsync >/dev/null 2>&1; then
    sudo rsync -aHAX /var/sods/vault/ /vault/sods/vault/
  else
    sudo cp -a /var/sods/vault/. /vault/sods/vault/
  fi
  sudo mv /var/sods/vault "/var/sods/vault.pre-$(date +%Y%m%d%H%M%S)"
fi
if [ ! -L /var/sods/vault ]; then
  sudo rm -rf /var/sods/vault
  sudo ln -s /vault/sods/vault /var/sods/vault
fi
sudo chown -h pi:pi /var/sods/vault
sudo chown -R pi:pi /var/sods /vault/sods

sudo cp "$ROOT_DIR/services/systemd/strangelab-vault-ingest.service" /etc/systemd/system/strangelab-vault-ingest.service
sudo systemctl daemon-reload
sudo systemctl enable strangelab-vault-ingest.service
sudo systemctl restart strangelab-vault-ingest.service

sudo systemctl --no-pager --full status strangelab-vault-ingest.service | sed -n '1,40p'
