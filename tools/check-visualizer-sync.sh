#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
WORKSPACE_ROOT="$(cd "$REPO_ROOT/../../.." && pwd)"

PKG_VISUALIZER="$WORKSPACE_ROOT/LvlUpKit.package/Sources/LvlUpKitSODSInternal/VisualizerView.swift"
APP_VISUALIZER="$REPO_ROOT/apps/dev-station/DevStation/VisualizerView.swift"

if [[ ! -f "$PKG_VISUALIZER" ]]; then
  echo "check-visualizer-sync: missing package visualizer: $PKG_VISUALIZER (skipping)" >&2
  exit 0
fi

if [[ ! -f "$APP_VISUALIZER" ]]; then
  echo "check-visualizer-sync: missing app visualizer: $APP_VISUALIZER" >&2
  exit 2
fi

if ! cmp -s "$PKG_VISUALIZER" "$APP_VISUALIZER"; then
  echo "Visualizer sync FAILED." >&2
  echo "Canonical package visualizer differs from app visualizer." >&2
  echo "Run:" >&2
  echo "  cp \"$PKG_VISUALIZER\" \"$APP_VISUALIZER\"" >&2
  exit 1
fi

echo "Visualizer sync OK."
