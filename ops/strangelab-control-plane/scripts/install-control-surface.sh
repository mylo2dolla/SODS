#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
SRC_DIR="$ROOT_DIR/control-surface"
TARGET_ROOT="/opt/strangelab"
BIN_DIR="$TARGET_ROOT/bin"
DESKTOP_DIR="$TARGET_ROOT/desktop"
ICON_DIR="$TARGET_ROOT/icons"
USER_DESKTOP="${HOME}/Desktop"
USER_APPS="${HOME}/.local/share/applications"

sudo mkdir -p "$BIN_DIR" "$DESKTOP_DIR" "$ICON_DIR"
sudo cp "$SRC_DIR/bin/"* "$BIN_DIR/"
sudo cp "$SRC_DIR/desktop/"*.desktop "$DESKTOP_DIR/"
sudo cp "$SRC_DIR/icons/"* "$ICON_DIR/"
sudo chmod 755 "$BIN_DIR/"*
sudo chmod 644 "$DESKTOP_DIR/"*.desktop "$ICON_DIR/"*

mkdir -p "$USER_DESKTOP" "$USER_APPS"
cp "$SRC_DIR/desktop/"*.desktop "$USER_APPS/"
cp "$SRC_DIR/desktop/"*.desktop "$USER_DESKTOP/" || true
chmod +x "$USER_DESKTOP/"*.desktop 2>/dev/null || true

echo "control surface installed:"
echo "  bin:      $BIN_DIR"
echo "  desktop:  $DESKTOP_DIR"
echo "  icons:    $ICON_DIR"
echo "  launchers copied to:"
echo "    $USER_APPS"
echo "    $USER_DESKTOP"
