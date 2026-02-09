#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

BOARD="${1:-p4}"
VERSION="${FW_VERSION:-}"
PORT_ARG="${PORT:-auto}"

case "$BOARD" in
  p4|waveshare-esp32p4)
    APP_DIR="$REPO_ROOT/firmware/sods-p4-godbutton"
    BOARD_ID="waveshare-esp32p4"
    ;;
  esp32|esp32-devkitv1)
    APP_DIR="$REPO_ROOT/firmware/node-agent"
    BOARD_ID="esp32-devkitv1"
    ;;
  esp32c3|esp32-c3)
    APP_DIR="$REPO_ROOT/firmware/node-agent"
    BOARD_ID="esp32-c3"
    ;;
  portal|portal-cyd|cyd|cyd-2432s028)
    APP_DIR="$REPO_ROOT/firmware/ops-portal"
    BOARD_ID="cyd-2432s028"
    ;;
  *)
    echo "flash-diagnose: unknown board '$BOARD'" >&2
    echo "usage: $0 <p4|esp32|esp32c3|portal-cyd> [uses PORT and FW_VERSION env if set]" >&2
    exit 64
    ;;
esac

ARGS=(./tools/flash.mjs --board "$BOARD_ID" --port "$PORT_ARG" --dry-run)
if [[ -n "$VERSION" ]]; then
  ARGS+=(--version "$VERSION")
fi

cd "$APP_DIR"
node "${ARGS[@]}"
