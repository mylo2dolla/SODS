#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

cd "$REPO_ROOT/firmware"
if [[ "${SODS_AUTO_STAGE_FIRMWARE:-1}" == "1" ]]; then
  node ./tools/fw-stage-all.mjs --skip-build --version "${FW_VERSION:-devstation}"
fi
node ./tools/fw-verify-all.mjs
