#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
FIRMWARE_DIR="$REPO_ROOT/firmware/ops-portal/esp-web-tools/firmware/portal-cyd"

PORT="${PORT:-}"
BAUD="${ESPTOOL_BAUD:-921600}"

if [[ -z "$PORT" ]]; then
  PORT="$(ls /dev/tty.usbmodem* /dev/tty.usbserial* /dev/ttyACM* 2>/dev/null | head -n 1 || true)"
fi
if [[ -z "$PORT" ]]; then
  echo "flash-portal-cyd-cli: no serial port found. Set PORT=/dev/tty.usbmodemXXXX" >&2
  exit 2
fi

for f in bootloader.bin partitions.bin boot_app0.bin firmware.bin; do
  if [[ ! -f "$FIRMWARE_DIR/$f" ]]; then
    echo "flash-portal-cyd-cli: missing $FIRMWARE_DIR/$f. Run tools/portal-cyd-stage.sh" >&2
    exit 2
  fi
done

if ! python3 -c "import esptool" >/dev/null 2>&1; then
  echo "flash-portal-cyd-cli: esptool not installed. Install via 'python3 -m pip install esptool'." >&2
  exit 2
fi

python3 -m esptool --chip esp32 --port "$PORT" --baud "$BAUD" write_flash -z \
  0x1000 "$FIRMWARE_DIR/bootloader.bin" \
  0x8000 "$FIRMWARE_DIR/partitions.bin" \
  0xE000 "$FIRMWARE_DIR/boot_app0.bin" \
  0x10000 "$FIRMWARE_DIR/firmware.bin"

echo "Flashed Ops Portal CYD via $PORT"
