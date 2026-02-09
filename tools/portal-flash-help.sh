#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/_env.sh"

STATION_URL="${STATION_URL:-$SODS_STATION_URL}"

cat <<EOF
SODS Ops Portal (CYD) flash help

1) Build firmware:
   $REPO_ROOT/tools/portal-cyd-build.sh

2) Stage firmware for ESP Web Tools:
   $REPO_ROOT/tools/portal-cyd-stage.sh

3) Open the Station flash page:
   $STATION_URL/flash/portal-cyd

EOF
