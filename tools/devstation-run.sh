#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/_env.sh"
PORT="${1:-$SODS_PORT}"
PI_LOGGER="${PI_LOGGER:-$PI_LOGGER_URL}"
APP_PATH="$REPO_ROOT/dist/DevStation.app"
LOG_DIR="$HOME/Library/Logs/SODS"
LOG_FILE="$LOG_DIR/station.log"
BUILD="${DEVSTATION_BUILD:-1}"

mkdir -p "$LOG_DIR"

STATION_URL="${SODS_STATION_URL:-http://127.0.0.1:${PORT}}"
if ! curl -fsS "${STATION_URL%/}/api/status" >/dev/null 2>&1; then
  "$REPO_ROOT/tools/station" start
fi

if [[ "${BUILD}" != "0" ]] || [[ ! -d "$APP_PATH" ]]; then
  "$REPO_ROOT/tools/devstation-build.sh"
fi

echo "Launching Dev Station..."
open "$APP_PATH"
