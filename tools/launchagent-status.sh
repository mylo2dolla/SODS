#!/usr/bin/env bash
set -euo pipefail

LABEL="io.strangemythic.sods.station"
PLIST_DST="$HOME/Library/LaunchAgents/${LABEL}.plist"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
LOG_PATH="$REPO_ROOT/data/logs/station.launchd.log"
UID="$(id -u)"

echo "LaunchAgent: $LABEL"
if launchctl print "gui/$UID/$LABEL" >/dev/null 2>&1; then
  echo "Status: loaded"
else
  echo "Status: not loaded"
fi

if [[ -f "$PLIST_DST" ]]; then
  echo "Plist: $PLIST_DST"
else
  echo "Plist: missing"
fi

echo "Log: $LOG_PATH"
