#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PROJ_DIR="$REPO_ROOT/firmware/sods-p4-godbutton"

if [[ ! -d "$PROJ_DIR" ]]; then
  echo "p4-build: project not found at $PROJ_DIR" >&2
  exit 2
fi

cd "$PROJ_DIR"

if [[ -z "${IDF_PATH:-}" ]]; then
  echo "p4-build: IDF_PATH is not set. Source the ESP-IDF export script first." >&2
  exit 2
fi

idf.py set-target esp32p4
idf.py build

echo "Build output: $PROJ_DIR/build"
