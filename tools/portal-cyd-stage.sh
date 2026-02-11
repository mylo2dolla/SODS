#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
VERSION="${FW_VERSION:-devstation}"

cd "$REPO_ROOT/firmware/ops-portal"
node ./tools/stage.mjs --board cyd-2432s028 --version "$VERSION"
