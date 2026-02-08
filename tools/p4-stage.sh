#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PROJ_DIR="$REPO_ROOT/firmware/sods-p4-godbutton"
VERSION="${FW_VERSION:-devstation}"

if [[ ! -d "$PROJ_DIR" ]]; then
  echo "p4-stage: project not found at $PROJ_DIR" >&2
  exit 2
fi

cd "$PROJ_DIR"
node ./tools/stage.mjs --board waveshare-esp32p4 --version "$VERSION"
