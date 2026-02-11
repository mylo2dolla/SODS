#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/_env.sh"
REMOTE_ROOT="${REMOTE_ROOT:-~/SODS-main}"
LOCAL_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

DRY_RUN_ARG=""
if [[ "${1:-}" == "--dry-run" ]]; then
  DRY_RUN_ARG="--dry-run"
fi

rsync -az ${DRY_RUN_ARG} \
  --delete \
  --exclude '.git/' \
  --exclude '.DS_Store' \
  --exclude 'cli/sods/node_modules/' \
  --exclude 'firmware/**/.pio/' \
  --exclude 'apps/dev-station/**/xcuserdata/' \
  --exclude 'apps/dev-station/**/DerivedData/' \
  "$REMOTE_HOST:$REMOTE_ROOT/" "$LOCAL_ROOT/"

echo "Synced $REMOTE_HOST:$REMOTE_ROOT -> local"
