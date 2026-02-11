#!/usr/bin/env bash
set -u -o pipefail

STATUS_FILE="$HOME/Library/Logs/SODS/control-plane-status.json"

if [[ ! -f "$STATUS_FILE" ]]; then
  echo "offline"
  exit 2
fi

overall="$(
  python3 - "$STATUS_FILE" <<'PY'
import json
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
try:
    data = json.loads(path.read_text())
except Exception:
    print("offline")
    sys.exit(2)

overall = str(data.get("overall", "offline")).strip().lower()
if overall not in {"ok", "degraded", "offline"}:
    print("offline")
    sys.exit(2)

print(overall)
PY
)"
rc=$?

echo "$overall"

if [[ $rc -ne 0 ]]; then
  exit 2
fi

if [[ "$overall" == "ok" ]]; then
  exit 0
fi
exit 1
