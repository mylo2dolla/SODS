#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
source "$REPO_ROOT/tools/_env.sh"

PI_AUX_IP="${PI_AUX_IP:-$AUX_HOST}"

curl -sS -X POST "http://${PI_AUX_IP}:9123/token" \
  -H 'content-type: application/json' \
  -d '{"identity":"token-test","room":"strangelab"}' | jq '{ok, hasToken:(.token|type=="string")}'

curl -sS -X POST "http://${PI_AUX_IP}:8099/god" \
  -H 'content-type: application/json' \
  -d '{"op":"whoami"}' | jq '.'

echo "Trigger sent. Verify in Vault ingest stream: control.god_button then agent.exec.result"
