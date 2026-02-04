#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PORT="${1:-9123}"
PI_LOGGER="${PI_LOGGER:-http://pi-logger.local:8088}"

cd "$ROOT/cli/sods"

if [[ ! -d node_modules ]]; then
  echo "Installing dependencies..."
  npm install
fi

echo "Starting sods on http://localhost:${PORT}"
PI_LOGGER="$PI_LOGGER" npm run dev -- --pi-logger "$PI_LOGGER" --port "$PORT"
