#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
if [[ -f "$REPO_ROOT/tools/_env.sh" ]]; then
  # shellcheck disable=SC1091
  source "$REPO_ROOT/tools/_env.sh"
fi

ROOT_DIR="$(cd -- "$SCRIPT_DIR/.." && pwd)"
TARGET_DIR="/opt/strangelab"
UFW_CIDR="${UFW_CIDR:-${AUX_CIDR:-192.168.8.0/24}}"

if ! command -v node >/dev/null 2>&1; then
  curl -fsSL https://deb.nodesource.com/setup_20.x | sudo -E bash -
  sudo apt-get update
  sudo apt-get install -y nodejs
fi

sudo mkdir -p "$TARGET_DIR"
sudo cp "$ROOT_DIR/agents/ops-feed.mjs" "$TARGET_DIR/ops-feed.mjs"
sudo cp "$ROOT_DIR/package.json" "$TARGET_DIR/package.json"

pushd "$TARGET_DIR" >/dev/null
sudo npm install --omit=dev
popd >/dev/null

sudo cp "$ROOT_DIR/services/systemd/strangelab-ops-feed.service" /etc/systemd/system/strangelab-ops-feed.service
sudo systemctl daemon-reload
sudo systemctl enable strangelab-ops-feed.service
sudo systemctl restart strangelab-ops-feed.service

if command -v ufw >/dev/null 2>&1; then
  sudo ufw allow from "$UFW_CIDR" to any port 9101 proto tcp >/dev/null 2>&1 || true
fi

sudo systemctl --no-pager --full status strangelab-ops-feed.service | sed -n '1,40p'
echo "ops-feed install complete"
