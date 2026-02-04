#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TARGET="esp32dev"
PORT=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --target)
      TARGET="$2"
      shift 2
      ;;
    --port)
      PORT="$2"
      shift 2
      ;;
    *)
      shift
      ;;
  esac
done

case "$TARGET" in
  esp32|esp32dev)
    SCRIPT="$REPO_ROOT/tools/flash-esp32dev.sh"
    ;;
  esp32c3)
    SCRIPT="$REPO_ROOT/tools/flash-esp32c3.sh"
    ;;
  *)
    echo "Unknown target: $TARGET (use esp32dev or esp32c3)" >&2
    exit 1
    ;;
esac

if [[ -n "$PORT" ]]; then
  "$SCRIPT" --port "$PORT"
else
  "$SCRIPT"
fi
