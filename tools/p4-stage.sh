#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PROJ_DIR="$REPO_ROOT/firmware/sods-p4-godbutton"
OUT_DIR="$PROJ_DIR/esp-web-tools/firmware/p4"

if [[ ! -d "$PROJ_DIR" ]]; then
  echo "p4-stage: project not found at $PROJ_DIR" >&2
  exit 2
fi

if [[ -z "${IDF_PATH:-}" ]]; then
  echo "p4-stage: IDF_PATH is not set. Source the ESP-IDF export script first." >&2
  exit 2
fi

cd "$PROJ_DIR"
idf.py build

BOOTLOADER="$PROJ_DIR/build/bootloader/bootloader.bin"
PARTITIONS="$PROJ_DIR/build/partition_table/partition-table.bin"
FIRMWARE="$PROJ_DIR/build/sods-p4-godbutton.bin"

if [[ ! -f "$BOOTLOADER" ]]; then
  echo "p4-stage: missing $BOOTLOADER" >&2
  exit 2
fi
if [[ ! -f "$PARTITIONS" ]]; then
  echo "p4-stage: missing $PARTITIONS" >&2
  exit 2
fi
if [[ ! -f "$FIRMWARE" ]]; then
  echo "p4-stage: missing $FIRMWARE" >&2
  exit 2
fi

mkdir -p "$OUT_DIR"
cp "$BOOTLOADER" "$OUT_DIR/bootloader.bin"
cp "$PARTITIONS" "$OUT_DIR/partitions.bin"
cp "$FIRMWARE" "$OUT_DIR/firmware.bin"

echo "Staged firmware to $OUT_DIR"
