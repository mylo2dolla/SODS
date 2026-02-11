#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/_env.sh"
PLIST_DST="$HOME/Library/LaunchAgents/io.strangemythic.sods.station.plist"
LOG_DIR="$REPO_ROOT/data/logs"
SODS_BIN="$REPO_ROOT/tools/sods"
LOG_PATH="$LOG_DIR/station.launchd.log"
PORT="${PORT:-$SODS_PORT}"

mkdir -p "$HOME/Library/LaunchAgents"
mkdir -p "$LOG_DIR"

if [[ ! -x "$SODS_BIN" ]]; then
  echo "launchagent-install: missing executable sods binary at $SODS_BIN" >&2
  exit 2
fi

cat > "$PLIST_DST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
  <dict>
    <key>Label</key>
    <string>io.strangemythic.sods.station</string>
    <key>ProgramArguments</key>
    <array>
      <string>$SODS_BIN</string>
      <string>start</string>
      <string>--pi-logger</string>
      <string>$PI_LOGGER_URL</string>
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
EOF

UID="$(id -u)"
launchctl bootout "gui/$UID" "$PLIST_DST" >/dev/null 2>&1 || true
launchctl bootstrap "gui/$UID" "$PLIST_DST"
launchctl enable "gui/$UID/io.strangemythic.sods.station"
launchctl kickstart -k "gui/$UID/io.strangemythic.sods.station"

echo "Installed and started LaunchAgent:"
echo "  $PLIST_DST"
echo "Program:"
echo "  $SODS_BIN start --pi-logger $PI_LOGGER_URL --port $PORT"
echo "Logs:"
echo "  $LOG_PATH"
