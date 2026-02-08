#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 1 ]]; then
  echo "usage: $0 mac1|mac2"
  exit 1
fi

TARGET="$1"
ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
TARGET_DIR="/opt/strangelab"

# Ensure common Homebrew locations are on PATH for non-interactive ssh shells.
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"

BREW_BIN=""
if command -v brew >/dev/null 2>&1; then
  BREW_BIN="$(command -v brew)"
elif [[ -x /opt/homebrew/bin/brew ]]; then
  BREW_BIN="/opt/homebrew/bin/brew"
elif [[ -x /usr/local/bin/brew ]]; then
  BREW_BIN="/usr/local/bin/brew"
fi

if [[ -z "$BREW_BIN" ]]; then
  echo "Homebrew required (not found in PATH, /opt/homebrew/bin, or /usr/local/bin)"
  exit 1
fi

if ! command -v node >/dev/null 2>&1; then
  "$BREW_BIN" install node
fi

sudo mkdir -p "$TARGET_DIR"
sudo cp "$ROOT_DIR/agents/exec-agent.mjs" "$TARGET_DIR/exec-agent.mjs"
sudo cp "$ROOT_DIR/package.json" "$TARGET_DIR/package.json"

pushd "$TARGET_DIR" >/dev/null
sudo npm install --omit=dev
popd >/dev/null

case "$TARGET" in
  mac1)
    CAPS_SRC="$ROOT_DIR/services/capabilities/mac1.json"
    PLIST_SRC="$ROOT_DIR/services/launchd/com.strangelab.exec-agent.mac1.plist"
    PLIST_DST="/Library/LaunchDaemons/com.strangelab.exec-agent.mac1.plist"
    LABEL="com.strangelab.exec-agent.mac1"
    ;;
  mac2)
    CAPS_SRC="$ROOT_DIR/services/capabilities/mac2.json"
    PLIST_SRC="$ROOT_DIR/services/launchd/com.strangelab.exec-agent.mac2.plist"
    PLIST_DST="/Library/LaunchDaemons/com.strangelab.exec-agent.mac2.plist"
    LABEL="com.strangelab.exec-agent.mac2"
    ;;
  *)
    echo "target must be mac1 or mac2"
    exit 1
    ;;
esac

sudo cp "$CAPS_SRC" "$TARGET_DIR/capabilities.json"

sudo cp "$PLIST_SRC" "$PLIST_DST"
sudo chown root:wheel "$PLIST_DST"
sudo chmod 644 "$PLIST_DST"

sudo launchctl bootout system/"$LABEL" >/dev/null 2>&1 || true
sudo launchctl bootstrap system "$PLIST_DST"
sudo launchctl enable system/"$LABEL"
sudo launchctl kickstart -k system/"$LABEL"
sudo launchctl print system/"$LABEL" | sed -n '1,80p'

echo "mac agent install complete for $TARGET"
