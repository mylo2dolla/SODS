#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/tools/_env.sh"
PORT="${1:-$SODS_PORT}"
PI_LOGGER="${PI_LOGGER:-$PI_LOGGER_URL}"

cd "$ROOT/cli/sods"

if [[ ! -d node_modules ]]; then
  echo "Installing dependencies..."
  npm install
fi

echo "Starting sods on http://localhost:${PORT}"
PI_LOGGER="$PI_LOGGER" npm run dev -- --pi-logger "$PI_LOGGER" --port "$PORT"
