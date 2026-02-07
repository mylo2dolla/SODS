#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
APP_SOURCE="$REPO_ROOT/dist/DevStation.app"
APP_TARGET="/Applications/Dev Station.app"

if [[ ! -d "$APP_SOURCE" ]]; then
  "$REPO_ROOT/tools/devstation-build.sh"
fi

if [[ ! -d "$APP_SOURCE" ]]; then
  echo "devstation-install: app not found at $APP_SOURCE" >&2
  exit 2
fi

echo "Installing to $APP_TARGET"
rm -rf "$APP_TARGET"
/usr/bin/ditto "$APP_SOURCE" "$APP_TARGET"

echo "Installed: $APP_TARGET"
