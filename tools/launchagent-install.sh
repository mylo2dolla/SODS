#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PLIST_DST="$HOME/Library/LaunchAgents/io.strangemythic.sods.station.plist"
LOG_DIR="$REPO_ROOT/data/logs"
LOG_PATH="$LOG_DIR/station.launchd.log"
PI_LOGGER="${PI_LOGGER:-http://pi-logger.local:8088}"
PORT="${PORT:-9123}"

mkdir -p "$HOME/Library/LaunchAgents"
mkdir -p "$LOG_DIR"

cat >"$PLIST_DST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
  <dict>
    <key>Label</key>
    <string>io.strangemythic.sods.station</string>

    <key>ProgramArguments</key>
    <array>
      <string>$REPO_ROOT/tools/sods</string>
      <string>start</string>
      <string>--pi-logger</string>
      <string>$PI_LOGGER</string>
      <string>--port</string>
      <string>$PORT</string>
    </array>

    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>

    <key>StandardOutPath</key>
    <string>$LOG_PATH</string>
    <key>StandardErrorPath</key>
    <string>$LOG_PATH</string>
  </dict>
</plist>
PLIST
chmod 0644 "$PLIST_DST"

UID="$(id -u)"
launchctl bootout "gui/$UID" "$PLIST_DST" >/dev/null 2>&1 || true
launchctl bootstrap "gui/$UID" "$PLIST_DST"
launchctl enable "gui/$UID/io.strangemythic.sods.station"
launchctl kickstart -k "gui/$UID/io.strangemythic.sods.station"

echo "Installed and started LaunchAgent:"
echo "  $PLIST_DST"
echo "Logs:"
echo "  $LOG_PATH"
