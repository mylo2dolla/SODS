#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

ARCHIVE_PATH="${1:-}"
if [[ -z "$ARCHIVE_PATH" ]]; then
  ARCHIVE_PATH="$(ls -dt "$ROOT_DIR"/build/SODSScanneriOS-*.xcarchive 2>/dev/null | head -n 1 || true)"
fi

if [[ -z "$ARCHIVE_PATH" || ! -d "$ARCHIVE_PATH" ]]; then
  echo "[FAIL] Archive path is missing. Run scripts/archive-release.sh first or pass an archive path." >&2
  exit 1
fi

TIMESTAMP="$(date -u +%Y%m%dT%H%M%SZ)"
EXPORT_PATH="${2:-$ROOT_DIR/build/export-$TIMESTAMP}"
mkdir -p "$EXPORT_PATH"

TEAM_ID="${DEVELOPMENT_TEAM_OVERRIDE:-$(xcodebuild -project SODSScanneriOS.xcodeproj -scheme SODSScanneriOS -configuration Release -showBuildSettings | awk -F' = ' '/DEVELOPMENT_TEAM = / {print $2; exit}' | tr -d '[:space:]')}"
if [[ -z "$TEAM_ID" || "$TEAM_ID" == '""' ]]; then
  echo "[FAIL] DEVELOPMENT_TEAM is empty. Set team in Xcode or pass DEVELOPMENT_TEAM_OVERRIDE." >&2
  exit 1
fi

EXPORT_OPTIONS_PLIST="$(mktemp /tmp/sods-scanner-export-options.XXXXXX.plist)"
cat > "$EXPORT_OPTIONS_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key>
  <string>app-store</string>
  <key>signingStyle</key>
  <string>automatic</string>
  <key>teamID</key>
  <string>$TEAM_ID</string>
  <key>uploadSymbols</key>
  <true/>
  <key>compileBitcode</key>
  <true/>
</dict>
</plist>
PLIST

xcodebuild \
  -exportArchive \
  -archivePath "$ARCHIVE_PATH" \
  -exportPath "$EXPORT_PATH" \
  -exportOptionsPlist "$EXPORT_OPTIONS_PLIST" \
  -allowProvisioningUpdates

rm -f "$EXPORT_OPTIONS_PLIST"

echo "[PASS] IPA export completed at: $EXPORT_PATH"
