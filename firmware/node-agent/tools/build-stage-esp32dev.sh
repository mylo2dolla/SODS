#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="${FW_VERSION:-devstation}"

cd "$REPO_ROOT"
node ./tools/stage.mjs --board esp32-devkitv1 --version "$VERSION"
