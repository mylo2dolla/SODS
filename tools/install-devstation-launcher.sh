#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

APP_NAME="${APP_NAME:-DevStation Stack}"
TARGET_DIR="/Applications"
if [[ ! -w "$TARGET_DIR" ]]; then
  TARGET_DIR="$HOME/Applications"
fi
mkdir -p "$TARGET_DIR"
APP_PATH="$TARGET_DIR/${APP_NAME}.app"
SHORTCUT_DIR="$HOME/Desktop/DevStation Launchers"
SHORTCUT_PATH="$SHORTCUT_DIR/${APP_NAME}.app"
MAIN_APP_PATH="/Applications/Dev Station.app"
MAIN_SHORTCUT_PATH="$SHORTCUT_DIR/Dev Station.app"

LOG_DIR="$HOME/Library/Logs/SODS"
mkdir -p "$LOG_DIR"

if [[ -x "$REPO_ROOT/tools/cleanup-old-devstation-assets.sh" ]]; then
  "$REPO_ROOT/tools/cleanup-old-devstation-assets.sh"
fi

REQUIRED_SCRIPTS=(
  "$REPO_ROOT/tools/launcher-up.sh"
  "$REPO_ROOT/tools/control-plane-up.sh"
  "$REPO_ROOT/tools/control-plane-status.sh"
)
for script_path in "${REQUIRED_SCRIPTS[@]}"; do
  if [[ ! -f "$script_path" ]]; then
    echo "missing required script: $script_path" >&2
    exit 2
  fi
  chmod +x "$script_path"
done

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

APPLESCRIPT_FILE="$TMP_DIR/launcher.applescript"
cat > "$APPLESCRIPT_FILE" <<EOF
on run
  set repoRoot to "${REPO_ROOT}"
  set startupCmd to repoRoot & "/tools/launcher-up.sh >> \$HOME/Library/Logs/SODS/launcher.log 2>&1 &"
  set launcherCmd to "/bin/bash -lc " & quoted form of startupCmd
  do shell script launcherCmd
  display notification "Dev Station startup launched" with title "SODS Launcher"
end run
EOF

rm -rf "$APP_PATH"
osacompile -o "$APP_PATH" "$APPLESCRIPT_FILE"

ICON_PNG="$REPO_ROOT/apps/dev-station/DevStation/Assets.xcassets/AppIcon.appiconset/icon_1024.png"
if [[ -f "$ICON_PNG" ]] && command -v iconutil >/dev/null 2>&1 && command -v sips >/dev/null 2>&1; then
  ICONSET="$TMP_DIR/AppIcon.iconset"
  mkdir -p "$ICONSET"
  sips -z 16 16 "$ICON_PNG" --out "$ICONSET/icon_16x16.png" >/dev/null
  sips -z 32 32 "$ICON_PNG" --out "$ICONSET/icon_16x16@2x.png" >/dev/null
  sips -z 32 32 "$ICON_PNG" --out "$ICONSET/icon_32x32.png" >/dev/null
  sips -z 64 64 "$ICON_PNG" --out "$ICONSET/icon_32x32@2x.png" >/dev/null
  sips -z 128 128 "$ICON_PNG" --out "$ICONSET/icon_128x128.png" >/dev/null
  sips -z 256 256 "$ICON_PNG" --out "$ICONSET/icon_128x128@2x.png" >/dev/null
  sips -z 256 256 "$ICON_PNG" --out "$ICONSET/icon_256x256.png" >/dev/null
  sips -z 512 512 "$ICON_PNG" --out "$ICONSET/icon_256x256@2x.png" >/dev/null
  sips -z 512 512 "$ICON_PNG" --out "$ICONSET/icon_512x512.png" >/dev/null
  cp "$ICON_PNG" "$ICONSET/icon_512x512@2x.png"
  iconutil -c icns "$ICONSET" -o "$TMP_DIR/applet.icns"
  cp "$TMP_DIR/applet.icns" "$APP_PATH/Contents/Resources/applet.icns"
fi

xattr -dr com.apple.quarantine "$APP_PATH" >/dev/null 2>&1 || true
codesign --force --deep --sign - "$APP_PATH" >/dev/null 2>&1 || true

mkdir -p "$SHORTCUT_DIR"
rm -f "$SHORTCUT_PATH"
ln -s "$APP_PATH" "$SHORTCUT_PATH"
if [[ -d "$MAIN_APP_PATH" ]]; then
  rm -f "$MAIN_SHORTCUT_PATH"
  ln -s "$MAIN_APP_PATH" "$MAIN_SHORTCUT_PATH"
fi

echo "Installed launcher: $APP_PATH"
echo "Desktop shortcuts: $SHORTCUT_DIR"
echo "Pin $APP_PATH in the Dock to start the full Dev Station stack."
echo "Launcher now runs full-fleet auto-heal with timeout before opening Dev Station."
