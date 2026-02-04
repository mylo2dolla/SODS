#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PLIST_SRC="$REPO_ROOT/launchd/io.strangemythic.sods.station.plist"
PLIST_DST="$HOME/Library/LaunchAgents/io.strangemythic.sods.station.plist"
LOG_DIR="$REPO_ROOT/data/logs"

mkdir -p "$HOME/Library/LaunchAgents"
mkdir -p "$LOG_DIR"

if [[ ! -f "$PLIST_SRC" ]]; then
  echo "launchagent-install: missing $PLIST_SRC" >&2
  exit 2
fi

cp "$PLIST_SRC" "$PLIST_DST"

UID="$(id -u)"
launchctl bootout "gui/$UID" "$PLIST_DST" >/dev/null 2>&1 || true
launchctl bootstrap "gui/$UID" "$PLIST_DST"
launchctl enable "gui/$UID/io.strangemythic.sods.station"
launchctl kickstart -k "gui/$UID/io.strangemythic.sods.station"

echo "Installed and started LaunchAgent:"
echo "  $PLIST_DST"
echo "Logs:"
echo "  $LOG_DIR/station.launchd.log"
