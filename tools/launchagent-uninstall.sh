#!/usr/bin/env bash
set -euo pipefail

PLIST_DST="$HOME/Library/LaunchAgents/io.strangemythic.sods.station.plist"
UID="$(id -u)"

launchctl bootout "gui/$UID" "$PLIST_DST" >/dev/null 2>&1 || true
launchctl disable "gui/$UID/io.strangemythic.sods.station" >/dev/null 2>&1 || true

if [[ -f "$PLIST_DST" ]]; then
  rm "$PLIST_DST"
fi

echo "Uninstalled LaunchAgent."
