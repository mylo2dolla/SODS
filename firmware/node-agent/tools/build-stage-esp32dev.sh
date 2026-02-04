#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="$REPO_ROOT/.pio/build/esp32dev"
STAGE_DIR="$REPO_ROOT/esp-web-tools/firmware/esp32dev"

cd "$REPO_ROOT"
pio run -e esp32dev

mkdir -p "$STAGE_DIR"
cp -f "$BUILD_DIR/bootloader.bin" "$STAGE_DIR/bootloader.bin"
cp -f "$BUILD_DIR/partitions.bin" "$STAGE_DIR/partitions.bin"
cp -f "$BUILD_DIR/firmware.bin" "$STAGE_DIR/firmware.bin"

size_bytes() {
  stat -f%z "$1"
}

echo "Staged ESP32 dev firmware:"
echo "  bootloader.bin  $(size_bytes "$STAGE_DIR/bootloader.bin") bytes"
echo "  partitions.bin  $(size_bytes "$STAGE_DIR/partitions.bin") bytes"
echo "  firmware.bin    $(size_bytes "$STAGE_DIR/firmware.bin") bytes"
