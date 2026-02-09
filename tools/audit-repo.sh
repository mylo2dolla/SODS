#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

missing=0

expect_dir() {
  local path="$1"
  if [[ ! -d "$REPO_ROOT/$path" ]]; then
    echo "missing dir: $path"
    missing=1
  fi
}

expect_file() {
  local path="$1"
  if [[ ! -f "$REPO_ROOT/$path" ]]; then
    echo "missing file: $path"
    missing=1
  fi
}

expect_exec() {
  local path="$1"
  if [[ ! -x "$REPO_ROOT/$path" ]]; then
    echo "not executable: $path"
    missing=1
  fi
}

expect_dir "cli/sods"
expect_dir "apps/dev-station"
expect_dir "firmware"
expect_dir "firmware/ops-portal"
expect_dir "tools"
expect_dir "docs"

expect_file "tools/sods"
expect_file "tools/devstation"
expect_file "tools/station"
expect_file "tools/cockpit"
expect_file "tools/permfix.sh"
expect_exec "tools/sods"
expect_exec "tools/devstation"
expect_exec "tools/station"
expect_exec "tools/cockpit"
expect_exec "tools/permfix.sh"

expect_file "docs/tool-registry.json"
expect_file "docs/presets.json"
expect_file "docs/runbooks.json"

if [[ "$missing" -ne 0 ]]; then
  echo "repo audit failed"
  exit 2
fi

echo "repo audit ok"
