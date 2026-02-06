#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
BUILD_DIR="$REPO_ROOT/firmware/ops-portal/.pio/build/ops-portal"
OUT_DIR="$REPO_ROOT/firmware/ops-portal/esp-web-tools/firmware/portal-cyd"

mkdir -p "$OUT_DIR"

cp "$BUILD_DIR/bootloader.bin" "$OUT_DIR/bootloader.bin"
cp "$BUILD_DIR/partitions.bin" "$OUT_DIR/partitions.bin"
cp "$BUILD_DIR/boot_app0.bin" "$OUT_DIR/boot_app0.bin"
cp "$BUILD_DIR/firmware.bin" "$OUT_DIR/firmware.bin"

echo "Staged portal-cyd firmware to $OUT_DIR"
