#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PROJ_DIR="$REPO_ROOT/firmware/sods-p4-godbutton"

if [[ ! -d "$PROJ_DIR" ]]; then
  echo "p4-flash: project not found at $PROJ_DIR" >&2
  exit 2
fi

if [[ -z "${IDF_PATH:-}" ]]; then
  echo "p4-flash: IDF_PATH is not set. Source the ESP-IDF export script first." >&2
  exit 2
fi

PORT="${PORT:-}"
if [[ -z "$PORT" ]]; then
  PORT="$(ls /dev/tty.usbmodem* /dev/tty.usbserial* /dev/ttyACM* 2>/dev/null | head -n 1 || true)"
fi
if [[ -z "$PORT" ]]; then
  echo "p4-flash: no serial port found. Set PORT=/dev/tty.usbmodemXXXX" >&2
  exit 2
fi

cd "$PROJ_DIR"
idf.py -p "$PORT" flash

echo "Flashed via $PORT"
echo "Build output: $PROJ_DIR/build"
