#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="$REPO_ROOT/.pio/build/esp32c3"
STAGE_DIR="$REPO_ROOT/esp-web-tools/firmware/esp32c3"
MANIFEST="$REPO_ROOT/esp-web-tools/manifest-esp32c3.json"

cd "$REPO_ROOT"
pio run -e esp32c3

mkdir -p "$STAGE_DIR"
cp -f "$BUILD_DIR/bootloader.bin" "$STAGE_DIR/bootloader.bin"
cp -f "$BUILD_DIR/partitions.bin" "$STAGE_DIR/partitions.bin"
cp -f "$BUILD_DIR/firmware.bin" "$STAGE_DIR/firmware.bin"

cat >"$MANIFEST" <<EOF_MANIFEST
{
  "name": "StrangeLab Node Agent (ESP32-C3)",
  "version": "0.1.0",
  "chipFamily": "ESP32-C3",
  "new_install_prompt_erase": true,
  "builds": [
    {
      "chipFamily": "ESP32-C3",
      "parts": [
        { "path": "firmware/esp32c3/bootloader.bin", "offset": 4096 },
        { "path": "firmware/esp32c3/partitions.bin", "offset": 32768 },
        { "path": "firmware/esp32c3/firmware.bin", "offset": 65536 }
      ]
    }
  ]
}
EOF_MANIFEST

size_bytes() {
  stat -f%z "$1"
}

echo "Staged ESP32-C3 firmware:"
echo "  bootloader.bin  $(size_bytes "$STAGE_DIR/bootloader.bin") bytes"
echo "  partitions.bin  $(size_bytes "$STAGE_DIR/partitions.bin") bytes"
echo "  firmware.bin    $(size_bytes "$STAGE_DIR/firmware.bin") bytes"
echo "  manifest        $MANIFEST"
