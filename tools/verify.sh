#!/usr/bin/env bash
set -euo pipefail

BASE_URL="${1:-http://localhost:9123}"

check() {
  local path="$1"
  local url="$BASE_URL$path"
  echo "Checking $url"
  curl -fsS "$url" >/dev/null
}

check "/health"
check "/metrics"
check "/nodes"

echo "verify ok"
