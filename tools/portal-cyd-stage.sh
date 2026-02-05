#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
BUILD_DIR="$REPO_ROOT/firmware/ops-portal/.pio/build/ops-portal"
OUT_DIR="$REPO_ROOT/firmware/ops-portal/esp-web-tools/firmware/portal-cyd"
APP0_FALLBACK="$HOME/.platformio/packages/framework-arduinoespressif32/tools/partitions/boot_app0.bin"

mkdir -p "$OUT_DIR"

cp "$BUILD_DIR/bootloader.bin" "$OUT_DIR/bootloader.bin"
cp "$BUILD_DIR/partitions.bin" "$OUT_DIR/partitions.bin"
if [[ -f "$BUILD_DIR/boot_app0.bin" ]]; then
  cp "$BUILD_DIR/boot_app0.bin" "$OUT_DIR/boot_app0.bin"
elif [[ -f "$APP0_FALLBACK" ]]; then
  cp "$APP0_FALLBACK" "$OUT_DIR/boot_app0.bin"
else
  echo "portal-cyd-stage: boot_app0.bin not found in build dir or fallback path" >&2
  exit 2
fi
cp "$BUILD_DIR/firmware.bin" "$OUT_DIR/firmware.bin"

echo "Staged portal-cyd firmware to $OUT_DIR"
