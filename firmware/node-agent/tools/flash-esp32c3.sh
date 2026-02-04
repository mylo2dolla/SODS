#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PORT="8000"
if [[ "${1:-}" == "--port" && -n "${2:-}" ]]; then
  PORT="$2"
fi
URL="http://localhost:${PORT}/esp-web-tools/?chip=esp32c3"

"$REPO_ROOT/tools/build-stage-esp32c3.sh"

if lsof -iTCP:"$PORT" -sTCP:LISTEN >/dev/null 2>&1; then
  echo "$URL"
  open "$URL" >/dev/null 2>&1 || true
  exit 0
fi

cd "$REPO_ROOT"
echo "Serving $REPO_ROOT on http://localhost:${PORT}"
python3 -m http.server "$PORT" >/dev/null 2>&1 &
SERVER_PID=$!

sleep 0.2
echo "$URL"
open "$URL" >/dev/null 2>&1 || true

trap 'kill "$SERVER_PID" >/dev/null 2>&1 || true' EXIT
wait "$SERVER_PID"
