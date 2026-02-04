#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PORT="${1:-9123}"
PI_LOGGER="${PI_LOGGER:-http://pi-logger.local:8088}"
APP_PATH="$REPO_ROOT/dist/DevStation.app"
LOG_DIR="$HOME/Library/Logs/SODS"
LOG_FILE="$LOG_DIR/station.log"

mkdir -p "$LOG_DIR"

if ! curl -fsS "http://localhost:${PORT}/api/status" >/dev/null 2>&1; then
  echo "Starting station on http://localhost:${PORT}"
  nohup "$REPO_ROOT/tools/sods" start --pi-logger "$PI_LOGGER" --port "$PORT" >>"$LOG_FILE" 2>&1 &
  sleep 1
fi

if [[ ! -d "$APP_PATH" ]]; then
  "$REPO_ROOT/tools/devstation-build.sh"
fi

echo "Launching Dev Station..."
open "$APP_PATH"
