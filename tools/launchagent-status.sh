#!/usr/bin/env bash
set -euo pipefail

LABEL="io.strangemythic.sods.station"
PLIST_DST="$HOME/Library/LaunchAgents/${LABEL}.plist"
LOG_PATH="/Users/letsdev/sods/SODS/data/logs/station.launchd.log"
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
