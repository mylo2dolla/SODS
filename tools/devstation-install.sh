#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
APP_SOURCE="$REPO_ROOT/dist/DevStation.app"
APP_TARGET="/Applications/Dev Station.app"

source "$REPO_ROOT/tools/_app_bundle.sh"

if [[ ! -d "$APP_SOURCE" ]]; then
  "$REPO_ROOT/tools/devstation-build.sh"
fi

if [[ ! -d "$APP_SOURCE" ]]; then
  echo "devstation-install: app not found at $APP_SOURCE" >&2
  exit 2
fi

if ! validate_app_bundle "$APP_SOURCE"; then
  echo "devstation-install: source bundle invalid at $APP_SOURCE" >&2
  exit 2
fi

if [[ -e "$APP_TARGET" ]]; then
  if [[ ! -w "$APP_TARGET" ]]; then
    if [[ -t 0 ]]; then
      echo "devstation-install: permission required for $APP_TARGET (retrying with sudo)" >&2
      exec sudo "$REPO_ROOT/tools/devstation-install.sh"
    fi
    echo "devstation-install: no permission to overwrite $APP_TARGET" >&2
    echo "Run: sudo $REPO_ROOT/tools/devstation-install.sh" >&2
    exit 3
  fi
else
  if [[ ! -w "$(dirname "$APP_TARGET")" ]]; then
    if [[ -t 0 ]]; then
      echo "devstation-install: permission required for $(dirname "$APP_TARGET") (retrying with sudo)" >&2
      exec sudo "$REPO_ROOT/tools/devstation-install.sh"
    fi
    echo "devstation-install: no permission to write to $(dirname "$APP_TARGET")" >&2
    echo "Run: sudo $REPO_ROOT/tools/devstation-install.sh" >&2
    exit 3
  fi
fi

echo "Installing to $APP_TARGET"
rm -rf "$APP_TARGET"
/usr/bin/ditto "$APP_SOURCE" "$APP_TARGET"

if ! validate_app_bundle "$APP_TARGET"; then
  echo "devstation-install: installed bundle invalid at $APP_TARGET" >&2
  exit 2
fi

echo "Installed: $APP_TARGET"
